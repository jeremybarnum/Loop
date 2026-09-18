//
//  PodLoanWatchController.swift
//  WatchApp Extension
//
//  The watch half of loan protocol v2 (docs/DESIGN_LOAN_PROTOCOL_V2.md §3.2, §10).
//  State machine, grant intake -> stock OmniPumpManager construction, the pump-host
//  delegate duties (the pump manager's report writes the book AND the journal — one
//  identity per dose, the pod-native raw), hand-back with resend-until-ack, revoke, and
//  the relaunch drain (data-first: a dead session is never resurrected). Uncertainty is
//  the pump manager's own: an unacknowledged command is resolved on its next session.
//
//  Transport is injected (`send`) so the controller is testable without WCSession;
//  the app-lifecycle integration wires WCSession.transferUserInfo/didReceiveUserInfo
//  to `send`/`handleIncoming`.
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import OmnipodKit
import WatchKit
import os.log

extension Notification.Name {
    /// The loan phase moved. The wrist surface listens and re-renders; posting instead of
    /// calling a controller keeps this file free of any particular UI's lifetime, which the
    /// SwiftUI watch app no longer models the same way.
    static let podLoanPhaseDidChange = Notification.Name("com.loopkit.Loop.podLoanPhaseDidChange")

    /// A manual bolus changed state (requested -> pod ACKed -> done). Repaints the glance at the
    /// transition instead of waiting for its tick, which is blocked behind the dose. See
    /// `setManualBolusDelivering`.
    static let manualBolusStateDidChange = Notification.Name("com.loopkit.Loop.manualBolusStateDidChange")

    /// A carb entry or bolus flow finished successfully. Posted regardless of who holds the pod;
    /// the host decides whether it means anything, so the flow does not have to know about pages.
    static let carbAndBolusFlowDidComplete = Notification.Name("com.loopkit.Loop.carbAndBolusFlowDidComplete")
}

/// Why a hand-back is stuck, when the shape says the transport is at fault rather than the
/// phone. The two wedges need opposite advice, which is the only reason to tell them apart.
enum HandbackWedge: Equatable {
    /// Nothing here looks like a wedge: too few offers, or the phone was legitimately away.
    case none
    /// Sends reported success and nothing came back. Only restarting the WATCH app recovers it.
    case oneWay
    /// The sends themselves errored: the session is tearing down and re-establishing, and the
    /// queued fallback delivers when it returns. Self-heals, so advise waiting.
    case sessionReestablishing

    /// A wedge means several offers went out, the phone was reachable for EVERY one, and not a
    /// single ack came back. An unreachable phone explains a hang innocently and heals itself;
    /// sustained reachability with total silence does not.
    ///
    /// `sawUnreachable` is sticky across the whole hand-back rather than sampled at timeout: a
    /// phone that dropped out even once explains the hang, even though it is usually reachable
    /// again by the time we give up.
    static func classify(resendCount: Int,
                         sawUnreachable: Bool,
                         reachableNow: Bool,
                         sendsErrored: Bool) -> HandbackWedge {
        guard resendCount >= 3, !sawUnreachable, reachableNow else { return .none }
        return sendsErrored ? .sessionReestablishing : .oneWay
    }
}

final class PodLoanWatchController {

    enum Phase: String {
        case idle, requested, takingOver, active, handingBack, revoked
        /// Relaunch found undrained records: drain-only mode, no pod session ever.
        case recoveredDrain
    }

    let log = OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanWatchController")
    let queue = DispatchQueue(label: "com.loopkit.Loop.PodLoanWatchController", qos: .utility)
    let loopManager: WatchLoopManager
    let journal: LoanEventJournal

    /// The clock seam. Every `Date()` in this file
    /// now reads `self.now()`, mirroring stock's own idiom (`LoopDataManager.now()`,
    /// `CarbStore.test_currentDate`). Production behavior is unchanged — the default IS
    /// `Date()` — but the file's timing behavior (takeover ladder budgets, hand-back resend
    /// cadence, stuck-alert deadlines, suspend windows) becomes assertable without waiting
    /// out real seconds, which is what made it untestable before.
    var now: () -> Date = Date.init

    /// The scheduling seam, completing the clock seam above. Every delayed execution in this
    /// file crosses it, so a test can substitute a virtual clock and drive the ladders,
    /// resends and deferred releases deterministically. nil (production) preserves the exact
    /// prior behavior — same queue, same deadline arithmetic — and the DispatchWorkItem
    /// crosses the seam intact, so cancellation works identically in both worlds.
    /// The label crosses too: it is what lets a test assert WHICH timers a transition arms,
    /// not merely how many. "a request arms exactly [request-timeout]" is a claim about
    /// behavior; "a request arms exactly one timer" is a claim about arithmetic.
    var scheduler: ((_ delay: TimeInterval, _ label: String, _ work: DispatchWorkItem) -> Void)?

