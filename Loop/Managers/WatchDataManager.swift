//
//  WatchDataManager.swift
//  Loop
//
//  Created by Nathan Racklyeft on 5/29/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import HealthKit
import UIKit
import WatchConnectivity
import LoopKit
import LoopCore
import CryptoKit

final class WatchDataManager: NSObject {

    private unowned let deviceManager: DeviceDataManager
    
    init(deviceManager: DeviceDataManager, healthStore: HKHealthStore) {
        self.deviceManager = deviceManager
        self.sleepStore = SleepStore(healthStore: healthStore)
        self.lastBedtimeQuery = UserDefaults.appGroup?.lastBedtimeQuery ?? .distantPast
        self.bedtime = UserDefaults.appGroup?.bedtime

        super.init()

        NotificationCenter.default.addObserver(self, selector: #selector(updateWatch(_:)), name: .LoopDataUpdated, object: deviceManager.loopManager)
        NotificationCenter.default.addObserver(self, selector: #selector(sendSupportedBolusVolumesIfNeeded), name: .PumpManagerChanged, object: deviceManager)

        watchSession?.delegate = self
        watchSession?.activate()
    }

    private let log = DiagnosticLog(category: "WatchDataManager")

    private var watchSession: WCSession? = {
        if WCSession.isSupported() {
            return WCSession.default
        } else {
            return nil
        }
    }()

    private var lastSentSettings: LoopSettings?
    private var lastSentBolusVolumes: [Double]?

    // MARK: - Pod loan (watch borrows the pod for a workout)

    /// The user's `dosingEnabled` setting captured when the pod was loaned to the
    /// watch, so it can be restored exactly on hand-back. Non-nil while a loan is
    /// active. Persisted (app group) so a phone reboot mid-loan can't lose it —
    /// losing it would leave closed loop silently OFF after hand-back.
    private var dosingEnabledBeforeWatchLoan: Bool? {
        get { UserDefaults.appGroup?.dosingEnabledBeforeWatchLoan }
        set { UserDefaults.appGroup?.dosingEnabledBeforeWatchLoan = newValue }
    }

    /// The most recent hand-back summary from the watch (Phase 1: shown to the
    /// user). `lastWatchLoanJournalData` keeps the raw journal for Phase 2 IOB
    /// reconciliation.
    private(set) var lastWatchLoanSummary: String?
    private(set) var lastWatchLoanJournalData: Data?

    private var contextDosingDecisions: [Date: BolusDosingDecision] {
        get { lockedContextDosingDecisions.value }
        set { lockedContextDosingDecisions.value = newValue }
    }
    private var lockedContextDosingDecisions: Locked<[Date: BolusDosingDecision]> = Locked([:])

    private let contextDosingDecisionExpirationDuration: TimeInterval = -.minutes(5)

    let sleepStore: SleepStore
    
    var lastBedtimeQuery: Date {
        didSet {
            UserDefaults.appGroup?.lastBedtimeQuery = lastBedtimeQuery
        }
    }
    
    var bedtime: Date? {
        didSet {
            UserDefaults.appGroup?.bedtime = bedtime
        }
    }
    
    private func updateBedtimeIfNeeded() {
        let now = Date()
        let lastUpdateInterval = now.timeIntervalSince(lastBedtimeQuery)
        
        guard lastUpdateInterval >= TimeInterval(hours: 24) else {
            // increment the bedtime by 1 day if it's before the current time, but we don't need to make another HealthKit query yet
            if let bedtime = bedtime, bedtime < now {
                let calendar = Calendar.current
                let hourComponent = calendar.component(.hour, from: bedtime)
                let minuteComponent = calendar.component(.minute, from: bedtime)
                
                if let newBedtime = calendar.nextDate(after: now, matching: DateComponents(hour: hourComponent, minute: minuteComponent), matchingPolicy: .nextTime) {
                    self.bedtime = newBedtime
                }
            }
            
            return
        }

        sleepStore.getAverageSleepStartTime() { (result) in

            self.lastBedtimeQuery = now
            
            switch result {
                case .success(let bedtime):
                    self.bedtime = bedtime
                case .failure:
                    self.bedtime = nil
            }
        }
    }

    @objc private func updateWatch(_ notification: Notification) {
        guard
            let rawUpdateContext = notification.userInfo?[LoopDataManager.LoopUpdateContextKey] as? LoopDataManager.LoopUpdateContext.RawValue,
            let updateContext = LoopDataManager.LoopUpdateContext(rawValue: rawUpdateContext)
        else {
            return
        }

        // Any update context should trigger a watch update
        sendWatchContextIfNeeded()

        if case .preferences = updateContext {
            sendSettingsIfNeeded()
        }
    }

    private var lastComplicationContext: WatchContext?

    private let minTrendDrift: Double = 20
    private lazy var minTrendUnit = HKUnit.milligramsPerDeciliter

    private func sendSettingsIfNeeded() {
        let settings = deviceManager.loopManager.settings

        guard let session = watchSession, session.isPaired, session.isWatchAppInstalled else {
            // Not silent: without this line, a watch that never receives settings
            // (unpaired / app not installed / sim WC inert) is invisible in logs.
            log.default("Skipping settings transfer: paired=%{public}@ watchAppInstalled=%{public}@",
                        String(describing: watchSession?.isPaired),
                        String(describing: watchSession?.isWatchAppInstalled))
            return
        }

        guard case .activated = session.activationState else {
            session.activate()
            return
        }

        guard settings != lastSentSettings else {
            log.default("Skipping settings transfer due to no changes")
            return
        }

        lastSentSettings = settings

        // clear any old pending settings transfers
        for transfer in session.outstandingUserInfoTransfers {
            if (transfer.userInfo["name"] as? String) == LoopSettingsUserInfo.name {
                log.default("Cancelling old setings transfer")
                transfer.cancel()
            }
        }

        let userInfo = LoopSettingsUserInfo(settings: settings).rawValue
        log.default("Transferring LoopSettingsUserInfo: %{public}@", userInfo)
        session.transferUserInfo(userInfo)
    }

    @objc private func sendSupportedBolusVolumesIfNeeded() {
        guard
            let volumes = deviceManager.pumpManager?.supportedBolusVolumes,
            let session = watchSession,
            session.isPaired,
            session.isWatchAppInstalled
        else {
            return
        }

        guard case .activated = session.activationState else {
            session.activate()
            return
        }

        guard volumes != lastSentBolusVolumes else {
            log.default("Skipping bolus volumes transfer due to no changes")
            return
        }

        lastSentBolusVolumes = volumes

        log.default("Transferring supported bolus volumes")
        session.transferUserInfo(SupportedBolusVolumesUserInfo(supportedBolusVolumes: volumes).rawValue)
    }

    private func sendWatchContextIfNeeded() {
        guard let session = watchSession, session.isPaired, session.isWatchAppInstalled else {
            return
        }

        guard case .activated = session.activationState else {
            session.activate()
            return
        }

        createWatchContext { (context) in
            self.sendWatchContext(context)
        }
    }

    private func sendWatchContext(_ context: WatchContext) {
        guard let session = watchSession, session.isPaired, session.isWatchAppInstalled else {
            return
        }

        guard case .activated = session.activationState else {
            session.activate()
            return
        }

        let complicationShouldUpdate: Bool
        updateBedtimeIfNeeded()

        if let lastContext = lastComplicationContext,
            let lastGlucose = lastContext.glucose, let lastGlucoseDate = lastContext.glucoseDate,
            let newGlucose = context.glucose, let newGlucoseDate = context.glucoseDate
        {
            let enoughTimePassed = newGlucoseDate.timeIntervalSince(lastGlucoseDate) >= session.complicationUserInfoTransferInterval(bedtime: bedtime)
            let enoughTrendDrift = abs(newGlucose.doubleValue(for: minTrendUnit) - lastGlucose.doubleValue(for: minTrendUnit)) >= minTrendDrift

            complicationShouldUpdate = enoughTimePassed || enoughTrendDrift
        } else {
            complicationShouldUpdate = true
        }

        if session.isComplicationEnabled && complicationShouldUpdate {
            log.default("transferCurrentComplicationUserInfo")
            session.transferCurrentComplicationUserInfo(context.rawValue)
            lastComplicationContext = context
        } else {
            do {
                log.default("updateApplicationContext")
                try session.updateApplicationContext(context.rawValue)
            } catch let error {
                log.error("%{public}@", String(describing: error))
            }
        }
    }

    private func createWatchContext(recommendingBolusFor potentialCarbEntry: NewCarbEntry? = nil, _ completion: @escaping (_ context: WatchContext) -> Void) {
        var dosingDecision = BolusDosingDecision(for: .watchBolus)

        let loopManager = deviceManager.loopManager!

        let glucose = deviceManager.glucoseStore.latestGlucose
        let reservoir =  deviceManager.doseStore.lastReservoirValue
        let basalDeliveryState = deviceManager.pumpManager?.status.basalDeliveryState

        loopManager.getLoopState { (manager, state) in
            let updateGroup = DispatchGroup()

            let carbsOnBoard = state.carbsOnBoard

            let context = WatchContext(glucose: glucose, glucoseUnit: self.deviceManager.preferredGlucoseUnit)
            context.reservoir = reservoir?.unitVolume
            context.loopLastRunDate = manager.lastLoopCompleted
            context.cob = carbsOnBoard?.quantity.doubleValue(for: HKUnit.gram())

            if let glucoseDisplay = self.deviceManager.glucoseDisplay(for: glucose) {
                context.glucoseTrend = glucoseDisplay.trendType
                context.glucoseTrendRate = glucoseDisplay.trendRate
            }

            dosingDecision.carbsOnBoard = carbsOnBoard

            context.cgmManagerState = self.deviceManager.cgmManager?.rawValue
        
            let settings = self.deviceManager.loopManager.settings

            context.isClosedLoop = settings.dosingEnabled

            context.potentialCarbEntry = potentialCarbEntry
            if let recommendedBolus = try? state.recommendBolus(consideringPotentialCarbEntry: potentialCarbEntry, replacingCarbEntry: nil, considerPositiveVelocityAndRC: FeatureFlags.usePositiveMomentumAndRCForManualBoluses)
            {
                context.recommendedBolusDose = recommendedBolus.amount
                dosingDecision.manualBolusRecommendation = ManualBolusRecommendationWithDate(recommendation: recommendedBolus,
                                                                                             date: Date())
            }

            var historicalGlucose: [HistoricalGlucoseValue]?
            if let glucose = glucose {
                updateGroup.enter()
                let historicalGlucoseStartDate = Date(timeIntervalSinceNow: -LoopCoreConstants.dosingDecisionHistoricalGlucoseInterval)
                self.deviceManager.glucoseStore.getGlucoseSamples(start: min(historicalGlucoseStartDate, glucose.startDate), end: nil) { (result) in
                    var sample: StoredGlucoseSample?
                    switch result {
                    case .failure(let error):
                        self.log.error("Failure getting glucose samples: %{public}@", String(describing: error))
                        sample = nil
                    case .success(let samples):
                        sample = samples.last
                        historicalGlucose = samples.filter { $0.startDate >= historicalGlucoseStartDate }.map { HistoricalGlucoseValue(startDate: $0.startDate, quantity: $0.quantity) }
                    }
                    context.glucose = sample?.quantity
                    context.glucoseDate = sample?.startDate
                    context.glucoseIsDisplayOnly = sample?.isDisplayOnly
                    context.glucoseWasUserEntered = sample?.wasUserEntered
                    context.glucoseSyncIdentifier = sample?.syncIdentifier
                    updateGroup.leave()
                }
            }

            var insulinOnBoard: InsulinValue?
            updateGroup.enter()
            self.deviceManager.doseStore.insulinOnBoard(at: Date()) { (result) in
                switch result {
                case .success(let iobValue):
                    context.iob = iobValue.value
                    insulinOnBoard = iobValue
                case .failure:
                    context.iob = nil
                }
                updateGroup.leave()
            }

            _ = updateGroup.wait(timeout: .distantFuture)

            dosingDecision.historicalGlucose = historicalGlucose
            dosingDecision.insulinOnBoard = insulinOnBoard

            if let basalDeliveryState = basalDeliveryState,
                let basalSchedule = manager.basalRateScheduleApplyingOverrideHistory,
                let netBasal = basalDeliveryState.getNetBasal(basalSchedule: basalSchedule, settings: manager.settings)
            {
                context.lastNetTempBasalDose = netBasal.rate
            }

            if let predictedGlucose = state.predictedGlucoseIncludingPendingInsulin {
                // Drop the first element in predictedGlucose because it is the current glucose
                let filteredPredictedGlucose = predictedGlucose.dropFirst()
                if filteredPredictedGlucose.count > 0 {
                    context.predictedGlucose = WatchPredictedGlucose(values: Array(filteredPredictedGlucose))
                }
            }

            dosingDecision.predictedGlucose = state.predictedGlucoseIncludingPendingInsulin ?? state.predictedGlucose

            var preMealOverride = settings.preMealOverride
            if preMealOverride?.hasFinished() == true {
                preMealOverride = nil
            }

            var scheduleOverride = settings.scheduleOverride
            if scheduleOverride?.hasFinished() == true {
                scheduleOverride = nil
            }

            dosingDecision.scheduleOverride = scheduleOverride

            if scheduleOverride != nil || preMealOverride != nil {
                dosingDecision.glucoseTargetRangeSchedule = settings.effectiveGlucoseTargetRangeSchedule(presumingMealEntry: potentialCarbEntry != nil)
            } else {
                dosingDecision.glucoseTargetRangeSchedule = settings.glucoseTargetRangeSchedule
            }

            // Remove any expired context dosing decisions and add new
            self.contextDosingDecisions = self.contextDosingDecisions.filter { (date, _) in date.timeIntervalSinceNow > self.contextDosingDecisionExpirationDuration }
            self.contextDosingDecisions[context.creationDate] = dosingDecision

            completion(context)
        }
    }

    private func addCarbEntryAndBolusFromWatchMessage(_ message: [String: Any]) {
        guard let bolus = SetBolusUserInfo(rawValue: message as SetBolusUserInfo.RawValue) else {
            log.error("Could not enact bolus from from unknown message: %{public}@", String(describing: message))
            return
        }

        // Prevent any delayed messages from enacting.
        guard bolus.startDate.timeIntervalSinceNow > -30 else {
            log.error("Could not enact expired bolus from watch: %{public}@", String(describing: message))
            return
        }

        var dosingDecision: BolusDosingDecision
        if let contextDate = bolus.contextDate, let contextDosingDecision = contextDosingDecisions[contextDate] {
            dosingDecision = contextDosingDecision
        } else {
            dosingDecision = BolusDosingDecision(for: .watchBolus)  // The user saved without waiting for recommendation (no bolus)
        }

        func enactBolus() {
            dosingDecision.manualBolusRequested = bolus.value
            deviceManager.loopManager.storeManualBolusDosingDecision(dosingDecision, withDate: bolus.startDate)

            guard bolus.value > 0 else {
                // Ensure active carbs is updated in the absence of a bolus
                sendWatchContextIfNeeded()
                return
            }

            deviceManager.enactBolus(units: bolus.value, activationType: bolus.activationType) { (error) in
                if error == nil {
                    self.deviceManager.analyticsServicesManager.didBolus(source: "Watch", units: bolus.value)
                }

                // When we've successfully started the bolus, send a new context with our new prediction
                self.sendWatchContextIfNeeded()

                self.deviceManager.loopManager.updateRemoteRecommendation()
            }
        }

        if let carbEntry = bolus.carbEntry {
            deviceManager.loopManager.addCarbEntry(carbEntry) { (result) in
                switch result {
                case .success(let storedCarbEntry):
                    dosingDecision.carbEntry = storedCarbEntry
                    self.deviceManager.analyticsServicesManager.didAddCarbs(source: "Watch", amount: storedCarbEntry.quantity.doubleValue(for: .gram()))
                    enactBolus()
                case .failure(let error):
                    self.log.error("%{public}@", String(describing: error))
                }
            }
        } else {
            dosingDecision.carbEntry = nil
            enactBolus()
        }
    }
}


extension WatchDataManager: WCSessionDelegate {
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        switch message["name"] as? String {
        case PotentialCarbEntryUserInfo.name?:
            if let potentialCarbEntry = PotentialCarbEntryUserInfo(rawValue: message)?.carbEntry {
                self.createWatchContext(recommendingBolusFor: potentialCarbEntry) { (context) in
                    replyHandler(context.rawValue)
                }
            } else {
                log.error("Could not recommend bolus from from unknown message: %{public}@", String(describing: message))
                replyHandler([:])
            }
        case SetBolusUserInfo.name?:
            // Add carbs if applicable; start the bolus and reply when it's successfully requested
            addCarbEntryAndBolusFromWatchMessage(message)

            // Reply immediately
            replyHandler([:])
        case LoopSettingsUserInfo.name?:
            if let watchSettings = LoopSettingsUserInfo(rawValue: message)?.settings {
                // So far we only support watch changes of temporary schedule overrides
                var loopSettings = deviceManager.loopManager.settings
                loopSettings.preMealOverride = watchSettings.preMealOverride
                loopSettings.scheduleOverride = watchSettings.scheduleOverride

                // Prevent re-sending these updated settings back to the watch
                lastSentSettings = loopSettings
                deviceManager.loopManager.mutateSettings { settings in
                    settings = loopSettings
                }
            }

            // Since target range affects recommended bolus, send back a new one
            createWatchContext { (context) in
                replyHandler(context.rawValue)
            }
        case CarbBackfillRequestUserInfo.name?:
            if let userInfo = CarbBackfillRequestUserInfo(rawValue: message) {
                deviceManager.carbStore.getSyncCarbObjects(start: userInfo.startDate) { (result) in
                    switch result {
                    case .failure(let error):
                        self.log.error("%{public}@", String(describing: error))
                        replyHandler([:])
                    case .success(let objects):
                        replyHandler(WatchHistoricalCarbs(objects: objects).rawValue)
                    }
                }
            } else {
                replyHandler([:])
            }
        case GlucoseBackfillRequestUserInfo.name?:
            if let userInfo = GlucoseBackfillRequestUserInfo(rawValue: message) {
                deviceManager.glucoseStore.getSyncGlucoseSamples(start: userInfo.startDate.addingTimeInterval(1)) { (result) in
                    switch result {
                    case .failure(let error):
                        self.log.error("Failure getting sync glucose objects: %{public}@", String(describing: error))
                        replyHandler([:])
                    case .success(let samples):
                        replyHandler(WatchHistoricalGlucose(samples: samples).rawValue)
                    }
                }
            } else {
                replyHandler([:])
            }
        case WatchContextRequestUserInfo.name?:
            self.createWatchContext { (context) in
                // Send back the updated prediction and recommended bolus
                replyHandler(context.rawValue)
            }
        case PodLoanRequestUserInfo.name?:
            handlePodLoanRequest(replyHandler: replyHandler)
        case PodHandbackUserInfo.name?:
            handlePodHandback(message)
            replyHandler([:])
        default:
            replyHandler([:])
        }
    }

    /// The watch is asking to borrow the pod for a workout. Reply with the pod
    /// identity it needs to take over (read from the pump manager's rawState —
    /// see PodLoanIdentity), and pause automatic dosing for the loan. If there's
    /// no active pod, the reply is a denial and nothing is changed.
    private func handlePodLoanRequest(replyHandler: @escaping ([String: Any]) -> Void) {
        let grant = PodLoanIdentity.grant(fromPumpManagerRawState: deviceManager.pumpManager?.rawState,
                                          insulinTypeRaw: deviceManager.loopManager.pumpInsulinType?.rawValue)

        if grant.granted {
            // Mark the loan window. The phone UI reports only its own truth
            // ("Pod Not Connected" once contact goes stale, or the Bluetooth
            // state) — never a claim about the watch; the grant alone doesn't
            // prove the watch took over.
            deviceManager.podLoanedToWatch = true
            // Capture the pre-loan dosing state and pause automatic dosing — but
            // ONLY on the first grant of a loan. A repeat borrow (e.g. the watch
            // retried after a failed takeover) must NOT re-capture: by then dosing
            // is already paused, so re-capturing would save "off" and hand-back
            // would restore to "off", silently leaving the loop open. Guarding on
            // nil makes the capture idempotent for the life of the loan.
            if dosingEnabledBeforeWatchLoan == nil {
                dosingEnabledBeforeWatchLoan = deviceManager.loopManager.settings.dosingEnabled
                deviceManager.loopManager.mutateSettings { $0.dosingEnabled = false }
                log.default("Pod loan granted to watch; automatic dosing paused")
            } else {
                log.default("Pod loan re-granted to watch (loan already active; dosing state preserved)")
            }
        } else {
            log.default("Pod loan denied: %{public}@", grant.denialReason ?? "unknown")
        }

        replyHandler(grant.rawValue)
    }

    /// The watch has handed the pod back. Record what it did (Phase 1: display;
    /// Phase 2: reconcile), restore automatic dosing to its pre-loan state, and
    /// re-establish the phone's own pod session so the pump data is current again.
    private func handlePodHandback(_ message: [String: Any]) {
        guard let handback = PodHandbackUserInfo(rawValue: message) else {
            log.error("Could not decode pod hand-back message: %{public}@", String(describing: message))
            return
        }

        log.default("Pod handed back from watch: %{public}@", handback.summary)
        lastWatchLoanSummary = handback.summary
        lastWatchLoanJournalData = handback.journalData
        deviceManager.podLoanedToWatch = false   // phone is back in control

        if let priorDosing = dosingEnabledBeforeWatchLoan {
            deviceManager.loopManager.mutateSettings { $0.dosingEnabled = priorDosing }
            dosingEnabledBeforeWatchLoan = nil
        }

        // Phase 2 (DIST-3): reconcile the watch's delivery into IOB — guarded against
        // duplicate hand-back messages (a retry after a lost ack resends the SAME
        // journal bytes; the watch snapshots the payload to keep them byte-stable).
        // The DoseStore does NOT dedupe manually-entered doses, so this hash is the
        // only defense against double-entering.
        let journalHash = SHA256.hash(data: handback.journalData).map { String(format: "%02x", $0) }.joined()
        if journalHash == UserDefaults.appGroup?.lastReconciledWatchLoanJournalHash {
            log.default("Duplicate pod hand-back (journal %{public}@… already reconciled) — state restored, dose entry skipped", String(journalHash.prefix(8)))
        } else {
            reconcileWatchLoan(journalData: handback.journalData, handedBackAt: handback.handedBackAt, journalHash: journalHash)
        }

        // Reconnect to the pod and refresh status now that we own it again.
        deviceManager.pumpManager?.ensureCurrentPumpData(completion: { _ in })
    }

    /// DIST-3 Phase B: enter what the watch delivered into the phone's dose
    /// accounting so IOB is correct for the hours after a loan.
    ///
    /// Design (see WATCH_DISTRIBUTION_SAFETY.md DIST-3): journal bolus events are
    /// PRIMARY — entered at their real timestamps so insulin decay is computed
    /// correctly. The pod's cumulative-delivered odometer then AUDITS the journal:
    /// any unexplained positive remainder (odometer delta − journal boluses −
    /// expected scheduled basal net of suspends) is entered timed-late at hand-back,
    /// which overstates IOB → Loop doses less → errs safe. Negative remainders
    /// (suspends/low temps below schedule) are logged, not entered (Phase C).
    private func reconcileWatchLoan(journalData: Data, handedBackAt: Date, journalHash: String) {
        guard let journal = WatchLoanJournal(data: journalData) else {
            // Undecodable journal: keep Phase-1 behavior (summary already stored for
            // display; user can record manually via Non-Pump Insulin). Do NOT persist
            // the hash — a later valid resend must still be processable.
            log.error("Watch loan journal could not be decoded (%{public}d bytes) — no doses entered", journalData.count)
            return
        }

        var doses: [(startDate: Date, units: Double)] = []

        // (a) Journal boluses at their real timestamps. Defense-in-depth: the watch
        // caps any single bolus at 1.0 U, so reject larger events (corrupt journal)
        // rather than inject phantom IOB.
        for event in journal.events {
            if case .bolus(let units) = event.kind {
                guard units > 0, units <= 1.05 else {
                    log.error("Watch loan journal bolus event of %{public}.2f U exceeds the watch cap — rejected", units)
                    continue
                }
                doses.append((startDate: event.date, units: units))
            }
        }

        // (b) Odometer audit. Skipped when the odometer baseline is missing.
        if let podDelta = journal.podDeliveredDelta {
            let expectedBasal = expectedScheduledBasal(from: journal.startedAt, to: handedBackAt, suspendWindows: journal.suspendWindows(endingAt: handedBackAt))
            let remainder = podDelta - journal.totalBolusUnits - expectedBasal
            log.default("Watch loan audit: podDelta=%{public}.2f boluses=%{public}.2f expectedBasal=%{public}.2f remainder=%{public}.2f", podDelta, journal.totalBolusUnits, expectedBasal, remainder)

            let remainderThreshold = 0.05   // one pod pulse; filters quantization/staleness noise
            let remainderSanityCap = 5.0    // implausible for one loan — odometer corruption guard
            if remainder >= remainderThreshold && remainder <= remainderSanityCap {
                // Timed LATE (at hand-back): zero decay elapsed → IOB maximally
                // overstated for this insulin → Loop doses less → safe direction.
                doses.append((startDate: handedBackAt, units: remainder))
            } else if remainder > remainderSanityCap {
                log.error("Watch loan audit remainder %{public}.2f U exceeds sanity cap — NOT entered; verify manually", remainder)
            }
        } else {
            log.default("Watch loan audit skipped: no odometer baseline in journal")
        }

        // (c) SHADOW — symmetric reconciliation, computed and logged but NOT
        // entered (docs/WATCH_INSULIN_MODEL.md §5). Reconstructs the journal's
        // off-schedule basal timeline and reports the signed net vs schedule —
        // including the NEGATIVE net from suspends/low temps that the active
        // path deliberately drops. Real-pod sessions validate these shadow
        // figures before symmetric write-back is allowed to touch dosing IOB.
        let shadowSegments = journal.offScheduleSegments(until: handedBackAt)
        if !shadowSegments.isEmpty,
           let schedule = deviceManager.loopManager.basalRateScheduleApplyingOverrideHistory {
            var shadowNet = 0.0
            for segment in shadowSegments {
                let deliveredUnits = segment.actualRate * segment.end.timeIntervalSince(segment.start) / 3600.0
                let scheduledUnits = schedule.truncatingBetween(start: segment.start, end: segment.end)
                    .reduce(0) { $0 + $1.value * $1.endDate.timeIntervalSince($1.startDate) / 3600.0 }
                shadowNet += deliveredUnits - scheduledUnits
            }
            log.default("Watch loan shadow (symmetric): %{public}d basal segment(s), net %{public}.2f U vs schedule — not entered (shadow mode)", shadowSegments.count, shadowNet)
        }

        guard !doses.isEmpty else {
            // Nothing to enter (e.g. basal-only loan) — mark reconciled so a duplicate
            // hand-back doesn't re-run the audit.
            UserDefaults.appGroup?.lastReconciledWatchLoanJournalHash = journalHash
            return
        }

        // Write doses FIRST; persist the idempotency hash only on confirmed success.
        // A crash in between means a retry double-enters (IOB overstated → safe);
        // the reverse order could silently LOSE doses (IOB understated → hypo risk).
        let insulinType = deviceManager.loopManager.pumpInsulinType
        deviceManager.loopManager.addManuallyEnteredDoses(doses, insulinType: insulinType) { [weak self] error in
            if let error = error {
                self?.log.error("Watch loan reconciliation dose entry failed: %{public}@ — hash not persisted; a resend will retry", String(describing: error))
            } else {
                UserDefaults.appGroup?.lastReconciledWatchLoanJournalHash = journalHash
                self?.log.default("Watch loan reconciled: %{public}d dose(s) entered", doses.count)
            }
        }
    }

    /// Scheduled basal (U) the pod was expected to deliver over the loan window,
    /// net of the journal's suspend windows (subtracting suspended time RAISES the
    /// audit remainder → overstates IOB → errs safe).
    private func expectedScheduledBasal(from start: Date, to end: Date, suspendWindows: [(start: Date, end: Date)]) -> Double {
        guard end > start,
              let schedule = deviceManager.loopManager.basalRateScheduleApplyingOverrideHistory else {
            return 0
        }

        var total: Double = 0
        for item in schedule.truncatingBetween(start: start, end: end) {
            total += item.value * item.endDate.timeIntervalSince(item.startDate) / 3600.0
            // Subtract the suspended portion of this schedule segment.
            for window in suspendWindows {
                let overlapStart = max(window.start, item.startDate)
                let overlapEnd = min(window.end, item.endDate)
                if overlapEnd > overlapStart {
                    total -= item.value * overlapEnd.timeIntervalSince(overlapStart) / 3600.0
                }
            }
        }
        return max(0, total)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        assertionFailure("We currently don't expect any userInfo messages transferred from the watch side")
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        switch activationState {
        case .activated:
            if let error = error {
                log.error("%{public}@", String(describing: error))
            } else {
                sendSettingsIfNeeded()
                sendWatchContextIfNeeded()
                sendSupportedBolusVolumesIfNeeded()
            }
        case .inactive, .notActivated:
            break
        @unknown default:
            break
        }
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if let error = error {
            log.error("%{public}@", String(describing: error))

            // This might be useless, as userInfoTransfer.userInfo seems to be nil when error is non-nil.
            switch userInfoTransfer.userInfo["name"] as? String {
            case nil:
                lastSentSettings = nil
                sendSettingsIfNeeded()
                lastSentBolusVolumes = nil
                sendSupportedBolusVolumesIfNeeded()
            case LoopSettingsUserInfo.name:
                lastSentSettings = nil
                sendSettingsIfNeeded()
            case SupportedBolusVolumesUserInfo.name:
                lastSentBolusVolumes = nil
                sendSupportedBolusVolumesIfNeeded()
            default:
                break
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        // Nothing to do here
    }

    func sessionDidDeactivate(_ session: WCSession) {
        lastSentSettings = nil
        watchSession = WCSession.default
        watchSession?.delegate = self
        watchSession?.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        sendSettingsIfNeeded()
        sendSupportedBolusVolumesIfNeeded()
    }
}


extension WatchDataManager {
    override var debugDescription: String {
        var items = [
            "## WatchDataManager",
            "lastSentSettings: \(String(describing: lastSentSettings))",
            "lastComplicationContext: \(String(describing: lastComplicationContext))",
            "lastBedtimeQuery: \(String(describing: lastBedtimeQuery))",
            "bedtime: \(String(describing: bedtime))",
            "complicationUserInfoTransferInterval: \(round(watchSession?.complicationUserInfoTransferInterval(bedtime: bedtime).minutes ?? 0)) min"
        ]

        if let session = watchSession {
            items.append(String(reflecting: session))
        } else {
            items.append(contentsOf: [
                "watchSession: nil"
            ])
        }

        return items.joined(separator: "\n")
    }

}

extension WCSession {
    open override var debugDescription: String {
        return [
            "\(self)",
            "* hasContentPending: \(hasContentPending)",
            "* isComplicationEnabled: \(isComplicationEnabled)",
            "* isPaired: \(isPaired)",
            "* isReachable: \(isReachable)",
            "* isWatchAppInstalled: \(isWatchAppInstalled)",
            "* outstandingFileTransfers: \(outstandingFileTransfers)",
            "* outstandingUserInfoTransfers: \(outstandingUserInfoTransfers)",
            "* receivedApplicationContext: \(receivedApplicationContext)",
            "* remainingComplicationUserInfoTransfers: \(remainingComplicationUserInfoTransfers)",
            "* watchDirectoryURL: \(watchDirectoryURL?.absoluteString ?? "nil")",
        ].joined(separator: "\n")
    }
    
    fileprivate func complicationUserInfoTransferInterval(bedtime: Date?) -> TimeInterval {
        let now = Date()
        let timeUntilRefresh: TimeInterval

        if let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0), matchingPolicy: .nextTime) {
            // we can have a more frequent refresh rate if we only refresh when it's likely the user is awake (based on HealthKit sleep data)
            if let nextBedtime = bedtime {
                let timeUntilBedtime = nextBedtime.timeIntervalSince(now)
                // if bedtime is before the current time or more than 24 hours away, use midnight instead
                timeUntilRefresh = (0..<TimeInterval(hours: 24)).contains(timeUntilBedtime) ? timeUntilBedtime : midnight.timeIntervalSince(now)
            }
            // otherwise, since (in most cases) the complications allowance refreshes at midnight, base it on the time remaining until midnight
            else {
                timeUntilRefresh = midnight.timeIntervalSince(now)
            }
        } else {
            timeUntilRefresh = .hours(24)
        }

        return timeUntilRefresh / Double(remainingComplicationUserInfoTransfers + 1)
    }
}

// MARK: - Watch loan journal mirror (decode-only)
//
// The phone deliberately does NOT link OmniBLECore (see PodHandbackUserInfo), so the
// journal JSON is decoded with this minimal mirror of OmniBLECore.PodLoanJournal /
// PodLoanEvent. Case names and associated-value labels MUST match the originals
// exactly — synthesized Codable derives its JSON keys from them (e.g.
// {"kind":{"bolus":{"units":0.5}}}). If the watch ever adds a new event kind, decoding
// here fails whole → reconciliation falls back to Phase-1 display-only (by design).
// Lives in this file rather than its own to avoid a hand-edited pbxproj entry.

private struct WatchLoanEvent: Decodable {
    enum Kind: Decodable {
        case tookOver
        case bolus(units: Double)
        case tempBasal(rate: Double, duration: TimeInterval)
        case suspend
        case resume
        case cancelTempBasal
        case handedBack
    }

