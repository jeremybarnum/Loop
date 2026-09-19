//
//  PodLoanPhoneController+Records.swift
//  Loop
//
//  Part of PodLoanPhoneController (see PodLoanPhoneController.swift). Split by concern; stored properties live in the core class.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore
import UserNotifications
import os.log

extension PodLoanPhoneController {

    // MARK: - Records (§2.4-2.6)

    func handleBatch(_ batch: DoseRecordBatch) {
        // OBS-9 (2026-08-13): this guard DISCARDS dose records, and used to do it in total
        // silence — no log on either side. That made a whole class of question unanswerable
        // from the logs: after a force-reclaim the phone is .owner, so every batch a returning
        // watch flushes from its queued backlog lands here and vanishes. The records are not
        // lost in the end (the watch's 15 s offer resend carries the same events, and the offer
        // path still commits in .owner), but "were these doses dropped here, or did they never
        // arrive?" had no answer. It has one now.
        guard batch.epoch == epoch, state == .loaned || state == .reclaimPending else {
            handbackDiag(batch.epoch, "batch DROPPED — \(batch.events.count) event(s) ev=\(batch.epoch) vs phone ev=\(epoch), state=\(state.rawValue) (recovered via the offer path if the watch still resends)")
            // A future-epoch batch is live evidence of a newer loan in ANY state — the
            // drop at .reconciling during the 2026-08-31 ghost drain is exactly the
            // moment the evidence mattered most (the close was about to steal the pod).
            if batch.epoch > epoch, newestForeignLoanEvidence.map({ batch.epoch >= $0.epoch }) ?? true {
                newestForeignLoanEvidence = (batch.epoch, deps.now())
            }
            // PHONE MIRROR detector B (row 6 — WC up): a FUTURE-epoch batch at .owner is
            // live evidence of a loan this phone never granted. The batch itself stays
            // dropped (yield needs less authority than adoption — booking still waits for
            // the token-bearing offer), but dosing as owner stops NOW instead of at
            // hand-back. Field 2026-08-30 23:43: this exact drop line fired while the
            // phone went on to bolus the pod as its own.
            if state == .owner, batch.epoch > epoch,
               UserDefaults.standard.string(forKey: Keys.dormantSeizeToken) != nil {
                engageInferredLoanYield(evidence: "future-epoch batch e\(batch.epoch) at .owner (live seized loan streaming)")
            }
            return
        }
        stage(events: batch.events, tombstones: batch.tombstones)
        // Records synced + odometer observed = a checkpoint candidate: the audit base can
        // advance past a window that reconciles, so a later forced reclaim judges only the
        // tail since this sync. Staging above happened first — the pairing is "records
        // through this batch" against "odometer at asOf".
        if let snap = batch.odometer {
            considerCheckpoint(snap, context: "batch")
        }
    }

    /// Relay a phone-side hand-back breadcrumb to the watch (which mirrors to iCloud)
    /// AND os_log it, so the phone's offer→write→ack path is visible when the phone
    /// silently fails to ack. Purely diagnostic.
    /// Publish the phone's own pod-link state into the 60 s link census, so a loan is no longer a
    /// silent window in the phone's log. Diagnostics only. Idempotent; safe to call repeatedly.
    func installPodLinkCensus() {
        WatchDataManager.podLinkCensus = { [weak self] in
            guard let self, let lendable = self.deps.pumpManager() as? PumpConnectionLendable else {
                return "no pump manager"
            }
            return "released=\(lendable.isConnectionReleased) \(lendable.connectionDiagnostics() ?? "no diagnostics")"
        }
    }

    func handbackDiag(_ epoch: Int, _ text: String) {
        os_log("HANDBACK-DIAG e%d: %{public}@", log: log, type: .default, epoch, text)
        // ...and into the phone's own mirrored file. These lines are relayed to the WATCH's log
        // too, but only while the watch is reachable and only as a [phone] echo. The file is the
        // phone's independent account — which is what was missing when both the hand-back stall
        // and the takeover failures came down to "did the phone actually release the pod?".
        PhoneLog.event("loan", "e\(epoch) \(text)")
        sendMessage(.diag(LoanDiag(epoch: epoch, text: text)))
    }

