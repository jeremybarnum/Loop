//
//  PodLoanPhoneController.swift
//  Loop
//
//  The phone half of loan protocol v2 (docs/DESIGN_LOAN_PROTOCOL_V2.md §3.1, §10).
//  Persisted state machine (podLoanedToWatch is DERIVED from this state, never a
//  volatile flag), epoch minting, grant assembly with deny-on-missing, the R8 alarm
//  inventory (exactly: T1 start-confirmation 5 min / loan-duration 6 h / paused-dosing
//  1 h repeating — deliberately NO heartbeat), record staging (the trap-cell defense),
//  and reconcile-commit-ack ordering (ack ONLY after the store writes commit).
//
//  Dependencies are injected closures so the state machine and ordering invariants
//  are testable without the live device stack; app integration wires the real
//  DeviceDataManager/WatchDataManager/AlertManager surfaces.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore
import UserNotifications
import os.log

final class PodLoanPhoneController {

    enum State: String {
        case owner, grantOffered, loaned, reconciling, reclaimPending
    }

    struct Dependencies {
        /// The current pump manager, if any (conditionally cast for lending).
        var pumpManager: () -> PumpManager?
        /// The live therapy settings (snapshot travels in the grant).
        var settings: () -> LoopSettings
        /// Pause/resume the phone's automatic dosing (loan-gated, R7).
        var setAutomaticDosingPaused: (Bool) -> Void
        /// Transport out (WCSession.transferUserInfo at integration).
        var send: ([String: Any]) -> Void
        /// Store writes. Loan insulin goes through the pump-event path (not addDoses) so
        /// it lands in the PumpEvent table (Event History), is run through stock
        /// InsulinMath.reconciled() at the store (overlap truncation), and mirrors into
        /// InsulinDeliveryStore/HealthKit — behaving exactly like real pump insulin (#69/#52).
        var addPumpEvents: ([NewPumpEvent], _ lastReconciliation: Date?, @escaping (Error?) -> Void) -> Void
        var addCarb: (NewCarbEntry, @escaping (Error?) -> Void) -> Void
        /// R30 (#89): remove a carb the WRIST deleted during the loan. Matched on the phone's
        /// syncIdentifier when the watch knew one (phone-originated carbs, which are the only
        /// ones that reach here — watch-entered add/delete pairs cancel in the reconciler), and
        /// on (startDate, grams) otherwise. Default is a no-op so tests and older wiring are
        /// unaffected.
        var deleteCarb: (LoanReconciler.DeletedCarb, @escaping (Error?) -> Void) -> Void = { _, done in done(nil) }
        /// #68 part B: apply a WATCH-enacted temporary schedule override to the phone's
        /// LoopSettings (nil = the wrist cleared it). Sovereignty ruling (2026-07-31): while
        /// the watch holds the pod it OWNS overrides, so this is a straight assignment — there
        /// is no merge with whatever the phone thought, and no user prompt. The phone's own
        /// override UI already funnels to a reclaim prompt during a loan (#71), so a competing
        /// phone-side edit cannot exist. Default no-op keeps the state-machine tests (and any
        /// caller that doesn't care about overrides) constructing unchanged.
        var applyScheduleOverride: (TemporaryScheduleOverride?) -> Void = { _ in }
        /// R23 OVERTURNED 2026-08-04 (Jeremy): "the loop should inherit the watch state" on the
        /// way back, mirroring the grant's outbound inheritance. Records the WRIST's final loop
        /// mode so the reclaim restores THAT rather than the value captured before the loan.
        /// Default no-op keeps the state-machine tests constructing unchanged.
        var noteWatchClosedLoop: (Bool) -> Void = { _ in }
        /// 16 h insulin history for the grant.
        var doseHistory: (_ start: Date, _ completion: @escaping ([DoseEntry]) -> Void) -> Void
        /// Active carb entries for the grant (#49) — seeded so the watch predicts with COB.
        var carbHistory: (_ start: Date, _ completion: @escaping ([LoanCarbRecord]) -> Void) -> Void = { _, done in done([]) }
        /// ~3 h of recent glucose for the grant — seeded so the watch's momentum + retrospective
        /// correction warm from the first post-takeover cycle instead of a cold empty store.
        var glucoseHistory: (_ start: Date, _ completion: @escaping ([LoanGlucoseRecord]) -> Void) -> Void = { _, done in done([]) }
        /// INSTRUMENTATION ONLY (#45): the phone's last-computed prediction, decomposed, carried in
        /// the grant so the watch can diff its first post-takeover prediction against the phone.
        /// Reads already-cached effect arrays only (no recompute, no dosing). Default nil keeps the
        /// state machine + existing tests green with no live LoopDataManager.
        var predictionSnapshot: (_ completion: @escaping (LoanPredictionSnapshot?) -> Void) -> Void = { done in done(nil) }
        /// Loud surfacing (banner + Event History line at integration).
        var issueNotice: (_ title: String, _ body: String) -> Void
        /// PODLOAN instant-tile port (crude f3784d49/674e1b13): fired when pod
        /// OWNERSHIP flips (owner <-> not-owner) so the phone HUD re-renders the
        /// pump tile immediately instead of aging into signal-loss.
        var ownershipDidChange: () -> Void = {}
        /// True when the loaned pump's connection is truly back after a reclaim (post-hand-back).
        /// Default true so a pump lacking the capability never gets stuck in the settling tile.
        var isConnectionReady: () -> Bool = { true }
        /// R33 (2026-08-11): cancel the temp the WATCH left running, the instant the reclaim
        /// round-trip proves we can reach the pod. Stock's own off-cycle `.cancel` idiom — see
        /// LoopDataManager.cancelTempBasalAfterPodReturn. Default no-op keeps the state-machine
        /// tests constructing unchanged.
        var cancelTempBasalAfterPodReturn: (@escaping (Error?) -> Void) -> Void = { $0(nil) }
        /// R32(b) (2026-08-11): the pod's odometer disagrees with our books by more than noise —
        /// stop automatic dosing and LEAVE it stopped until the user decides otherwise.
        ///
        /// Deliberately NOT `setAutomaticDosingPaused(true)`. That call pairs with a matching
        /// `(false)` at the next loan's end, which would silently re-close the loop R32 just
        /// opened — the implementation must also clear the pre-loan capture so no later restore
        /// can undo this. Default no-op keeps the state-machine tests constructing unchanged.
        var openLoopForUncertainReconciliation: () -> Void = {}
        var now: () -> Date = { Date() }
    }

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanPhoneController")
    private let queue = DispatchQueue(label: "com.loopkit.Loop.PodLoanPhoneController", qos: .utility)
    private var deps: Dependencies

    // MARK: - Loan → pump-event conversion (#69/#52)

    /// Wrap reconciled loan DoseEntries as NewPumpEvents for DoseStore.addPumpEvents.
    /// The identity must live in `raw` — NewPumpEvent.init overwrites dose.syncIdentifier
    /// with raw.hexadecimalString, so we encode the deterministic loan syncIdentifier
    /// (loanv2-<uuid>) there for idempotent, dedup-safe upserts. (The loanv2-audit-<epoch>
    /// odometer-IOB sync ID is gone as of 2026-07-27 — no odometer insulin is injected.)
    private func newPumpEvents(from doses: [DoseEntry]) -> [NewPumpEvent] {
        doses.compactMap { dose in
            guard let syncID = dose.syncIdentifier else { return nil }
            return NewPumpEvent(date: dose.startDate,
                                dose: dose,
                                raw: Data(syncID.utf8),
                                title: Self.pumpEventTitle(for: dose.type))
        }
    }

    private static func pumpEventTitle(for type: DoseType) -> String {
        switch type {
        case .bolus:     return "Bolus"
        case .tempBasal: return "Temp Basal"
        case .basal:     return "Basal"
        case .suspend:   return "Suspend"
        case .resume:    return "Resume"
        }
    }

    private(set) var state: State {
        didSet {
            UserDefaults.standard.set(state.rawValue, forKey: Keys.state)
            // Instant-tile: EVERY state change re-renders (the tile distinguishes
            // "Pod on Watch" from "Reclaiming…", so intermediate transitions are
            // user-visible — crude parity: it pushed every phase, and the 5s frozen
            // tile during hand-back read as ambiguity).
            if oldValue != state {
                // Phase-1 anchor for the pump pill's fill (2026-08-04). Phase 1 is the
                // ownership handover — bounded, and the only half worth drawing a bar for.
                // Measured across 51 real hand-backs: median 6s, p75 24s, p85 61s. Phase 2
                // (the BLE settle) is deliberately NOT covered: 2s to 190s with no way to
                // predict which, so a bar there would be a lie about half the time.
                let inPhase1 = (state == .reconciling || state == .reclaimPending)
                let wasPhase1 = (oldValue == .reconciling || oldValue == .reclaimPending)
                if inPhase1 && !wasPhase1 {
                    reclaimPhase1StartedAt = deps.now()
                } else if !inPhase1 {
                    reclaimPhase1StartedAt = nil
                }
                deps.ownershipDidChange()
                // A reclaim just landed us in .owner, but reclaimConnection() only re-armed
                // the BLE bid — the pod isn't actually back for ~2 min. Open the settle window
                // so "Reclaiming…" (and the bolus gate) persist until the pod is truly reachable.
                if oldValue != .owner, state == .owner {
                    beginReclaimSettleWindow()
                }
            }
        }
    }

