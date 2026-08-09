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

final class WatchDataManager: NSObject {

    private unowned let deviceManager: DeviceDataManager

    /// Minimal decode of a loan envelope's kind — routing stays in the controller;
    /// this only answers "is this a request?" for the sensor-code re-arm above.
    private struct LoanKindPeek: Decodable { let kind: String }
    
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

        // M5: construct eagerly so a relaunch mid-loan restores the persisted state
        // machine (dosing stays paused, reminders re-arm) before any message arrives.
        _ = podLoanController
    }

    // MARK: - New-sensor code relay (Component A, ported from g7-build-next)

    /// Fire a parked sensor-code relay once the session activates.
    private func sendPendingSensorCodeIfNeeded(_ session: WCSession) {
        guard session.activationState == .activated,
              let raw = UserDefaults.appGroup?.pendingSensorCodeRelay else { return }
        UserDefaults.appGroup?.pendingSensorCodeRelay = nil
        session.transferUserInfo(raw)
        log.default("Parked sensor code relayed to watch (from activation)")
    }

    // MARK: - Loan protocol v2 (M5)

    private(set) lazy var podLoanController: PodLoanPhoneController = {
        let dosingKey = "PodLoanPhoneController.dosingEnabledBeforeLoan"
        return PodLoanPhoneController(dependencies: .init(
            pumpManager: { [weak self] in self?.deviceManager.pumpManager },
            settings: { [weak self] in self?.deviceManager.loopManager.settings ?? LoopSettings() },
            setAutomaticDosingPaused: { [weak self] paused in
                guard let self = self else { return }
                if paused {
                    // Capture-once (the 4880ef92 lesson), persisted so a relaunch
                    // mid-loan still restores the right value at reconcile.
                    if UserDefaults.standard.object(forKey: dosingKey) == nil {
                        UserDefaults.standard.set(self.deviceManager.loopManager.settings.dosingEnabled, forKey: dosingKey)
                    }
                    self.deviceManager.loopManager.mutateSettings { $0.dosingEnabled = false }
                    // SPORT MODE (#2): loan just started — cancel the "Loop Failure" batch the last
                    // pre-loan loop already queued (the podOnLoanProvider gate stops FUTURE re-arms,
                    // but the queued 20/40/60/120-min ladder must be killed now so it never fires
                    // mid-loan). Also covers relaunch-into-loan (this closure runs at reconcile).
                    // #26: the ForLoanGrant variant also drops the future rungs' bookkeeping so
                    // loan-end inference can't record phantom "issued" alerts for cancelled rungs.
                    self.deviceManager.alertManager?.clearLoopNotRunningNotificationsForLoanGrant()
                    // #26 (replace, don't just mute): arm the watch-silence dead-man — during a
                    // loan the alarm-worthy failure is the WATCH going dark, not the phone not
                    // looping. Ungated arm (the loan state flips after this closure runs);
                    // main-hopped so every watch-silence mutation serializes on one queue.
                    DispatchQueue.main.async { [weak self] in
                        self?.deviceManager.alertManager?.armWatchSilenceNotifications()
                    }
                } else {
                    // Restore defaults to OPEN loop when the capture is missing —
                    // never invent closed-loop-on (R7's override is the settings UI).
                    let prior = UserDefaults.standard.object(forKey: dosingKey) as? Bool ?? false
                    UserDefaults.standard.removeObject(forKey: dosingKey)
                    self.deviceManager.loopManager.mutateSettings { $0.dosingEnabled = prior }
                    // #26: this closure runs ON the loan controller's serial queue, and the
                    // reschedule below reads the podOnLoan gate, which does queue.sync onto that
                    // SAME queue — calling it inline is a guaranteed deadlock (adversarial
                    // review blocker). Hop to main: by the time it runs, state == .owner is
                    // already set (every unpause site flips state first), so the gate is open
                    // and reads safely cross-queue. The main hop also serializes the clear
                    // against any in-flight watch-receipt re-arm (TOCTOU).
                    DispatchQueue.main.async { [weak self] in
                        // Loan ended — the watch no longer owes us a heartbeat.
                        self?.deviceManager.alertManager?.clearWatchSilenceNotifications()
                        // Reclaim-gap fix: the "Loop Failure" ladder only re-arms on a SUCCESSFUL
                        // loop, so a phone that fails to resume looping after reclaim — exactly
                        // the case the ladder exists for — would stay silent forever. Re-arm from
                        // the reclaim instant; the first successful loop reschedules normally.
                        self?.deviceManager.alertManager?.rescheduleLoopNotRunningNotifications(Date())
                    }
                }
            },
            send: { [weak self] dictionary in
                guard let session = self?.watchSession else { return }
                // #42 (2026-08-02): mirror of the watch's transport policy. The interactive
                // handshake (grant / denial / revoke / hand-back ack) takes the immediate
                // channel so a backgrounded watch app is woken now instead of whenever iOS
                // decides to drain its queue; record-bearing and diagnostic traffic keeps
                // transferUserInfo's guaranteed delivery. Failure falls back to that queue,
                // so this is never less reliable than the previous unconditional path.
                // #61/#35: log the SEND outcome. The grant's delivery was previously a black
                // box — an urgent send could fail into the queued fallback with no line saying
                // so, and on the simulator the queued path may not drain for minutes, which
                // presented as "phone granted, watch timed out" with zero evidence in between.
                let kind: String? = (dictionary[LoanProtocol.userInfoKey] as? Data)
                    .flatMap { try? JSONDecoder().decode(LoanKindPeek.self, from: $0) }?.kind
                guard LoanMessage.isInteractiveHandshake(transport: dictionary),
                      session.isReachable else {
                    let size = (dictionary[LoanProtocol.userInfoKey] as? Data)?.count ?? 0
                    self?.log.default("Loan send kind=%{public}@ path=queued (interactive=%{public}@ reachable=%{public}@ bytes=%{public}d)",
                                      kind ?? "?", String(describing: LoanMessage.isInteractiveHandshake(transport: dictionary)),
                                      String(describing: session.isReachable), size)
                    session.transferUserInfo(dictionary)
                    return
                }
                self?.log.default("Loan send kind=%{public}@ path=urgent", kind ?? "?")
                session.sendMessage(dictionary, replyHandler: nil, errorHandler: { [weak self] error in
                    self?.log.error("Loan urgent send FAILED kind=%{public}@ — %{public}@ — falling back to queued", kind ?? "?", String(describing: error))
                    session.transferUserInfo(dictionary)
                })
            },
            addPumpEvents: { [weak self] events, lastReconciliation, completion in
                guard let self = self else { completion(nil); return }
                // #69/#52: loan insulin behaves like real pump insulin — PumpEvent rows
                // (Event History) + stock reconciled() truncation + HealthKit. All loan
                // doses are IMMUTABLE (the interim open temp is deferred to the final drain),
                // so replacePendingEvents:false — there is no loan mutable dose to replace,
                // and it must NOT purge the phone's OWN resumed-pod in-flight temp when a
                // post-reclaim write (re-audit / forced reclaim) lands.
                self.deviceManager.doseStore.addPumpEvents(events, lastReconciliation: lastReconciliation, replacePendingEvents: false) { error in
                    completion(error.map { $0 as Error })
                }
            },
            addCarb: { [weak self] entry, completion in
                guard let self = self else { completion(nil); return }
                self.deviceManager.carbStore.addCarbEntry(entry) { result in
                    if case .failure(let error) = result { completion(error) } else { completion(nil) }
                }
            },
            // R30 (#89): a carb the WRIST deleted during the loan. Deleting through
            // `loopManager.deleteCarbEntry` (not carbStore directly) is deliberate — that is the
            // same door CarbAbsorptionViewController's swipe-to-delete uses, so the phone's COB
            // and prediction invalidate exactly as they do for a phone-side deletion.
            //
            // MATCHED, NOT TRUSTED. We re-read the store and match rather than reconstructing a
            // StoredCarbEntry from the wire: syncIdentifier first (phone-originated carbs carry
            // the phone's own, seeded through the grant), falling back to (startDate, grams)
            // within a second. A miss is logged and dropped — deleting the WRONG carb because a
            // key was ambiguous would be far worse than failing to delete, and the failure
            // direction here is a carb that survives and keeps driving dosing, which is visible.
            deleteCarb: { [weak self] gone, completion in
                guard let self = self else { completion(nil); return }
                let window = gone.startDate.addingTimeInterval(-.hours(1))
                self.deviceManager.carbStore.getCarbEntries(start: window) { result in
                    guard case .success(let entries) = result else { completion(nil); return }
                    let match = entries.first { entry in
                        if let id = gone.syncIdentifier, let entryID = entry.syncIdentifier { return id == entryID }
                        return abs(entry.startDate.timeIntervalSince(gone.startDate)) < 1
                            && abs(entry.quantity.doubleValue(for: .gram()) - gone.grams) < 0.01
                    }
                    guard let victim = match else {
                        self.log.default("PODLOAN carb delete: no match for %.0f g @ %{public}@ (already gone?)",
                                         gone.grams, String(describing: gone.startDate))
                        completion(nil)
                        return
                    }
                    self.deviceManager.loopManager.deleteCarbEntry(victim) { result in
                        if case .failure(let error) = result { completion(error) } else { completion(nil) }
                    }
                }
            },
            applyScheduleOverride: { [weak self] override in
                // #68 part B: the watch's override lands on the phone through the SAME single
                // door every other override uses — mutateSettings, whose didSet does the
                // overrideHistory.recordOverride (LoopDataManager:269-270) that actually
                // rescales basal/ISF/carb-ratio. Nothing bespoke, and no merge: during a loan
                // the watch is sovereign over overrides, so this is a straight assignment.
                // Called INLINE on the loan controller's queue (as setAutomaticDosingPaused
                // above already does) so the controller's "already applied?" read and this
                // write cannot interleave; mutateSettings is Locked-based and any-queue safe,
                // and its own oldValue != newValue guard makes a redundant write free.
                self?.deviceManager.loopManager.mutateSettings { $0.scheduleOverride = override }
            },
            // R23 overturned 2026-08-04: overwrite the captured pre-loan value with the WRIST's
            // final mode, so the restore in setAutomaticDosingPaused(false) picks it up
            // untouched. Writing the SAME key inherits the persistence that already survives a
            // relaunch mid-loan, and leaves the "missing capture defaults to OPEN" fail-safe
            // exactly as it was. Called inline on the loan controller's queue, like the
            // override door above; UserDefaults is any-queue safe.
            noteWatchClosedLoop: { closed in
                UserDefaults.standard.set(closed, forKey: dosingKey)
            },
            doseHistory: { [weak self] start, completion in
                guard let self = self else { completion([]); return }
                self.deviceManager.doseStore.getNormalizedDoseEntries(start: start) { result in
                    if case .success(let entries) = result { completion(entries) } else { completion([]) }
                }
            },
            carbHistory: { [weak self] start, completion in
                guard let self = self else { completion([]); return }
                // #49: the phone's active carbs, carrying the identity CarbStore.syncCarbObjects
                // dedups on so re-seeding is idempotent. Absorbed carbs older than the window
                // fall off naturally; only entries with future absorption matter for COB.
                self.deviceManager.carbStore.getCarbEntries(start: start) { result in
                    guard case .success(let entries) = result else { completion([]); return }
                    completion(entries.map { e in
                        LoanCarbRecord(syncIdentifier: e.syncIdentifier,
                                       provenanceIdentifier: e.provenanceIdentifier,
                                       syncVersion: e.syncVersion,
                                       startDate: e.startDate,
                                       grams: e.quantity.doubleValue(for: .gram()),
                                       absorptionTime: e.absorptionTime,
                                       foodType: e.foodType,
                                       userCreatedDate: e.userCreatedDate,
                                       userUpdatedDate: e.userUpdatedDate)
                    })
                }
            },
            glucoseHistory: { [weak self] start, completion in
                guard let self = self else { completion([]); return }
                // ~3 h of the phone's glucose so the watch's momentum + RC warm at takeover.
                self.deviceManager.glucoseStore.getGlucoseSamples(start: start, end: nil) { result in
                    guard case .success(let samples) = result else { completion([]); return }
                    let mgdl = HKUnit.milligramsPerDeciliter
                    let mgdlPerMin = mgdl.unitDivided(by: .minute())
                    completion(samples.map { s in
                        LoanGlucoseRecord(syncIdentifier: s.syncIdentifier,
                                          startDate: s.startDate,
                                          valueMgdl: s.quantity.doubleValue(for: mgdl),
                                          trendRateMgdlPerMin: s.trendRate?.doubleValue(for: mgdlPerMin),
                                          isDisplayOnly: s.isDisplayOnly,
                                          wasUserEntered: s.wasUserEntered)
                    })
                }
            },
            predictionSnapshot: { [weak self] completion in
                // INSTRUMENTATION ONLY (#45): the phone's last-computed prediction, decomposed,
                // for the grant. Pure cached read (no recompute, no dosing).
                guard let self = self else { completion(nil); return }
                self.deviceManager.loopManager.capturePredictionSnapshot(completion)
            },
            issueNotice: { [weak self] title, body in
                self?.log.error("PodLoan notice: %{public}@ - %{public}@", title, body)
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "podloan.notice.\(UUID().uuidString)", content: content, trigger: nil))
            },
            ownershipDidChange: { [weak self] in
                // Instant-tile port (crude f3784d49): the status screen observes
                // .PumpManagerChanged (object-filtered on deviceManager) and
                // re-presents pumpStatusHighlight, which keys on the persisted
                // isConnectionReleased — so the tile flips the moment ownership does.
                DispatchQueue.main.async {
                    guard let deviceManager = self?.deviceManager else { return }
                    NotificationCenter.default.post(name: .PumpManagerChanged, object: deviceManager)
                }
            },
            isConnectionReady: { [weak self] in
                // Post-hand-back settle: reclaimConnection() only re-arms the BLE bid, so the pod
                // peripheral is not actually back for ~2 min. Report the real link state so the
                // "Reclaiming…" tile persists (and the bolus gate refuses honestly) until then.
                (self?.deviceManager.pumpManager as? PumpConnectionLendable)?.isConnectionReady ?? true
            }
        ))
    }()

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

        // PODLOAN: while the pod is loaned to the watch this phone CANNOT deliver —
        // its pod link is deliberately released. Current watch builds enact locally
        // and never send a bolus here mid-loan; this catches stale/legacy requests
        // LOUDLY instead of letting them die in a BLE timeout. DELIVERY ONLY is
        // refused — an attached carb entry still stores below (dropping it would
        // lose the meal from the record entirely).
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

        func enactBolus() {
            dosingDecision.manualBolusRequested = bolus.value
            deviceManager.loopManager.storeManualBolusDosingDecision(dosingDecision, withDate: bolus.startDate)

            guard bolus.value > 0, !deliveryRefusedForLoan else {
                // Ensure active carbs is updated in the absence of a bolus
                // (or when loan-time delivery was refused above — carbs stored).
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
        deviceManager.alertManager?.noteWatchContactDuringLoan()   // #26: any watch traffic re-arms the silence dead-man
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
        default:
            replyHandler([:])
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        deviceManager.alertManager?.noteWatchContactDuringLoan()   // #26: the 5-min log pulse is the loan's heartbeat
        // Watch diagnostics log → Documents, visible in the Files app (On My iPhone →
        // Loop) so it can be AirDropped from the PHONE (watchOS has no AirDrop; logs
        // were being texted). Copy immediately — the system deletes file.fileURL when
        // this method returns.
        guard file.metadata?["kind"] as? String == "g7watch.log" else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamped = docs.appendingPathComponent("g7watch-\(formatter.string(from: Date())).log")
        try? FileManager.default.copyItem(at: file.fileURL, to: stamped)
        let latest = docs.appendingPathComponent("g7watch-latest.log")
        try? FileManager.default.removeItem(at: latest)
        try? FileManager.default.copyItem(at: file.fileURL, to: latest)
        // Retention: transfers now arrive every reading (~5 min), so stamped copies
        // accumulate fast. Keep the newest 20; the stamp is lexicographically
        // sortable. g7watch-latest.log is exempt (it's the rolling current copy).
        if let entries = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            let stampedLogs = entries
                .filter { $0.pathExtension == "log" && $0.lastPathComponent.hasPrefix("g7watch-") && $0.lastPathComponent != "g7watch-latest.log" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in stampedLogs.dropFirst(20) {
                try? FileManager.default.removeItem(at: old)
            }
        }
        // Log pipeline v3: mirror into the app's iCloud container so the file syncs
        // to iCloud Drive → the Mac with no Shortcuts step (works on cellular too).
        // url(forUbiquityContainerIdentifier:) can block, and file.fileURL dies when
        // this delegate method returns — so mirror from the durable local copy on a
        // background queue. Same latest+stamped+prune scheme as the local folder.
        Self.mirrorLogToICloud(from: stamped)
        log.default("Watch log received: %{public}@", stamped.lastPathComponent)
    }

    /// SERIAL queue (audit 2026-07-20, field-confirmed same day): concurrent
    /// global-queue mirrors raced each other — a queued-transfer flush delivers
    /// several files back-to-back, and interleaved remove/copy/prune left
    /// g7watch-latest.log stale or missing in iCloud (the Mac view froze at 17:42
    /// while newer sends existed). One mirror at a time, in arrival order.
    private static let mirrorQueue = DispatchQueue(label: "com.loopkit.Loop.logMirror", qos: .utility)

    private static func mirrorLogToICloud(from localStamped: URL) {
        mirrorQueue.async {
            let fm = FileManager.default
            guard let container = fm.url(forUbiquityContainerIdentifier: nil) else { return }   // iCloud off / not signed in
            let dir = container.appendingPathComponent("Documents", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.copyItem(at: localStamped, to: dir.appendingPathComponent(localStamped.lastPathComponent))
            let cloudLatest = dir.appendingPathComponent("g7watch-latest.log")
            // Atomic replace (never remove-then-copy): a crash or race between the
            // two steps is exactly how latest.log goes MISSING instead of stale.
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

    /// #42: the IMMEDIATE channel. sendMessage(replyHandler: nil) lands HERE — the
    /// replyHandler variant above is only called when the sender supplied one — so without
    /// this method the watch's urgent Start request would be silently dropped. Mirrors the
    /// loan routing in didReceiveUserInfo below, including the sensor-code re-relay that a
    /// request triggers.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deviceManager.alertManager?.noteWatchContactDuringLoan()   // #26: re-arm the silence dead-man
        guard message[LoanProtocol.userInfoKey] != nil else {
            log.default("Ignoring unexpected sendMessage from watch: %{public}@", String(describing: message.keys))
            return
        }
        let peekedKind: String? = (message[LoanProtocol.userInfoKey] as? Data)
            .flatMap { try? JSONDecoder().decode(LoanKindPeek.self, from: $0) }?.kind
        log.default("Loan sendMessage delivered (urgent path): kind=%{public}@", peekedKind ?? "unknown")
        if peekedKind == "request" {
        }
        podLoanController.handleIncoming(userInfo: message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        deviceManager.alertManager?.noteWatchContactDuringLoan()   // #26: loan protocol traffic re-arms the silence dead-man
        // M5: loan protocol v2 rides its own single key. Unknown payloads are logged
        // and ignored — never asserted on (failure-matrix row 17: WC redelivers
        // queued userInfo across reinstalls).
        if userInfo[LoanProtocol.userInfoKey] != nil {
            // #35 liveness: log EVERY loan userInfo the OS delivers to this phone, before
            // routing. If a future field log shows the watch resending offers but NO
            // "Loan userInfo delivered" line here, the OS never handed them over (app
            // suspended/killed/unreachable) — a delivery problem, not a controller drop.
            let peekedKind: String? = (userInfo[LoanProtocol.userInfoKey] as? Data)
                .flatMap { try? JSONDecoder().decode(LoanKindPeek.self, from: $0) }?.kind
            log.default("Loan userInfo delivered: kind=%{public}@", peekedKind ?? "unknown")
            // Component A re-arm: a loan REQUEST is the moment the watch needs the
            // current sensor's pairing code (its direct-G7 bond/prewarm path). The
            // automatic .sensorStart capture only fires for sensors started after
            // install — for the sensor already on-body, re-relay the held code or
            // prompt for it now.
            if peekedKind == "request" {
            }
            podLoanController.handleIncoming(userInfo: userInfo)
            return
        }
        log.default("Ignoring unexpected userInfo from watch: %{public}@", String(describing: userInfo.keys))
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
        // M5: any sign of watch life re-sends a parked revoke (kept from v1).
        podLoanController.watchDidBecomeReachable()
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
