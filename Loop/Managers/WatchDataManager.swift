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

        // Constructed eagerly so a relaunch mid-loan restores the persisted state machine —
        // dosing stays paused, reminders re-arm — before any message arrives.
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
                    // Captured once and persisted, so a relaunch mid-loan still restores the right value at
                    // reconcile.
                    if UserDefaults.standard.object(forKey: dosingKey) == nil {
                        UserDefaults.standard.set(self.deviceManager.loopManager.settings.dosingEnabled, forKey: dosingKey)
                    }
                    self.deviceManager.loopManager.mutateSettings { $0.dosingEnabled = false }
                    // A loan just started: cancel the "Loop Failure" batch the last pre-loan loop queued.
                    // Gating future re-arms is not enough — the already-queued 20/40/60/120-minute rungs
                    // would still fire mid-loan. Also covers relaunching into an active loan, since this runs
                    // at reconcile. The ForLoanGrant variant additionally drops the future rungs' bookkeeping,
                    // so loan-end inference cannot record alerts that were cancelled.
                    self.deviceManager.alertManager?.clearLoopNotRunningNotificationsForLoanGrant()
                    // Arm the watch-silence dead-man: during a loan the alarm-worthy failure is the WATCH
                    // going dark, not the phone failing to loop. Armed ungated because the loan state flips
                    // after this closure runs, and main-hopped so every watch-silence mutation serializes on
                    // one queue.
                    DispatchQueue.main.async { [weak self] in
                        self?.deviceManager.alertManager?.armWatchSilenceNotifications()
                    }
                } else {
                    // Restore defaults to OPEN loop when the capture is missing —
                    // never invent closed-loop-on (R7's override is the settings UI).
                    let prior = UserDefaults.standard.object(forKey: dosingKey) as? Bool ?? false
                    UserDefaults.standard.removeObject(forKey: dosingKey)
                    self.deviceManager.loopManager.mutateSettings { $0.dosingEnabled = prior }
                    // This closure runs on the loan controller's serial queue, and the
                    // reschedule below reads a gate that dispatches sync onto that same queue —
                    // calling it inline deadlocks. Hopping to main is safe: state is already
                    // .owner by then, so the gate reads open from another queue, and the hop
                    // also serializes this clear against any in-flight re-arm.
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
                // The interactive handshake — grant, denial, revoke, hand-back ack — takes the
                // immediate channel so a backgrounded watch app wakes now rather than when iOS
                // drains its queue. Record-bearing and diagnostic traffic keeps
                // transferUserInfo's guaranteed delivery, and an urgent failure falls back to
                // it, so this is never less reliable than sending everything queued. The send
                // outcome is logged because an urgent send that failed into the fallback is
                // otherwise indistinguishable from one that worked.
                let kind: String? = (dictionary[LoanProtocol.userInfoKey] as? Data)
                    .flatMap { try? JSONDecoder().decode(LoanKindPeek.self, from: $0) }?.kind
                // DIAGNOSTICS NEVER TAKE THE GUARANTEED QUEUE.
                //
                // handbackDiag already writes every line to the phone's own file and says of the
                // watch relay: "only while the watch is reachable and only as a [phone] echo. The
                // file is the phone's independent account." That is the correct contract; the
                // transport was not honouring it. Falling through to transferUserInfo below made
                // each diag a guaranteed, ORDERED delivery — and handbackDiag has 60 call sites,
                // so one hand-back can enqueue dozens.
                //
                // Why that is not merely wasteful: transferUserInfo preserves order, and a GRANT
                // issued while the watch is unreachable takes that same queue. It then waits
                // behind every diag already in it, while the watch gives up after 25 s. Measured
                // 2026-08-17: bursts of 22-23 diag messages landing at an idle watch immediately
                // before each of two wedges, several within the same millisecond — the signature
                // of a backlog draining, not of live traffic.
                //
                // So: send when the watch is there, drop when it is not, and never queue. Nothing
                // is lost — the phone's file already holds every line.
                if kind == "diag" {
                    guard session.isReachable else { return }
                    session.sendMessage(dictionary, replyHandler: nil, errorHandler: { _ in })
                    return
                }

                // REACHABILITY IS RECORDED HERE, AT SEND TIME, IN THE PHONE'S OWN FILE.
                //
                // Every previous diagnosis of a lost grant has been inferred from the reclaim
                // ladder's "reachable N", which is sampled MINUTES later — after the watch has
                // timed out, gone idle and let its screen sleep. That is a reading about the
                // wrong moment, and reasoning from it produced two wrong explanations.
                //
                // Note what isReachable means on iOS: the WATCH APP IS IN THE FOREGROUND. It is
                // not a statement about Bluetooth, WiFi, proximity or battery. Both devices can
                // be inches apart, charged and connected, and this is still false.
                let bytes = (dictionary[LoanProtocol.userInfoKey] as? Data)?.count ?? 0
                let reachableNow = session.isReachable
                let interactive = LoanMessage.isInteractiveHandshake(transport: dictionary)
                // isReachable is only the SYMPTOM. The cause we are chasing is isWatchAppInstalled
                // going false — an app iOS is simultaneously receiving messages FROM — after which
                // every send fails WCErrorDomain 7006 and nothing queues. Record all four flags so
                // the send line alone says which layer failed.
                PhoneLog.event("wc", "send \(kind ?? "?") path=\(interactive && reachableNow ? "urgent" : "queued") "
                                   + "bytes=\(bytes) (interactive=\(interactive) reachable=\(reachableNow) "
                                   + "installed=\(session.isWatchAppInstalled) paired=\(session.isPaired) "
                                   + "activation=\(session.activationState.rawValue))")
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
                    PhoneLog.event("wc", "send \(kind ?? "?") URGENT FAILED — \(String(describing: error)) — falling back to queued")
                    session.transferUserInfo(dictionary)
                })
            },
            addPumpEvents: { [weak self] events, lastReconciliation, completion in
                guard let self = self else { completion(nil); return }
                // Loan insulin is treated exactly like pump insulin: PumpEvent rows, stock
                // reconciliation, HealthKit. Every loan dose is immutable by the time it
                // arrives — the interim open temp is held back until the final drain — so
                // there is no pending loan dose to replace, and replacing would purge the
                // phone's own in-flight temp when a post-reclaim write lands.
                self.deviceManager.doseStore.addPumpEvents(events, lastReconciliation: lastReconciliation, replacePendingEvents: false) { error in
                    completion(error.map { $0 as Error })
                }
            },
            addCarb: { [weak self] entry, syncIdentifier, completion in
                guard let self = self else { completion(nil); return }
                // R36: the identity-accepting ingestion path. The plain addCarbEntry mints a
                // fresh identity per call — correct for authoring, wrong for delivery, and the
                // mechanism behind the twelve phantom carbs of 2026-08-12.
                self.deviceManager.carbStore.addCarbEntry(entry, syncIdentifier: syncIdentifier) { result in
                    if case .failure(let error) = result { completion(error) } else { completion(nil) }
                }
            },
            // A carb the wrist deleted during the loan. Deleting through loopManager rather
            // than carbStore directly is deliberate: it is the same door the phone's own
            // swipe-to-delete uses, so COB and the prediction invalidate identically.
            //
            // The entry is matched against the store rather than reconstructed from the wire —
            // syncIdentifier first, falling back to (startDate, grams) within a second. That rule
            // now lives in `LoanReconciler.matchDeletedCarb`, where it can be tested; written
            // inline here it read as the fallback it is not, and the difference is a real miss
            // (see that function). A miss is logged and dropped: deleting the wrong carb because
            // a key was ambiguous is far worse than failing to delete, and a carb that wrongly
            // survives keeps driving dosing visibly.
            //
            // The lower bound is the DELETED carb's own start minus an hour, so an entry from
            // hours before the loan is still a candidate — the wrist lists back to the start of
            // the day, so the carb a user reaches for is routinely older than the loan.
            deleteCarb: { [weak self] gone, completion in
                guard let self = self else { completion(nil); return }
                let window = gone.startDate.addingTimeInterval(-.hours(1))
                self.deviceManager.carbStore.getCarbEntries(start: window) { result in
                    guard case .success(let entries) = result else { completion(nil); return }
                    guard let victim = LoanReconciler.matchDeletedCarb(gone, among: entries) else {
                        // A miss must be LOUD and carry the candidate set — "no match" without
                        // the near-misses is how the 258/260 failures took a release each to
                        // localize. The error surfaces through the controller's handbackDiag,
                        // which mirrors to the phone log and echoes to the watch log.
                        let lineup = entries.map { e in
                            String(format: "%.0fg@%@ sync=%@", e.quantity.doubleValue(for: .gram()),
                                   DateFormatter.localizedString(from: e.startDate, dateStyle: .none, timeStyle: .medium),
                                   e.syncIdentifier.map { String($0.prefix(8)) } ?? "nil")
                        }.joined(separator: " | ")
                        self.log.default("PODLOAN carb delete: no match for %.0f g @ %{public}@ · candidates: %{public}@",
                                         gone.grams, String(describing: gone.startDate), lineup)
                        completion(NSError(domain: "PodLoan.carbDelete", code: 404, userInfo: [
                            NSLocalizedDescriptionKey: "no match among \(entries.count) candidate(s): \(lineup)"]))
                        return
                    }
                    self.deviceManager.loopManager.deleteCarbEntry(victim) { result in
                        if case .failure(let error) = result { completion(error) } else { completion(nil) }
                    }
                }
            },
            applyScheduleOverride: { [weak self] override in
                // The watch's override lands through the same single door every other override uses —
                // mutateSettings, whose didSet records it in the override history that actually rescales
                // basal, ISF and carb ratio. No merge: during a loan the watch is sovereign over
                // overrides, so this is a straight assignment. Called inline on the loan controller's
                // queue so the controller's "already applied?" read cannot interleave with this write;
                // mutateSettings is lock-based and safe from any queue.
                self?.deviceManager.loopManager.mutateSettings { $0.scheduleOverride = override }
            },
            // Overwrite the captured pre-loan loop mode with the wrist's final one, so the
            // restore at loan end picks it up untouched — the phone inherits the watch's mode
            // rather than reverting to its own. Writing the same key keeps the persistence that
            // already survives a relaunch mid-loan and leaves the "missing capture defaults to
            // open loop" fail-safe intact.
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
                // The phone's active carbs, carrying the identity CarbStore dedups on so re-seeding is
                // idempotent. Absorbed carbs older than the window fall off naturally; only entries with
                // future absorption matter for COB.
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
                // Instrumentation only: the phone's last-computed prediction, decomposed, for the grant.
                // A pure cached read — no recompute, no dosing.
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
            },
            cancelTempBasalAfterPodReturn: { [weak self] completion in
                // The pod is home and reachable: drop the temp the watch set.
                guard let self = self else { return completion(nil) }
                self.deviceManager.loopManager.cancelTempBasalAfterPodReturn(completion: completion)
            },
            openLoopForUncertainReconciliation: { [weak self] in
                guard let self = self else { return }
                // ORDER MATTERS: clear the pre-loan capture before opening the loop. The end of the next
                // loan restores dosingEnabled from that key, so leaving it set would silently re-close the
                // loop this just opened — one loud warning followed by the machine quietly resuming, which
                // is worse than not warning at all. Cleared, the next loan captures false and restores
                // false, and only the user's own settings change can re-close it.
                UserDefaults.standard.removeObject(forKey: dosingKey)
                self.deviceManager.loopManager.mutateSettings { $0.dosingEnabled = false }
            },
            issueUrgentNotice: { [weak self] title, body in
                // The urgent channel's distinction is TIME-SENSITIVE interruption: it breaks
                // through Focus modes and gets lock-screen prominence, for messages where the
                // phone is the only device able to get the user's attention (a dead-watch
                // reclaim verdict, a rewritten IOB). Foreground banners are no longer this
                // channel's job — LoopAppManager banners every notification in-app now, same
                // as the daily-driver branches.
                self?.log.error("PodLoan URGENT: %{public}@ - %{public}@", title, body)
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "podloan.urgent.\(UUID().uuidString)", content: content, trigger: nil))
            },
            bookGapDose: { [weak self] entry, completion in
                // R37: manually-entered dose — the store keeps its syncIdentifier as identity
                // (pump events overwrite theirs with hex-of-raw), which is what makes the
                // placeholder deletable when the watch's real records arrive.
                guard let self = self else { return completion(false) }
                self.deviceManager.doseStore.addDoses([entry], from: nil) { error in
                    completion(error == nil)
                }
            },
            deleteGapDose: { [weak self] syncIdentifier, completion in
                guard let self = self else { return completion(false) }
                // deleteDose matches on syncIdentifier alone; the other fields are inert.
                let stub = DoseEntry(type: .bolus, startDate: Date(), endDate: Date(),
                                     value: 0, unit: .units, syncIdentifier: syncIdentifier,
                                     manuallyEntered: true)
                self.deviceManager.doseStore.deleteDose(stub) { error in
                    completion(error == nil)
                }
            },
            backfillDoses: { [weak self] doses, completion in
                // e44: the pump-event path above cannot land a basal-shaped dose behind the
                // delivery store's last immutable basal end date (DoseStore.swift:1174), which is
                // how a late journal commit after a force-reclaim loses every temp. syncDoseEntries
                // is stock's update-or-insert-by-syncIdentifier door, written for a remote
                // authoritative store — the watch journal is exactly that — so it writes straight
                // into the InsulinDeliveryStore with no boundary in the way.
                guard let self = self else { completion(nil); return }
                Task {
                    do {
                        try await self.deviceManager.doseStore.syncDoseEntries(doses)
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            },
            // A2: the writes above all land BEHIND the loop's counteraction-effect frontier, and
            // that memo is append-only — its bins over the loan window were computed against an
            // insulin curve that did not yet contain these doses, so dynamic carb absorption goes
            // on attributing the watch's insulin as unexplained glucose movement. Worse for the
            // e44 path, which posts no store notification at all (syncDoseEntries reaches
            // InsulinDeliveryStore, whose doseEntriesDidChange nothing in this app observes), so
            // without this hook a backfill invalidates nothing whatsoever.
            insulinHistoryRewritten: { [weak self] earliestStart in
                guard let self = self else { return }
                self.deviceManager.loopManager.insulinHistoryRewritten(startingAt: earliestStart)
                // The memo refills lazily, at the next update(). If the status screen is not
                // frontmost nothing calls getLoopState, so COB and IOB would stay wrong on the
                // books for up to a full 5-minute cycle after the hand-back that corrected them.
                // Nudge one update. Same serial dataAccessQueue as the prune, so it is ordered
                // after it by construction.
                self.deviceManager.loopManager.getLoopState { _, _ in }
            },
            // The two inputs the reclaim ladder branches on. Reachability is the positive-only
            // signal (true proves the watch is awake; false is routinely true of a healthy
            // backgrounded watch, which is why it cannot stand alone), and the contact timestamp
            // is the real separator — the loan's 300 s log pulse means a live watch is never more
            // than a few minutes stale.
            // Stock's background-task idiom (LoopDataManager keeps the same shape for its
            // persistence saves): begin ends any previous hold first, so the settle's re-begin
            // after the tap's begin nets one live identifier. beginBackgroundTask is one of the
            // few UIKit calls documented safe off the main thread, which is why these run
            // directly on the controller's queue.
            beginReclaimBackgroundTask: { [weak self] in self?.beginReclaimBackgroundTask() },
            endReclaimBackgroundTask: { [weak self] in self?.endReclaimBackgroundTask() },
            isWatchReachable: { [weak self] in self?.watchSession?.isReachable ?? false },
            lastWatchContactAt: { [weak self] in self?.lockedLastWatchContact.value ?? nil }
        ))
    }()

    /// ~30 s of continued execution across a reclaim, so tap-and-pocket completes ON SCHEDULE
    /// instead of freezing the ladder and orphaning the pod until the next foreground.
    private var reclaimBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func beginReclaimBackgroundTask() {
        endReclaimBackgroundTask()
        reclaimBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PodLoanReclaim") { [weak self] in
            // Expiration: iOS is done waiting — release the hold or be killed. The wall-clock
            // rungs then fire whatever is overdue at the next resume.
            self?.endReclaimBackgroundTask()
        }
    }

    private func endReclaimBackgroundTask() {
        if reclaimBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(reclaimBackgroundTask)
            reclaimBackgroundTask = .invalid
        }
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

    private var contextDosingDecisions: [Date: BolusDosingDecision] {
        get { lockedContextDosingDecisions.value }
        set { lockedContextDosingDecisions.value = newValue }
    }
    private var lockedContextDosingDecisions: Locked<[Date: BolusDosingDecision]> = Locked([:])

    /// When the phone last heard ANYTHING from the watch. Written from every inbound
    /// WatchConnectivity funnel (all four route through `noteWatchContact`), read from the loan
    /// controller's own serial queue when a reclaim picks its branch — hence the same `Locked`
    /// idiom the dosing-decision cache above uses, rather than a bare stored property.
    ///
    /// Deliberately NOT persisted: after a relaunch the phone genuinely has heard nothing from the
    /// watch this launch, and nil is the honest answer. The cost is bounded and known — a reclaim
    /// tapped in the first minutes after a relaunch runs the dead-watch ladder even if the watch is
    /// alive; live reachability, and the promotion when reachability arrives mid-ladder, are what
    /// recover that case. Persisting it instead would let a timestamp from a previous launch
    /// vouch for a watch nobody has heard from since.
    private let lockedLastWatchContact = Locked<Date?>(nil)

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

        // While the pod is loaned to the watch this phone cannot deliver — its pod link is
        // deliberately released. Refuse loudly rather than letting the request die in a BLE
        // timeout. Delivery only is refused: an attached carb entry still stores below, because
        // dropping it would lose the meal from the record entirely.
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

    /// The single place every inbound WatchConnectivity delivery reports itself. Two consumers,
    /// both of which need "the watch is alive" rather than "the watch said something specific":
    /// the silence dead-man re-arms, and the timestamp feeds the reclaim ladder's branch — a
    /// watch holding the pod transfers its log every 300 s, so contact age is what separates a
    /// drain worth waiting for from a watch that is not going to answer.
    private func noteWatchContact() {
        lockedLastWatchContact.value = Date()
        deviceManager.alertManager?.noteWatchContactDuringLoan()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        noteWatchContact()   // any watch traffic re-arms the silence dead-man
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
        noteWatchContact()   // the 5-min log pulse is the loan's heartbeat
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

    /// The immediate channel. `sendMessage(replyHandler: nil)` lands here rather than in the
    /// replyHandler variant above, which is only called when the sender supplied one — without
    /// this method the watch's urgent Start request would be silently dropped.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        noteWatchContact()   // re-arm the silence dead-man
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
        noteWatchContact()   // loan protocol traffic re-arms the silence dead-man
        // The loan protocol rides its own single key. Unknown payloads are logged and ignored,
        // never asserted on: WatchConnectivity redelivers queued userInfo across reinstalls, so a
        // payload from an older build can always arrive.
        if userInfo[LoanProtocol.userInfoKey] != nil {
            // Log every loan userInfo the OS delivers, before routing. If the watch is
            // resending offers and no line appears here, the OS never handed them over — a
            // delivery problem rather than a controller drop, and the two are otherwise
            // indistinguishable.
            let peekedKind: String? = (userInfo[LoanProtocol.userInfoKey] as? Data)
                .flatMap { try? JSONDecoder().decode(LoanKindPeek.self, from: $0) }?.kind
            log.default("Loan userInfo delivered: kind=%{public}@", peekedKind ?? "unknown")
            // A loan request is the moment the watch needs the current sensor's pairing code
            // for its direct-G7 bond. The automatic capture only fires for sensors started
            // after install, so for a sensor already on-body, re-relay the held code or prompt
            // for it now.
            if peekedKind == "request" {
            }
            podLoanController.handleIncoming(userInfo: userInfo)
            return
        }
        log.default("Ignoring unexpected userInfo from watch: %{public}@", String(describing: userInfo.keys))
    }

    /// iOS calls this whenever isPaired / isWatchAppInstalled change — i.e. the exact moment the
    /// system decides the watch app has appeared or vanished. It was not implemented, so the flip
    /// that breaks a loan happened invisibly and could only be inferred, hours later, from sends
    /// that had already failed.
    ///
    /// The open question this exists to answer: does `isWatchAppInstalled` go false and STAY false
    /// until the app is reinstalled, or does it recover on its own? The answer decides whether the
    /// remedy is prevention alone or prevention plus a recovery path, and no amount of reading the
    /// send failures can settle it — only watching the transition can.
    func sessionWatchStateDidChange(_ session: WCSession) {
        PhoneLog.event("wc", "WATCH STATE CHANGED — installed=\(session.isWatchAppInstalled) "
                           + "paired=\(session.isPaired) activation=\(session.activationState.rawValue) "
                           + "reachable=\(session.isReachable)")
        log.default("Watch state changed: installed=%{public}@ paired=%{public}@ reachable=%{public}@",
                    String(describing: session.isWatchAppInstalled),
                    String(describing: session.isPaired),
                    String(describing: session.isReachable))
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

            // Into the FILE as well, because this is where a lost grant would surface and until
            // now it surfaced only in os_log — invisible to every after-the-fact investigation.
            // The retry switch below covers settings and bolus volumes; LOAN traffic is not
            // handled by it at all, so a queued grant that fails here is dropped silently and
            // the watch simply times out with no grant and no explanation on either side.
            // `userInfo` is documented-unreliable on failure (see the note below), so the count
            // of still-outstanding transfers is logged as the more dependable signal.
            let wc = error as NSError
            let named = (wc.domain == "WCErrorDomain" && wc.code == 7006)
                ? "WATCH APP NOT INSTALLED (7006) — iOS believes the watch app is absent; sends fail and nothing queues. "
                : ""
            PhoneLog.event("wc", "transferUserInfo FAILED — \(named)\(String(describing: error)) "
                               + "· outstanding=\(session.outstandingUserInfoTransfers.count) "
                               + "· name=\(userInfoTransfer.userInfo["name"] as? String ?? "nil(loan or unknown)")")

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