    /// When the ownership handover (phase 1) began, or nil if not in it.
    private var reclaimPhase1StartedAt: Date?

    /// Fraction 0...0.95 of the expected phase-1 handover, or nil when phase 1 is not running.
    ///
    /// Calibrated PESSIMISTICALLY at 25s, the p75 of 51 measured hand-backs (median 6s), so
    /// three quarters of reclaims beat the bar — the same "make the good case a pleasant
    /// surprise" rule Jeremy set for the takeover bar. Holds at 0.95 rather than completing,
    /// because completion is the tile changing, not the bar filling.
    var reclaimPhase1Progress: Double? {
        return queue.sync {
            guard let started = reclaimPhase1StartedAt else { return nil }
            let elapsed = deps.now().timeIntervalSince(started)
            return min(max(elapsed, 0) / 25.0, 0.95)
        }
    }

    /// True during the post-handover BLE settle: the phone owns the pod but cannot yet command
    /// it. Distinct from `isPodLoanedOut` (which is false here, since state is already .owner),
    /// so a bolus tapped now would be aimed at a link that is not up.
    var isReclaimSettlingOnly: Bool {
        return queue.sync { state == .owner && reclaimStartedAt != nil && reclaimVerifiedAt == nil }
    }

    // MARK: Reclaim settle window (post-hand-back "Reclaiming…" until the pod is truly back)

    /// Set when state enters .owner (a reclaim re-armed the BLE bid, but the pod isn't back
    /// yet). Drives `isReclaimSettling` so the tile persists until the pod is truly connected
    /// (deps.isConnectionReady) or the ceiling elapses. nil = not settling.
    private var reclaimStartedAt: Date?
    private var reclaimSettleWork: DispatchWorkItem?
    private static let reclaimSettleTimeout: TimeInterval = .minutes(5)
    /// #42 (2026-08-02): set when a pod ROUND-TRIP has completed since the reclaim began.
    /// This — not the peripheral's Bluetooth state — is what "the pod is back" means.
    /// Field measurement: after a hand-back the pod advertises immediately, the phone's
    /// standing bid connects within seconds, and isConnectionReady() flips true long before
    /// the phone has actually TALKED to the pod. Grants issued in that gap release a
    /// half-returned pod, and the watch's takeover then flaps against it (~90 s of #7/#11).
    /// Every recorded failure sat inside that window; every success outside it.
    private var reclaimVerifiedAt: Date?
    private var reclaimVerifyInFlight = false
    /// #42 (2026-08-02): last request identity handled, for transport-redelivery suppression.
    /// sendMessage can report a timeout WITHOUT meaning undelivered, so the queued fallback
    /// sends a second copy that also lands. See handleRequest for what that cost in the field.
    private var lastRequestID: String?
    private var lastRequestAt: Date?
    private static let requestDedupeWindow: TimeInterval = .minutes(2)