    func handleHandbackOffer(_ offer: HandbackOffer) {
        // R40 seize 4/4: retro-acknowledge a loan this phone never granted. A seized loan's
        // offer arrives with an epoch AHEAD of ours (forced fresh at activation) and the
        // reunion token matching the outstanding dormant credential. Adopting the epoch and
        // entering .loaned makes everything downstream the PROVEN hand-back path — the
        // normal transition to .reconciling, stage, commit, ack, the window audit anchored
        // at the offer's own seize-time odometer start, R33 cancel on the verified reclaim —
        // and .loaned also accepts the mid-blackout record batches WC queued behind this
        // offer. From .owner, or from .reclaimPending — the aimed-revoke drain (the pill tap
        // that targeted a live seized loan) answers with exactly this offer, and refusing it
        // there meant a needless force before the .owner door opened. The defense holds
        // either way: the states a duplicated credential must never stomp are a live grant
        // in flight (.grantOffered) and a live granted loan (.loaned/.reconciling), and both
        // stay excluded — a reclaim is this phone actively ENDING whatever loan exists.
        if let token = offer.seizeToken, state == .owner || state == .reclaimPending, offer.epoch > epoch,
           token.uuidString == UserDefaults.standard.string(forKey: Keys.dormantSeizeToken) {
            if state == .reclaimPending {
                // The drain the ladder was waiting for — stand the rungs down before adopting
                // so the force cannot fire into the hand-back it just received.
                cancelReclaimLadder()
                handbackDiag(offer.epoch, "[seize] retro-ack arrived MID-RECLAIM — ladder stood down; the aimed revoke got its drain")
            }
            handbackDiag(offer.epoch, "[seize] RETRO-ACK — offer for a SEIZED loan (token …\(String(token.uuidString.suffix(8)))); adopting epoch \(epoch)→\(offer.epoch) as .loaned, reconciling on the normal path")
            // PHONE MIRROR exit: the inferred loan just became a KNOWN loan — the flag's
            // job is done (dosing stays paused; the drain-close unpauses as always).
            clearInferredLoanYield(reason: "retro-ack — the inferred loan is now the adopted loan e\(offer.epoch)")
            epoch = offer.epoch
            state = .loaned
            // The seized loan's audit anchors at ITS OWN seize-time odometer read
            // (offer.odometer.deliveredAtStart); anchors from before the blackout must not
            // widen the window or misattribute the phone's own pre-blackout delivery.
            auditBase = nil
            checkpointsThisLoan = 0
            worstWindowThisLoan = 0
            UserDefaults.standard.removeObject(forKey: Keys.deliveredAtTakeover)
            // The loan window anchors at the OFFER'S OWN ERA — its earliest event, else
            // its hand-back stamp — never nil: a nil anchor fell back to the reconciler's
            // 2-hour default and audited a 5-minute seized loan over the whole morning
            // (field 2026-08-31: loanMin=120, phantom -1.15/-1.30 residuals). Floored at
            // -6h, the insulin horizon.
            let anchor = max(offer.events.map(\.record.startDate).min() ?? offer.handedBackAt,
                             deps.now().addingTimeInterval(-.hours(6)))
            loanStartedAt = anchor
            UserDefaults.standard.set(anchor, forKey: Keys.loanStartedAt)
        }
        // Stale epoch (rows 13/14): the records still drain — they are historical
        // truth, idempotent by ID — but loan STATE is untouched and the ack says
        // stale so the sender stops retrying. Dead loans cannot speak.
        let isStale = offer.epoch < epoch
        guard offer.epoch == epoch || isStale else {
            // Liveness: the offer is AHEAD of this phone's epoch (the watch is on a
            // higher epoch than this phone ever minted — e.g. a phone reinstall reset the
            // persisted epoch while WC redelivered a queued offer, failure-matrix row 17).
            // This USED TO return silently, which strands the loan: the phone never acks,
            // the watch resends every 15s forever (the "28 ignored offers" signature).
            // Never silent now — logged on both sides. Recovery behavior (adopt vs reclaim)
            // is a separate decision; for now the escape-hatch reclaim / new REQUEST path
            // is the way out.
            os_log("Hand-back offer DROPPED: offer.epoch %d > phone.epoch %d — watch ahead of phone; loan may be stranded (needs reclaim or new request)",
                   log: log, type: .error, offer.epoch, epoch)
            handbackDiag(offer.epoch, "offer DROPPED epoch \(offer.epoch) > phone \(epoch) — phone behind, loan stranded")
            return
        }
        handbackDiag(offer.epoch, "offer RX ev=\(offer.events.count) released=\(offer.released.map { $0 ? "final" : "interim" } ?? "nil") stale=\(isStale) state=\(state.rawValue)")

        // One commit in flight at a time — see the property doc. Coalesce, never drop.
        if commitInFlight {
            let storedIsFinal = coalescedOffers[offer.epoch]?.released == true
            if !(storedIsFinal && offer.released != true) {
                coalescedOffers[offer.epoch] = offer
            }
            handbackDiag(offer.epoch, "offer COALESCED behind the in-flight write (#118) — \(coalescedOffers.count) waiting")
            return
        }

        // Two-phase hand-back: an INTERIM offer (released == false) means the
        // watch is still dosing and still owns the pod — commit + ack ONLY; no state
        // change, no reclaim, tile stays "Pod on Watch". Legacy senders (released
        // nil) only offered after stopping, so nil = final.
        //
        // NO early re-ack shortcut (verify finding REAL-4): the staging path below is
        // idempotent by construction (committedIDs/cursor filters), and a blind re-ack
        // permanently stranded any event minted after the final-offer snapshot — the
        // watch could never drain it and held the pod forever. Every non-stale offer
        // now stages + commits unseen events; only the STATE transitions are gated.
        let isFinal = offer.released ?? true
        let canTransition = state == .loaned || state == .reclaimPending || state == .grantOffered
        if !isStale, isFinal, canTransition, deps.isBluetoothPoweredOff() {
            // A final offer hands this phone the pod, and the ack below is what lets the watch
            // release it. With Bluetooth off the phone cannot reclaim: it would own a pod it
            // cannot reach while a watch that was looping fine stands down. WatchConnectivity
            // runs over WiFi, so the watch cannot see this — only this phone can (bench
            // 2026-09-19 13:19: Bluetooth off for three minutes, hand-back ACKed in a second,
            // then the settle ran to its 300 s ceiling with no pod round-trip and the watch's
            // last temp still running). The ack is already the gate, so the refusal is simply
            // no ack: the watch's deadline keeps the loan and its glance says End did not
            // complete. No new message. Records in this offer stay unacked on the watch and
            // ride the next one.
            handbackDiag(offer.epoch, "final offer NOT accepted — this phone's Bluetooth is off, so it could not reclaim the pod; no ack, the watch keeps the loan")
            return
        }
        if !isStale, isFinal, canTransition {
            state = .reconciling
            // Record the wrist's loop mode BEFORE the unpause runs, so the restore path reads
            // it instead of the pre-loan capture. Gated on the same transition-owning condition
            // as the odometer audit: a duplicate final (routine — 15s resends vs ack latency)
            // must not re-apply it after the user has since changed the phone's own setting.
            // nil (older watch) leaves the captured pre-loan value alone.
            handbackDiag(offer.epoch, "commit done — ACKing now; the watch cannot release the pod until this lands")
            if let watchClosed = offer.watchClosedLoopEnabled {
                deps.noteWatchClosedLoop(watchClosed)
                handbackDiag(offer.epoch, "loop mode INHERITED from the wrist — phone will resume \(watchClosed ? "CLOSED" : "OPEN")")
            }
            // Loop recency inherits across the boundary too (ring ruling 2026-08-23): the
            // system looped seconds ago on the wrist, and the watch's temp keeps running
            // until this phone cancels it (R33), so a red ring during the ~10 s settle would
            // claim a therapy gap that does not exist. The phone's OWN next cycle then keeps
            // or loses the green honestly — if the pod or BG is missing, it ages out.
            if let watchLoop = offer.lastLoopCompleted {
                deps.noteWatchLoopCompleted(watchLoop)
                handbackDiag(offer.epoch, String(format: "loop recency INHERITED from the wrist — last cycle %.0fs ago", deps.now().timeIntervalSince(watchLoop)))
            }
        }
        // Round-2 fix: the odometer audit runs ONLY on the transition-owning final
        // offer. A duplicate final (routine: 15s resends vs ack latency) arrives
        // after finishLoanAfterCommit cleared `staged` — its re-staged tail is a
        // SUBSET of the loan, and auditing the whole-loan odometer against it mints
        // phantom remainders. Interim
        // offers carry freshened=false anyway; this makes the skip explicit.
        let auditThisOffer = !isStale && isFinal && state == .reconciling

        stage(events: offer.events, tombstones: offer.tombstones)
        // An INTERIM drain is a mid-loan sync like any batch: records + odometer paired, so
        // it may checkpoint. A FINAL offer must NOT — its snapshot is the endpoint the audit
        // below is about to judge; advancing the base to it first would collapse the verdict
        // window to nothing.
        if !isStale, offer.epoch == epoch, offer.released == false, let snap = offer.odometer {
            considerCheckpoint(snap, context: "interim-offer")
        }
        // Round-4 fix: dedup by EVENT ID only. The seq>cursor condition assumed a
        // gapless cursor; two-phase withholding creates gaps (an in-flight command's seq
        // can arrive AFTER later events were acked), and it would silently discard
        // the late-classified event. committedIDs is persisted — the ID filter is
        // the true exactly-once invariant.
        //
        // A MESSAGE MAY ONLY CAUSE WORK RELATED TO ITSELF.
        //
        // The transport guarantees delivery, not timeliness and not exactly-once — a copy of an
        // offer can arrive an hour after the original was handled. The protocol is built for
        // that (stable event IDs, ID-based dedup, a monotonic cursor), so a redelivered offer
        // should be a no-op. It was not, because this filter takes EVERYTHING staged rather than
        // what the arriving message brought, and the reconciler then clamps all of it to THAT
        // message's handedBackAt. Harmless while the message is current; catastrophic when it is
        // an hour old and `staged` now belongs to a different session: two already-acked epoch-1
        // offers were redelivered while epoch 2 was live, and epoch 2's temps were written ending
        // BEFORE they started. Core Data rejected the batch, the context was never rolled back,
        // and every later hand-back write failed for ~20 minutes.
        //
        // A STALE offer may therefore speak only for its own records. Current offers are
        // unchanged — draining the whole staged set is what interim/final drains rely on.
        let ownEventIDs = isStale ? Set(offer.events.map(\.id)) : nil
        let events = staged.values
            .filter { !stagedTombstones.contains($0.id) && !committedIDs.contains($0.id) }
            .filter { ownEventIDs?.contains($0.id) ?? true }
            .sorted { $0.seq < $1.seq }
        // The odometer audit must see the WHOLE loan's journal, not the tail —
        // interim-committed temps/suspends are real recorded insulin, not schedule.
        let allStagedEvents = staged.values
            .filter { !stagedTombstones.contains($0.id) }
            .sorted { $0.seq < $1.seq }

        let loanStart = loanStartedAt ?? offer.handedBackAt.addingTimeInterval(-.hours(2))
        let input = LoanReconciler.Input(
            events: events,
            odometer: auditThisOffer ? offer.odometer : nil,
            auditEvents: allStagedEvents,
            schedule: deps.settings().basalRateSchedule,
            loanStart: loanStart,
            loanEnd: offer.handedBackAt,
            // Interim drain (watch still dosing): don't clamp a still-open temp to
            // this drain instant — that would orphan its post-drain delivery.
            isFinalHandback: isFinal)
        let outcome = LoanReconciler.reconcile(input)

        // §5.3.3 audit inputs: the expected total over the WHOLE loan (all staged
        // events, not just this drain) and whether the watch's own audit ran.
        if auditThisOffer {
            let expected = LoanReconciler.expectedInsulin(events: allStagedEvents, schedule: deps.settings().basalRateSchedule,
                                                          from: loanStart, to: offer.handedBackAt)
            UserDefaults.standard.set(expected, forKey: Keys.expectedUnits)
            UserDefaults.standard.set(offer.odometer?.freshenSucceeded == true, forKey: Keys.watchAuditRan)

            // THE AUDIT: does the pod's own odometer agree with the
            // delivery history the watch claims to have executed?
            //
            //   delivered = the pod's cumulative-delivered DELTA over the loan — an independent,
            //               pulse-counted physical measurement we did not compute.
            //   expected  = expectedInsulin(ALL staged events + the basal schedule filling every
            //               uncovered gap) — i.e. the odometer reading implied by our own records.
            //   residual  = delivered - expected. THIS is the number the open-loop decision
            //               keys on. Tolerance is ONE PULSE (0.05 U) plus any bolus mid-delivery:
            //               both sides are pulse-quantized (supported rates are multiples of 0.05),
            //               so the only genuine ambiguity is whether the pulse due at the boundary
            //               has fired yet. That makes the threshold principled rather than guessed.
            //
            // WHY THIS LINE CHANGED: it used to print cmdCont/cmdFloor
            // from `outcome.doses` — the doses committed in THIS drain — against `delivered`, which
            // spans the WHOLE loan. After an interim drain the final offer carries no events, so the
            // line read "delivered=6.000 cmdFloor=0.000 remFloor=+6.000" and again "delivered=1.400
            // … remFloor=+1.400": six and one-point-four units of phantom missing insulin, pure
            // scope mismatch. `expected` was computed correctly on the line above and written only to
            // UserDefaults, so the audit has been running for weeks with nobody able to see its
            // answer. The drain-scoped figures are kept, clearly labelled, because they are still
            // useful for "what did THIS drain write".
            //
            // Still NO user-facing action here (the warning + the IOB valve remain unwired) —
            // this is the measurement that has to come before the threshold.
            let delivered = offer.odometer.map { $0.deliveredLatest - $0.deliveredAtStart }
            let drainCont = outcome.doses.reduce(0.0) { $0 + $1.programmedUnits }
            let drainFloor = outcome.doses.reduce(0.0) { $0 + (($1.programmedUnits * 20).rounded(.down) / 20) }
            let loanMin = offer.handedBackAt.timeIntervalSince(loanStart) / 60
            handbackDiag(offer.epoch, String(format:
                "reconcile[provisional]: delivered=%@ expected=%.3f residual=%@ (tol 0.05) · thisDrain cont=%.3f floor=%.3f · loanMin=%.0f cycles=%d fresh=%@",
                delivered.map { String(format: "%.3f", $0) } ?? "n/a", expected,
                delivered.map { String(format: "%+.3f", $0 - expected) } ?? "n/a",
                drainCont, drainFloor,
                loanMin, allStagedEvents.count, offer.odometer?.freshenSucceeded == true ? "Y" : "N"))

            // …and hold the audit open for a FIRST-HAND end reading.
            //
            // The line above is provisional because its end reading comes from the watch, and at
            // hand-back the watch cannot read the pod: it released the BLE link after its last dose
            // window, so both its cancel and its odometer freshen fail in about a millisecond. That
            // is why `fresh=N` on every hand-back on record. The endpoint is whatever the odometer
            // said at the last dose — up to ~5 minutes and one temp's delivery ago.
            //
            // The phone, meanwhile, does a real pod round-trip within seconds of reclaim to verify
            // the pod is home (the settle-window chase). It was already reading the odometer and throwing the
            // value away. Take it: same audit, same tolerance, an endpoint that is actually the end.
            if isFinal, let start = offer.odometer?.deliveredAtStart {
                // Since-last-sync: the verdict window runs from the audit base — the last
                // checkpoint when mid-loan syncs reconciled, the takeover reading when none
                // did (in which case base.units == start and this is the whole loan, the old
                // behavior exactly). The whole-loan pair rides along for the residual bank
                // and the slow-drift tripwire.
                let windowStart = auditBase?.units ?? start
                let windowExpected = auditBase.map {
                    LoanReconciler.expectedInsulin(events: allStagedEvents, schedule: deps.settings().basalRateSchedule,
                                                   from: $0.asOf, to: offer.handedBackAt)
                } ?? expected
                if checkpointsThisLoan > 0 {
                    handbackDiag(offer.epoch, String(format:
                        "[checkpoint] verdict window narrowed by %d checkpoint(s): anchor %.3f U (loan start %.3f), window expected %.3f (loan %.3f)",
                        checkpointsThisLoan, windowStart, start, windowExpected, expected))
                }
                pendingHandbackAudit = PendingHandbackAudit(
                    epoch: offer.epoch, deliveredAtStart: windowStart, expected: windowExpected,
                    loanMinutes: loanMin, cycles: allStagedEvents.count,
                    watchLatest: offer.odometer?.deliveredLatest,
                    watchFreshened: offer.odometer?.freshenSucceeded == true,
                    takeoverUnits: start, wholeLoanExpected: expected)
            }
        }

        // No additional insulin is added at hand-back: the positive-remainder
        // IOB valve is disabled for now. IOB comes purely from the streamed reconciled records — stock-
        // like trust; stock never injects odometer-derived IOB. outcome.positiveRemainderUnits is still
        // computed (and captured above) but no longer consumed. Re-enable if/when the reconciliation
        // warning is redesigned with a proper threshold.
        let doses = outcome.doses

        // The still-open temp (outcome.openEventID) is skipped by the reconciler and
        // kept out of committedIDs, so it re-drains and is written (clamped, immutable) on
        // the final drain. But we STILL ack its seq (newCursor below uses `events`, not
        // `committable`) so the watch's finalize gate (unackedEvents empty) can clear —
        // decoupling the ack cursor from committedIDs is what avoids the finalize deadlock.
        let committable = events.filter { $0.id != outcome.openEventID }

        // Write-events-first; ack ONLY after commit (a897d22c). Failure: no ack, stay
        // reconciling, 1 h reminder repeats (row 11) — never dose on incomplete records.
        // Loan insulin goes through addPumpEvents (PumpEvent table + stock reconciled() +
        // HealthKit); lastReconciliation = handedBackAt (the finalized-through watermark).
        // Belt-and-braces: never hand the store a dose that ends before it starts.
        //
        // The stale-offer scoping above removes the cause we know about, but this kills the
        // whole class — and it is the class that is dangerous, because that failure only surfaced
        // by luck. Those durations were so wrong that Core Data refused the batch loudly. Shift
        // the timing slightly and the same defect yields durations that are merely WRONG, which
        // validate fine and quietly corrupt IOB. Drop the bad rows, keep the good ones, and say
        // exactly what was dropped — an atomic batch failure told us nothing and wedged the
        // context for twenty minutes.
        let sane = doses.filter { $0.endDate >= $0.startDate }
        if sane.count != doses.count {
            let bad = doses.filter { $0.endDate < $0.startDate }
            handbackDiag(offer.epoch, "** DROPPED \(bad.count) impossible dose(s) (end before start) — writing \(sane.count) of \(doses.count). First: \(bad[0].type) \(bad[0].startDate) -> \(bad[0].endDate) **")
        }

        let writeStart = deps.now()
        handbackDiag(offer.epoch, "write START \(sane.count) dose(s) (final=\(isFinal))")
        // Held until BOTH store writes are done (pump events, then the e44 backfill) —
        // the latch's job is to keep a second Core Data write from starting, and the backfill
        // is one. Cleared on every exit path below.
        commitInFlight = true
        deps.addPumpEvents(newPumpEvents(from: sane), offer.handedBackAt) { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    self.commitInFlight = false
                    self.handbackDiag(offer.epoch, "write FAILED: \(String(describing: error))")
                    os_log("Reconcile write failed: %{public}@", log: self.log, type: .fault, String(describing: error))
                    // No notice. It was unactionable the instant it fired — the watch resends
                    // every 15 s and the retry is automatic — and `issueNotice` mints a fresh
                    // UUID per post, so it could never be retracted: the EXPECTED recovery left
                    // a banner standing that still claimed "Dosing stays paused" long after
                    // dosing had resumed. The .fault logs below carry the diagnosis, and
                    // armPausedReminder still carries the user-visible consequence.
                    self.armPausedReminder()
                    // No coalesced replay on failure — the watch's 15 s resend is the
                    // retry, and a hot local replay of the same failing write would spin. A
                    // deferred force-reclaim DOES run: it is the loan's only way out, and its
                    // own path re-attempts the staged records.
                    if let reason = self.pendingForceReclaimReason {
                        self.pendingForceReclaimReason = nil
                        self.forceReclaimToOwner(reason: reason)
                    }
                    return
                }

                // A2: the earliest dose the e44 backfill restated, filled in by the branch below
                // and read back inside finishCommit. Declared ahead of the closure because the
                // backfill is decided after it — the prune must span BOTH writes, and the
                // backfill routinely reaches further back than the pump-event batch (it restates
                // the whole loan window, including temps the boundary dropped).
                var backfillEarliestStart: Date? = nil

                // Everything downstream of the store writes — carbs, overrides, the ack, the gap
                // retire — held in one closure so the e44 backfill below can fail the whole commit
                // the way a failed pump-event write already does: nothing committed past the
                // insulin, and no ack.
                let finishCommit: (Error?) -> Void = { [weak self] backfillError in
                    guard let self = self else { return }
                    self.queue.async {
                        self.commitInFlight = false
                        if let backfillError = backfillError {
                            // Same treatment as a failed write, and for the same reason: the ack is
                            // what stops the watch's 15 s resend, so acking a half-landed commit
                            // retires the only retry we have. The upsert is idempotent, so the
                            // resend costs nothing.
                            self.handbackDiag(offer.epoch, "backfill FAILED: \(String(describing: backfillError))")
                            os_log("Loan dose backfill failed: %{public}@", log: self.log, type: .fault, String(describing: backfillError))
                            // Same as the write-failure path above: logged, not posted.
                            self.armPausedReminder()
                            if let reason = self.pendingForceReclaimReason {
                                self.pendingForceReclaimReason = nil
                                self.forceReclaimToOwner(reason: reason)
                            }
                            return
                        }

                        // Gate carbs on !isStale, matching the override change below.
                        // The commit used to run unconditionally while committedIDs.formUnion sat inside
                        // the `if !isStale` block at the bottom of this closure — so a stale redelivery
                        // committed the carbs and recorded nothing, and every resend added another copy.
                        // Insulin is immune (NewPumpEvent.raw dedupes at the store); carbs have no
                        // identity at all, so the cursor is the only guard and it was being skipped.
                        if !isStale {
                            for carb in outcome.carbs {
                                self.deps.addCarb(carb.entry, carb.eventID.uuidString) { _ in }  // insert-if-absent on the wire identity
                            }
                            // Deletions ride the same staleness gate as adds — a dead loan
                            // may not mutate the carb store in either direction.
                            for gone in outcome.deletedCarbs {
                                self.handbackDiag(offer.epoch, String(format: "carb DELETE from wrist — %.0f g @ %@ sync=%@", gone.grams, String(describing: gone.startDate), gone.syncIdentifier.map { String($0.prefix(8)) } ?? "nil"))
                                self.deps.deleteCarb(gone) { error in
                                    // Outcome, always — a delete that silently missed is how a carb
                                    // survives to the next grant and "resurrects" on the wrist.
                                    self.handbackDiag(offer.epoch, error == nil
                                        ? String(format: "carb DELETE applied on phone — %.0f g", gone.grams)
                                        : String(format: "carb DELETE MISSED on phone — %.0f g: %@", gone.grams, String(describing: error!)))
                                }
                            }
                        } else if !outcome.carbs.isEmpty {
                            self.handbackDiag(offer.epoch, "stale offer — \(outcome.carbs.count) carb(s) NOT committed (a dead loan cannot add carbs)")
                        }

                        // The watch owned overrides for the loan, so a drained override
                        // record lands on the phone here — after the store write commits, alongside
                        // carbs, and touching NO dose accounting. Stale offers are excluded: a dead
                        // loan cannot change live therapy settings.
                        if !isStale, let change = outcome.overrideChange {
                            self.applyWatchOverride(change, epoch: offer.epoch, isFinal: isFinal)
                        }

                        // Over/under delivery warning removed for now (Jeremy 2026-07-27): the hand-back is
                        // silent — records committed, delta captured in the [phone] reconcile line above, no
                        // user notice. outcome.residualShortfallUnits is still computed but no longer surfaced;
                        // the warning returns once a threshold is chosen from the captured field data.

                        let newCursor = events.map(\.seq).max() ?? self.committedCursor
                        if !isStale {
                            self.committedCursor = max(self.committedCursor, newCursor)
                            self.committedIDs.formUnion(committable.map(\.id))
                            self.persistCommittedIDs()
                            self.sendMessage(.handbackAck(HandbackAck(epoch: self.epoch, committedCursor: self.committedCursor)))
                            self.handbackDiag(self.epoch, String(format: "write DONE %.0fms → ACK cursor %d", self.deps.now().timeIntervalSince(writeStart) * 1000, self.committedCursor))
                            if isFinal, self.state == .reconciling {
                                // Only the transition-owning offer finishes; a duplicate final
                                // offer post-.owner just committed any unseen tail + re-acked.
                                self.finishLoanAfterCommit()
                            } else if !isFinal {
                                os_log("Interim drain committed to cursor %d — watch still dosing", log: self.log, type: .default, self.committedCursor)
                            }
                        } else {
                            self.sendMessage(.handbackAck(HandbackAck(epoch: offer.epoch, committedCursor: newCursor, stale: true)))
                        }
                        // A2: every dose this commit just wrote sits behind the phone's counteraction
                        // frontier — that is what a loan window IS — so the memo must be pruned back
                        // to the earliest of them or COB keeps attributing the loan's insulin as
                        // unexplained glucose movement. Outside the staleness gate for the same
                        // reason the retire below is: a stale offer still writes its doses, so it
                        // still rewrites insulin history. Both writes count — the pump-event batch
                        // (`sane`) and the e44 backfill.
                        if let earliest = (sane.map(\.startDate) + (backfillEarliestStart.map { [$0] } ?? [])).min() {
                            self.deps.insulinHistoryRewritten(earliest)
                        }
                        // Outside the staleness gate ON PURPOSE — a watch that comes back after a
                        // NEW loan has started re-offers its old epoch as stale, and stale offers still
                        // write their doses ("historical truth" above). If those doses explain a gap
                        // booking, the placeholder retires regardless of loan-state bookkeeping.
                        self.retireGapBookingIfExplained(
                            offerEpoch: offer.epoch,
                            dosesJustCommitted: sane,
                            carbsJustCommitted: isStale ? 0 : outcome.carbs.count)
                        self.drainAfterCommit()   // replay one coalesced offer, or run a deferred force-reclaim
                    }
                }

                // e44 (field, −0.25 U): the pump-event write above CANNOT land a
                // basal-shaped dose that starts before the delivery store's last immutable basal
                // end date — DoseStore.swift:1174 drops it from the InsulinDeliveryStore sync,
                // with a bolus-only escape. After a force-reclaim the salvage's clamped tail AND
                // the phone's own resumed records sit ahead of the entire loan window, so a
                // journal that comes back late writes its PumpEvent rows fine and NONE of its
                // temps reach the books: the bolus survives, the temps vanish, IOB under-counts.
                // That asymmetry is the field signature exactly.
                //
                // So restate the WHOLE loan's doses under their store identity and upsert them
                // (DoseStore.syncDoseEntries — update-or-insert on syncIdentifier, built for a
                // remote authoritative store, which is what the watch journal is). Inserts the
                // dropped temps, no-op-updates the clean path's rows, and corrects the
                // salvage-clamped extension to the journal's true end: same event UUID, same
                // identity, so "real records replace estimates" happens as an
                // upsert-correction instead of a delete.
                //
                // STALE OFFERS SKIP IT: a dead loan speaks only for its own records, and
                // reconciling the whole staged set against a stale `handedBackAt` is exactly the
                // defect that wrote temps ending before they started.
                let backfillOutcome = LoanReconciler.reconcile(LoanReconciler.Input(
                    events: allStagedEvents,
                    odometer: nil,
                    schedule: self.deps.settings().basalRateSchedule,
                    loanStart: loanStart,
                    loanEnd: offer.handedBackAt,
                    isFinalHandback: isFinal))
                let backfill = self.storeIdentifiedDoses(from: self.truncatingOverlaps(
                    backfillOutcome.doses.filter { $0.endDate >= $0.startDate }))
                if isStale || backfill.isEmpty {
                    if isStale {
                        self.handbackDiag(offer.epoch, "backfill SKIPPED — a stale offer speaks only for its own records (#102)")
                    }
                    finishCommit(nil)
                } else {
                    self.handbackDiag(offer.epoch, "backfill \(backfill.count) loan-window dose(s) by store identity (e44 boundary)")
                    backfillEarliestStart = backfill.map(\.startDate).min()   // A2: read by finishCommit
                    self.deps.backfillDoses(backfill, finishCommit)
                }
            }
        }
    }

    /// Runs on `queue` after a successful commit. The deferred force-reclaim goes first
    /// (it writes any remaining staged tail itself, now against an up-to-date committedIDs);
    /// then ONE coalesced offer replays — one per completion, so a storm drains serially.
    func drainAfterCommit() {
        if let reason = pendingForceReclaimReason {
            pendingForceReclaimReason = nil
            forceReclaimToOwner(reason: reason)
        }
        if let next = coalescedOffers.popFirst()?.value {
            handleHandbackOffer(next)
        }
    }


    // MARK: - Watch-enacted overrides landing on the phone

    /// Apply (or clear) a watch-enacted override on this phone, idempotently.
    ///
    /// IDEMPOTENCY is by the override's OWN `syncIdentifier` (the UUID `createOverride` minted
    /// on the wrist and the record carried home), not by event bookkeeping alone:
    ///   - `.set` whose syncIdentifier already matches what the phone holds → SKIP. That covers
    ///     the routine replay (the watch resends an offer every 15 s until acked, and a duplicate
    ///     FINAL offer is normal), plus the case where the phone already got the override live
    ///     over the WC settings channel while it happened to be reachable.
    ///   - `.cleared` when the phone already holds nothing → SKIP, so a replayed drain cannot
    ///     "re-clear" — which matters because a re-clear is not harmless: it would cancel an
    ///     override the user set on the PHONE after the loan ended.
    /// The persisted `committedIDs` filter upstream is the second belt (an already-committed
    /// record never reaches the reconciler again); this check is the one that survives even a
    /// staged-state reset, because it compares against live truth rather than history.
    ///
    /// LOGGED BOTH WAYS — os_log locally and `handbackDiag` (which the watch mirrors into the
    /// iCloud session log as `[phone] …`), so a session's override story is legible from the
    /// watch log alone, which is the only log Jeremy reads in the field.
    private func applyWatchOverride(_ change: LoanReconciler.OverrideChange, epoch: Int, isFinal: Bool) {
        let current = deps.scheduleOverride()
        let phase = isFinal ? "final" : "interim"
        switch change {
        case .set(let override):
            guard current?.syncIdentifier != override.syncIdentifier else {
                os_log("[override] from watch: SKIPPED — %{public}@ already applied (sync %{public}@)",
                       log: log, type: .default, Self.overrideNameForLog(override), override.syncIdentifier.uuidString)
                handbackDiag(epoch, "[override] SKIPPED (already applied) \(Self.overrideNameForLog(override))")
                return
            }
            deps.applyScheduleOverride(override)
            let ends = override.duration.isInfinite ? "indefinite" : ISO8601DateFormatter().string(from: override.scheduledEndDate)
            os_log("[override] from watch: APPLIED %{public}@ · insulin needs %.0f%% · target %{public}@ · ends %{public}@ · sync %{public}@ (%{public}@ drain)",
                   log: log, type: .default, Self.overrideNameForLog(override),
                   override.settings.effectiveInsulinNeedsScaleFactor * 100,
                   Self.targetForLog(override), ends, override.syncIdentifier.uuidString, phase)
            handbackDiag(epoch, String(format: "[override] APPLIED %@ · needs %.0f%% · target %@ · ends %@ (%@ drain)",
                                       Self.overrideNameForLog(override),
                                       override.settings.effectiveInsulinNeedsScaleFactor * 100,
                                       Self.targetForLog(override), ends, phase))
        case .cleared:
            guard current != nil else {
                os_log("[override] from watch: SKIPPED clear — the phone holds no override", log: log, type: .default)
                handbackDiag(epoch, "[override] SKIPPED clear (phone already has none)")
                return
            }
            deps.applyScheduleOverride(nil)
            os_log("[override] from watch: CLEARED %{public}@ — phone schedules resolve unscaled again (%{public}@ drain)",
                   log: log, type: .default, current.map(Self.overrideNameForLog) ?? "—", phase)
            handbackDiag(epoch, "[override] CLEARED \(current.map(Self.overrideNameForLog) ?? "—") (\(phase) drain)")
        }
    }

    static func overrideNameForLog(_ override: TemporaryScheduleOverride) -> String {
        switch override.context {
        case .preMeal: return "pre-meal"
        case .activity(let preset): return "\(preset.activityType.symbol) \(preset.activityType.name)"
        case .preset(let preset): return "\(preset.symbol) \(preset.name)"
        case .custom: return "custom"
        }
    }

    private static func targetForLog(_ override: TemporaryScheduleOverride) -> String {
        guard let range = override.settings.targetRange else { return "unchanged" }
        return String(format: "%.0f-%.0f",
                      range.lowerBound.doubleValue(for: .milligramsPerDeciliter),
                      range.upperBound.doubleValue(for: .milligramsPerDeciliter))
    }

    private func finishLoanAfterCommit() {
        // The drain landed — whatever rungs a reclaim tap left armed have nothing left to do, and
        // a resend firing now would push a revoke at a watch that has already handed back.
        cancelReclaimLadder()
        cancelNotification(id: NotificationID.duration)
        cancelNotification(id: NotificationID.paused)
        // GHOST-DRAIN SUPERSESSION (field 2026-08-31 12:44): the loan that just drained
        // can be a reboot-era ghost whose queued FINAL offer outlived the fold — while the
        // LIVE successor loan is streaming. Closing its books is right; resuming custody
        // is theft: the old close reclaimed the pod and R33-canceled the live loan's temp.
        // With fresh newer-epoch evidence in hand: commit stands, audit is moot (it needs
        // the pod, and the pod is the live loan's), custody yields — and dosing STAYS
        // paused (the yield posture re-asserts the pause).
        if supersededByLiveLoan(epoch) {
            let liveEpoch = newestForeignLoanEvidence?.epoch ?? epoch + 1
            pendingRevoke = false
            state = .owner
            staged = [:]
            stagedTombstones = []
            persistStaged()
            pendingHandbackAudit = nil
            UserDefaults.standard.removeObject(forKey: Keys.deliveredAtGrant)
            PhoneLog.event("mirror", "drain e\(epoch) closed UNDER live e\(liveEpoch) — books committed, audit moot, custody NOT resumed [mirror]")
            engageInferredLoanYield(evidence: "superseding loan e\(liveEpoch) streamed during the e\(epoch) drain")
            return
        }
        reclaimPodConnection()
        pendingRevoke = false
        state = .owner
        deps.setAutomaticDosingPaused(false)
        staged = [:]
        stagedTombstones = []
        persistStaged()
        // The +90 s re-audit is GONE from this path (item 1, 2026-08-11). It existed to get a
        // phone-read odometer after a clean hand-back, and `finishPendingHandbackAudit` now does
        // that better: on the verified reclaim round-trip instead of a fixed 90 s guess, so the
        // window can't fold in post-loan phone delivery, and against the same `expected` the
        // reconciler computed rather than the biased continuous estimate. Two audits printing two
        // different answers for one loan is worse than one right answer.
        //
        // It survives on the dead-watch path (reclaimNow → recordsCommitted: false), which has no
        // offer, no deliveredAtStart, and therefore nothing for the pending audit to resolve.
        UserDefaults.standard.removeObject(forKey: Keys.deliveredAtGrant)
    }

    func schedulePostReclaimReAudit(recordsCommitted: Bool) {
        queue.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self = self else { return }
            if let override = self.postReclaimReAudit {
                override()
            } else {
                self.performReAudit(recordsCommitted: recordsCommitted)
            }
        }
    }

    /// The post-reclaim re-audit. DIAGNOSTIC-ONLY: it re-reads
    /// the pod's odometer ~90 s after reclaim and os_log's delivered-vs-expected, but takes
    /// NO user-facing action — the IOB valve and the over/under notices are both disabled
    /// (deferred until a proper warning threshold is chosen). The dose-integrity commit path
    /// and the [phone] reconcile capture at the drain audit are the trustworthy signals; this
    /// is a rough breadcrumb only (its `expected` is the biased continuous estimate and its
    /// late window can fold in post-loan phone delivery).
    private func performReAudit(recordsCommitted: Bool) {
        guard let lendable = deps.pumpManager() as? PumpConnectionLendable,
              let atGrant = UserDefaults.standard.object(forKey: Keys.deliveredAtGrant) as? Double else { return }
        let watchAuditRan = UserDefaults.standard.bool(forKey: Keys.watchAuditRan)

        lendable.refreshLentDeviceStatus { [weak self] success in
            guard let self = self, success else { return }
            self.queue.async {
                guard let now = (self.deps.pumpManager() as? PumpConnectionLendable)?.lentDeviceInsulinDelivered else { return }
                let delivered = now - atGrant

                let expected: Double
                if recordsCommitted, let e = UserDefaults.standard.object(forKey: Keys.expectedUnits) as? Double {
                    expected = e
                } else if let schedule = self.deps.settings().basalRateSchedule, let start = self.loanStartedAt {
                    expected = LoanReconciler.expectedInsulin(events: [], schedule: schedule, from: start, to: self.deps.now())
                } else {
                    return
                }

                let remainder = delivered - expected
                // Re-audit is diagnostic-only (Jeremy 2026-07-27): log the number, take NO user-facing
                // action — no IOB injection ("not adding insulin at hand-back") and no over/under
                // warning (deferred). NOTE this `expected` is the biased continuous estimate and this
                // 90 s-late window can fold in post-loan phone delivery, so it is a rough breadcrumb
                // only — the trustworthy capture is the [phone] reconcile line at the drain audit.
                os_log("Post-reclaim re-audit (diagnostic-only): delivered %.2f, expected %.2f, remainder %.2f (recordsCommitted %d, watchAuditRan %d)",
                       log: self.log, type: .default, delivered, expected, remainder, recordsCommitted ? 1 : 0, watchAuditRan ? 1 : 0)
                if recordsCommitted {
                    UserDefaults.standard.removeObject(forKey: Keys.deliveredAtGrant)
                }
            }
        }
    }

}
