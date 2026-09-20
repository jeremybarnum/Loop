//
//  PodLoanPhoneController+Wiring.swift
//  Loop
//
//  PODLOAN: how the phone's loan controller is wired to the stock managers. The controller
//  takes injected closures so the state machine is testable without the app; this is the one
//  place those closures are built from the real DeviceDataManager, LoopDataManager,
//  SettingsManager and the WatchConnectivity session. WatchDataManager keeps a one-line hook.
//

import HealthKit
import UIKit
import WatchConnectivity
import LoopAlgorithm
import LoopKit
import LoopCore

    /// Peek at a queued payload's kind without fully decoding it, to decide whether it must
    /// ride the interactive channel.
private struct LoanKindPeek: Decodable { let kind: String }

extension WatchDataManager {
    func makePodLoanController() -> PodLoanPhoneController {
        return PodLoanPhoneController(dependencies: .init(
            pumpManager: { [weak self] in self?.deviceManager.pumpManager },
            settings: { [weak self] in self?.settingsManager.loopSettings ?? LoopSettings() },
            setAutomaticDosingPaused: { [weak self] paused in
                guard let self = self else { return }
                if paused {
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
                        Task { await self?.deviceManager.alertManager?.rescheduleLoopNotRunningNotifications(Date()) }
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
                // SIZE IS LOGGED ON BOTH PATHS, and to the FILE, not just os_log.
                //
                // These lines previously went only to os_log, so the phone's log file recorded a
                // confident "GRANT" with no way to tell whether the send actually left the device.
                // The watch logs every send it makes; the phone logged none, and that asymmetry is
                // why a grant that the phone believed it sent and the watch never saw could not be
                // told apart from a grant that failed on the way out.
                //
                // Bytes matter specifically: sendMessage has a payload ceiling that
                // transferUserInfo does not, and the grant grows with the dose/carb/glucose
                // history it seeds. A grant that outgrows the urgent channel fails HERE, and
                // without the number there is nothing to correlate against.
                let size = (dictionary[LoanProtocol.userInfoKey] as? Data)?.count ?? 0
                guard LoanMessage.isInteractiveHandshake(transport: dictionary),
                      session.isReachable else {
                    self?.log.default("Loan send kind=%{public}@ path=queued (interactive=%{public}@ reachable=%{public}@ bytes=%{public}d)",
                                      kind ?? "?", String(describing: LoanMessage.isInteractiveHandshake(transport: dictionary)),
                                      String(describing: session.isReachable), size)
                    PhoneLog.event("wc", "send \(kind ?? "?") path=queued bytes=\(size) (interactive=\(LoanMessage.isInteractiveHandshake(transport: dictionary)) reachable=\(session.isReachable))")
                    session.transferUserInfo(dictionary)
                    return
                }
                // PODLOAN: THE GRANT RIDES BOTH CHANNELS. sendMessage is best-effort and its
                // reachability is advisory: on 2026-09-17 07:59 a grant went urgent 2 s after the
                // wrist went down, the framework reported no error, the fallback never ran, and
                // the watch never received it — the phone reclaimed 2.5 min later. The queued
                // copy is the guarantee; the urgent copy is the speed. The watch rejects the
                // duplicate by epoch (an accepted epoch is never accepted twice).
                let grantRidesBothChannels = (kind == "grant")
                self?.log.default("Loan send kind=%{public}@ path=urgent bytes=%{public}d", kind ?? "?", size)
                PhoneLog.event("wc", "send \(kind ?? "?") path=urgent\(grantRidesBothChannels ? "+queued" : "") bytes=\(size)")
                session.sendMessage(dictionary, replyHandler: nil, errorHandler: { [weak self] error in
                    guard !grantRidesBothChannels else {
                        PhoneLog.event("wc", "urgent send FAILED grant — \(error.localizedDescription) — the queued copy carries it")
                        return
                    }
                    self?.log.error("Loan urgent send FAILED kind=%{public}@ — %{public}@ — falling back to queued", kind ?? "?", String(describing: error))
                    PhoneLog.event("wc", "urgent send FAILED \(kind ?? "?") bytes=\(size) — \(error.localizedDescription) — falling back to queued")
                    session.transferUserInfo(dictionary)
                })
                if grantRidesBothChannels { session.transferUserInfo(dictionary) }
            },
            addPumpEvents: { [weak self] events, lastReconciliation, completion in
                guard let self = self else { completion(nil); return }
                // Loan insulin is treated exactly like pump insulin: PumpEvent rows, stock
                // reconciliation, HealthKit. Every loan dose is immutable by the time it
                // arrives — the interim open temp is held back until the final drain — so
                // there is no pending loan dose to replace, and replacing would purge the
                // phone's own in-flight temp when a post-reclaim write lands.
                Task {
                    do {
                        try await self.deviceManager.doseStore.addPumpEvents(events, lastReconciliation: lastReconciliation, replacePendingEvents: false)
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            },
            addCarb: { [weak self] entry, syncIdentifier, completion in
                guard let self = self else { completion(nil); return }
                // R36: the identity-accepting ingestion path. The plain addCarbEntry mints a
                // fresh identity per call — correct for authoring, wrong for delivery, and the
                // mechanism behind the twelve phantom carbs of 2026-08-12.
                Task {
                    do {
                        _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<StoredCarbEntry, Error>) in
                            self.deviceManager.carbStore.addCarbEntry(entry, syncIdentifier: syncIdentifier) { c.resume(with: $0) }
                        }
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            },
            // A carb the wrist deleted during the loan. Deleting through loopManager rather
            // than carbStore directly is deliberate: it is the same door the phone's own
            // swipe-to-delete uses, so COB and the prediction invalidate identically.
            //
            // The entry is matched against the store rather than reconstructed from the wire —
            // syncIdentifier first, falling back to (startDate, grams) within a second. A miss
            // is logged and dropped: deleting the wrong carb because a key was ambiguous is far
            // worse than failing to delete, and a carb that wrongly survives keeps driving
            // dosing visibly.
            deleteCarb: { [weak self] gone, completion in
                guard let self = self else { completion(nil); return }
                let window = gone.startDate.addingTimeInterval(-.hours(1))
                Task {
                    guard let entries = try? await self.deviceManager.carbStore.getCarbEntries(start: window) else { completion(nil); return }
                    let match = entries.first { entry in
                        if let id = gone.syncIdentifier, let entryID = entry.syncIdentifier { return id == entryID }
                        return abs(entry.startDate.timeIntervalSince(gone.startDate)) < 1
                            && abs(entry.quantity.doubleValue(for: .gram) - gone.grams) < 0.01
                    }
                    guard let victim = match else {
                        // A miss must be LOUD and carry the candidate set — "no match" without
                        // the near-misses is how the 258/260 failures took a release each to
                        // localize. The error surfaces through the controller's handbackDiag,
                        // which mirrors to the phone log and echoes to the watch log.
                        let lineup = entries.map { e in
                            String(format: "%.0fg@%@ sync=%@", e.quantity.doubleValue(for: .gram),
                                   DateFormatter.localizedString(from: e.startDate, dateStyle: .none, timeStyle: .medium),
                                   e.syncIdentifier.map { String($0.prefix(8)) } ?? "nil")
                        }.joined(separator: " | ")
                        self.log.default("PODLOAN carb delete: no match for %.0f g @ %{public}@ · candidates: %{public}@",
                                         gone.grams, String(describing: gone.startDate), lineup)
                        completion(NSError(domain: "PodLoan.carbDelete", code: 404, userInfo: [
                            NSLocalizedDescriptionKey: "no match among \(entries.count) candidate(s): \(lineup)"]))
                        return
                    }
                    do {
                        _ = try await self.deviceManager.carbStore.deleteCarbEntry(victim)
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            },
            // The READ side of the override property, and it must be wired: the controller's
            // apply path below is idempotent by comparing an incoming record against what the
            // phone currently holds, so an unwired reader (the `{ nil }` default) does not merely
            // lose an optimization — it reads "the phone holds no override" forever. That inverts
            // the clear: `.cleared` is skipped when nothing is held, so a preset the user switched
            // OFF on the wrist would never switch off on the phone, and the override would outlive
            // the loan indefinitely. Same queue reasoning as the writer below.
            // Refuse to grant when WCSession would only QUEUE the grant — see beginGrant().
            watchAppInstalled: { WCSession.isSupported() && WCSession.default.isWatchAppInstalled },
            scheduleOverride: { [weak self] in
                self?.temporaryPresetsManager.scheduleOverride
            },
            applyScheduleOverride: { [weak self] override in
                // The watch's override lands through the same single door every other override uses —
                // mutateSettings, whose didSet records it in the override history that actually rescales
                // basal, ISF and carb ratio. No merge: during a loan the watch is sovereign over
                // overrides, so this is a straight assignment. Called inline on the loan controller's
                // queue so the controller's "already applied?" read cannot interleave with this write;
                // mutateSettings is lock-based and safe from any queue.
                self?.temporaryPresetsManager.scheduleOverride = override
            },
            // The wrist's final loop mode is the phone's mode after the loan: applied directly,
            // on main, like every other therapy-settings write. Nothing is captured or restored.
            noteWatchClosedLoop: { [weak self] closed in
                DispatchQueue.main.async {
                    self?.settingsManager.mutateLoopSettings { $0.dosingEnabled = closed }
                }
            },
            lastLoopCompleted: { [weak self] in
                // Reading a @MainActor-published Date? off-actor is a benign snapshot: the
                // grant path wants "roughly when did this phone last loop", not a sync point.
                self?.loopDataManager.lastLoopCompleted
            },
            noteWatchLoopCompleted: { [weak self] date in
                DispatchQueue.main.async {
                    self?.loopDataManager.seedLastLoopCompleted(fromWatch: date)
                }
            },
            doseHistory: { [weak self] start, completion in
                guard let self = self else { completion([]); return }
                Task {
                    completion((try? await self.deviceManager.doseStore.getNormalizedDoseEntries(start: start)) ?? [])
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
                                       grams: e.quantity.doubleValue(for: .gram),
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
                Task {
                    guard let samples = try? await self.deviceManager.glucoseStore.getGlucoseSamples(start: start, end: nil) else { completion([]); return }
                    let mgdl = LoopUnit.milligramsPerDeciliter
                    let mgdlPerMin = mgdl.unitDivided(by: .minute)
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
                // Instrumentation only — the phone's forecast is no longer captured through a
                // stateful loop, and the watch runs its own. Nothing dosing reads this.
                completion(nil)
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
                Task {
                    do {
                        try await self.loopDataManager.cancelTempBasalAfterPodReturn()
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            },
            cancelTempBasalForGrant: { [weak self] completion in
                // PUMPLOAN: before the pod is lent, the phone cancels its own running temp and waits.
                guard let self = self else { return completion(nil) }
                Task {
                    do {
                        try await self.loopDataManager.cancelTempBasalForPodLoan(reason: .podLoanGrant)
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            },
            openLoopForUncertainReconciliation: { [weak self] in
                guard let self = self else { return }
                // MAIN-hopped (2026-08-26): third instance of the off-main therapy-write
                // desync. The R32 open at the end of the 9-hour overnight loan applied
                // dosingEnabled=false from the controller queue; the settings screen kept
                // showing CLOSED while automation was genuinely off — the user only knew
                // because the warning text disagreed with the toggle. Same treatment as the
                // pause/restore writes: one writer, one thread.
                DispatchQueue.main.async {
                    self.settingsManager.mutateLoopSettings { $0.dosingEnabled = false }
                }
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
                Task {
                    do {
                        try await self.deviceManager.doseStore.addDoses([entry], from: nil)
                        completion(true)
                    } catch {
                        completion(false)
                    }
                }
            },
            deleteGapDose: { [weak self] syncIdentifier, completion in
                guard let self = self else { return completion(false) }
                // deleteDose matches on syncIdentifier alone; the other fields are inert.
                let stub = DoseEntry(type: .bolus, startDate: Date(), endDate: Date(),
                                     value: 0, unit: .units, decisionId: nil, syncIdentifier: syncIdentifier,
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
                // Launch-while-locked guard (field crash 2026-08-27, TF 141): a reboot
                // mid-loan relaunched Loop in the background BEFORE FIRST UNLOCK, and the
                // display-refresh task this hook drives trapped +2 s into that launch
                // (insulinHistoryRewritten → updateDisplayState → EXC_BREAKPOINT). There is
                // no display to refresh while the device is locked, and the first
                // post-unlock cycle recomputes everything — skipping is free.
                // isProtectedDataAvailable must be read on main.
                DispatchQueue.main.async {
                    guard UIApplication.shared.isProtectedDataAvailable else {
                        PhoneLog.event("loan", "insulinHistoryRewritten display refresh SKIPPED — protected data locked (pre-first-unlock launch); the next cycle repaints [locked-launch]")
                        return
                    }
                    self.loopDataManager.insulinHistoryRewritten(startingAt: earliestStart)
                    // insulinHistoryRewritten already refreshes the display state, so the corrected
                    // books are visible without waiting for the next 5-minute cycle.
                }
            },
            whenProtectedDataAvailable: { work in
                DispatchQueue.main.async {
                    if UIApplication.shared.isProtectedDataAvailable {
                        work()
                    } else {
                        // One-shot: resume the deferred launch store work at first unlock.
                        PhoneLog.event("loan", "launch store work DEFERRED — protected data locked (pre-first-unlock launch); resuming on unlock [locked-launch]")
                        var token: NSObjectProtocol?
                        token = NotificationCenter.default.addObserver(
                            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                            object: nil, queue: .main) { _ in
                            if let token = token { NotificationCenter.default.removeObserver(token) }
                            work()
                        }
                    }
                }
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
            isBluetoothPoweredOff: { [weak self] in self?.deviceManager.bluetoothProvider.bluetoothState == .poweredOff },
            lastWatchContactAt: { [weak self] in self?.lockedLastWatchContact.value ?? nil },
            latestGlucoseDate: { [weak self] in self?.deviceManager.glucoseStore.latestGlucose?.startDate }
        ))
    }
}
