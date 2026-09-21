//
//  PodLoanPhoneController+Mirror.swift
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

    // MARK: - A loan the watch announced (a seized pod)
    //
    // The watch can take the pod from its standing copy while the phone is out of reach. When
    // the watch then SAYS so — a status report, or records from a loan this phone never granted —
    // the phone stands aside exactly as if it had granted it: pill reads Pod on Watch, dosing
    // paused, pod link released. The flag rides .owner because the watch's real epoch is only
    // adopted when its hand-back offer arrives with the seize token (the retro-ack).
    //
    // The phone stands aside on the watch's WORD only. It used to infer a loan from the pod's
    // own evidence too (foreign sessions plus a quiet watch); that inference is gone — on
    // 2026-09-13 it locked the phone out for two hours, and on 2026-09-19 it yielded to a loan
    // that had ended hours earlier and then booked 3.45 U of already-recorded insulin. Like any
    // hold, this one lapses by itself when the watch goes quiet (+Hold.swift).

    /// Fresh evidence that a loan NEWER than `epochN` is live right now.
    func supersededByLiveLoan(_ epochN: Int) -> Bool {
        guard let evidence = newestForeignLoanEvidence, evidence.epoch > epochN else { return false }
        return deps.now().timeIntervalSince(evidence.at) < 600
    }

    /// Both detectors funnel here. Yield is deliberately cheap to enter: it doses nothing,
    /// claims nothing, and every exit is user-driven or evidence-driven.
    func engageInferredLoanYield(evidence: String) {
        guard state == .owner, !yieldingToInferredLoan else { return }
        yieldingToInferredLoan = true
        holdRenewedAt = deps.now()
        holdLapseNoticedAt = nil
        // If this loan has to be taken back unheard, its audit runs from THIS phone's own last
        // pod read — never from an earlier loan's anchors. (Known gap, documented not built: the
        // phone's own temp still running at that read is not counted as expected.)
        if let units = (deps.pumpManager() as? PumpConnectionLendable)?.lentDeviceInsulinDelivered {
            let asOf = deps.pumpManager()?.lastSync ?? deps.now()
            checkpointsThisLoan = 0
            auditBase = AuditBase(units: units, asOf: asOf)
            loanStartedAt = asOf
            UserDefaults.standard.set(asOf, forKey: Keys.loanStartedAt)
        }
        deps.setAutomaticDosingPaused(true)
        // Yield the RADIO too, exactly as a grant does: a yielded phone that keeps its
        // standing connect starves an alive watch's per-cycle reclaims (single-central
        // pod) — authority and radio must travel together. reclaimNow re-arms the bid.
        // The loan interlock comes with the release, as in a grant, and that is right: the
        // veto's one legitimate case is a live watch looping the pod behind a dead WC link,
        // and this phone's five-minute status reads ride the same CGM cadence as the watch's
        // dosing sessions. What must never happen is the interlock outliving the user's way
        // back — and the way back is the tile tap, which now reaches reclaimNow from this
        // posture (uiSnapshot.isLoanedOut) and re-arms the bid, clearing the interlock.
        (deps.pumpManager() as? PumpConnectionLendable)?.releaseConnection()
        syncUIMirror()          // the tile routes its tap on the mirror — sync BEFORE notifying
        deps.ownershipDidChange()
        // Say so. The yield otherwise goes quiet — dosing paused, the loop-failure alerts
        // swept, nothing but the tile — and the only way back is the tile tap.
        deps.issueNotice(
            NSLocalizedString("Pod Looks Controlled by the Watch", comment: "Phone notice title when the phone yields to an inferred watch loan"),
            NSLocalizedString("This phone has paused automatic dosing because the pod appears to be in use by the watch. Tap the pod tile to take it back.", comment: "Phone notice body when the phone yields to an inferred watch loan"))
        PhoneLog.event("mirror", "YIELDING to an inferred loan — \(evidence); pill=Pod on Watch, dosing paused, pod BLE released, exits: pill tap / watch revival / R40(f) prompt (R40(a): on conflict the phone yields) [mirror]")
    }

    /// Every re-arm of the phone's pod bid goes through here.
    func reclaimPodConnection() {
        (deps.pumpManager() as? PumpConnectionLendable)?.reclaimConnection()
    }

    /// Exit bookkeeping. `resumeDosing` stays false on every current path: reclaimNow's
    /// force unpauses in forceReclaimToOwner, the retro-ack keeps the pause because the
    /// loan it adopts is live, and beginGrant re-pauses for its own loan.
    func clearInferredLoanYield(reason: String) {
        guard yieldingToInferredLoan else { return }
        yieldingToInferredLoan = false
        syncUIMirror()
        deps.ownershipDidChange()
        PhoneLog.event("mirror", "inferred-loan yield CLEARED — \(reason) [mirror]")
    }

    func abortGrant(reason: String) {
        // The refusal travels to the WATCH, which is where the user just tapped Start and is
        // still looking; the phone posts nothing. Reasons here are internal encoding failures
        // the user cannot act on, and the pod never left the phone.
        os_log("Grant aborted: %{public}@", log: log, type: .error, reason)
        sendMessage(.denied(LoanDenied(reason: "The loan could not start (\(reason)). The phone kept the pod.")))
        reclaimToOwner(alert: nil, reason: "grant ABORTED before it left the phone: \(reason)")
    }

    /// T1: 5 min start-confirmation, cancelled by TakeoverComplete. Row 4:
    /// query-before-reclaim — a watch whose TakeoverComplete was lost gets one chance
    /// to prove it holds the pod before auto-reclaim.
    /// How long to wait before ASKING whether the hand-over arrived. Not how long to wait
    /// before acting — those got conflated, and only the acting needed to be patient.
    ///
    /// A normal takeover completes in ~13 s, so by 20 s a healthy loan has
    /// already left `.grantOffered` and this never fires. A slow-but-fine takeover answers
    /// "yes I have the grant" and nothing happens. Only an explicit "I never got it" acts.
    private static let grantLostProbeDelay: TimeInterval = 20


    /// Probe once, early, for a hand-over that never landed.
    ///
    /// The failure it catches: the phone has already stopped dosing and already released the pod
    /// (it must, so the watch can take it) when the grant is lost in transit. Nobody then holds
    /// the pod. It keeps delivering its last program on its own — no hazard — but no loop is
    /// adjusting anything on either device, and that used to last 5 min 15 s.
    ///
    /// Seen in the field when Start is tapped seconds after an install, before the watch
    /// messaging channel has finished waking.
    ///
    /// SILENCE IS NOT "NO". An unreachable watch that is perfectly fine and mid-takeover looks
    /// identical, from here, to a watch that never heard anything. So this only sends a question;
    /// the answer path (handleStatusReport) acts on an explicit `knowsGrant == false` and nothing
    /// else. No answer ⇒ the original 5-minute timer runs exactly as before.
    private func armGrantLostProbe(for grantEpoch: Int) {
        queue.asyncAfter(deadline: .now() + Self.grantLostProbeDelay) { [weak self] in
            guard let self = self, self.state == .grantOffered, self.epoch == grantEpoch else { return }
            self.handbackDiag(grantEpoch, String(format: "grant unconfirmed after %.0fs — asking the watch whether it arrived (#108)", Self.grantLostProbeDelay))
            // EVIDENCE-KEYED WEDGE ALERT (2026-08-21). This is the replacement the removed
            // grant gate's comment asked for: never BLOCK on isWatchAppInstalled (it lies, and
            // blocking on it refused three Start taps against a live link on 2026-08-19), but
            // when the grant has ALREADY gone unconfirmed for 20 s AND the flag is false, those
            // are two independent symptoms of the same wedge — WCSession queueing everything we
            // send. The watch cannot see this flag; only the phone can, so only the phone can
            // tell the user. The reliable field remedy is a Bluetooth toggle on this phone.
            // Reconciled to Caitlin's line 2026-09-09: the one-way-wedge evidence is logged, not
            // posted as a notice.
            if !self.deps.watchAppInstalled() {
                self.handbackDiag(grantEpoch, "grant unconfirmed AND isWatchAppInstalled=false — one-way wedge signature")
            }
            self.sendMessage(.statusQuery(StatusQuery(epoch: grantEpoch)))
        }
    }

    func armT1(for grantEpoch: Int) {
        // STAMPED PER GRANT, unconditionally. The old `if grantOfferedAt == nil` guard meant a
        // FAILED takeover — which never clears this — leaked its anchor into the next grant, so
        // the elapsed this feeds kept growing across attempts: field 2026-08-17, e59 reported
        // "takeover IN PROGRESS at +145s" 21 s after its own grant, quoting e58's clock.
        //
        // Historically that was not just a wrong number in a log line: the elapsed was compared
        // against a ceiling that decided whether to extend the dead-man, so the longer a session
        // ran, the sooner its takeovers were abandoned. The extension was removed 2026-09-09;
        // the anchor now feeds the diagnostic line only.
        //
        // NOW A FALLBACK (2026-08-20). The grant path stamps this at the DECISION instead — armT1
        // runs at the end of a deep async chain, and a watch that answers before the chain lands used
        // to find it nil and report "+0s". Overwriting here would push the anchor forward by
        // however long the snapshot took and re-open that window, so this only fills a genuine gap:
        // the relaunch re-arm, where the state is restored from disk but this in-memory stamp is not.
        // The per-grant reset that made the write unconditional now happens at the decision point,
        // so a failed takeover's clock still cannot follow the next grant.
        if grantOfferedAt == nil { grantOfferedAt = deps.now() }
        armGrantLostProbe(for: grantEpoch)
        // Pre-scheduled, so its text is fixed FIVE MINUTES before it lands and cannot describe
        // anything that happens in between. It therefore states only what is certain at the
        // fire instant — no confirmation has arrived — and the phone's INTENT, not a completed
        // act. The reclaim itself runs 15 s later, and only when the app is awake to run the
        // work item; the suspended-app case this dead-man exists for is precisely where a
        // "the phone reclaimed it" claim would be false, potentially for a long time.
        scheduleNotification(id: NotificationID.t1, title: "Watch Loan Not Confirmed",
                             body: "The watch hasn't confirmed taking the pod. The phone will take it back.",
                             delay: .minutes(5), repeats: false)
        t1WorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .grantOffered, self.epoch == grantEpoch else { return }
            self.sendMessage(.statusQuery(StatusQuery(epoch: grantEpoch)))
            let confirm = DispatchWorkItem { [weak self] in
                guard let self = self, self.state == .grantOffered, self.epoch == grantEpoch else { return }
                // Reclaims silently: the watch never confirmed, so in the common case nothing
                // ever left the phone and there is nothing for the user to do. The phone's own
                // pill already shows it holds the pod.
                self.reclaimToOwner(alert: nil, reason: "dead-man T1 expired — the watch never confirmed the takeover")
            }
            self.t1WorkItem = confirm
            self.queue.asyncAfter(deadline: .now() + 15, execute: confirm)
        }
        t1WorkItem = work
        queue.asyncAfter(deadline: .now() + .minutes(5), execute: work)
    }

    func handleTakeoverComplete(_ complete: TakeoverComplete) {
        guard complete.epoch == epoch, state == .grantOffered else { return }
        noteHoldRenewal(sentAt: complete.firstPodStatus.timestamp)
        grantOfferedAt = nil
        t1WorkItem?.cancel()
        cancelNotification(id: NotificationID.t1)
        // Bank the watch's post-takeover odometer NOW, while the watch is alive to send it.
        // This is what lets the end-of-loan audit run even if the watch is dead by then — the
        // normal audit's baseline arrives in the hand-back offer, which a dead watch never sends.
        if let atTakeover = complete.firstPodStatus.deliveredUnits {
            UserDefaults.standard.set(atTakeover, forKey: Keys.deliveredAtTakeover)
            // Re-anchor the audit base on the watch's post-takeover pair — the reading every
            // window audit measures from, stamped by the same clock as the records.
            auditBase = AuditBase(units: atTakeover, asOf: complete.firstPodStatus.timestamp)
        }
        state = .loaned
        // No 6-hour duration notice. It was armed unconditionally the instant a takeover
        // succeeded, with no fault predicate and no loan cap anywhere in this file — so its
        // only condition was "Sport Mode is still working six hours later", i.e. it alarmed on
        // success. A long ride is a choice, not a fault. Every real failure mode during a loan
        // has its own signal on the WATCH, which is the device in a position to know.
        // The cancel sites below are left in place so an upgrade retires any rung a previous
        // build already scheduled.

        // No on-loan notification. One existed here — a designed-silent notice carrying the
        // bench-era escape-hatch action — until the blanket foreground-banner change promoted
        // it to a banner announcing what the pump tile already says. Field-ruled clutter, and
        // its escape-hatch role was superseded by the real UI (the tile's reclaim affordances)
        // long ago, as its own comment admitted.
    }

    func handleTakeoverFailed(_ failed: TakeoverFailed) {
        guard failed.epoch == epoch, state == .grantOffered else { return }
        t1WorkItem?.cancel()
        cancelNotification(id: NotificationID.t1)
        // Silent: the watch reported this failure, so the wrist the user is looking at already
        // shows the reason in its idle note — with better wording and the retry affordance the
        // phone banner lacked. iOS mirrors phone notices to that same wrist, so posting here put
        // the worse copy on top of the better one.
        reclaimToOwner(alert: nil, reason: "watch reported takeover FAILED: \(failed.reason)")
    }

    func handleStatusReport(_ report: StatusReport) {
        // PHONE MIRROR detector C (before the epoch guard — a foreign-epoch report is the
        // whole point): the watch says outright that it holds the pod on a loan ahead of
        // ours. Sent at the reunion prompt and at Keep, so the yield no longer waits for
        // dose-stream evidence that only flows when the loop happens to enact — and it
        // converts the 2026-08-31 phantom-grant standoff (query → silence → force-steal)
        // into query → answer → yield, once epochs are honest (fix 4).
        if report.holdsPod, report.epoch > epoch {
            if newestForeignLoanEvidence.map({ report.epoch >= $0.epoch }) ?? true {
                newestForeignLoanEvidence = (report.epoch, deps.now())
            }
            let hasCredential = UserDefaults.standard.string(forKey: Keys.dormantSeizeToken) != nil
            switch state {
            case .owner where hasCredential:
                engageInferredLoanYield(evidence: "statusReport — watch holds the pod on e\(report.epoch)")
            case .grantOffered where hasCredential:
                // GHOST-GRANT ABANDON (field 2026-08-31 21:21): a queued request detonated at
                // reunion and this phone granted e276 against a live seized e277 — then sat on
                // "Handing over…" awaiting a takeoverComplete the watch's wrong-phase refusal
                // guarantees will never come. The watch now answers that refusal (and the +20s
                // #108 probe, and stale revokes) with this report: the grant can never confirm,
                // so stop waiting on it and enter the posture the evidence says is true. The
                // burned epoch stays burned — the retro-ack adopts forward exactly as tape
                // proved (276→277), and the T1 dead-man is cancelled WITH the wait it timed.
                t1WorkItem?.cancel()
                cancelNotification(id: NotificationID.t1)
                handbackDiag(epoch, "ghost grant e\(epoch) ABANDONED — the watch answered holdsPod e\(report.epoch); yielding instead of waiting on a takeover that cannot come [mirror]")
                state = .owner
                engageInferredLoanYield(evidence: "statusReport — watch holds e\(report.epoch), ghost grant abandoned")
            case .reclaimPending:
                // RE-AIM (same field episode, 21:24): the ladder's revoke named this phone's
                // stale epoch, the watch refused it as matching no live session, and the ladder
                // read refusal as death and force-stole a live loan's pod. The report names the
                // real loan — spend the ladder's remaining attempt on it. The force rung stays
                // armed behind this, unchanged, for a watch that goes quiet after answering.
                if var ladder = reclaimLadder, !ladder.forced, ladder.attempts < 2 {
                    sendMessage(.revoke(Revoke(epoch: report.epoch)))
                    ladder.attempts += 1
                    reclaimLadder = ladder
                    handbackDiag(epoch, "reclaim revoke RE-AIMED at e\(report.epoch) (attempt \(ladder.attempts) of 2) — the watch holds a newer loan than the one this reclaim named")
                }
            default:
                break
            }
        }
        guard report.epoch == epoch else { return }
        // Row 4: the query-before-reclaim answer.
        if state == .grantOffered, report.holdsPod {
            handleTakeoverComplete(TakeoverComplete(epoch: report.epoch, firstPodStatus: LoanPodStatus(timestamp: deps.now(), deliveredUnits: nil, reservoirLevel: nil, isSuspended: false, faultCode: report.podFault)))
        }
        // The watch says outright that the hand-over never reached it. Take the pod back
        // now rather than in five more minutes — the phone released it for a takeover that is
        // never going to start, so every second after this answer is time nobody is looping.
        //
        // `== false` deliberately, not `!= true`: nil is an older build that could not answer, and
        // must fall through to the 5-minute timer. Only an explicit denial acts.
        // TAKEOVER IN PROGRESS: the watch has the grant and is working on it, but does not hold
        // the pod yet — the third answer the protocol distinguishes (see `knowsGrant`).
        // The dead-man EXTENSION this used to grant was REMOVED 2026-09-09 (Jeremy: "the vast
        // majority of takeovers are fast now, that seems redundant"), matching Caitlin's line,
        // which arms T1 once. History so the trade-off is not re-litigated blind: it existed
        // because takeovers on this branch once ran 190-265 s against a 5-minute dead-man, and
        // one overran it — the phone reclaimed while the watch took over successfully, both
        // believed they owned the pod, and the phone then denied every later loan because its own
        // reclaim could never verify. Unrecoverable without ending the loan from the wrist.
        // Measured takeovers 2026-09-08/09: 8-57 s, so the margin is now wide.
        //
        // The report is still LOGGED — its elapsed is the observable for the grant-anchor
        // regression test (testANewGrantDoesNotInheritAFailedTakeoversClock).
        if state == .grantOffered, report.knowsGrant == true, !report.holdsPod {
            let elapsed = grantOfferedAt.map { deps.now().timeIntervalSince($0) } ?? 0
            handbackDiag(report.epoch, String(format: "takeover IN PROGRESS on the watch at +%.0fs — the 5-minute dead-man runs unchanged", elapsed))
        }
        if state == .grantOffered, report.knowsGrant == false, !report.holdsPod {
            handbackDiag(report.epoch, "grant CONFIRMED LOST by the watch — reclaiming now instead of waiting out the 5-minute timer (#108)")
            t1WorkItem?.cancel()
            cancelNotification(id: NotificationID.t1)
            // Tell the WATCH, don't post on the phone. Deleting the phone banner outright would
            // be wrong here: without a .denied the wrist falls through to its request-timeout
            // note ("No response from iPhone"), which is FALSE in this case — the phone answered,
            // it was the grant that went missing — and points the user at the wrong device.
            // With the reason routed, the glance shows it where the user is already looking.
            sendMessage(.denied(LoanDenied(reason: "The hand-over never reached the watch. The phone kept the pod. Tap Start again.")))
            reclaimToOwner(alert: nil, reason: "grant CONFIRMED LOST by the watch")
        }
        if report.podFault != nil {
            // No notice. This line could never do what its title claimed: a StatusReport is only
            // solicited while state == .grantOffered, so a fault occurring DURING the loan never
            // reaches here — it was the appearance of pod-fault coverage, not coverage. The real
            // gap is that the watch holds the pod and its own alert path for pod faults is a
            // log-only stub; that is where the signal has to be built, not here.
            handbackDiag(report.epoch, "pod fault reported in a status report — logged only; the watch owns pod-fault surfacing during a loan")
        }
    }

}