    let id: UUID
    let date: Date
    let kind: Kind
}

private struct WatchLoanJournal: Decodable {
    let startedAt: Date
    let deliveredAtStart: Double?
    let deliveredLatest: Double?
    let events: [WatchLoanEvent]

    init?(data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(WatchLoanJournal.self, from: data) else { return nil }
        self = decoded
    }

    var totalBolusUnits: Double {
        events.reduce(0) { acc, event in
            if case .bolus(let units) = event.kind { return acc + units }
            return acc
        }
    }

    /// The pod's own cumulative-delivered delta over the loan (basal + boluses), or
    /// nil when either odometer reading is missing.
    var podDeliveredDelta: Double? {
        guard let start = deliveredAtStart, let latest = deliveredLatest else { return nil }
        return max(0, latest - start)
    }

    /// Contiguous suspend windows, mirroring the producer's semantics (only a resume
    /// closes a window; an open window closes at `end`). A temp basal after a suspend
    /// does NOT close the window here — that under-credits expected basal, which
    /// RAISES the audit remainder → overstates IOB → errs safe.
    func suspendWindows(endingAt end: Date) -> [(start: Date, end: Date)] {
        var windows: [(Date, Date)] = []
        var openStart: Date?
        for event in events {
            switch event.kind {
            case .suspend:
                if openStart == nil { openStart = event.date }
            case .resume:
                if let start = openStart { windows.append((start, event.date)); openStart = nil }
            default:
                continue
            }
        }
        if let start = openStart { windows.append((start, end)) }
        return windows.map { (start: $0.0, end: $0.1) }
    }

