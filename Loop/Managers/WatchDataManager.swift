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
import LoopAlgorithm
import LoopKit
import LoopCore


enum WatchDataManagerError: Error {
    case decodingError
    case expiredBolusRecommendation
}

@MainActor
final class WatchDataManager: NSObject {
    private static var lastOnboardingKey = ""   // [onboarding-gate] dedupe


    unowned let deviceManager: DeviceDataManager   // PODLOAN: read by the wiring extension
    unowned let settingsManager: SettingsManager   // PODLOAN: read by the wiring extension
    unowned let loopDataManager: LoopDataManager   // PODLOAN: read by the wiring extension
    private unowned let carbStore: CarbStore
    private unowned let glucoseStore: GlucoseStore
    private unowned let analyticsServicesManager: AnalyticsServicesManager?
    unowned let temporaryPresetsManager: TemporaryPresetsManager   // PODLOAN: read by the wiring extension
    private unowned let alertManager: AlertManager


    // MARK: - Loan support


    /// The reclaim ladder runs on wall-clock rungs; hold the app awake across them so a
    /// backgrounded phone still finishes taking the pod back.
    private var reclaimBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    func beginReclaimBackgroundTask() {
        endReclaimBackgroundTask()
        reclaimBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PodLoanReclaim") { [weak self] in
            // Expiration: iOS is done waiting — release the hold or be killed. The wall-clock
            // rungs then fire whatever is overdue at the next resume.
            self?.endReclaimBackgroundTask()
        }
    }

    func endReclaimBackgroundTask() {
        if reclaimBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(reclaimBackgroundTask)
            reclaimBackgroundTask = .invalid
        }
    }

    /// When the watch was last heard from — the loan's liveness signal.
    /// appInstalled=false glitch detector state (see trackAppInstalledGlitch).
    private var appInstalledGlitchWork: DispatchWorkItem?
    private var appInstalledGlitchNotified = false

    let lockedLastWatchContact = Locked<Date?>(nil)

    // MARK: - Loan protocol v2 (M5)

    /// One-time wiring of the alert manager's Loop-Failure suppression gate to the loan
    /// state. Lazy-adjacent to the controller so neither can exist without the other.
    func wireLoopFailureSuppressionGate() {
        deviceManager.alertManager?.loopNotRunningSuppressionGate = { [weak self] in
            self?.podLoanController.isLoanedOutForUI ?? false
        }
        Self.loanLadderSweep = { [weak self] in
            self?.deviceManager.alertManager?.sweepLoopNotRunningNotificationsDuringLoan()
        }
    }

    /// Called from the link-census tick (its own queue) — the sweep itself gates on loan state.
    /// nonisolated(unsafe): written once at wiring time on main, read from the census queue;
    /// the closure hops back through Task-per-call inside the sweep itself.
    nonisolated(unsafe) private static var loanLadderSweep: (() -> Void)?

    // PODLOAN: the controller's dependency wiring lives in PodLoanPhoneController+Wiring.swift.
    private(set) lazy var podLoanController: PodLoanPhoneController = makePodLoanController()

    /// Where inbound pod-loan messages go. Installed by the loan controller when Sport Mode is
    /// wired up, and nil in a stock build — which is what keeps this feature's traffic from
    /// being a hard dependency of the WatchConnectivity plumbing. Nil with a message arriving
    /// is a real fault (the watch believes a loan exists and the phone has no owner for it),
    /// so it logs rather than being silently tolerated.
    var podLoanMessageReceiver: ((LoanMessage) -> Void)?

    init(
        deviceManager: DeviceDataManager,
        settingsManager: SettingsManager,
        loopDataManager: LoopDataManager,
        carbStore: CarbStore,
        glucoseStore: GlucoseStore,
        analyticsServicesManager: AnalyticsServicesManager?,
        temporaryPresetsManager: TemporaryPresetsManager,
        alertManager: AlertManager,
        healthStore: HKHealthStore
    ) {
        self.deviceManager = deviceManager
        self.settingsManager = settingsManager
        self.loopDataManager = loopDataManager
        self.carbStore = carbStore
        self.glucoseStore = glucoseStore
        self.analyticsServicesManager = analyticsServicesManager
        self.temporaryPresetsManager = temporaryPresetsManager
        self.alertManager = alertManager
        self.sleepStore = SleepStore(healthStore: healthStore)
        self.lastBedtimeQuery = UserDefaults.appGroup?.lastBedtimeQuery ?? .distantPast
        self.bedtime = UserDefaults.appGroup?.bedtime

        super.init()

        NotificationCenter.default.addObserver(self, selector: #selector(updateWatch(_:)), name: .LoopDataUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sendSupportedBolusVolumesIfNeeded), name: .PumpManagerChanged, object: deviceManager)

        wireLoopFailureSuppressionGate()
        watchSession?.delegate = self
        watchSession?.activate()

        // Constructed eagerly so a relaunch mid-loan restores the persisted state machine —
        // dosing stays paused, reminders re-arm — before any message arrives.
        _ = podLoanController
        startLinkCensus()
    }

    let log = DiagnosticLog(category: "WatchDataManager")

    var watchSession: WCSession? = {
        if WCSession.isSupported() {
            return WCSession.default
        } else {
            return nil
        }
    }()

    private var lastSentUserInfo: LoopSettingsUserInfo?
    private var lastSentBolusVolumes: [Double]?

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
            let rawUpdateContext = notification.userInfo?[LoopDataManager.LoopUpdateContextKey] as? LoopUpdateContext.RawValue,
            let updateContext = LoopUpdateContext(rawValue: rawUpdateContext)
        else {
            return
        }

        // R40: every loop update pings the dormant-grant refresher — all gating (owner
        // state, watch capability, settings fingerprint, 30-min floor) lives inside it,
        // so this is one enqueued no-op almost always.
        podLoanController.considerDormantRefresh()
        // The watch's hold on the pod lapses by itself when its renewals stop — same pulse.
        podLoanController.considerHoldLapse()

        // Any update context should trigger a watch update
        sendWatchContextIfNeeded()

        if case .preferences = updateContext {
            sendSettingsIfNeeded()
        }
    }

    private var lastComplicationContext: WatchContext?

    private let minTrendDrift: Double = 20
    private lazy var minTrendUnit = LoopUnit.milligramsPerDeciliter

    private func sendSettingsIfNeeded() {
        let userInfo = LoopSettingsUserInfo(
            loopSettings: settingsManager.loopSettings,
            scheduleOverride: temporaryPresetsManager.scheduleOverride)

        guard let session = watchSession, session.isPaired, session.isWatchAppInstalled else {
            return
        }

        guard case .activated = session.activationState else {
            session.activate()
            return
        }

        guard userInfo != lastSentUserInfo else {
            return
        }

        lastSentUserInfo = userInfo

        // clear any old pending settings transfers
        for transfer in session.outstandingUserInfoTransfers {
            if (transfer.userInfo["name"] as? String) == LoopSettingsUserInfo.name {
                log.default("Cancelling old setings transfer")
                transfer.cancel()
            }
        }

        let rawUserInfo = userInfo.rawValue
        //log.default("Transferring LoopSettingsUserInfo: %{public}@", rawUserInfo)
        session.transferUserInfo(rawUserInfo)
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
            return
        }

        for xfer in session.outstandingUserInfoTransfers {
            if (xfer.userInfo["name"] as? String) == SupportedBolusVolumesUserInfo.name {
                // We have an outstanding SupportedBolusVolumesUserInfo xfer in progress
                return
            }
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

        Task {
            let context = await createWatchContext()
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

    @MainActor
    private func createWatchContext(recommendingBolusFor potentialCarbEntry: NewCarbEntry? = nil) async -> WatchContext {
        var dosingDecision = BolusDosingDecision(for: .watchBolus)

        let glucose = loopDataManager.latestGlucose
        let reservoir = loopDataManager.lastReservoirValue
        let basalDeliveryState = deviceManager.pumpManager?.status.basalDeliveryState

        let (_, algoOutput) = loopDataManager.displayState.asTuple

        let carbsOnBoard = loopDataManager.activeCarbs

        let context = WatchContext(glucose: glucose, glucoseUnit: self.deviceManager.displayGlucosePreference.unit)
        context.reservoir = reservoir?.unitVolume
        context.loopLastRunDate = loopDataManager.lastLoopCompleted
        context.cob = carbsOnBoard?.quantity.doubleValue(for: .gram)

        if let glucoseDisplay = self.deviceManager.glucoseDisplay(for: glucose) {
            context.glucoseTrend = glucoseDisplay.trendType
            context.glucoseTrendRate = glucoseDisplay.trendRate
        }

        dosingDecision.carbsOnBoard = carbsOnBoard

        context.cgmManagerState = self.deviceManager.cgmManager?.rawValue

        let settings = self.settingsManager.loopSettings

        context.isClosedLoop = settings.dosingEnabled
        context.isOnboardingCompleted = deviceManager.cgmManager?.isOnboarded == true && deviceManager.pumpManager?.isOnboarded == true
        // Bench 2026-09-18: the watch kept showing "Please complete onboarding" and neither log
        // said what this phone had told it. Logged on change only; pairs with the watch's
        // "[onboarding-gate]" lines.
        let onboardingKey = "\(context.isOnboardingCompleted == true)|\(deviceManager.cgmManager != nil)|\(deviceManager.pumpManager?.isOnboarded == true)"
        if onboardingKey != Self.lastOnboardingKey {
            Self.lastOnboardingKey = onboardingKey
            PhoneLog.event("link", "context to watch: onboardingCompleted=\(context.isOnboardingCompleted == true) — cgmManager \(deviceManager.cgmManager == nil ? "NIL" : "present"), pump onboarded=\(deviceManager.pumpManager?.isOnboarded == true) [onboarding-gate]")
        }
        context.deviceIssue = deviceManager.cgmManager == nil || deviceManager.cgmManager?.isInoperable == true || deviceManager.cgmManager?.inSignalLoss == true || deviceManager.pumpManager == nil || deviceManager.pumpManager?.isInoperable == true || deviceManager.pumpManager?.inSignalLoss == true || deviceManager.hasBluetoothIssue

        context.potentialCarbEntry = potentialCarbEntry

        if let recommendedBolus = try? await loopDataManager.recommendManualBolus(
            manualGlucoseSample: nil,
            potentialCarbEntry: potentialCarbEntry,
            originalCarbEntry: nil
        ) {
            context.recommendedBolusDose = recommendedBolus.amount
            dosingDecision.manualBolusRecommendation = ManualBolusRecommendationWithDate(
                recommendation: recommendedBolus,
                date: Date())
            log.debug("watch bolus recommended: %{public}@ (with carb entry: %{public}@", String(describing: recommendedBolus.amount), String(describing: potentialCarbEntry))
        }

        var historicalGlucose: [HistoricalGlucoseValue]?

        if let glucose = glucose {
            var sample: StoredGlucoseSample?

            let historicalGlucoseStartDate = Date(timeIntervalSinceNow: -LoopCoreConstants.dosingDecisionHistoricalGlucoseInterval)
            if let input = loopDataManager.displayState.input {
                let start = min(historicalGlucoseStartDate, glucose.startDate)
                let samples = input.glucoseHistory.filterDateRange(start, nil)
                sample = samples.last
                historicalGlucose = samples.filter { $0.startDate >= historicalGlucoseStartDate }.map { HistoricalGlucoseValue(startDate: $0.startDate, quantity: $0.quantity) }
            }
            context.glucose = sample?.quantity
            context.glucoseDate = sample?.startDate
            context.glucoseIsDisplayOnly = sample?.isDisplayOnly
            context.glucoseWasUserEntered = sample?.wasUserEntered
            context.glucoseSyncIdentifier = sample?.syncIdentifier
        }

        context.iob = loopDataManager.activeInsulin?.value

        if deviceManager.isPumpInoperable {
            context.insulinDeliveryState = .noDelivery
        } else if deviceManager.isSuspended {
            context.insulinDeliveryState = .suspended
        } else if let automatedTreatmentState = loopDataManager.automatedTreatmentState {
            switch automatedTreatmentState {
            case .neutralNoOverride:
                context.insulinDeliveryState = .neutralNoOverride
            case .neutralOverride:
                context.insulinDeliveryState = .neutralOverride
            case .increasedInsulin:
                context.insulinDeliveryState = .increasedInsulin
            case .decreasedInsulin:
                context.insulinDeliveryState = .decreasedInsulin
            case .minimumDelivery:
                context.insulinDeliveryState = .minimumDelivery
            }
        }

        context.lastManualBolus = loopDataManager.lastManualBolus

        dosingDecision.historicalGlucose = historicalGlucose
        dosingDecision.insulinOnBoard = loopDataManager.activeInsulin

        if let basalDeliveryState = basalDeliveryState,
           let basalSchedule = self.temporaryPresetsManager.basalRateScheduleApplyingOverrideHistory,
           let netBasal = basalDeliveryState.getNetBasal(basalSchedule: basalSchedule, maximumBasalRatePerHour: self.settingsManager.settings.maximumBasalRatePerHour)
        {
            context.lastNetTempBasalDose = netBasal.rate
        }

        if let predictedGlucose = algoOutput?.predictedGlucose {
            // Drop the first element in predictedGlucose because it is the current glucose
            let filteredPredictedGlucose = predictedGlucose.dropFirst()
            if filteredPredictedGlucose.count > 0 {
                context.predictedGlucose = WatchPredictedGlucose(values: Array(filteredPredictedGlucose))
            }
        }

        dosingDecision.predictedGlucose = algoOutput?.predictedGlucose

        var preMealOverride = self.temporaryPresetsManager.preMealOverride
        if preMealOverride?.hasFinished() == true {
            preMealOverride = nil
        }

        var scheduleOverride = self.temporaryPresetsManager.scheduleOverride
        if scheduleOverride?.hasFinished() == true {
            scheduleOverride = nil
        }

        dosingDecision.scheduleOverride = scheduleOverride

        if scheduleOverride != nil || preMealOverride != nil {
            dosingDecision.glucoseTargetRangeSchedule = self.temporaryPresetsManager.effectiveCorrectionRangeSchedule(presumingMealEntry: potentialCarbEntry != nil)
        } else {
            dosingDecision.glucoseTargetRangeSchedule = settings.glucoseTargetRangeSchedule
        }

        // Remove any expired context dosing decisions and add new
        self.contextDosingDecisions = self.contextDosingDecisions.filter { (date, _) in date.timeIntervalSinceNow > self.contextDosingDecisionExpirationDuration }
        self.contextDosingDecisions[context.creationDate] = dosingDecision

        return context
    }

    private func addCarbEntryAndBolusFromWatchMessage(_ message: [String: Any]) async throws {
        guard let bolus = SetBolusUserInfo(rawValue: message as SetBolusUserInfo.RawValue) else {
            log.error("Could not enact bolus from from unknown message: %{public}@", String(describing: message))
            throw WatchDataManagerError.decodingError
        }

        // Prevent any delayed messages from enacting.
        guard bolus.startDate.timeIntervalSinceNow > -30 else {
            log.error("Could not enact expired bolus from watch: %{public}@", String(describing: message))
            throw WatchDataManagerError.expiredBolusRecommendation
        }

        // While the pod is loaned to the watch this phone cannot deliver — its pod link is
        // deliberately released. Refuse loudly rather than letting the request die in a BLE
        // timeout. Delivery only is refused: an attached carb entry still stores below, because
        // dropping it would lose the meal from the record entirely.
        // (Reconciled from Caitlin's line 2026-09-09. The port had NO guard here: a watch
        // bolus during a loan went straight to enactBolus against a released pod link.)
        let deliveryRefusedForLoan = bolus.value > 0 && podLoanController.isPodLoanedOut
        if deliveryRefusedForLoan {
            log.error("Refusing watch bolus while the pod is on loan: %{public}@", String(describing: message))
            NotificationManager.sendBolusFailureNotificationForPodLoan(units: bolus.value)
        }

        var dosingDecision: BolusDosingDecision
        if let contextDate = bolus.contextDate, let contextDosingDecision = contextDosingDecisions[contextDate] {
            dosingDecision = contextDosingDecision
        } else {
            dosingDecision = BolusDosingDecision(for: .watchBolus)  // The user saved without waiting for recommendation (no bolus)
        }

        if let carbEntry = bolus.carbEntry {
            let storedCarbEntry = try await loopDataManager.addCarbEntry(carbEntry)
            dosingDecision.carbEntry = storedCarbEntry
            self.analyticsServicesManager?.didAddCarbs(source: "Watch", amount: storedCarbEntry.quantity.doubleValue(for: .gram))
        } else {
            dosingDecision.carbEntry = nil
        }

        dosingDecision.manualBolusRequested = bolus.value
        await loopDataManager.storeManualBolusDosingDecision(dosingDecision, withDate: bolus.startDate)

        // Loan-time refusal: the decision and any carbs are stored above; delivery is not attempted.
        guard !deliveryRefusedForLoan else { return }

        try await deviceManager.enactBolus(units: bolus.value, decisionId: dosingDecision.id, activationType: bolus.activationType)
        self.analyticsServicesManager?.didBolus(source: "Watch", units: bolus.value)
    }

    func handleWatchMessage(_ message: [String: Any]) async throws -> [String: Any] {
        switch message["name"] as? String {
        case SettingsRequestUserInfo.name?:
            let userInfo = LoopSettingsUserInfo(
                loopSettings: settingsManager.loopSettings,
                scheduleOverride: temporaryPresetsManager.scheduleOverride)
            return userInfo.rawValue
        case GetBolusRecommendationUserInfo.name?:
            if let request = GetBolusRecommendationUserInfo(rawValue: message) {
                let context = await createWatchContext(recommendingBolusFor: request.carbEntry)
                return context.rawValue
            } else {
                log.error("Could not recommend bolus from from unknown message: %{public}@", String(describing: message))
            }
        case SetBolusUserInfo.name?:
            // Add carbs if applicable; start the bolus and reply when it's successfully requested
            try await addCarbEntryAndBolusFromWatchMessage(message)
            let updatedContext = await createWatchContext()
            lastComplicationContext = updatedContext // Watch will use this to update context
            return updatedContext.rawValue

        case SetPresetUserInfo.name?:
            log.default("Set Preset from watch: %{public}@", String(describing: message))
            if let userInfo = SetPresetUserInfo(rawValue: message) {
                if let presetIdentifier = userInfo.presetIdentifier {
                    temporaryPresetsManager.startPreset(withIdentifier: presetIdentifier)
                } else {
                    temporaryPresetsManager.clearOverride()
                }

                // Prevent re-sending these updated settings back to the watch
                lastSentUserInfo?.scheduleOverride = temporaryPresetsManager.scheduleOverride

                if let alertIdentifier = userInfo.alertIdentifier {
                    let id = Alert.Identifier(managerIdentifier: temporaryPresetsManager.managerIdentifier, alertIdentifier: alertIdentifier)
                    try? await alertManager.acknowledgeAlert(identifier: id)
                }
                return [:]
            }

            let context = await createWatchContext()
            return context.rawValue
        case AcknowledgeAlertUserInfo.name?:
            log.default("Acknowledge alert from watch: %{public}@", String(describing: message))
            if let userInfo = AcknowledgeAlertUserInfo(rawValue: message) {
                let id = Alert.Identifier(managerIdentifier: userInfo.managerIdentifier, alertIdentifier: userInfo.alertIdentifier)
                try? await alertManager.acknowledgeAlert(identifier: id)
            }
            return [:]
        case CarbBackfillRequestUserInfo.name?:
            if let userInfo = CarbBackfillRequestUserInfo(rawValue: message) {
                do {
                    let objects = try await carbStore.getSyncCarbObjects(start: userInfo.startDate)
                    return WatchHistoricalCarbs(objects: objects).rawValue
                } catch {
                    self.log.error("%{public}@", String(describing: error))
                    return [:]
                }
            } else {
                return [:]
            }
        case GlucoseBackfillRequestUserInfo.name?:
            if let userInfo = GlucoseBackfillRequestUserInfo(rawValue: message) {
                do {
                    let samples = try await glucoseStore.getSyncGlucoseSamples(start: userInfo.startDate.addingTimeInterval(1))
                    return WatchHistoricalGlucose(samples: samples).rawValue
                } catch {
                    self.log.error("Failure getting sync glucose objects: %{public}@", String(describing: error))
                    return [:]
                }
            } else {
                return [:]
            }
        case WatchContextRequestUserInfo.name?:
            return await createWatchContext().rawValue
        case NotificationActionSelection.name?:
            if let selection = NotificationActionSelection(rawValue: message) {
                let identifier = Alert.Identifier(
                    managerIdentifier: selection.managerIdentifier,
                    alertIdentifier: selection.alertIdentifier
                )
                try? await alertManager.userDidSelectAction(alertIdentifier: identifier, actionIdentifier: selection.actionIdentifier)
            }
        default:
            return [:]
        }

        return [:]
    }
}


extension WatchDataManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            self.log.default("Received message: %{public}@", message)
            // The loan's interactive handshake — request, hand-back offer, acks — rides this
            // channel so a backgrounded watch app is woken now rather than whenever iOS decides
            // to drain the queue. Answer it before the stock message handling, which knows
            // nothing about these kinds.
            if (try? LoanMessage.decode(fromTransport: message)) != nil {
                lockedLastWatchContact.value = Date()
                podLoanController.handleIncoming(userInfo: message)
                replyHandler([:])
                return
            }
            do {
                replyHandler(try await handleWatchMessage(message))
            } catch {
                replyHandler(["error":String(describing: error)])
            }
        }
    }

    /// The URGENT channel with no reply handler — and the one the watch's Start actually uses.
    ///
    /// `sendMessage(_:replyHandler:nil)` is delivered HERE, not to the `replyHandler:` variant
    /// above, which WatchConnectivity only calls when the sender supplied a reply handler. Without
    /// this method the request is dropped by the framework with no error on either side: the watch
    /// logs a successful send, the phone logs nothing at all, and the watch sits until its 25 s
    /// timeout and reports "No response from iPhone". That is exactly what it looked like on the
    /// wrist, and it is indistinguishable from a phone that is refusing or asleep.
    ///
    /// The queued path below is not a substitute. The watch only falls back to it when the phone
    /// is UNREACHABLE, so this gap hides whenever the phone is present — the case that matters.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            guard (try? LoanMessage.decode(fromTransport: message)) != nil else {
                log.default("Ignoring unexpected sendMessage from the watch: %{public}@",
                            String(describing: Array(message.keys)))
                return
            }
            lockedLastWatchContact.value = Date()
            log.default("Loan sendMessage delivered (urgent path)")
            podLoanController.handleIncoming(userInfo: message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        // The pod loan protocol's QUEUED channel carries watch→phone traffic — streamed dose
        // records, status reports, hand-back offers — so this is no longer an impossible
        // callback. It previously asserted, which would take the app down on the first such
        // message, and during a loan that is the worst possible moment: the watch is holding
        // the pump and the phone is the side that has to commit its records.
        //
        // Three outcomes, none of them a silent drop (loan protocol: never ack-and-drop).
        // Ours → route it. Not ours → log, because stock genuinely sends nothing here and a
        // new sender is worth seeing. Undecodable-but-ours → log loudly; the sender's own
        // nack path handles recovery.
        Task { @MainActor in
            do {
                if let message = try LoanMessage.decode(fromTransport: userInfo) {
                    lockedLastWatchContact.value = Date()
                    if let receiver = podLoanMessageReceiver {
                        receiver(message)
                    } else {
                        podLoanController.handleIncoming(userInfo: userInfo)
                    }
                    return
                }
                log.default("Unexpected userInfo from the watch: %{public}@", String(describing: Array(userInfo.keys)))
            } catch {
                log.error("Undecodable pod loan payload from the watch: %{public}@", String(describing: error))
            }
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
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
    }

    /// The watch's diagnostics log, transferred file-by-file.
    ///
    /// Without this method the transfers still SUCCEED on the watch side and are then dropped
    /// here, so the wrist reports a healthy log pipeline while nothing is ever written — which is
    /// the worst shape a diagnostics gap can take, because it looks like silence from the device
    /// rather than a missing receiver.
    ///
    /// Two destinations, deliberately. Documents makes the file visible in Files (On My iPhone →
    /// Loop) so it can be AirDropped from the PHONE — watchOS has no AirDrop, and the logs were
    /// otherwise being texted. The iCloud mirror syncs it to the Mac with no Shortcuts step, and
    /// works on cellular. The copy has to happen NOW: the system deletes `file.fileURL` as soon
    /// as this method returns.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        lockedLastWatchContact.value = Date()   // the log pulse is the loan's heartbeat
        guard file.metadata?["kind"] as? String == "g7watch.log" else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamped = docs.appendingPathComponent("g7watch-\(formatter.string(from: Date())).log")
        try? FileManager.default.copyItem(at: file.fileURL, to: stamped)
        let latest = docs.appendingPathComponent("g7watch-latest.log")
        try? FileManager.default.removeItem(at: latest)
        try? FileManager.default.copyItem(at: file.fileURL, to: latest)
        // Retention: transfers arrive every reading (~5 min), so stamped copies accumulate fast.
        // Keep the newest 20; the stamp is lexicographically sortable. latest is exempt.
        if let entries = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            let stampedLogs = entries
                .filter { $0.pathExtension == "log" && $0.lastPathComponent.hasPrefix("g7watch-") && $0.lastPathComponent != "g7watch-latest.log" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in stampedLogs.dropFirst(20) {
                try? FileManager.default.removeItem(at: old)
            }
        }
        // Mirrored from the durable local copy, not from file.fileURL, which is gone by the time
        // the background queue runs.
        Self.mirrorLogToICloud(from: stamped)
        log.default("Watch log received: %{public}@", stamped.lastPathComponent)
    }

    /// SERIAL, not a global queue: a queued-transfer flush delivers several files back-to-back,
    /// and concurrent mirrors interleave their remove/copy/prune steps — which is how
    /// g7watch-latest.log ends up stale or missing in iCloud while newer sends exist. One mirror
    /// at a time, in arrival order.
    /// LINK CENSUS — one line a minute saying whether this PHONE can see the watch.
    ///
    /// The mirror of the watch's census. Reachability otherwise appears only as a side effect of
    /// a send, so the record is silent precisely when nothing is being sent — and a phone that
    /// could not reach the watch looks identical to a phone with nothing to say. Both directions
    /// are logged because they are not the same question and have disagreed in the field: the
    /// watch has reported `reachable true` while the phone logged `reachable=false` acking the
    /// same hand-back.
    nonisolated private static let linkCensusQueue = DispatchQueue(label: "com.loopkit.Loop.linkCensus", qos: .utility)
    nonisolated(unsafe) private static var linkCensusTimer: DispatchSourceTimer?

    /// Set by `PodLoanPhoneController` so the 60 s census can also report what the PHONE's pod link is
    /// doing DURING a loan. Filling a hole, not adding detail: on 2026-08-19 the phone logged NOTHING
    /// about its pod between `released=true linkUp=false` and, 110 s later, `link up +0.0s` — a link it
    /// should not have had, with no record of how it got one. A loan is exactly the window in which the
    /// phone is supposed to be silent on the radio, so silence in the log is indistinguishable from
    /// correct behaviour. Now it is not.
    nonisolated(unsafe) static var podLinkCensus: (() -> String)?

    nonisolated private func startLinkCensus() {
        let t = DispatchSource.makeTimerSource(queue: Self.linkCensusQueue)
        t.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        t.setEventHandler {
            guard WCSession.isSupported() else { return }
            let s = WCSession.default
            let pod = Self.podLinkCensus.map { " · pod: \($0())" } ?? ""
            Self.loanLadderSweep?()
            PhoneLog.event("link", "watch reachable=\(s.isReachable) activation=\(s.activationState.rawValue) paired=\(s.isPaired) appInstalled=\(s.isWatchAppInstalled)\(pod)")
        }
        t.resume()
        Self.linkCensusTimer = t
    }

    nonisolated private static let mirrorQueue = DispatchQueue(label: "com.loopkit.Loop.logMirror", qos: .utility)

    nonisolated private static func mirrorLogToICloud(from localStamped: URL) {
        mirrorQueue.async {
            let fm = FileManager.default
            guard let container = fm.url(forUbiquityContainerIdentifier: nil) else { return }   // iCloud off / not signed in
            let dir = container.appendingPathComponent("Documents", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.copyItem(at: localStamped, to: dir.appendingPathComponent(localStamped.lastPathComponent))
            let cloudLatest = dir.appendingPathComponent("g7watch-latest.log")
            // Atomic replace, never remove-then-copy: a crash or race between those two steps is
            // exactly how latest.log goes MISSING rather than merely stale.
            let tmp = dir.appendingPathComponent(".g7watch-latest.tmp")
            try? fm.removeItem(at: tmp)
            if (try? fm.copyItem(at: localStamped, to: tmp)) != nil {
                _ = try? fm.replaceItemAt(cloudLatest, withItemAt: tmp)
            }
            if let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                let stampedLogs = entries
                    .filter { $0.pathExtension == "log" && $0.lastPathComponent.hasPrefix("g7watch-") && $0.lastPathComponent != "g7watch-latest.log" }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
                for old in stampedLogs.dropFirst(20) {
                    try? fm.removeItem(at: old)
                }
            }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        Task { @MainActor in
            if let error = error {
                log.error("%{public}@", String(describing: error))

                // This might be useless, as userInfoTransfer.userInfo seems to be nil when error is non-nil.
                switch userInfoTransfer.userInfo["name"] as? String {
                case nil:
                    lastSentUserInfo = nil
                    sendSettingsIfNeeded()
                    lastSentBolusVolumes = nil
                    sendSupportedBolusVolumesIfNeeded()
                case LoopSettingsUserInfo.name:
                    lastSentUserInfo = nil
                    sendSettingsIfNeeded()
                case SupportedBolusVolumesUserInfo.name:
                    lastSentBolusVolumes = nil
                    sendSupportedBolusVolumesIfNeeded()
                default:
                    break
                }
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        // Nothing to do here
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            lastSentUserInfo = nil
            watchSession = WCSession.default
            watchSession?.delegate = self
            watchSession?.activate()
        }
    }

    /// The exact instant `isWatchAppInstalled` (or paired/complication) changes — the one thing the
    /// 60 s census cannot give us.
    ///
    /// WHY THIS MATTERS MORE THAN IT LOOKS. `WCSession.isWatchAppInstalled == false` makes WCSession
    /// QUEUE every message instead of delivering it, which silently breaks the loan's hand-back ACK:
    /// the phone commits, takes the pod back in a second, and the watch spins on "returning records"
    /// forever because the ack never lands. On 2026-08-19 that flag flapped five times in ninety
    /// minutes around install churn, and because we only sampled it every 60 s we could never say
    /// which install flipped it. A sampled level cannot be attributed to an event; a transition can.
    ///
    /// This also answers the open question directly: does installing the WATCH first and the phone
    /// workspace second leave the registration healthy, where the other order does not? Do each
    /// ordering once and read the transition lines.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        PhoneLog.event("link", "** WATCH STATE CHANGED ** paired=\(session.isPaired) "
            + "appInstalled=\(session.isWatchAppInstalled) reachable=\(session.isReachable) "
            + "activation=\(session.activationState.rawValue) "
            + "complication=\(session.isComplicationEnabled)")
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        Task { @MainActor in self.trackAppInstalledGlitch(paired: paired, installed: installed) }
    }

    /// The `appInstalled=false` GLITCH detector. WCSession sometimes reports the watch app "not
    /// installed" while it is sitting right there installed — a watch-side transport wedge, not
    /// an install state. Field remedy, three-for-three (2026-08-2x): toggling the WATCH's
    /// Bluetooth. Every occurrence cost real diagnosis time until someone remembered the
    /// folklore, so the phone now says the remedy itself. 75 s of persistence before speaking:
    /// a genuine install/replacement transits through false for up to ~7 min, but flips are
    /// also momentary during ordinary churn — the delay keeps this quiet through normal
    /// installs while still catching a wedge the same minute it starts. One notice per
    /// occurrence; re-arms when the flag recovers.
    @MainActor private func trackAppInstalledGlitch(paired: Bool, installed: Bool) {
        if installed || !paired {
            appInstalledGlitchWork?.cancel()
            appInstalledGlitchWork = nil
            appInstalledGlitchNotified = false
            return
        }
        guard appInstalledGlitchWork == nil, !appInstalledGlitchNotified else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.appInstalledGlitchWork = nil
            self.appInstalledGlitchNotified = true
            // Reconciled to Caitlin's line 2026-09-09: the 75-s persistence is still detected and
            // logged (it was the signature of both of 09-08's silences); it no longer posts.
            PhoneLog.event("link", "appInstalled=false has PERSISTED 75s [appinstalled-glitch]")
        }
        appInstalledGlitchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 75, execute: work)
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            if session.isReachable {
                lockedLastWatchContact.value = Date()
                podLoanController.watchDidBecomeReachable()
            }
            sendSettingsIfNeeded()
            sendSupportedBolusVolumesIfNeeded()
        }
    }
}


extension WatchDataManager {
    override var debugDescription: String {
        var items = [
            "## WatchDataManager",
            "lastSentUserInfo: \(String(describing: lastSentUserInfo))",
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