    /// reclaimConnection() only re-arms the BLE bid; the actual reconnect lands
    /// seconds-to-minutes later. Open a bounded window so the tile keeps showing "Reclaiming…"
    /// until the pod is genuinely reachable, without ever sticking (the ceiling clears it).
    /// Runs on `queue` (state is queue-confined, as the sync accessors below assume).
    ///
    /// #42: the window now also CHASES completion instead of waiting for it. Left alone, the
    /// first post-reclaim pod round-trip is whenever the phone's 5-minute cycle next runs —
    /// or, on a locked phone, whenever iOS feels like it (one hand-back completed the moment
    /// an unrelated notification woke the phone). ensureCurrentPumpData is fired as soon as
    /// the link is up, so "returned" happens in seconds when the phone is awake instead of
    /// minutes by accident.
    private func beginReclaimSettleWindow() {
        let started = deps.now()
        reclaimStartedAt = started
        reclaimVerifiedAt = nil
        reclaimVerifyInFlight = false
        reclaimSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.reclaimStartedAt == started else { return }
            os_log("Reclaim settle CEILING reached (%.0fs) without a verified round-trip — clearing anyway",
                   log: self.log, type: .error, Self.reclaimSettleTimeout)
            self.reclaimStartedAt = nil            // ceiling reached — stop settling
            self.deps.ownershipDidChange()         // final re-render that clears the tile
        }
        reclaimSettleWork = work
        queue.asyncAfter(deadline: .now() + Self.reclaimSettleTimeout, execute: work)
        chaseReclaimVerification(started: started)
    }

    /// Poll on `queue` every 2 s: once the link is up, do ONE pod round-trip and mark the
    /// reclaim verified when it lands. Self-cancelling when superseded (a new settle window,
    /// the ceiling, or a grant taking us out of .owner).
    private func chaseReclaimVerification(started: Date, attempt: Int = 0) {
        guard reclaimStartedAt == started, reclaimVerifiedAt == nil else { return }
        attemptReclaimVerificationNow(started: started)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.chaseReclaimVerification(started: started, attempt: attempt + 1)
        }
    }

    /// One verification attempt, no rescheduling. Also called EAGERLY from the grant-deny
    /// path: a premature Start is the strongest possible signal the user wants the pod back,
    /// so their tap accelerates the very check their retry is waiting on.
    private func attemptReclaimVerificationNow(started: Date) {
        guard reclaimStartedAt == started, reclaimVerifiedAt == nil else { return }
        if deps.isConnectionReady(), !reclaimVerifyInFlight, let pump = deps.pumpManager() {
            reclaimVerifyInFlight = true
            pump.ensureCurrentPumpData { [weak self] lastSync in
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
                        os_log("Reclaim VERIFIED — pod round-trip complete %.0fs after reclaim began",
                               log: self.log, type: .default, elapsed)
                        // Ride the existing diag channel so the unified watch/iCloud log
                        // carries the completion time — the measurement #42 was missing.
                        self.sendMessage(.diag(LoanDiag(epoch: self.epoch,
                            text: String(format: "reclaim VERIFIED — pod round-trip complete +%.0fs", elapsed))))
                        self.deps.ownershipDidChange()
                        // The pod is provably reachable RIGHT NOW. This is the only moment in the
                        // whole hand-back where that is true, so it is where both jobs that need
                        // the pod happen: read the real end-of-loan odometer, and cancel the temp
                        // the watch left running.
                        self.finishPendingHandbackAudit(elapsed: elapsed)
                    }
                }
            }
        }
    }

    /// The two things that require a live pod link at the end of a loan, done at the one instant
    /// we know we have one: the verified reclaim round-trip (item 1, 2026-08-11).
    ///
    /// 1. THE AUTHORITATIVE AUDIT. `ensureCurrentPumpData` just completed a real conversation with
    ///    the pod, so `lentDeviceInsulinDelivered` is the odometer as of seconds ago. Paired with
    ///    `deliveredAtStart` — which still comes from the WATCH's post-takeover read, the one
    ///    odometer reading the watch takes while it definitely holds the link — that is a clean
    ///    measurement of the loan's whole delivery, bracketed by two fresh readings.
    ///
    /// 2. THE INHERITED TEMP. R33: no automatic program crosses the boundary. The watch cannot
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
    private func finishPendingHandbackAudit(elapsed: TimeInterval) {
        guard let pending = pendingHandbackAudit else { return }
        pendingHandbackAudit = nil

        if let latest = (deps.pumpManager() as? PumpConnectionLendable)?.lentDeviceInsulinDelivered {
            let delivered = latest - pending.deliveredAtStart
            let residual = delivered - pending.expected
            // `drift` is the whole point of the change: how much delivery the watch's stale
            // endpoint was missing. If this is reliably ~0 the watch's reading was fine after all
            // and this machinery can go; if it is a temp's worth, every earlier residual we
            // puzzled over was measuring the wrong interval.
            let drift = pending.watchLatest.map { latest - $0 }
            handbackDiag(pending.epoch, String(format:
                "reconcile[AUTHORITATIVE]: delivered=%.3f expected=%.3f residual=%+.3f (tol 0.05) · loanMin=%.0f cycles=%d · odometer read by PHONE +%.0fs after reclaim · vs watch endpoint %@ (watch fresh=%@)",
                delivered, pending.expected, residual,
                pending.loanMinutes, pending.cycles, elapsed,
                drift.map { String(format: "%+.3f", $0) } ?? "n/a",
                pending.watchFreshened ? "Y" : "N"))
            UserDefaults.standard.set(delivered, forKey: Keys.deliveredAuthoritative)
            bankResidual(residual, epoch: pending.epoch)
            applyReconciliationVerdict(residual: residual, epoch: pending.epoch)
        } else {
            handbackDiag(pending.epoch, "reconcile[AUTHORITATIVE]: pod reachable but reported no odometer — keeping the provisional line")
        }

        // R33: cancel the watch's temp now that we can actually reach the pod.
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

    // MARK: - R32(b): what a reconciliation difference actually DOES

    /// A positive residual — the pod delivered MORE than our books say — beyond this opens the
    /// loop. Ten pulses: quantization cannot produce it, a bolus we recorded cannot produce it,
    /// and the largest bias we have ever measured is a third of it. So a trip means something
    /// real happened that our records do not contain.
    ///
    /// DELIBERATELY LOOSE, and it should not stay this loose. Every residual we had when this was
    /// chosen was measured against the watch's stale endpoint, i.e. against the wrong interval —
    /// which is exactly what `finishPendingHandbackAudit` now fixes. Tightening before the new
    /// measurement has a distribution would be fitting to known-bad data. `bankResidual` counts
    /// the clean samples and says in the log when there are enough. See RULINGS R32.
    private static let openLoopPositiveResidual: Double = 0.5

    /// A negative residual — the pod delivered LESS than our books say — beyond this warns.
    private static let warnNegativeResidual: Double = 0.5

    /// R32(b), sign-aware. The two directions are not the same failure and do not deserve the
    /// same response:
    ///
    /// POSITIVE (pod delivered more than recorded) — there is insulin in the body that the
    /// algorithm cannot see. Closed loop will dose on top of it. That is stacking, and the remedy
    /// is to stop the machine: go open, tell the user loudly, let them look and dose by hand.
    ///
    /// NEGATIVE (pod delivered less than recorded) — the books carry phantom IOB. The algorithm
    /// believes there is more insulin working than there is, so it doses LESS: the error is
    /// self-limiting, it decays out within DIA, and R22's annulment already retires the
    /// identifiable cases. Opening the loop here would make the actual failure (under-treatment)
    /// worse, not better — the one direction where R32's remedy is the wrong medicine. So: warn,
    /// keep looping.
    ///
    /// Warned once per event, never once per retry (#102's alarm-fatigue finding).
    private func applyReconciliationVerdict(residual: Double, epoch: Int) {
        if residual > Self.openLoopPositiveResidual {
            handbackDiag(epoch, String(format:
                "** R32 OPEN LOOP — residual %+.3f U exceeds +%.2f: the pod delivered insulin our records do not contain. Automatic dosing STOPPED. **",
                residual, Self.openLoopPositiveResidual))
            deps.openLoopForUncertainReconciliation()
            deps.issueNotice("Loop Opened — Unexplained Insulin",
                             String(format: "The pod delivered %.2f U more than the watch session's records account for. Automatic dosing is off until you turn it back on. Check your insulin on board before dosing.", residual))
        } else if residual < -Self.warnNegativeResidual {
            handbackDiag(epoch, String(format:
                "** R32 WARN — residual %+.3f U beyond -%.2f: records claim more delivery than the pod made (phantom IOB). Still looping — this direction under-doses and decays out. **",
                residual, Self.warnNegativeResidual))
            deps.issueNotice("Insulin On Board May Be High",
                             String(format: "The watch session's records account for %.2f U more than the pod delivered. Automatic dosing continues; expect it to run cautious until this clears.", -residual))
        }
    }

    /// The "don't forget to tighten this" mechanism, built so it cannot be forgotten: bank every
    /// authoritative residual and say in the log how many clean samples exist. A note in a doc
    /// relies on someone re-reading the doc; a line that appears at every hand-back does not.
    private func bankResidual(_ residual: Double, epoch: Int) {
        var history = (UserDefaults.standard.array(forKey: Keys.residualHistory) as? [Double]) ?? []
        history.append(residual)
        if history.count > 40 { history.removeFirst(history.count - 40) }
        UserDefaults.standard.set(history, forKey: Keys.residualHistory)

        let mean = history.reduce(0, +) / Double(history.count)
        let worst = history.map(abs).max() ?? 0
        var line = String(format: "residual bank: n=%d mean=%+.3f worst=|%.3f| min=%+.3f max=%+.3f",
                          history.count, mean, worst, history.min() ?? 0, history.max() ?? 0)
        if history.count >= Self.residualSampleTarget {
            line += String(format: " ** R32 THRESHOLD REVIEW DUE — %d authoritative samples banked; the ±%.2f U bounds were set with none **",
                           history.count, Self.openLoopPositiveResidual)
        } else {
            line += String(format: " (%d more for a threshold review)", Self.residualSampleTarget - history.count)
        }
        handbackDiag(epoch, line)
    }

    /// How many phone-read residuals to bank before the loose bounds above are worth revisiting.
    private static let residualSampleTarget = 10

    /// True whenever this phone does NOT own the pod's connection (any non-owner
    /// state — the link is released or in flux). Delivery attempts made here while
    /// true would die in a BLE timeout; callers should refuse loudly instead.
    var isPodLoanedOut: Bool {
        return queue.sync { state != .owner }
    }

    /// True while the pod is actively coming home (hand-back reconcile / reclaim in
    /// flight) — the pump tile shows "Reclaiming…" instead of "Pod on Watch".
    var isReclaimInProgress: Bool {
        return queue.sync { state == .reconciling || state == .reclaimPending }
    }

    /// True after state flips to .owner until the pod is truly back on the link
    /// (deps.isConnectionReady) or the settle ceiling elapses — bridging the ~2 min BLE
    /// re-establishment window after reclaimConnection() (which only re-arms the bid). Keeps
    /// "Reclaiming…" up until the pod is actually reachable, without sticking (ceiling) or
    /// misfiring on a later ordinary signal-loss (gated on a recent reclaimStartedAt).
    var isReclaimSettling: Bool {
        return queue.sync {
            guard state == .owner, let started = reclaimStartedAt else { return false }
            if deps.now().timeIntervalSince(started) >= Self.reclaimSettleTimeout { return false }
            // #42: settling until a pod ROUND-TRIP has landed, not until the peripheral shows
            // .connected — the Bluetooth state flips true seconds after hand-back while the
            // actual return conversation hasn't happened. This is what kept "Reclaiming…"
            // honest AND sticky before; now it clears the moment the round-trip completes,
            // which the chase makes prompt.
            return reclaimVerifiedAt == nil
        }
    }
    private var epoch: Int {
        didSet { UserDefaults.standard.set(epoch, forKey: Keys.epoch) }
    }
    private var committedCursor: Int {
        didSet { UserDefaults.standard.set(committedCursor, forKey: Keys.cursor) }
    }
    /// Committed event IDs for the CURRENT epoch (secondary idempotency; the cursor
    /// is primary). Bounded: cleared when a loan fully closes.
    /// #102: latch so a repeatedly-failing hand-back write warns ONCE, not once per 15 s resend.
    /// Deliberately not persisted — a relaunch is a fresh chance to tell the user.
    private var hasWarnedRecordsNotSaved = false

    /// R33/item-1 (2026-08-11): everything the odometer audit needs EXCEPT the end reading, held
    /// from the final drain until the phone's own reclaim round-trip lands (seconds later) and can
    /// supply that reading first-hand. See `finishPendingHandbackAudit`.
    private struct PendingHandbackAudit {
        let epoch: Int
        let deliveredAtStart: Double
        let expected: Double
        let loanMinutes: Double
        let cycles: Int
        let watchLatest: Double?      // the watch's own end reading, for the fresh-vs-stale delta
        let watchFreshened: Bool
    }
    private var pendingHandbackAudit: PendingHandbackAudit?

    private var committedIDs: Set<UUID>
    /// Staged (received, not-yet-committed) events for the current epoch — persisted
    /// on every batch so a phone relaunch keeps the trap-cell defense.
    private var staged: [UUID: LoanEvent] = [:]
    private var stagedTombstones: Set<UUID> = []
    private var loanStartedAt: Date?
    private var pendingRevoke: Bool {
        didSet { UserDefaults.standard.set(pendingRevoke, forKey: Keys.pendingRevoke) }
    }
    private var t1WorkItem: DispatchWorkItem?
    private var reclaimTimeoutWork: DispatchWorkItem?

    private enum Keys {
        static let state = "PodLoanPhoneController.state"
        static let epoch = "PodLoanPhoneController.epoch"
        static let cursor = "PodLoanPhoneController.cursor"
        static let pendingRevoke = "PodLoanPhoneController.pendingRevoke"
        static let committedIDs = "PodLoanPhoneController.committedIDs"
        static let loanStartedAt = "PodLoanPhoneController.loanStartedAt"
        // §5.3.3 post-reclaim re-audit state
        static let deliveredAtGrant = "PodLoanPhoneController.deliveredAtGrant"
        static let expectedUnits = "PodLoanPhoneController.expectedUnits"
        static let watchAuditRan = "PodLoanPhoneController.watchAuditRan"
        /// Item 1: the last loan's delivered total measured against a PHONE-read end odometer.
        static let deliveredAuthoritative = "PodLoanPhoneController.deliveredAuthoritative"
        /// R32(b): every authoritative residual, so the loose thresholds get tightened from data.
        static let residualHistory = "PodLoanPhoneController.residualHistory"
    }

    private enum NotificationID {
        static let t1 = "podloan.t1"           // start-confirmation, 5 min (R8)
        static let duration = "podloan.6h"     // loan-duration reminder, 6 h (R8)
        static let paused = "podloan.paused1h" // paused-dosing reminder, 1 h repeating (R8)
        /// Silent informational notice carrying the bench reclaim action — NOT an
        /// alarm (R8's inventory governs alarms); replaced by real UI later.
        static let onLoan = "podloan.onloan"
    }

    /// Derived — what v1 kept as the volatile `podLoanedToWatch` flag (:480/:697).
    /// #92/#109: the grant is out but the watch has NOT confirmed it has the pod. Distinct from
    /// `podIsOnLoan`, which is true here too — this is the narrower "in transit, outbound" window
    /// the tile shows as "Taking over…". Ends when `.takeoverComplete` arrives (state -> .loaned)
    /// or the loan is abandoned.
    var isPodTakeoverInProgress: Bool {
        return state == .grantOffered
    }

    var podIsOnLoan: Bool {
        switch state {
        case .owner: return false
        case .grantOffered, .loaned, .reconciling, .reclaimPending: return true
        }
    }

    init(dependencies: Dependencies) {
        self.deps = dependencies
        self.state = State(rawValue: UserDefaults.standard.string(forKey: Keys.state) ?? "") ?? .owner
        self.epoch = UserDefaults.standard.object(forKey: Keys.epoch) as? Int ?? 0
        self.committedCursor = UserDefaults.standard.object(forKey: Keys.cursor) as? Int ?? 0
        self.pendingRevoke = UserDefaults.standard.bool(forKey: Keys.pendingRevoke)
        self.loanStartedAt = UserDefaults.standard.object(forKey: Keys.loanStartedAt) as? Date
        if let raw = UserDefaults.standard.array(forKey: Keys.committedIDs) as? [String] {
            self.committedIDs = Set(raw.compactMap(UUID.init(uuidString:)))
        } else {
            self.committedIDs = []
        }
        loadStaged()

        // Relaunch during a non-owner state: dosing stays paused (persisted-state
        // derivation is the whole point). Re-post the recovery affordance so the user
        // is never stranded with no way back to OWNER (bug E), and re-arm the reclaim
        // escalation if we were mid-reclaim.
        if podIsOnLoan {
            deps.setAutomaticDosingPaused(true)
            // Transient states (reconciling / reclaim-pending / grant-offered) should
            // resolve quickly; a relaunch still sitting in one means it stranded, so
            // give it a bounded self-heal to OWNER (records preserved). LOANED is NOT
            // healed — a relaunch during a real multi-hour loan is normal (R8); its
            // recovery is a new request or the escape hatch, never a timer.
            if state == .reconciling || state == .reclaimPending {
                armPausedReminder()
                let stranded = state
                queue.asyncAfter(deadline: .now() + 120) { [weak self] in
                    guard let self = self, self.state == stranded else { return }
                    self.forceReclaimToOwner(reason: "relaunched into \(stranded.rawValue), no hand-back")
                }
            } else if state == .grantOffered {
                // The T1 alarm doesn't survive relaunch; re-arm the auto-reclaim.
                armT1(for: epoch)
            }
        }
    }

    // MARK: - Incoming

    func handleIncoming(userInfo: [String: Any]) {
        queue.async { self.handleIncomingOnQueue(userInfo) }
    }

    private func handleIncomingOnQueue(_ userInfo: [String: Any]) {
        let message: LoanMessage?
        do {
            message = try LoanMessage.decode(fromTransport: userInfo)
        } catch {
            sendMessage(.nack(ProtocolNack(seenVersion: nil)))
            deps.issueNotice("Loan Protocol Error", "The watch sent a message this phone build cannot read. Update one of the builds. Nothing was discarded.")
            return
        }
        guard let message = message else { return }

        switch message {
        case .request(let request):
            handleRequest(request)
        case .takeoverComplete(let complete):
            handleTakeoverComplete(complete)
        case .takeoverFailed(let failed):
            handleTakeoverFailed(failed)
        case .doseRecordBatch(let batch):
            handleBatch(batch)
        case .handbackOffer(let offer):
            handleHandbackOffer(offer)
        case .statusReport(let report):
            handleStatusReport(report)
        case .nack:
            deps.issueNotice("Loan Protocol Error", "The watch could not read this phone's messages. Update one of the builds.")
        case .grant, .handbackAck, .revoke, .statusQuery, .denied, .diag:
            break  // watch-bound kinds (diag is phone→watch only)
        }
    }

    // MARK: - Grant (§2.2)

    private func handleRequest(_ request: LoanRequest) {
        // #42 (2026-08-02): suppress a TRANSPORT redelivery of the same request. This is not
        // the same as a user tapping Start twice — a second tap arrives seconds later against
        // settled state, whereas a redelivered copy arrives milliseconds later while the FIRST
        // is still in flight. Field 18:20:54 that day: copy 1 granted epoch 122 and released
        // the pod; copy 2 landed in .grantOffered, took the stale-state recovery below,
        // force-reclaimed the pod it had just released (`released=false`) and re-granted —
        // which the reclaim-settle guard then denied. The watch was left holding a grant for a
        // pod still on the phone, so every ladder read returned `no-peripheral` and the loan
        // died. Genuine retries carry a fresh ID and are unaffected; a pre-207 watch sends no
        // ID and behaves exactly as before.
        if let id = request.requestID, id == lastRequestID,
           let seenAt = lastRequestAt,
           deps.now().timeIntervalSince(seenAt) < Self.requestDedupeWindow {
            os_log("Duplicate loan request %{public}@ ignored (transport redelivery, %.1fs after the first)",
                   log: log, type: .default, id, deps.now().timeIntervalSince(seenAt))
            return
        }
        if let id = request.requestID {
            lastRequestID = id
            lastRequestAt = deps.now()
        }
        guard request.supportedVersions.contains(LoanProtocol.version) else {
            sendMessage(.nack(ProtocolNack(seenVersion: request.supportedVersions.max())))
            return
        }
        guard state == .owner else {
            // A NEW request means the watch is NOT in a loan — so a lingering
            // non-owner state is stale. Recover instead of refusing forever (bug E).
            switch state {
            case .grantOffered, .reconciling, .reclaimPending:
                // No live watch dosing in these states → safe to reset and grant now.
                os_log("Loan request while %{public}@ — recovering stale state and granting", log: log, type: .default, state.rawValue)
                forceReclaimToOwner(reason: "new request while \(state.rawValue)")
                beginGrant()
            case .loaned:
                // Possibly a live loan → don't steal the pod silently. Revoke (single-
                // writer preserved); the reclaim escalation forces to owner if the watch
                // is gone. The user retries in a moment.
                os_log("Loan request while LOANED — revoking the previous loan first", log: log, type: .default)
                reclaimNow()
                deny("Reclaiming the previous loan from the watch — try Start again in a few seconds.")
            case .owner:
                break
            }
            return
        }
        beginGrant()
    }

    /// Refuse the request AND tell the watch why (so it shows the reason instead of
    /// hanging on "requesting…"), plus a local phone banner for good measure.
    private func deny(_ reason: String) {
        os_log("Loan denied: %{public}@", log: log, type: .default, reason)
        sendMessage(.denied(LoanDenied(reason: reason)))
        deps.issueNotice("Sport Mode Not Started", reason)
    }

    private func beginGrant() {
        guard let pump = deps.pumpManager() else {
            deny("No pump is set up on the phone.")
            return
        }
        guard let lendable = pump as? PumpConnectionLendable else {
            deny("This pump can't be loaned to the watch (\(type(of: pump))).")
            return
        }

        // #42: don't hand a still-returning pod to the watch. After a reclaim the phone
        // enters .owner but the pod BLE isn't truly back for up to ~2 min — reclaimConnection()
        // only re-arms the bid. Granting inside that settle window releases a half-reconnected
        // pod, and the watch's takeover then races the phone's in-flight link → takeover fails
        // (the "rapid hand-back → re-takeover" bug). Deny-and-retry until the pod is genuinely
        // reachable (isConnectionReady) or the settle ceiling clears — conservative: it never
        // grants a not-ready pod, and the user's next Start succeeds once it's home.
        // #42 (2026-08-02): readiness = a completed pod ROUND-TRIP since the reclaim began,
        // NOT the peripheral state. isConnectionReady() flips true within seconds of hand-back
        // (baseband connect) while the pod's actual return work hasn't happened; grants issued
        // on that signal released a half-returned pod and the watch takeover flapped against it
        // for ~90 s (every recorded failure was inside this window — 9-85 s gaps; every success
        // outside). The chase in beginReclaimSettleWindow makes verification prompt, so this
        // deny window is short in practice when the phone is awake.
        if let started = reclaimStartedAt,
           deps.now().timeIntervalSince(started) < Self.reclaimSettleTimeout,
           reclaimVerifiedAt == nil {
            os_log("Grant deferred: pod still returning from the last reclaim (%.0fs into settle, round-trip not yet verified) — deny-and-retry",
                   log: log, type: .default, deps.now().timeIntervalSince(started))
            deny("The pod is still returning from the last session. Try Start again in a few seconds.")
            attemptReclaimVerificationNow(started: started)   // the tap accelerates the return check
            return
        }

        // Deny-on-missing (R1/R16): the grant is refused, never defaulted.
        let settings = deps.settings()
        guard settings.basalRateSchedule != nil,
              settings.insulinSensitivitySchedule != nil,
              settings.carbRatioSchedule != nil,
              settings.glucoseTargetRangeSchedule != nil,
              settings.maximumBasalRatePerHour != nil,
              settings.maximumBolus != nil else {
            deny("Therapy settings are incomplete; the watch can't dose without them.")
            return
        }

        // Fix 1 (#69, field-confirmed boundaryDup=YES): DO NOT emit a boundaryRecord.
        // The running temp is (near-always) already in `doseHistory` — getNormalizedDoseEntries
        // returns the open mutable temp, fetched below AFTER releaseConnection (which only
        // truncates the in-memory pod state via cancel(at:), never the dose store). A separate
        // same-start, same-rate boundaryRecord is therefore a duplicate of that temp, and seeding
        // both double-counts the [start→handover] slice (the ~0.3 U IOB bump at takeover). The
        // watch's stock reconciled() truncates the seeded open temp when it enacts its first
        // command. (Narrow caveat: if a just-set temp has not yet reached the dose store, the seed
        // could miss it for a few seconds — acceptably rarer than the double-seed it replaces.)
        // The .boundaryTruncation Kind + LoanReconciler's handling of it are LEFT in place as
        // defensive/back-compat tolerance ONLY: the watch hand-back journal never mints that kind,
        // so those arms are now vestigial in production (an older phone may still send one).
        let handedOverAt = deps.now()

        // §5.3.3: capture the odometer NOW (the phone was polling until this moment)
        // so the post-reclaim re-audit has a loan-start baseline even if the watch
        // dies before ever sending one.
        if let delivered = lendable.lentDeviceInsulinDelivered {
            UserDefaults.standard.set(delivered, forKey: Keys.deliveredAtGrant)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.deliveredAtGrant)
        }
        UserDefaults.standard.set(false, forKey: Keys.watchAuditRan)
        UserDefaults.standard.removeObject(forKey: Keys.expectedUnits)

        // Pause dosing, then stop bidding for the pod (C5 truncation happens inside).
        deps.setAutomaticDosingPaused(true)
        // #42 diagnosis: if the phone doesn't actually drop the pod BLE here, the watch's
        // takeover reads "pod unreachable" (a pod is a single-central peripheral). Relay the
        // release state to the watch's iCloud log — before, and a +3s confirm (release is async).
        let releaseEpoch = epoch + 1
        handbackDiag(releaseEpoch, "GRANT — releasing pod BLE (wasReleased=\(lendable.isConnectionReleased))")
        lendable.releaseConnection()
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak lendable] in
            guard let self = self, let lendable = lendable else { return }
            // `released` is a FLAG — set synchronously by releaseConnection, it says only that we
            // asked. `linkUp` is `isConnectionReady`, which on OmniPumpManager is literally
            // `podLoanConnectionStateDescription == "connected"` — the peripheral's own state.
            //
            // This is the line the whole takeover investigation has been missing. 4 of 6 takeovers
            // failed on build 234, every connect returning connectionLimitReached while the WATCH's
            // central held nothing — so something else held the slot, and the only candidate we
            // could not test was "the phone never actually let go". released=true says nothing
            // about that. linkUp=true three seconds after a release says it outright.
            self.handbackDiag(releaseEpoch, "GRANT +3s — pod BLE released=\(lendable.isConnectionReleased) linkUp=\(lendable.isConnectionReady)")
            if lendable.isConnectionReady {
                self.handbackDiag(releaseEpoch, "GRANT +3s — ** STILL CONNECTED after release — the watch's takeover will be refused (single-central pod) **")
            }
            PhoneLog.flush()   // the analysis wants this file current at exactly this moment
        }

        epoch += 1
        state = .grantOffered
        committedCursor = 0
        committedIDs = []
        persistCommittedIDs()
        staged = [:]
        stagedTombstones = []
        persistStaged()
        loanStartedAt = handedOverAt
        UserDefaults.standard.set(handedOverAt, forKey: Keys.loanStartedAt)

        let grantEpoch = epoch
        let historyStart = handedOverAt.addingTimeInterval(-.hours(16))
        // Fetch insulin AND carb history before building the grant (#49). Nested so both
        // are in hand at construction; the same 16h window that seeds IOB now seeds COB.
        // 3 h of glucose (the Integral RC look-back) seeds momentum + RC; the 16 h window seeds
        // IOB and COB. Nested so all three are in hand at construction.
        let glucoseStart = handedOverAt.addingTimeInterval(-.hours(3))
        deps.doseHistory(historyStart) { [weak self] history in
            guard let self = self else { return }
            self.deps.carbHistory(historyStart) { [weak self] carbs in
                guard let self = self else { return }
                self.deps.glucoseHistory(glucoseStart) { [weak self] glucose in
                    guard let self = self else { return }
                    // INSTRUMENTATION ONLY (#45): capture the phone's last-computed prediction
                    // decomposition (cached read, no recompute) as a fourth nested fetch, so it
                    // rides in the grant. Default nil closure ⇒ this is a no-op for tests / old builds.
                    self.deps.predictionSnapshot { [weak self] snapshot in
                    guard let self = self else { return }
                    self.queue.async {
                        guard self.state == .grantOffered, self.epoch == grantEpoch else { return }
                        guard let stateData = try? PropertyListSerialization.data(fromPropertyList: pump.rawValue, format: .binary, options: 0),
                              let settingsData = try? PropertyListSerialization.data(fromPropertyList: settings.rawValue, format: .binary, options: 0) else {
                            self.abortGrant(reason: "snapshot encoding failed")
                            return
                        }
                        let grant = LoanGrant(
                            epoch: grantEpoch,
                            expiresAt: handedOverAt.addingTimeInterval(.minutes(5)),
                            pumpManagerRawState: stateData,
                            podAddress: 0,
                            therapySettingsRaw: settingsData,
                            settingsTimeZoneID: settings.basalRateSchedule?.timeZone.identifier ?? TimeZone.current.identifier,
                            doseHistory: history.compactMap(Self.loanRecord(from:)),
                            boundaryRecord: nil,   // Fix 1: running temp already lives in doseHistory (see above)
                            supportsInterimHandback: true,   // WS1 capability gate (REAL-3)
                            supportsOverrideRecords: true,   // #68B: this phone decodes .overrideChange
                            // Same source LoopDataManager:458 reads. Without this the watch runs
                            // Standard RC while this phone may be running Integral — different
                            // predictions from identical inputs, silently (audit 2026-07-22).
                            integralRetrospectiveCorrectionEnabled: UserDefaults.standard.integralRetrospectiveCorrectionEnabled,
                            // R23 OVERTURNED 2026-08-04 (Jeremy): the wrist follows the phone's
                            // loop mode instead of resetting to OPEN each loan. Snapshotted at
                            // the grant like the therapy settings, so a later phone-side toggle
                            // does not reach through to a loan already in flight.
                            phoneClosedLoopEnabled: settings.dosingEnabled,
                            carbHistory: carbs,
                            glucoseHistory: glucose,
                            predictionSnapshot: snapshot)
                        self.sendMessage(.grant(grant))
                        self.armT1(for: grantEpoch)
                    }
                    }
                }
            }
        }
    }

    private func abortGrant(reason: String) {
        os_log("Grant aborted: %{public}@", log: log, type: .error, reason)
        sendMessage(.denied(LoanDenied(reason: "The loan could not start (\(reason)). The phone kept the pod.")))
        reclaimToOwner(alert: ("Pod Loan Failed", "The loan could not start (\(reason)). The phone kept the pod."))
    }

    /// T1 (R8): 5 min start-confirmation, cancelled by TakeoverComplete. Row 4:
    /// query-before-reclaim — a watch whose TakeoverComplete was lost gets one chance
    /// to prove it holds the pod before auto-reclaim.
    /// #108: how long to wait before ASKING whether the hand-over arrived. Not how long to wait
    /// before acting — those got conflated, and only the acting needed to be patient.
    ///
    /// A normal takeover completes in ~13 s (field 2026-08-11), so by 20 s a healthy loan has
    /// already left `.grantOffered` and this never fires. A slow-but-fine takeover answers
    /// "yes I have the grant" and nothing happens. Only an explicit "I never got it" acts.
    private static let grantLostProbeDelay: TimeInterval = 20

    /// #108: probe once, early, for a hand-over that never landed.
    ///
    /// The failure it catches: the phone has already stopped dosing and already released the pod
    /// (it must, so the watch can take it) when the grant is lost in transit. Nobody then holds
    /// the pod. It keeps delivering its last program on its own — no hazard — but no loop is
    /// adjusting anything on either device, and until 2026-08-11 that lasted 5 min 15 s.
    ///
    /// Jeremy hit it installing build 267 (Start tapped ~4 s after install, before the watch
    /// messaging channel had finished waking); he force-quit rather than wait it out.
    ///
    /// SILENCE IS NOT "NO". An unreachable watch that is perfectly fine and mid-takeover looks
    /// identical, from here, to a watch that never heard anything. So this only sends a question;
    /// the answer path (handleStatusReport) acts on an explicit `knowsGrant == false` and nothing
    /// else. No answer ⇒ the original 5-minute timer runs exactly as before.
    private func armGrantLostProbe(for grantEpoch: Int) {
        queue.asyncAfter(deadline: .now() + Self.grantLostProbeDelay) { [weak self] in
            guard let self = self, self.state == .grantOffered, self.epoch == grantEpoch else { return }
            self.handbackDiag(grantEpoch, String(format: "grant unconfirmed after %.0fs — asking the watch whether it arrived (#108)", Self.grantLostProbeDelay))
            self.sendMessage(.statusQuery(StatusQuery(epoch: grantEpoch)))
        }
    }

    private func armT1(for grantEpoch: Int) {
        armGrantLostProbe(for: grantEpoch)
        scheduleNotification(id: NotificationID.t1, title: "Watch Loan Not Confirmed",
                             body: "The watch never confirmed taking the pod. The phone reclaimed it.",
                             delay: .minutes(5), repeats: false)
        t1WorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .grantOffered, self.epoch == grantEpoch else { return }
            self.sendMessage(.statusQuery(StatusQuery(epoch: grantEpoch)))
            let confirm = DispatchWorkItem { [weak self] in
                guard let self = self, self.state == .grantOffered, self.epoch == grantEpoch else { return }
                self.reclaimToOwner(alert: ("Watch Loan Failed", "The watch never confirmed taking the pod. The phone reclaimed it."))
            }
            self.t1WorkItem = confirm
            self.queue.asyncAfter(deadline: .now() + 15, execute: confirm)
        }
        t1WorkItem = work
        queue.asyncAfter(deadline: .now() + .minutes(5), execute: work)
    }

    private func handleTakeoverComplete(_ complete: TakeoverComplete) {
        guard complete.epoch == epoch, state == .grantOffered else { return }
        t1WorkItem?.cancel()
        cancelNotification(id: NotificationID.t1)
        state = .loaned
        scheduleNotification(id: NotificationID.duration, title: "Pod Still On Loan",
                             body: "The pod has been on the watch for 6 hours.",
                             delay: .hours(6), repeats: false)

        // Silent on-loan notice with the escape-hatch action (long-press → Reclaim
        // Pod). The bench trigger for drills 12/13; the UI phase replaces it.
        let content = UNMutableNotificationContent()
        content.title = "Pod Is On the Watch"
        content.body = "The watch is running the loop. Long-press for the escape hatch."
        content.categoryIdentifier = NotificationManager.podLoanCategoryIdentifier
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: NotificationID.onLoan, content: content, trigger: nil))
    }

    private func handleTakeoverFailed(_ failed: TakeoverFailed) {
        guard failed.epoch == epoch, state == .grantOffered else { return }
        t1WorkItem?.cancel()
        cancelNotification(id: NotificationID.t1)
        reclaimToOwner(alert: ("Watch Loan Failed", "The watch could not take the pod (\(failed.reason)). The phone kept it."))
    }

    private func handleStatusReport(_ report: StatusReport) {
        guard report.epoch == epoch else { return }
        // Row 4: the query-before-reclaim answer.
        if state == .grantOffered, report.holdsPod {
            handleTakeoverComplete(TakeoverComplete(epoch: report.epoch, firstPodStatus: LoanPodStatus(timestamp: deps.now(), deliveredUnits: nil, reservoirLevel: nil, isSuspended: false, faultCode: report.podFault)))
        }
        // #108: the watch says outright that the hand-over never reached it. Take the pod back
        // now rather than in five more minutes — the phone released it for a takeover that is
        // never going to start, so every second after this answer is time nobody is looping.
        //
        // `== false` deliberately, not `!= true`: nil is an older build that could not answer, and
        // must fall through to the 5-minute timer. Only an explicit denial acts.
        if state == .grantOffered, report.knowsGrant == false, !report.holdsPod {
            handbackDiag(report.epoch, "grant CONFIRMED LOST by the watch — reclaiming now instead of waiting out the 5-minute timer (#108)")
            t1WorkItem?.cancel()
            cancelNotification(id: NotificationID.t1)
            reclaimToOwner(alert: ("Sport Mode Didn't Start",
                                   "The watch never received the hand-over, so the phone kept the pod and is still looping. Tap Start again."))
        }
        if let fault = report.podFault {
            deps.issueNotice("Pod Fault During Loan", "The pod reported a fault while on the watch: \(fault). Check the pod.")
        }
    }

    // MARK: - Records (§2.4-2.6)

    private func handleBatch(_ batch: DoseRecordBatch) {
        guard batch.epoch == epoch, state == .loaned || state == .reclaimPending else { return }
        stage(events: batch.events, tombstones: batch.tombstones)
    }

    /// #35: relay a phone-side hand-back breadcrumb to the watch (which mirrors to iCloud)
    /// AND os_log it, so the phone's offer→write→ack path is visible when the phone
    /// silently fails to ack. Purely diagnostic.
    private func handbackDiag(_ epoch: Int, _ text: String) {
        os_log("HANDBACK-DIAG e%d: %{public}@", log: log, type: .default, epoch, text)
        // ...and into the phone's own mirrored file. These lines are relayed to the WATCH's log
        // too, but only while the watch is reachable and only as a [phone] echo. The file is the
        // phone's independent account — which is what was missing when both the hand-back stall
        // and the takeover failures came down to "did the phone actually release the pod?".
        PhoneLog.event("loan", "e\(epoch) \(text)")
        sendMessage(.diag(LoanDiag(epoch: epoch, text: text)))
    }

    private func handleHandbackOffer(_ offer: HandbackOffer) {
        // Stale epoch (rows 13/14): the records still drain — they are historical
        // truth, idempotent by ID — but loan STATE is untouched and the ack says
        // stale so the sender stops retrying. Dead loans cannot speak.
        let isStale = offer.epoch < epoch
        guard offer.epoch == epoch || isStale else {
            // #35 liveness: the offer is AHEAD of this phone's epoch (the watch is on a
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

        // WS1 (two-phase hand-back): an INTERIM offer (released == false) means the
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
        }
        // Round-2 fix: the odometer audit runs ONLY on the transition-owning final
        // offer. A duplicate final (routine: 15s resends vs ack latency) arrives
        // after finishLoanAfterCommit cleared `staged` — its re-staged tail is a
        // SUBSET of the loan, and auditing the whole-loan odometer against it mints
        // phantom remainders (the R1 bug, reintroduced via this path). Interim
        // offers carry freshened=false anyway; this makes the skip explicit.
        let auditThisOffer = !isStale && isFinal && state == .reconciling

        stage(events: offer.events, tombstones: offer.tombstones)
        // Round-4 fix: dedup by EVENT ID only. The seq>cursor condition assumed a
        // gapless cursor; WS1 withholding creates gaps (an in-flight command's seq
        // can arrive AFTER later events were acked), and it would silently discard
        // the late-classified event. committedIDs is persisted — the ID filter is
        // the true exactly-once invariant.
        //
        // #102 (field 2026-08-11 00:16): A MESSAGE MAY ONLY CAUSE WORK RELATED TO ITSELF.
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
        // WS1: the odometer audit must see the WHOLE loan's journal, not the tail —
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
            // Interim WS1 drain (watch still dosing): don't clamp a still-open temp to
            // this drain instant — that would orphan its post-drain delivery (#69).
            isFinalHandback: isFinal)
        let outcome = LoanReconciler.reconcile(input)

        // §5.3.3 audit inputs: the expected total over the WHOLE loan (all staged
        // events, not just this drain) and whether the watch's own audit ran.
        if auditThisOffer {
            let expected = LoanReconciler.expectedInsulin(events: allStagedEvents, schedule: deps.settings().basalRateSchedule,
                                                          from: loanStart, to: offer.handedBackAt)
            UserDefaults.standard.set(expected, forKey: Keys.expectedUnits)
            UserDefaults.standard.set(offer.odometer?.freshenSucceeded == true, forKey: Keys.watchAuditRan)

            // THE AUDIT (2026-08-11, Jeremy's design): does the pod's own odometer agree with the
            // delivery history the watch claims to have executed?
            //
            //   delivered = the pod's cumulative-delivered DELTA over the loan — an independent,
            //               pulse-counted physical measurement we did not compute.
            //   expected  = expectedInsulin(ALL staged events + the basal schedule filling every
            //               uncovered gap) — i.e. the odometer reading implied by our own records.
            //   residual  = delivered - expected. THIS is the number the R32 open-loop decision
            //               keys on. Tolerance is ONE PULSE (0.05 U) plus any bolus mid-delivery:
            //               both sides are pulse-quantized (supported rates are multiples of 0.05),
            //               so the only genuine ambiguity is whether the pulse due at the boundary
            //               has fired yet. That makes the threshold principled rather than guessed.
            //
            // WHY THIS LINE CHANGED (field 2026-08-11, twice): it used to print cmdCont/cmdFloor
            // from `outcome.doses` — the doses committed in THIS drain — against `delivered`, which
            // spans the WHOLE loan. After an interim drain the final offer carries no events, so the
            // line read "delivered=6.000 cmdFloor=0.000 remFloor=+6.000" and again "delivered=1.400
            // … remFloor=+1.400": six and one-point-four units of phantom missing insulin, pure
            // scope mismatch. `expected` was computed correctly on the line above and written only to
            // UserDefaults, so the audit has been running for weeks with nobody able to see its
            // answer. The drain-scoped figures are kept, clearly labelled, because they are still
            // useful for "what did THIS drain write".
            //
            // Still NO user-facing action here (R32's warning + the IOB valve remain unwired) —
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

            // …and hold the audit open for a FIRST-HAND end reading (item 1, 2026-08-11).
            //
            // The line above is provisional because its end reading comes from the watch, and at
            // hand-back the watch cannot read the pod: it released the BLE link after its last dose
            // window, so both its cancel and its odometer freshen fail in about a millisecond. That
            // is why `fresh=N` on every hand-back on record. The endpoint is whatever the odometer
            // said at the last dose — up to ~5 minutes and one temp's delivery ago.
            //
            // The phone, meanwhile, does a real pod round-trip within seconds of reclaim to verify
            // the pod is home (#42's chase). It was already reading the odometer and throwing the
            // value away. Take it: same audit, same tolerance, an endpoint that is actually the end.
            if isFinal, let start = offer.odometer?.deliveredAtStart {
                pendingHandbackAudit = PendingHandbackAudit(
                    epoch: offer.epoch, deliveredAtStart: start, expected: expected,
                    loanMinutes: loanMin, cycles: allStagedEvents.count,
                    watchLatest: offer.odometer?.deliveredLatest,
                    watchFreshened: offer.odometer?.freshenSucceeded == true)
            }
        }

        // No additional insulin is added at hand-back (Jeremy 2026-07-27): the R6 positive-remainder
        // IOB valve is disabled for now. IOB comes purely from the streamed reconciled records — stock-
        // like trust; stock never injects odometer-derived IOB. outcome.positiveRemainderUnits is still
        // computed (and captured above) but no longer consumed. Re-enable if/when the reconciliation
        // warning is redesigned with a proper threshold.
        let doses = outcome.doses

        // WS1: the still-open temp (outcome.openEventID) is skipped by the reconciler and
        // kept out of committedIDs, so it re-drains and is written (clamped, immutable) on
        // the final drain. But we STILL ack its seq (newCursor below uses `events`, not
        // `committable`) so the watch's finalize gate (unackedEvents empty) can clear —
        // decoupling the ack cursor from committedIDs is what avoids the finalize deadlock.
        let committable = events.filter { $0.id != outcome.openEventID }

        // Write-events-first; ack ONLY after commit (a897d22c). Failure: no ack, stay
        // reconciling, 1 h reminder repeats (row 11) — never dose on incomplete records.
        // Loan insulin goes through addPumpEvents (PumpEvent table + stock reconciled() +
        // HealthKit); lastReconciliation = handedBackAt (the finalized-through watermark).
        // #102 belt-and-braces: never hand the store a dose that ends before it starts.
        //
        // The stale-offer scoping above removes the cause we know about, but this kills the
        // whole class — and it is the class that is dangerous, because 2026-08-11 only surfaced
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
        deps.addPumpEvents(newPumpEvents(from: sane), offer.handedBackAt) { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    self.handbackDiag(offer.epoch, "write FAILED: \(String(describing: error))")
                    os_log("Reconcile write failed: %{public}@", log: self.log, type: .fault, String(describing: error))
                    // #102: ONCE per failing state, not once per retry. Offers resend every 15 s,
                    // so the 2026-08-11 wedge produced 10-12 identical "Watch Records Not Saved"
                    // warnings on the wrist for a single phone-side bug. A wall of identical
                    // alarms for one fault is how people learn to ignore alarms.
                    if !self.hasWarnedRecordsNotSaved {
                        self.hasWarnedRecordsNotSaved = true
                        self.deps.issueNotice("Watch Records Not Saved", "The watch session's records could not be saved. Dosing stays paused; will retry on the next hand-back attempt.")
                    }
                    self.armPausedReminder()
                    return
                }
                self.hasWarnedRecordsNotSaved = false   // recovered — a future failure is news again

                // #66 (2026-08-04): gate carbs on !isStale, matching the override change below.
                // The commit used to run unconditionally while committedIDs.formUnion sat inside
                // the `if !isStale` block at the bottom of this closure — so a stale redelivery
                // committed the carbs and recorded nothing, and every resend added another copy.
                // Insulin is immune (NewPumpEvent.raw dedupes at the store); carbs have no
                // identity at all, so the cursor is the only guard and it was being skipped.
                if !isStale {
                    for carb in outcome.carbs {
                        self.deps.addCarb(carb) { _ in }  // merge-not-replace at integration
                    }
                    // R30 (#89): deletions ride the same staleness gate as adds — a dead loan
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

                // #68 part B: the watch owned overrides for the loan, so a drained override
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
            }
        }
    }

    // MARK: - #68 part B: watch-enacted overrides landing on the phone

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
        let current = deps.settings().scheduleOverride
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

    private static func overrideNameForLog(_ override: TemporaryScheduleOverride) -> String {
        switch override.context {
        case .preMeal: return "pre-meal"
        case .legacyWorkout: return "workout(legacy)"
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
        cancelNotification(id: NotificationID.duration)
        cancelNotification(id: NotificationID.paused)
        cancelNotification(id: NotificationID.onLoan)
        (deps.pumpManager() as? PumpConnectionLendable)?.reclaimConnection()
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

    /// §5.3.3: the phone asks the pod the same forensic questions after reclaim,
    /// shrinking the dead-watch blind window. Override for tests; the default runs
    /// the real audit 90 s after reclaim (BLE session re-establishment time).
    var postReclaimReAudit: (() -> Void)?
    private func schedulePostReclaimReAudit(recordsCommitted: Bool) {
        queue.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self = self else { return }
            if let override = self.postReclaimReAudit {
                override()
            } else {
                self.performReAudit(recordsCommitted: recordsCommitted)
            }
        }
    }

    /// The post-reclaim re-audit. DIAGNOSTIC-ONLY as of 2026-07-27 (Jeremy): it re-reads
    /// the pod's odometer ~90 s after reclaim and os_log's delivered-vs-expected, but takes
    /// NO user-facing action — the R6 IOB valve and the over/under notices are both disabled
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

    // MARK: - Escape hatch (§3.1 RECLAIM_PENDING, R7)

    func reclaimNow() {
        queue.async {
            guard self.podIsOnLoan else { return }
            self.pendingRevoke = true
            self.cancelNotification(id: NotificationID.onLoan)
            self.sendMessage(.revoke(Revoke(epoch: self.epoch)))
            (self.deps.pumpManager() as? PumpConnectionLendable)?.reclaimConnection()
            self.state = .reclaimPending
            self.armPausedReminder()
            // §5.3.3 dead-watch path: audit against the schedule, notice-only.
            self.schedulePostReclaimReAudit(recordsCommitted: false)
            // R7 override, made real: if the watch never drains within 45 s (dead /
            // gone / already handed off), force back to OWNER so we never strand.
            self.reclaimTimeoutWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.state == .reclaimPending else { return }
                self.forceReclaimToOwner(reason: "reclaim timed out — watch did not drain")
            }
            self.reclaimTimeoutWork = work
            self.queue.asyncAfter(deadline: .now() + 45, execute: work)
        }
    }

    /// The R7 explicit override, made real: abandon a stuck/stale loan and return to
    /// OWNER unconditionally. Records are NOT dropped blindly — any staged events are
    /// written to the store first (records are truth; never understate IOB), then the
    /// pod is reclaimed and dosing restored. Used when a new request proves the old
    /// loan is dead, when reclaim times out, or on a relaunch into a stranded state.
    // (Removed logReconciledDoses — the #69 forensic dump built on `programmedUnits` = rate×FULL
    // temp window, the untruncated "implied Σ" over-count. It was os_log-only, fed no logic, and its
    // sum was physically impossible as delivery (exceeded max basal), so it consistently misled.
    // The trustworthy commanded number is the floored reconciled dose total; the real hand-back
    // reconciliation delta will be captured explicitly instead.)

    func forceReclaimToOwner(reason: String) {
        os_log("Force reclaim to OWNER: %{public}@", log: log, type: .default, reason)
        reclaimTimeoutWork?.cancel()
        cancelNotification(id: NotificationID.onLoan)
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
            deps.addPumpEvents(newPumpEvents(from: outcome.doses), deps.now()) { _ in }
            for carb in outcome.carbs { deps.addCarb(carb) { _ in } }
            for gone in outcome.deletedCarbs {   // R30 (#89)
                deps.deleteCarb(gone) { error in
                    self.handbackDiag(self.epoch, error == nil
                        ? String(format: "carb DELETE applied on phone (recovery) — %.0f g", gone.grams)
                        : String(format: "carb DELETE MISSED on phone (recovery) — %.0f g: %@", gone.grams, String(describing: error!)))
                }
            }
            // #66 (2026-08-04): RECORD what we just committed. This path read committedIDs in
            // the filter above but never added to it, and it sends no handbackAck — so the
            // watch's 15 s resend loop kept redelivering the same offer against an unchanged
            // set, and each delivery committed the carbs again.
            //
            // Insulin survived this because NewPumpEvent carries `raw`, which the store dedupes
            // on. Carbs cannot: NewCarbEntry has no identity field and CarbStore mints a fresh
            // syncIdentifier per addCarbEntry, so the cursor IS the only guard. Duplicate carbs
            // here then mirror into every later grant via wipe-then-replace — the #65
            // phantom-COB failure mode with the phone as the source.
            //
            // Reached whenever a watch goes unreachable mid-loan: the 45 s reachability timeout,
            // a stranded-state relaunch, or a fresh request while still loaned.
            committedIDs.formUnion(events.map(\.id))
            persistCommittedIDs()
            deps.issueNotice("Sport Mode Reset", "A previous watch loan was ended without a clean hand-back; its records were saved. Check Event History and the pod.")
        }

        (deps.pumpManager() as? PumpConnectionLendable)?.reclaimConnection()
        pendingRevoke = false
        state = .owner
        deps.setAutomaticDosingPaused(false)
        staged = [:]
        stagedTombstones = []
        persistStaged()
    }

    /// Re-send a parked revoke on any sign of watch life (kept from v1).
    func watchDidBecomeReachable() {
        queue.async {
            if self.pendingRevoke {
                self.sendMessage(.revoke(Revoke(epoch: self.epoch)))
            }
        }
    }

    // MARK: - Helpers

    private func reclaimToOwner(alert: (title: String, body: String)) {
        cancelNotification(id: NotificationID.onLoan)
        (deps.pumpManager() as? PumpConnectionLendable)?.reclaimConnection()
        state = .owner
        deps.setAutomaticDosingPaused(false)
        deps.issueNotice(alert.title, alert.body)
    }

    private func stage(events: [LoanEvent], tombstones: [UUID]) {
        for event in events { staged[event.id] = event }
        stagedTombstones.formUnion(tombstones)
        persistStaged()
    }

    private func sendMessage(_ message: LoanMessage) {
        guard let dictionary = try? message.transportDictionary() else { return }
        deps.send(dictionary)
    }

    private static func loanRecord(from dose: DoseEntry) -> LoanDoseRecord? {
        // #69: carry the phone's stable syncIdentifier (so the watch's re-seeds upsert-dedup instead
        // of accumulating) and insulinType (so the watch decays on the same model). Both flow through
        // seedDoseEntry → the seeded DoseEntry.
        switch dose.type {
        case .bolus:
            return LoanDoseRecord(kind: .bolus, startDate: dose.startDate, endDate: dose.endDate, amount: dose.deliveredUnits ?? dose.programmedUnits,
                                  syncIdentifier: dose.syncIdentifier, insulinType: dose.insulinType)
        case .tempBasal:
            // #80: send the pod's ACTUAL floored delivery (the bolus arm above already does) —
            // without it the watch re-derives with round() and over-states IOB by ~0.025 U per
            // elapsed temp slice (field 2026-07-30: phone 0.70 vs watch 1.00 over 33 slices).
            return LoanDoseRecord(kind: .tempBasal, startDate: dose.startDate, endDate: dose.endDate, unitsPerHour: dose.unitsPerHour,
                                  syncIdentifier: dose.syncIdentifier, insulinType: dose.insulinType,
                                  deliveredUnits: dose.deliveredUnits)
        case .suspend:
            return LoanDoseRecord(kind: .suspend, startDate: dose.startDate, endDate: dose.endDate, unitsPerHour: 0,
                                  syncIdentifier: dose.syncIdentifier, insulinType: dose.insulinType,
                                  deliveredUnits: dose.deliveredUnits)
        case .basal, .resume:
            return nil
        }
    }

    // MARK: - R8 notifications (the COMPLETE alarm inventory)

    private func scheduleNotification(id: String, title: String, body: String, delay: TimeInterval, repeats: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: repeats)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func cancelNotification(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    private func armPausedReminder() {
        scheduleNotification(id: NotificationID.paused, title: "Automatic Dosing Paused",
                             body: "Dosing has been paused since the pod loan ended without complete records. Reconcile or re-enable Closed Loop to override.",
                             delay: .hours(1), repeats: true)
    }

    // MARK: - Staging persistence (trap-cell defense survives phone relaunch)

    private var stagedFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PodLoanStagedRecordsV2.json")
    }

    private struct StagedState: Codable {
        let epoch: Int
        let events: [LoanEvent]
        let tombstones: [UUID]
    }

    private func persistStaged() {
        let snapshot = StagedState(epoch: epoch, events: Array(staged.values), tombstones: Array(stagedTombstones))
        if let data = try? LoanProtocol.encoder.encode(snapshot) {
            try? data.write(to: stagedFileURL, options: .atomic)
        }
    }

    private func loadStaged() {
        guard let data = try? Data(contentsOf: stagedFileURL),
              let snapshot = try? LoanProtocol.decoder.decode(StagedState.self, from: data),
              snapshot.epoch == epoch else { return }
        for event in snapshot.events { staged[event.id] = event }
        stagedTombstones.formUnion(snapshot.tombstones)
    }

    private func persistCommittedIDs() {
        UserDefaults.standard.set(committedIDs.map(\.uuidString), forKey: Keys.committedIDs)
    }
}
