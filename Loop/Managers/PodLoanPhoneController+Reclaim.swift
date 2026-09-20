//
//  PodLoanPhoneController+Reclaim.swift
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

    // MARK: Reclaim settle window (post-hand-back "Reclaiming…" until the pod is truly back)

    static let reclaimSettleTimeout: TimeInterval = .minutes(5)
    /// The settle bar's single-stage promise, watch-present and watch-initiated alike.
    ///
    /// This replaced a two-stage bar (12 s, then a 105 s re-baseline) that was calibrated to a
    /// BIMODAL distribution: across 91 verified reclaims, 70 landed in 1-11 s and 21 in
    /// 24-190 s with nothing between. The slow mode then turned out not to be radio physics at
    /// all — the verification call skips the radio whenever the manager judges its pump data
    /// fresh (under 6 minutes) and returns the old lastSync, which the settle rejects forever;
    /// one field settle burned 77 such calls over 167 s. With the forced read in place, every
    /// settle measured on the fixed build finished in 1-3 s with zero stale reads (six samples:
    /// one forced, two phone-tap, three watch-End), and end-to-end tap-to-verified ran
    /// 3.2-7.1 s. Ten seconds covers the worst of those by 40%.
    ///
    /// The slow mode has existed and could recur (one afternoon of clean samples is evidence,
    /// not proof; a reclaim during an in-flight G7 acquisition is still unsampled). If it does,
    /// the bar holds at the 0.95 cap with the elapsed seconds climbing — nearly-done and
    /// visibly alive — under the unchanged 5-minute ceiling. Ruled in the field: an
    /// occasionally-wrong promise beats a re-baseline that reads as a second failure.
    static let reclaimSettleExpectation: TimeInterval = 10


    /// Grace period before a stalled reclaim escalates from the manager's gentle reconnect to its
    /// scan-and-adopt. 20s because the takeover budget calls a connect "typically ~17s": inside
    /// that, a normal reconnect is still landing and escalating would only add radio contention;
    /// past it, waiting is not working. Field settles that stalled ran 224.2s and 237.0s.
    /// Lean 2026-08-24: 20 → 12 s. Since the reclaim dials at re-arm (skipDiscovery), measured
    /// link-up runs 0.0–8.8 s; twelve covers the worst by a third. Elapsed time stays the
    /// trigger because this escalation exists ONLY for the link-never-came-up case, where there
    /// are no failed reads to count — absence is the only evidence there is.
    private static let reclaimEscalateAfter: TimeInterval = 12

    static let requestDedupeWindow: TimeInterval = .minutes(2)
    /// How old a request may be (by its own sentAt stamp) and still earn a grant. The watch
    /// gives up on a request in ≤25 s; anything older arriving here rode the queued channel
    /// and its sender has long moved on. 90 s = the timeout with generous transit slack.
    static let requestTTL: TimeInterval = 90

    /// reclaimConnection() only re-arms the BLE bid; the actual reconnect lands
    /// seconds-to-minutes later. Open a bounded window so the tile keeps showing "Reclaiming…"
    /// until the pod is genuinely reachable, without ever sticking (the ceiling clears it).
    /// Runs on `queue` (state is queue-confined, as the sync accessors below assume).
    ///
    /// The window also CHASES completion instead of waiting for it. Left alone, the
    /// first post-reclaim pod round-trip is whenever the phone's 5-minute cycle next runs —
    /// or, on a locked phone, whenever iOS feels like it (one hand-back completed the moment
    /// an unrelated notification woke the phone). ensureCurrentPumpData is fired as soon as
    /// the link is up, so "returned" happens in seconds when the phone is awake instead of
    /// minutes by accident.
    func beginReclaimSettleWindow() {
        let started = deps.now()
        reclaimStartedAt = started
        reclaimEscalated = false
        reclaimVerifiedAt = nil
        syncUIMirror()
        reclaimVerifyInFlight = false
        reclaimLinkUpAt = nil
        reclaimStaleReads = 0
        // Keep a RECENT tap anchor so the bar continues across the handover-to-settle boundary
        // instead of restarting; adopt the settle's own start otherwise. The 60 s staleness
        // bound is structural protection: an anchor left behind by an abandoned reclaim must
        // never stretch a later, unrelated settle's bar.
        if let anchor = reclaimDisplayAnchor, started.timeIntervalSince(anchor) < 60 {
            // continuous bar from the user's tap
        } else {
            reclaimDisplayAnchor = started
        }
        // Re-begin rather than assume the tap's hold is still alive: the watch-initiated route
        // has no tap, and re-beginning is stock's own idiom (end-then-begin, one identifier).
        deps.beginReclaimBackgroundTask()
        reclaimSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.reclaimStartedAt == started else { return }
            os_log("Reclaim settle CEILING reached (%.0fs) without a verified round-trip — clearing anyway",
                   log: self.log, type: .error, Self.reclaimSettleTimeout)
            // ALSO to the FILE log, with the radio's own account of the window.
            //
            // This is the line whose absence made the stalled settle undiagnosable: the ceiling
            // reported only through os_log, so the file logs showed the settle simply stopping
            // mid-sentence — `settle: link up +0.0s` and then nothing, for two separate epochs.
            // The BLE trail says whether the link was ever really up, how often it flapped, and
            // what refused a connect, none of which the settle's own polling can see.
            let ble = (self.deps.pumpManager() as? PumpConnectionLendable)?.connectionDiagnostics()
            self.handbackDiag(self.epoch, String(
                format: "settle CEILING at %.0fs — NO verified round-trip; clearing anyway · ble: %@",
                Self.reclaimSettleTimeout, ble ?? "no diagnostics from the pump manager"))
            self.reclaimStartedAt = nil            // ceiling reached — stop settling
            self.syncUIMirror()
            self.reclaimDisplayAnchor = nil
            self.deps.endReclaimBackgroundTask()
            // A force-reclaim audit that never got its round-trip is an UNVERIFIED
            // session, and dosing is still held from the reclaim. Unverified opens; it never
            // quietly resumes.
            if let pending = self.pendingHandbackAudit, pending.flavor == .forceReclaim {
                self.pendingHandbackAudit = nil
                self.handbackDiag(pending.epoch, "** R37: audit NEVER RAN — pod unreachable through the settle window. Session UNVERIFIED, loop OPENS **")
                self.deps.setAutomaticDosingPaused(false)
                self.deps.openLoopForUncertainReconciliation()
                self.armOpenLoopReminder()
                // One text for all three unverified outcomes (see Self.sessionUnverifiedBody):
                // pod never answered, answered without a total, or no baseline to compare
                // against. The difference is internal cause; the user's situation and the one
                // thing they can do about it are identical in all three.
                self.deps.issueUrgentNotice("Watch Session Unverified", Self.sessionUnverifiedBody)
            }
            self.deps.ownershipDidChange()         // final re-render that clears the tile
        }
        reclaimSettleWork = work
        // Wall clock for the same reason as the ladder rungs: a suspension must not stretch
        // the ceiling past its promise.
        queue.asyncAfter(wallDeadline: .now() + Self.reclaimSettleTimeout, execute: work)
        chaseReclaimVerification(started: started)
    }

    /// Poll on `queue` every 2 s: once the link is up, do ONE pod round-trip and mark the
    /// reclaim verified when it lands. Self-cancelling when superseded (a new settle window,
    /// the ceiling, or a grant taking us out of .owner).
    private func chaseReclaimVerification(started: Date, attempt: Int = 0) {
        guard reclaimStartedAt == started, reclaimVerifiedAt == nil else { return }
        // Stamp the link-up edge exactly once. Everything before it is the peripheral coming
        // back; everything after it is us failing to get a word in over a link that is already
        // up. The tick number rides along because a slow link and a slow FIRST poll look
        // identical in an elapsed time on its own.
        if reclaimLinkUpAt == nil, deps.isConnectionReady() {
            let up = deps.now()
            reclaimLinkUpAt = up
            let waited = up.timeIntervalSince(started)
            // handbackDiag, not a bare diag send: the dead-watch force reclaim is the case
            // that most needs this line, and that is exactly the case where the watch-bound
            // diag channel queues until the watch returns — the first field run of this
            // instrumentation (2026-08-14) left the phone's own file with no settle record
            // at all. The phone file must carry its own account.
            handbackDiag(epoch, String(format: "settle: link up +%.1fs (tick %d)", waited, attempt))
        }
        // The link has NOT come up and the grace period is gone: stop waiting to hear the pod
        // and go looking for it. `reclaimConnection()` only re-armed a bare pending-connect, which
        // against an idle pod is probabilistic; the scan-and-adopt this escalates to is what the
        // takeover path uses. Once per settle, and never once the link is up — at that point the
        // pod is back and the remaining wait is getting a word in, which a scan would not help.
        if reclaimLinkUpAt == nil, !reclaimEscalated,
           deps.now().timeIntervalSince(started) >= Self.reclaimEscalateAfter,
           let lendable = deps.pumpManager() as? PumpConnectionLendable {
            reclaimEscalated = true
            let bleBefore = lendable.connectionDiagnostics() ?? "none"
            let outcome = lendable.escalateConnectionReclaim() ?? "the pump manager had nothing to escalate"
            handbackDiag(epoch, String(format: "settle: link still down at +%.0fs — escalating: %@ · ble before: %@",
                                       deps.now().timeIntervalSince(started), outcome, bleBefore))
        }
        // ALWAYS a real round-trip — the cheap call does not always talk to the pod at all
        // (`ensureCurrentPumpData` skips the radio on data under 6 min old and returns the
        // existing lastSync, which the `lastSync > started` test rejects forever; field
        // 2026-08-14: 77 such calls in a row, settle stuck 169 s). The forced/cheap split and
        // its 12 s spacing were sized for a settle that could run minutes; with the reclaim
        // dialing at re-arm (2026-08-23) every measured settle verifies on the FIRST read
        // after link-up, so the spacing machinery guarded radio time no settle spends anymore.
        // The `reclaimVerifyInFlight` latch is the remaining (sufficient) throttle.
        attemptReclaimVerificationNow(started: started, forced: true)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.chaseReclaimVerification(started: started, attempt: attempt + 1)
        }
    }

    /// One verification attempt, no rescheduling. Also called EAGERLY from the grant-deny
    /// path: a premature Start is the strongest possible signal the user wants the pod back,
    /// so their tap accelerates the very check their retry is waiting on — and forces a real
    /// read, for the same reason their tap on the pod status screen ends a stalled settle.
    ///
    /// `forced` routes through `refreshLentDeviceStatus`, which bypasses the freshness
    /// optimization; the cheap path is left for the ticks in between.
    func attemptReclaimVerificationNow(started: Date, forced: Bool = true) {
        guard reclaimStartedAt == started, reclaimVerifiedAt == nil else { return }
        if deps.isConnectionReady(), !reclaimVerifyInFlight, let pump = deps.pumpManager() {
            reclaimVerifyInFlight = true
            let read: (@escaping (Date?) -> Void) -> Void
            if forced, let lendable = pump as? PumpConnectionLendable {
                // Force the round-trip, then ask the ordinary way for the answer. The forced
                // read updates the manager's report date, so the follow-up takes the cheap
                // no-radio path and hands back the NOW-ADVANCED lastSync — one round-trip, and
                // the verification still keys on the completion's date rather than on a
                // property read, which is the contract the rest of this method is written to.
                read = { done in
                    lendable.refreshLentDeviceStatus { _ in pump.ensureCurrentPumpData { done($0) } }
                }
            } else {
                read = { done in pump.ensureCurrentPumpData { done($0) } }
            }
            read { [weak self] lastSync in
                guard let self = self else { return }
                self.queue.async {
                    self.reclaimVerifyInFlight = false
                    guard self.reclaimStartedAt == started, self.reclaimVerifiedAt == nil else { return }
                    // lastSync only advances on a SUCCESSFUL pod comms round-trip, so
                    // lastSync > started is the proof the pod is genuinely home. A stale
                    // date means the read failed — keep chasing until the ceiling.
                    if let sync = lastSync, sync > started {
                        let elapsed = self.deps.now().timeIntervalSince(started)
                        self.reclaimVerifiedAt = self.deps.now()
                        self.reclaimSettleWork?.cancel()
                        self.reclaimStartedAt = nil
                        self.syncUIMirror()
                        self.reclaimDisplayAnchor = nil
                        self.deps.endReclaimBackgroundTask()
                        // Split the wait. A missing link stamp means the link and the read
                        // landed inside one tick, so charge the whole thing to the link rather
                        // than inventing a read time.
                        let linkWait = self.reclaimLinkUpAt.map { $0.timeIntervalSince(started) } ?? elapsed
                        let readWait = max(elapsed - linkWait, 0)
                        // handbackDiag = the phone's own file AND the watch-bound diag echo. The
                        // leading phrase is unchanged on purpose: 91 historical samples are
                        // parsed off it, so the split appends rather than replaces.
                        self.handbackDiag(self.epoch,
                            String(format: "reclaim VERIFIED — pod round-trip complete +%.0fs (link +%.1fs, stale reads %d, read +%.1fs)",
                                   elapsed, linkWait, self.reclaimStaleReads, readWait))
                        self.deps.ownershipDidChange()
                        // The pod is provably reachable RIGHT NOW. This is the only moment in the
                        // whole hand-back where that is true, so it is where both jobs that need
                        // the pod happen: read the real end-of-loan odometer, and cancel the temp
                        // the watch left running.
                        self.finishPendingHandbackAudit(elapsed: elapsed)
                    } else {
                        // The link was up enough to attempt a read and the read still did not
                        // advance lastSync. Counting these is the whole point: a slow settle
                        // with zero of them is the pod failing to come back, and a slow settle
                        // with several is the pod being back and refusing to answer.
                        self.reclaimStaleReads += 1
                        os_log("Settle: status read %d did not advance lastSync — link %{public}@",
                               log: self.log, type: .default, self.reclaimStaleReads,
                               self.reclaimLinkUpAt == nil ? "still down" : "already up")
                        // Phone file only — no diag: a slow settle produces ~30 of these on a
                        // 2 s tick, and flooding the queued channel at a dead watch buys
                        // nothing. Their timing says when the reads started failing and when
                        // they stopped, which the end-of-settle count alone cannot.
                        PhoneLog.event("loan", String(format: "e%d settle: read %d stale — link %@",
                                                      self.epoch, self.reclaimStaleReads,
                                                      self.reclaimLinkUpAt == nil ? "still down" : "already up"))
                    }
                }
            }
        }
    }

    /// The two things that require a live pod link at the end of a loan, done at the one instant
    /// we know we have one: the verified reclaim round-trip.
    ///
    /// 1. THE AUTHORITATIVE AUDIT. `ensureCurrentPumpData` just completed a real conversation with
    ///    the pod, so `lentDeviceInsulinDelivered` is the odometer as of seconds ago. Paired with
    ///    `deliveredAtStart` — which still comes from the WATCH's post-takeover read, the one
    ///    odometer reading the watch takes while it definitely holds the link — that is a clean
    ///    measurement of the loan's whole delivery, bracketed by two fresh readings.
    ///
    /// 2. THE INHERITED TEMP. No automatic program crosses the boundary. The watch cannot
    ///    enforce that (no link); the phone can, and does it here with stock's bare-`.cancel`
    ///    idiom. The pod falls back to the user's schedule until the phone's next reading.
    ///
    /// Audit first, then cancel: the reading must describe the loan, not the cancel. (A cancel
    /// delivers nothing, so this is about clarity of the number rather than its value — and if the
    /// cancel fails we still have the measurement.)
    ///
    /// Bounded and self-cleaning: `pendingHandbackAudit` is consumed on the first call, and if the
    /// reclaim never verifies, the settle ceiling drops it. A loan that ends with the pod
    /// unreachable simply keeps the provisional line — which is what we had before.
    func finishPendingHandbackAudit(elapsed: TimeInterval) {
        defer { clearAuditAnchors() }   // the pod is home: whatever this loan's audit was, it is spent
        guard let pending = pendingHandbackAudit else { return }
        pendingHandbackAudit = nil

        if let latest = (deps.pumpManager() as? PumpConnectionLendable)?.lentDeviceInsulinDelivered {
            // The VERDICT residual is window-scoped: [audit base → this reading]. With no
            // checkpoints the base is the takeover anchor and this is the whole loan.
            // Quantized to milli-units BEFORE the band comparisons: e223 (2026-08-26) opened
            // the loop on "+0.200 exceeds +0.20" because 2.400−2.200 is 0.20000000000000018
            // in binary — the boundary must turn on the pulse grid, never on float dust.
            let delivered = latest - pending.deliveredAtStart
            let residual = ((delivered - pending.expected) * 1000).rounded() / 1000
            // The whole-loan companions: what the bank and the drift tripwire read, so the
            // residual series keeps one meaning across the checkpoint change.
            let loanDelivered = pending.takeoverUnits.map { latest - $0 }
            let loanResidual: Double? = {
                guard let d = loanDelivered, let e = pending.wholeLoanExpected else { return nil }
                return d - e
            }()
            // `drift` is the whole point of the change: how much delivery the watch's stale
            // endpoint was missing. If this is reliably ~0 the watch's reading was fine after all
            // and this machinery can go; if it is a temp's worth, every earlier residual we
            // puzzled over was measuring the wrong interval.
            let drift = pending.watchLatest.map { latest - $0 }
            handbackDiag(pending.epoch, String(format:
                "reconcile[%@]: delivered=%.3f expected=%.3f residual=%+.3f (tol 0.05) · loan total %@ resid %@ · %d checkpoint(s) · loanMin=%.0f cycles=%d · odometer read by PHONE +%.0fs after reclaim · vs watch endpoint %@ (watch fresh=%@)",
                pending.flavor == .forceReclaim ? "FORCE-RECLAIM" : "AUTHORITATIVE",
                delivered, pending.expected, residual,
                loanDelivered.map { String(format: "%.3f", $0) } ?? "n/a",
                loanResidual.map { String(format: "%+.3f", $0) } ?? "n/a",
                checkpointsThisLoan,
                pending.loanMinutes, pending.cycles, elapsed,
                drift.map { String(format: "%+.3f", $0) } ?? "n/a",
                pending.watchFreshened ? "Y" : "N"))
            UserDefaults.standard.set(loanDelivered ?? delivered, forKey: Keys.deliveredAuthoritative)
            // The slow-drip tripwire: windows individually clean, loan total not. Never an
            // action — quantization drift is same-signed too and the one field-observed
            // systematic case erred conservative. Visibility only.
            if let lr = loanResidual, abs(lr) > 0.5, abs(residual) <= Self.checkpointBand {
                handbackDiag(pending.epoch, String(format:
                    "** [checkpoint] loan-total residual %+.3f U exceeds ±0.5 while every window reconciled — possible systematic drip; diagnostic only **", lr))
            }
            switch pending.flavor {
            case .handback:
                // BANKED ONLY ON A CLEAN HAND-BACK (2026-08-13). The bank exists to describe the
                // residual of a loan whose records are COMPLETE, because that is the distribution
                // the ±0.20 U bounds are calibrated against. A force-reclaim's residual measures
                // the opposite — a dead watch's missing records — so banking it poisons the very
                // statistics the next threshold review reads: two of them (+0.800, +0.850) had
                // already moved the banked max from +0.000 to +0.850. Force-reclaim residuals stay
                // visible in the reconcile[FORCE-RECLAIM] line above; they just are not evidence
                // about hand-backs. Consequence, intended: a force-reclaim audit prints no bank
                // line, so the "N more for a re-review" countdown counts clean samples only.
                // The bank keeps its pre-checkpoint meaning — the WHOLE loan's residual —
                // so the drift-trend series stays one distribution. Identical to `residual`
                // whenever no checkpoint advanced the base. The VERDICT is window-scoped.
                bankResidual(loanResidual ?? residual,
                             worstWindow: max(worstWindowThisLoan, abs(residual)),
                             epoch: pending.epoch)
                applyReconciliationVerdict(residual: residual, epoch: pending.epoch)
            case .forceReclaim:
                applyForceReclaimVerdict(residual: residual, epoch: pending.epoch)
            }
        } else if pending.flavor == .forceReclaim {
            // A verified round-trip that reports no odometer cannot verify the session.
            // Unverified is not clean — open, loudly.
            handbackDiag(pending.epoch, "** R37: reclaim round-trip landed but no odometer — session UNVERIFIED, loop OPENS **")
            deps.setAutomaticDosingPaused(false)
            deps.openLoopForUncertainReconciliation()
            armOpenLoopReminder()
            deps.issueUrgentNotice("Watch Session Unverified", Self.sessionUnverifiedBody)
        } else {
            handbackDiag(pending.epoch, "reconcile[AUTHORITATIVE]: pod reachable but reported no odometer — keeping the provisional line")
        }

        // Cancel the watch's temp now that we can actually reach the pod.
        deps.cancelTempBasalAfterPodReturn { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    // Diagnostic, not a stall: the phone's next reading (≤5 min) supersedes the
                    // temp anyway, and until then the pod runs the watch's last automatic rate —
                    // which was computed from real CGM data minutes ago, not a wild value.
                    self.handbackDiag(pending.epoch, "R33 temp cancel FAILED — pod keeps the watch's temp until the next cycle · \(String(describing: error))")
                } else {
                    self.handbackDiag(pending.epoch, "R33 temp cancelled — pod reverts to the user's schedule until the phone's next reading")
                }
            }
        }
    }


    // MARK: - Reclaim ladder (2026-08-13)

    /// The state of a tapped reclaim: which branch the evidence chose, when it started, and the
    /// two deadlines it is running to. One ladder at a time; nil means no reclaim is in flight.
    struct ReclaimLadder {
        enum Branch: String { case live = "LIVE", dead = "DEAD" }
        var branch: Branch
        let startedAt: Date
        /// The rung that resends the revoke — the second and last attempt.
        var resendAt: Date
        /// The rung that gives up on the watch and takes the pod back.
        var forceAt: Date
        /// Revokes sent for this reclaim, counting the one the tap itself sent. Capped at two:
        /// a retry exists for a watch that is merely asleep, and a third would only delay the
        /// force. Any resend counts — including the one a reachability change fires.
        var attempts: Int
        /// The force rung has run. NOT the same as finished: a force lands on
        /// `pendingForceReclaimReason` when a hand-back commit is mid-write, so this ladder can
        /// outlive its own last rung and must keep describing the situation until state moves.
        var forced: Bool
        var phase: ReclaimProgress.Phase {
            // The dead branch IS the force from the moment it is chosen — it waits for nothing —
            // so it reads as forcing even in the instant before the rung runs, and through a
            // force deferred behind an in-flight commit.
            if forced || branch == .dead { return .forcing }
            return .draining
        }
    }

    /// A watch holding the pod transfers its log every 300 s. Measured across 134 gaps since
    /// 2026-08-08: 283.1 s to 301.4 s, zero excursions past 302 s. One pulse period plus margin
    /// therefore separates a live watch from a dead one with enormous headroom — the one live
    /// revoke on record had a 6.5-second-old pulse, the five dead ones 5.5 to 21.2 minutes.
    static let watchContactLivenessWindow: TimeInterval = 330

    /// Live branch: the drain is two urgent WatchConnectivity round trips plus one Core Data
    /// commit, with NO pod round-trip on the critical path. The one field revoke drained 9 doses
    /// in 2.32 s, and 20 current-era hand-backs put trigger-to-final-ack at p50 1.0 s. 10 s covers
    /// 16 of those 20 outright; the resend captures 19. The 20th was an 80 s WatchConnectivity
    /// transport failure — surrendered to the force path on purpose rather than charged to every
    /// reclaim as a longer wait.
    private static let liveResendDelay: TimeInterval = 10
    private static let liveForceDelay: TimeInterval = 25

    /// The live handover's drain promise: the bar fills to here, and past it the label concedes
    /// ("No watch reply…") while the bar holds at cap until the force resolves things at 25 s.
    /// Ten seconds is the resend deadline ON PURPOSE — the concession and the second revoke are
    /// one event — and it covers the measured drains with room: every answered revoke on record
    /// drained in under 5 s (p50 1.0 s across 20 hand-backs). Field-ruled: a bar that fills and
    /// concedes beats a sweep that promises nothing, and the unsure-if-reachable scenario the
    /// sweep hedged against is not realistic.
    static let liveHandoverExpectation: TimeInterval = 10

    // The dead branch has no delay constants: it forces immediately. See armReclaimLadder for
    // the reasoning — nothing that lands on that branch can answer, and the pulse discriminator
    // above is what keeps an alive watch off it.


    private func scheduleLadderRung(after delay: TimeInterval, label: String, execute work: DispatchWorkItem) {
        if let scheduler = scheduler {
            scheduler(delay, label, work)
        } else {
            // WALL clock, not the monotonic default. Dispatch's `.now() + delay` freezes while
            // iOS suspends the app, and the suspension is APPENDED to the wait: a reclaim's
            // force rung due at +25 s fired at +85 s in the field because the phone was locked
            // between the tap and the deadline — the resend at +11 s ran on time, which
            // brackets the suspension. A wall deadline fires the overdue rung the moment the
            // app resumes instead of restarting its remaining wait.
            queue.asyncAfter(wallDeadline: .now() + delay, execute: work)
        }
    }

    enum Keys {
        static let state = "PodLoanPhoneController.state"
        static let epoch = "PodLoanPhoneController.epoch"
        static let cursor = "PodLoanPhoneController.cursor"
        static let pendingRevoke = "PodLoanPhoneController.pendingRevoke"
        static let committedIDs = "PodLoanPhoneController.committedIDs"
        static let loanStartedAt = "PodLoanPhoneController.loanStartedAt"
        // §5.3.3 post-reclaim re-audit state
        static let deliveredAtGrant = "PodLoanPhoneController.deliveredAtGrant"
        /// The watch's post-takeover odometer, sent in takeoverComplete while the watch is
        /// still alive — which is what makes the end-of-loan audit possible after it dies.
        static let deliveredAtTakeover = "PodLoanPhoneController.deliveredAtTakeover"
        /// The booked odometer-gap placeholder {epoch, units, bookedAt} awaiting the
        /// watch's real records.
        static let gapBooking = "PodLoanPhoneController.gapBooking"
        /// A force-reclaim audit armed but not yet resolved (restart survival).
        static let pendingForceAudit = "PodLoanPhoneController.pendingForceAudit"
        /// Item 1: the last loan's delivered total measured against a PHONE-read end odometer.
        static let deliveredAuthoritative = "PodLoanPhoneController.deliveredAuthoritative"
        /// Every authoritative residual, so the loose thresholds get tightened from data.
        static let residualHistory = "PodLoanPhoneController.residualHistory"
        /// One-shot repair flag for the residuals banked before the bank was scoped to clean
        /// hand-backs. Date-suffixed on purpose: this names a specific 2026-08-13 field-data
        /// repair, not a standing rule, so nobody reads it as a recurring purge.
        static let residualHistoryPurged = "PodLoanPhoneController.residualHistoryPurged.2026-08-13"
        /// The since-last-sync audit base {units, asOf, epoch} — the last odometer reading
        /// reconciled against a complete record set (restart survival; epoch-guarded on load).
        static let auditBase = "PodLoanPhoneController.auditBase"
        /// Per-loan worst |window residual| ring — the distribution any future band review
        /// reads (R32 closed 2026-08-27).
        static let windowWorstHistory = "PodLoanPhoneController.windowResidualWorst"
        /// R40: the paired watch advertised supportsSeize in a LoanRequest — gates the
        /// dormant-grant refresher (an older watch's decoder throws on the unknown kind).
        static let watchSupportsSeize = "PodLoanPhoneController.watchSupportsSeize"
        /// R40: the stable per-pod reunion identity for seized loans.
        static let dormantSeizeToken = "PodLoanPhoneController.dormantSeizeToken"
        /// PHONE MIRROR: the yielded posture survives relaunch (the blackout it answers
        /// can include phone reboots).
        static let yieldingToInferredLoan = "PodLoanPhoneController.yieldingToInferredLoan"
    }

    enum NotificationID {
        static let t1 = "podloan.t1"           // start-confirmation, 5 min
        static let duration = "podloan.6h"     // retired; kept so upgrades can cancel it
        static let paused = "podloan.paused1h" // retired; kept so upgrades can cancel it
        /// One reminder, an hour after an AUDIT opened the loop. Once only (ruled 2026-08-15):
        /// after that the user is making a conscious choice, and a repeating nag about a
        /// decision teaches people to swipe reminders away.
        static let openLoop = "podloan.openloop"
        /// The standing placeholder reminder, bounded by DIA. Rungs, not a repeating trigger,
        /// so the ladder simply runs out — nothing has to remember to stop it.
        static func placeholder(_ index: Int) -> String { "podloan.placeholder.\(index)" }
    }

    /// Reminder geometry. Both ladders stop inside the insulin action duration (6 h) because
    /// past that there is nothing left to remind about: the placeholder bolus has decayed out
    /// of IOB entirely, and re-timing it is moot. Hassling someone about insulin that no longer
    /// exists is how a useful reminder becomes noise.
    enum ReminderLadder {
        /// t=0 is already covered by the force-reclaim notice that announced the booking.
        static let placeholderRungs: [TimeInterval] = [.hours(2), .hours(4)]
        static let openLoopDelay: TimeInterval = .hours(1)
    }

    /// Derived — what v1 kept as the volatile `podLoanedToWatch` flag (:480/:697).
    /// The grant is out but the watch has NOT confirmed it has the pod. Distinct from
    /// `podIsOnLoan`, which is true here too — this is the narrower "in transit, outbound" window
    /// the tile shows as "Handing over…". Ends when `.takeoverComplete` arrives (state -> .loaned)
    /// or the loan is abandoned.
    var isPodTakeoverInProgress: Bool {
        return state == .grantOffered
    }

    var podIsOnLoan: Bool {
        switch state {
        // PHONE MIRROR: the yielded posture IS a loan for every consumer of this
        // predicate — the sweep engages, the re-pause-on-relaunch covers it, reclaimNow's
        // guard admits the pill tap.
        case .owner: return yieldingToInferredLoan
        case .grantOffered, .loaned, .reconciling, .reclaimPending: return true
        }
    }



    // MARK: - Escape hatch (§3.1 RECLAIM_PENDING)

    func reclaimNow() {
        queue.async {
            guard self.podIsOnLoan else { return }
            // PHONE MIRROR exit: the pill tap on an inferred loan takes the SAME road a
            // granted dead-watch loan takes — revoke (stale epoch, harmless), ladder,
            // force, schedule audit, gap booking. forceReclaimToOwner unpauses dosing.
            self.clearInferredLoanYield(reason: "pill tap — reclaimNow (the inherited exit)")
            self.reclaimDisplayAnchor = self.deps.now()   // the user's wait starts at the tap
            // Hold background execution from the tap: without it, tap-and-pocket freezes the
            // ladder and orphans the pod until the user next looks at the phone.
            self.deps.beginReclaimBackgroundTask()
            self.pendingRevoke = true
            // AIM AT THE LIVE LOAN when fresh evidence names one this phone never granted
            // (a seized loan discovered by the mirror). A revoke at our own stale epoch is
            // refused by the watch's split-brain guard as matching no live session — correct
            // on its side, but the ladder then reads refusal as death and force-steals a pod
            // that would have drained politely (field 2026-08-31 21:24). Freshness-gated via
            // supersededByLiveLoan so yesterday's evidence can't mis-aim today's reclaim —
            // stale or absent evidence keeps today's exact behavior.
            let revokeEpoch = self.supersededByLiveLoan(self.epoch)
                ? (self.newestForeignLoanEvidence?.epoch ?? self.epoch) : self.epoch
            if revokeEpoch != self.epoch {
                self.handbackDiag(self.epoch, "reclaim revoke AIMED at e\(revokeEpoch) — fresh evidence of a loan this phone never granted (mirror)")
            }
            self.sendMessage(.revoke(Revoke(epoch: revokeEpoch)))
            self.reclaimPodConnection()
            self.state = .reclaimPending
            self.armPausedReminder()
            self.armReclaimLadder()
        }
    }

    /// Two attempts, then force — on a deadline chosen ONCE, here, from the evidence available at
    /// the tap.
    ///
    /// The two regimes are separable before the wait starts, and the separator is the loan pulse
    /// rather than reachability: a watch holding the pod checks in every 300 s like a metronome,
    /// so the age of the last contact says whether there is a drain to wait for. Reachability
    /// only ever ADDS to the live side — it is a channel selector in this codebase, false for a
    /// healthy backgrounded watch, so it can prove life but never absence.
    ///
    /// Resending the revoke is safe: it carries only the epoch, and the watch guards on epoch
    /// plus phase, so the second copy is either the first one the watch ever sees or a no-op.
    ///
    /// The cost of the shorter wait, stated where it is paid: reclaiming earlier makes it likelier
    /// that a returning watch finds a NEWER loan already started, and a stale offer forfeits the
    /// wrist's final loop-mode inheritance and one calibration sample. That is why the live branch
    /// stays generous enough for a real drain to finish instead of being tuned to the p50.
    private func armReclaimLadder() {
        cancelReclaimLadder()

        let reachable = deps.isWatchReachable()
        let lastContact = deps.lastWatchContactAt()
        let contactAge = lastContact.map { deps.now().timeIntervalSince($0) }
        let heardRecently = (contactAge ?? .greatestFiniteMagnitude) < Self.watchContactLivenessWindow
        let branch: ReclaimLadder.Branch = (reachable || heardRecently) ? .live : .dead

        // The DEAD branch does not wait (field ruling, 2026-08-14). The reclaims that land here
        // are, realistically: a lost watch, or a watch out of battery — and in both, nothing can
        // answer a revoke, so a wait is ceremony. The scenario that LOOKS risky — the watch is
        // actually alive in a bag and the user just wants the pod back on the phone — cannot
        // normally reach this branch at all: an alive watch with the app running pulses its log
        // every 300 s (the keepalive holds it awake for the whole loan; 283-302 s across 134
        // measured gaps), so it is heardRecently and lands LIVE. The guard for that scenario is
        // the pulse discriminator above, not a wait; the wait never protected anything.
        //
        // An earlier version waited out two revoke attempts here. No dead-branch revoke was
        // ever answered — though honestly, the bench tests had the watch off by design, so that
        // record is close to tautological. The structural argument is the one that holds: a
        // watch silent past the liveness window either cannot answer or is not running, and in
        // both cases its records come home the same way whenever it returns — the queued revoke
        // is consumed at relaunch, the watch offers what it has, and the booked gap retires.
        // Waiting changed none of that; it only delayed the force.
        //
        // The revoke is still SENT — it arms the split-brain guard on any watch that later
        // wakes, and the returning-watch record flow rides on it. Fire, and force now. The
        // force itself still defers behind an in-flight commit, unchanged.
        let resendDelay: TimeInterval? = branch == .live ? Self.liveResendDelay : nil
        let forceDelay: TimeInterval = branch == .live ? Self.liveForceDelay : 0

        let started = deps.now()
        reclaimLadder = ReclaimLadder(branch: branch,
                                      startedAt: started,
                                      resendAt: started.addingTimeInterval(resendDelay ?? 0),
                                      forceAt: started.addingTimeInterval(forceDelay),
                                      attempts: 1,          // the tap's own revoke
                                      forced: false)

        // The evidence, not just the verdict: a field log has to be auditable after the fact for
        // whether the branch this reclaim took was the right one.
        let ageText = contactAge.map { String(format: "%.1fs ago", $0) } ?? "never"
        let planText = branch == .live
            ? String(format: "resend +%.0fs, force +%.0fs", Self.liveResendDelay, Self.liveForceDelay)
            : "force NOW (dead branch waits for nothing; the revoke is fire-and-forget)"
        handbackDiag(epoch, String(format: "reclaim ladder %@ — last watch contact %@, reachable %d · %@",
                                   branch.rawValue, ageText, reachable ? 1 : 0, planText))

        scheduleRungs(resendIn: resendDelay, forceIn: forceDelay)
    }

    /// Arm (or re-arm) the two rungs. Delays are measured from NOW, so a caller that moves a
    /// deadline passes the remaining time rather than the original budget.
    private func scheduleRungs(resendIn resendDelay: TimeInterval?, forceIn forceDelay: TimeInterval) {
        reclaimResendWork?.cancel()
        reclaimTimeoutWork?.cancel()

        if let resendDelay = resendDelay {
            let resend = DispatchWorkItem { [weak self] in
                guard let self = self, self.state == .reclaimPending,
                      var ladder = self.reclaimLadder, !ladder.forced else { return }
                // Two attempts is the whole budget. A reachability change can already have spent
                // the second one — better timed than this rung, since the watch was awake for it.
                guard ladder.attempts < 2 else { return }
                // Same aim rule as the tap's own revoke: fresh evidence of a never-granted
                // live loan re-targets the resend (evidence can arrive BETWEEN the rungs —
                // a holdsPod answer to attempt 1 is exactly that).
                let resendEpoch = self.supersededByLiveLoan(self.epoch)
                    ? (self.newestForeignLoanEvidence?.epoch ?? self.epoch) : self.epoch
                self.sendMessage(.revoke(Revoke(epoch: resendEpoch)))
                ladder.attempts += 1
                self.reclaimLadder = ladder
                self.handbackDiag(self.epoch, "reclaim revoke RESENT (attempt \(ladder.attempts) of 2) — no drain yet on the \(ladder.branch.rawValue) branch")
            }
            reclaimResendWork = resend
            scheduleLadderRung(after: max(resendDelay, 0), label: "reclaim-resend", execute: resend)
        } else {
            reclaimResendWork = nil
        }

        let force = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .reclaimPending, let ladder = self.reclaimLadder else { return }
            // Mark BEFORE forcing: a force can be deferred behind an in-flight hand-back commit,
            // and while it waits the tile must say what is actually happening.
            self.reclaimLadder?.forced = true
            // "Watch did not drain" was field-misread as "no reply from watch" when the watch
            // WAS replying (refusing stale revokes for a loan it holds). Name the newer loan
            // when the evidence shows one, so the log and the notice describe a refusal, not
            // silence.
            let holding = self.supersededByLiveLoan(self.epoch)
                ? " (watch holds newer loan e\(self.newestForeignLoanEvidence?.epoch ?? 0) — refused, not silent)" : ""
            self.forceReclaimToOwner(reason: "reclaim ladder spent on the \(ladder.branch.rawValue) branch — \(ladder.attempts) revoke attempt(s), watch did not drain\(holding)")
        }
        reclaimTimeoutWork = force
        scheduleLadderRung(after: max(forceDelay, 0), label: "reclaim-force", execute: force)
    }

    /// Kill every pending rung and forget the ladder. Called wherever a reclaim stops being in
    /// flight — a completed drain, a force that landed, a fresh tap, an abandoned loan — so no
    /// rung can resend a revoke into a loan that is already over, and so the determinate bar
    /// stops the moment the handover does.
    func cancelReclaimLadder() {
        reclaimResendWork?.cancel()
        reclaimResendWork = nil
        reclaimTimeoutWork?.cancel()
        reclaimTimeoutWork = nil
        reclaimLadder = nil
    }

    /// The explicit override, made real: abandon a stuck/stale loan and return to
    /// OWNER unconditionally. Records are NOT dropped blindly — any staged events are
    /// written to the store first (records are truth; never understate IOB), then the
    /// pod is reclaimed and dosing restored. Used when a new request proves the old
    /// loan is dead, when reclaim times out, or on a relaunch into a stranded state.
    // (Removed logReconciledDoses — the forensic dump built on `programmedUnits` = rate×FULL
    // temp window, the untruncated "implied Σ" over-count. It was os_log-only, fed no logic, and its
    // sum was physically impossible as delivery (exceeded max basal), so it consistently misled.
    // The trustworthy commanded number is the floored reconciled dose total; the real hand-back
    // reconciliation delta will be captured explicitly instead.)

    func forceReclaimToOwner(reason: String) {
        os_log("Force reclaim to OWNER: %{public}@", log: log, type: .default, reason)
        // Never mid-write — see pendingForceReclaimReason's doc. drainAfterCommit runs it.
        if commitInFlight {
            handbackDiag(epoch, "force reclaim DEFERRED (#118) — a hand-back commit is writing; runs when it lands")
            pendingForceReclaimReason = reason
            return
        }
        // PHONE MIRROR absolution: the force is a deliberate reassertion of ownership —
        // every foreign session up to this moment is either the loan being forced closed
        // or the seizure the user just chose to take over from. The mirror must not
        // rediscover it minutes later.
        cancelReclaimLadder()
        cancelNotification(id: NotificationID.paused)
        cancelNotification(id: NotificationID.duration)

        // Preserve known insulin: reconcile staged events records-only (no odometer)
        // and write them before we drop them.
        let events = staged.values
            .filter { !stagedTombstones.contains($0.id) && !committedIDs.contains($0.id) }
            .sorted { $0.seq < $1.seq }
        if !events.isEmpty {
            let input = LoanReconciler.Input(
                events: events, odometer: nil, schedule: deps.settings().basalRateSchedule,
                loanStart: loanStartedAt ?? deps.now().addingTimeInterval(-.hours(2)),
                loanEnd: deps.now())
            let outcome = LoanReconciler.reconcile(input)  // isFinalHandback defaults true → all finalized
            // OBS-9 (2026-08-13): SAY WHAT WAS SALVAGED. This path wrote insulin and announced
            // "its records were saved" without ever logging WHAT it saved, which is exactly why
            // Jeremy's phone-off/watch-off test could not be settled from the logs: the notice
            // proves only that `events` was non-empty, and an early-loan temp basal satisfies
            // that as well as a bolus does. The distinction that matters is whether a
            // delivered-but-unstreamed BOLUS was in this set at reclaim time or arrived minutes
            // later with the returning watch — the difference between complete books and the
            // loop resuming while under-counting IOB. One line answers it.
            // SPLIT, because one number cannot answer that question. The old line claimed to
            // "report what actually went in" via `deliveredUnits ?? programmedUnits`, but
            // LoanReconciler mints every dose with deliveredUnits nil (:193-198, :205-210), so the
            // `??` never fired and the total was ALWAYS gross programmed — rate × FULL clamped
            // window, un-netted against the schedule and untruncated against the next temp. That
            // is the very "implied Σ" over-count removed above, and with temps dominating it can
            // read 1.53 U for 0.85 U of real delivery, burying the bolus this line exists to
            // surface. Bolus units stand alone; rate records get a column labelled gross on its
            // face. (`deliveredUnits ??` kept on the bolus sum only — inert today, right the day a
            // record carries one.)
            let boluses = outcome.doses.filter { $0.type == .bolus }
            let bolusUnits = boluses.reduce(0.0) { $0 + ($1.deliveredUnits ?? $1.programmedUnits) }
            let rateGross = outcome.doses.filter { $0.type != .bolus }.reduce(0.0) { $0 + $1.programmedUnits }
            handbackDiag(epoch, String(format:
                "force reclaim SALVAGE — %d staged event(s) → %d dose(s): %.3f U bolus + %d rate record(s) (%.3f U gross programmed), %d carb(s), %d delete(s); loop resumes CLOSED on these books (no odometer check — OBS-9)",
                events.count, outcome.doses.count, bolusUnits, outcome.doses.count - boluses.count,
                rateGross, outcome.carbs.count, outcome.deletedCarbs.count))
            deps.addPumpEvents(newPumpEvents(from: outcome.doses), deps.now()) { _ in }
            // A2: the salvage is the fourth back-dated dose write on this file's books — these
            // doses span the loan from `loanStart`, entirely behind the frontier. `bookGapDose`
            // below needs no prune: its placeholder is timestamped at reclaim-now, ahead of it.
            if let earliest = outcome.doses.map(\.startDate).min() {
                deps.insulinHistoryRewritten(earliest)
            }
            for carb in outcome.carbs { deps.addCarb(carb.entry, carb.eventID.uuidString) { _ in } }
            for gone in outcome.deletedCarbs {   // carbs the wrist deleted during the loan
                deps.deleteCarb(gone) { error in
                    self.handbackDiag(self.epoch, error == nil
                        ? String(format: "carb DELETE applied on phone (recovery) — %.0f g", gone.grams)
                        : String(format: "carb DELETE MISSED on phone (recovery) — %.0f g: %@", gone.grams, String(describing: error!)))
                }
            }
            // RECORD what we just committed. This path read committedIDs in
            // the filter above but never added to it, and it sends no handbackAck — so the
            // watch's 15 s resend loop kept redelivering the same offer against an unchanged
            // set, and each delivery committed the carbs again.
            //
            // Insulin survived this because NewPumpEvent carries `raw`, which the store dedupes
            // on. Carbs cannot: NewCarbEntry has no identity field and CarbStore mints a fresh
            // syncIdentifier per addCarbEntry, so the cursor IS the only guard. Duplicate carbs
            // here then mirror into every later grant via wipe-then-replace — the
            // phantom-COB failure mode with the phone as the source.
            //
            // Reached whenever a watch goes unreachable mid-loan: the reclaim ladder spending both
            // of its attempts, a stranded-state relaunch, or a fresh request while still loaned.
            committedIDs.formUnion(events.map(\.id))
            persistCommittedIDs()
            // LIVELOCK FIX. This used to record the IDs and stop, leaving
            // `committedCursor` where it was — usually 0, because a force-reclaim happens when
            // the watch went quiet and no offer ever completed.
            //
            // The consequence is not lost insulin (the ID filter holds; nothing double-books) —
            // it is that the loan NEVER CLOSES ON THE WRIST. A returning watch re-offers, this
            // phone commits nothing (every event is already in committedIDs), and acks the
            // unchanged cursor 0. `PodLoanWatchController.handleAck` only closes when
            // `journal.unackedEvents()` is empty, which cursor 0 can never make true, so the
            // 15 s resend loop runs forever: battery, log noise, a loan the wrist cannot end,
            // and possibly a spurious stuck-hand-back alert.
            //
            // Measured before the fix (LoanTwoSidedContractTests): ack cursor 0, stale=false,
            // watch journal still holding seq [1,2].
            //
            // Advancing to the max committed seq is safe against the withheld-seq gap, and the
            // safety lives on the WATCH, not here: `applyAck(committedCursor:withholding:)` caps
            // whatever we send to below its own lowest withheld seq. So an over-eager cursor from
            // this side cannot bury an unclassified command. Same arithmetic as the normal commit
            // path (:1220-1222), which is the point — this path had simply never learned it.
            if let newCursor = events.map(\.seq).max() {
                committedCursor = max(committedCursor, newCursor)
            }
            // "Reset" named nothing observed. What IS observed here: a loan ended without a
            // clean hand-back, and the staged records just went to the store.
            //
            // The old copy omitted the fact that matters most — automatic dosing is PAUSED at
            // this instant and stays paused until the audit rules (:2614-2623) — so a reader
            // came away believing the loop was running. It also told the user to "check Event
            // History and the pod": Event History shows a set the code cannot vouch for (this
            // path reconciles with odometer: nil, so `.assumed` records are written as fact),
            // and there is nothing on the pod a user can read. Worse, the app REFUSES manual
            // boluses and carb entry while the settle runs, so it was advice the app would
            // then decline to let them act on.
            //
            // What replaces it is the honest shape of the wait: dosing is off, a pod round-trip
            // is in flight, and it is quick — field-measured at ~2 s on the one real dead-watch
            // run, chased every 2 s under a 5-minute ceiling. The verdict that follows is the
            // loud one; this is only the "hold on" note before it.
            deps.issueNotice(
                NSLocalizedString("Watch Session Ended Without Hand-Back", comment: "Phone notice title after a force reclaim salvaged staged records"),
                NSLocalizedString("Automatic dosing is paused while Loop checks the pod's insulin total. This usually takes seconds.", comment: "Phone notice body after a force reclaim salvaged staged records"))
        }

        // Arm the odometer audit BEFORE clearing staged — its `expected` is computed over
        // everything the phone holds for this loan, and silence counts as zero. Uses the whole
        // staged set (not just the uncommitted salvage above), matching how the normal path's
        // expected spans the loan.
        let auditArmed = armForceReclaimAudit()

        reclaimPodConnection()
        pendingRevoke = false
        state = .owner
        // Automatic dosing does NOT resume here. The old behavior — resume CLOSED on
        // whatever records happened to have streamed — is exactly what the watch-battery-dies
        // test exposed: a bolus the watch delivered but never streamed was invisible, and the
        // loop closed on books missing real insulin. The audit's verdict resumes dosing (clean),
        // or opens the loop loudly (unexplained insulin), or the settle ceiling / a missing
        // odometer does the conservative thing. If the audit could not even be armed, that
        // already surfaced inside armForceReclaimAudit.
        if !auditArmed {
            deps.setAutomaticDosingPaused(false)   // the settings-level open is the latch; see armForceReclaimAudit
        }
        beginReclaimSettleWindow()
        staged = [:]
        stagedTombstones = []
        persistStaged()
    }

    /// Everything the audit needs except the end odometer, which the verified reclaim
    /// round-trip supplies seconds later (`finishPendingHandbackAudit`). Returns false when no
    /// baseline exists — in which case the loop has already been opened and the user told,
    /// because "cannot verify" must never quietly become "assume fine".
    @discardableResult
    private func armForceReclaimAudit() -> Bool {
        // The one rule everywhere: the verdict window runs from the audit base — the last
        // mid-loan sync when there ever was one, the takeover reading when there wasn't. A
        // dead watch after a contactless loan therefore still gets the whole-loan audit
        // (no choice there), but a watch that synced records an hour ago is judged only on
        // the hour the phone actually cannot account for.
        let start = loanStartedAt ?? deps.now().addingTimeInterval(-.hours(2))
        let anchor: (units: Double, asOf: Date)?
        if let base = auditBase {
            anchor = (base.units, base.asOf)
        } else if let units = (UserDefaults.standard.object(forKey: Keys.deliveredAtTakeover) as? Double)
                            ?? (UserDefaults.standard.object(forKey: Keys.deliveredAtGrant) as? Double) {
            anchor = (units, start)
        } else {
            anchor = nil
        }
        guard let anchor = anchor, let schedule = deps.settings().basalRateSchedule else {
            handbackDiag(epoch, "** R37 force-reclaim audit IMPOSSIBLE — no start odometer/schedule; loop OPENS on principle (cannot verify => do not resume) **")
            deps.openLoopForUncertainReconciliation()
            armOpenLoopReminder()
            deps.issueUrgentNotice("Watch Session Unverified", Self.sessionUnverifiedBody)
            return false
        }
        let allEvents = staged.values.sorted { $0.seq < $1.seq }
        let expected = LoanReconciler.expectedInsulin(events: allEvents, schedule: schedule,
                                                      from: anchor.asOf, to: deps.now())
        // Whole-loan companions for the reconcile line's loan-total fields (never banked on
        // the force flavor; diagnostic color only).
        let takeoverUnits = UserDefaults.standard.object(forKey: Keys.deliveredAtTakeover) as? Double
        let wholeLoanExpected = takeoverUnits.map {
            _ in LoanReconciler.expectedInsulin(events: allEvents, schedule: schedule, from: start, to: deps.now())
        }
        pendingHandbackAudit = PendingHandbackAudit(
            epoch: epoch, deliveredAtStart: anchor.units, expected: expected,
            loanMinutes: deps.now().timeIntervalSince(start) / 60, cycles: 0,
            watchLatest: nil, watchFreshened: false, flavor: .forceReclaim,
            takeoverUnits: takeoverUnits, wholeLoanExpected: wholeLoanExpected)
        // checkpointsThisLoan survives relaunch (persisted with the base) — e226 mislabeled
        // its relaunch-survived base as "takeover (0 checkpoint(s))" before it did.
        handbackDiag(epoch, String(format:
            "R37 audit armed — expected %.3f U from %d record(s) + schedule fill over window since %@ (%d checkpoint(s)); verdict on the reclaim round-trip",
            expected, allEvents.count,
            checkpointsThisLoan > 0 ? String(format: "last sync %.0f min ago", deps.now().timeIntervalSince(anchor.asOf) / 60) : "takeover",
            checkpointsThisLoan))
        return true
    }

    /// Re-send a parked revoke on any sign of watch life (kept from v1), and record it against
    /// a waiting ladder's two-attempt budget so the resend rung never buys a third — this
    /// wake-up revoke is the best-timed attempt available, going out while the watch is
    /// provably awake.
    ///
    /// A dead-branch promotion used to live here (a dead ladder that got proof of life moved
    /// onto the live deadlines). It went with the dead branch's wait: a dead ladder now forces
    /// immediately, so there is no window left in which a waking watch could promote one — and
    /// a watch that wakes after the force follows the ordinary returning-watch path, records
    /// and all.
    func watchDidBecomeReachable() {
        queue.async {
            guard self.pendingRevoke else { return }
            self.sendMessage(.revoke(Revoke(epoch: self.epoch)))
            if var ladder = self.reclaimLadder, self.state == .reclaimPending, !ladder.forced,
               ladder.attempts < 2 {
                ladder.attempts += 1
                self.reclaimLadder = ladder
            }
        }
    }

}
