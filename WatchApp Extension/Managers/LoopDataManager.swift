//
//  LoopDataManager.swift
//  WatchApp Extension
//
//  Created by Bharat Mediratta on 6/21/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore
import WatchConnectivity
import os.log


class LoopDataManager {
    let carbStore: CarbStore

    let glucoseStore: GlucoseStore

    @PersistedProperty(key: "Settings")
    private var rawSettings: LoopSettings.RawValue?

    // Main queue only
    var settings: LoopSettings {
        didSet {
            needsDidUpdateContextNotification = true
            sendDidUpdateContextNotificationIfNecessary()
            rawSettings = settings.rawValue
        }
    }

    // Main queue only
    var supportedBolusVolumes = UserDefaults.standard.supportedBolusVolumes {
        didSet {
            UserDefaults.standard.supportedBolusVolumes = supportedBolusVolumes
            needsDidUpdateContextNotification = true
            sendDidUpdateContextNotificationIfNecessary()
        }
    }

    private let log = OSLog(category: "LoopDataManager")

    // Main queue only
    private(set) var activeContext: WatchContext? {
        didSet {
            needsDidUpdateContextNotification = true
            sendDidUpdateContextNotificationIfNecessary()
        }
    }

    private var needsDidUpdateContextNotification: Bool = false

    /// The most recent context the PHONE sent, kept even while a loan makes it non-authoritative
    /// for display. The watch's phone-BG fallback reads its glucose from here: that relay is the
    /// backup CGM source and must survive the display gate below. Main queue only.
    private(set) var phoneRelayContext: WatchContext?

    /// The last attempt to backfill glucose. We use a date because the message timeout is longer
    /// than our desired retry interval, so we allow multiple messages in-flight
    /// Main queue only
    private var lastGlucoseBackfill = Date.distantPast

    public let healthStore: HKHealthStore

    init() {
        healthStore = HKHealthStore()
        let cacheStore = PersistenceController.controllerInLocalDirectory()

        carbStore = CarbStore(
            cacheStore: cacheStore,
            cacheLength: .hours(24),    // Require 24 hours to store recent carbs "since midnight" for CarbEntryListController
            defaultAbsorptionTimes: LoopCoreConstants.defaultCarbAbsorptionTimes,
            syncVersion: 0,
            provenanceIdentifier: HKSource.default().bundleIdentifier
        )
        glucoseStore = GlucoseStore(
            cacheStore: cacheStore,
            cacheLength: .hours(4),
            provenanceIdentifier: HKSource.default().bundleIdentifier
        )

        settings = LoopSettings()

        if let rawSettings = rawSettings, let storedSettings = LoopSettings(rawValue: rawSettings) {
            self.settings = storedSettings
        }
    }
}

extension LoopDataManager {
    static let didUpdateContextNotification = Notification.Name(rawValue: "com.loopkit.notification.ContextUpdated")
}

extension LoopDataManager {
    func updateContext(_ context: WatchContext) {
        dispatchPrecondition(condition: .onQueue(.main))

        // #47 ROOT CAUSE (2026-08-05): `shouldReplace` compares ONLY glucoseDate, with `>=`.
        // The phone relays the same physical reading the watch just took, so its context
        // carries an EQUAL timestamp and replaces the watch's — silently discarding the
        // watch-authored isClosedLoop, IOB, COB, temp and prediction. That is why every stock
        // watch screen reverted to the phone's view during a loan: the ring showing the phone's
        // loop mode, the blank prediction line, the blank recommended bolus. One cause, three
        // symptoms, all reported separately.
        //
        // During a loan the WATCH is the dosing controller, so its context is authoritative and
        // the phone's is stale by construction. Refuse the phone's outright rather than trying
        // to merge — there is no field on it the watch does not know better, except the display
        // unit, which publishHUDContext already carries forward.
        // The phone's context is always retained for its GLUCOSE, whatever we do about display.
        if !context.isWatchAuthored {
            phoneRelayContext = context
        }
        let onLoan = ExtensionDelegate.shared().stockLoopSession.loanController.isLoanActiveNonBlocking
        if onLoan && !context.isWatchAuthored {
            // Its LOOP STATE is stale during a loan (see above), so it must not become
            // activeContext. But two things still have to happen, and an early `return` here
            // silently killed both — the backup BG source, during exactly the window it exists
            // for (caught by Jeremy before this shipped):
            //
            //   1. the relayed reading still belongs in the store, and
            //   2. the notification must still fire — WatchLoopManager's
            //      ingestPhoneGlucoseFromContext hangs off didUpdateContextNotification, and
            //      that notification is posted by activeContext's didSet, which we are skipping.
            if let newGlucoseSample = context.newGlucoseSample {
                glucoseStore.addGlucoseSamples([newGlucoseSample]) { (_) in }
            }
            NotificationCenter.default.post(name: LoopDataManager.didUpdateContextNotification, object: self)
            return
        }
        if activeContext == nil || context.shouldReplace(activeContext!) {
            if let newGlucoseSample = context.newGlucoseSample {
                self.glucoseStore.addGlucoseSamples([newGlucoseSample]) { (_) in }
            }
            activeContext = context
        }
    }