    /// The spans when the watch commanded delivery AWAY from the schedule (a temp
    /// basal until superseded/suspended/expired, or a suspend until resumed) —
    /// the raw material for symmetric reconciliation. Mirrors the walk in
    /// OmniBLECore's PodLoanJournal.offScheduleSegments; time on-schedule is
    /// omitted (it nets to zero).
    func offScheduleSegments(until end: Date) -> [(start: Date, end: Date, actualRate: Double)] {
        enum DeliveryState {
            case following
            case temp(rate: Double, since: Date, expiry: Date)
            case suspended(since: Date)
        }

        var segments: [(start: Date, end: Date, actualRate: Double)] = []
        var state = DeliveryState.following

        func close(at date: Date) {
            switch state {
            case .following:
                break
            case .temp(let rate, let since, let expiry):
                let segmentEnd = min(date, expiry)
                if segmentEnd > since {
                    segments.append((start: since, end: segmentEnd, actualRate: rate))
                }
            case .suspended(let since):
                if date > since {
                    segments.append((start: since, end: date, actualRate: 0))
                }
            }
        }

        for event in events.sorted(by: { $0.date < $1.date }) where event.date < end {
            switch event.kind {
            case .tempBasal(let rate, let duration):
                close(at: event.date)
                state = .temp(rate: rate, since: event.date, expiry: event.date.addingTimeInterval(duration))
            case .suspend:
                close(at: event.date)
                state = .suspended(since: event.date)
            case .resume, .cancelTempBasal, .handedBack:
                close(at: event.date)
                state = .following
            case .bolus, .tookOver:
                break
            }
        }
        close(at: end)
        return segments
    }
}
