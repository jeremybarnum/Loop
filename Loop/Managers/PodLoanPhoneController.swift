//
//  PodLoanPhoneController.swift
//  Loop
//
//  The phone half of loan protocol v2 (docs/DESIGN_LOAN_PROTOCOL_V2.md §3.1, §10).
//  Persisted state machine (podLoanedToWatch is DERIVED from this state, never a
//  volatile flag), epoch minting, grant assembly with deny-on-missing, the alarm
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

    /// What a reclaim is doing right now — published so the tile can name the situation instead of
    /// implying progress that isn't happening, and so the pump pill can draw a DETERMINATE bar for
    /// the one part of the return that is long enough to be worth drawing.
    ///
    /// ONLY THE SETTLE CARRIES A FRACTION, and it was not the half this started as. The ownership
    /// handover — the drain and, failing that, the force — was measured at 736 ms for a
    /// phone-tapped reclaim on 2026-08-14 and runs sub-second on a watch-initiated hand-back;
    /// dosing and prediction are back on the phone's screen that fast. A bar over a sub-second
    /// event is a flash, so the handover phases publish a nil `fraction` and the pill sweeps
    /// through them. The BLE settle behind it — the phone re-establishing its own pod link and
    /// proving it with one round-trip — is the wait the user actually sits through, and it gets
    /// the bar (see `reclaimSettleExpectation` for the promise and its evidence).
    struct ReclaimProgress: Equatable {
        enum Phase: Equatable {
            /// The watch was heard from within one log-pulse period, or is reachable now: its
            /// records are draining and the wait is a real drain window. Carries a determinate
            /// fraction against the drain promise — the sweep is retired.
            case draining
            /// The drain promise expired without an answer: the bar holds at its cap and the
            /// label concedes the trouble, twelve to fifteen seconds before the force resolves
            /// it. Deliberately entered at the same moment the second revoke goes out, so the
            /// concession and the last attempt are one event.
            case watchNotAnswering
            /// Taking the pod back without the watch's cooperation. The dead branch enters this
            /// the moment it is chosen — it waits for nothing — and a force deferred behind an
            /// in-flight commit stays described by it.
            case forcing
            /// Ownership is already back on the phone, but the phone has not yet completed the pod
            /// round-trip that proves the pod is home — it is re-establishing the BLE session.
            /// Reached identically from a tapped reclaim and from a watch-initiated hand-back,
            /// which is why it hangs off the settle window rather than off the tapped-reclaim
            /// ladder: a regularly ended session arms no ladder and lands in exactly this wait.
            ///
            /// One stage, no slow-mode re-baseline. The two-stage split existed for a bimodal
            /// settle whose slow mode turned out to be verification calls that skipped the radio
            /// when the manager judged its data fresh; with the forced read in place, every
            /// watch-present settle measured on the fixed build landed in 2-3 s with zero stale
            /// reads. An overrun holds at the cap under the 5-minute ceiling, as ever.
            case reconnectingToPod
            /// The settle that follows a FORCE reclaim, presented as one operation with one
            /// deadline — a bar that re-baselined mid-force would read as a second failure.
            /// Ruled in the field: users understand a force takes a while, so a generous
            /// promise that is occasionally wrong beats a renamed wait.
            case forceReclaimingPod
        }
        let phase: Phase
        /// When the whole wait began — the reclaim tap for a handover, the settle window opening
        /// for a settle. It does NOT move when the settle re-baselines into its second stage, so
        /// `elapsed` below stays a continuous count of how long the user has been waiting.
        let startedAt: Date
        /// The moment the user has been promised an answer by: the force deadline during the
        /// ownership handover, the end of stage one during a fast settle, the end of stage two
        /// once that has expired. Never a ceiling — overrunning it holds the bar at its cap
        /// rather than ending the wait.
        let expectedBy: Date
        /// 0...0.95 within the CURRENT STAGE — or NIL when this phase is too short to draw, which
        /// is every phase except the settle. Deliberately not `startedAt`-to-`expectedBy`: the
        /// settle's second stage is re-baselined at its own entry, so the bar restarts there and
        /// climbs against the slow mode's deadline instead of crawling against a total. Holds at
        /// 0.95 rather than completing, because completion is the tile changing, not the bar
        /// filling.
        ///
        /// A nil here is what leaves the pill on its indeterminate sweep, which is the right
        /// affordance for the one handover that can genuinely take a while: a dead-watch reclaim
        /// waits out the ladder's 20 s force with nothing to report but its labels — "Reaching
        /// Watch…" while the first revoke is out, "Can't Reach Watch" from the resend deadline.
        let fraction: Double?
        /// How long the whole wait has been running, on the controller's own clock, as of the
        /// moment this was read. Published rather than re-derived at the call site so the label's
        /// ticking seconds and the bar's fill can never disagree about when the wait started, and
        /// continuous across the settle's stage change so the counter never appears to reset.
        let elapsed: TimeInterval
    }

    struct Dependencies {
        /// The current pump manager, if any (conditionally cast for lending).
        var pumpManager: () -> PumpManager?
        /// The live therapy settings (snapshot travels in the grant).
        var settings: () -> LoopSettings
        /// Pause/resume the phone's automatic dosing (loan-gated).
        var setAutomaticDosingPaused: (Bool) -> Void
        /// Transport out (WCSession.transferUserInfo at integration).
        var send: ([String: Any]) -> Void
        /// Store writes. Loan insulin goes through the pump-event path (not addDoses) so
        /// it lands in the PumpEvent table (Event History), is run through stock
        /// InsulinMath.reconciled() at the store (overlap truncation), and mirrors into
        /// InsulinDeliveryStore/HealthKit — behaving exactly like real pump insulin.
        var addPumpEvents: ([NewPumpEvent], _ lastReconciliation: Date?, @escaping (Error?) -> Void) -> Void
        /// The String is the watch journal event UUID — the identity the store
        /// inserts-if-absent on. Every redelivery of the same event carries the same string.
        var addCarb: (NewCarbEntry, String, @escaping (Error?) -> Void) -> Void
        /// Remove a carb the WRIST deleted during the loan. Matched on the phone's
        /// syncIdentifier when the watch knew one (phone-originated carbs, which are the only
        /// ones that reach here — watch-entered add/delete pairs cancel in the reconciler), and
        /// on (startDate, grams) otherwise. Default is a no-op so tests and older wiring are
        /// unaffected.
        var deleteCarb: (LoanReconciler.DeletedCarb, @escaping (Error?) -> Void) -> Void = { _, done in done(nil) }

        /// `WCSession.isWatchAppInstalled`. When false, WCSession QUEUES every message rather than
        /// delivering it, so a grant would never reach the watch — see `beginGrant()`. Injected rather
        /// than read from `WCSession.default` so the controller stays testable, and DEFAULTS TO TRUE so
        /// every existing test is unaffected: the guard is opt-in from the app, not a new precondition
        /// the suite has to satisfy.
        var watchAppInstalled: () -> Bool = { true }
        /// Apply a WATCH-enacted temporary schedule override to the phone's
        /// LoopSettings (nil = the wrist cleared it). Sovereignty: while
        /// the watch holds the pod it OWNS overrides, so this is a straight assignment — there
        /// is no merge with whatever the phone thought, and no user prompt. The phone's own
        /// override UI already funnels to a reclaim prompt during a loan, so a competing
        /// phone-side edit cannot exist. Default no-op keeps the state-machine tests (and any
        /// caller that doesn't care about overrides) constructing unchanged.
        /// The override the phone currently holds. Read separately from `settings` because
        /// the override no longer lives on LoopSettings — it belongs to the presets manager,
        /// which is also what makes it take effect.
        var scheduleOverride: () -> TemporaryScheduleOverride? = { nil }
        var applyScheduleOverride: (TemporaryScheduleOverride?) -> Void = { _ in }
        /// The loop inherits the watch's state on the
        /// way back, mirroring the grant's outbound inheritance. Records the WRIST's final loop
        /// mode so the reclaim restores THAT rather than the value captured before the loan.
        /// Default no-op keeps the state-machine tests constructing unchanged.
        var noteWatchClosedLoop: (Bool) -> Void = { _ in }
        /// 16 h insulin history for the grant.
        var doseHistory: (_ start: Date, _ completion: @escaping ([DoseEntry]) -> Void) -> Void
        /// Active carb entries for the grant — seeded so the watch predicts with COB.
        var carbHistory: (_ start: Date, _ completion: @escaping ([LoanCarbRecord]) -> Void) -> Void = { _, done in done([]) }
        /// ~3 h of recent glucose for the grant — seeded so the watch's momentum + retrospective
        /// correction warm from the first post-takeover cycle instead of a cold empty store.
        var glucoseHistory: (_ start: Date, _ completion: @escaping ([LoanGlucoseRecord]) -> Void) -> Void = { _, done in done([]) }
        /// INSTRUMENTATION ONLY: the phone's last-computed prediction, decomposed, carried in
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
        /// Cancel the temp the WATCH left running, the instant the reclaim
        /// round-trip proves we can reach the pod. Stock's own off-cycle `.cancel` idiom — see
        /// LoopDataManager.cancelTempBasalAfterPodReturn. Default no-op keeps the state-machine
        /// tests constructing unchanged.
        var cancelTempBasalAfterPodReturn: (@escaping (Error?) -> Void) -> Void = { $0(nil) }
        /// The pod's odometer disagrees with our books by more than noise —
        /// stop automatic dosing and LEAVE it stopped until the user decides otherwise.
        ///
        /// Deliberately NOT `setAutomaticDosingPaused(true)`. That call pairs with a matching
        /// `(false)` at the next loan's end, which would silently re-close the loop this just
        /// opened — the implementation must also clear the pre-loan capture so no later restore
        /// can undo this. Default no-op keeps the state-machine tests constructing unchanged.
        var openLoopForUncertainReconciliation: () -> Void = {}
        /// Escalated surfacing for the dead-watch reclaim — time-sensitive interruption and
        /// a foreground banner, where `issueNotice` is a quiet list entry. The watch is dead, so
        /// the phone is the only device that can get the user's attention.
        var issueUrgentNotice: (_ title: String, _ body: String) -> Void = { _, _ in }
        /// Book the odometer-gap placeholder as a MANUALLY-ENTERED dose. Deliberately not
        /// the pump-event path: manual doses keep their `syncIdentifier` as their store identity
        /// (pump events overwrite it with hex-of-raw), which is what lets the placeholder be
        /// deleted by that same identifier when the watch's real records arrive.
        var bookGapDose: (_ entry: DoseEntry, _ completion: @escaping (Bool) -> Void) -> Void = { _, done in done(false) }
        /// Retire the placeholder by its syncIdentifier.
        var deleteGapDose: (_ syncIdentifier: String, _ completion: @escaping (Bool) -> Void) -> Void = { _, done in done(false) }
        /// e44 (2026-08-13): UPSERT reconciled loan doses into the delivery store by their store
        /// identity (update-or-insert on syncIdentifier). The only write that can land a loan dose
        /// BEHIND the store's basal boundary — the pump-event path above cannot, which is how a
        /// force-reclaim followed by a late journal commit silently loses every temp. See the call
        /// site in `handleHandbackOffer` for the mechanism. Default no-op keeps the state-machine
        /// tests constructing unchanged.
        var backfillDoses: (_ doses: [DoseEntry], _ completion: @escaping (Error?) -> Void) -> Void = { _, done in done(nil) }
        /// A2: doses just landed BEHIND the phone's counteraction-effect frontier. That memo is
        /// append-only, so the bins covering the loan window still carry the insulin's effect as
        /// if it were unexplained glucose movement, and dynamic carb absorption over-attributes
        /// COB from them until the app relaunches. Prune the memo from the earliest rewritten
        /// dose start and recompute — the same idiom `addReservoirValue` has always used for a
        /// reservoir-inferred dose. Default no-op keeps the state-machine tests constructing
        /// unchanged.
        var insulinHistoryRewritten: (_ earliestDoseStart: Date) -> Void = { _ in }
        /// True when the watch app is reachable RIGHT NOW (WCSession.isReachable at integration).
        /// Admissible only as a POSITIVE signal: reachable proves the watch is alive, but false
        /// proves nothing — in this codebase the flag is a channel selector (urgent vs queued) and
        /// reads false for a healthy watch whose app is merely backgrounded. Default false, so a
        /// caller that does not wire it falls back to the contact-age evidence below.
        /// Hold background execution across a reclaim (tap through verified), stock's own
        /// background-task idiom. Without it, tap-and-pocket freezes the ladder mid-flight and
        /// the pod sits ORPHANED — released by the watch, not yet taken by the phone, nobody
        /// dosing — until the user next looks at the phone. iOS grants ~30 s after
        /// backgrounding, which covers the whole live ladder (force at 25 s) plus a typical
        /// settle; the wall-clock rungs remain the backstop for anything longer. Defaults are
        /// no-ops so tests and harnesses are unaffected.
        var beginReclaimBackgroundTask: () -> Void = {}
        var endReclaimBackgroundTask: () -> Void = {}
        var isWatchReachable: () -> Bool = { false }
        /// When the phone last heard ANYTHING from the watch — any inbound WatchConnectivity
        /// funnel. This, not reachability, is what separates a live watch from a dead one at
        /// reclaim time: a watch holding the pod transfers its log every 300 s, metronomically
        /// (n=134 gaps since 2026-08-08, range 283.1-301.4 s, zero excursions past 302 s), while
        /// the five dead revokes on record had silences of 5.5 to 21.2 MINUTES. nil = nothing
        /// heard, which the reclaim ladder treats as dead. Default nil keeps the state-machine
        /// tests constructing unchanged.
        var lastWatchContactAt: () -> Date? = { nil }
        var now: () -> Date = { Date() }
    }

    /// Code-level configuration: when a force-reclaim's odometer audit finds insulin the
    /// records cannot explain, book that gap as a bolus timestamped AT RECLAIM — zero decay, so
    /// IOB over-counts rather than under-counts until the truth arrives. `false` still opens the
    /// loop and alerts; it only skips the booking.
    static let bookUnattributedInsulinOnForceReclaim = true

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanPhoneController")
    private let queue = DispatchQueue(label: "com.loopkit.Loop.PodLoanPhoneController", qos: .utility)
    private var deps: Dependencies

    // MARK: - Loan → pump-event conversion

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

    /// e44: the overlap truncation the STORE does on the way into the delivery store, done here
    /// because the backfill upsert deliberately bypasses that path.
    ///
    /// NOT optional. The watch journals a temp with its PROGRAMMED end (PodLoanWatchController
    /// `loanWillEnactTempBasal`: `endDate = now + duration`), so a 5-minutely dose cycle leaves
    /// half a dozen 30-minute temps overlapping — the watch's own log calls that untruncated sum
    /// "NOT a meaningful commanded total" (:2222). LoanReconciler leaves them that way on purpose
    /// (LoanReconciler.swift:182-188) because `DoseStore.addPumpEvents` runs stock
    /// `InsulinMath.reconciled()` before the delivery-store insert (DoseStore.swift:1174). An
    /// upsert that carried the untruncated spans would REPLACE the store's own truncated rows
    /// with them and inflate IOB on every hand-back, healthy ones included.
    ///
    /// `reconciled()` is internal to LoopKit, so this is its rate-record arm restated against the
    /// only two dose types that can appear here: a rate record ends where the next one starts, a
    /// fully superseded one is dropped, boluses pass through. The suspend/resume arms are
    /// unreachable — LoanReconciler mints suspends as rate-0 `.tempBasal` (:200-211) and never
    /// emits `.suspend`/`.resume` DoseEntries.
    private func truncatingOverlaps(_ doses: [DoseEntry]) -> [DoseEntry] {
        var out: [DoseEntry] = []
        var lastRate: DoseEntry?
        for dose in doses.sorted(by: { $0.startDate < $1.startDate }) {
            guard dose.type != .bolus else {
                out.append(dose)
                continue
            }
            if let last = lastRate {
                let end = Swift.min(last.endDate, dose.startDate)
                if end > last.startDate {
                    if let trimmed = last.trimmed(from: nil, to: end, syncIdentifier: last.syncIdentifier) {
                        out.append(trimmed)
                    }
                }
            }
            lastRate = dose
        }
        // Stock's tail guard verbatim (InsulinMath.swift:514): a zero-duration final record is
        // dropped there, so appending it here would upsert a stray row the clean path never wrote.
        if let last = lastRate, last.endDate > last.startDate { out.append(last) }
        return out
    }

    /// The other half of what the store's path does that the upsert bypasses:
    /// `reconciled()` ends with `resolvingDelivery` (InsulinMath.swift:345-365, fileprivate),
    /// which stamps `deliveredUnits` on every immutable dose — pulse-quantized for temps.
    /// Without this, an upserted row REPLACES a clean row that had `deliveredUnits` set with
    /// one that has nil, and downstream math falls back to un-quantized programmed figures —
    /// sub-pulse drift, but rows the backfill corrects must be indistinguishable from rows
    /// the clean path wrote.
    private static func resolvedDeliveredUnits(for dose: DoseEntry) -> Double? {
        guard !dose.isMutable else { return nil }
        switch dose.type {
        case .bolus:     return dose.programmedUnits
        case .tempBasal: return dose.unitsInDeliverableIncrements
        default:         return nil
        }
    }

    /// e44: the same reconciled doses, restated under the identity the STORE gave them.
    ///
    /// `NewPumpEvent.init` DISCARDS `dose.syncIdentifier` and derives the stored one as
    /// `raw.hexadecimalString` (NewPumpEvent.swift:33), so a dose upserted by syncIdentifier has
    /// to carry hex(utf8("loanv2-<uuid>")) or it inserts a SECOND row instead of correcting the
    /// one the pump-event path already wrote. Rebuilt rather than mutated: `syncIdentifier` is
    /// `internal(set)` outside LoopKit, and `value` is not readable at all — recovered through
    /// the unit-appropriate public accessor.
    private func storeIdentifiedDoses(from doses: [DoseEntry]) -> [DoseEntry] {
        doses.compactMap { dose in
            guard let syncID = dose.syncIdentifier else { return nil }
            return DoseEntry(type: dose.type,
                             startDate: dose.startDate,
                             endDate: dose.endDate,
                             value: dose.unit == .unitsPerHour ? dose.unitsPerHour : dose.programmedUnits,
                             unit: dose.unit,
                             decisionId: dose.decisionId,
                             deliveredUnits: dose.deliveredUnits ?? Self.resolvedDeliveredUnits(for: dose),
                             description: dose.description,
                             syncIdentifier: Data(syncID.utf8).hexadecimalString,
                             scheduledBasalRate: dose.scheduledBasalRate,
                             insulinType: dose.insulinType,
                             automatic: dose.automatic,
                             manuallyEntered: dose.manuallyEntered,
                             isMutable: dose.isMutable,
                             wasProgrammedByPumpUI: dose.wasProgrammedByPumpUI)
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
                // SETTLE WINDOW FIRST, then mirror, then notify (reordered 2026-08-22). The old
                // order announced .owner before the settle baseline existed, so any observer that
                // reacted to the announcement could catch the gap: a tile render saw
                // isSettlingOnly=false for a frame ("done" flashing before "Reclaiming…"), and
                // testSettleFractionCapsAndHoldsWhenTheSettleOverruns caught it as a race — its
                // fake clock advanced in the gap, so the baseline consumed the ADVANCED time and
                // every elapsed came up 9.5 s short (fraction 0.0 where 0.95 was owed). That is
                // the test that blocked a ship on 2026-08-21 while passing in isolation. The
                // window is display bookkeeping, so opening it before the pod is re-armed costs
                // nothing; observers must simply never see .owner without its baseline.
                if oldValue != .owner, state == .owner {
                    beginReclaimSettleWindow()
                }
                // Mirror before notifying — the notification causes the read.
                syncUIMirror()
                deps.ownershipDidChange()
            }
        }
    }

    /// The reclaim's phase, its real deadline, and — for the settle alone — a fraction to draw.
    /// nil when nothing is in flight.
    ///
    /// Two windows, one accessor, and only the settle draws. The tapped handover still publishes
    /// its phase and the ladder's own force deadline, because the tile's label comes from that phase
    /// ("Reaching Watch…" the moment a dead branch is decided, not after the wait — and
    /// "Can't Reach Watch" from the resend deadline, so the verdict lands before the force).
    /// What it no longer publishes is a fraction: at 736 ms tapped and sub-second on a
    /// hand-back, a bar over the handover is a flash, and a dead-watch handover is better
    /// served by the sweep plus a label that names the problem than by a bar racing a 20 s force.
    ///
    /// The settle arm is deliberately NOT gated on a ladder. A watch-initiated hand-back arms no
    /// ladder and still lands in the same settle, so gating on one is what left a regularly ended
    /// session with an indeterminate sweep for the whole of its wait. Every route into `.owner`
    /// opens the settle window, so every route — tapped, watch-initiated, forced — draws a
    /// settle bar. A settle that follows a FORCE runs one stage against its own promise; the
    /// others run the two-stage fast/slow split.
    ///
    /// nil during a watch-initiated hand-back's own store commit, which no tap promised anything
    /// about, and nil again the moment the settle's round-trip verifies.
    var reclaimProgress: ReclaimProgress? {
        return Self.reclaimProgress(from: queue.sync { uiSnapshot() }, now: deps.now())
    }

    // MARK: - Non-blocking UI reads

    /// THE PUMP TILE MUST NEVER TAKE THE LOAN QUEUE. It draws on the main thread, and this queue
    /// is the one doing BLE work, store commits and reconcile — so a `queue.sync` from a tile
    /// refresh puts the main thread behind whatever the reclaim is currently doing. Field-proven
    /// on 2026-08-16: a settle that stalled held the queue, the tile blocked main behind it, and
    /// the ENTIRE phone UI froze until the app was force-quit. The pod was fine throughout; only
    /// the interface was gone.
    ///
    /// So the tile reads a mirror under a plain lock, refreshed opportunistically from the queue.
    /// The mirror caches the reclaim's INPUTS (its anchors and phase), never a finished
    /// `ReclaimProgress` — the derivation is re-run against a fresh `now` on every read, so the
    /// elapsed counter keeps ticking truthfully even while the queue is wedged and the snapshot
    /// itself is stale. That is exactly the case where the seconds matter most: they are the only
    /// thing distinguishing still-working from stuck.
    struct UISnapshot: Equatable {
        var isLoanedOut = false
        var isTakeoverInProgress = false
        var isSettlingOnly = false
        var ladderIsRunning = false
        var ladderStartedAt: Date?
        var ladderPhase: ReclaimProgress.Phase = .draining
        var ladderForceAt: Date?
        var isOwner = true
        var reclaimStartedAt: Date?
        var reclaimVerified = true
        var auditIsForceReclaim = false
        var displayAnchor: Date?
    }

    private let uiMirrorLock = NSLock()
    private var uiMirror = UISnapshot()

    /// Captures the fields the tile derives from. MUST be called on `queue`.
    private func uiSnapshot() -> UISnapshot {
        var s = UISnapshot()
        s.isLoanedOut = state != .owner
        s.isTakeoverInProgress = state == .grantOffered
        s.isSettlingOnly = state == .owner && reclaimStartedAt != nil && reclaimVerifiedAt == nil
        if let ladder = reclaimLadder {
            s.ladderIsRunning = state == .reclaimPending || state == .reconciling
            s.ladderStartedAt = ladder.startedAt
            s.ladderPhase = ladder.phase
            s.ladderForceAt = ladder.forceAt
        }
        s.isOwner = state == .owner
        s.reclaimStartedAt = reclaimStartedAt
        s.reclaimVerified = reclaimVerifiedAt != nil
        s.auditIsForceReclaim = pendingHandbackAudit?.flavor == .forceReclaim
        s.displayAnchor = reclaimDisplayAnchor
        return s
    }

    /// Writes the mirror from data the caller already holds. MUST be called on `queue`.
    ///
    /// EVERY transition the tile draws must call this BEFORE it notifies. The async refresh below
    /// is not enough on its own: a re-render triggered by the state change would read the mirror
    /// before the async write lands, draw the PREVIOUS state, and then sit there — nothing
    /// re-renders a second time. Field-seen on 2026-08-16: the watch went live while the phone
    /// kept saying "Handing over…" until the user swiped, which forced an unrelated redraw.
    private func syncUIMirror() {
        let s = uiSnapshot()
        uiMirrorLock.lock()
        uiMirror = s
        uiMirrorLock.unlock()
    }

    /// Refreshes the mirror from the queue. Cheap and idempotent; safe to call from anywhere.
    func refreshUIMirror() {
        queue.async { [weak self] in
            guard let self else { return }
            let s = self.uiSnapshot()
            self.uiMirrorLock.lock()
            self.uiMirror = s
            self.uiMirrorLock.unlock()
        }
    }

    /// The tile's read. Never blocks: it returns the last mirror and asks for a fresh one.
    var uiState: UISnapshot {
        refreshUIMirror()
        uiMirrorLock.lock()
        defer { uiMirrorLock.unlock() }
        return uiMirror
    }

    /// The single derivation, shared by the blocking accessor and the tile's non-blocking one, so
    /// the two can never drift into describing the same reclaim differently.
    static func reclaimProgress(from s: UISnapshot, now: Date) -> ReclaimProgress? {
        // `.reconciling` is part of the tapped handover, not a gap in it: the drain's records
        // are being written, and the label the user is reading was chosen by this ladder's
        // branch. Guarding on `.reclaimPending` alone dropped the phase for the length of one
        // Core Data write, which relabels a dead-watch reclaim from its branch label to the
        // generic "Reclaiming…" mid-write and then back.
        if s.ladderIsRunning, let ladderStartedAt = s.ladderStartedAt {
            let elapsed = max(now.timeIntervalSince(ladderStartedAt), 0)
            // The live handover draws a determinate bar against the drain promise — the
            // sweep is retired (field ruling). Past the promise the phase concedes and the
            // bar holds at cap; the force at 25 s is what actually resolves it. The forcing
            // phase (dead branch, or a live force mid-deferral) keeps a nil fraction: its
            // own settle bar arrives within a second.
            var phase = s.ladderPhase
            var fraction: Double?
            if phase == .draining {
                fraction = min(elapsed / Self.liveHandoverExpectation, 0.95)
                if elapsed >= Self.liveHandoverExpectation { phase = .watchNotAnswering }
            }
            return ReclaimProgress(phase: phase, startedAt: ladderStartedAt,
                                   expectedBy: phase == .draining
                                       ? ladderStartedAt.addingTimeInterval(Self.liveHandoverExpectation)
                                       : (s.ladderForceAt ?? ladderStartedAt),
                                   fraction: fraction,
                                   elapsed: elapsed)
        }
        // The settle predicate is restated inline rather than read from `isReclaimSettling`:
        // that accessor takes the same serial queue this block is already running on, and a
        // nested sync onto a serial queue deadlocks. It is `isReclaimSettling` and not
        // `isReclaimSettlingOnly` that it must match, ceiling term included — the pill draws
        // this fraction BEFORE it checks whether a reclaim is in progress at all, so a bar
        // that outlived the "Reclaiming…" tile would paint itself under some other label.
        if s.isOwner, let started = s.reclaimStartedAt, !s.reclaimVerified,
           now.timeIntervalSince(started) < Self.reclaimSettleTimeout {
            let elapsed = max(now.timeIntervalSince(started), 0)
            // A settle that follows a FORCE reclaim is one operation to the user — the tile
            // just told them the watch could not be reached — so it runs ONE stage against
            // its own promise instead of the fast/slow re-baseline, which mid-force would
            // read as a second failure. The audit flavor is the marker: the force path arms
            // it before ownership flips, and it is consumed only after the verification this
            // bar is waiting on.
            if s.auditIsForceReclaim {
                // Same promise as the ordinary settle (one const, by the 2026-08-23 lean
                // ruling) — the label differs, the physics no longer do.
                return ReclaimProgress(
                    phase: .forceReclaimingPod, startedAt: started,
                    expectedBy: started.addingTimeInterval(Self.reclaimSettleExpectation),
                    fraction: min(elapsed / Self.reclaimSettleExpectation, 0.95),
                    elapsed: elapsed)
            }
            // One stage, anchored where the USER'S wait began — the tap for a phone
            // reclaim, the settle open for a watch-initiated one — so the bar is a single
            // continuous fill across the handover and the settle. Caps at 0.95 and HOLDS
            // there on an overrun: the settle's real bound is `reclaimSettleTimeout`, not
            // the expectation, so a bar that has run out of deadline must read as
            // nearly-done-and-still-working rather than as finished.
            let anchor = s.displayAnchor ?? started
            let waitElapsed = max(now.timeIntervalSince(anchor), 0)
            return ReclaimProgress(
                phase: .reconnectingToPod, startedAt: anchor,
                expectedBy: anchor.addingTimeInterval(Self.reclaimSettleExpectation),
                fraction: min(waitElapsed / Self.reclaimSettleExpectation, 0.95),
                elapsed: waitElapsed)
        }
        return nil
    }

    /// True during the post-handover BLE settle: the phone owns the pod but cannot yet command
    /// it. Distinct from `isPodLoanedOut` (which is false here, since state is already .owner),
    /// so a bolus tapped now would be aimed at a link that is not up.
    var isReclaimSettlingOnly: Bool {
        return queue.sync { state == .owner && reclaimStartedAt != nil && reclaimVerifiedAt == nil }
    }

    /// Non-blocking twins of the predicates above, for the tile. See `UISnapshot`.
    var isReclaimSettlingOnlyForUI: Bool { return uiState.isSettlingOnly }

    /// The TILE's gate: any reclaim activity at all — the drain/force ladder OR the settle.
    /// The old gate was settle-only, so a dead-watch force showed "Pod on Watch" for the whole
    /// 25 s ladder (field, 2026-08-23): the ladder runs with state still .loaned, isSettlingOnly
    /// false throughout, and the first honest frame arrived only at .owner — by which time the
    /// settle was 5 s and the render never caught it. The mirror already carries both flags and
    /// every state change syncs it before notifying, so this is purely the gate widening.
    var isReclaimActivityForUI: Bool {
        let s = uiState
        return s.isSettlingOnly || s.ladderIsRunning
    }
    var isPodLoanedOutForUI: Bool { return uiState.isLoanedOut }
    var isPodTakeoverInProgressForUI: Bool { return uiState.isTakeoverInProgress }
    var reclaimProgressForUI: ReclaimProgress? {
        return Self.reclaimProgress(from: uiState, now: Date())
    }

    // MARK: Reclaim settle window (post-hand-back "Reclaiming…" until the pod is truly back)

    /// Set when state enters .owner (a reclaim re-armed the BLE bid, but the pod isn't back
    /// yet). Drives `isReclaimSettling` so the tile persists until the pod is truly connected
    /// (deps.isConnectionReady) or the ceiling elapses. nil = not settling.
    private var reclaimStartedAt: Date?
    private var reclaimSettleWork: DispatchWorkItem?
    private static let reclaimSettleTimeout: TimeInterval = .minutes(5)
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
    private static let reclaimSettleExpectation: TimeInterval = 10


    /// Set when a pod ROUND-TRIP has completed since the reclaim began.
    /// This — not the peripheral's Bluetooth state — is what "the pod is back" means.
    /// Field measurement: after a hand-back the pod advertises immediately, the phone's
    /// standing bid connects within seconds, and isConnectionReady() flips true long before
    /// the phone has actually TALKED to the pod. Grants issued in that gap release a
    /// half-returned pod, and the watch's takeover then flaps against it (~90 s of #7/#11).
    /// Every recorded failure sat inside that window; every success outside it.
    private var reclaimVerifiedAt: Date?
    private var reclaimVerifyInFlight = false
    /// The two halves of a settle, so the single elapsed number stops hiding which one it was.
    /// `reclaimLinkUpAt` is when the peripheral first reached CoreBluetooth "connected";
    /// `reclaimStaleReads` counts status round-trips that came back without advancing lastSync
    /// after that. Measured across 91 settles, the wait is bimodal — 70 land in 1-11 s, 21 in
    /// 24-190 s, and NOTHING lands in the 12-23 s band — so something discrete decides the
    /// mode, and these two fields are what say whether it is the link or the read. Nil/zero
    /// outside a settle window.
    private var reclaimLinkUpAt: Date?

    /// Grace period before a stalled reclaim escalates from the manager's gentle reconnect to its
    /// scan-and-adopt. 20s because the takeover budget calls a connect "typically ~17s": inside
    /// that, a normal reconnect is still landing and escalating would only add radio contention;
    /// past it, waiting is not working. Field settles that stalled ran 224.2s and 237.0s.
    private static let reclaimEscalateAfter: TimeInterval = 20

    /// One escalation per reclaim. Re-armed with each new settle window.
    private var reclaimEscalated = false
    private var reclaimStaleReads = 0
    /// Where the USER'S wait began, for the bar alone — the tap for a phone-initiated reclaim,
    /// the settle open for a watch-initiated one. The bar must be ONE continuous fill across
    /// the handover and the settle (a bar that restarts at the phase boundary reads as a second
    /// failure — the same ruling as the forced path), but the settle's own metrics keep
    /// measuring from the settle open so the verified "+Ns (link, reads)" corpus stays
    /// comparable across builds. Display state only; never read by any timing decision.
    private var reclaimDisplayAnchor: Date?
    /// Last request identity handled, for transport-redelivery suppression.
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
    /// The window also CHASES completion instead of waiting for it. Left alone, the
    /// first post-reclaim pod round-trip is whenever the phone's 5-minute cycle next runs —
    /// or, on a locked phone, whenever iOS feels like it (one hand-back completed the moment
    /// an unrelated notification woke the phone). ensureCurrentPumpData is fired as soon as
    /// the link is up, so "returned" happens in seconds when the phone is awake instead of
    /// minutes by accident.
    private func beginReclaimSettleWindow() {
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
    private func attemptReclaimVerificationNow(started: Date, forced: Bool = true) {
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
                "reconcile[%@]: delivered=%.3f expected=%.3f residual=%+.3f (tol 0.05) · loanMin=%.0f cycles=%d · odometer read by PHONE +%.0fs after reclaim · vs watch endpoint %@ (watch fresh=%@)",
                pending.flavor == .forceReclaim ? "FORCE-RECLAIM" : "AUTHORITATIVE",
                delivered, pending.expected, residual,
                pending.loanMinutes, pending.cycles, elapsed,
                drift.map { String(format: "%+.3f", $0) } ?? "n/a",
                pending.watchFreshened ? "Y" : "N"))
            UserDefaults.standard.set(delivered, forKey: Keys.deliveredAuthoritative)
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
                bankResidual(residual, epoch: pending.epoch)
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

    // MARK: - What a reconciliation difference actually DOES

    /// A positive residual — the pod delivered MORE than our books say — beyond this opens the
    /// loop.
    /// **0.20 U, set FROM DATA**, replacing the deliberately
    /// loose +0.5 U that had to be chosen when every residual available had been measured against
    /// the watch's stale endpoint — i.e. against the wrong interval.
    ///
    /// The bank that justifies it: n=13 authoritative samples, mean −0.031, worst |0.200|,
    /// min −0.200, max +0.000. Note WHERE THE MASS SITS — every sample is at or below zero, so the
    /// open-loop direction has never once been observed. Tightening 2.5× therefore costs nothing
    /// in false trips against the measured distribution, while catching a real over-delivery six
    /// pulses sooner. Four pulses (0.20 U) is still well clear of quantization, which
    /// tops out around half a pulse per temp replacement.
    private static let openLoopPositiveResidual: Double = 0.20

    /// A negative residual — the pod delivered LESS than our books say — beyond this warns, and
    /// only warns (see the sign asymmetry on `applyReconciliationVerdict`). Also 0.20 U.
    ///
    /// Unlike the positive bound, this one DOES sit on the measured distribution: the worst banked
    /// sample is exactly −0.200, so a loan marginally worse than anything yet seen will now warn.
    /// That is the intended trade rather than an oversight — this direction never opens the loop,
    /// so the cost of a trip is a notice, not a therapy gap, and the under-delivery direction is
    /// precisely where we WANT early visibility while the residual's true distribution fills in.
    private static let warnNegativeResidual: Double = 0.20

    /// Sign-aware. The two directions are not the same failure and do not deserve the
    /// same response:
    ///
    /// POSITIVE (pod delivered more than recorded) — there is insulin in the body that the
    /// algorithm cannot see. Closed loop will dose on top of it. That is stacking, and the remedy
    /// is to stop the machine: go open, tell the user loudly, let them look and dose by hand.
    ///
    /// NEGATIVE (pod delivered less than recorded) — the books carry phantom IOB. The algorithm
    /// believes there is more insulin working than there is, so it doses LESS: the error is
    /// self-limiting, it decays out within DIA, and annulment already retires the
    /// identifiable cases. Opening the loop here would make the actual failure (under-treatment)
    /// worse, not better — the one direction where opening the loop is the wrong medicine. So: warn,
    /// keep looping.
    ///
    /// Warned once per event, never once per retry (alarm fatigue).
    private func applyReconciliationVerdict(residual: Double, epoch: Int) {
        if residual > Self.openLoopPositiveResidual {
            handbackDiag(epoch, String(format:
                "** R32 OPEN LOOP — residual %+.3f U exceeds +%.2f: the pod delivered insulin our records do not contain. Automatic dosing STOPPED. **",
                residual, Self.openLoopPositiveResidual))
            deps.openLoopForUncertainReconciliation()
            armOpenLoopReminder()
            // URGENT on either flavor: an alert that stops automatic dosing must never be a
            // quiet list entry. The one alert left on the plain channel is the negative warn
            // below, which keeps looping — caution, not action (alarm fatigue).
            deps.issueUrgentNotice("Loop Open — Unexplained Insulin",
                             String(format: "The pod delivered %.2f U more than the watch session's records account for. Automatic dosing is off until you turn it back on. Check your insulin on board before dosing.", residual))
        } else if residual < -Self.warnNegativeResidual {
            handbackDiag(epoch, String(format:
                "** R32 WARN — residual %+.3f U beyond -%.2f: records claim more delivery than the pod made (phantom IOB). Still looping — this direction under-doses and decays out. **",
                residual, Self.warnNegativeResidual))
            // "Overstated", not "High": the pod delivered LESS than the records claim, so the
            // defect is in the books, not in the body. "High" reads as a therapy state — is my
            // IOB high, is that bad? — and sends the user looking at the wrong thing.
            deps.issueNotice("Insulin On Board May Be Overstated",
                             String(format: "The watch session's records account for %.2f U more than the pod delivered. Automatic dosing continues; expect it to run cautious until this clears.", -residual))
        }
    }

    /// The force-reclaim verdict. Same bounds and sign asymmetry as the verdict above — a dead
    /// watch is the limiting case of incomplete books, not a different protocol — but the RESPONSE
    /// escalates, because the counterparty that would normally explain a residual is dead, and
    /// because dosing has been held since the reclaim waiting on exactly this answer.
    private func applyForceReclaimVerdict(residual: Double, epoch: Int) {
        deps.setAutomaticDosingPaused(false)   // the latch's job is done; dosingEnabled carries any verdict
        if residual > Self.openLoopPositiveResidual {
            handbackDiag(epoch, String(format:
                "** R37 OPEN LOOP — force-reclaim residual %+.3f U exceeds +%.2f: the pod delivered insulin the records cannot explain (watch died mid-session?). Automatic dosing STOPPED. **",
                residual, Self.openLoopPositiveResidual))
            deps.openLoopForUncertainReconciliation()
            armOpenLoopReminder()
            // Written to survive a BANNER, which is where this is actually read. The previous
            // wording ran past four lines and truncated mid-sentence on the field screenshot
            // (2026-08-14), cutting off at "its real records w" — so the reader lost the one
            // clause that says the situation resolves itself. Order is deliberate: the number
            // and the dosing state first, because those are what a truncated banner must still
            // carry, then the reassurance. The ~2 min figure is the measured lag from the watch
            // reconnecting to its records landing and the estimate retiring.
            var body = String(format:
                "%.2f U on the pod isn't in the watch's records, so automatic dosing is OFF.", residual)
            if Self.bookUnattributedInsulinOnForceReclaim {
                bookGapDose(units: residual, epoch: epoch)
                body += " It's booked as a bolus to keep IOB conservative; the watch's real records replace it about 2 min after the phone sees the watch again."
            } else {
                body += " Check your insulin on board before dosing."
            }
            deps.issueUrgentNotice("Loop Open — Unverified Insulin", body)
        } else if residual < -Self.warnNegativeResidual {
            // Same asymmetry as the verdict above: phantom IOB under-doses and decays out, so opening
            // the loop would worsen the actual failure. Warn — but urgently, since a dead-watch
            // session earns attention either way.
            handbackDiag(epoch, String(format:
                "** R37 WARN — force-reclaim residual %+.3f U beyond -%.2f: records claim more than the pod delivered (phantom IOB). Looping resumes — this direction under-doses and decays out. **",
                residual, Self.warnNegativeResidual))
            // PLAIN channel, matching the identical verdict on the clean-hand-back path (:857).
            // Same finding, same direction, same "looping continues" outcome — the urgent
            // channel here was an inconsistency, and this direction under-doses and decays out
            // on its own, which is the case for NOT breaking through a Focus mode.
            deps.issueNotice("Insulin On Board May Be Overstated",
                             String(format: "After the watch session ended abruptly, records account for %.2f U more than the pod delivered. Automatic dosing resumes; expect it to run cautious until this clears.", -residual))
        } else {
            handbackDiag(epoch, String(format:
                "R37 audit CLEAN — residual %+.3f U within ±%.2f; automatic dosing resumes", residual, Self.openLoopPositiveResidual))
        }
    }

    /// The placeholder for insulin the odometer proved but no record explains. Timestamped
    /// NOW (the reclaim) — zero decay, maximum IOB, the conservative direction — and manually
    /// entered with a deterministic syncIdentifier so the watch's return can retire it.
    private func bookGapDose(units: Double, epoch: Int) {
        let now = deps.now()
        let sync = Self.gapSyncIdentifier(epoch: epoch)
        let entry = DoseEntry(type: .bolus, startDate: now, endDate: now,
                              value: units, unit: .units, decisionId: nil, deliveredUnits: units,
                              syncIdentifier: sync, manuallyEntered: true)
        deps.bookGapDose(entry) { [weak self] ok in
            guard let self = self else { return }
            self.queue.async {
                if ok {
                    UserDefaults.standard.set(["epoch": epoch, "units": units,
                                               "bookedAt": now.timeIntervalSince1970],
                                              forKey: Keys.gapBooking)
                    // The booking is now the standing condition, so this is where the standing
                    // reminder belongs — not at the four "dosing is paused" sites the old one
                    // used, none of which imply a placeholder exists.
                    self.armPlaceholderReminders(units: units, bookedAt: now)
                    self.handbackDiag(epoch, String(format: "R37 gap BOOKED — %.2f U bolus @ reclaim (sync %@); retired if the watch returns", units, sync))
                } else {
                    self.handbackDiag(epoch, String(format: "** R37 gap booking FAILED to save — %.2f U is NOT in the books. Loop is open; dose by hand with that in mind. **", units))
                }
            }
        }
    }

    private static func gapSyncIdentifier(epoch: Int) -> String { "PODLOAN-ODOGAP-e\(epoch)" }

    /// Retry a gap delete that failed on a previous launch. `retireGapBookingIfExplained`
    /// only runs from inside an offer's write completion, and the hand-back ack that stops the
    /// watch's 15 s resend loop goes out BEFORE that retire attempt — so a delete that fails on
    /// its one shot can outlive the offer that would have retried it, with no other trigger left
    /// to fire. This is that other trigger: called once from `init`, it retries against whatever
    /// is persisted, independent of any offer or epoch match, because by the time this runs the
    /// watch may never send another one.
    private func retryPersistedGapDeleteIfAny() {
        guard let gap = UserDefaults.standard.dictionary(forKey: Keys.gapBooking),
              let gapEpoch = gap["epoch"] as? Int, let booked = gap["units"] as? Double else { return }
        // RULED 2026-08-15: the placeholder STAYS unless the watch's real records actually
        // arrived. Previously this guard asked only "is a booking persisted", which cannot tell
        // "the delete failed after real records committed" (retry it — the point of this
        // function) from "nothing ever explained this insulin" (the booking is still TRUE). The
        // key is written at booking and cleared only on a successful delete, so the second case
        // is the normal persisted state — and every launch was silently deleting a conservative
        // IOB booking that nothing had replaced, while the user had been told it was there to
        // keep IOB safe. Losing the watch for good is exactly when that margin matters most.
        //
        // The flag is set only in retireGapBookingIfExplained's failure branch, i.e. only after
        // real records committed. An un-flagged booking now stands until either the watch comes
        // back or the dose decays out of the DIA window on its own.
        guard gap["deleteFailedAfterRecords"] as? Bool == true else {
            handbackDiag(gapEpoch, String(format: "R37 gap placeholder STANDS — %.2f U still unexplained; the watch never returned, so the booking is left in place", booked))
            return
        }
        let sync = Self.gapSyncIdentifier(epoch: gapEpoch)
        handbackDiag(gapEpoch, String(format: "R37 gap DELETE retrying at launch — %.2f U placeholder (sync %@) was unretired last session", booked, sync))
        deps.deleteGapDose(sync) { [weak self] ok in
            guard let self = self else { return }
            self.queue.async {
                if ok {
                    UserDefaults.standard.removeObject(forKey: Keys.gapBooking)
                    // A2: a delete is an insulin-history rewrite like any other — the placeholder
                    // was booked AT the reclaim, which by the time this launch-retry runs is well
                    // behind the frontier. Without the prune the counteraction memo keeps the
                    // deleted units baked into its bins.
                    if let bookedAt = (gap["bookedAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)) {
                        self.deps.insulinHistoryRewritten(bookedAt)
                    }
                    self.cancelPlaceholderReminders()
                    self.handbackDiag(gapEpoch, String(format: "R37 gap RETIRED on launch retry — %.2f U placeholder cleared", booked))
                } else {
                    self.handbackDiag(gapEpoch, String(format: "** R37 gap DELETE FAILED AGAIN at launch — %.2f U placeholder still stands; will retry next launch or the next matching offer **", booked))
                }
            }
        }
    }

    /// The watch came back. Its offer just committed the REAL records behind the gap, so
    /// the placeholder retires — full replacement, not a partial offset: the store now carries
    /// the truth-bearing account (validated in aggregate by the odometer at reclaim), and any
    /// residue left is ordinary reconcile noise. Runs AFTER the real doses are written, so the
    /// transition never passes through a state with neither (a brief both is the safe
    /// direction; a gap of neither is not). Keyed on persisted state: duplicate redeliveries
    /// find nothing and no-op. A failed delete keeps the state (retried on the next offer and
    /// at launch) and says so, because a silent failure here is a double-counted IOB.
    private func retireGapBookingIfExplained(offerEpoch: Int, dosesJustCommitted: [DoseEntry], carbsJustCommitted: Int) {
        guard let gap = UserDefaults.standard.dictionary(forKey: Keys.gapBooking),
              let gapEpoch = gap["epoch"] as? Int, gapEpoch == offerEpoch,
              let booked = gap["units"] as? Double else { return }
        guard !dosesJustCommitted.isEmpty else { return }   // an empty offer explains nothing
        // The array, not a pre-summed total: `booked` is a bolus-shaped, odometer-derived number,
        // so only bolus units are comparable to it. LoanReconciler mints every dose without
        // deliveredUnits (:193-198, :205-210), which made the old single total ALWAYS gross
        // programmed — rate × FULL clamped window, un-netted against the schedule and untruncated
        // against the next temp. That is the "implied Σ" over-count this file already deleted once
        // (see the note above forceReclaimToOwner), printed here against a real delivered figure.
        // `deliveredUnits ??` survives on the BOLUS sum only: inert today, right the day a record
        // carries one. Rate records get their own column, labelled gross on its face.
        let boluses = dosesJustCommitted.filter { $0.type == .bolus }
        let bolusUnits = boluses.reduce(0.0) { $0 + ($1.deliveredUnits ?? $1.programmedUnits) }
        let rateCount = dosesJustCommitted.count - boluses.count
        let rateGross = dosesJustCommitted.filter { $0.type != .bolus }.reduce(0.0) { $0 + $1.programmedUnits }
        let sync = Self.gapSyncIdentifier(epoch: gapEpoch)
        deps.deleteGapDose(sync) { [weak self] ok in
            guard let self = self else { return }
            self.queue.async {
                if ok {
                    UserDefaults.standard.removeObject(forKey: Keys.gapBooking)
                    // A2: the placeholder is gone from the books, so the counteraction bins that
                    // were computed with it in the insulin curve are wrong from `bookedAt` on.
                    // Same prune as the doses that just replaced it — the pair is one rewrite.
                    if let bookedAt = (gap["bookedAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)) {
                        self.deps.insulinHistoryRewritten(bookedAt)
                    }
                    self.handbackDiag(gapEpoch, String(format:
                        "R37 gap RETIRED — the watch returned with %d real dose(s): %.2f U bolus + %d rate record(s) (%.2f U gross programmed, pre-truncation) and %d carb(s); the %.2f U estimate is replaced by actual timing",
                        dosesJustCommitted.count, bolusUnits, rateCount, rateGross, carbsJustCommitted, booked))
                    // STAYS (ruled 2026-08-15, restoring the 2026-08-14 field request). The
                    // keeps re-review called this a congratulation banner announcing that a
                    // self-healing correction healed, and recommended killing it. That misses
                    // what it is actually for: IOB and COB CHANGE UNDER THE USER'S FEET at this
                    // instant. A numbers-changed notice is not reassurance, and the urgent
                    // channel is right for it.
                    //
                    // The review's real finding stands though — it omits the half the user can
                    // act on, because the loop the audit opened is STILL OPEN and nothing in
                    // this codebase closes it. That sentence is going into the standing
                    // placeholder/open-loop reminder rather than here, so this can stay a short
                    // statement of what just changed.
                    self.cancelPlaceholderReminders()   // the condition is gone
                    self.deps.issueUrgentNotice("Watch Records Recovered",
                                          String(format: "The watch is back. Its records (%d doses, %d carbs) replaced the estimated %.2f U bolus — your IOB and COB now reflect actual timing.",
                                                 dosesJustCommitted.count, carbsJustCommitted, booked))
                } else {
                    // Mark the booking as "real records DID arrive, the delete is what failed".
                    // Only that state earns a launch retry — see retryPersistedGapDeleteIfAny.
                    var marked = gap
                    marked["deleteFailedAfterRecords"] = true
                    UserDefaults.standard.set(marked, forKey: Keys.gapBooking)
                    self.handbackDiag(gapEpoch, String(format:
                        "** R37 gap DELETE FAILED — the %.2f U placeholder AND the real records are both booked; IOB is over-counted until this retries **", booked))
                }
            }
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
        // The first review HAPPENED (2026-08-13, n=13 → ±0.20 U), so this line no longer asks for
        // it. Leaving the old text in place would have printed "the bounds were set with none" at
        // every hand-back forever — a log line stating something false, which is the exact
        // cry-wolf failure OBS-8 was about. The ratchet is kept, just re-armed further out.
        if history.count >= Self.residualReReviewTarget {
            line += String(format: " ** R32 THRESHOLD RE-REVIEW DUE — %d samples banked since the ±%.2f U bounds were set from 13 on 2026-08-13 **",
                           history.count, Self.openLoopPositiveResidual)
        } else {
            line += String(format: " (bounds ±%.2f U, set from 13 samples 2026-08-13; %d more for a re-review)",
                           Self.openLoopPositiveResidual, Self.residualReReviewTarget - history.count)
        }
        handbackDiag(epoch, line)
    }

    /// How many banked residuals before the bounds above are worth revisiting AGAIN. The first
    /// review fired at 10, was acted on at 13, and set ±0.20 U; this is the next checkpoint.
    /// It equals the ring capacity, so it trips exactly when the whole 40-sample window is fresh
    /// evidence gathered under the tightened bounds.
    private static let residualReReviewTarget = 40

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
            // Settling until a pod ROUND-TRIP has landed, not until the peripheral shows
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
    /// Latch so a repeatedly-failing hand-back write warns ONCE, not once per 15 s resend.
    /// Deliberately not persisted — a relaunch is a fresh chance to tell the user.
    /// Same once-per-state discipline, for the build-skew notice: cleared on the first clean decode.
    private var hasWarnedProtocolMismatch = false

    /// Everything the odometer audit needs EXCEPT the end reading, held
    /// from the final drain until the phone's own reclaim round-trip lands (seconds later) and can
    /// supply that reading first-hand. See `finishPendingHandbackAudit`.
    private struct PendingHandbackAudit {
        enum Flavor: String { case handback, forceReclaim }
        let epoch: Int
        let deliveredAtStart: Double
        let expected: Double
        let loanMinutes: Double
        let cycles: Int
        let watchLatest: Double?      // the watch's own end reading, for the fresh-vs-stale delta
        let watchFreshened: Bool
        var flavor: Flavor = .handback
    }
    private var pendingHandbackAudit: PendingHandbackAudit? {
        didSet {
            // Only the force flavor persists. A restart between the force-reclaim and the
            // verified round-trip must re-arm the audit rather than quietly resume dosing —
            // whether the loop closes again should depend on the pod's answer, not on whether
            // the app happened to relaunch first.
            if let p = pendingHandbackAudit, p.flavor == .forceReclaim {
                UserDefaults.standard.set(["epoch": p.epoch, "atStart": p.deliveredAtStart,
                                           "expected": p.expected, "loanMinutes": p.loanMinutes],
                                          forKey: Keys.pendingForceAudit)
            } else if oldValue?.flavor == .forceReclaim {
                UserDefaults.standard.removeObject(forKey: Keys.pendingForceAudit)
            }
        }
    }

    /// True from write START until its completion runs, both paths.
    /// While set, incoming offers COALESCE below instead of launching concurrent Core Data
    /// writes, and a force-reclaim defers. Events only enter `committedIDs` in the write's
    /// completion, so without this latch every duplicate copy of an offer arriving mid-write
    /// saw them as uncommitted and started its own write — one field session logged 12 receipts
    /// for 3 sends and ELEVEN concurrent writes (3-19 s each) for one 0.15 U dose.
    /// Self-amplifying: slow writes delay the ack, the watch resends, more writes.
    private var commitInFlight = false
    /// Offers that arrived during an in-flight write — latest per epoch, and a FINAL is
    /// never displaced by an interim. Replayed one-per-completion by `drainAfterCommit`, at
    /// which point `committedIDs` makes a duplicate a cheap re-ack. §2.9: never drop a message.
    private var coalescedOffers: [Int: HandbackOffer] = [:]
    /// A force-reclaim requested mid-write. It used to run immediately, read the
    /// not-yet-updated `committedIDs`, and re-commit the same staged records — insulin
    /// survives (raw dedup at the store) but CARBS HAVE NO IDENTITY and double.
    private var pendingForceReclaimReason: String?
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
    private var reclaimResendWork: DispatchWorkItem?

    // MARK: - Reclaim ladder (2026-08-13)

    /// The state of a tapped reclaim: which branch the evidence chose, when it started, and the
    /// two deadlines it is running to. One ladder at a time; nil means no reclaim is in flight.
    private struct ReclaimLadder {
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
    private var reclaimLadder: ReclaimLadder?

    /// A watch holding the pod transfers its log every 300 s. Measured across 134 gaps since
    /// 2026-08-08: 283.1 s to 301.4 s, zero excursions past 302 s. One pulse period plus margin
    /// therefore separates a live watch from a dead one with enormous headroom — the one live
    /// revoke on record had a 6.5-second-old pulse, the five dead ones 5.5 to 21.2 minutes.
    private static let watchContactLivenessWindow: TimeInterval = 330

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
    private static let liveHandoverExpectation: TimeInterval = 10

    // The dead branch has no delay constants: it forces immediately. See armReclaimLadder for
    // the reasoning — nothing that lands on that branch can answer, and the pulse discriminator
    // above is what keeps an alive watch off it.

    /// The scheduling seam for the ladder's rungs. nil (production) runs them on `queue` at their
    /// real deadlines; a test substitutes a virtual clock and fires a rung inline, which is what
    /// makes a 25-second geometry assertable without waiting 25 real seconds. The label crosses
    /// too, so a test can assert WHICH rung armed at which deadline rather than merely how many.
    var scheduler: ((_ delay: TimeInterval, _ label: String, _ work: DispatchWorkItem) -> Void)?

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
    }

    private enum NotificationID {
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
    private enum ReminderLadder {
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
        installPodLinkCensus()

        // One-shot: two force-reclaim residuals (+0.800, +0.850) were banked before
        // bankResidual was scoped to `.handback`, and they are what the next threshold review
        // would read as the worst clean hand-backs on record. No clean hand-back can exceed
        // +0.5 U — it is 2.5× the open-loop bound above, and the banked legit distribution tops
        // out at +0.000 — so that is the cut. Deliberately NOT the +0.20 bound: a legitimate
        // hand-back above it opens the loop loudly and its residual is still authentic calibration
        // data. Runs here rather than in bankResidual so the stats stop lying now, instead of
        // at whenever the next hand-back happens to be.
        if !UserDefaults.standard.bool(forKey: Keys.residualHistoryPurged) {
            if var history = UserDefaults.standard.array(forKey: Keys.residualHistory) as? [Double] {
                let before = history.count
                history.removeAll { $0 > 0.5 }
                if history.count != before {
                    UserDefaults.standard.set(history, forKey: Keys.residualHistory)
                }
            }
            UserDefaults.standard.set(true, forKey: Keys.residualHistoryPurged)
        }

        // A restart between a force-reclaim and its verified round-trip must not lose the
        // audit — the loop is being held open waiting on the pod's answer, and forgetting the
        // question would leave it that way (or worse, resume on unverified books). Re-arm from
        // the persisted inputs; the settle window re-runs the chase.
        if let saved = UserDefaults.standard.dictionary(forKey: Keys.pendingForceAudit),
           let e = saved["epoch"] as? Int, let atStart = saved["atStart"] as? Double,
           let expected = saved["expected"] as? Double, let loanMinutes = saved["loanMinutes"] as? Double {
            pendingHandbackAudit = PendingHandbackAudit(
                epoch: e, deliveredAtStart: atStart, expected: expected,
                loanMinutes: loanMinutes, cycles: 0,
                watchLatest: nil, watchFreshened: false, flavor: .forceReclaim)
            queue.async { [weak self] in
                guard let self = self else { return }
                self.handbackDiag(e, "R37 audit RE-ARMED after relaunch — verdict still owed")
                self.beginReclaimSettleWindow()
            }
        }

        // A gap placeholder whose delete failed has no other trigger once the watch's
        // resend loop has been acked off — see retryPersistedGapDeleteIfAny for why. Independent
        // of the audit re-arm above: this fires on every launch that finds ANY persisted
        // booking, whether or not a force-reclaim is currently in flight.
        queue.async { [weak self] in
            self?.retryPersistedGapDeleteIfAny()
            // Best-effort tidy-up: if the user closed the loop while the app was dead, retire
            // the pending reminder rather than let it fire about a decision already made.
            self?.cancelOpenLoopReminderIfLoopClosed()
        }

        // Relaunch during a non-owner state: dosing stays paused (persisted-state
        // derivation is the whole point). Re-post the recovery affordance so the user
        // is never stranded with no way back to OWNER (bug E), and re-arm the reclaim
        // escalation if we were mid-reclaim.
        if podIsOnLoan {
            deps.setAutomaticDosingPaused(true)
            // Transient states (reconciling / reclaim-pending / grant-offered) should
            // resolve quickly; a relaunch still sitting in one means it stranded, so
            // give it a bounded self-heal to OWNER (records preserved). LOANED is NOT
            // healed — a relaunch during a real multi-hour loan is normal; its
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
            warnProtocolMismatch()
            return
        }
        hasWarnedProtocolMismatch = false   // a clean decode means the skew is over
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
            // Logged, not posted. Two reasons, both found in the keeps re-review: the shared
            // notice says "Loop can't read a message from the watch", which is BACKWARDS here —
            // a nack means the WATCH could not read US. And a nack is itself a clean decode, so
            // it never reaches the latch that suppresses repeats: an ongoing skew would have
            // posted a fresh banner every 15 s, forever. The decode arm keeps the notice; this
            // direction is a developer fact, and the user's own signal is the loan not starting.
            os_log("Loan protocol skew — the WATCH could not decode a message from this phone", log: log, type: .fault)
        case .grant, .handbackAck, .revoke, .statusQuery, .denied, .diag:
            break  // watch-bound kinds (diag is phone→watch only)
        }
    }

    // MARK: - Grant (§2.2)

    private func handleRequest(_ request: LoanRequest) {
        // Suppress a TRANSPORT redelivery of the same request. This is not
        // the same as a user tapping Start twice — a second tap arrives seconds later against
        // settled state, whereas a redelivered copy arrives milliseconds later while the FIRST
        // is still in flight. Seen in the field: copy 1 granted the epoch and released
        // the pod; copy 2 landed in .grantOffered, took the stale-state recovery below,
        // force-reclaimed the pod it had just released (`released=false`) and re-granted —
        // which the reclaim-settle guard then denied. The watch was left holding a grant for a
        // pod still on the phone, so every ladder read returned `no-peripheral` and the loan
        // died. Genuine retries carry a fresh ID and are unaffected; a watch build that sends
        // no ID behaves exactly as before.
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

    /// Refuse the request and tell the WATCH why, so it shows the reason instead of hanging
    /// on "requesting…". No phone notice: the user is looking at the wrist they just tapped,
    /// and the reason is already on it — the phone copy was pure duplication.
    private func deny(_ reason: String) {
        os_log("Loan denied: %{public}@", log: log, type: .default, reason)
        sendMessage(.denied(LoanDenied(reason: reason)))
    }

    private func beginGrant() {
        // NO isWatchAppInstalled GATE HERE. One was added 2026-08-19 22:0x and REMOVED the same
        // hour: it refused three consecutive Start taps while the watch's request was arriving on the
        // URGENT path in the same second — i.e. it blocked a grant over a link that was demonstrably
        // live, because the flag it trusted had flipped false 9 seconds earlier and was simply wrong.
        // The flag flaps on a ~70-second timescale and lags reality; it is not a safe precondition.
        //
        // It also failed silently: the denial is sent to the WATCH, over the direction that is broken
        // in the very case the gate fires, so the phone showed nothing at all and the watch ground out
        // its full 25-second timeout. A guard that can neither be trusted nor explain itself is worse
        // than the failure it guards against, which is recoverable by force reclaim.
        //
        // If this is reinstated, key it on EVIDENCE, not cache: whether the request arrived on the
        // live (didReceiveMessage) path rather than the queued one, and deliver the refusal in the
        // REPLY to that request so it cannot be lost to the same broken direction.
        guard let pump = deps.pumpManager() else {
            deny("No pump is set up on the phone.")
            return
        }
        guard let lendable = pump as? PumpConnectionLendable else {
            deny("This pump can't be loaned to the watch (\(type(of: pump))).")
            return
        }

        // Don't hand a still-returning pod to the watch. After a reclaim the phone
        // enters .owner but the pod BLE isn't truly back for up to ~2 min — reclaimConnection()
        // only re-arms the bid. Granting inside that settle window releases a half-reconnected
        // pod, and the watch's takeover then races the phone's in-flight link → takeover fails
        // (the "rapid hand-back → re-takeover" bug). Deny-and-retry until the pod is genuinely
        // reachable (isConnectionReady) or the settle ceiling clears — conservative: it never
        // grants a not-ready pod, and the user's next Start succeeds once it's home.
        // Readiness = a completed pod ROUND-TRIP since the reclaim began,
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

        // Deny-on-missing: the grant is refused, never defaulted.
        let settings = deps.settings()

        // THE WATCH DOSES BY TEMP BASAL ONLY. If the phone is running automaticBolus, the wrist
        // refuses EVERY cycle — it holds the pod and never doses at all, surfacing a raw Swift
        // error on the watch face. Field-confirmed on the pure line's first live run with a real
        // T1D user: 5 cycles, 5 refusals, zero enacts, for someone whose therapy is a continuous
        // stream of small automatic boluses. It also explains a high eventual with no temping at
        // the same time — the loop never produced a recommendation, so there was nothing to enact.
        //
        // So the loan runs on temps, and the strategy is overridden HERE, in the snapshot the
        // grant carries — deliberately NOT by changing the phone's stored setting. Flipping the
        // real setting would need a restore at hand-back, and a restore that never runs (relaunch
        // mid-loan, force reclaim, dead watch, app killed) would leave the user silently on
        // tempBasalOnly forever: a lasting therapy change from a bookkeeping miss. Overriding the
        // snapshot has nothing to undo, so there is no restore that can fail. The phone is
        // automaticBolus again the instant it has the pod back, because it never stopped being.
        var loanSettings = settings
        let strategyOverridden = settings.automaticDosingStrategy != .tempBasalOnly
        loanSettings.automaticDosingStrategy = .tempBasalOnly
        if strategyOverridden {
            PhoneLog.event("loan", "dosing strategy overridden for the loan — phone \(settings.automaticDosingStrategy) → wrist tempBasalOnly; the phone's own setting is untouched")
        }
        guard settings.basalRateSchedule != nil,
              settings.insulinSensitivitySchedule != nil,
              settings.carbRatioSchedule != nil,
              settings.glucoseTargetRangeSchedule != nil,
              settings.maximumBasalRatePerHour != nil,
              settings.maximumBolus != nil else {
            deny("Therapy settings are incomplete; the watch can't dose without them.")
            return
        }

        // Fix 1 (field-confirmed boundaryDup=YES): DO NOT emit a boundaryRecord.
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
        // The LAST loan's takeover odometer must not leak into this one. If a force-reclaim
        // fires before this loan's takeoverComplete arrives, the audit's baseline fallback is the
        // fresh grant capture above — a stale takeover value would put the whole previous loan's
        // delivery inside the "unexplained" window and book a wildly wrong bolus.
        UserDefaults.standard.removeObject(forKey: Keys.deliveredAtTakeover)
        UserDefaults.standard.set(false, forKey: Keys.watchAuditRan)
        UserDefaults.standard.removeObject(forKey: Keys.expectedUnits)

        // Pause dosing, then stop bidding for the pod (C5 truncation happens inside).
        deps.setAutomaticDosingPaused(true)
        // If the phone doesn't actually drop the pod BLE here, the watch's
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
        // A new grant supersedes any deferred force-reclaim — running it later would
        // stomp this fresh loan straight back to .owner — and any coalesced old-epoch offers:
        // the watch resends whatever went unacked, and those take the stale-offer path.
        pendingForceReclaimReason = nil
        coalescedOffers.removeAll()
        staged = [:]
        stagedTombstones = []
        persistStaged()
        loanStartedAt = handedOverAt
        UserDefaults.standard.set(handedOverAt, forKey: Keys.loanStartedAt)

        let grantEpoch = epoch
        let historyStart = handedOverAt.addingTimeInterval(-.hours(16))
        // Fetch insulin AND carb history before building the grant. Nested so both
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
                    // INSTRUMENTATION ONLY: capture the phone's last-computed prediction
                    // decomposition (cached read, no recompute) as a fourth nested fetch, so it
                    // rides in the grant. Default nil closure ⇒ this is a no-op for tests / old builds.
                    self.deps.predictionSnapshot { [weak self] snapshot in
                    guard let self = self else { return }
                    self.queue.async {
                        guard self.state == .grantOffered, self.epoch == grantEpoch else { return }
                        guard let stateData = try? PropertyListSerialization.data(fromPropertyList: pump.rawValue, format: .binary, options: 0),
                              let settingsData = try? PropertyListSerialization.data(fromPropertyList: loanSettings.rawValue, format: .binary, options: 0) else {
                            self.abortGrant(reason: "snapshot encoding failed")
                            return
                        }
                        // The active override is NOT part of LoopSettings, so it cannot ride in
                        // therapySettingsRaw and is encoded alongside it — same plist encoding the
                        // hand-back's .overrideChange records use, so both directions agree. An
                        // already-finished override is dropped rather than sent (the same filter the
                        // phone applies before putting one in a WatchContext): seeding a dead
                        // override would show a stale preset on the glance for the whole loan.
                        // Encoding failure is NOT fatal here, unlike the settings blob above — a
                        // loan that dosed unscaled is wrong, but a loan refused outright mid-exercise
                        // is worse, and the log line below says which happened.
                        let activeOverride = self.deps.scheduleOverride().flatMap {
                            $0.hasFinished() ? nil : $0
                        }
                        let overrideData: Data? = activeOverride.flatMap { o in
                            try? PropertyListSerialization.data(fromPropertyList: o.rawValue, format: .binary, options: 0)
                        }
                        if let o = activeOverride {
                            if overrideData == nil {
                                os_log("[override] grant: FAILED to encode active override %{public}@ — the wrist will dose UNSCALED",
                                       log: self.log, type: .error, Self.overrideNameForLog(o))
                            } else {
                                os_log("[override] grant: carrying %{public}@ · insulin needs %.0f%% · sync %{public}@",
                                       log: self.log, type: .default, Self.overrideNameForLog(o),
                                       o.settings.effectiveInsulinNeedsScaleFactor * 100,
                                       o.syncIdentifier.uuidString)
                            }
                        }
                        // What LoopSettings.rawValue drops on this branch, carried alongside it.
                        // The schedules are the ONLY dosing limits the wrist has, and the insulin
                        // model decides its forecast — encoding failure here is therefore not a
                        // detail: the watch refuses the loan on missing schedules (loud), but a
                        // missing insulin model would silently downgrade it to rapid-acting-adult.
                        // So the model is logged when it is carried, and its absence is logged too.
                        var supplement: [String: Any] = [:]
                        supplement["basalRateSchedule"] = settings.basalRateSchedule?.rawValue
                        supplement["insulinSensitivitySchedule"] = settings.insulinSensitivitySchedule?.rawValue
                        supplement["carbRatioSchedule"] = settings.carbRatioSchedule?.rawValue
                        supplement["defaultRapidActingModel"] = settings.defaultRapidActingModel?.rawValue
                        let supplementData = supplement.isEmpty ? nil
                            : try? PropertyListSerialization.data(fromPropertyList: supplement, format: .binary, options: 0)
                        os_log("[grant] settings supplement: basal=%{public}@ isf=%{public}@ cr=%{public}@ model=%{public}@ bytes=%{public}d",
                               log: self.log, type: .default,
                               settings.basalRateSchedule == nil ? "MISSING" : "ok",
                               settings.insulinSensitivitySchedule == nil ? "MISSING" : "ok",
                               settings.carbRatioSchedule == nil ? "MISSING" : "ok",
                               settings.defaultRapidActingModel.map { String(describing: $0) } ?? "MISSING (wrist will assume rapid-acting adult)",
                               supplementData?.count ?? 0)
                        // To the FILE too, and with the seed counts beside it: the grant's size is
                        // dominated by the history it carries, so "how big is the supplement" is
                        // only meaningful next to "how big was it already".
                        self.handbackDiag(grantEpoch, "[grant] supplement \(supplementData?.count ?? 0)B · seeds: \(history.count) dose, \(carbs.count) carb, \(glucose.count) glucose · podState \(stateData.count)B · settings \(settingsData.count)B")
                        let grant = LoanGrant(
                            epoch: grantEpoch,
                            expiresAt: handedOverAt.addingTimeInterval(.minutes(5)),
                            pumpManagerRawState: stateData,
                            podAddress: 0,
                            therapySettingsRaw: settingsData,
                            settingsTimeZoneID: settings.basalRateSchedule?.timeZone.identifier ?? TimeZone.current.identifier,
                            doseHistory: history.compactMap(Self.loanRecord(from:)),
                            boundaryRecord: nil,   // Fix 1: running temp already lives in doseHistory (see above)
                            supportsInterimHandback: true,   // two-phase hand-back capability gate (REAL-3)
                            supportsOverrideRecords: true,   // this phone decodes .overrideChange
                            // Same source LoopDataManager:458 reads. Without this the watch runs
                            // Standard RC while this phone may be running Integral — different
                            // predictions from identical inputs, silently (audit 2026-07-22).
                            integralRetrospectiveCorrectionEnabled: UserDefaults.standard.integralRetrospectiveCorrectionEnabled,
                            // The wrist follows the phone's
                            // loop mode instead of resetting to OPEN each loan. Snapshotted at
                            // the grant like the therapy settings, so a later phone-side toggle
                            // does not reach through to a loan already in flight.
                            phoneClosedLoopEnabled: settings.dosingEnabled,
                            carbHistory: carbs,
                            glucoseHistory: glucose,
                            predictionSnapshot: snapshot,
                            activeOverrideRaw: overrideData,
                            therapySettingsSupplementRaw: supplementData)
                        self.sendMessage(.grant(grant))
                        self.armT1(for: grantEpoch)
                    }
                    }
                }
            }
        }
    }

    private func abortGrant(reason: String) {
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

    /// How much longer a watch that says it is ACTIVELY TAKING OVER buys itself, each time it
    /// says so. One T1 window, so a working takeover is never cut off mid-ladder.
    private static let takeoverProgressExtension: TimeInterval = .minutes(5)

    /// Ceiling on those extensions. A takeover that has not landed in fifteen minutes is not
    /// going to; past this the dead-man reclaims regardless of what the watch claims, because
    /// "still trying" forever is indistinguishable from a wedged watch holding the pod hostage.
    private static let takeoverProgressCeiling: TimeInterval = .minutes(15)

    /// When the current grant was offered — the anchor the ceiling is measured from.
    private var grantOfferedAt: Date?

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
            if !self.deps.watchAppInstalled() {
                self.handbackDiag(grantEpoch, "grant unconfirmed AND isWatchAppInstalled=false — one-way wedge; alerting the user (BT toggle)")
                self.deps.issueNotice("Watch Link Is Stuck",
                                      "This phone thinks the watch app isn't installed, so messages to the watch are being silently queued. Toggle Bluetooth off and on (Control Center), open Loop, and start the loan again.")
            }
            self.sendMessage(.statusQuery(StatusQuery(epoch: grantEpoch)))
        }
    }

    private func armT1(for grantEpoch: Int) {
        // STAMPED PER GRANT, unconditionally. The old `if grantOfferedAt == nil` guard meant a
        // FAILED takeover — which never clears this — leaked its anchor into the next grant, so
        // the elapsed this feeds kept growing across attempts: field 2026-08-17, e59 reported
        // "takeover IN PROGRESS at +145s" 21 s after its own grant, quoting e58's clock.
        //
        // That is not just a wrong number in a log line. `handleStatusReport` compares this
        // elapsed against `takeoverProgressCeiling`, and past the ceiling it stops extending the
        // dead-man and reclaims at once — so the longer a session ran, the sooner its takeovers
        // were abandoned.
        //
        // NOW A FALLBACK (2026-08-20). The grant path stamps this at the DECISION instead — armT1
        // runs at the end of a deep async chain, and a watch that answers before the chain lands used
        // to find it nil and report "+0s", which makes `elapsed < takeoverProgressCeiling` trivially
        // true and stops the ceiling ever firing. Overwriting here would push the anchor forward by
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

    private func handleTakeoverComplete(_ complete: TakeoverComplete) {
        guard complete.epoch == epoch, state == .grantOffered else { return }
        grantOfferedAt = nil
        t1WorkItem?.cancel()
        cancelNotification(id: NotificationID.t1)
        // Bank the watch's post-takeover odometer NOW, while the watch is alive to send it.
        // This is what lets the end-of-loan audit run even if the watch is dead by then — the
        // normal audit's baseline arrives in the hand-back offer, which a dead watch never sends.
        if let atTakeover = complete.firstPodStatus.deliveredUnits {
            UserDefaults.standard.set(atTakeover, forKey: Keys.deliveredAtTakeover)
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

    private func handleTakeoverFailed(_ failed: TakeoverFailed) {
        guard failed.epoch == epoch, state == .grantOffered else { return }
        t1WorkItem?.cancel()
        cancelNotification(id: NotificationID.t1)
        // Silent: the watch reported this failure, so the wrist the user is looking at already
        // shows the reason in its idle note — with better wording and the retry affordance the
        // phone banner lacked. iOS mirrors phone notices to that same wrist, so posting here put
        // the worse copy on top of the better one.
        reclaimToOwner(alert: nil, reason: "watch reported takeover FAILED: \(failed.reason)")
    }

    private func handleStatusReport(_ report: StatusReport) {
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
        // the pod yet. This is the third answer the protocol was built to distinguish — see
        // `knowsGrant` — and until now it fell through to the 5-minute dead-man and got the pod
        // reclaimed out from under it. Measured takeovers on this branch run 190-265s and one
        // exceeded the ceiling entirely, which produced a SPLIT BRAIN: the phone reclaimed while
        // the watch went on to take over successfully, so both believed they owned the pod. The
        // phone then denied every subsequent loan because its own reclaim could never verify —
        // the watch really did have the pod. Unrecoverable without ending the loan from the wrist.
        //
        // A watch that says it is still working buys another window, bounded by
        // takeoverProgressCeiling so a wedged watch cannot hold the pod hostage by claiming
        // progress forever.
        if state == .grantOffered, report.knowsGrant == true, !report.holdsPod {
            let elapsed = grantOfferedAt.map { deps.now().timeIntervalSince($0) } ?? 0
            if elapsed < Self.takeoverProgressCeiling {
                handbackDiag(report.epoch, String(format: "takeover IN PROGRESS on the watch at +%.0fs — extending the dead-man rather than reclaiming", elapsed))
                t1WorkItem?.cancel()
                cancelNotification(id: NotificationID.t1)
                let grantEpoch = report.epoch
                scheduleNotification(id: NotificationID.t1, title: "Watch Loan Not Confirmed",
                                     body: "The watch hasn't confirmed taking the pod. The phone will take it back.",
                                     delay: Self.takeoverProgressExtension, repeats: false)
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, self.state == .grantOffered, self.epoch == grantEpoch else { return }
                    self.sendMessage(.statusQuery(StatusQuery(epoch: grantEpoch)))
                    let confirm = DispatchWorkItem { [weak self] in
                        guard let self = self, self.state == .grantOffered, self.epoch == grantEpoch else { return }
                        self.reclaimToOwner(alert: nil, reason: "dead-man expired after the in-progress EXTENSION — takeover never completed")
                    }
                    self.t1WorkItem = confirm
                    self.queue.asyncAfter(deadline: .now() + 15, execute: confirm)
                }
                t1WorkItem = work
                queue.asyncAfter(deadline: .now() + Self.takeoverProgressExtension, execute: work)
            } else {
                handbackDiag(report.epoch, String(format: "takeover still unfinished at +%.0fs — past the %.0fs ceiling; reclaiming anyway", elapsed, Self.takeoverProgressCeiling))
            }
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

    // MARK: - Records (§2.4-2.6)

    private func handleBatch(_ batch: DoseRecordBatch) {
        // OBS-9 (2026-08-13): this guard DISCARDS dose records, and used to do it in total
        // silence — no log on either side. That made a whole class of question unanswerable
        // from the logs: after a force-reclaim the phone is .owner, so every batch a returning
        // watch flushes from its queued backlog lands here and vanishes. The records are not
        // lost in the end (the watch's 15 s offer resend carries the same events, and the offer
        // path still commits in .owner), but "were these doses dropped here, or did they never
        // arrive?" had no answer. It has one now.
        guard batch.epoch == epoch, state == .loaned || state == .reclaimPending else {
            handbackDiag(batch.epoch, "batch DROPPED — \(batch.events.count) event(s) ev=\(batch.epoch) vs phone ev=\(epoch), state=\(state.rawValue) (recovered via the offer path if the watch still resends)")
            return
        }
        stage(events: batch.events, tombstones: batch.tombstones)
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
        // phantom remainders. Interim
        // offers carry freshened=false anyway; this makes the skip explicit.
        let auditThisOffer = !isStale && isFinal && state == .reconciling

        stage(events: offer.events, tombstones: offer.tombstones)
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
                pendingHandbackAudit = PendingHandbackAudit(
                    epoch: offer.epoch, deliveredAtStart: start, expected: expected,
                    loanMinutes: loanMin, cycles: allStagedEvents.count,
                    watchLatest: offer.odometer?.deliveredLatest,
                    watchFreshened: offer.odometer?.freshenSucceeded == true)
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
    private func drainAfterCommit() {
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

    private static func overrideNameForLog(_ override: TemporaryScheduleOverride) -> String {
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

    // MARK: - Escape hatch (§3.1 RECLAIM_PENDING)

    func reclaimNow() {
        queue.async {
            guard self.podIsOnLoan else { return }
            self.reclaimDisplayAnchor = self.deps.now()   // the user's wait starts at the tap
            // Hold background execution from the tap: without it, tap-and-pocket freezes the
            // ladder and orphans the pod until the user next looks at the phone.
            self.deps.beginReclaimBackgroundTask()
            self.pendingRevoke = true
            self.sendMessage(.revoke(Revoke(epoch: self.epoch)))
            (self.deps.pumpManager() as? PumpConnectionLendable)?.reclaimConnection()
            self.state = .reclaimPending
            self.armPausedReminder()
            // §5.3.3 dead-watch path: audit against the schedule, notice-only.
            self.schedulePostReclaimReAudit(recordsCommitted: false)
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
                self.sendMessage(.revoke(Revoke(epoch: self.epoch)))
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
            self.forceReclaimToOwner(reason: "reclaim ladder spent on the \(ladder.branch.rawValue) branch — \(ladder.attempts) revoke attempt(s), watch did not drain")
        }
        reclaimTimeoutWork = force
        scheduleLadderRung(after: max(forceDelay, 0), label: "reclaim-force", execute: force)
    }

    /// Kill every pending rung and forget the ladder. Called wherever a reclaim stops being in
    /// flight — a completed drain, a force that landed, a fresh tap, an abandoned loan — so no
    /// rung can resend a revoke into a loan that is already over, and so the determinate bar
    /// stops the moment the handover does.
    private func cancelReclaimLadder() {
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

        (deps.pumpManager() as? PumpConnectionLendable)?.reclaimConnection()
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
        let baseline = (UserDefaults.standard.object(forKey: Keys.deliveredAtTakeover) as? Double)
                    ?? (UserDefaults.standard.object(forKey: Keys.deliveredAtGrant) as? Double)
        guard let deliveredAtStart = baseline, let schedule = deps.settings().basalRateSchedule else {
            handbackDiag(epoch, "** R37 force-reclaim audit IMPOSSIBLE — no start odometer/schedule; loop OPENS on principle (cannot verify => do not resume) **")
            deps.openLoopForUncertainReconciliation()
            armOpenLoopReminder()
            deps.issueUrgentNotice("Watch Session Unverified", Self.sessionUnverifiedBody)
            return false
        }
        let start = loanStartedAt ?? deps.now().addingTimeInterval(-.hours(2))
        let allEvents = staged.values.sorted { $0.seq < $1.seq }
        let expected = LoanReconciler.expectedInsulin(events: allEvents, schedule: schedule,
                                                      from: start, to: deps.now())
        pendingHandbackAudit = PendingHandbackAudit(
            epoch: epoch, deliveredAtStart: deliveredAtStart, expected: expected,
            loanMinutes: deps.now().timeIntervalSince(start) / 60, cycles: 0,
            watchLatest: nil, watchFreshened: false, flavor: .forceReclaim)
        handbackDiag(epoch, String(format:
            "R37 audit armed — expected %.3f U from %d record(s) + schedule fill; verdict on the reclaim round-trip",
            expected, allEvents.count))
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

    // MARK: - Helpers

    /// `alert: nil` reclaims silently — for the paths where the user has nothing to do and
    /// the phone's own pod pill already says who holds it.
    ///
    /// SILENT TO THE USER IS NOT SILENT TO THE LOG. Every route in here abandons a loan, and
    /// until 2026-08-17 none of them wrote a line: a failed takeover left a ~90 s hole between
    /// "extending the dead-man" and the settle, with nothing saying what moved the phone back to
    /// .owner. `reason` is required rather than defaulted so a new call site cannot reopen it.
    private func reclaimToOwner(alert: (title: String, body: String)?, reason: String) {
        handbackDiag(epoch, "loan ABANDONED — back to phone control: \(reason)")
        // Abandoning the loan retires any ladder with it; a rung firing afterwards would be
        // reasoning about a reclaim that no longer exists. The background hold ends here too:
        // this path never opens a settle window, so neither end-site below it would fire.
        cancelReclaimLadder()
        deps.endReclaimBackgroundTask()
        // The takeover this anchored is over, however it ended. Leaving it set is what let a
        // failed attempt's clock follow the NEXT grant around.
        grantOfferedAt = nil
        (deps.pumpManager() as? PumpConnectionLendable)?.reclaimConnection()
        state = .owner
        deps.setAutomaticDosingPaused(false)
        if let alert = alert { deps.issueNotice(alert.title, alert.body) }
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
        // Carry the phone's stable syncIdentifier (so the watch's re-seeds upsert-dedup instead
        // of accumulating) and insulinType (so the watch decays on the same model). Both flow through
        // seedDoseEntry → the seeded DoseEntry.
        switch dose.type {
        case .bolus:
            return LoanDoseRecord(kind: .bolus, startDate: dose.startDate, endDate: dose.endDate, amount: dose.deliveredUnits ?? dose.programmedUnits,
                                  syncIdentifier: dose.syncIdentifier, insulinType: dose.insulinType)
        case .tempBasal:
            // Send the pod's ACTUAL floored delivery (the bolus arm above already does) —
            // without it the watch re-derives with round() and over-states IOB by ~0.025 U per
            // elapsed temp slice (measured: phone 0.70 vs watch 1.00 over 33 slices).
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

    // MARK: - Notifications (the COMPLETE alarm inventory)

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

    /// Both directions of a protocol skew — the watch sent something this build cannot decode,
    /// or the watch nacked something this build sent — mean the same thing to the user, so they
    /// share one notice. The cause is named with "may", because the decode failure is all that
    /// was observed: a mismatched build is the designed reason (the envelope hard-guards
    /// protocolVersion and throws rather than guessing) and by far the likeliest one, but a
    /// corrupt payload produces the identical symptom. The check is worth naming because
    /// installing the two halves is genuinely fiddly and a half-updated pair is the common
    /// self-inflicted case.
    ///
    /// Latched once per skew and released on the first clean decode, for the reason the
    /// records-not-saved warning is latched: offers resend every 15 s, and `issueNotice` mints
    /// a fresh UUID per post, so an unlatched warning would stack a new banner every resend
    /// rather than replacing the last one.
    private func warnProtocolMismatch() {
        os_log("Loan protocol skew — payload undecodable in this build", log: log, type: .error)
        guard !hasWarnedProtocolMismatch else { return }
        hasWarnedProtocolMismatch = true
        deps.issueNotice(
            NSLocalizedString("Watch Message Unreadable", comment: "Phone notice title when a loan message cannot be decoded"),
            NSLocalizedString("Loop can't read a message from the watch. The apps may be on different builds — check both are current.", comment: "Phone notice body when a loan message cannot be decoded"))
    }

    /// Shared by the three paths that end an unverifiable session: the pod never answered, it
    /// answered without an insulin total, or there was no start-of-loan baseline to compare
    /// against. Those are three internal reasons for one user-facing fact, and previously each
    /// shipped its own wording — so the same situation read as three different problems. The
    /// second sentence is the house phrasing already used elsewhere in this file for a latched
    /// loop, which is what makes it accurate here: nothing reopens it automatically.
    static let sessionUnverifiedBody = NSLocalizedString(
        "Loop couldn't verify the watch's insulin delivery. Automatic dosing is off until you turn it back on.",
        comment: "Phone notice when a watch session's insulin could not be verified after reclaim")

    /// RETIRED (ruled 2026-08-15). It repeated hourly, forever, to say that automatic dosing was
    /// paused — a state the user can see, and often one they chose. Worse, it was armed from four
    /// sites where the thing actually worth standing over (a booked placeholder) did not exist.
    /// Its two cancel sites survive as no-ops so an upgrade retires anything already scheduled.
    private func armPausedReminder() {}

    // MARK: - Standing reminders (ruled 2026-08-15)
    //
    // Two conditions can outlive the notice that announced them, and both stop mattering after
    // the insulin action duration:
    //
    //   1. A PLACEHOLDER bolus stands in your IOB for insulin the pod proved it delivered and
    //      no record explains. You may be able to correct it from memory — but only while the
    //      dose is still within the manual-entry date picker's ±6 h reach, which is the same 6 h
    //      after which it has decayed out anyway. Two rungs, then silence.
    //   2. An AUDIT OPENED THE LOOP and nothing in this codebase closes it. One reminder only:
    //      the first tells someone who missed the original notice; a second would be nagging
    //      about a decision they have now made.

    /// Arm the placeholder ladder. Cancelled wherever the booking retires.
    private func armPlaceholderReminders(units: Double, bookedAt: Date) {
        let amount = String(format: "%.2f", units)
        let time = Self.reminderTimeFormatter.string(from: bookedAt)
        for (index, delay) in ReminderLadder.placeholderRungs.enumerated() {
            scheduleNotification(
                id: NotificationID.placeholder(index),
                title: NSLocalizedString("Estimated Insulin Still Booked", comment: "Phone reminder title while an unexplained gap bolus stands"),
                body: String(format: NSLocalizedString("%1$@ U is booked as a bolus at %2$@ — the pod's total, not real timing. If you remember the session, correct it in Insulin Delivery.", comment: "Phone reminder body while an unexplained gap bolus stands (1: units, 2: time booked)"), amount, time),
                delay: delay, repeats: false)
        }
    }

    private func cancelPlaceholderReminders() {
        for index in ReminderLadder.placeholderRungs.indices {
            cancelNotification(id: NotificationID.placeholder(index))
        }
    }

    /// Arm the single open-loop reminder. Best-effort cancelled: the phone cannot observe the
    /// user flipping Closed Loop back on from outside its own work, so this is also cleared at
    /// launch and at the next grant if dosing is already enabled by then. Worst case is one
    /// stale reminder, which is why this is a single rung and not a ladder.
    private func armOpenLoopReminder() {
        scheduleNotification(
            id: NotificationID.openLoop,
            title: NSLocalizedString("Closed Loop Is Off", comment: "Phone reminder title after an audit opened the loop"),
            body: NSLocalizedString("Loop couldn't verify the watch session's insulin, so it stopped dosing. Turn Closed Loop back on when you're ready.", comment: "Phone reminder body after an audit opened the loop"),
            delay: ReminderLadder.openLoopDelay, repeats: false)
    }

    /// Clear the open-loop reminder if the user has already closed the loop themselves.
    private func cancelOpenLoopReminderIfLoopClosed() {
        guard deps.settings().dosingEnabled else { return }
        cancelNotification(id: NotificationID.openLoop)
    }

    private static let reminderTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

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