    func sendDidUpdateContextNotificationIfNecessary() {
        dispatchPrecondition(condition: .onQueue(.main))

        if needsDidUpdateContextNotification && !WCSession.default.hasContentPending {
            needsDidUpdateContextNotification = false
            NotificationCenter.default.post(name: LoopDataManager.didUpdateContextNotification, object: self)
        }
    }

    func requestCarbBackfill() {
        dispatchPrecondition(condition: .onQueue(.main))

        let start = min(Calendar.current.startOfDay(for: Date()), Date(timeIntervalSinceNow: -carbStore.maximumAbsorptionTimeInterval))
        let userInfo = CarbBackfillRequestUserInfo(startDate: start)
        WCSession.default.sendCarbBackfillRequestMessage(userInfo) { (result) in
            switch result {
            case .success(let context):
                self.carbStore.setSyncCarbObjects(context.objects) { (error) in
                    if let error = error {
                        self.log.error("Failure setting sync carb objects: %{public}@", String(describing: error))
                    }
                }
            case .failure:
                // Already logged
                break
            }
        }
    }

    @discardableResult
    func requestGlucoseBackfillIfNecessary() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        guard lastGlucoseBackfill < .staleGlucoseCutoff else {
            log.default("Skipping glucose backfill request because our latest attempt was %{public}@", String(describing: lastGlucoseBackfill))
            return false
        }

        // Loop doesn't read data from HealthKit anymore, and its local watch data is truly ephemeral
        // to power the chart. Fetch enough data to populate the display of the chart.
        let latestDate = max(lastGlucoseBackfill, .earliestGlucoseCutoff)
        guard latestDate < .staleGlucoseCutoff else {
            self.log.default("Skipping glucose backfill request because our latest sample date is %{public}@", String(describing: latestDate))
            return false
        }

        lastGlucoseBackfill = Date()
        let userInfo = GlucoseBackfillRequestUserInfo(startDate: latestDate)
        WCSession.default.sendGlucoseBackfillRequestMessage(userInfo) { (result) in
            switch result {
            case .success(let context):
                self.glucoseStore.setSyncGlucoseSamples(context.samples) { (error) in
                    if let error = error {
                        self.log.error("Failure setting sync glucose samples: %{public}@", String(describing: error))
                    }
                }
            case .failure:
                // Already logged
                // Reset our last date to immediately retry
                DispatchQueue.main.async {
                    self.lastGlucoseBackfill = .earliestGlucoseCutoff
                }
            }
        }

        return true
    }

    func requestContextUpdate(completion: @escaping () -> Void = { }) {
        try? WCSession.default.sendContextRequestMessage(WatchContextRequestUserInfo(), completionHandler: { (result) in
            DispatchQueue.main.async {
                RuntimeStateLog.mark("loop.contextReply")
                switch result {
                case .success(let context):
                    self.updateContext(context)
                case .failure:
                    break
                }
                completion()
            }
        })
    }
}

extension LoopDataManager {
    var displayGlucoseUnit: HKUnit {
        activeContext?.displayGlucoseUnit ?? .milligramsPerDeciliter
    }
}

extension LoopDataManager {
    func generateChartData(completion: @escaping (GlucoseChartData?) -> Void) {
        guard let activeContext = activeContext else {
            completion(nil)
            return
        }

        glucoseStore.getGlucoseSamples(start: .earliestGlucoseCutoff) { result in
            var historicalGlucose: [StoredGlucoseSample]?
            switch result {
            case .failure(let error):
                self.log.error("Failure getting glucose samples: %{public}@", String(describing: error))
                historicalGlucose = nil
            case .success(let samples):
                historicalGlucose = samples
            }
            let chartData = GlucoseChartData(
                unit: activeContext.displayGlucoseUnit,
                correctionRange: self.settings.glucoseTargetRangeSchedule,
                preMealOverride: self.settings.preMealOverride,
                scheduleOverride: self.settings.scheduleOverride,
                historicalGlucose: historicalGlucose,
                predictedGlucose: (activeContext.isClosedLoop ?? false) ? activeContext.predictedGlucose?.values : nil
            )
            completion(chartData)
        }
    }
}