    /// Every timer logs armed / fired / skipped, with its lateness and the epoch it was armed
    /// under. Lateness is the suspension signature — a deferred release firing minutes late is
    /// what poisons the BLE stack — and an armed-epoch that differs from the firing epoch is
    /// the cross-loan-residue signature. Both were previously inferable only from clustered
    /// timestamps; now each firing carries its own evidence.
    func schedule(after delay: TimeInterval, label: String, execute work: DispatchWorkItem) {
        let armedEpoch = epoch
        let armedAt = now()
        SportLog.event("timer", "armed \(label) +\(fmtDelay(delay)) e=\(armedEpoch.map(String.init) ?? "-")")
        let wrapper = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if work.isCancelled {
                SportLog.event("timer", "skipped \(label) — cancelled before its deadline")
                return
            }
            let late = self.now().timeIntervalSince(armedAt) - delay
            let lateNote = late > 1.0 ? String(format: " late %.1fs", late) : ""
            let epochNote = armedEpoch != self.epoch
                ? " ** armed e=\(armedEpoch.map(String.init) ?? "-") firing e=\(self.epoch.map(String.init) ?? "-") — cross-epoch **"
                : ""
            SportLog.event("timer", "fired \(label) +\(self.fmtDelay(delay))\(lateNote)\(epochNote)")
            work.perform()
        }
        if let scheduler = scheduler {
            scheduler(delay, label, wrapper)
        } else {
            queue.asyncAfter(deadline: .now() + delay, execute: wrapper)
        }
    }

    func schedule(after delay: TimeInterval, label: String, execute body: @escaping () -> Void) {
        schedule(after: delay, label: label, execute: DispatchWorkItem(block: body))
    }

    private func fmtDelay(_ d: TimeInterval) -> String {
        d < 1 ? String(format: "%.2fs", d) : String(format: "%.0fs", d)
    }

    /// Companion seam: `UserDefaults.standard` reads/writes go through this, so a test
    /// can hand in a scratch suite instead of mutating the host app's real defaults.
    var defaults: UserDefaults = .standard

    /// Is the counterpart app reachable right now
    /// (WCSession.isReachable at integration)? Injected so the controller stays testable.
    /// Default true = behave exactly as before wherever it is not wired.
    var isPhoneReachable: () -> Bool = { true }
    /// Last reachability logged during a hand-back, so the log records TRANSITIONS rather
    /// than repeating the same line every 15 s resend.
    var lastHandbackReachable: Bool?
    /// Did this hand-back EVER see the phone unreachable? Distinguishes the ordinary
    /// "phone was away" hang — which resolves itself the moment it returns — from the transport
    /// wedge, where every offer went out with reachable=true and none was ever acked. Only the
    /// second one is fixed by restarting the watch app, so only the second one should say so.
    var handbackSawUnreachable = false
    /// Did any urgent send ERROR during this hand-back? Separates the two wedge variants at the
    /// timeout: erroring sends mean the session is re-establishing and will likely self-heal
    /// (variant B); silent sends with no acks mean the one-way wedge whose only known recovery
    /// is restarting the watch app (variant A). The advice for one is wrong for the other.
    var handbackSawUrgentSendError = false

    /// Called by the transport when an urgent send's errorHandler fires (StockLoopSession).
    func noteUrgentSendFailed() {
        queue.async { self.handbackSawUrgentSendError = true }
        urgentSendWedged = true
    }

    /// Set the first time an urgent send times out, cleared when a hand-back starts.
    ///
    /// WCSession's `isReachable` can be TRUE while `sendMessage` times out anyway — the
    /// `.oneWay` wedge this code already names as "#113 variant A". Each attempt then costs the
    /// full 15 s before falling back to the queued path, and the resend loop re-chose `urgent`
    /// every time: field 2026-08-20 23:27-23:28, four attempts, a minute of "ending..." with the
    /// queued path available from the first failure onward. One timeout is enough evidence;
    /// there is no reason to re-learn it every 15 s. Deliberately NOT queue-isolated — it is a
    /// benign one-way bool read from the WCSession callback thread, like `appIsForeground`.
    var urgentSendWedged = false

    /// Injected transport: dictionary -> WCSession.transferUserInfo (integration step).
    var send: (([String: Any]) -> Void)?

    /// Fires on loan lifecycle edges: true when the loan becomes ACTIVE (the session
    /// GHOST-REQUEST DEFUSER (field 2026-08-31): a loan request still queued for a dark
    /// phone after the watch stops wanting it is a delayed detonator — the watch moves on
    /// (possibly all the way to a seize), then delivers whenever the phone returns — and if
    /// that reunion lands inside the phone's 90 s freshness window, the phone GRANTS it, over
    /// a loan the watch is actively running. Field 2026-08-31 21:21: the seize-prelude request
    /// (~67 s old at delivery) did exactly that — ghost grant e276 against live e277, phone
    /// wedged on "Handing over…" until a manual force. The queue is the same one the offer
    /// superseder already prunes (#120); this is the request-kind twin.
    var cancelQueuedLoanRequests: (() -> Int)?

    /// The single funnel for "this request is dead to us": every path that stops awaiting a
    /// grant calls this, so a queued copy can never outlive the watch's interest.
    func cancelStaleQueuedRequests(context: String) {
        guard let cancelled = cancelQueuedLoanRequests?(), cancelled > 0 else { return }
        SportLog.event("loan", "cancelled \(cancelled) queued loan request(s) — \(context); a delivered ghost would re-grant over whatever this watch does next")
    }

    /// owner starts the G7 transport — closedDirect needs glucose), false when the
    /// pod is released/revoked/failed (transport stops, loop input pauses).
    var onLoanActiveChanged: ((Bool) -> Void)?

    /// Reverse arbiter: the pod TAKEOVER outranks the G7 — during the bounded
    /// ~40s ladder the G7 client stands down, because G7 scans/handshakes starve pod
    /// BLE session establishment on the single watch radio. Wired by the session;
    /// fired with true on entering .takingOver and false on leaving it (any exit).
    var onTakeoverRadioHold: ((Bool) -> Void)?

    /// True while a hand-back is in flight and the watch still holds the pod.
    ///
    /// The RELEASE is gated on the phone's ack, and that ack only takes WCSession's immediate
    /// channel while `session.isReachable`; otherwise it falls back to transferUserInfo, which
    /// iOS drains on its own schedule. The user's habit makes that the common case — tap End,
    /// drop the wrist, look at the phone — so the watch stops being reachable at exactly the
    /// moment permission to let go is being sent. The symptom: the carb
    /// and insulin records are already visible on the phone while "Reclaiming…" persists another
    /// 20-50s. The records being visible proves the commit landed; the wait is the ack.
    ///
    /// Takeover already solved this class with a keepalive holder for its ~40s ladder; the
    /// return path never got one. This is that hook. It changes NO safety property — the
    /// release stays gated on the ack — it just stops the ack from being starved.
    var onHandbackRuntimeHold: ((Bool) -> Void)?
    var phase: Phase {
        didSet {
            defaults.set(phase.rawValue, forKey: Keys.phase)
            loanActiveMirrorLock.lock()
            _loanActiveMirror = (phase == .active)
            loanActiveMirrorLock.unlock()
            if (oldValue == .takingOver) != (phase == .takingOver) {
                onTakeoverRadioHold?(phase == .takingOver)
                setTakeoverSessionListener(phase == .takingOver)
            }
            // Hold runtime for the whole hand-back, i.e. while the watch is waiting to be told
            // it may release. .handingBack is the phase in which the pod is still held and the
            // ack is outstanding.
            if (oldValue == .handingBack) != (phase == .handingBack) {
                onHandbackRuntimeHold?(phase == .handingBack)
            }
            // Repaint the glance on EVERY phase change, because every one of them changes what
            // the wrist should be reading and none of them is guaranteed a tick: the 2 s timer
            // runs only while the page is on screen, a screen dim kills it, and a bare undim
            // does not revive it.
            //
            // Poking only at the loan-end callback was not enough. It painted the drain frame
            // ("returning records…") and then nothing repainted when the drain finished and this
            // went .idle, so the wrist held an intermediate frame until a tap (field, 2026-08-14).
            // Transitions are rare — steady-state looping sits in .active and never re-enters
            // here — so this is a handful of renders per session, not a tick.
            //
            // Guarded on a REAL change: Swift fires didSet on same-value assignment too, and
            // several paths reassign .idle defensively.
            if oldValue != phase {
                NotificationCenter.default.post(name: .podLoanPhaseDidChange, object: nil)
            }
        }
    }
    var epoch: Int? {
        didSet { defaults.set(epoch, forKey: Keys.epoch) }
    }

    /// Repaint for NON-phase state the glance renders — the seize offer, the reunion
    /// prompt, idle notes. The phase.didSet repaint above covers transitions, but these
    /// mutate WITHIN a phase (the prompt is raised on .active; a re-entry offer lands on
    /// a same-value resting reassignment, which the real-change guard skips) — field
    /// 2026-08-31: both needed a tap to appear, which corrupted a day of test readings.
    func notifyUI() {
        NotificationCenter.default.post(name: .podLoanPhaseDidChange, object: nil)
    }

    var pumpManager: OmniPumpManager?

    /// Odometer at takeover, for the hand-back snapshot pair (§1.4).
    var deliveredAtTakeover: Double?
    /// When the current Start attempt began (request sent) — drives the glance
    /// progress bar. Meaningful only while phase is requested/takingOver.
    var attemptStartedAt: Date?
    /// Wall-clock of the previous takeover-ladder read, and the largest gap seen between two
    /// consecutive reads this attempt. A read is event-driven when the pod stack's session-
    /// established callback fires (fast — no fixed period) and backstop-driven otherwise, on an
    /// 8 s timer. So an ordinary backstop-only run reads
    /// ~8 s apart; a gap far past THAT means the APP STOPPED EXECUTING mid-connect — not that the
    /// pod went quiet. Distinguishing those two is the whole point: they send the user to
    /// opposite places. (See `driver` on `attemptTakeoverRead` for the per-read tag.)
    var lastTakeoverReadAt: Date?
    /// The pending takeover retry, held so the session-established event can fire it early.
    /// The ACTION is a plain closure and the BACKSTOP is the cancellable timer — they must not
    /// be the same object. Storing one DispatchWorkItem for both and doing cancel() then
    /// perform() stops the ladder dead the instant the event fires: a cancelled work item
    /// releases its block and performs nothing, so no retry and no timeout ever run.
    var takeoverRetryAction: (() -> Void)?
    var takeoverBackstop: DispatchWorkItem?
    var takeoverMaxReadGap: TimeInterval = 0
    /// Hand-back offer resend counter (reset when a drain begins) — makes an
    /// unreachable-phone wait self-documenting in the log.
    var handbackResendCount = 0
    /// A hand-back has been REQUESTED but the watch is still
    /// in control — phase stays .active, dosing and boluses continue, the journal
    /// drains via interim offers (released=false), and the user can cancel. Only when
    /// the drain is fully acked does finalizeHandback() stop dosing and send the
    /// final (released=true) offer. In-memory only: any relaunch ends the loan.
    var handbackRequested = false
    /// Capability gate: interim offers only when the granting phone
    /// understands them; false/nil grant → legacy single-phase hand-back.
    var phoneSupportsInterimHandback = false
    /// Only mint .overrideChange when the granting phone can decode it.
    var phoneSupportsOverrideRecords = false
    /// finalizeHandback flips phase BEFORE its ~3-15s of pod work
    /// (temp-cancel + status reads); a duplicate interim ack arriving in that window
    /// must NOT close the loan (the final offer hasn't been sent — the phone would
    /// strand in .loaned forever). The close path requires this flag in .handingBack.
    var finalOfferSent = false
    var resendWorkItem: DispatchWorkItem?
    /// When the LIVE hand-back gives up waiting for the phone's ack and resumes on the
    /// watch. Set at the End tap (beginHandback), cleared on ack/cancel/timeout. Nil for a
    /// recovered/revoke drain (no local loan to resume — those keep resending).
    /// How many unacked drain offers before the watch stops waiting. 20 x 15 s = ~5 minutes,
    /// comfortably past any normal ack latency and far short of the 97-minute silent limbo the
    /// resend loop could otherwise produce.
    static let maxDrainResends = 20

    var handbackDeadline: Date?
    /// When the CURRENT hand-back began — the anchor for the reclaim progress bar.
    /// Set and cleared in lockstep with `handbackDeadline`, which already marks exactly the
    /// hand-back's lifetime, so there is no second lifecycle to keep in step.
    var handbackStartedAt: Date?
    /// When the FINAL (released=true) offer was sent — the clock the ack is racing.
    /// Splits "Reclaiming…" into the two intervals we could not previously tell apart:
    /// waiting for the phone's permission, versus iOS actually freeing the pod's BLE slot.
    var finalOfferSentAt: Date?
    var requestTimeoutWork: DispatchWorkItem?
    /// Surfaced on the glance idle screen after a failed/timed-out start, so the user
    /// sees WHY instead of a silent return to idle.
    var lastIdleNote: String?
    /// A start (requested/takingOver) was in flight when the
    /// app was killed or replaced. init() can't send — `send` is wired afterward — so
    /// it stashes the epoch here and drainRecoveredIfNeeded() (post-wiring) fails the
    /// takeover to the phone, which would otherwise strand in .grantOffered.
    var pendingInterruptedTakeoverEpoch: Int?
    /// The cached handle THIS takeover trusted, so a takeover that never connected on it can
    /// forget it (the next Start then pays for discovery once). Replaces the framework's 6 s
    /// known-handle fallback scan.
    var takeoverCachedHandle: (address: UInt32, handle: String)?

    enum Keys {
        static let phase = "PodLoanWatchController.phase"
        static let epoch = "PodLoanWatchController.epoch"
        /// The pump manager's raw state, written on every state update and at the grant — the
        /// phone's own `PumpManagerState` persistence, on the wrist. Present only while a loan
        /// holds the pod: `teardownPump` clears it, so a relaunch that finds it knows the loan
        /// was ACTIVE when the process died and resumes it (R40(e)).
        static let pumpState = "PodLoanWatchController.pumpState"
        /// Fix 4a (field 2026-08-31): the highest epoch ANY accepted loan has used —
        /// never cleared, survives CLOSED (which wipes `epoch` and the journal, the
        /// amnesia that let back-to-back seizes reuse a spent epoch: 270→270 five times
        /// on tape, then bricked by the split-brain guard at revoked 271).
        static let highWaterEpoch = "PodLoanWatchController.highWaterEpoch"
    }

    /// `defaults` is an init parameter, not just a settable property, because the relaunch
    /// restore below reads it before `self` is fully initialized — which is exactly the path
    /// a test most wants to drive (phase/epoch recovery after a crash or force-quit).
    init(loopManager: WatchLoopManager, journal: LoanEventJournal = LoanEventJournal(),
         defaults: UserDefaults = .standard) {
        self.loopManager = loopManager
        self.journal = journal
        self.defaults = defaults
        self.phase = Phase(rawValue: defaults.string(forKey: Keys.phase) ?? "") ?? .idle
        self.epoch = defaults.object(forKey: Keys.epoch) as? Int

        // RELAUNCH. An ACTIVE loan with saved pod state resumes exactly as the phone resumes
        // after a relaunch (R40(e), re-ruled 2026-09-18: a stock relaunch — no fingerprint, no
        // age cap, no confirm, no notification). Everything else keeps the data-first drain
        // (spec §3.2): undrained records go out as a recovered hand-back and the pod session
        // is never resurrected. Construction is deferred to `resumeIfNeeded()`, which the
        // session calls once the hooks are wired: the resume fires `onLoanActiveChanged`, which
        // arms the dead-man ladder, and a hook fired before it is wired is a hook lost.
        let savedPumpState = phase == .active ? defaults.dictionary(forKey: Keys.pumpState) : nil
        if let savedPumpState {
            pendingResumeState = savedPumpState
        } else if journal.hasUndrainedEvents {
            phase = .recoveredDrain
            issueSessionEndedAlert()
        } else {
            switch phase {
            case .idle:
                break
            case .requested, .takingOver:
                // A start was in flight at kill/replace.
                // The phone may have granted and be waiting on a verdict; without one
                // it strands in .grantOffered and the user stares at a dead progress
                // bar. Stash the epoch — drainRecoveredIfNeeded fails it to the phone
                // once `send` is wired — and reset to a legible idle.
                pendingInterruptedTakeoverEpoch = epoch
                lastIdleNote = NSLocalizedString("Sport Mode start was interrupted. Tap Start to try again.", comment: "Glance: start interrupted by relaunch")
                phase = .idle
                epoch = nil
            case .active, .handingBack, .revoked, .recoveredDrain:
                // A live loan (or an in-flight drain) with no records left to send.
                // Never silently abandon it — the phone would stay .loaned ("Pod on
                // Watch") with nobody running the loop. Route to a recovered drain so
                // the phone gets a released hand-back and reclaims (offer is idempotent
                // by epoch; an empty event list still transitions the phone to owner).
                phase = .recoveredDrain
                issueSessionEndedAlert()
            }
        }
    }

    /// Saved pod state found at init for an ACTIVE loan, waiting for `resumeIfNeeded()`.
    private var pendingResumeState: PumpManager.RawStateValue?

    /// R40(e): resume the loan a relaunch interrupted. Called by the session after every hook is
    /// wired (the sibling of `drainRecoveredIfNeeded`, minus the transport dependency: the pod
    /// needs no phone). No-op unless init found an active loan with saved state.
    func resumeIfNeeded() {
        queue.async {
            guard let saved = self.pendingResumeState else { return }
            self.pendingResumeState = nil
            self.resumeSavedLoanOnQueue(saved)
        }
    }

    /// R40(e): rebuild the pump manager from the state saved while the loan was ACTIVE and carry
    /// on — the phone's `instantiateDeviceManagers`, on the wrist. The saved state already holds
    /// this watch's own BLE handle (patched in at the grant, then persisted by the manager), so
    /// BlePodComms auto-connects from it at init with no discovery. The journal is untouched:
    /// an active loan's undrained records are the normal checkpoint backlog, not a drain.
    private func resumeSavedLoanOnQueue(_ savedState: PumpManager.RawStateValue) {
        guard let manager = OmniPumpManager(rawState: savedState) else {
            // Unreadable state: fall back to what a relaunch did before — return the pod.
            defaults.removeObject(forKey: Keys.pumpState)
            phase = .recoveredDrain
            issueSessionEndedAlert()
            SportLog.event("loan", "RESUME failed — saved pod state unreadable; falling back to a recovered drain")
            return
        }
        manager.pumpManagerDelegate = self
        manager.delegateQueue = queue
        pumpManager = manager
        loopManager.pumpManager = manager
        onLoanActiveChanged?(true)
        SportLog.event("loan", "RESUMED — epoch \(epoch ?? -1) rebuilt from saved pod state after a relaunch (R40(e): stock relaunch) · \(RuntimeStateLog.snapshot())")
    }

    /// Fires from `init` on a relaunch that found undrained records — so the session did not
    /// "end" in front of the user, the app died mid-loan and this is the first they hear of it.
    /// The old copy claimed records "are being returned", a present progressive describing a
    /// drain that has not started yet and may not succeed; "may not be on the phone yet" is the
    /// honest form, and "yet" does the work of stock's authorise-waiting clause in one word.
    private func issueSessionEndedAlert() {
        let title = NSLocalizedString("Sport Mode Ended", comment: "Watch alert title on relaunch after the app died mid-loan")
        let body = NSLocalizedString("The watch app restarted. Insulin and carb records may not be on the phone yet.", comment: "Watch alert body on relaunch after the app died mid-loan")
        Task { @MainActor in
            loopManager.issueAlert(Alert(
                identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "sessionEnded"),
                foregroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                backgroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                trigger: .immediate))
        }
    }

    // MARK: - Incoming (wired from the WCSession delegate at integration)

    func handleIncoming(userInfo: [String: Any], channel: LoanTransportChannel) {
        queue.async { self.handleIncomingOnQueue(userInfo: userInfo, channel: channel) }
    }

    private func handleIncomingOnQueue(userInfo: [String: Any], channel: LoanTransportChannel) {
        let message: LoanMessage?
        do {
            message = try LoanMessage.decode(fromTransport: userInfo)
        } catch {
            // §2.9: never ack-and-drop — nack so the sender learns, and log at fault level.
            // The user-facing alert was removed: a build-version mismatch is not something
            // the wearer can act on mid-session, and the loan simply will not start, which
            // is its own visible signal.
            os_log("Undecodable v2 payload: %{public}@", log: log, type: .fault, String(describing: error))
            sendMessage(.nack(ProtocolNack(seenVersion: nil)))
            return
        }
        guard let message = message else { return }  // not a v2 payload

        // LOG EVERY ARRIVAL, BEFORE ANY GUARD.
        //
        // Without this line, "the ack never arrived" and "the ack arrived and a guard dropped
        // it" produce BYTE-IDENTICAL logs, because nothing records receipt and
        // `handleAck`'s epoch guard returns in silence. An instrument that cannot separate
        // "not delivered" from "delivered and discarded" cannot diagnose a delivery bug.
        //
        // `channel` is the discriminator that makes an occurrence answerable in one read.
        // Interactive kinds (grant/revoke/ack) ride sendMessage = .urgent; bookkeeping and diags
        // ride transferUserInfo = .queued (see LoanMessage.isInteractiveHandshake). A hand-back
        // wedge has been seen with the phone emitting BOTH — acks on urgent, diags on queued.
        // So: diags present and acks absent => only the immediate channel is wedged. Neither
        // present => the watch's whole inbound path is dead. Those are different bugs with
        // different fixes.
        SportLog.event("loan", "RX \(message.kindLabel) ch=\(channel.rawValue) — ours ev=\(epoch.map(String.init) ?? "nil") phase=\(phase.rawValue)")

        switch message {
        case .grant(let grant):
            handleGrant(grant)
        case .handbackAck(let ack):
            handleAck(ack)
        case .revoke(let revoke):
            handleRevoke(revoke)
        case .statusQuery(let query):
            handleStatusQuery(query)
        case .nack:
            // Logged, not alerted: the mirror of the undecodable case above, and equally
            // unactionable on the wrist.
            SportLog.event("loan", "phone NACKed our payload — build mismatch; the loan will not start")
        case .denied(let denied):
            // The phone refused — show why instead of hanging on "requesting…".
            requestTimeoutWork?.cancel()
            if phase == .requested || phase == .idle || phase == .recoveredDrain {
                returnToRestingPhase()
                lastIdleNote = denied.reason
                notifyUI()   // the reason must not wait for a tap
            }
            SportLog.event("loan", "DENIED by phone — \(denied.reason)")
        case .diag(let d):
            SportLog.event("phone", d.text)   // Phone hand-back breadcrumb → iCloud mirror
        case .dormantGrant(let dormant):
            handleDormantGrant(dormant)
        case .request, .takeoverComplete, .takeoverFailed, .doseRecordBatch, .handbackOffer, .statusReport:
            os_log("Ignoring phone-bound message kind on watch", log: log, type: .default)
        }
    }

    // MARK: - Internals

    func sendMessage(_ message: LoanMessage) {
        guard let dictionary = try? message.transportDictionary() else { return }
        send?(dictionary)
    }

    /// Title is a parameter now: "Loan Protocol Error" named an internal layer rather than the
    /// user's situation, and the only surviving caller is about a hand-back that did not confirm.
    func issueProtocolAlert(title: String, body: String) {
        Task { @MainActor in
            loopManager.issueAlert(Alert(
                identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "protocolNack"),
                foregroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                backgroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                trigger: .immediate))
        }
    }

    func teardownPump() {
        // Drop the BLE link EXPLICITLY before dropping the manager. Relying on deallocation to
        // tear down BlePodComms -> BluetoothManager -> CBCentralManager is the weakest release
        // path there is, and this is the one moment the pod must actually become free: without
        // an explicit disconnect nothing removes the pod from autoConnectIDs, any lingering
        // reference keeps the link, and a pod that stays CONNECTED is not advertising — so the
        // phone's standing connect cannot land however aggressive it is.
        //
        // The ONE boundary release: releaseConnection() drops the link, cancels an unfinished
        // takeover scan and clears the auto-connect bid. Its C5 record-close lands on a manager
        // copy discarded two lines down, so it books nothing here.
        SportLog.event("handback", "teardownPump: releasing BLE explicitly (see PODLOAN release log for the identifier)")
        pumpManager?.releaseConnection()
        pumpManager?.pumpManagerDelegate = nil
        pumpManager = nil
        defaults.removeObject(forKey: Keys.pumpState)   // R40(e): no pod held, nothing to resume
        // The loan's insulin book ends with the loan: the phone owns the truth again.
        let loopManager = self.loopManager
        Task { await loopManager.resetInsulinBook(reason: "teardown") }
        // ...and so does the override. WatchLoopManager lives for the PROCESS, not the loan, and
        // the grant intake writes the override with `if let` and no else-branch — so without
        // this an indefinite override from one loan kept rescaling ISF, basal and carb ratio
        // through the next one, while every UI surface correctly showed none. The next grant
        // brings its own; nothing should survive between them.
        loopManager.applyWristOverride(nil)
    }

    /// Best-effort streaming (§2.4): the phone accumulates the record even if the
    /// watch later dies. Loss is harmless — the cursor and IDs absorb redelivery.
    func streamRecords() {
        guard phase == .active, let epoch = epoch else { return }
        // Events that are IN-FLIGHT (mint→classification) or
        // whose verdict chase is LIVE stay out of the stream — the phone's commit set
        // is drawn from its staged map, so streaming either would let an interim
        // commit write a dose before an annul/refuted verdict can unwind it
        // (tombstones only filter staged events). They flow on classification.
        let events = journal.unackedEvents()
        let tombstones = journal.pendingTombstones()
        guard !events.isEmpty || !tombstones.isEmpty else { return }
        // What the watch streams to the phone. (Removed the old "implied Σ" — a sum of temp
        // rate×FULL-window with overlaps untruncated. It was a diagnostic-only over-count that fed
        // no logic and consistently mislead: it exceeds physically-possible delivery, so it is NOT a
        // meaningful commanded total. The trustworthy commanded number is the watch's own floored
        // reconciled dose total; the hand-back reconciliation delta will be captured separately.)
        // Ride the latest odometer reading along as a CHECKPOINT candidate: the phone pairs
        // "records through this batch" with "pod odometer at asOf" and, when they reconcile,
        // advances its audit base — so a later forced reclaim judges only the tail since this
        // sync. The reading is whatever the last dose window already fetched (no extra radio);
        // its asOf is the status response's own validTime, so the phone integrates expected
        // insulin to exactly the reading's moment, not the send's.
        // Coherence guard: a checkpoint pairs a COMPLETE record set with the reading. A
        // withheld event (in-flight mint→classification, or a live uncertainty chase) is
        // insulin the odometer may already meter but this batch does not carry — its
        // checkpoint would breach by construction. Skip; the next clean batch checkpoints.
        var odometer: LoanOdometerSnapshot?
        if let start = deliveredAtTakeover, let latest = pumpManager?.podLoanInsulinDelivered,
           let asOf = pumpManager?.podLoanInsulinDeliveredAt {
            odometer = LoanOdometerSnapshot(deliveredAtStart: start, deliveredLatest: latest,
                                            freshenSucceeded: false, asOf: asOf)
        }
        SportLog.event("handback", String(format: "stream: %d event(s), %d tombstone(s)%@", events.count, tombstones.count,
                                          odometer.map { String(format: " · odo %.2f U @ %@ [checkpoint]", $0.deliveredLatest, DateFormatter.localizedString(from: $0.asOf ?? .distantPast, dateStyle: .none, timeStyle: .medium)) } ?? ""))
        sendMessage(.doseRecordBatch(DoseRecordBatch(epoch: epoch, events: events, tombstones: tombstones, odometer: odometer)))
    }

    // MARK: - State owned by the extensions (stored properties cannot live in an extension)

    // MARK: - State for PodLoanWatchController+Grant.swift

    /// R40(b) entry gate: the pending offline-start offer, set when a normal request times
    /// out and a dormant grant is stored. The glance renders the deliberate confirm off the
    /// snapshot; confirmSeize()/dismissSeize() consume it. Queue-confined.
    var seizeOffer: (issuedAt: Date, token: UUID)?

    /// True only inside a confirmed seize's activation, to let handleGrant's lease and
    /// staleness guards stand aside for a credential that has neither (a dormant grant has
    /// no 5-minute lease, and its epoch is provisional and forced fresh at activation).
    var seizeActivationInFlight = false

    /// The reunion token of a seize whose activation is in flight but not yet proven. It is
    /// PROMOTED to the persisted active token only when the takeover reaches .active — an
    /// aborted activation never touched the pod, so nothing may later echo its token: a
    /// stale persisted token plus the activation's forced-fresh epoch is exactly the pair
    /// the phone's retro-ack matches on, and it would acknowledge a loan that never ran.
    /// Memory-only on purpose: a crash mid-ladder cannot resume the ladder, so there is
    /// nothing to reunify; a crash AFTER .active has the persisted token, which is the case
    /// reunion exists for.
    var pendingSeizeToken: UUID?

    /// True while the 30 s reunion debounce is pending, so reachability flapping arms it once.
    var seizeReunionDebounceArmed = false

    /// True while the reunion PROMPT is up: the phone became reachable during a seized
    /// loan and the user has not chosen yet. Queue-confined; rendered off the snapshot.
    var reunionPromptActive = false

    // MARK: - State for PodLoanWatchController+SimulatorDriver.swift

    // Stage 2: feed the phone's stock CGM-simulator BG (via WatchContext) into the REAL
    // glucose store on a timer, so the REAL loop/prediction runs. simIngestPhoneGlucose
    // dedups on date; the loop's own 4.2-min gate keeps it to one cycle per new phone reading.
    var simGlucoseTimer: DispatchSourceTimer?

    // MARK: - State for PodLoanWatchController+Handback.swift

    /// Highest epoch the phone has ever revoked — survives an unmatched revoke (see handleRevoke).
    /// The odometer captured at revoke, before teardown nils the pump — consumed by the
    /// offer builder as a fallback so revoke hand-backs still carry a reconcile baseline.
    var revokeCapturedDelivered: Double?

    /// The reading-time twin of `revokeCapturedDelivered` — captured together so a revoke
    /// hand-back's snapshot still carries the `asOf` the phone's checkpoint audit anchors on.
    var revokeCapturedDeliveredAt: Date?
    var lastRevokedEpoch: Int?

    // MARK: - State for PodLoanWatchController+Debug.swift

    /// Main-safe mirror of "is a loan active". Updated synchronously in the `phase` didSet, so
    /// it is never stale, and readable without touching `queue` — which doubles as the pump's
    /// delegateQueue and must never be sync'd from the UI (see the snapshot mirror below).
    let loanActiveMirrorLock = NSLock()
    var _loanActiveMirror = false

    /// Lock-guarded mirror of the last snapshot, refreshed asynchronously on `queue`.
    ///
    /// `debugSnapshot()` is `queue.sync`, and `queue` is ALSO OmniPumpManager's delegateQueue
    /// (:498) — so it is occupied for the whole duration of a bolus, a takeover ladder or a
    /// pod reclaim. GlanceViewModel polls on a 2s MAIN-THREAD timer, so every one of those
    /// polls blocked the main thread for the length of the pod operation. On the wrist that
    /// is the bolus screen freezing until delivery completes and then unfreezing as the
    /// haptic lands — and it would equally freeze the UI during any long pod operation.
    ///
    /// Display reads take the mirror instead: at most one refresh interval stale, never
    /// blocking. Dosing paths that genuinely need current state still call `debugSnapshot()`.
    let snapshotMirrorLock = NSLock()

    /// Throttle for the [glance-stale] instrument — one line per burst, not one per tick.
    private var lastMirrorDelayLogAt: Date?
    var _snapshotMirror: DebugSnapshot?
}

enum LoanTransportChannel: String {
    case urgent    // WCSession.sendMessage -> session(_:didReceiveMessage:)
    case queued    // WCSession.transferUserInfo -> session(_:didReceiveUserInfo:)
}

