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
        /// The phone's last completed loop cycle, for the grant (ring ruling 2026-08-23).
        var lastLoopCompleted: () -> Date? = { nil }
        /// Seed the phone's loop-recency display from the wrist's final cycle at reclaim
        /// commit — the return-direction twin. Display only; never read by dosing.
        var noteWatchLoopCompleted: (Date) -> Void = { _ in }
        /// 16 h insulin history for the grant.
        var doseHistory: (_ start: Date, _ completion: @escaping ([DoseEntry]) -> Void) -> Void
        /// Active carb entries for the grant — seeded so the watch predicts with COB.
        var carbHistory: (_ start: Date, _ completion: @escaping ([LoanCarbRecord]) -> Void) -> Void = { _, done in done([]) }
        /// ~3 h of recent glucose for the grant — seeded so the watch's momentum + retrospective
        /// correction warm from the first post-takeover cycle instead of a cold empty store.
        var glucoseHistory: (_ start: Date, _ completion: @escaping ([LoanGlucoseRecord]) -> Void) -> Void = { _, done in done([]) }
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
        /// Cancel the phone's running temp basal before the pod is released at grant — stock's
        /// automation-off behaviour, awaited (LoopDataManager.cancelTempBasalForPodLoan). Default
        /// no-op keeps the state-machine tests on their fake pump.
        var cancelTempBasalForGrant: (@escaping (Error?) -> Void) -> Void = { $0(nil) }
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
        /// Runs `work` once protected data (file access) is available — immediately when it
        /// already is. A reboot mid-loan relaunches Loop in the BACKGROUND before first
        /// unlock, where the data-protection layer still has every store file locked; the
        /// controller's launch-time store work must wait for the unlock instead of trapping
        /// against sealed files (field crash 2026-08-27, TF 141, +2 s into a locked launch).
        /// Injected so the controller stays UIKit-free; DEFAULTS TO IMMEDIATE so tests and
        /// existing wiring are unaffected.
        var whenProtectedDataAvailable: (@escaping () -> Void) -> Void = { $0() }
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
        /// Is this phone's Bluetooth definitely OFF (stock's `BluetoothProvider`, `.poweredOff`)?
        /// A phone in that state cannot reclaim a pod, so it must not accept one. Transient
        /// states (unknown, resetting) are NOT "off". Default false keeps tests unchanged.
        var isBluetoothPoweredOff: () -> Bool = { false }
        /// When the phone last heard ANYTHING from the watch — any inbound WatchConnectivity
        /// funnel. This, not reachability, is what separates a live watch from a dead one at
        /// reclaim time: a watch holding the pod transfers its log every 300 s, metronomically
        /// (n=134 gaps since 2026-08-08, range 283.1-301.4 s, zero excursions past 302 s), while
        /// the five dead revokes on record had silences of 5.5 to 21.2 MINUTES. nil = nothing
        /// heard, which the reclaim ladder treats as dead. Default nil keeps the state-machine
        /// tests constructing unchanged.
        var lastWatchContactAt: () -> Date? = { nil }
        /// When this phone last read the sensor ITSELF. The sensor is on the body, like the pod:
        /// a phone with a fresh reading is near both, a phone without one can reach neither.
        var latestGlucoseDate: () -> Date? = { nil }
        var now: () -> Date = { Date() }
    }

    /// Code-level configuration: when a force-reclaim's odometer audit finds insulin the
    /// records cannot explain, book that gap as a bolus timestamped AT RECLAIM — zero decay, so
    /// IOB over-counts rather than under-counts until the truth arrives. `false` still opens the
    /// loop and alerts; it only skips the booking.
    static let bookUnattributedInsulinOnForceReclaim = true

    let log = OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanPhoneController")
    let queue = DispatchQueue(label: "com.loopkit.Loop.PodLoanPhoneController", qos: .utility)
    var deps: Dependencies

    // MARK: - Incoming

    func handleIncoming(userInfo: [String: Any]) {
        queue.async { self.handleIncomingOnQueue(userInfo) }
    }

    func handleIncomingOnQueue(_ userInfo: [String: Any]) {
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
        case .grant, .handbackAck, .revoke, .statusQuery, .denied, .diag, .dormantGrant:
            break  // watch-bound kinds (diag is phone→watch only)
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
    func reclaimToOwner(alert: (title: String, body: String)?, reason: String) {
        handbackDiag(epoch, "loan ABANDONED — back to phone control: \(reason)")
        // Abandoning the loan retires any ladder with it; a rung firing afterwards would be
        // reasoning about a reclaim that no longer exists. The background hold ends here too:
        // this path never opens a settle window, so neither end-site below it would fire.
        cancelReclaimLadder()
        deps.endReclaimBackgroundTask()
        // The takeover this anchored is over, however it ended. Leaving it set is what let a
        // failed attempt's clock follow the NEXT grant around.
        grantOfferedAt = nil
        clearAuditAnchors()
        reclaimPodConnection()
        state = .owner
        deps.setAutomaticDosingPaused(false)
        if let alert = alert { deps.issueNotice(alert.title, alert.body) }
    }

    func stage(events: [LoanEvent], tombstones: [UUID]) {
        for event in events { staged[event.id] = event }
        stagedTombstones.formUnion(tombstones)
        persistStaged()
    }

    func sendMessage(_ message: LoanMessage) {
        guard let dictionary = try? message.transportDictionary() else { return }
        deps.send(dictionary)
    }

    static func loanRecord(from dose: DoseEntry) -> LoanDoseRecord? {
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



    // MARK: - Init

    init(dependencies: Dependencies) {
        self.deps = dependencies
        self.state = State(rawValue: UserDefaults.standard.string(forKey: Keys.state) ?? "") ?? .owner
        self.epoch = UserDefaults.standard.object(forKey: Keys.epoch) as? Int ?? 0
        // PHONE MIRROR: restored BEFORE the podIsOnLoan re-pause below, so a relaunch
        // mid-yield re-enters the posture (flag folds into podIsOnLoan) automatically.
        self.yieldingToInferredLoan = UserDefaults.standard.bool(forKey: Keys.yieldingToInferredLoan)
        self.committedCursor = UserDefaults.standard.object(forKey: Keys.cursor) as? Int ?? 0
        self.pendingRevoke = UserDefaults.standard.bool(forKey: Keys.pendingRevoke)
        self.loanStartedAt = UserDefaults.standard.object(forKey: Keys.loanStartedAt) as? Date
        if let raw = UserDefaults.standard.array(forKey: Keys.committedIDs) as? [String] {
            self.committedIDs = Set(raw.compactMap(UUID.init(uuidString:)))
        } else {
            self.committedIDs = []
        }
        loadStaged()
        // Epoch-guarded: a base persisted by some other loan must never anchor this one —
        // a wrong anchor turns the whole previous loan's delivery into "unexplained".
        if let d = UserDefaults.standard.dictionary(forKey: Keys.auditBase),
           let units = d["units"] as? Double, let asOf = d["asOf"] as? Date,
           (d["epoch"] as? Int) == self.epoch {
            self.auditBase = AuditBase(units: units, asOf: asOf)
            self.checkpointsThisLoan = d["count"] as? Int ?? 0
        }
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
        // Store work waits for first unlock — see Dependencies.whenProtectedDataAvailable.
        deps.whenProtectedDataAvailable { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                self.retryPersistedGapDeleteIfAny()
                // Best-effort tidy-up: if the user closed the loop while the app was dead, retire
                // the pending reminder rather than let it fire about a decision already made.
                self.cancelOpenLoopReminderIfLoopClosed()
            }
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

    // MARK: - State owned by the extensions (stored properties cannot live in an extension)

    // MARK: - State for PodLoanPhoneController+UIReads.swift

    let uiMirrorLock = NSLock()
    var uiMirror = UISnapshot()

    // MARK: - State for PodLoanPhoneController+Reclaim.swift

    /// Set when state enters .owner (a reclaim re-armed the BLE bid, but the pod isn't back
    /// yet). Drives `isReclaimSettling` so the tile persists until the pod is truly connected
    /// (deps.isConnectionReady) or the ceiling elapses. nil = not settling.
    var reclaimStartedAt: Date?
    var reclaimSettleWork: DispatchWorkItem?

    /// Set when a pod ROUND-TRIP has completed since the reclaim began.
    /// This — not the peripheral's Bluetooth state — is what "the pod is back" means.
    /// Field measurement: after a hand-back the pod advertises immediately, the phone's
    /// standing bid connects within seconds, and isConnectionReady() flips true long before
    /// the phone has actually TALKED to the pod. Grants issued in that gap release a
    /// half-returned pod, and the watch's takeover then flaps against it (~90 s of #7/#11).
    /// Every recorded failure sat inside that window; every success outside it.
    var reclaimVerifiedAt: Date?
    var reclaimVerifyInFlight = false

    /// The two halves of a settle, so the single elapsed number stops hiding which one it was.
    /// `reclaimLinkUpAt` is when the peripheral first reached CoreBluetooth "connected";
    /// `reclaimStaleReads` counts status round-trips that came back without advancing lastSync
    /// after that. Measured across 91 settles, the wait is bimodal — 70 land in 1-11 s, 21 in
    /// 24-190 s, and NOTHING lands in the 12-23 s band — so something discrete decides the
    /// mode, and these two fields are what say whether it is the link or the read. Nil/zero
    /// outside a settle window.
    var reclaimLinkUpAt: Date?

    /// One escalation per reclaim. Re-armed with each new settle window.
    var reclaimEscalated = false
    var reclaimStaleReads = 0

    /// Where the USER'S wait began, for the bar alone — the tap for a phone-initiated reclaim,
    /// the settle open for a watch-initiated one. The bar must be ONE continuous fill across
    /// the handover and the settle (a bar that restarts at the phase boundary reads as a second
    /// failure — the same ruling as the forced path), but the settle's own metrics keep
    /// measuring from the settle open so the verified "+Ns (link, reads)" corpus stays
    /// comparable across builds. Display state only; never read by any timing decision.
    var reclaimDisplayAnchor: Date?

    /// Last request identity handled, for transport-redelivery suppression.
    /// sendMessage can report a timeout WITHOUT meaning undelivered, so the queued fallback
    /// sends a second copy that also lands. See handleRequest for what that cost in the field.
    var lastRequestID: String?
    var lastRequestAt: Date?

    // MARK: - State for PodLoanPhoneController+Reconciliation.swift

    /// Committed event IDs for the CURRENT epoch (secondary idempotency; the cursor
    /// is primary). Bounded: cleared when a loan fully closes.
    /// Latch so a repeatedly-failing hand-back write warns ONCE, not once per 15 s resend.
    /// Deliberately not persisted — a relaunch is a fresh chance to tell the user.
    /// Same once-per-state discipline, for the build-skew notice: cleared on the first clean decode.
    var hasWarnedProtocolMismatch = false

    /// Accepted checkpoints this loan — diagnostic color for the end-of-loan reconcile lines.
    /// Persisted inside the auditBase dict: e226 (2026-08-26, field) relaunched mid-loan and
    /// the R37 line then said "since takeover (0 checkpoint(s))" while correctly auditing
    /// from the LOADED base — a label that misdescribes the verdict's own anchor.
    var checkpointsThisLoan = 0

    /// The largest |window residual| any accepted checkpoint saw this loan — combined with
    /// the final window's at hand-back, it becomes the banked worst-window sample (the
    /// distribution a future band review reads; R32 closed 2026-08-27).
    var worstWindowThisLoan: Double = 0

    /// True from write START until its completion runs, both paths.
    /// While set, incoming offers COALESCE below instead of launching concurrent Core Data
    /// writes, and a force-reclaim defers. Events only enter `committedIDs` in the write's
    /// completion, so without this latch every duplicate copy of an offer arriving mid-write
    /// saw them as uncommitted and started its own write — one field session logged 12 receipts
    /// for 3 sends and ELEVEN concurrent writes (3-19 s each) for one 0.15 U dose.
    /// Self-amplifying: slow writes delay the ack, the watch resends, more writes.
    var commitInFlight = false

    /// Offers that arrived during an in-flight write — latest per epoch, and a FINAL is
    /// never displaced by an interim. Replayed one-per-completion by `drainAfterCommit`, at
    /// which point `committedIDs` makes a duplicate a cheap re-ack. §2.9: never drop a message.
    var coalescedOffers: [Int: HandbackOffer] = [:]

    /// A force-reclaim requested mid-write. It used to run immediately, read the
    /// not-yet-updated `committedIDs`, and re-commit the same staged records — insulin
    /// survives (raw dedup at the store) but CARBS HAVE NO IDENTITY and double.
    /// A grant is between its awaited temp cancel and its release; a second request waits.
    var grantInFlight = false
    var pendingForceReclaimReason: String?
    var committedIDs: Set<UUID>

    /// Staged (received, not-yet-committed) events for the current epoch — persisted
    /// on every batch so a phone relaunch keeps the trap-cell defense.
    var staged: [UUID: LoanEvent] = [:]
    var stagedTombstones: Set<UUID> = []
    var loanStartedAt: Date?
    var t1WorkItem: DispatchWorkItem?
    var reclaimTimeoutWork: DispatchWorkItem?
    var reclaimResendWork: DispatchWorkItem?

    var reclaimLadder: ReclaimLadder?

    /// The scheduling seam for the ladder's rungs. nil (production) runs them on `queue` at their
    /// real deadlines; a test substitutes a virtual clock and fires a rung inline, which is what
    /// makes a 25-second geometry assertable without waiting 25 real seconds. The label crosses
    /// too, so a test can assert WHICH rung armed at which deadline rather than merely how many.
    var scheduler: ((_ delay: TimeInterval, _ label: String, _ work: DispatchWorkItem) -> Void)?

    // MARK: - State for PodLoanPhoneController+Grant.swift

    var lastDormantRefreshAt: Date?
    /// A refresh the book asked for inside the floor; one runs when the floor expires.
    var trailingDormantRefreshPending = false
    /// Throttle for the revoke that answers records from a closed session (two batches per cycle).
    var lastClosedSessionRevokeAt: Date?
    var lastDormantSettingsFingerprint: String?

    // MARK: - State for PodLoanPhoneController+Mirror.swift

    /// The newest loan traffic seen for an epoch AHEAD of ours, in ANY state — batches
    /// dropped mid-drain, holdsPod status reports. Fix for the 2026-08-31 ghost-drain
    /// theft: e269's batches arrived while the e268 ghost was closing (.reconciling, so
    /// detector B's .owner guard couldn't act), and the close then reclaimed the pod out
    /// from under the live loan. Remembered here so the close can check before resuming
    /// custody. In-memory on purpose: only FRESH evidence (10 min) may block a reclaim.
    var newestForeignLoanEvidence: (epoch: Int, at: Date)?

    /// When the current grant was offered — the anchor the ceiling is measured from.
    var grantOfferedAt: Date?

    // MARK: - State with observers (moved out of the extension files)

    /// Presentation-level posture flag on .owner (never a state transition). Persisted:
    /// the blackout this answers can include phone reboots.
    var yieldingToInferredLoan: Bool {
        didSet { UserDefaults.standard.set(yieldingToInferredLoan, forKey: Keys.yieldingToInferredLoan) }
    }

    var state: State {
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

    var epoch: Int {
        didSet { UserDefaults.standard.set(epoch, forKey: Keys.epoch) }
    }

    var committedCursor: Int {
        didSet { UserDefaults.standard.set(committedCursor, forKey: Keys.cursor) }
    }

    var auditBase: AuditBase? {
        didSet {
            if let b = auditBase {
                UserDefaults.standard.set(["units": b.units, "asOf": b.asOf, "epoch": epoch,
                                           "count": checkpointsThisLoan],
                                          forKey: Keys.auditBase)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.auditBase)
            }
        }
    }

    var pendingHandbackAudit: PendingHandbackAudit? {
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

    var pendingRevoke: Bool {
        didSet { UserDefaults.standard.set(pendingRevoke, forKey: Keys.pendingRevoke) }
    }
}
