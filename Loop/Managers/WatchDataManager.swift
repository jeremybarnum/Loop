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
        NotificationCenter.default.addObserver(self, selector: #selector(sendPodLoanRevoke), name: .PodLoanReclaimedViaEscapeHatch, object: deviceManager)
        NotificationCenter.default.addObserver(self, selector: #selector(sendSensorCodeToWatch(_:)), name: .SensorCodeCapturedForWatch, object: deviceManager)
        NotificationCenter.default.addObserver(self, selector: #selector(pollWatchLoanStatusOnForeground), name: UIApplication.didBecomeActiveNotification, object: nil)

        watchSession?.delegate = self
        watchSession?.activate()
    }

    /// DESIGN-6: after an escape-hatch reclaim, tell the watch its loan is over.
    /// transferUserInfo is QUEUED — it survives the watch being unreachable,
    /// asleep, or dead, and delivers on the watch's next app run. The watch drops
    /// its pod bid, keeps its journal, and sends it back for reconciliation.
    /// If the WC session isn't activated yet (reclaim raced app launch), the
    /// revoke parks in the app group and is queued on activation — a one-shot
    /// silent drop here would leave a live watch believing it owns the pod.
    @objc private func sendPodLoanRevoke() {
        guard let session = watchSession, session.activationState == .activated else {
            UserDefaults.appGroup?.pendingPodLoanRevokeDate = Date()
            log.error("Pod loan revoke deferred: watch session not activated (parked for activation)")
            return
        }
        session.transferUserInfo(PodLoanRevokeUserInfo(revokedAt: Date()).rawValue)
        log.default("Pod loan revoke queued for watch")
    }

    /// Component A: DeviceDataManager captured a new sensor's pairing code (or is re-relaying
    /// a known one). Push it to the watch — queued, so it survives the watch being asleep.
    @objc private func sendSensorCodeToWatch(_ note: Notification) {
        guard let code = note.userInfo?["code"] as? String,
              let sensorID = note.userInfo?["sid"] as? String else { return }
        let activatedAt = note.userInfo?["act"] as? Date
        let info = SensorCodeUserInfo(code: code, sensorID: sensorID, activatedAt: activatedAt)
        guard let session = watchSession, session.activationState == .activated else {
            // Session not up yet (sensor change raced app launch): PARK it and fire on
            // activation, rather than dropping the code — mirrors sendPodLoanRevoke. Once
            // sent, transferUserInfo itself queues delivery to an asleep/absent watch.
            UserDefaults.appGroup?.pendingSensorCodeRelay = info.rawValue
            log.error("Sensor code relay parked: watch session not activated (will fire on activation)")
            return
        }
        session.transferUserInfo(info.rawValue)
        log.default("Relayed sensor code to watch for sensor %{public}@", sensorID)
    }

    /// Fire a parked sensor-code relay once the session activates (see sendSensorCodeToWatch).
    private func sendPendingSensorCodeIfNeeded(_ session: WCSession) {
        guard session.activationState == .activated,
              let raw = UserDefaults.appGroup?.pendingSensorCodeRelay else { return }
        UserDefaults.appGroup?.pendingSensorCodeRelay = nil
        session.transferUserInfo(raw)
        log.default("Parked sensor code relayed to watch (from activation)")
    }

    /// Queue a parked revoke (see sendPodLoanRevoke) once the session activates.
    private func sendPendingPodLoanRevokeIfNeeded(_ session: WCSession) {
        guard session.activationState == .activated,
              let revokedAt = UserDefaults.appGroup?.pendingPodLoanRevokeDate else { return }
        UserDefaults.appGroup?.pendingPodLoanRevokeDate = nil
        session.transferUserInfo(PodLoanRevokeUserInfo(revokedAt: revokedAt).rawValue)
        log.default("Parked pod loan revoke queued for watch (from activation)")
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
    private var watchLoanPollTimer: Timer?   // 3b v2: Show-Mode status poll cadence (lives in the class; extensions can't hold stored properties)

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

        // 3b v2: keep the Show-Mode status poll alive on the loop cadence, and
        // (re)start it after a mid-loan relaunch. No-op when no loan is active.
        startWatchLoanPollingIfNeeded()

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
        case LoopSettingsUserInfo.name?:
            // The watch is asking for a settings refresh: a reinstalled watch app
            // has none, and the push path (transferUserInfo) won't resend while
            // the phone believes nothing changed (it's also unreliable on
            // simulators). Idempotent full-settings reply.
            log.default("Watch requested settings refresh")
            replyHandler(LoopSettingsUserInfo(settings: deviceManager.loopManager.settings).rawValue)
        case PodLoanDoseHistoryRequest.name?:
            // The watch wants pre-loan insulin history for its prediction (the
            // grant carries it normally; the sim demo's faked grant doesn't).
            deviceManager.loopManager.getDoseHistoryForWatchLoan(start: Date(timeIntervalSinceNow: -.hours(16))) { [log] result in
                var reply: [String: Any] = [:]
                if case .success(let doses) = result, let data = PodLoanDoseHistory(doses: doses).encoded() {
                    log.default("Replying to dose history request: %d doses (%d bytes)", doses.count, data.count)
                    reply["dh"] = data
                } else {
                    log.error("Dose history request: fetch/encode failed")
                }
                replyHandler(reply)
            }
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
            // Ack ONLY after the reconcile write commits (the closure) — not synchronously
            // here. The watch discards its journal on our ack, so a premature ack + a failed
            // write would lose the delivered doses from IOB with no resend.
            handlePodHandback(message) { replyHandler([:]) }
        default:
            replyHandler([:])
        }
    }

    /// The watch is asking to borrow the pod for a workout. Reply with the pod
    /// identity it needs to take over (read from the pump manager's rawState —
    /// see PodLoanIdentity), and pause automatic dosing for the loan. If there's
    /// no active pod, the reply is a denial and nothing is changed.
    // MARK: - Show-Mode status poll (3b v2 — phone-driven ownership indicator)

    /// Whether the phone currently has the pod out on loan — keyed on the
    /// PERSISTED release state (matches the pod tile + escape hatch), so a phone
    /// relaunched mid-loan still polls.
    private var isPodLoanActive: Bool {
        (deviceManager.pumpManager as? PumpConnectionLendable)?.isConnectionReleased == true
    }

    @objc private func pollWatchLoanStatusOnForeground() {
        startWatchLoanPollingIfNeeded()
    }

    /// Start (or refresh) polling the watch for its Show-Mode status while a loan
    /// is active. The phone drives the cadence; the watch just replies. A
    /// main-runloop timer polls every 30s while the app is foreground (it
    /// auto-suspends when backgrounded), plus an immediate poll here so a grant /
    /// app-foreground reflects "On Watch" promptly. Idempotent; no-op with no loan.
    func startWatchLoanPollingIfNeeded() {
        DispatchQueue.main.async {
            guard self.isPodLoanActive else { return }
            self.pollWatchLoanStatus()
            guard self.watchLoanPollTimer == nil else { return }
            self.watchLoanPollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.pollWatchLoanStatus()
            }
        }
    }

    private func stopWatchLoanPolling() {
        DispatchQueue.main.async {
            self.watchLoanPollTimer?.invalidate()
            self.watchLoanPollTimer = nil
        }
    }

    /// One poll round-trip (runs on main). On reply, record the watch's status +
    /// a fresh timestamp. On failure (watch unreachable/asleep), leave `lastHeard`
    /// untouched so the grace window ages it out to the honest "unknown" state —
    /// the poll deliberately cannot wake a sleeping watch, so it costs the watch
    /// no battery.
    private func pollWatchLoanStatus() {
        guard isPodLoanActive else {
            stopWatchLoanPolling()
            deviceManager.lastWatchLoanReport = nil
            return
        }
        guard let session = watchSession,
              session.activationState == .activated,
              session.isReachable else {
            return
        }
        session.sendMessage(WatchLoanStatusRequestUserInfo().rawValue, replyHandler: { [weak self] reply in
            guard let self, let status = WatchLoanStatusUserInfo(rawValue: reply) else { return }
            DispatchQueue.main.async {
                self.deviceManager.lastWatchLoanReport = DeviceDataManager.WatchLoanReport(
                    watchHoldsPod: status.holdsPod,
                    podConnected: status.podConnected,
                    lastHeard: Date())
            }
        }, errorHandler: { [weak self] error in
            self?.log.default("Watch loan status poll failed (watch unreachable): %{public}@", error.localizedDescription)
        })
    }

    private func handlePodLoanRequest(replyHandler: @escaping ([String: Any]) -> Void) {
        var grant = PodLoanIdentity.grant(fromPumpManagerRawState: deviceManager.pumpManager?.rawState,
                                          insulinTypeRaw: deviceManager.loopManager.pumpInsulinType?.rawValue)

        // FORMAL HANDOFF: the phone must deliberately stop bidding for the pod's
        // connection BEFORE granting, so the watch takes over uncontested — no
        // Bluetooth-off ritual, no reclaim races. A pump manager that can't
        // release gets no loan (granting while still bidding would be a lie:
        // the phone would steal the pod back within seconds).
        if grant.granted {
            if let lendable = deviceManager.pumpManager as? PumpConnectionLendable {
                lendable.releaseConnection()
                log.default("Pod connection released for loan (phone stops bidding)")
            } else {
                log.error("Pod loan denied: pump manager cannot release its connection")
                grant = .denied(reason: "Pump can't release the pod")
            }
        }

        if grant.granted {
            // RACE GUARD input: stamp the grant so a stale dead-session
            // hand-back arriving after this can be told apart from the live
            // loan's own hand-back (see handlePodHandback).
            UserDefaults.appGroup?.podLoanLastGrantedAt = Date()
            // Mark the loan window. The phone UI reports only its own truth
            // ("Pod Not Connected" once contact goes stale, or the Bluetooth
            // state) — never a claim about the watch; the grant alone doesn't
            // prove the watch took over.
            deviceManager.podLoanedToWatch = true
            startWatchLoanPollingIfNeeded()   // 3b v2: begin polling the watch for its status
            // A1: the phone's loop pauses for the loan (dosing off + pod released), so it
            // will legitimately stop completing. FULLY cancel the already-queued
            // loop-not-running notifications now — including the still-PENDING scheduled
            // timers (clearLoopNotRunningNotifications alone only removes DELIVERED ones);
            // the podLoanedToWatch gate then blocks any stray re-arm until the loan ends.
            deviceManager.alertManager.cancelLoopNotRunningNotifications()
            // C8: the boats are burned above (pod released, dosing pausing, loop
            // watchdog silenced) before the watch confirms takeover. Arm the
            // start watchdog — cancelled by the watch's holdsPod status push —
            // and the long-session reminder. Re-arms on a re-grant (a retried
            // takeover is unconfirmed again).
            deviceManager.alertManager.scheduleLoanStartWatchdog()
            deviceManager.alertManager.scheduleLoanDurationReminder()
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

        guard grant.granted else {
            replyHandler(grant.rawValue)
            return
        }

        // Attach 16h of dose history for the watch prediction algorithm. The
        // grant is the "frozen at handover" carrier; a failed fetch degrades
        // the watch to loan-session-only insulin, it never blocks the loan.
        let historyStart = Date(timeIntervalSinceNow: -.hours(16))
        deviceManager.loopManager.getDoseHistoryForWatchLoan(start: historyStart) { [log] result in
            var grant = grant
            switch result {
            case .success(let doses):
                if let data = PodLoanDoseHistory(doses: doses).encoded() {
                    grant.doseHistoryData = data
                    log.default("Pod loan grant carries %d doses (%d bytes)", doses.count, data.count)
                }
            case .failure(let error):
                log.error("Pod loan grant without dose history: %{public}@", String(describing: error))
            }
            replyHandler(grant.rawValue)
        }
    }

    /// The watch has handed the pod back. Record what it did (Phase 1: display;
    /// Phase 2: reconcile), restore automatic dosing to its pre-loan state, and
    /// re-establish the phone's own pod session so the pump data is current again.
    private func handlePodHandback(_ message: [String: Any], ackHandback: @escaping () -> Void) {
        guard let handback = PodHandbackUserInfo(rawValue: message) else {
            log.error("Could not decode pod hand-back message: %{public}@", String(describing: message))
            ackHandback()   // undecodable message: ack to avoid an infinite resend loop
            return
        }

        // RACE GUARD (observed 2026-07-17): a recovered dead-session hand-back
        // can race a NEW grant — the user re-enables Sport Mode moments after
        // the watch relaunches, and this handler's reclaim then lands AFTER the
        // new grant's release, stealing the pod back from the watch mid-takeover
        // (phone-pod sessions at 15:56/15:58 while the watch failed to connect).
        // Discriminate by session identity: a journal that STARTED before the
        // most recent grant belongs to a dead session, and its hand-back is
        // DATA ONLY — reconcile the doses and ack, but skip every "loan over"
        // side effect (flags, dosing restore, watchdog re-arm, reclaim,
        // schedule assert): those belong to the LIVE loan's lifecycle.
        let journalStartedAt = WatchLoanJournal(data: handback.journalData)?.startedAt
        let staleSession = deviceManager.podLoanedToWatch
            && journalStartedAt.map { $0 < (UserDefaults.appGroup?.podLoanLastGrantedAt ?? .distantPast) } == true
        if staleSession {
            log.default("Hand-back from a DEAD session (journal started %{public}@, current loan granted later) — reconciling data only; live loan untouched",
                        String(describing: journalStartedAt))
            lastWatchLoanSummary = handback.summary
            lastWatchLoanJournalData = handback.journalData
            let journalHash = SHA256.hash(data: handback.journalData).map { String(format: "%02x", $0) }.joined()
            if journalHash == UserDefaults.appGroup?.lastReconciledWatchLoanJournalHash {
                ackHandback()
            } else {
                reconcileWatchLoan(journalData: handback.journalData, handedBackAt: handback.handedBackAt, journalHash: journalHash, onWriteCommitted: ackHandback)
            }
            return
        }

        log.default("Pod handed back from watch: %{public}@", handback.summary)
        lastWatchLoanSummary = handback.summary
        lastWatchLoanJournalData = handback.journalData
        deviceManager.podLoanedToWatch = false   // phone is back in control
        DispatchQueue.main.async { self.deviceManager.lastWatchLoanReport = nil }
        stopWatchLoanPolling()   // 3b v2: loan over, stop polling the watch

        if let priorDosing = dosingEnabledBeforeWatchLoan {
            deviceManager.loopManager.mutateSettings { $0.dosingEnabled = priorDosing }
            dosingEnabledBeforeWatchLoan = nil
            // Clear any crash-recovery flag stranded by the loan grant (a loop enact
            // racing the pod-connection release never completes → the flag stays armed
            // the whole loan). Dosing was paused during the loan, so an armed flag here
            // is a grant-race artifact, not a real in-flight dose — clearing it at
            // hand-back stops a false "Loop Crashed" on a later reboot.
            deviceManager.crashRecoveryManager.dosingFinished()
        }
        // A1: re-arm the loop-not-running watchdog from now — the phone resumes looping
        // after hand-back, so a genuine failure to loop post-loan still alerts ~20 min
        // later (without waiting for a .LoopCompleted that may take a while post-reclaim).
        deviceManager.alertManager.rescheduleLoopNotRunningNotifications(Date())
        // C8: loan over — stand down both loan watchdogs. C6: the journal has
        // arrived (this handler restores dosing above), so the paused-dosing
        // reminder from an earlier escape-hatch reclaim also stands down.
        deviceManager.alertManager.cancelLoanStartWatchdog()
        deviceManager.alertManager.cancelLoanDurationReminder()
        deviceManager.alertManager.cancelDosingPausedAfterReclaimReminder()

        // Phase 2 (DIST-3): reconcile the watch's delivery into IOB — guarded against
        // duplicate hand-back messages (a retry after a lost ack resends the SAME
        // journal bytes; the watch snapshots the payload to keep them byte-stable).
        // The DoseStore does NOT dedupe manually-entered doses, so this hash is the
        // only defense against double-entering.
        let journalHash = SHA256.hash(data: handback.journalData).map { String(format: "%02x", $0) }.joined()
        if journalHash == UserDefaults.appGroup?.lastReconciledWatchLoanJournalHash {
            // Fast path: a byte-identical resend (lost ack, no further watch
            // activity). C7: a GROWN resend hashes differently and proceeds into
            // the per-event incremental reconcile below.
            log.default("Duplicate pod hand-back (journal %{public}@… already reconciled) — state restored, dose entry skipped", String(journalHash.prefix(8)))
            ackHandback()   // already reconciled — safe to let the watch clear its journal
        } else {
            // Ack only once the write COMMITS (onWriteCommitted); on write failure we stay
            // silent so the watch's send times out, keeps the journal, and retries.
            reconcileWatchLoan(journalData: handback.journalData, handedBackAt: handback.handedBackAt, journalHash: journalHash, onWriteCommitted: ackHandback)
        }

        // FORMAL HANDOFF: resume bidding for the pod's connection. The standing
        // connect re-arms, the session re-establishes on next contact (pod-side
        // EAP resync), and the next status poll resynchronizes pump data — no
        // manual poll here (the link isn't up yet; it would just error).
        if let lendable = deviceManager.pumpManager as? PumpConnectionLendable {
            lendable.reclaimConnection()
            log.default("Pod connection reclaimed after hand-back (phone resumes bidding)")
        } else {
            // Legacy path (pump manager without the capability): poll to refresh.
            deviceManager.pumpManager?.ensureCurrentPumpData(completion: { _ in })
        }
        // C11: assert scheduled basal. A RECOVERED hand-back (watch died) can
        // leave the watch's last temp still running on the pod — the dead
        // session couldn't cancel it, and this phone's pump state doesn't know
        // it exists. duration 0 = the stock cancel-and-resume-schedule
        // semantics; after a clean hand-back it's a harmless no-op (the watch
        // already cancelled). Best-effort — the link may take a moment to
        // re-establish; the closed loop's first enact is the backstop.
        deviceManager.pumpManager?.enactTempBasal(unitsPerHour: 0, for: 0) { [log] error in
            if let error = error {
                log.error("Post-handback schedule assert failed (loop's next enact is the backstop): %{public}@", String(describing: error))
            } else {
                log.default("Post-handback schedule assert: any leftover watch temp cancelled")
            }
        }
    }

    /// DIST-3 Phase B: enter what the watch delivered into the phone's dose
    /// accounting so IOB is correct for the hours after a loan.
    ///
    /// Design (see WATCH_DISTRIBUTION_SAFETY.md DIST-3 + docs/WATCH_INSULIN_MODEL.md
    /// §4c): journal bolus events are PRIMARY — entered at their real timestamps so
    /// insulin decay is computed correctly. §4c PHASE 2 (2026-07-10): the journal's
    /// off-schedule basal (temps above/below schedule, suspends as rate-0) is ALSO
    /// entered, as native temp-basal DoseEntries — Loop derives the signed net
    /// itself, so below-schedule sessions correctly REDUCE IOB. The pod's
    /// cumulative-delivered odometer then AUDITS the journal: any unexplained
    /// positive remainder (odometer delta − boluses − (full schedule + journal
    /// net)) is entered timed-late at hand-back, which overstates IOB → Loop doses
    /// less → errs safe. Negative remainders are logged, not entered.
    /// C7: per-loan incremental reconcile bookkeeping. A resend after a lost ack
    /// is byte-identical (fast-skipped by hash) UNLESS the watch did anything
    /// more first — then the journal GREW and hashes differently. Every journal
    /// entry has carried a stable UUID since day one; tracking which IDs are
    /// already entered makes the phone idempotent per-entry, so a grown resend
    /// enters only its new content. This is the phone half of the loan-protocol-v2
    /// cursor design, with no watch or wire-format change.
    private struct WatchLoanReconcileState: Codable {
        var loanStartedAt: Date
        var journalHash: String
        var reconciledEventIDs: Set<UUID>
        var reconciledCarbIDs: Set<UUID>
        /// Basal timeline entered through here (the previous hand-back stamp);
        /// a grown resend enters basal only after this instant — no overlap and
        /// no gap, because the prior reconcile's last segment ended exactly here.
        var basalEnteredUntil: Date
        var remainderEnteredUnits: Double

        static func load(forLoanStartedAt startedAt: Date) -> WatchLoanReconcileState? {
            guard let data = UserDefaults.appGroup?.watchLoanReconcileStateData,
                  let state = try? Self.decoder.decode(WatchLoanReconcileState.self, from: data),
                  abs(state.loanStartedAt.timeIntervalSince(startedAt)) < 1 else { return nil }
            return state
        }

        func save() {
            UserDefaults.appGroup?.watchLoanReconcileStateData = try? Self.encoder.encode(self)
        }

        private static let encoder: JSONEncoder = {
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
        }()
        private static let decoder: JSONDecoder = {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
        }()
    }

    private func reconcileWatchLoan(journalData: Data, handedBackAt: Date, journalHash: String, onWriteCommitted: @escaping () -> Void) {
        guard let journal = WatchLoanJournal(data: journalData) else {
            // Undecodable journal: keep Phase-1 behavior (summary already stored for
            // display; user can record manually via Non-Pump Insulin). Do NOT persist
            // the hash — a later valid resend must still be processable.
            log.error("Watch loan journal could not be decoded (%{public}d bytes) — no doses entered", journalData.count)
            onWriteCommitted()   // ack: the same bytes would never decode on retry — avoid a resend loop
            return
        }

        // C7: prior bookkeeping for THIS loan (matched on startedAt) → incremental;
        // a different/first loan starts fresh.
        let priorState = WatchLoanReconcileState.load(forLoanStartedAt: journal.startedAt)
        if let prior = priorState {
            log.default("Watch loan reconcile is INCREMENTAL: %{public}d events / %{public}d carbs already entered, basal covered to %{public}@",
                        prior.reconciledEventIDs.count, prior.reconciledCarbIDs.count,
                        Self.shadowTimeFormatter.string(from: prior.basalEnteredUntil))
        }

        let insulinType = deviceManager.loopManager.pumpInsulinType

        // The phone's therapy max-bolus — used below ONLY as the threshold above which an
        // odometer-audit remainder is flagged for review (never as a reject: the journal is
        // a record of ACTUAL delivery and the pod odometer is the reconciliation authority,
        // so no delivered dose is dropped — see the audit).
        let maxBolus = deviceManager.loopManager.settings.maximumBolus ?? 1.0

        // ALL of this hand-back's records enter in ONE DoseStore write (single
        // atomic Core Data save): a partial reconcile — basal entered, boluses
        // lost — would understate IOB by the boluses (over-dosing direction) and,
        // because the phone acks the hand-back BEFORE these async writes, no
        // watch-side resend would repair it. One write means the reconcile is
        // all-or-nothing; the idempotency hash persists only on its success.
        var entries: [DoseEntry] = []

        // (a) Journal boluses at their real timestamps, with deterministic
        // syncIdentifiers (journal-hash-derived, like the basal entries); the
        // CachedInsulinDeliveryObject uniqueness constraint drops exact re-entries
        // (insert-or-ignore) if a duplicate ever slips past the hash guard.
        // ITEMIZE EVERY bolus: the journal is a record of ACTUAL delivery, and the pod
        // odometer (podDelta, audit below) is the reconciliation AUTHORITY, so a recorded
        // delivery is NEVER silently dropped here — dropping one would understate IOB (the
        // over-dose direction). (The old `bolusRejectCap` reject was removed: it could only
        // ever fire on a REAL over-phone-cap delivery — genuine corruption fails to decode
        // into a valid journal, and the watch can't journal a bolus above its own cap since
        // it records the CAPPED value — so it only ever dropped real insulin.)
        // C7: totalBolusUnits = cumulative across ALL reconciles of this loan (the
        // audit needs the full-loan figure); only NEW events become entries.
        // syncIdentifiers are now the events' own stable UUIDs, so the store's
        // insert-or-ignore uniqueness is a true per-event second defense.
        var totalBolusUnits = 0.0
        var newEventIDs: Set<UUID> = []
        for event in journal.events {
            if case .bolus(let units) = event.kind, units > 0 {
                totalBolusUnits += units
                guard priorState?.reconciledEventIDs.contains(event.id) != true else { continue }
                entries.append(DoseEntry(type: .bolus,
                                         startDate: event.date,
                                         value: units,
                                         unit: .units,
                                         syncIdentifier: "watchloan-bolus-\(event.id.uuidString)",
                                         insulinType: insulinType,
                                         manuallyEntered: true,
                                         isMutable: false))
                newEventIDs.insert(event.id)
            }
        }

        // (b) §4c phase 2: the journal's off-schedule basal as native temp-basal
        // DoseEntries — Loop derives the signed net itself (negative for
        // suspends/low temps below schedule). ENTERED as of phase 2; the shadow
        // gate (§5) was passed 2026-07-10: a 54-min real-pod session's shadow
        // net (−3.23 U) matched the pod odometer's actual-vs-schedule deficit
        // (−3.24 U) to one pulse.
        // C7: entries are clipped to start after the prior reconcile's coverage
        // (no overlap, no gap — its last segment ended exactly at basalEnteredUntil);
        // the audit's journal-net term must span the FULL loan, so compute that
        // from the unclipped build.
        let basalDoses = buildWatchLoanBasalDoses(journal: journal, handedBackAt: handedBackAt, journalHash: journalHash,
                                                  enteringAfter: priorState?.basalEnteredUntil)
        entries.append(contentsOf: basalDoses)
        let fullBasalDoses = priorState == nil
            ? basalDoses
            : buildWatchLoanBasalDoses(journal: journal, handedBackAt: handedBackAt, journalHash: journalHash, enteringAfter: nil)
        var journalNet = 0.0
        for dose in fullBasalDoses {
            journalNet += dose.netBasalUnits
        }
        for dose in basalDoses {
            // One line per entry; pre-formatted (DiagnosticLog arity!).
            let desc = String(format: "%@ %.2f U/hr %@→%@ sched %.2f net %+.2f U",
                              dose.syncIdentifier ?? "?",
                              dose.unitsPerHour,
                              Self.shadowTimeFormatter.string(from: dose.startDate),
                              Self.shadowTimeFormatter.string(from: dose.endDate),
                              dose.scheduledBasalRate?.doubleValue(for: HKUnit.internationalUnit().unitDivided(by: .hour())) ?? 0,
                              dose.netBasalUnits)
            log.default("Watch loan basal entry: %{public}@", desc)
        }

        // (c) Odometer audit v2. Expected pod delivery is now the FULL schedule
        // plus the journal's net deviation (temps above/below schedule; suspends
        // as rate-0). With the basal entries entered for real, the v1 form
        // (schedule net of suspends) would double-count above-schedule delivery.
        // The remainder therefore isolates UNJOURNALED delivery only.
        // Skipped when the odometer baseline is missing.
        var remainderEnteredThisPass = 0.0
        if let podDelta = journal.podDeliveredDelta {
            let expectedBasal = expectedScheduledBasal(from: journal.startedAt, to: handedBackAt) + journalNet
            // Full-loan remainder, minus what earlier reconciles of this loan already
            // entered (C7): only the increment is new information.
            let remainder = podDelta - totalBolusUnits - expectedBasal - (priorState?.remainderEnteredUnits ?? 0)
            // NOTE: DiagnosticLog forwards at most FIVE varargs correctly (its
            // arity switch); a sixth argument misaligns os_log's va_list and
            // crashes in %@ decoding (SIGSEGV, 2026-07-10 00:07 hand-back crash).
            // Keep this call at <=5 args — the raw odometer readings are
            // pre-formatted into one string.
            let odometer = String(format: "start=%@ latest=%@",
                                  journal.deliveredAtStart.map { String(format: "%.2f", $0) } ?? "nil",
                                  journal.deliveredLatest.map { String(format: "%.2f", $0) } ?? "nil")
            log.default("Watch loan audit v2: podDelta=%{public}.2f (%{public}@) totalBoluses=%{public}.2f expected(sched+net)=%{public}.2f remainder=%{public}.2f",
                        podDelta, odometer, totalBolusUnits, expectedBasal, remainder)

            let remainderThreshold = 0.05   // one pod pulse; filters quantization/staleness noise
            // ENTER any positive remainder (delivery the journal didn't itemize) into IOB:
            // under-counting IOB is the dangerous (over-dose) direction and the odometer is
            // ground truth. Above the therapy max-bolus it's suspicious, so still enter it
            // (safe direction) but FLAG it for manual verification. Only a physically
            // implausible remainder (odometer corruption — a phantom that large would itself
            // withhold dosing for a long time) is withheld and surfaced instead of entered.
            let remainderReviewCap = max(5.0, maxBolus + 0.05)
            let remainderHardCap = 30.0   // implausible unjournaled delivery for one loan session
            if remainder >= remainderThreshold && remainder <= remainderHardCap {
                if remainder > remainderReviewCap {
                    log.error("Watch loan audit remainder %{public}.2f U is large — entered (IOB errs safe) but FLAGGED; verify delivery", remainder)
                }
                // Timed LATE (at hand-back): zero decay elapsed → IOB maximally
                // overstated for this insulin → Loop doses less → safe direction.
                entries.append(DoseEntry(type: .bolus,
                                         startDate: handedBackAt,
                                         value: remainder,
                                         unit: .units,
                                         syncIdentifier: "watchloan-\(journalHash.prefix(8))-audit",
                                         insulinType: insulinType,
                                         manuallyEntered: true,
                                         isMutable: false))
                remainderEnteredThisPass = remainder
            } else if remainder > remainderHardCap {
                log.error("Watch loan audit remainder %{public}.2f U implausibly large — NOT entered; verify delivery manually", remainder)
            }
        } else {
            log.default("Watch loan audit skipped: no odometer baseline in journal")
        }

        // C7: bookkeeping this reconcile persists on success — cumulative over
        // every reconcile of this loan.
        var newState = WatchLoanReconcileState(
            loanStartedAt: journal.startedAt,
            journalHash: journalHash,
            reconciledEventIDs: (priorState?.reconciledEventIDs ?? []).union(newEventIDs),
            reconciledCarbIDs: priorState?.reconciledCarbIDs ?? [],
            basalEnteredUntil: handedBackAt,
            remainderEnteredUnits: (priorState?.remainderEnteredUnits ?? 0) + remainderEnteredThisPass)

        guard !entries.isEmpty else {
            // No insulin to enter (e.g. a carbs-only loan, or a grown resend whose
            // increment is carbs/on-schedule only). Enter any new carbs, persist the
            // bookkeeping, and ACK — this path previously never called
            // onWriteCommitted, so no-dose hand-backs were re-sent forever (H21).
            newState.reconciledCarbIDs.formUnion(enterWatchLoanCarbs(journal, skipping: newState.reconciledCarbIDs))
            newState.save()
            UserDefaults.appGroup?.lastReconciledWatchLoanJournalHash = journalHash
            onWriteCommitted()
            return
        }

        // ONE write, hash on success. Retry semantics, honestly stated: the
        // phone acks the hand-back before this async write, so a watch resend
        // repairs only a reconcile that never STARTED (hash absent, nothing
        // committed — the atomic write guarantees nothing-committed on failure).
        // A crash after the ack but before this write completes loses the
        // reconcile with no resend — a pre-existing, known-narrow gap (see
        // SAFETY_PARADIGM), unchanged by phase 2. Deterministic syncIdentifiers
        // are belt-and-braces: an exact duplicate entry set is dropped by the
        // store's uniqueness constraint (insert-or-ignore — the store does NOT
        // update on collision, so this is safe only for identical content, which
        // the atomic write + byte-stable journal guarantee).
        let count = entries.count
        deviceManager.loopManager.addWatchLoanDoseEntries(entries) { [weak self] error in
            if let error = error {
                self?.log.error("Watch loan reconciliation failed: %{public}@ — nothing entered, hash not persisted; a resend re-enters everything", String(describing: error))
                // Do NOT ack: the watch's send times out, so it keeps the journal and
                // retries (the resend re-enters everything; the hash guard makes a
                // retry-after-a-late-success harmless).
            } else {
                // Carbs only after the dose write commits (bookkeeping persists with them).
                var state = newState
                state.reconciledCarbIDs.formUnion(self?.enterWatchLoanCarbs(journal, skipping: state.reconciledCarbIDs) ?? [])
                state.save()
                UserDefaults.appGroup?.lastReconciledWatchLoanJournalHash = journalHash
                self?.log.default("Watch loan reconciled: %{public}d entr%{public}@ in one write (basal net %{public}+.2f U)",
                                  count, count == 1 ? "y" : "ies", journalNet)
                onWriteCommitted()   // ack ONLY now that the write has committed
            }
        }
    }

    /// Enter the journal's watch-logged carbs into the phone's carb store, so the
    /// phone's COB is correct after the loan (a meal logged on the watch would
    /// otherwise be invisible to the phone). Called only where the reconcile hash is
    /// persisted, so the handback dedup guard prevents any double-entry.
    /// C7: enters only carbs whose IDs aren't in `skipping`; returns the IDs it
    /// dispatched so the caller can extend the per-loan bookkeeping.
    @discardableResult
    private func enterWatchLoanCarbs(_ journal: WatchLoanJournal, skipping: Set<UUID>) -> Set<UUID> {
        guard let carbs = journal.carbs, !carbs.isEmpty else { return [] }
        var dispatched: Set<UUID> = []
        for carb in carbs where !skipping.contains(carb.id) {
            dispatched.insert(carb.id)
            let entry = NewCarbEntry(quantity: HKQuantity(unit: .gram(), doubleValue: carb.grams),
                                     startDate: carb.date, foodType: nil, absorptionTime: carb.absorptionTime)
            deviceManager.loopManager.addCarbEntry(entry) { [weak self] result in
                if case .failure(let error) = result {
                    self?.log.error("Watch loan carb reconciliation failed (%{public}.0f g): %{public}@", carb.grams, String(describing: error))
                } else {
                    self?.log.default("Watch loan carb reconciled: %{public}.0f g", carb.grams)
                }
            }
        }
        return dispatched
    }

    private static let shadowTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// §4c: the temp-basal DoseEntries representing the journal's off-schedule
    /// delivery — one per (segment × schedule slice) so scheduledBasalRate is
    /// exact for each entry. Suspends are rate-0 temp basals (mathematically
    /// identical to .suspend; avoids the .suspend HK path's unguarded-duration
    /// trap). Deterministic syncIdentifiers make retries idempotent-by-hash.
    /// Entered via LoopDataManager.addWatchLoanDoseEntries (§4c phase 2).
    /// C7 `enteringAfter`: when non-nil, slices ending at or before the cutoff are
    /// dropped and a straddling slice is trimmed to start AT the cutoff — a grown
    /// resend enters only the timeline the prior reconcile didn't cover (its last
    /// segment ended exactly at the cutoff, so there is no overlap and no gap).
    /// Pass nil for the full-loan build (fresh reconcile, or the audit's net term).
    private func buildWatchLoanBasalDoses(journal: WatchLoanJournal, handedBackAt: Date, journalHash: String, enteringAfter cutoff: Date?) -> [DoseEntry] {
        guard let schedule = deviceManager.loopManager.basalRateScheduleApplyingOverrideHistory else {
            return []
        }
        let insulinType = deviceManager.loopManager.pumpInsulinType
        let rateUnit = HKUnit.internationalUnit().unitDivided(by: .hour())
        var doses: [DoseEntry] = []
        var seq = 0
        for segment in journal.offScheduleSegments(until: handedBackAt) {
            for slice in schedule.truncatingBetween(start: segment.start, end: segment.end) {
                var sliceStart = slice.startDate
                if let cutoff = cutoff {
                    guard slice.endDate > cutoff else { continue }   // fully covered by a prior reconcile
                    if sliceStart < cutoff { sliceStart = cutoff }   // straddling: enter only the tail
                }
                let duration = slice.endDate.timeIntervalSince(sliceStart)
                guard duration > 1 else { continue }   // degenerate slices: skip (HK duration guard)
                doses.append(DoseEntry(
                    type: .tempBasal,
                    startDate: sliceStart,
                    endDate: slice.endDate,
                    value: segment.actualRate,
                    unit: .unitsPerHour,
                    deliveredUnits: segment.actualRate * duration / 3600.0,
                    syncIdentifier: "watchloan-\(journalHash.prefix(8))-\(seq)",
                    scheduledBasalRate: HKQuantity(unit: rateUnit, doubleValue: slice.value),
                    insulinType: insulinType,
                    automatic: false,
                    manuallyEntered: true,
                    isMutable: false))
                seq += 1
            }
        }
        return doses
    }

    /// The FULL scheduled basal (U) over the loan window — no suspend adjustment.
    /// Audit v2 pairs this with the journal-net term, where suspends live as
    /// rate-0 segments; subtracting suspend windows here as well would
    /// double-subtract them and inflate the remainder (the v1 suspend-window
    /// machinery was deleted for exactly that trap).
    private func expectedScheduledBasal(from start: Date, to end: Date) -> Double {
        guard end > start,
              let schedule = deviceManager.loopManager.basalRateScheduleApplyingOverrideHistory else {
            return 0
        }

        var total: Double = 0
        for item in schedule.truncatingBetween(start: start, end: end) {
            total += item.value * item.endDate.timeIntervalSince(item.startDate) / 3600.0
        }
        return total
    }

    /// 3b v2.1: the watch PUSHES its Show-Mode status on phase transitions (grant/end) so the
    /// tile updates immediately; the poll remains the steady-state truth. Reachable path.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let status = WatchLoanStatusUserInfo(rawValue: message) {
            applyWatchLoanStatus(status)
        }
    }

    private func applyWatchLoanStatus(_ status: WatchLoanStatusUserInfo) {
        // C8: holdsPod straight from the watch is the loan-activation proof —
        // the takeover happened, so the did-Sport-Mode-start watchdog stands down.
        if status.holdsPod {
            deviceManager.alertManager.cancelLoanStartWatchdog()
        }
        DispatchQueue.main.async {
            self.deviceManager.lastWatchLoanReport = DeviceDataManager.WatchLoanReport(
                watchHoldsPod: status.holdsPod,
                podConnected: status.podConnected,
                lastHeard: Date())
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        // Queued fallback for the watch's status push (phone was unreachable at the transition).
        if let status = WatchLoanStatusUserInfo(rawValue: userInfo) {
            applyWatchLoanStatus(status)
            return
        }
        assertionFailure("We currently don't expect any userInfo messages transferred from the watch side")
    }

    /// Receive the watch's g7watch.log (G7 BLE trace + loop decisions + pod commands) and save it
    /// into the phone's Documents (file-sharing enabled → visible in Files / Finder for export).
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard (file.metadata?["kind"] as? String) == "g7log" else { return }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let df = DateFormatter()
        df.dateFormat = "MMdd-HHmm"
        let dst = docs.appendingPathComponent("g7watch-\(df.string(from: Date())).log")
        try? fm.removeItem(at: dst)
        do {
            try fm.copyItem(at: file.fileURL, to: dst)
            log.default("saved watch g7 log → Documents/%{public}@", dst.lastPathComponent)
        } catch {
            log.error("failed to save watch g7 log: %{public}@", String(describing: error))
        }
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
                sendPendingPodLoanRevokeIfNeeded(session)
                sendPendingSensorCodeIfNeeded(session)
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
        // 3b v2: the Show-Mode status poll can only land while the watch is
        // reachable, so poll the instant reachability comes up — turns the
        // minutes-to-first-"On Watch" wait (reachability settling) into seconds.
        // No-op when no loan is active.
        startWatchLoanPollingIfNeeded()
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

/// Mirror of OmniBLECore.PodLoanCarb — carbs the watch logged during the loan.
/// Field names MUST match the original (synthesized Codable keys).
private struct WatchLoanCarb: Decodable {
    let id: UUID
    let date: Date
    let grams: Double
    let absorptionTime: TimeInterval
}

private struct WatchLoanJournal: Decodable {
    let startedAt: Date
    let deliveredAtStart: Double?
    let deliveredLatest: Double?
    let events: [WatchLoanEvent]
    /// Optional so a journal from a PRE-carb watch build still decodes (absent → nil).
    let carbs: [WatchLoanCarb]?

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
