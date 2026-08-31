//
//  PodLoanWatchController.swift
//  WatchApp Extension
//
//  The watch half of loan protocol v2 (docs/DESIGN_LOAN_PROTOCOL_V2.md §3.2, §10).
//  State machine, grant intake -> stock OmniPumpManager construction, the pump-host
//  delegate duties, the layer-1 verdict chase (the piece stock deliberately lacks:
//  stock resolves an unacknowledged command only on the NEXT natural pod contact;
//  during sport that can be minutes away, so the controller chases at 5s/20s/60s),
//  journal provenance consequences, hand-back with resend-until-ack, revoke, and the
//  relaunch drain (data-first: a dead session is never resurrected).
//
//  Transport is injected (`send`) so the controller is testable without WCSession;
//  the app-lifecycle integration wires WCSession.transferUserInfo/didReceiveUserInfo
//  to `send`/`handleIncoming`.
//

import Foundation
import HealthKit
import LoopKit
import G7SensorKit
import LoopCore
import OmnipodKit
import WatchKit
import os.log

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

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanWatchController")
    private let queue = DispatchQueue(label: "com.loopkit.Loop.PodLoanWatchController", qos: .utility)

    private let loopManager: WatchLoopManager
    private let journal: LoanEventJournal

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
    /// `epochScoped` timers refuse to fire into a loan they were not armed for.
    ///
    /// Opt-in, not blanket, because two kinds of timer legitimately cross: those armed before
    /// any grant, which have no epoch at all (the request timeout, whose whole job is to rescue
    /// a hung request), and those that must outlive their loan by design (the hand-back resend,
    /// which exists to keep pushing records after the loan ends).
    private func schedule(after delay: TimeInterval, label: String, epochScoped: Bool = false, execute work: DispatchWorkItem) {
        let armedEpoch = epoch
        let armedAt = now()
        SportLog.event("timer", "armed \(label) +\(fmtDelay(delay)) e=\(armedEpoch.map(String.init) ?? "-")\(epochScoped ? " scoped" : "")")
        let wrapper = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if work.isCancelled {
                SportLog.event("timer", "skipped \(label) — cancelled before its deadline")
                return
            }
            // Skip loudly: "never armed", "fired and did nothing" and "refused to fire" have to
            // stay distinguishable in the log, or a delivery bug cannot be diagnosed from it.
            if epochScoped, let armed = armedEpoch, armed != self.epoch {
                SportLog.event("timer", "REFUSED \(label) — armed e=\(armed), now e=\(self.epoch.map(String.init) ?? "-") · a different loan owns the pod")
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

    private func schedule(after delay: TimeInterval, label: String, epochScoped: Bool = false, execute body: @escaping () -> Void) {
        schedule(after: delay, label: label, epochScoped: epochScoped, execute: DispatchWorkItem(block: body))
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
    private var lastHandbackReachable: Bool?
    /// Did this hand-back EVER see the phone unreachable? Distinguishes the ordinary
    /// "phone was away" hang — which resolves itself the moment it returns — from the transport
    /// wedge, where every offer went out with reachable=true and none was ever acked. Only the
    /// second one is fixed by restarting the watch app, so only the second one should say so.
    private var handbackSawUnreachable = false
    /// Did any urgent send ERROR during this hand-back? Separates the two wedge variants at the
    /// timeout: erroring sends mean the session is re-establishing and will likely self-heal
    /// (variant B); silent sends with no acks mean the one-way wedge whose only known recovery
    /// is restarting the watch app (variant A). The advice for one is wrong for the other.
    private var handbackSawUrgentSendError = false

    /// Called by the transport when an urgent send's errorHandler fires (StockLoopSession).
    func noteUrgentSendFailed() {
        queue.async { self.handbackSawUrgentSendError = true }
    }

    /// Injected transport: dictionary -> WCSession.transferUserInfo (integration step).
    var send: (([String: Any]) -> Void)?

    /// Fires on loan lifecycle edges: true when the loan becomes ACTIVE (the session
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

    private(set) var phase: Phase {
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
                DispatchQueue.main.async { GlanceController.current?.refreshGlanceNow() }
            }
        }
    }
    private var epoch: Int? {
        didSet { defaults.set(epoch, forKey: Keys.epoch) }
    }

    private var pumpManager: OmniPumpManager?
    /// Odometer at takeover, for the hand-back snapshot pair (§1.4).
    private var deliveredAtTakeover: Double?
    /// When the current Start attempt began (request sent) — drives the glance
    /// progress bar. Meaningful only while phase is requested/takingOver.
    private var attemptStartedAt: Date?
    /// Wall-clock of the previous takeover-ladder read, and the largest gap seen between two
    /// consecutive reads this attempt. A read is event-driven when the pod stack's session-
    /// established callback fires (fast — no fixed period) and backstop-driven otherwise, on an
    /// 8 s timer. So an ordinary backstop-only run reads
    /// ~8 s apart; a gap far past THAT means the APP STOPPED EXECUTING mid-connect — not that the
    /// pod went quiet. Distinguishing those two is the whole point: they send the user to
    /// opposite places. (See `driver` on `attemptTakeoverRead` for the per-read tag.)
    private var lastTakeoverReadAt: Date?
    /// The pending takeover retry, held so the session-established event can fire it early.
    /// The ACTION is a plain closure and the BACKSTOP is the cancellable timer — they must not
    /// be the same object. Storing one DispatchWorkItem for both and doing cancel() then
    /// perform() stops the ladder dead the instant the event fires: a cancelled work item
    /// releases its block and performs nothing, so no retry and no timeout ever run.
    private var takeoverRetryAction: (() -> Void)?
    private var takeoverBackstop: DispatchWorkItem?
    private var takeoverMaxReadGap: TimeInterval = 0
    /// Hand-back offer resend counter (reset when a drain begins) — makes an
    /// unreachable-phone wait self-documenting in the log.
    private var handbackResendCount = 0
    /// A hand-back has been REQUESTED but the watch is still
    /// in control — phase stays .active, dosing and boluses continue, the journal
    /// drains via interim offers (released=false), and the user can cancel. Only when
    /// the drain is fully acked does finalizeHandback() stop dosing and send the
    /// final (released=true) offer. In-memory only: any relaunch ends the loan.
    private var handbackRequested = false
    /// Capability gate: interim offers only when the granting phone
    /// understands them; false/nil grant → legacy single-phase hand-back.
    private var phoneSupportsInterimHandback = false
    /// Only mint .overrideChange when the granting phone can decode it.
    private var phoneSupportsOverrideRecords = false
    /// finalizeHandback flips phase BEFORE its ~3-15s of pod work
    /// (temp-cancel + status reads); a duplicate interim ack arriving in that window
    /// must NOT close the loan (the final offer hasn't been sent — the phone would
    /// strand in .loaned forever). The close path requires this flag in .handingBack.
    private var finalOfferSent = false
    /// A pod COMMAND's journal event exists from MINT time, but its
    /// delivery classification (confirmed / uncertain / annulled) only lands at the
    /// enact COMPLETION seconds later — a resend or stream in that window would carry
    /// it to the phone, whose interim commit has no unwind for a later annul.
    /// Events in this set are withheld from streams and interim offers until their
    /// loanDidEnact classifies them. (Carb records mint CONFIRMED — never in-flight.)
    /// The odometer captured at revoke, before teardown nils the pump — consumed by the
    /// offer builder as a fallback so revoke hand-backs still carry a reconcile baseline.
    private var revokeCapturedDelivered: Double?
    /// The reading-time twin of `revokeCapturedDelivered` — captured together so a revoke
    /// hand-back's snapshot still carries the `asOf` the phone's checkpoint audit anchors on.
    private var revokeCapturedDeliveredAt: Date?

    private var inFlightEventIDs: Set<UUID> = []
    /// The single in-flight uncertainty being chased (mirrors the crude
    /// UncertainCommandRecord — one at a time; a NEW programming command destroys the
    /// verdict evidence and the conservative record stands, per d27a40c7 semantics).
    private var pendingUncertainEventID: UUID?
    private var chaseWorkItem: DispatchWorkItem?
    private var resendWorkItem: DispatchWorkItem?
    /// When the LIVE hand-back gives up waiting for the phone's ack and resumes on the
    /// watch. Set at the End tap (beginHandback), cleared on ack/cancel/timeout. Nil for a
    /// recovered/revoke drain (no local loan to resume — those keep resending).
    private var handbackDeadline: Date?
    /// When the CURRENT hand-back began — the anchor for the reclaim progress bar.
    /// Set and cleared in lockstep with `handbackDeadline`, which already marks exactly the
    /// hand-back's lifetime, so there is no second lifecycle to keep in step.
    private var handbackStartedAt: Date?
    /// When the FINAL (released=true) offer was sent — the clock the ack is racing.
    /// Splits "Reclaiming…" into the two intervals we could not previously tell apart:
    /// waiting for the phone's permission, versus iOS actually freeing the pod's BLE slot.
    private var finalOfferSentAt: Date?
    private var requestTimeoutWork: DispatchWorkItem?
    /// The pending post-dose release, so a second dose in the same cycle re-arms rather than
    /// stacking a second independent 12 s timer.
    private var postDoseReleaseWork: DispatchWorkItem?
    /// Surfaced on the glance idle screen after a failed/timed-out start, so the user
    /// sees WHY instead of a silent return to idle.
    private(set) var lastIdleNote: String?
    /// A start (requested/takingOver) was in flight when the
    /// app was killed or replaced. init() can't send — `send` is wired afterward — so
    /// it stashes the epoch here and drainRecoveredIfNeeded() (post-wiring) fails the
    /// takeover to the phone, which would otherwise strand in .grantOffered.
    private var pendingInterruptedTakeoverEpoch: Int?
    /// Manual bounded suspend end; a running bounded suspend survives
    /// hand-back and reports mode .suspended.
    private var manualSuspendEnd: Date?

    private enum Keys {
        static let phase = "PodLoanWatchController.phase"
        static let epoch = "PodLoanWatchController.epoch"
        static let pumpRawValue = "PodLoanWatchController.pumpManagerRawValue"
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

        // RELAUNCH (spec §3.2): never resurrect the pod session. Undrained records go
        // out as a recovered hand-back; persisted pump state is retained ONLY as data
        // (stock recovery semantics live phone-side after reclaim, spec §5.3.3).
        if journal.hasUndrainedEvents {
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

    /// Fires from `init` on a relaunch that found undrained records — so the session did not
    /// "end" in front of the user, the app died mid-loan and this is the first they hear of it.
    /// The old copy claimed records "are being returned", a present progressive describing a
    /// drain that has not started yet and may not succeed; "may not be on the phone yet" is the
    /// honest form, and "yet" does the work of stock's authorise-waiting clause in one word.
    private func issueSessionEndedAlert() {
        let title = NSLocalizedString("Sport Mode Ended", comment: "Watch alert title on relaunch after the app died mid-loan")
        let body = NSLocalizedString("The watch app restarted. Insulin and carb records may not be on the phone yet.", comment: "Watch alert body on relaunch after the app died mid-loan")
        loopManager.issueAlert(Alert(
            identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "sessionEnded"),
            foregroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
            backgroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
            trigger: .immediate))
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

    // MARK: - R40: the dormant grant (seize credential)


    /// UserDefaults keys for the stored seize credential. The grant blob (~14 KB) rides
    /// defaults deliberately: it must survive relaunches and be readable before any store
    /// wiring, exactly like the loan journal's persisted state.
    private enum DormantKeys {
        static let envelope = "PodLoanWatchController.dormantGrant"
        static let issuedAt = "PodLoanWatchController.dormantGrantIssuedAt"
        static let token = "PodLoanWatchController.dormantGrantToken"
        /// R40: set the moment a seize activates; rides every hand-back offer of the seized
        /// loan so the phone can retro-acknowledge; cleared when the loan CLOSES. Persisted —
        /// a relaunch mid-seized-loan must keep sending it.
        static let activeToken = "PodLoanWatchController.activeSeizeToken"
    }

    /// R40(b) entry gate: the pending offline-start offer, set when a normal request times
    /// out and a dormant grant is stored. The glance renders the deliberate confirm off the
    /// snapshot; confirmSeize()/dismissSeize() consume it. Queue-confined.
    private var seizeOffer: (issuedAt: Date, token: UUID)?
    /// True only inside a confirmed seize's activation, to let handleGrant's lease and
    /// staleness guards stand aside for a credential that has neither (a dormant grant has
    /// no 5-minute lease, and its epoch is provisional and forced fresh at activation).
    private var seizeActivationInFlight = false

    /// The reunion token of a seize whose activation is in flight but not yet proven. It is
    /// PROMOTED to the persisted active token only when the takeover reaches .active — an
    /// aborted activation never touched the pod, so nothing may later echo its token: a
    /// stale persisted token plus the activation's forced-fresh epoch is exactly the pair
    /// the phone's retro-ack matches on, and it would acknowledge a loan that never ran.
    /// Memory-only on purpose: a crash mid-ladder cannot resume the ladder, so there is
    /// nothing to reunify; a crash AFTER .active has the persisted token, which is the case
    /// reunion exists for.
    private var pendingSeizeToken: UUID?

    /// The takeover-liveness budget a seize activation mints for itself — the same 5 minutes
    /// a live grant gets from the phone. The DORMANT credential's own expiresAt is issuedAt
    /// by contract ("meaningless dormant"); forgetting to re-stamp it here is what killed
    /// the first field seize at ladder read 1 (2026-08-30, "grant lease expired
    /// mid-takeover" 900 ms after the confirm). The lease bounds the HANDSHAKE, not the
    /// credential — R40(d) keeps credential age uncapped and disclosed, and the handshake
    /// starts at the confirm.
    static let seizeActivationLease: TimeInterval = 5 * 60

    /// R40(b): the user asked, the phone did not answer, a credential exists — OFFER the
    /// offline path (never auto-take it). Shows the age per R40(d); a deliberate confirm
    /// activates, anything else stays idle.
    func confirmSeize() {
        queue.async {
            // R40 re-entry: the offer can be presented from plain idle OR from a parked
            // drain (.recoveredDrain) — a watch reboot mid-phoneless-loan rests there.
            guard self.phase == .idle || self.phase == .recoveredDrain, let offer = self.seizeOffer,
                  let dormant = self.storedDormantGrant(), dormant.seizeToken == offer.token else {
                SportLog.event("seize", "confirm arrived with no live offer — ignored [seize]")
                return
            }
            self.seizeOffer = nil
            // Force the local epoch FRESH: the credential's epoch is provisional (the
            // phone's counter at issue) and may be stale against loans granted since. The
            // phone's retro-ack matches on the token, not the epoch, so freshness here only
            // has to satisfy the watch's own monotonicity guards — plus the parked
            // journal's epoch, which the fold (handleGrant) re-tags and must strictly
            // exceed: a fold ONTO the same epoch would let the drain's queued
            // released=final offer close the LIVE loan on the phone.
            let newEpoch = max(dormant.grant.epoch, (self.epoch ?? 0) + 1, (self.journal.activeEpoch ?? 0) + 1)
            // Mint the LIVE lease alongside: the dormant expiresAt is issuedAt by contract,
            // so an un-restamped credential walks into the ladder already expired and the
            // mid-takeover lease guard kills it at read 1 (the first field seize, 2026-08-30).
            let leaseUntil = self.now().addingTimeInterval(Self.seizeActivationLease)
            self.pendingSeizeToken = dormant.seizeToken
            SportLog.event("seize", String(format: "SEIZE confirmed — activating dormant grant (issued %@, epoch %d→%d, lease +%.0fs, token …%@) [seize]",
                                           DateFormatter.localizedString(from: dormant.issuedAt, dateStyle: .short, timeStyle: .short),
                                           dormant.grant.epoch, newEpoch, Self.seizeActivationLease,
                                           String(dormant.seizeToken.uuidString.suffix(8))))
            self.phase = .requested
            self.attemptStartedAt = self.now()
            self.seizeActivationInFlight = true
            self.handleGrant(dormant.grant.withEpoch(newEpoch, leaseUntil: leaseUntil))
            self.seizeActivationInFlight = false
        }
    }

    func dismissSeize() {
        queue.async {
            guard self.seizeOffer != nil else { return }
            self.seizeOffer = nil
            self.lastIdleNote = NSLocalizedString("Offline start cancelled.", comment: "Glance note after dismissing a seize offer")
            SportLog.event("seize", "seize offer DISMISSED [seize]")
        }
    }

    /// Every refresh replaces the stored credential wholesale — the newest snapshot is the
    /// only one that matters (R40: full records, settings frozen at issue). Logged at each
    /// arrival so the field cadence is auditable; the seize confirm's age line reads
    /// issuedAt (R40(d): age SHOWN, never capped).
    /// Internal (not private) so tests can seed a stored credential through the real writer.
    func handleDormantGrant(_ dormant: DormantGrant) {
        guard let data = try? LoanProtocol.encoder.encode(dormant) else {
            SportLog.event("seize", "dormant grant arrived but failed to re-encode — NOT stored [seize]")
            return
        }
        defaults.set(data, forKey: DormantKeys.envelope)
        defaults.set(dormant.issuedAt, forKey: DormantKeys.issuedAt)
        defaults.set(dormant.seizeToken.uuidString, forKey: DormantKeys.token)
        SportLog.event("seize", String(format: "dormant grant refreshed — issued %@, %d dose record(s), token …%@ [seize]",
                                       DateFormatter.localizedString(from: dormant.issuedAt, dateStyle: .none, timeStyle: .medium),
                                       dormant.grant.doseHistory.count,
                                       String(dormant.seizeToken.uuidString.suffix(8))))
    }

    /// The stored seize credential, decoded fresh from defaults — the entry flow (next
    /// commit) reads this when the phone doesn't answer a normal request.
    func storedDormantGrant() -> DormantGrant? {
        guard let data = defaults.data(forKey: DormantKeys.envelope) else { return nil }
        return try? LoanProtocol.decoder.decode(DormantGrant.self, from: data)
    }

    // MARK: - Request / Grant / Takeover (§2.1-2.3)

    /// Where a failed or abandoned start attempt comes to rest. Plain .idle — unless
    /// undrained records are parked, in which case the resting phase is .recoveredDrain and
    /// the drain's resend chain is restarted (the 15 s re-arm guard deliberately lets the
    /// chain die whenever phase leaves the drain family, so every return must re-kick it).
    /// This is what makes the drain a STATE the watch passes through rather than a wall:
    /// field 2026-08-30, a watch reboot mid-seized-loan parked 3 records and then refused
    /// Start — silently — until the phone came back. The records resend on their own;
    /// nothing about them should block the next attempt.
    private func returnToRestingPhase() {
        if journal.hasUndrainedEvents {
            phase = .recoveredDrain
            sendHandbackOffer(freshened: false, recovered: true)
        } else {
            phase = .idle
        }
    }

    func requestLoan(watchBuild: String) {
        #if targetEnvironment(simulator)
        // Default in the sim: run the REAL loan protocol against the phone's simulated
        // Omnipod (OmniPumpManager fakes pod comms in-sim). The watch-only fake-flow driver
        // stays available behind a flag for when no paired phone is running.
        // Log the flag VALUE at the decision: a fresh container with the flag absent has been
        // seen driving the fake path, which contradicts this gate as read (the suspect is a
        // stale embedded binary), and this line settles it either way.
        let simFakeFlow = defaults.bool(forKey: "sim.fakeLoanFlow")
        SportLog.event("loan", "Start (sim): sim.fakeLoanFlow=\(simFakeFlow) — \(simFakeFlow ? "FAKE flow driver" : "REAL loan protocol")")
        if simFakeFlow { simDriveStart(); return }
        #endif
        queue.async {
            // R40 re-entry: a parked drain (.recoveredDrain) is startable ground, not a
            // wall. The staged records keep resending on their own timeline and, on the
            // seize path, FOLD into the new loan's stream (handleGrant). Any other busy
            // phase still refuses.
            guard self.phase == .idle || self.phase == .recoveredDrain else {
                SportLog.event("loan", "Start ignored — not idle (phase \(self.phase.rawValue))")
                return
            }
            if self.phase == .recoveredDrain {
                SportLog.event("loan", "Start over a parked drain — \(self.journal.unackedEvents().count) undrained event(s) keep resending; a seize would fold them in [seize]")
            }
            self.phase = .requested
            self.attemptStartedAt = self.now()
            self.lastIdleNote = nil
            // Advisory reachability ACCELERATES the timeout, never gates the attempt (R40(b)):
            // a session already reporting unreachable will not deliver a grant in the next
            // 17 s either, and the user is standing there watching "requesting…" — the first
            // field seize (2026-08-30) spent 25 s twice against a powered-off phone. A
            // reachable-LOOKING dead phone still gets the full window.
            let reachable = self.isPhoneReachable()
            let timeout: TimeInterval = reachable ? 25 : 8
            SportLog.event("loan", "REQUEST sent (build \(watchBuild)) — awaiting grant\(reachable ? "" : " (phone unreachable — short \(Int(timeout))s timeout)")")
            self.sendMessage(.request(LoanRequest(watchBuild: watchBuild, supportsSeize: true, sentAt: self.now())))

            // No grant within the timeout → the phone refused, is busy, or isn't reachable.
            // Return to idle with a visible reason instead of hanging on "requesting…".
            self.requestTimeoutWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.phase == .requested else { return }
                self.returnToRestingPhase()
                // R40(b): no answer + a stored credential = offer the offline path (never
                // auto-take it; the confirm is the user's deliberate act). No credential =
                // the pre-seize message stands.
                if let dormant = self.storedDormantGrant() {
                    self.seizeOffer = (issuedAt: dormant.issuedAt, token: dormant.seizeToken)
                    self.lastIdleNote = nil
                    SportLog.event("seize", String(format: "REQUEST TIMED OUT — offering offline start (credential issued %@) [seize]",
                                                   DateFormatter.localizedString(from: dormant.issuedAt, dateStyle: .short, timeStyle: .short)))
                } else {
                    self.lastIdleNote = NSLocalizedString("No response from iPhone — check the phone (loan refused, or busy) and try again.", comment: "Glance: loan request timed out")
                    SportLog.event("loan", "REQUEST TIMED OUT — no grant in \(Int(timeout))s (phone refused / busy / unreachable)")
                }
            }
            self.requestTimeoutWork = work
            self.schedule(after: timeout, label: "request-timeout", execute: work)
        }
    }

    #if targetEnvironment(simulator)
    // MARK: - Simulator flow driver — NEVER compiled into a device build.
    // Drives the loan `phase` on timers so the watch UI FLOWS run without a pod/phone/BLE.
    // Touches NO pod, NO BLE, NO WCSession, NO dosing — only the observable `phase` the glance
    // polls. Gated by targetEnvironment(simulator): it cannot reach a device, where this
    // controller drives the real Omnipod enact seam. (Stage 2 will feed the phone's stock CGM
    // simulator into the real glucose store so prediction/DoseMath run for real; the pod enact
    // is faked. This stage is the flow skeleton.)
    private func simDriveStart() {
        queue.async {
            guard self.phase == .idle else { return }
            SportLog.event("sim", "SIM start — driving idle→active on timers (no pod/BLE)")
            self.lastIdleNote = nil
            self.attemptStartedAt = self.now()
            self.phase = .requested
            self.schedule(after: 0.8, label: "sim-grant") { [weak self] in
                guard let self, self.phase == .requested else { return }
                self.attemptStartedAt = self.now()          // reset anchor for the ~10s takeover bar
                self.phase = .takingOver
            }
            self.schedule(after: 2.4, label: "sim-active") { [weak self] in
                guard let self, self.phase == .takingOver else { return }
                self.epoch = (self.epoch ?? 0) + 1
                self.phase = .active
                self.loopManager.setClosedLoopEnabled(false)   // Loans start OPEN
                self.simStartGlucoseFeed()                     // stage 2: feed phone-sim BG → real loop
                self.armDirectG7Watchdog(takeoverAt: self.now())   // same watchdog as a real loan
            }
        }
    }

    private func simDriveHandback() {
        queue.async {
            guard self.phase == .active else { return }
            SportLog.event("sim", "SIM hand-back — draining to idle")
            self.handbackRequested = true
            self.schedule(after: 2.5, label: "sim-handback") { [weak self] in
                guard let self, self.handbackRequested else { return }   // a cancel aborts the drain
                self.simStopGlucoseFeed()
                self.handbackRequested = false
                self.attemptStartedAt = nil
                self.phase = .idle
            }
        }
    }

    // Stage 2: feed the phone's stock CGM-simulator BG (via WatchContext) into the REAL
    // glucose store on a timer, so the REAL loop/prediction runs. simIngestPhoneGlucose
    // dedups on date; the loop's own 4.2-min gate keeps it to one cycle per new phone reading.
    private var simGlucoseTimer: DispatchSourceTimer?

    private func simStartGlucoseFeed() {
        simStopGlucoseFeed()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 30)
        timer.setEventHandler { [weak self] in self?.loopManager.simIngestPhoneGlucose() }
        timer.resume()
        simGlucoseTimer = timer
    }

    private func simStopGlucoseFeed() {
        simGlucoseTimer?.cancel()
        simGlucoseTimer = nil
    }
    #endif

    private func handleGrant(_ grant: LoanGrant) {
        SportLog.event("loan", "GRANT received — epoch \(grant.epoch), \(grant.pumpManagerRawState.count)B pod state")

        // A REAL grant supersedes any seize attempt that never proved out: drop the pending
        // reunion token so this (normal) loan's ACTIVE flip cannot promote a seize identity
        // it does not own. Covers every route to .active — they all pass through here first.
        if !seizeActivationInFlight { pendingSeizeToken = nil }

        /// Order matters here. The timeout is cancelled AFTER the phase check and BEFORE the
        /// rejections: a grant we are going to act on stops the timeout, but a rejected one must
        /// leave something to move the controller. Cancel any earlier and a rejection strands it
        /// at `.requested` with no timeout pending — and since `requestLoan` guards on
        /// `phase == .idle`, Start becomes a silent no-op until the app is relaunched. Every
        /// rejection path goes through `rejectGrant`, which restores `.idle` so the state does
        /// the timeout's job instead.
        guard phase == .idle || phase == .requested else {
            SportLog.event("loan", "grant ignored — wrong phase (\(phase.rawValue))")
            return
        }
        requestTimeoutWork?.cancel()

        /// Every rejection must leave the controller startable. Logs the reason, tells the phone
        /// where the protocol expects it, and returns to the resting phase (idle, or the
        /// parked drain when undrained records exist — startable either way).
        func rejectGrant(_ reason: String, notifyPhone: Bool) {
            SportLog.event("loan", "grant REJECTED — \(reason); returning to resting so Start works again")
            if notifyPhone {
                sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: reason)))
            }
            returnToRestingPhase()
        }
        guard self.now() < grant.expiresAt || seizeActivationInFlight else {
            // Row 2: a late grant self-rejects; the phone's T1 already reclaimed.
            // (A confirmed seize stands aside: a dormant credential has no lease — R40(d)
            // staleness was shown and consented to in the confirm.)
            rejectGrant("grant expired", notifyPhone: true)
            return
        }
        if let known = epoch, grant.epoch <= known, !seizeActivationInFlight {
            rejectGrant("stale epoch \(grant.epoch) (known \(known))", notifyPhone: false)
            return
        }
        // SPLIT-BRAIN GUARD (see handleRevoke): the existing expiry check cannot catch this —
        // the lease is 5 min against a 25s request timeout — and the stale-epoch check above is
        // inert because a timed-out request leaves `epoch` nil. Fails safe: the phone keeps the
        // pod and the user taps Start again.
        if let revoked = lastRevokedEpoch, grant.epoch <= revoked {
            rejectGrant("epoch \(grant.epoch) at or below the last revoke (ev=\(revoked)); the phone already asked for the pod back",
                        notifyPhone: true)
            return
        }

        // Therapy settings snapshot: the ONLY dosing limits; frozen for the
        // loan (spec §8). Validate COMPLETENESS at the loan
        // boundary and refuse with a stated reason — an incomplete config must be a
        // legible denial, not a per-cycle configurationError mid-session (a schedule lost
        // in serialization otherwise dies silently on every cycle of the whole
        // session). Validated BEFORE journal.begin so a
        // refusal leaves no journal/epoch residue.
        var decodedSettings: LoopSettings?
        if let raw = (try? PropertyListSerialization.propertyList(from: grant.therapySettingsRaw, options: [], format: nil)) as? LoopSettings.RawValue {
            decodedSettings = LoopSettings(rawValue: raw)
        }
        let missing: String? = {
            guard let s = decodedSettings else { return "settings snapshot" }
            if s.basalRateSchedule == nil { return "basal schedule" }
            if s.insulinSensitivitySchedule == nil { return "insulin sensitivity" }
            if s.carbRatioSchedule == nil { return "carb ratio" }
            if s.glucoseTargetRangeSchedule == nil { return "glucose target range" }
            if s.maximumBasalRatePerHour == nil { return "max basal rate" }
            if s.maximumBolus == nil { return "max bolus" }
            return nil
        }()
        if let missing = missing {
            returnToRestingPhase()
            lastIdleNote = String(format: NSLocalizedString("Can't start: %@ didn't arrive from the phone. Check therapy settings and try again.", comment: "Glance: grant refused for incomplete settings (1: missing field)"), missing)
            SportLog.event("loan", "grant REFUSED — therapy settings incomplete (\(missing))")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "therapy settings incomplete: \(missing)")))
            return
        }

        if seizeActivationInFlight, journal.hasUndrainedEvents {
            // R40 re-entry FOLD: the parked drain becomes this loan's opening stream —
            // epoch re-tagged, events/seqs/cursor/tombstones kept (see adoptEpoch for why
            // re-tagging beats re-minting). Seize-only: confirmSeize guarantees this epoch
            // strictly exceeds the parked one. A normal grant still refuses below — the
            // phone is reachable in that case and the drain resolves itself in seconds.
            let carried = journal.adoptEpoch(grant.epoch)
            SportLog.event("seize", "journal FOLDED — \(carried) undrained event(s) carried into epoch \(grant.epoch); the drain rides this loan's stream [seize]")
            // The folded stream carries REAL records from the prior seized era, and the
            // phone DROPS a future-epoch offer that has no token ("watch ahead of phone").
            // So the reunion token is persisted NOW, not at .active: even if this
            // activation aborts, the resend chain must keep the retro-ack door open.
            // The promote-at-.active hygiene still governs the no-fold path — its property
            // ("no token without records or a live loan") holds here BECAUSE records exist.
            if let token = pendingSeizeToken {
                defaults.set(token.uuidString, forKey: DormantKeys.activeToken)
                pendingSeizeToken = nil
                SportLog.event("seize", "reunion token …\(String(token.uuidString.suffix(8))) persisted at FOLD — the folded drain needs the retro-ack door [seize]")
            }
        } else {
            do {
                try journal.begin(epoch: grant.epoch)
            } catch {
                // An undrained prior loan must drain first — refuse, never clobber.
                rejectGrant("undrained prior loan must drain first", notifyPhone: true)
                return
            }
        }

        epoch = grant.epoch
        phoneSupportsInterimHandback = grant.supportsInterimHandback ?? false   // interim-handback capability gate
        phoneSupportsOverrideRecords = grant.supportsOverrideRecords ?? false    // override-record skew gate
        chaseWorkItem?.cancel()         // liveness: fresh loan, no chase residue
        pendingUncertainEventID = nil
        inFlightEventIDs = []
        handbackRequested = false
        finalOfferSent = false
        // Progress-bar anchor: ALWAYS re-anchor at grant. The grant round-trip is WCSession
        // roulette (0.5s to 15s observed on hardware) while the takeover itself is the
        // predictable part (~5s with the scan fix) — so the determinate bar measures
        // the takeover only; the request stage renders indeterminate. This also keeps
        // a late queued grant (after the 25s timeout) from inheriting a dead anchor.
        attemptStartedAt = self.now()
        lastTakeoverReadAt = nil          // fresh ladder, fresh stall measurement
        takeoverMaxReadGap = 0
        PodLoanConnectClock.reset()       // connect/disconnect stamps describe THIS attempt
        // Stamp every BLE edge with the execution state it fired in. The flapping has only
        // ever been seen overnight/wrist-down; Sport Mode is awake and moving. This is how we
        // find out whether the regime that matters behaves the same way.
        PodLoanConnectClock.appStateProbe = { RuntimeStateLog.appStateName() }
        RuntimeStateLog.probeTimerDeferral("takeover-start")
        phase = .takingOver
        loopManager.settings = decodedSettings!
        // Frozen-at-grant like the therapy settings above: run the RC implementation the
        // GRANTING phone runs, instead of silently assuming Standard. nil (older phone) →
        // Standard, the pre-existing behavior.
        loopManager.setIntegralRetrospectiveCorrection(grant.integralRetrospectiveCorrectionEnabled ?? false)
        // Predicted-low warning: inherited wholesale, and nil means an older phone that said
        // nothing — the wrist then stays silent rather than warning on invented defaults. The
        // snooze anchor travels inside, so a warning the phone posted moments before the hand-over
        // still suppresses the wrist's first cycle.
        loopManager.lowBGWarningSettings = grant.lowBGWarningSettings
        loopManager.lastLowBGWarningTime = grant.lowBGWarningSettings?.lastNotificationTime
        SportLog.event("lowbg", grant.lowBGWarningSettings.map {
            "inherited · enabled=\($0.enabled) night=\($0.nightWarningsEnabled) offsets \(Int($0.dayWarningOffset))/\(Int($0.nightWarningOffset)) · snooze \(Int($0.warningSnooze / 60))m · window \(Int($0.dontWarnIfSooner / 60))-\(Int($0.dontWarnIfLater / 60))m"
        } ?? "no settings in grant — wrist warnings stay OFF")
        // The wrist inherits the phone's loop mode: if the phone is closed the watch is
        // closed, if the phone is open the watch is open. An earlier rule reset every loan
        // to OPEN/advisory regardless; it was superseded for the sake of a second user's
        // intuition, not because confidence in the fail-safe changed, so a broader release
        // may revert to always-open.
        //
        // Frozen at the grant like the therapy settings. nil (a phone predating the field)
        // → false, i.e. exactly the old start-OPEN rule, so build skew degrades to the
        // previous behavior rather than to an unintended closed loop.
        loopManager.setClosedLoopEnabled(grant.phoneClosedLoopEnabled ?? false,
                                         reason: grant.phoneClosedLoopEnabled == nil
                                            ? "(older phone sent no loop mode — defaulting open)"
                                            : "inherited from the phone at grant")
        // Ring ruling 2026-08-23: the loop dot starts from the SYSTEM's recency — the phone
        // looped minutes ago at most, so the wrist should not open on grey/red for the seconds
        // until its own first cycle. Forward-only seed; the watch's first cycle (~10 s away)
        // takes over the clock immediately.
        if let phoneLoop = grant.lastLoopCompleted {
            loopManager.seedLastLoopCompleted(phoneLoop, source: "phone at grant")
        }
        // INSTRUMENTATION ONLY: stash the phone's prediction decomposition + echo it into the
        // log, BEFORE the takeover read / first prediction refresh, so [predict-diff] and [iob-diff]
        // Leg 1 have the phone baseline in hand. The serial dataAccessQueue guarantees the stash
        // lands before the first diff.
        ingestPredictionSnapshot(grant)

        // Log what the watch ACTUALLY received. The grant validates completeness but does
        // not record the VALUES, so verifying any prediction against real settings
        // otherwise means back-solving them from observed effects — which is unreliable,
        // because the insulin-effect window includes pre-loan dose history, not
        // just the loan odometer. Two settings-transfer bugs have already hidden here
        // (schedules never reaching the stores; missing overrideHistory), so this also
        // turns "did the settings arrive intact?" into a glance.
        if let s = decodedSettings {
            let now = self.loopManager.now()
            let isf = s.insulinSensitivitySchedule?.quantity(at: now).doubleValue(for: .milligramsPerDeciliter)
            let cr = s.carbRatioSchedule?.value(at: now)
            let basal = s.basalRateSchedule?.value(at: now)
            let target = s.glucoseTargetRangeSchedule?.quantityRange(at: now)
            let lo = target?.lowerBound.doubleValue(for: .milligramsPerDeciliter)
            let hi = target?.upperBound.doubleValue(for: .milligramsPerDeciliter)
            let csf = (isf != nil && cr != nil && cr! > 0) ? isf! / cr! : nil
            SportLog.event("settings", String(
                format: "granted @now — ISF %@ mg/dL/U · CR %@ g/U · CSF %@ mg/dL/g · basal %@ U/hr · target %@-%@ · maxBasal %@ U/hr · maxBolus %@ U",
                isf.map { String(format: "%.0f", $0) } ?? "nil",
                cr.map { String(format: "%.1f", $0) } ?? "nil",
                csf.map { String(format: "%.2f", $0) } ?? "nil",
                basal.map { String(format: "%.2f", $0) } ?? "nil",
                lo.map { String(format: "%.0f", $0) } ?? "nil",
                hi.map { String(format: "%.0f", $0) } ?? "nil",
                s.maximumBasalRatePerHour.map { String(format: "%.2f", $0) } ?? "nil",
                s.maximumBolus.map { String(format: "%.2f", $0) } ?? "nil"))
        }

        // Stock construction: exactly a phone relaunch. BlePodComms auto-connects from
        // podState.bleIdentifier at init (BlePodComms.swift:44) — no arming step.
        guard let rawValue = (try? PropertyListSerialization.propertyList(from: grant.pumpManagerRawState, options: [], format: nil)) as? [String: Any],
              let rawState = rawValue["state"] as? PumpManager.RawStateValue,
              let manager = OmniPumpManager(rawState: rawState) else {
            teardownPump()
            returnToRestingPhase()
            lastIdleNote = NSLocalizedString("Couldn't read the pod from the phone. Try again.", comment: "Glance: pump snapshot rejected")
            SportLog.event("loan", "grant FAILED — could not rebuild the pump from the phone's snapshot")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "pump state snapshot rejected")))
            return
        }

        manager.pumpManagerDelegate = self
        manager.delegateQueue = queue
        pumpManager = manager
        persistPumpRawValue()
        ingestGrantHistory(grant)
        // Cross-device adoption: the phone's bleIdentifier is useless here — scan for
        // the pod by its address and adopt the peripheral THIS watch discovers.
        // The grant's LIVE temp record (still-delivering at takeover, omitted from the
        // seed) gates and parameterizes the re-arm — it corroborates that the PHONE's books
        // also believe the temp is running (guards the stale-C5-signature corner across
        // back-to-back loans), and its endDate is the only way to restore a 0 U/hr temp's span.
        let liveTempRecord = grant.seedDoseEntries(finishedBy: self.now()).live.first { $0.type == .tempBasal }
        let scanning = manager.podLoanBeginTakeover(liveTempStart: liveTempRecord?.startDate,
                                                    liveTempEnd: liveTempRecord?.endDate)
        SportLog.event("loan", "pump rebuilt — \(scanning ? "scanning for the pod by address" : "no pod address!") for takeover")
        // beginTakeover re-armed the C5-cancelled inherited temp (if any) so THIS watch
        // tracks its live delivery — IOB climbs with the running temp instead of freezing at
        // the handover stamp. The seed omits it (live dose); the pod's mutable re-reports own it.
        if let liveTemp = manager.podLoanLiveTempBasalDescription {
            SportLog.event("loan", "#72: tracking inherited running temp — \(liveTemp) (mutable, pod-owned; IOB tracks delivery)")
        } else if liveTempRecord != nil {
            SportLog.event("loan", "#72: live temp in grant but NOT re-armed (no C5 signature / start mismatch) — record stays closed at handover")
        }

        // First pod status = the takeover proof (§2.3). The pod's BLE session takes
        // SECONDS to establish after construction (scan → connect → EAP-AKA), but a
        // status read fails INSTANTLY with .podNotConnected until it's up
        // (BlePodComms.bleRunSession guard). So retry on a bounded schedule — the
        // pod-side timeout budget (~40s) — instead of failing on the first,
        // pre-connection read.
        // The lease horizon, logged at entry: a grant whose budget is already negative or
        // seconds-thin dies at read 1 with "lease expired mid-takeover", and that death
        // should be legible HERE rather than reconstructed from issue timestamps (the
        // first field seize burned two attempts before the un-restamped dormant lease
        // was identified as the killer).
        SportLog.event("loan", String(format: "takeover ladder start — lease %+.0fs, epoch %d%@",
                                      grant.expiresAt.timeIntervalSince(now()), grant.epoch,
                                      pendingSeizeToken != nil ? " [seize]" : ""))
        attemptTakeoverRead(manager: manager, grant: grant, attempt: 0)
    }

    /// Up to 14 reads while the pod's BLE session establishes — fast when the session-established
    /// event drives them (no fixed period), up to ~112s if every read falls through to the 8s
    /// backstop.
    /// The takeover waits for the pod stack's own session-established EVENT
    /// instead of inferring readiness from a polled CBPeripheral.state.
    ///
    /// Why: `peripheral.state`, read from this controller's queue, is not valid there, and it
    /// contradicts the connect callbacks every time — reporting "disconnected" or "connecting"
    /// a fraction of a second after didConnect. bleRunSession bails on that stale value, so no
    /// byte is ever sent and the pod hangs up on the silent link.
    ///
    /// So: the event drives the retry, and the periodic poll is only a slow backstop. A
    /// short debounce after the event lets the peripheral state propagate to our queue before
    /// the read, since the guard downstream still consults it.
    ///
    /// Deliberately NOT applied to the steady-state reclaim, which is reliable in the field
    /// precisely because it never re-enters this configuration path. Takeover-only: the initial
    /// takeover gets its own protocol.
    private func setTakeoverSessionListener(_ armed: Bool) {
        guard armed else {
            PodLoanConnectClock.podLoanOnSessionEstablished = nil
            takeoverBackstop?.cancel()
            takeoverBackstop = nil
            takeoverRetryAction = nil
            return
        }
        PodLoanConnectClock.podLoanOnSessionEstablished = { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                guard self.phase == .takingOver, let action = self.takeoverRetryAction else { return }
                SportLog.event("loan", "takeover: pod session ESTABLISHED (stack event) — reading now instead of waiting for the backstop")
                self.takeoverRetryAction = nil
                self.takeoverBackstop?.cancel()      // cancel the TIMER only
                self.takeoverBackstop = nil
                self.schedule(after: 0.25, label: "session-event-settle") { action() }   // the action still lives
            }
        }
    }

    /// `driver` says WHY this particular read fired: "initial" (attempt 0), "event" (the pod
    /// stack's session-established callback ran it early), or "backstop" (the 8s timer fired with
    /// no event). Without it, the split between event-driven reads (fast, irregular) and
    /// backstop-driven ones (exactly the backstop period) has to be INFERRED by
    /// cross-referencing the "session
    /// ESTABLISHED" log line against the read line that followed it. Stamping the driver directly
    /// on every read line makes that split a single grep instead of a reconstruction.
    private func attemptTakeoverRead(manager: OmniPumpManager, grant: LoanGrant, attempt: Int, driver: String = "initial") {
        let maxAttempts = 14
        manager.podLoanReadStatus { [weak self] success in
            guard let self = self else { return }
            self.queue.async {
                guard self.phase == .takingOver, self.epoch == grant.epoch else {
                    // Verdict completeness: a takeover must never vanish without a verdict.
                    // This fires when the in-flight ladder for grant.epoch was superseded — the user
                    // re-tapped Start (phase left .takingOver) or a newer grant bumped the epoch.
                    // Log-only: a "superseded" line, not a behavior change.
                    SportLog.event("loan", "TAKEOVER SUPERSEDED — epoch \(grant.epoch) abandoned mid-ladder (now phase \(self.phase.rawValue), epoch \(self.epoch.map(String.init) ?? "nil"))")
                    return
                }
                // CRITICAL: the grant's ~5-min lease is validated
                // once at intake, but this ladder can run FAR past its nominal ~40s
                // when the app is suspended mid-ladder — frozen queue timers draining
                // late on wake have stretched one ladder to 23 minutes.
                // Past the lease, the phone is entitled to have
                // T1-reclaimed the pod; flipping .active here would put TWO controllers
                // on one pod. Re-check the lease every iteration and abort BEFORE
                // honoring a successful read — expiry outranks a good status.
                guard self.now() < grant.expiresAt else {
                    self.teardownPump()
                    self.returnToRestingPhase()
                    // Two messages, because the two failures need OPPOSITE user responses.
                    // The wedge (Code-11, or a ladder that never connected once) is made WORSE
                    // by retrying — tonight's field session force-quit-and-retried its way from
                    // one camped slot to a blind radio — and fixed by a watch Bluetooth toggle.
                    // Only a clean transient (pod seen, connects attempted, no #11) earns
                    // "try again".
                    if PodLoanConnectClock.wedgeSignature {
                        self.lastIdleNote = NSLocalizedString("The pod didn't answer. Turn watch Bluetooth off and on, then try again.", comment: "Glance: takeover failed with the BLE-wedge signature")
                    } else {
                        self.lastIdleNote = NSLocalizedString("Sport Mode start expired before the pod answered. Tap Start to try again.", comment: "Glance: grant lease expired mid-takeover")
                    }
                    SportLog.event("loan", "TAKEOVER ABORTED — grant lease expired mid-takeover after \(attempt + 1) read(s), epoch \(grant.epoch), wedgeSignature=\(PodLoanConnectClock.wedgeSignature)\(self.pendingSeizeToken != nil ? " [seize]" : "")")
                    self.sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "grant expired mid-takeover")))
                    return
                }
                if success, let delivered = manager.podLoanInsulinDelivered {
                    self.revokeCapturedDelivered = nil   // new loan, new baseline — never a stale capture
                    self.revokeCapturedDeliveredAt = nil
                    self.deliveredAtTakeover = delivered
                    self.phase = .active
                    // R40 reunion identity: the seize is PROVEN only now — persist its token
                    // so the loan's offers echo it and the phone can retro-acknowledge. Every
                    // failed activation leaves this un-promoted, so nothing stale can match.
                    if let token = self.pendingSeizeToken {
                        self.defaults.set(token.uuidString, forKey: DormantKeys.activeToken)
                        self.pendingSeizeToken = nil
                        SportLog.event("seize", "seized loan ACTIVE — reunion token …\(String(token.uuidString.suffix(8))) persisted for the offer echo [seize]")
                    }
                    self.loopManager.pumpManager = manager
                    self.loopManager.loanDoseRecorder = self
                    self.onLoanActiveChanged?(true)
                    let takeoverSecs = self.attemptStartedAt.map { self.now().timeIntervalSince($0) } ?? -1
                    SportLog.event("loan", String(format: "ACTIVE — epoch %d, pod taken after %d read(s) in %.1fs [takeover-timing], odometer %.2f U, final read driver=%@ · %@",
                                                  grant.epoch, attempt + 1, takeoverSecs, delivered, driver, RuntimeStateLog.snapshot()))
                    self.sendMessage(.takeoverComplete(TakeoverComplete(epoch: grant.epoch, firstPodStatus: self.currentPodStatus())))
                    self.armDirectG7Watchdog(takeoverAt: self.now())
                    // Refresh the glance eventual + IOB from the just-seeded insulin/carbs/
                    // glucose NOW (display-only, no enact) so the prediction reflects the seeded
                    // carbs at takeover instead of the stale pre-loan value until the first G7
                    // reading drives a full cycle. The seeds completed well before this point.
                    // THE WATCH ASSERTS ITS OWN PROGRAM AT TAKEOVER — no program crosses the
                    // boundary. Two controllers sharing one temp is the defect behind a whole
                    // family of problems: unbooked tails, re-arm copy divergence, the record-close
                    // that truncated a running temp at every release, and a systematic audit bias
                    // (expectedInsulin predicts the SCHEDULE across a gap it has no journal segment
                    // for, so an inherited 0.90 U/hr against a 0.70 schedule accrues ~0.20 U/hr of
                    // unexplained delivery). A clean boundary removes that rather than accounting
                    // around it.
                    //
                    // A full loop() rather than a bespoke enact, deliberately: it reuses every gate
                    // (closed-loop mode inherited from the grant, glucose recency, pump-data
                    // freshness, DoseMath limits, the IOB clamp), records a CYCLE VERDICT like any
                    // other cycle, and — the point — MINTS A JOURNAL EVENT, so the loan's first
                    // program is ours, streamed to the phone, and inside the audit. The pod link is
                    // already up here, so the enactor's reclaim is a no-op. The new temp supersedes
                    // the old in the same breath, so there is no gap in delivery.
                    SportLog.event("loan", "takeover: asserting our own program (R2 overturned — no inherited temp crosses the boundary)")
                    self.loopManager.loop()
                    // Time-separate the radios. The takeover is done and the initial status
                    // is read, so the pod BLE connection isn't needed until the next dose.
                    // Release it (orphan the pod — it runs its last basal natively;
                    // keys/state untouched) so G7 acquisition has the watch's radio
                    // uncontested.
                    //
                    // UNCONDITIONAL, deliberately. The gate this replaced read a defaults key
                    // whose toggle and registered default had been deleted, so it evaluated
                    // FALSE — "hold the pod link forever" — on any device where the toggle had
                    // never been switched on. A held link starves G7 acquisition outright
                    // (zero adoptions across ~130 min of held link in a controlled toggle
                    // test), so a fresh install would silently lose the sensor while a device
                    // carrying the old persisted value looked fine. Never re-gate this.
                    do {
                        // Releasing AT takeover broke G7
                        // entirely — a "connects-but-can't-read" loop, the pod cancel
                        // left it stuck .disconnecting and poisoned the shared BLE
                        // budget (the same watchOS teardown demon that causes the
                        // missed windows). DEFER the release: take the free first read
                        // with the pod connected — the first connection is always the
                        // good one — then cancel a SETTLED, idle connection ~90s later,
                        // which should tear down cleaner than a fresh one.
                        SportLog.event("loan", "pod release DEFERRED +90s (release a settled connection after first reads)")
                        let scheduledReleaseAt = self.now().addingTimeInterval(90)
                        self.schedule(after: 90, label: "takeover-budget") { [weak self] in
                            self?.performDeferredTakeoverRelease(epoch: grant.epoch, manager: manager,
                                                                scheduledAt: scheduledReleaseAt)
                        }
                    }
                } else if attempt + 1 < maxAttempts {
                    if attempt == 0 {
                        SportLog.event("loan", "connecting to pod… (BLE session establishing; typically ~17s, budget ~40s)")
                    }
                    // Log the pod BLE state each failed read so "unreachable"
                    // shows WHY — stuck disconnected (pod not advertising / still held by the
                    // phone) vs connecting-but-no-response.
                    let readElapsed = self.attemptStartedAt.map { self.now().timeIntervalSince($0) } ?? -1
                    // Measure the inter-read gap. Backstop-driven reads land ~8 s apart (event-
                    // driven reads can be much faster) — a gap well past 8 s is suspended-app time,
                    // not pod silence.
                    let readNow = self.now()
                    if let prev = self.lastTakeoverReadAt {
                        self.takeoverMaxReadGap = max(self.takeoverMaxReadGap, readNow.timeIntervalSince(prev))
                    }
                    self.lastTakeoverReadAt = readNow
                    // Probe the NEXT inter-read interval directly, so a stalled ladder says
                    // whether the OS deferred our timer or the read itself blocked. Only on the
                    // first few reads — this is a meter, not a metronome.
                    if attempt < 3 { RuntimeStateLog.probeTimerDeferral("ladder-read\(attempt + 1)") }
                    // Pair OUR observation with the BLE stack's own timestamps. If didConnect
                    // reads +12s while this poll is landing at +68s, the link was up and only our
                    // deferred timer was late — fix the ladder. If didConnect says "never", the
                    // radio genuinely hasn't connected — fix the keepalive. The poll alone cannot
                    // distinguish those, which is why this line exists.
                    // The G7 stamp exists because Code-11 during a takeover cannot name its
                    // holder from OmnipodKit's own census — the G7's central is a separate
                    // manager, and a pending connect camped there is invisible here. One field:
                    // how long a G7 connect has been pending, or "-" when none is.
                    let g7Pending = G7RadioCensus.connectPendingSince
                        .map { String(format: "g7pending=%.0fs", self.now().timeIntervalSince($0)) } ?? "g7pending=-"
                    SportLog.event("loan", String(format: "takeover read %d/%d driver=%@ (+%.1fs) — pod BLE state %@ · %@ · \(g7Pending) · %@",
                                                  attempt + 1, maxAttempts, driver, readElapsed,
                                                  manager.podLoanConnectionStateDescription,
                                                  PodLoanConnectClock.summary(since: self.attemptStartedAt),
                                                  RuntimeStateLog.snapshot()))
                    // The retry is a cancellable work item so the session-established
                    // event can run it IMMEDIATELY. The timer is only a backstop at 8 s —
                    // with the event driving progress, polling faster only burns
                    // the attempt budget against a stale state read.
                    let fireRetry: (String) -> Void = { [weak self] nextDriver in
                        guard let self = self else { return }
                        self.takeoverRetryAction = nil
                        self.takeoverBackstop = nil
                        guard self.phase == .takingOver, self.epoch == grant.epoch else {
                            // The ladder was superseded during the inter-attempt wait
                            // (re-Start or a newer epoch). Emit the verdict instead of vanishing.
                            SportLog.event("loan", "TAKEOVER SUPERSEDED — epoch \(grant.epoch) abandoned between reads (now phase \(self.phase.rawValue), epoch \(self.epoch.map(String.init) ?? "nil"))")
                            return
                        }
                        self.attemptTakeoverRead(manager: manager, grant: grant, attempt: attempt + 1, driver: nextDriver)
                    }
                    self.takeoverRetryAction = { fireRetry("event") }
                    let backstop = DispatchWorkItem { fireRetry("backstop") }
                    self.takeoverBackstop = backstop
                    self.schedule(after: 8, label: "takeover-read", execute: backstop)
                } else {
                    self.teardownPump()
                    self.returnToRestingPhase()
                    let failSecs = self.attemptStartedAt.map { self.now().timeIntervalSince($0) } ?? -1
                    // A stalled ladder usually means watchOS suspended the app mid-connect, not
                    // that the pod is unreachable — so the message must not send the user to the
                    // pod. `.takingOver` holds runtime through `onTakeoverRadioHold`
                    // (StockLoopSession.swift), the same WorkoutKeepalive soak and hand-back use,
                    // so this gap should only open if the keepalive itself failed to start or
                    // renew (HK auth denied, session error).
                    //
                    // `RuntimeStateLog.snapshot()` on every read line settles which it was without
                    // inference: "keepalive running(takeover)" on every read means the keepalive
                    // held and the stall is something else; "off"/"DENIED"/"FAILED" means the
                    // keepalive is the failure.
                    let stalled = self.takeoverMaxReadGap > 20
                    if stalled {
                        // Say ONLY what was measured. Battery level does NOT track the outcome:
                        // takeovers succeed at 20% with the wrist up, and run unsuspended at 65%
                        // under the same no-keepalive condition. What tracks the outcome is
                        // whether anything kept the app awake during the connect.
                        // Guessing a remedy is how an earlier note ended up blaming a healthy pod.
                        self.lastIdleNote = String(format: NSLocalizedString(
                            "Sport Mode didn't start — the watch app stopped running mid-connect (%@). Your phone still has the pod. Keep the watch awake — wrist up or screen on — and try again.",
                            comment: "Glance: takeover failed because the app was suspended"), batteryTag())
                    } else {
                        // Root-caused, and it is NOT the pod. Every connect
                        // returned CBErrorDomain#11 (connectionLimitReached) — a limit on THIS
                        // APP's CoreBluetooth slots, not a busy or sleeping pod. The phone had
                        // released cleanly (its own log showed the link down) and the pod's
                        // census held one disconnected device. The slot was ours: the G7 client
                        // leaves an armed pending connect alive across a takeover
                        // and a pending connect reserves a slot. Hence the
                        // gap signature — re-takeovers 12-15 s apart all succeeded, the one after a
                        // 153 s quiet gap failed, because only the long gap gave the G7 time to
                        // re-arm.
                        //
                        // So telling the user to "check the pod is nearby and awake" sent them to
                        // inspect healthy hardware for a fault in our own radio bookkeeping. Say
                        // the two things that are true and useful instead: nothing moved, and a
                        // short wait is the remedy that actually works in the field.
                        self.lastIdleNote = String(format: NSLocalizedString(
                            "Sport Mode didn't start (%.0fs). Your phone still has the pod and is still looping. Wait ~30s, then try again.",
                            comment: "Glance: takeover failed — the pod link never established"), failSecs)
                    }
                    SportLog.event("loan", String(format: "TAKEOVER FAILED — %@ after %d reads in %.1fs [takeover-timing], max inter-read gap %.1fs (event-driven; 8s backstop when no event fires), %@, final BLE state %@, %@, %@, epoch %d%@",
                                                  stalled ? "ladder STALLED (our polling was deferred; see cb: for whether the link was up)" : "pod unreachable",
                                                  maxAttempts, failSecs, self.takeoverMaxReadGap, batteryTag(),
                                                  manager.podLoanConnectionStateDescription,
                                                  PodLoanConnectClock.summary(since: self.attemptStartedAt),
                                                  RuntimeStateLog.snapshot(), grant.epoch,
                                                  self.pendingSeizeToken != nil ? " [seize]" : ""))
                    // The reason string is rendered verbatim in the PHONE's notification body
                    // ("The watch could not take the pod (…). The phone kept it."), so it carries
                    // the same obligation as the wrist note above: do not blame the pod for a
                    // connection slot we were holding ourselves.
                    self.sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: stalled ? "watch app suspended mid-takeover" : "couldn't establish the pod link")))
                }
            }
        }
    }

    // MARK: - Reconnect the orphaned pod to dose, then re-release

    /// Wired to WatchLoopManager via StockLoopSession. Called just before a dose while
    /// the between-dose time-separation has the pod orphaned. completion(true) = pod connected
    /// & ready; (false) = couldn't reconnect in the bounded window → caller SKIPS the dose (pod
    /// keeps running its baseline). Uses podLoanReadStatus as the connection probe —
    /// idempotent and exactly what the takeover ladder uses, so no double-dose risk.
    /// When the pod link was last confirmed alive (successful reclaim read or release).
    /// Reclaims have succeeded and then failed within the same session with no visible
    /// difference; idle duration is one of the few candidate discriminators left, so it is
    /// measured rather than eyeballed from timestamps.
    private var lastPodLinkContact: Date?
    /// Highest epoch the phone has ever revoked — survives an unmatched revoke (see handleRevoke).
    private var lastRevokedEpoch: Int?

    /// The reclaim must not start INSIDE the G7's connect+auth burst. Measured across 140
    /// ladders over five days, the single discriminator is how much live G7 GATT session
    /// remains when the reclaim starts: >1 s remaining → 0/45 succeed; closing within 1 s →
    /// 62/69; no link at all → 23/26 (p ≈ 2.7e-27). A G7 SCAN in flight is harmless (4/4) —
    /// the contended resource is the connection initiator, not the scanner.
    ///
    /// The enact path already waits (WatchLoopManager :1822), but the "pump data N min old"
    /// pre-cycle refresh reclaims BEFORE any arbitration. Gating here covers every caller.
    ///
    /// Is the pod's standing auto-connect bid currently RELEASED? Code that assumes the pod
    /// link is held is wrong once a between-dose release has disarmed the bid, and nothing
    /// re-arms it. Lock-free read of the manager's own flag; safe from any thread.
    var podConnectionIsReleased: Bool {
        return pumpManager?.isConnectionReleased ?? false
    }

    /// While this is in the future, a pod COMMAND is in flight and the link must not be
    /// pulled. Opened by every reclaim-to-dose, closed by the matching release. It is a
    /// deadline rather than a bool so a dose path that dies without releasing cannot strand
    /// the link held forever — the window simply expires.
    ///
    /// Without it, the takeover's +90 s deferred release can fire between a temp-basal
    /// command's two writes and disconnect the pod mid-command: the write times out and the
    /// dose is lost. The release closure guards only on phase and epoch — it has no idea a
    /// command is in flight.
    /// Touched only on `queue`, which is where all three of reclaim, release and the deferred
    /// release run.
    private var doseWindowUntil: Date?

    /// The takeover's deferred pod-link release, extracted so it can re-defer itself.
    ///
    /// Unguarded, this fires into a temp-basal enact — between the command's two writes — and
    /// disconnects the pod mid-command. The
    /// write times out and the dose is lost. The +90 s mark lands at a uniformly random point
    /// on the 5-minute reading grid, so roughly one loan in a hundred hits the ~2-3 s overlap,
    /// and it always costs the FIRST dose.
    ///
    /// Re-defers in 10 s steps while a pod command is in flight. Self-limiting: `doseWindowUntil`
    /// is a deadline, so even a dose path that dies without releasing lets this proceed once the
    /// window expires — it can never hold the link open indefinitely.
    private func performDeferredTakeoverRelease(epoch grantEpoch: Int, manager: OmniPumpManager, scheduledAt: Date) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .active, epoch == grantEpoch else { return }

        if let busyUntil = doseWindowUntil, busyUntil > now() {
            SportLog.event("loan", String(format: "pod release DEFERRED again — dose in flight (retry in 10s, window closes in %.0fs)",
                                          busyUntil.timeIntervalSince(now())))
            schedule(after: 10, label: "deferred-release-retry") { [weak self] in
                self?.performDeferredTakeoverRelease(epoch: grantEpoch, manager: manager, scheduledAt: scheduledAt)
            }
            return
        }

        // Same before/after capture as the post-dose release. This is the one that has fired
        // minutes LATE with the app suspended, by which point the pod had
        // self-disconnected — so we cancelled nothing and wedged the peripheral. `before`
        // says outright whether the link was still alive when we pulled it, and the
        // scheduled-vs-actual delay says whether runtime was stolen.
        let before = manager.podLoanConnectionStateDescription
        let lateBy = now().timeIntervalSince(scheduledAt)
        // ORPHAN, not release — dropping the BLE link keeps the watch as controller;
        // the C5 record-close in releaseConnection() is handover accounting and was silently
        // truncating the running temp at every release (killing live IOB tracking ~90s in).
        manager.podLoanOrphanConnection()
        lastPodLinkContact = now()
        SportLog.event("loan", String(format: "E4: pod BLE released (+90s deferred, %.0fs late) — state was %@ at cancel%@",
                                      lateBy, before,
                                      before == "connected" ? "" : " ** cancelled a link that was ALREADY GONE **"))
        schedule(after: 3, label: "release-verify") { [weak self] in
            guard let self = self, let manager = self.pumpManager else { return }
            let after = manager.podLoanConnectionStateDescription
            SportLog.event("loan", "E4: post-release pod state \(after)\(after.hasPrefix("DISCONNECTING") ? " ** WEDGED — poisoning signature **" : "")")
        }
    }

    func reclaimPodForDose(_ completion: @escaping (Bool) -> Void) {
        queue.async {
            guard self.phase == .active, let manager = self.pumpManager else { completion(false); return }
            // Bounded generously: the reclaim ladder alone budgets ~40 s, plus the command.
            self.doseWindowUntil = self.now().addingTimeInterval(75)
            let idle = self.lastPodLinkContact.map { self.now().timeIntervalSince($0) }
            SportLog.event("loan", String(format: "E4: reclaim starting — pod BLE state %@, released=%@, idle %@",
                                          manager.podLoanConnectionStateDescription,
                                          manager.isConnectionReleased ? "yes" : "no",
                                          idle.map { String(format: "%.0fs", $0) } ?? "unknown"))
            // This used to short-circuit on
            // `isConnectionReleased == false` alone, commented "still connected — nothing to do".
            // But that flag is the standing-connect BID, not the link. A reclaim already in flight
            // clears it while the peripheral is still .connecting, so a second concurrent caller
            // arriving ~100 ms later concludes the link is up, doses immediately, and the enact
            // fails with podNotConnected — losing that cycle's correction until the next one.
            // Two loop triggers that close together are routine: a carb save recomputes while
            // the bolus screen is open.
            //
            // Short-circuit only when the LINK is genuinely up; otherwise fall through to the read
            // ladder, which is the real readiness probe and already handles a connect in progress.
            if !manager.isConnectionReleased, manager.podLoanConnectionStateDescription == "connected" {
                self.lastPodLinkContact = self.now()
                completion(true)
                return
            }
            // NO RADIO STAND-DOWN, and nothing left to stand down. Earlier builds stood our own
            // G7 reader down so it could not occupy the radio during the pod's ladder; that was
            // retired for stranding the radio when the app suspended mid-ladder, and the reader
            // itself is gone. The CGM is now stock G7SensorKit riding
            // the Dexcom watch app's session; this app never drives the sensor radio, so the pod
            // ladder has no contender to yield to or hold off.
            // ONE liveness ceiling for the whole ladder (the port line's elegant-reclaim
            // design, taken without its geometry): every read below is completion-driven, so
            // a driver callback that never comes would strand the cycle with nothing to time
            // it out. The ceiling fails the ladder at budget+2 so the loop breathes; the
            // bounded read chain keeps polling harmlessly and its late completions no-op.
            var ladderFinished = false
            let finish: (Bool) -> Void = { ok in   // every caller is on `queue`
                guard !ladderFinished else { return }
                ladderFinished = true
                completion(ok)
            }
            self.schedule(after: 42, label: "reclaim-ladder-liveness") {
                guard !ladderFinished else { return }
                SportLog.event("loan", "E4: LIVENESS CEILING at 42s — a read is wedged past the driver's own timeout; failing the ladder so the loop breathes")
                finish(false)
            }
            SportLog.event("loan", "E4: reclaiming pod to dose (scan-adopt primary, #54)")
            manager.reclaimConnection()
            // Scan-adopt is the PRIMARY reclaim, not a mid-ladder fallback.
            // The bare pending-connect "wins" a reclaim
            // only ~2% of the time — an orphaned pod self-disconnects ~3 min after last contact,
            // and the gentle bid is a coin-flip against a self-disconnected pod (it caught one
            // 578s-idle pod, and missed 518s- and 259s-idle pods entirely). The scan-adopt
            // escalation carried ~98% of reclaims anyway, just 15s later — and that 15s was the
            // whole of the 30-40s reclaim the user felt.
            // Arm the fresh-central address scan up front; recreateCentral's poweredOn handler
            // re-connects the bare bid too, so both paths race from t=0. The read ladder below is
            // the success probe; the release path cancels an unfinished scan (cancelLoanScan).
            manager.podLoanEscalateReclaim()
            self.attemptReclaimRead(manager: manager, attempt: 0, completion: finish)
        }
    }

    /// Budget MATCHES the takeover ladder (14 reads / ~40s), and for the same reason.
    ///
    /// This was 8 reads / ~16s on the premise that "a bonded pod reconnect is seconds".
    /// That premise only holds for a WARM pod: an overnight run reclaiming every
    /// 5 minutes succeeded 84/84 — but in 2-4 reads, always well inside 16s. It
    /// silently validated the warm case only.
    ///
    /// The cold case is the opposite: with the pod's link
    /// released and then idle 8+ minutes it self-disconnects (~3 min after last
    /// contact), and every reclaim failed — 8/8 — while the TAKEOVER of the very same
    /// pod minutes earlier succeeded in 4 reads on its 40s budget. So the pod was
    /// reachable throughout; the reclaim was simply giving up first. Each failure left
    /// pump data unrefreshed, so pumpDataTooOld re-deadlocked the loop with the age
    /// climbing 15 -> 45 min.
    ///
    /// Radio cost is acceptable: the reclaim starts immediately after a reading, and
    /// the next G7 window is ~5 min out, so even a full 40s leaves ~4 min of margin —
    /// a pod exchange on every single cycle was already shown to cost 0% catch rate.
    private func attemptReclaimRead(manager: OmniPumpManager, attempt: Int, completion: @escaping (Bool) -> Void) {
        let maxAttempts = 14   // ~40s (14 × ~2s), same as the takeover ladder
        manager.podLoanReadStatus { [weak self] success in
            guard let self = self else { completion(false); return }
            self.queue.async {
                guard self.phase == .active else {
                    SportLog.event("loan", "E4: reclaim ABORTED — phase left .active (now \(self.phase.rawValue)). An in-flight dose is CANCELLED BY THE HAND-BACK, not by an unreachable pod — this is the 3x field failure (227 00:07:51, 228 00:18:44), all within ~1s of an End tap.")
                    completion(false); return
                }
                if success {
                    self.lastPodLinkContact = self.now()
                    SportLog.event("loan", "E4: pod reconnected for dose (after \(attempt + 1) read(s)) — state \(manager.podLoanConnectionStateDescription)")
                    completion(true)
                } else if attempt + 1 < maxAttempts {
                    // Per-attempt visibility. `podLoanReadStatus` returns a bare Bool, so
                    // 14 failed reads say only "it didn't work" — three separate theories
                    // (cold pod, suspension, spurious release) are indistinguishable
                    // against that silence. Report what the BLE layer
                    // actually sees each attempt: a peripheral stuck .disconnecting (2),
                    // one never reaching .connected (0/1), and a connected pod failing its
                    // status read are three different bugs that looked identical.
                    SportLog.event("loan", "E4: reclaim read \(attempt + 1)/\(maxAttempts) failed — pod BLE state \(manager.podLoanConnectionStateDescription), released=\(manager.isConnectionReleased)")
                    // Scan-adopt is armed UP FRONT in reclaimPodForDose, so the
                    // whole ladder rides the takeover-grade path from read 0 — no mid-ladder escalation.
                    // The fresh central's poweredOn handler races the bare bid and the address scan;
                    // these reads just poll for the winner. (Was: bare-connect first, escalate at read 6,
                    // which burned ~15s on the ~98% of reclaims the bare bid never won.)
                    self.schedule(after: 2, label: "reclaim-read") {
                        guard self.phase == .active else {
                            SportLog.event("loan", "E4: reclaim ABORTED mid-ladder — phase left .active (now \(self.phase.rawValue)); in-flight dose cancelled by the hand-back")
                            completion(false); return
                        }
                        self.attemptReclaimRead(manager: manager, attempt: attempt + 1, completion: completion)
                    }
                } else {
                    SportLog.event("loan", "E4: pod didn't reconnect after \(maxAttempts) reads (~40s) — dose skipped, pod runs baseline")
                    completion(false)
                }
            }
        }
    }

    /// Re-release the pod after a dose — but only after a SETTLE delay: cancelling a
    /// freshly-established connection poisons the BLE stack, and
    /// the connection has only been up for the dose (~seconds), so give it a moment to
    /// settle before releasing (mirrors the +90s deferred release at takeover).
    func releasePodAfterDose() {
        // The dose is done — close the in-flight window NOW, not after the 12 s settle,
        // so a deferred release that has been waiting on us can proceed promptly. Enqueued
        // rather than set inline because `doseWindowUntil` is queue-confined and this is
        // called from the enactor's own queue.
        // Cancel before re-arming, like every other one-shot timer here. A cycle can reclaim
        // twice — once to refresh stale pump data, then again to dose — and without this each
        // call stacks its own independent 12 s release. A superseded one whose guards happen to
        // pass (a new reclaim reconnected inside the window) would drop the BLE link out from
        // under a live dose. Both timers belong to the same epoch, so `epochScoped` cannot see
        // this; only cancellation prevents it.
        //
        // Armed on the controller's queue, where the work-item handle and `epoch` both live —
        // this is called from the enactor's queue.
        queue.async { [weak self] in
            guard let self = self else { return }
            self.doseWindowUntil = nil
            self.postDoseReleaseWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.performPostDoseRelease() }
            self.postDoseReleaseWork = work
            // epochScoped: the only timer here that ACTS on the pod link across a window long
            // enough to outlive its loan. `.active` alone is not enough, because a LATER loan is
            // also `.active` — a hand-back and re-grant inside 12 s would let this tear down the
            // link belonging to the loan that now owns the pod.
            self.schedule(after: 12, label: "post-dose-release", epochScoped: true, execute: work)
        }
    }

    /// Runs on `queue`: armed inside a `queue.async` block and fired by the seam, which
    /// dispatches there. No `dispatchPrecondition` — tests drive timer bodies directly, and
    /// this body needs to stay reachable from them.
    private func performPostDoseRelease() {
        postDoseReleaseWork = nil
        // Unconditional — see the takeover-release note above for why the defaults-key gate
        // had to go (absent key = false = hold the link forever on a fresh install, the arm
        // the toggle experiment disproved).
        guard self.phase == .active, let manager = self.pumpManager,
              manager.isConnectionReleased == false else { return }
        // Capture the peripheral BEFORE and AFTER the cancel. The poisoning
        // signature is a peripheral left in .disconnecting, which is otherwise only
        // inferable minutes later from a central recreate. Cancelling a link the pod
        // has ALREADY dropped is the suspected trigger, so "what state were we in when
        // we cancelled" is the load-bearing fact — and a state that is not .connected
        // going in means there was nothing to cancel.
        let before = manager.podLoanConnectionStateDescription
        // ORPHAN, not release — same as the deferred takeover release: dropping the link
        // keeps the watch as controller, so the running temp's record must NOT close here.
        manager.podLoanOrphanConnection()
        lastPodLinkContact = now()
        schedule(after: 3, label: "post-dose-verify") { [weak self] in
            guard let self = self, let manager = self.pumpManager else { return }
            let after = manager.podLoanConnectionStateDescription
            SportLog.event("loan", "E4: pod re-released after dose (+12s settle) — state \(before) -> \(after) (+3s)\(after.hasPrefix("DISCONNECTING") ? " ** WEDGED — this is the poisoning signature **" : "")")
        }
    }

    // auditDoseCount + the addPumpEvents seed doc DELETED: the store holds no doses.
    // Seed mechanics live in SessionInsulinLedger; DESIGN_LOAN_ADDPUMPEVENTS.md is historical.
    private func ingestGrantHistory(_ grant: LoanGrant) {
        // The watch DoseStore is CONFIG ONLY. It holds no dose data, and nothing here
        // maintains a second book — the watch store is `isReadOnly`, so its saves silently no-op
        // and any dose written to it is invisible. The LEDGER is the book: born per epoch, so a
        // new ledger IS the wipe and there is nothing to leak, seeded from the grant split.
        //
        // FINISHED history seeds as fixed records; a dose still DELIVERING at takeover seeds
        // LIVE instead — `ledgerSeed(finished:live:)` takes both. The live one carries no settled
        // delivered amount (it logs `del=nil`) because the grant's podState blob owns it and the
        // pump manager reports it as a mutable dose, so IOB tracks delivery in real time. It is
        // seeded, not omitted.
        let seedReconciliation = self.now()
        let (entries, liveDoses) = grant.seedDoseEntries(finishedBy: seedReconciliation)
        loopManager.ledgerSeed(finished: entries, live: liveDoses)
        // The pump-recency clock is owned by the manager now (it used to advance as a side
        // effect of seeding the store). Stamp the takeover instant so pumpDataTooOld cannot
        // deadlock the first cycle; the takeover's own status read re-stamps it seconds later.
        loopManager.notePumpDataReceived(at: seedReconciliation)
        let grossImpliedSum = entries.reduce(0.0) { $0 + $1.programmedUnits }
        let liveNote = liveDoses.isEmpty ? "" :
            String(format: "; %d live — delivery tracked from pod state (#72), latest ends +%.0fm",
                   liveDoses.count, (liveDoses.map { $0.endDate }.max()!.timeIntervalSince(seedReconciliation)) / 60)
        SportLog.event("loan", String(format: "insulin books rebuilt from grant — %d records (ledger seed, R35: %d finished%@) · grossImpliedΣ=%.2fU",
                                       entries.count + liveDoses.count, entries.count, liveNote, grossImpliedSum))
        loopManager.invalidateInsulinEffect()
        // SEED-IN IOB anchor — from the LEDGER, the only book. Primes the glance/HUD so
        // IOB shows at takeover instead of blank until the first cycle, and records the anchors
        // for [iob-diff] (phone vs seed vs cycle1).
        loopManager.primeIOBFromLedger(at: seedReconciliation) { iob in
            guard let iob = iob else {
                SportLog.event("loan", "SEED-IN IOB unavailable (no schedule yet) — [iob-diff] anchors skipped this loan")
                return
            }
            SportLog.event("loan", String(format: "SEED-IN IOB=%.2fU @ takeover (%d seeded doses: %d finished%@)",
                                          iob, entries.count + liveDoses.count, entries.count, liveNote))
            self.loopManager.recordTakeoverIOBAnchors(
                phone: grant.predictionSnapshot?.iobUnits,
                phoneDate: grant.predictionSnapshot?.iobDate,
                seed: iob,
                at: seedReconciliation)
            self.loopManager.dumpIOBDecomp("SEED-IN", at: seedReconciliation)
        }
        ingestGrantCarbs(grant)
        ingestGrantGlucose(grant)
    }

    /// Make the watch carb store an authoritative MIRROR of the phone's at takeover:
    /// WIPE it, then replace with the grant's carbs via `setSyncCarbObjects` (which
    /// `purgeCachedCarbObjectsUnconditionally` before inserting). This is the phantom-COB fix.
    /// The previous `syncCarbObjects` UPSERTED on (syncIdentifier, provenanceIdentifier) and never
    /// deleted absent entries, so a prior-epoch residual — or a carb the user DELETED on the phone
    /// (→ empty grant, which used to early-return and wipe nothing) — survived on the watch,
    /// absorbing and pushing dosing until it aged past the 24 h cache. With a true replace, an empty
    /// grant wipes to zero, so phone-side deletions propagate. Safe because carbs are ONE-WAY
    /// phone→watch in v1: watch-entered carbs are not returned (see `loanDidRecordCarbs`), so the
    /// watch never legitimately holds a carb the phone doesn't. Full bidirectional sync is future work.
    private func ingestGrantCarbs(_ grant: LoanGrant) {
        let phoneCOB = grant.predictionSnapshot?.cobGrams
        let phoneCOBStr = phoneCOB.map { String(format: "%.1f", $0) } ?? "n/a"
        // How stale the phone's COB is. The comparison below is meaningless without it: carbs
        // decay, so a 98-second-old phone COB is legitimately a couple of grams under a fresh one.
        let snapshotAge = grant.predictionSnapshot.map { self.now().timeIntervalSince($0.snapshotAt) }
        let carbs = grant.carbHistory ?? []
        let objects: [SyncCarbObject] = carbs.map { c in
            SyncCarbObject(
                absorptionTime: c.absorptionTime,
                createdByCurrentApp: false,
                foodType: c.foodType,
                grams: c.grams,
                startDate: c.startDate,
                uuid: nil,
                provenanceIdentifier: c.provenanceIdentifier,
                syncIdentifier: c.syncIdentifier,
                syncVersion: c.syncVersion,
                userCreatedDate: c.userCreatedDate,
                userUpdatedDate: c.userUpdatedDate,
                userDeletedDate: nil,
                operation: .create,
                addedDate: nil,
                supercededDate: nil)
        }
        let seededGrams = carbs.reduce(0.0) { $0 + $1.grams }
        let source = (grant.carbHistory == nil) ? "absent(old phone)"
                   : (carbs.isEmpty ? "empty(deleted on phone)→wipe" : "\(objects.count) entr\(objects.count == 1 ? "y" : "ies")")
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let manifest = carbs.isEmpty ? "—" : carbs.map { c in
            String(format: "%.1fg@%@ sync=%@ prov=%@", c.grams, tf.string(from: c.startDate),
                   c.syncIdentifier ?? "nil", String(c.provenanceIdentifier.prefix(12)))
        }.joined(separator: " | ")
        // WIPE-then-replace: setSyncCarbObjects purges unconditionally first, so an EMPTY set is a
        // clean wipe (deletions propagate) and a non-empty set fully replaces (no residual/dup).
        loopManager.carbStore.setSyncCarbObjects(objects) { [weak self] error in
            if let error = error {
                os_log("Grant carb replace failed: %{public}@", log: OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanWatchController"), type: .error, String(describing: error))
                return
            }
            // [cob-diff]: did the wipe-then-replace leave the watch holding EXACTLY the
            // phone's carbs?
            //
            // That question is answered by the ENTRY SET, not by comparing computed COB. The
            // earlier check inferred a residual from Δ(post−phone) > 2 g, which is a category
            // error.
            //
            // Both devices compute COB through the SAME dynamic API, with effect velocities
            // passed identically (WatchLoopManager :703, LoopDataManager :1142) — this is NOT a
            // static-vs-dynamic split between platforms. The divergence is observation
            // FRESHNESS: dynamic absorption falls back, per entry, to the modelled curve while
            // that entry has no observed timeline yet (CarbStatus :56). This read happens
            // immediately after the replace, before any cycle has extended the watch's
            // insulinCounteractionEffects over the newly-seeded carbs, so they take that
            // fallback; the phone's cached figure is from a completed cycle that has observation
            // behind it. The phone would print the same number if read at this instant.
            //
            // Field evidence across eight replaces: Δ ≈ 0 with the newest carb 1 min old
            // (nothing absorbed yet, both agree) and 90-148 min old (both ~zero), and +4.3 to
            // +7.3 g at 3, 5, 8, 21 and 51 min — perfect separation on absorption phase, none on
            // entry count or snapshot age. Every one was reported as "wipe failed?".
            //
            // So read the store back and compare identities. `manifest` above is what we SENT,
            // which proves nothing about what landed.
            guard let self = self else { return }
            let expectedIDs = Set(carbs.compactMap { $0.syncIdentifier })
            let readFrom = (carbs.map(\.startDate).min() ?? self.now()).addingTimeInterval(-3600)
            self.loopManager.carbStore.getCarbEntries(start: readFrom) { result in
                var verdict: String
                switch result {
                case .failure(let e):
                    // Unverified is NOT the same as clean — say so rather than printing a
                    // silent pass.
                    verdict = " ⚠ wipe UNVERIFIED (read-back failed: \(e))"
                case .success(let stored):
                    let storedIDs = Set(stored.compactMap { $0.syncIdentifier })
                    let residual = storedIDs.subtracting(expectedIDs)
                    let missing = expectedIDs.subtracting(storedIDs)
                    let dupes = stored.count - storedIDs.count
                    if residual.isEmpty && missing.isEmpty && dupes == 0 {
                        verdict = " · wipe verified \(stored.count)/\(expectedIDs.count)"
                    } else {
                        verdict = String(format: " ⚠ WIPE FAILED — %d residual, %d missing, %d duplicate",
                                         residual.count, missing.count, dupes)
                    }
                }
                self.loopManager.glanceCarbsOnBoard { cob in
                    let postV = cob ?? 0
                    let vsPhone = phoneCOB.map { postV - $0 }
                    // Δ stays in the line — it is worth seeing — but as what it is: the two sides
                    // reading the same dynamic model at different observation maturity, which
                    // grows with actively-absorbing carbs and says nothing about the wipe.
                    let ageStr = snapshotAge.map { "\(Int($0.rounded()))s" } ?? "n/a"
                    SportLog.event("cob-diff", String(format: "REPLACE %@ · phoneCOB=%@ g (snapshot age %@) · watch COB(post)=%.2f g · replaced %.0f g · Δ(post−phone)=%@ g (observation freshness, not a model split)%@ · [%@]",
                                                       source, phoneCOBStr, ageStr, postV, seededGrams,
                                                       vsPhone.map { String(format: "%+.2f", $0) } ?? "—",
                                                       verdict, manifest))
                }
            }
        }
        // Carb effect is cached; force a recompute so the replaced COB reaches the first
        // prediction instead of waiting for a CGM-triggered invalidation.
        loopManager.invalidateCarbEffect()
    }

    /// Seed ~3 h of the phone's glucose so the watch's momentum + retrospective correction
    /// compute from the FIRST post-takeover cycle. The watch GlucoseStore is otherwise empty
    /// until live G7 reads accumulate — momentum was blind for ~15 min and RC never warmed, so
    /// the watch dosed on a prediction that ignored glucose history. Reuses the phone's
    /// syncIdentifier so re-grants dedup (GlucoseStore keys on provenance + syncIdentifier).
    /// Seeded samples are pre-takeover, and the watch's G7 path reads one current EGV per
    /// connection (no backfill), so at most a SINGLE boundary sample can duplicate — phone and
    /// watch derive different G7 syncIds for the same reading, so dedup can't match it — which is
    /// harmless (momentum is duplicate-insensitive; counteraction skips sub-4-min pairs). Pairs
    /// with the RC-freeze fix in WatchLoopManager (both required for RC to produce an effect).
    private func ingestGrantGlucose(_ grant: LoanGrant) {
        guard let records = grant.glucoseHistory, !records.isEmpty else { return }
        let mgdl = HKUnit.milligramsPerDeciliter
        let mgdlPerMin = mgdl.unitDivided(by: .minute())
        let samples: [NewGlucoseSample] = records.map { r in
            NewGlucoseSample(
                date: r.startDate,
                quantity: HKQuantity(unit: mgdl, doubleValue: r.valueMgdl),
                condition: nil,
                trend: nil,
                trendRate: r.trendRateMgdlPerMin.map { HKQuantity(unit: mgdlPerMin, doubleValue: $0) },
                isDisplayOnly: r.isDisplayOnly,
                wasUserEntered: r.wasUserEntered,
                syncIdentifier: r.syncIdentifier ?? "loanv2-glucose-\(Int(r.startDate.timeIntervalSince1970 * 1000))")
        }
        // Stamp the phone as the source BEFORE storing, and regardless of what dedup keeps — the
        // same OPTION C discipline the direct-G7 path uses (see GlanceData.directG7At). The
        // question the glance's provenance line answers is "who last delivered a reading to us",
        // not "whose copy won the store", and on a re-takeover every seeded sample can be a
        // duplicate while the phone has still just handed us its glucose history.
        loopManager.notePhoneGlucoseDelivered()
        loopManager.glucoseStore.addGlucoseSamples(samples) { result in
            switch result {
            case .success(let stored):
                // Same "INGEST src=" key as the direct-G7 and phone-relay paths, so
                // one grep counts every route glucose can enter this store by. Without it,
                // scoring CGM coverage meant grepping a BLE-layer line that only fires for live
                // notification values and silently misses backfill batches.
                SportLog.event("glucose", "INGEST src=grant-seed stored=\(stored.count)/\(samples.count) · loan takeover warm-up")
                SportLog.event("loan", "seeded \(stored.count) glucose sample\(stored.count == 1 ? "" : "s") from the phone (momentum/RC warm-up)")
                self.loopManager.invalidateGlucoseDerivedEffects()
            case .failure(let error):
                os_log("Grant glucose ingest failed: %{public}@", log: OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanWatchController"), type: .error, String(describing: error))
            }
        }
    }

    /// INSTRUMENTATION ONLY: stash the phone's grant prediction snapshot on the watch loop
    /// manager (so `[predict-diff]` can subtract it) and echo it to the log at takeover, next to the
    /// SEED-IN IOB/COB lines. No-op when the grant carries no snapshot (older phone / stale caches).
    private func ingestPredictionSnapshot(_ grant: LoanGrant) {
        loopManager.stashPhonePredictionSnapshot(grant.predictionSnapshot)
        guard let s = grant.predictionSnapshot else { return }
        let now = self.now()
        SportLog.event("snapshot", String(format:
            "RX phone@grant — eventual %.0f start %.0f@%.0fs IOB %.2f@%.0fs COB %.0f · impact mom %+.0f ins %+.0f carb %+.0f RC %+.0f · momPts %d rcDisc %d · snapAge %.0fs",
            s.eventualMgdl, s.startGlucoseMgdl, now.timeIntervalSince(s.startGlucoseDate),
            s.iobUnits, now.timeIntervalSince(s.iobDate), s.cobGrams,
            s.impactMomentumMgdl, s.impactInsulinMgdl, s.impactCarbMgdl, s.impactRCMgdl,
            s.momentumPointCount, s.rcDiscrepancyCount, now.timeIntervalSince(s.snapshotAt)))
    }

    /// Double-seed detector: is the grant's running-temp `boundaryRecord` ALSO present
    /// inside `doseHistory` (same rate, overlapping window)? If so, the running temp is
    /// seeded twice at takeover → its insulin is double-counted in watch IOB (~0.3U bump).
    private static func boundaryDuplicatesHistory(_ grant: LoanGrant) -> Bool {
        guard let b = grant.boundaryRecord, let bRate = b.unitsPerHour, let bEnd = b.endDate else { return false }
        return grant.doseHistory.contains { r in
            switch r.kind {
            case .tempBasal, .suspend, .boundaryTruncation:
                guard let rRate = r.unitsPerHour, let rEnd = r.endDate else { return false }
                return abs(rRate - bRate) < 0.0001 && r.startDate < bEnd && rEnd > b.startDate
            default:
                return false
            }
        }
    }

    /// Titles for seeded pump events (record→DoseEntry lives in the shared
    /// LoanProtocolV2 `seedDoseEntry`/`seedDoseEntries` so the watch and the tests agree).
    private static func pumpEventTitle(for type: DoseType) -> String {
        switch type {
        case .bolus:     return "Bolus"
        case .tempBasal: return "Temp Basal"
        case .basal:     return "Basal"
        case .suspend:   return "Suspend"
        case .resume:    return "Resume"
        }
    }

    // MARK: - Hand-back (§3.2 HANDING_BACK)

    /// Request a hand-back WITHOUT giving up control. Phase stays .active —
    /// dosing, boluses, and the G7 loop all continue; the journal drains via interim
    /// offers. When the drain is fully acked, finalizeHandback() stops dosing and
    /// sends the final offer. Cancelable until then.
    func beginHandback() {
        #if targetEnvironment(simulator)
        if defaults.bool(forKey: "sim.fakeLoanFlow") { simDriveHandback(); return }
        #endif
        queue.async {
            guard self.phase == .active, self.pumpManager != nil else { return }
            guard !self.handbackRequested else { return }
            self.handbackRequested = true
            self.handbackResendCount = 0
            self.handbackSawUnreachable = false
            self.handbackSawUrgentSendError = false
            // Bound the wait for the phone's ack. Pre-scheduled alert fires from a suspended
            // app; the resend loop resumes Sport Mode on the watch at the same deadline. Covers
            // both the interim-drain path below and the legacy single-phase finalize.
            self.handbackDeadline = self.now().addingTimeInterval(HandbackStuckAlert.interval)
            self.handbackStartedAt = self.now()
            HandbackStuckAlert.arm()
            guard self.phoneSupportsInterimHandback else {
                // Skew gate: an old phone treats ANY offer as final — go
                // straight to the legacy single-phase hand-back (stop, then offer).
                SportLog.event("loan", "HAND-BACK started (legacy single-phase — phone predates interim drains)")
                self.finalizeHandback()
                return
            }
            SportLog.event("loan", "HAND-BACK requested — draining \(self.journal.unackedEvents().count) events; still in control (WS1)")
            self.sendHandbackOffer(freshened: false, recovered: false)
        }
    }

    /// Abort a requested hand-back while still in the drain (phase .active).
    /// After finalize the pod has stopped taking watch commands — too late to cancel.
    func cancelHandback() {
        queue.async {
            guard self.phase == .active, self.handbackRequested else { return }
            self.handbackRequested = false
            self.resendWorkItem?.cancel()
            self.handbackDeadline = nil
            self.handbackStartedAt = nil
            HandbackStuckAlert.disarm()   // Aborted before the budget — no stuck alert
            SportLog.event("loan", "HAND-BACK cancelled — Sport Mode continues")
        }
    }

    /// The phone never acked the hand-back within the budget (unreachable, or silently
    /// dropping offers). We stayed the pod's SOLE OWNER throughout — interim: still dosing;
    /// final: dosing stopped but the pod is STILL HELD (release only on the final ack) — so
    /// recovery is clean: resume Sport Mode on the watch in the SAME loop mode (never auto-open
    /// or auto-close). Unacked records stay in the journal and re-offer on a
    /// later hand-back (the phone dedups by event ID); the odometer reconciles the totals then.
    /// The pre-scheduled HandbackStuckAlert delivers the wrist notification (even from a suspended
    /// app, in which case this state restore runs on the next wake).
    private func handbackTimedOut() {
        resendWorkItem?.cancel()
        handbackDeadline = nil
        handbackStartedAt = nil
        let wasFinal = (phase == .handingBack)
        let wedge = HandbackWedge.classify(resendCount: handbackResendCount,
                                           sawUnreachable: handbackSawUnreachable,
                                           reachableNow: isPhoneReachable(),
                                           sendsErrored: handbackSawUrgentSendError)
        let wedgeSuffix: String
        switch wedge {
        case .sessionReestablishing:
            wedgeSuffix = " · ** \(handbackResendCount) offers, phone reachable, zero acks — but the sends themselves ERRORED: session re-establishing (#113 variant B), usually self-heals in 1-2 min **"
        case .oneWay:
            wedgeSuffix = " · ** \(handbackResendCount) offers, phone REACHABLE throughout, zero acks — transport wedge (#113 variant A); restarting the WATCH app is the known recovery **"
        case .none:
            wedgeSuffix = ""
        }
        handbackRequested = false
        finalOfferSent = false
        if wasFinal, let manager = pumpManager {
            // finalize nilled loopManager.pumpManager but self.pumpManager still HOLDS the pod —
            // re-point the loop and re-loop, no re-takeover needed.
            phase = .active
            loopManager.pumpManager = manager
            loopManager.loanDoseRecorder = self
            onLoanActiveChanged?(true)
            SportLog.event("loan", "HAND-BACK timed out (final, \(Int(HandbackStuckAlert.interval))s) — iPhone never acked; resumed Sport Mode on the watch (still holding the pod)\(wedgeSuffix)")
            loopManager.checkPumpDataAndLoop()   // re-establish a temp this cycle
        } else {
            // Interim hang: never stopped dosing; phase already .active. Just abort the drain.
            SportLog.event("loan", "HAND-BACK timed out (interim, \(Int(HandbackStuckAlert.interval))s) — iPhone never acked; Sport Mode continues on the watch\(wedgeSuffix)")
        }
        switch wedge {
        case .sessionReestablishing:
            // No alert: this variant resolves on its own, and HandbackStuckAlert has already
            // told the user End did not complete. A second, softer notice on top of it added
            // words without adding an action.
            SportLog.event("loan", "hand-back wedge variant B (session re-establishing) — no alert; expected to clear on its own")
        case .oneWay:
            // Reachability is read live at the classify site, so "is reachable" is observed.
            // The remedy no longer names ONE device: this was written when the wedge was
            // believed to be watch-side only, and 2026-08-15 produced a PHONE-side instance
            // where restarting the watch app did nothing and only reinstalling the phone app
            // cleared it. The classifier cannot tell the two apart, so the copy must not either.
            issueProtocolAlert(title: "End Not Confirmed",
                               body: "Your iPhone is reachable but hasn't confirmed. Reopening Loop on both devices usually clears this.")
        case .none:
            break
        }
        // HandbackStuckAlert is intentionally NOT disarmed here — its pre-scheduled notification
        // is the user's signal that End didn't complete. It self-expires; a later successful
        // hand-back re-arms a fresh one.
    }

    /// The drain is fully acked while still active — NOW stop dosing, close the
    /// loop-temp record, freshen the odometer, and send the FINAL (released) offer.
    /// The pod's BLE link is still held until the final ack (kept from v1: release
    /// ONLY after the phone has committed everything).
    private func finalizeHandback() {
        // A stale INTERIM resend timer (armed 0-15s ago) must
        // not fire during the ~3-12s of temp-cancel + status reads below — once phase
        // flips it would send released=true prematurely and the phone would reclaim
        // while this device is still commanding the pod.
        resendWorkItem?.cancel()
        finalOfferSent = false   // the close path waits for the real final offer
        guard let manager = pumpManager else {
            handbackRequested = false
            phase = .handingBack
            finalOfferSent = true
            sendHandbackOffer(freshened: false, recovered: false)
            return
        }
        handbackRequested = false
        phase = .handingBack
        SportLog.event("loan", "drain complete — finalizing hand-back (loop dosing stops now)")
        loopManager.pumpManager = nil  // no dosing from here

        // Cancel the leftover LOOP temp — but a running bounded manual
        // suspend is preserved; the pod auto-resumes at its expiry.
        let suspendActive = (self.manualSuspendEnd ?? .distantPast) > self.now()
        // NO PROGRAM CROSSES THE BOUNDARY — the automatic
        // controller is standing down, so its automatic temp goes with it and the pod reverts
        // to the user's own schedule. This mirrors stock's own off-cycle idiom exactly:
        // LoopDataManager.cancelActiveTempBasal enacts a bare `.cancel` outside loop() for
        // automaticDosingDisabled / unreliableCGMData / maximumBasalRateChanged. Stock never
        // SETS a rate off-cycle (that needs a fresh prediction from fresh CGM data) but it
        // always allows CANCELLING, because cancelling can only move toward less intervention.
        // So the phone does NOT need an off-cycle dosing trigger here; its next reading, ≤5 min
        // away, sets the new rate, and until then the pod runs the user's baseline.
        //
        // NEVER guard this on `if case .tempBasal = manager.status.basalDeliveryState`.
        // The pod's BLE link is orphaned between doses, so by hand-back that state reads nil
        // even though the pod is still delivering — the cancel then never fires at all, and
        // every loan's last temp keeps running after the pod goes home.
        // Ask the loop manager instead: it falls back to the temp it last enacted, until that
        // temp's programmed end.
        let runningTemp = self.loopManager.runningTempBasalForHandback()
        // The CANCEL IS THE PHONE'S JOB, because the watch cannot do it. Between
        // dose windows the watch has deliberately released the pod's BLE link, so the command
        // fails in about a millisecond with podNotConnected — there is no round-trip to fail,
        // there is no link. The same missing link is why the odometer freshen below also fails
        // and the audit prints `fresh=N`: one cause, both symptoms.
        //
        // The phone is by definition talking to the pod at this moment, and its reclaim
        // round-trip lands within seconds, so it cancels instead (see
        // PodLoanPhoneController.finishPendingHandbackAudit). The pod keeps delivering OUR last
        // temp in the meantime, which is the better failure mode anyway: continuous therapy
        // across the boundary rather than a gap. The principle is unchanged — no automatic
        // program outlives the controller that set it — only the device that enforces it moved
        // to the one that can.
        //
        // The ledger truncation stays: it is watch-LOCAL bookkeeping, and if a failed
        // offer resumes this session the ledger must not carry a phantom full-span temp.
        if runningTemp != nil, !suspendActive {
            let cancelAt = self.now()
            self.loopManager.ledgerRecordEnact(DoseEntry(
                type: .tempBasal, startDate: cancelAt, endDate: cancelAt,
                value: 0, unit: .unitsPerHour))
            SportLog.event("loan", String(format: "hand-back: our temp (%.2f U/hr until %@) stays live until the phone cancels it on reclaim (R33, phone-enforced)",
                                          runningTemp?.unitsPerHour ?? 0,
                                          runningTemp.map { ISO8601DateFormatter().string(from: $0.endDate) } ?? "—"))
        }

        do {
            // Freshen the odometer (one retry on a zero delta), then offer. Best-effort:
            // when the link is down this fails instantly and the offer carries freshenSucceeded
            // = false, which is now merely a note — the AUTHORITATIVE end-of-loan reading is the
            // one the phone takes on its own reclaim round-trip.
            manager.podLoanReadStatus { first in
                let finalize: (Bool) -> Void = { freshened in
                    self.queue.async {
                        self.finalOfferSent = true
                        self.sendHandbackOffer(freshened: freshened, recovered: false)
                    }
                }
                let delivered = manager.podLoanInsulinDelivered
                if first, delivered != nil, delivered == self.deliveredAtTakeover {
                    manager.podLoanReadStatus { second in finalize(second) }
                } else {
                    finalize(first)
                }
            }
        }
    }

    private func sendHandbackOffer(freshened: Bool, recovered: Bool) {
        guard let epoch = epoch ?? journal.activeEpoch else { return }
        var odometer: LoanOdometerSnapshot?
        if let start = deliveredAtTakeover,
           let latest = pumpManager?.podLoanInsulinDelivered ?? revokeCapturedDelivered {
            // asOf makes the snapshot a checkpoint candidate for an INTERIM drain; the phone
            // never checkpoints a FINAL offer's snapshot (it is the endpoint under audit).
            // The revoke captures are the fallback for the torn-down-pump path (e181).
            odometer = LoanOdometerSnapshot(deliveredAtStart: start, deliveredLatest: latest, freshenSucceeded: freshened,
                                            asOf: pumpManager?.podLoanInsulinDeliveredAt ?? revokeCapturedDeliveredAt)
        }
        // Verify rounds 1-3: IN-FLIGHT (mint→classification) and chase-pending events
        // stay OUT of interim offers — once the phone commits one, a later annul or
        // REFUTED verdict can't unwind the store write (tombstones only filter staged
        // events). They ride a later offer once classified; the final offer carries
        // everything (chases resolve or stand conservative before finalize).
        var offerEvents = journal.unackedEvents()
        if phase == .active {
            offerEvents.removeAll { inFlightEventIDs.contains($0.id) }
            if let pending = pendingUncertainEventID {
                offerEvents.removeAll { $0.id == pending }
            }
        }
        let offer = HandbackOffer(
            epoch: epoch,
            handedBackAt: self.now(),
            finalStatus: pumpManager.map { _ in currentPodStatus() },
            odometer: odometer,
            events: offerEvents,
            tombstones: journal.pendingTombstones(),
            recovered: recovered,
            released: phase != .active,   // interim while still dosing; final after finalize
            // The phone inherits the wrist's loop mode on
            // the way back, mirroring the grant's outbound inheritance. Read through the
            // NON-BLOCKING mirror: this runs on `queue`, and `closedLoopEnabled` would sync
            // onto dataAccessQueue — the deadlock direction.
            // RECOVERED offers send nil — no authority (ported from next-dev, field 2026-08-25
            // e221): a relaunch-recovered drain reads a freshly-booted manager whose flag is a
            // boot default, not the wrist's real mode; e221's recovered offer overwrote the
            // user's captured CLOSED with open, and the phone resumed open-loop after the watch
            // died. nil already means exactly the right thing at the phone: keep the captured
            // pre-loan value.
            watchClosedLoopEnabled: recovered ? nil : loopManager.closedLoopEnabledNonBlocking,
            // R40 reunion identity: present only while a SEIZED loan is live — the phone
            // retro-acknowledges on match; an old phone ignores it (stale-drain, safe).
            seizeToken: defaults.string(forKey: DormantKeys.activeToken).flatMap(UUID.init(uuidString:)),
            // Same benign-snapshot read as the mode above: "roughly when did the wrist last
            // loop" for the phone's recency seed, not a sync point. (Safe on recovered drains
            // without gating: a freshly-booted manager's clock is nil, and the phone's seed is
            // forward-only either way.)
            lastLoopCompleted: loopManager.lastLoopCompleted,
            // Hands the snooze anchor back, so the phone resuming its own warnings does not
            // repeat within minutes what the user just read on their wrist. Same non-blocking
            // mirror discipline as the loop mode above — this is built on `queue`.
            lastLowBGWarningAt: loopManager.lastLowBGWarningTimeNonBlocking)
        if offer.released == true, finalOfferSentAt == nil { finalOfferSentAt = self.now() }
        handbackResendCount += 1
        // Self-documenting limbo (a wait can run to 97 silent minutes of 15s resends):
        // log the attempt count each minute so the wait is visible in the log.
        if handbackResendCount == 1 || handbackResendCount % 4 == 0 {
            SportLog.event("loan", "hand-back offer attempt \(handbackResendCount) — waiting for iPhone ack")
        }
        // Say WHY the wait is happening. End tapped with the phone unreachable otherwise shows
        // nothing but "ending…" for minutes, even though `reachable false` is on every send
        // line in the log the whole time: the
        // signal exists, it was just never surfaced. Log transitions here; the glance note is
        // driven off DebugSnapshot.phoneReachable. NOTE we do NOT abort on unreachable —
        // reachability flaps, and the queued offer lands the moment the phone returns (acking
        // within tens of milliseconds once reachable). Fast feedback, slow abort.
        let reachableNow = isPhoneReachable()
        if !reachableNow { handbackSawUnreachable = true }
        if lastHandbackReachable != reachableNow {
            SportLog.event("loan", reachableNow
                ? "hand-back: iPhone reachable — offer should ack shortly"
                : "hand-back: iPhone UNREACHABLE — offer queued, will land when it returns (still looping)")
            lastHandbackReachable = reachableNow
        }
        sendMessage(.handbackOffer(offer))

        // Resend until ack (rows 9/10): same event IDs every retry by construction.
        resendWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Give up after the budget and resume Sport Mode on the watch (we stayed the
            // pod's sole owner throughout). Only the LIVE hand-back (deadline set) — a
            // recovered/revoke drain has no local loan to resume, so it keeps resending.
            if let deadline = self.handbackDeadline, self.now() >= deadline,
               self.phase == .handingBack || (self.phase == .active && self.handbackRequested) {
                self.handbackTimedOut()
                return
            }
            if self.phase == .handingBack || self.phase == .revoked || self.phase == .recoveredDrain
                || (self.phase == .active && self.handbackRequested) {   // interim drain
                self.sendHandbackOffer(freshened: freshened, recovered: recovered)
            }
        }
        resendWorkItem = work
        schedule(after: 15, label: "handback-resend", execute: work)
    }

    private func handleAck(_ ack: HandbackAck) {
        // This was a silent `return`. An ack for the wrong epoch is a real and expected event
        // (a stale redelivery), but it is ALSO what a mis-paired session would look like, so it
        // must be distinguishable from "no ack arrived" in the log rather than inferred.
        guard let current = epoch ?? journal.activeEpoch, ack.epoch == current else {
            SportLog.event("loan", "ack IGNORED ev=\(ack.epoch) — ours ev=\(epoch.map(String.init) ?? "nil") journal ev=\(journal.activeEpoch.map(String.init) ?? "nil"); stale redelivery or epoch mismatch")
            return
        }
        // The phone acks MAX-seq, but withholding (in-flight /
        // chase-pending events) creates seq GAPS a max-seq cursor can't represent —
        // an ack covering a later carb would skip a withheld command forever. The cap
        // itself lives in the journal (see `applyAck(committedCursor:withholding:)`);
        // this side just says WHICH
        // events are withheld, which is the only part the controller actually knows.
        var withheld = inFlightEventIDs
        if let pending = pendingUncertainEventID { withheld.insert(pending) }
        journal.applyAck(committedCursor: ack.committedCursor, withholding: withheld)
        guard journal.unackedEvents().isEmpty else { return }

        // The drain completed while STILL DOSING — now stop the loop's pod,
        // close records, and send the final (released) offer. The close below runs
        // on that final offer's ack. Never finalize while a verdict
        // chase is live (its withheld event also keeps unackedEvents non-empty —
        // this is the explicit belt to that suspender).
        if phase == .active && handbackRequested {
            // Belt: no finalize while ANY command is unclassified (in-flight
            // OR chase-pending) — the withheld-seq cursor cap above is the suspender.
            guard pendingUncertainEventID == nil, inFlightEventIDs.isEmpty else { return }
            finalizeHandback()
            return
        }
        guard phase == .handingBack || phase == .revoked || phase == .recoveredDrain else { return }
        // During finalize's pod-ops window (phase flipped, journal
        // empty, final offer NOT yet sent) a duplicate interim ack must not close
        // the loan — the phone would never receive released=true and strand .loaned.
        if phase == .handingBack && !finalOfferSent { return }

        // Fully drained: release the pod ONLY now (kept from v1).
        resendWorkItem?.cancel()
        chaseWorkItem?.cancel()
        // Liveness: chase/in-flight residue must not cross loan
        // boundaries — the finalize gate reads pendingUncertainEventID, and a stale
        // flag from THIS loan would block the NEXT loan's drain indefinitely.
        pendingUncertainEventID = nil
        inFlightEventIDs = []
        // Splits "Reclaiming…" into its two candidate components: how long the watch waited
        // for PERMISSION to release (the phone's ack), versus how long the release itself took.
        // The ack only rides WCSession's immediate channel while the watch is reachable, so a
        // wrist dropped after End pushes it into the queued path.
        let ackWait = finalOfferSentAt.map { self.now().timeIntervalSince($0) }
        SportLog.event("loan", String(format: "ack RECEIVED %@ after the final offer — releasing the pod now",
                                      ackWait.map { String(format: "+%.1fs", $0) } ?? "(no offer stamp)"))
        let releaseBegan = self.now()
        teardownPump()
        SportLog.event("loan", String(format: "pod BLE teardown returned in %.2fs — the phone's standing connect can land from here",
                                      self.now().timeIntervalSince(releaseBegan)))
        finalOfferSentAt = nil
        journal.end()
        phase = .idle
        epoch = nil
        deliveredAtTakeover = nil
        manualSuspendEnd = nil
        handbackDeadline = nil
        handbackStartedAt = nil
        HandbackStuckAlert.disarm()   // Hand-back completed cleanly
        onLoanActiveChanged?(false)
        defaults.removeObject(forKey: DormantKeys.activeToken)   // R40: seized loan (if any) is over
        SportLog.event("loan", "CLOSED — records drained, pod released, cursor \(ack.committedCursor)")
    }

    // MARK: - Revoke (§3.2)

    private func handleRevoke(_ revoke: Revoke) {
        // SPLIT-BRAIN GUARD. Record that the phone asked for the pod back BEFORE the epoch
        // match, and log it rather than returning in silence.
        //
        // The hole it closes: the watch's request patience is 25 s (:304) but a grant's lease is
        // 5 MINUTES (PodLoanPhoneController :603). A grant delivered on the queued path can land
        // after the watch has given up and dropped to .idle with `epoch` still nil. A revoke
        // arriving in between would match nothing and vanish; the late grant then arrives
        // un-expired into .idle — an accepting phase (:383) — and the watch takes the pod. The
        // phone meanwhile ignores the resulting takeoverComplete (it requires .grantOffered,
        // PodLoanPhoneController :662), times out, and forceReclaimToOwner sets state = .owner
        // AND setAutomaticDosingPaused(false). Both sides then believe they own the pod.
        //
        // The pod is single-central so they cannot drive it at the same instant — but the watch
        // frees the radio 90 s after takeover and 12 s after every dose, so they would ALTERNATE,
        // each dosing off its own books with no sight of the other's insulin.
        //
        // Remembering the epoch is enough: the phone increments on every grant, so a legitimate
        // later grant is > this and still passes.
        if revoke.epoch > (lastRevokedEpoch ?? Int.min) {
            lastRevokedEpoch = revoke.epoch
        }
        guard let current = epoch ?? journal.activeEpoch, revoke.epoch == current else {
            SportLog.event("loan", "revoke ev=\(revoke.epoch) matched no live session (epoch \(epoch.map(String.init) ?? "nil"), phase \(phase.rawValue)) — RECORDED; any grant at or below ev=\(revoke.epoch) will now be refused")
            return
        }
        guard phase != .idle else { return }
        // Stop dosing, zero post-revoke pod commands, drain what we have.
        handbackRequested = false   // a phone-initiated revoke supersedes a pending drain
        handbackDeadline = nil
        handbackStartedAt = nil
        HandbackStuckAlert.disarm()   // The phone took over — no stuck alert
        // Capture the odometer BEFORE the teardown nils the pump. The revoke path tears down
        // first ON PURPOSE (it frees the pod's BLE immediately for the phone that is actively
        // reclaiming), but the offer built below used to ask the now-nil pumpManager for
        // podLoanInsulinDelivered and shipped odometer: nil — so revoke hand-backs skipped the
        // AUTHORITATIVE reconcile entirely (port-line e181, 2026-08-23: the one loan that day
        // with no reconcile line). The records still ride the drain; this restores the
        // CROSS-CHECK — and, since the checkpoint port, the asOf twin keeps revoke offers
        // checkpoint-capable too.
        revokeCapturedDelivered = pumpManager?.podLoanInsulinDelivered
        revokeCapturedDeliveredAt = pumpManager?.podLoanInsulinDeliveredAt
        loopManager.pumpManager = nil
        chaseWorkItem?.cancel()
        pendingUncertainEventID = nil   // liveness: no cross-loan chase residue
        inFlightEventIDs = []           // (the conservative .assumed records ride the drain)
        teardownPump()
        phase = .revoked
        onLoanActiveChanged?(false)
        SportLog.event("loan", "REVOKED — phone reclaimed the pod, draining records")
        sendHandbackOffer(freshened: false, recovered: true)
    }

    /// Drains a relaunch-recovered journal once the transport is available.
    func drainRecoveredIfNeeded() {
        queue.async {
            if let epoch = self.pendingInterruptedTakeoverEpoch {
                self.pendingInterruptedTakeoverEpoch = nil
                SportLog.event("loan", "START INTERRUPTED — takeover was in flight at relaunch; failing it to the phone, epoch \(epoch)")
                self.sendMessage(.takeoverFailed(TakeoverFailed(epoch: epoch, reason: "watch relaunched during takeover")))
            }
            guard self.phase == .recoveredDrain else { return }
            self.sendHandbackOffer(freshened: false, recovered: true)
        }
    }

    // MARK: - Status (§2.8)

    private func handleStatusQuery(_ query: StatusQuery) {
        guard let current = epoch, query.epoch == current else {
            // ANSWER, don't go quiet. Silence here was the whole bug — the one case the
            // phone most needs to hear about (its hand-over never arrived, so it is sitting there
            // having already let go of the pod) was the one case this returned without a word.
            //
            // Two guards on saying "I don't have it", because a wrong "no" makes the phone snatch
            // the pod back mid-takeover:
            //   phase != .active   — never claim ignorance while actually holding the pod.
            //   epoch < query.epoch — we are BEHIND the phone, i.e. this grant genuinely never
            //                         landed. A query for an epoch older than ours is a stale
            //                         message and gets the silence it deserves.
            if phase != .active, (epoch ?? Int.min) < query.epoch {
                SportLog.event("loan", "status query for epoch \(query.epoch) — we have \(epoch.map(String.init) ?? "none") and hold no pod: the grant never reached us (#108)")
                sendMessage(.statusReport(StatusReport(
                    epoch: query.epoch,
                    mode: currentMode(),
                    lastDirectGlucoseAge: nil,
                    lastEventSeq: 0,
                    podFault: nil,
                    holdsPod: false,
                    knowsGrant: false)))
            }
            return
        }
        let report = StatusReport(
            epoch: current,
            mode: currentMode(),
            lastDirectGlucoseAge: loopManager.latestGlucoseAge,  // sovereignty signal
            lastEventSeq: journal.lastEventSeq,
            podFault: pumpManager?.podLoanFaultDescription,
            holdsPod: phase == .active,
            knowsGrant: true)
        sendMessage(.statusReport(report))
    }

    private func currentMode() -> LoanDosingMode {
        if (manualSuspendEnd ?? .distantPast) > self.now() { return .suspended }
        // closedPhoneFed/cgmViewer/pausedStale arrive with the picker integration.
        return .closedDirect
    }

    private func currentPodStatus() -> LoanPodStatus {
        LoanPodStatus(
            timestamp: self.now(),
            deliveredUnits: pumpManager?.podLoanInsulinDelivered,
            reservoirLevel: nil,
            isSuspended: (manualSuspendEnd ?? .distantPast) > self.now(),
            faultCode: pumpManager?.podLoanFaultDescription)
    }

    // MARK: - Debug surface (the bare-bones bench screen; real UI comes later)

    struct DebugSnapshot {
        let phase: Phase
        let epoch: Int?
        let mode: LoanDosingMode
        let hasPumpManager: Bool
        let deliveredUnits: Double?
        let podFault: String?
        let lastEventSeq: Int
        let unackedCount: Int
        let pendingUncertain: Bool
        let suspendEndsAt: Date?
        let lastIdleNote: String?
        /// When the current Start attempt began (progress bar); only meaningful
        /// while phase is requested/takingOver.
        let startedAt: Date?
        /// A hand-back is requested and draining while the watch is still in
        /// control (phase .active) — the glance shows "ending…" + Cancel.
        let handbackPending: Bool
        /// When the current hand-back began — anchors the reclaim progress bar.
        let handbackStartedAt: Date?
        /// Can we reach the iPhone right now? The ONLY thing the
        /// watch needs to know — it does not care whether the phone is out of range, has
        /// Bluetooth off, or is powered down; all three are "can't reach it" and all three
        /// have the same remedy. Drives the hand-back wrist note.
        let phoneReachable: Bool
        /// R40(b): a seize offer is pending (normal request timed out with a stored
        /// credential); the glance renders the deliberate confirm with this age.
        let seizeOfferIssuedAt: Date?
    }

    /// True while this watch owns the pod (phase .active) — the carb/bolus flow
    /// routes delivery LOCALLY during a loan (the phone's pod link is released).
    var isLoanActive: Bool {
        return queue.sync { phase == .active }
    }

    /// Main-safe mirror of "is a loan active". Updated synchronously in the `phase` didSet, so
    /// it is never stale, and readable without touching `queue` — which doubles as the pump's
    /// delegateQueue and must never be sync'd from the UI (see the snapshot mirror below).
    private let loanActiveMirrorLock = NSLock()
    private var _loanActiveMirror = false
    /// Does the POD beep for a manual bolus? (acknowledgement at accept, completion at end)
    /// Read live, because the watch inherits the phone's beep settings in the grant.
    var podBeepsOnManualBolus: Bool {
        pumpManager?.podLoanBeepsOnManualBolus ?? false
    }

    var isLoanActiveNonBlocking: Bool {
        loanActiveMirrorLock.lock()
        defer { loanActiveMirrorLock.unlock() }
        return _loanActiveMirror
    }

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
    private let snapshotMirrorLock = NSLock()
    private var _snapshotMirror: DebugSnapshot?

    /// Main-safe: never touches `queue`. Nil only before the first refresh completes.
    var mirroredDebugSnapshot: DebugSnapshot? {
        snapshotMirrorLock.lock()
        defer { snapshotMirrorLock.unlock() }
        return _snapshotMirror
    }

    /// Ask for a fresh mirror. Returns immediately; the work lands on `queue` behind whatever
    /// pod operation is in flight, which is exactly the wait we refuse to make main sit through.
    func refreshDebugSnapshot() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let snap = self.buildDebugSnapshot()
            self.snapshotMirrorLock.lock()
            self._snapshotMirror = snap
            self.snapshotMirrorLock.unlock()
        }
    }

    func debugSnapshot() -> DebugSnapshot {
        return queue.sync { buildDebugSnapshot() }
    }

    /// MUST be called on `queue` — reads queue-confined state.
    private func buildDebugSnapshot() -> DebugSnapshot {
        return DebugSnapshot(
                phase: phase,
                epoch: epoch ?? journal.activeEpoch,
                mode: currentMode(),
                hasPumpManager: pumpManager != nil,
                deliveredUnits: pumpManager?.podLoanInsulinDelivered,
                podFault: pumpManager?.podLoanFaultDescription,
                lastEventSeq: journal.lastEventSeq,
                unackedCount: journal.unackedEvents().count,
                pendingUncertain: pendingUncertainEventID != nil,
                suspendEndsAt: (manualSuspendEnd ?? .distantPast) > self.now() ? manualSuspendEnd : nil,
                lastIdleNote: lastIdleNote,
                startedAt: attemptStartedAt,
                handbackPending: handbackRequested,
                handbackStartedAt: handbackStartedAt,
                phoneReachable: isPhoneReachable(),
                seizeOfferIssuedAt: seizeOffer?.issuedAt)
    }

    /// Bench helper: force a real pod status round-trip and report reachability.
    /// Only meaningful during an ACTIVE loan (the watch holds the pod then); returns
    /// nil when there's no pump to read (not in a loan).
    func debugReadStatus(completion: @escaping (Bool?) -> Void) {
        queue.async {
            guard let manager = self.pumpManager else { completion(nil); return }
            manager.podLoanReadStatus { ok in completion(ok) }
        }
    }

    // debugReset() REMOVED. Its doc comment claimed it "does NOT touch the pod — just local
    // state; the phone recovers on its own T1", and both halves were wrong in an active loan: it
    // called teardownPump(), and `.loaned` on the phone has no T1 (that timer only exists in
    // `.grantOffered`). What it actually did was abandon a live loan — pod orphaned on its
    // last command, phone still believing the watch held it, staged-but-unacked doses
    // stranded under a cleared epoch. The recovery paths that remain are the real ones: the
    // phone's escape hatch (reclaimNow), the hand-back flow, and an app relaunch.
    // In git at the commit that removed it, if a genuine wedge ever needs it back.

    // MARK: - Internals

    private func sendMessage(_ message: LoanMessage) {
        guard let dictionary = try? message.transportDictionary() else { return }
        send?(dictionary)
    }

    /// Title is a parameter now: "Loan Protocol Error" named an internal layer rather than the
    /// user's situation, and the only surviving caller is about a hand-back that did not confirm.
    // MARK: - Direct-G7 watchdog (the backstop behind the Start gate)

    /// The gate starts a loan on instant state checks; the estimated residue — a loan those
    /// checks bless that still gets no direct G7 — is 1-2% (takeover-window contention,
    /// mid-loan sensor death). This is the backstop for that residue, and the reason the gate
    /// is allowed to be fast.
    ///
    /// Two transmit windows, not one: takeover contention legitimately eats the first (pod and
    /// sensor competing for the establishment phase), so one window is twitchy and two is the
    /// floor of meaning. WARN ONLY — relay covers while the phone is near, so the alert can be
    /// calm; termination stayed off the table (Jeremy, 2026-08-22).
    ///
    /// Fire-and-check, deliberately no cancel plumbing: the timer always fires, reads the
    /// stamp, and stays silent when a reading arrived. Cancel-on-ingest would need a hook from
    /// the glucose path into this controller for the sole benefit of skipping a comparison.
    static let directG7WatchdogDelay: TimeInterval = 12 * 60

    /// The decision alone, testable without timers, alerts, or a live pump: warn iff no direct
    /// reading has arrived since takeover.
    func directG7WatchdogShouldWarn(takeoverAt: Date) -> Bool {
        guard let last = loopManager.lastDirectReadingAt else { return true }
        return last <= takeoverAt
    }

    func armDirectG7Watchdog(takeoverAt: Date) {
        schedule(after: Self.directG7WatchdogDelay, label: "direct-g7-watchdog", epochScoped: true) { [weak self] in
            guard let self = self, self.phase == .active else { return }
            guard self.directG7WatchdogShouldWarn(takeoverAt: takeoverAt) else {
                SportLog.event("loan", "direct-G7 watchdog: quiet — sensor delivering")
                return
            }
            SportLog.event("loan", "direct-G7 watchdog: NO direct reading since takeover (+\(Int(Self.directG7WatchdogDelay))s) — warning; relay covers while the phone is near")
            self.issueProtocolAlert(title: NSLocalizedString("No Direct BG", comment: "Watch alert title when a loan has no direct sensor readings"),
                                    body: NSLocalizedString("The watch isn't hearing your sensor this session. Keep your phone nearby.", comment: "Watch alert body when a loan has no direct sensor readings"))
        }
    }

    private func issueProtocolAlert(title: String, body: String) {
        loopManager.issueAlert(Alert(
            identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "protocolNack"),
            foregroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
            backgroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
            trigger: .immediate))
    }

    private func persistPumpRawValue() {
        guard let manager = pumpManager else { return }
        // Same {managerIdentifier, state} shape the phone persists (Common/Models/
        // PumpManager.swift rawValue — that file is phone-target-only, so built here).
        defaults.set(["managerIdentifier": "Omnipod", "state": manager.rawState], forKey: Keys.pumpRawValue)
    }

    private func teardownPump() {
        // Drop the BLE link EXPLICITLY before dropping the manager. Relying on deallocation to
        // tear down BlePodComms -> BluetoothManager -> CBCentralManager is the weakest release
        // path there is, and this is the one moment the pod must actually become free: without
        // an explicit disconnect nothing removes the pod from autoConnectIDs, any lingering
        // reference keeps the link, and a pod that stays CONNECTED is not advertising — so the
        // phone's standing connect cannot land however aggressive it is.
        //
        // podLoanOrphanConnection rather than releaseConnection: it does the disconnect +
        // cancelLoanScan WITHOUT the C5 record-close, which finalizeHandback has already
        // performed and which ledgerClear below supersedes anyway.
        SportLog.event("handback", "teardownPump: releasing BLE explicitly (see PODLOAN orphan log for the identifier)")
        pumpManager?.podLoanOrphanConnection()
        pumpManager?.pumpManagerDelegate = nil
        pumpManager = nil
        defaults.removeObject(forKey: Keys.pumpRawValue)
        // The session ledger ends with the session.
        loopManager.ledgerClear()
    }

    // MARK: - Uncertainty chase (the genuinely-additive layer-1 piece, d27a40c7 port)

    private func scheduleChase(attempt: Int = 0) {
        let delays: [TimeInterval] = [5, 20, 60]
        guard attempt < delays.count else {
            // Chase exhausted: the conservative .assumed record STANDS (the hand-back
            // audit settles it) — resolve the pending flag so the record can
            // stream/commit and an interim drain isn't blocked behind a dead chase.
            SportLog.event("verdict", "chase exhausted — assumed record stands (hand-back audit settles it)")
            pendingUncertainEventID = nil
            streamRecords()
            return
        }
        chaseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.phase == .active,
                  let manager = self.pumpManager,
                  let eventID = self.pendingUncertainEventID else { return }
            manager.podLoanResolveUncertainty { verdict in
                self.queue.async {
                    guard self.pendingUncertainEventID == eventID else { return }
                    switch verdict {
                    case .noPendingCommand:
                        // Stock resolved it on an earlier contact; the dose truth is in
                        // hasNewPumpEvents. The journal entry stays .assumed and the
                        // hand-back reconciliation settles it — never guess here.
                        self.pendingUncertainEventID = nil
                        self.streamRecords()   // the withheld .assumed record may flow now
                    case .delivered:
                        self.journal.confirm(id: eventID)
                        self.pendingUncertainEventID = nil
                        self.streamRecords()
                        SportLog.event("verdict", "DELIVERED — pod confirmed the uncertain command")
                    case .refuted(let kind):
                        // Reverse the ledger's assumed booking BEFORE annulling
                        // (the record lookup needs the event still present). A
                        // skipped-reduction was never booked → removeDose no-ops.
                        var refutedUnits: Double?
                        if let event = self.journal.unackedEvents().first(where: { $0.id == eventID }),
                           case .assumed(let kind) = event.provenance, kind != .skippedReduction,
                           let dose = event.record.podLoanLedgerDoseEntry(insulinType: nil) {
                            // skippedReduction was never booked — removing would rely on
                            // "no ±2s neighbor" luck (adversarial review); guard explicitly.
                            self.loopManager.ledgerRemoveDose(type: dose.type, startingAt: dose.startDate)
                            // Captured here, while the event is still present, so the alert can
                            // name the amount that did NOT go in. Nil for anything without a
                            // dose to name; the title then omits the number rather than lying.
                            if dose.type == .bolus { refutedUnits = dose.programmedUnits }
                        }
                        self.journal.annul(id: eventID)
                        self.pendingUncertainEventID = nil
                        self.streamRecords()
                        SportLog.event("verdict", "REFUTED \(kind) — command never reached the pod, record annulled")
                        self.alertRefuted(kind: kind, units: refutedUnits)
                    case .unreachable:
                        self.scheduleChase(attempt: attempt + 1)
                    }
                }
            }
        }
        chaseWorkItem = work
        schedule(after: delays[attempt], label: "verdict-chase-\(attempt + 1)", execute: work)
    }

    /// This is the ONE path entitled to assert non-delivery: the pod's own state proved the
    /// command never arrived. The old copy then said "Bolus again if you still need it" — an
    /// insulin instruction, which stock never puts in notification text. Removing it costs
    /// nothing, because the sentence that replaces it does the same work better: the record was
    /// just annulled, so active insulin no longer counts the dose, and the bolus calculator
    /// will now recommend accordingly. Attribution ("the pod reports") rather than assertion,
    /// per stock's voice.
    private func alertRefuted(kind: OmniPumpManager.PodLoanPendingKind, units: Double? = nil) {
        switch kind {
        case .bolus:
            WKInterfaceDevice.current().play(.failure)
            let title = units.map {
                String(format: NSLocalizedString("Bolus Not Delivered: %@ U", comment: "Watch alert title when the pod proved a bolus never arrived (1: units)"),
                       NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal))
            } ?? NSLocalizedString("Bolus Not Delivered", comment: "Watch alert title when the pod proved a bolus never arrived")
            let body = NSLocalizedString("The pod reports no delivery. Active insulin no longer includes it.", comment: "Watch alert body when the pod proved a bolus never arrived")
            loopManager.issueAlert(Alert(
                identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "refutedBolus"),
                foregroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                backgroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                trigger: .immediate))
        case .resume:
            // Dead three ways over, so it is logged rather than surfaced. The watch never
            // programs a basal schedule, so `.resume` cannot arise here at all; the watch's
            // `issueAlert` is a log-only stub, so nothing would reach the wrist even if it did;
            // and "Resume again" named a control the watch does not have. Kept as a case so a
            // future watch-side resume path lands somewhere visible instead of falling silently
            // into `default`.
            SportLog.event("verdict", "REFUTED resume — unreachable on this build; logged only")
        default:
            break
        }
    }

    /// Best-effort streaming (§2.4): the phone accumulates the record even if the
    /// watch later dies. Loss is harmless — the cursor and IDs absorb redelivery.
    private func streamRecords() {
        guard phase == .active, let epoch = epoch else { return }
        // Events that are IN-FLIGHT (mint→classification) or
        // whose verdict chase is LIVE stay out of the stream — the phone's commit set
        // is drawn from its staged map, so streaming either would let an interim
        // commit write a dose before an annul/refuted verdict can unwind it
        // (tombstones only filter staged events). They flow on classification.
        var events = journal.unackedEvents()
        events.removeAll { inFlightEventIDs.contains($0.id) }
        if let pending = pendingUncertainEventID {
            events.removeAll { $0.id == pending }
        }
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
        if inFlightEventIDs.isEmpty, pendingUncertainEventID == nil,
           let start = deliveredAtTakeover, let latest = pumpManager?.podLoanInsulinDelivered,
           let asOf = pumpManager?.podLoanInsulinDeliveredAt {
            odometer = LoanOdometerSnapshot(deliveredAtStart: start, deliveredLatest: latest,
                                            freshenSucceeded: false, asOf: asOf)
        }
        SportLog.event("handback", String(format: "stream: %d event(s), %d tombstone(s)%@", events.count, tombstones.count,
                                          odometer.map { String(format: " · odo %.2f U [checkpoint]", $0.deliveredLatest) } ?? ""))
        sendMessage(.doseRecordBatch(DoseRecordBatch(epoch: epoch, events: events, tombstones: tombstones, odometer: odometer)))
    }
}

// MARK: - Dose recording hooks (WatchDoseEnactor calls these around stock enacts)

protocol WatchLoanDoseRecording: AnyObject {
    func loanWillEnactTempBasal(unitsPerHour: Double, duration: TimeInterval) -> UUID?
    func loanWillEnactBolus(units: Double) -> UUID?
    func loanDidEnact(eventID: UUID?, error: PumpManagerError?)
}

extension PodLoanWatchController: WatchLoanDoseRecording {

    func loanWillEnactTempBasal(unitsPerHour: Double, duration: TimeInterval) -> UUID? {
        return mintIntent(record: LoanDoseRecord(
            kind: unitsPerHour == 0 && duration > 0 ? .suspend : .tempBasal,
            startDate: self.now(),
            endDate: self.now().addingTimeInterval(duration),
            unitsPerHour: unitsPerHour),
            uncertainKind: .tempUncertain)
    }

    func loanWillEnactBolus(units: Double) -> UUID? {
        return mintIntent(record: LoanDoseRecord(kind: .bolus, startDate: self.now(), amount: units),
                          uncertainKind: .bolusUncertain)
    }

    /// Watch-entered carbs follow the pod home.
    ///
    /// Rides the ordinary journal, exactly like the override path, so it inherits the per-loan
    /// seq, the commit cursor, resend-until-ack and the hand-back drain for free. On the phone,
    /// LoanReconciler turns a .carb record into a NewCarbEntry (LoanReconciler.swift:183-189)
    /// and both commit sites run behind
    /// `.filter { !stagedTombstones.contains($0.id) && !committedIDs.contains($0.id) }`, so a
    /// redelivered record is dropped before it reaches addCarb.
    ///
    /// That protocol-level gate is load-bearing, not belt-and-braces: NewCarbEntry carries no
    /// identity of its own (CarbStore mints a fresh syncIdentifier on every addCarbEntry), so
    /// the store can never dedupe and the cursor is the only guard against double-counting.
    ///
    /// No skew gate needed, unlike .overrideChange: .carb is an original kind that every phone
    /// build in the field can decode.
    func loanDidRecordCarbs(_ entry: NewCarbEntry) {
        let grams = entry.quantity.doubleValue(for: .gram())
        queue.async {
            guard self.phase == .active else {
                SportLog.event("loan", String(format: "carb entry ignored (%.0f g) — no active loan to journal it against", grams))
                return
            }
            let record = LoanDoseRecord(kind: .carb,
                                        startDate: entry.startDate,
                                        amount: grams,
                                        absorptionTime: entry.absorptionTime)
            guard let event = try? self.journal.mintEvent(record: record, provenance: .confirmed) else {
                SportLog.event("loan", String(format: "** CARB JOURNAL MINT FAILED (%.0f g) — the carb is LIVE on the watch but will NOT follow the pod home **", grams))
                return
            }
            SportLog.event("loan", String(format: "carb JOURNALED %.0f g (absorption %.1f h) — seq %d, event %@",
                                          grams, (entry.absorptionTime ?? 0) / 3600, event.seq,
                                          String(event.id.uuidString.prefix(8))))
            self.streamRecords()
        }
    }

    /// Journal a carb the WRIST deleted, so the deletion follows the pod home.
    ///
    /// This CANNOT be a local-only delete. `ingestGrantCarbs` makes the watch an authoritative
    /// mirror of the phone at every takeover, so a deletion the phone never heard about is
    /// resurrected at the next grant — the user deletes it, watches it vanish, and it comes back
    /// still driving dosing. Riding the journal buys the per-loan seq, the commit cursor,
    /// resend-until-ack and the hand-back drain, which is exactly what makes the deletion survive
    /// a phone that is out of range for the whole session.
    ///
    /// `syncIdentifier` is the phone's own, when the carb came from the grant; nil for a carb
    /// entered on this wrist, whose add/delete pair the reconciler cancels instead of
    /// round-tripping (LoanReconciler `.carbDeleted`).
    func loanDidDeleteCarb(syncIdentifier: String?, startDate: Date, grams: Double) {
        queue.async {
            guard self.phase == .active else {
                SportLog.event("loan", String(format: "carb delete ignored (%.0f g) — no active loan to journal it against", grams))
                return
            }
            let record = LoanDoseRecord(kind: .carbDeleted,
                                        startDate: startDate,
                                        amount: grams,
                                        syncIdentifier: syncIdentifier)
            guard let event = try? self.journal.mintEvent(record: record, provenance: .confirmed) else {
                // Say it loudly: the carb is gone from the WATCH but the phone still holds it, so
                // the next takeover will bring it back. Same failure class as a lost carb add.
                SportLog.event("loan", String(format: "** CARB DELETE JOURNAL MINT FAILED (%.0f g) — gone on the watch but the phone still has it; the next grant will RESURRECT it **", grams))
                return
            }
            SportLog.event("loan", String(format: "carb DELETE journaled %.0f g @ %@ — sync %@, seq %d, event %@",
                                          grams, ISO8601DateFormatter().string(from: startDate),
                                          syncIdentifier ?? "none(watch-entered)", event.seq,
                                          String(event.id.uuidString.prefix(8))))
            self.streamRecords()
        }
    }

    /// Journal a WRIST-enacted override change so it follows the pod home.
    ///
    /// Rides the ordinary journal, exactly like the (currently suppressed) carb path: it
    /// inherits the per-loan seq, the commit cursor, resend-until-ack, and the hand-back drain —
    /// which is precisely what makes a phone-ABSENT override still reach the phone. A bespoke
    /// WC message would be dropped on the floor the moment the phone is out of range, and Sport
    /// Mode's whole premise is that it is.
    ///
    /// Minted `.confirmed`, NOT through `mintIntent`: this is not a pod command. There is no
    /// transmission to be uncertain about and no verdict to chase, so it must never enter
    /// `inFlightEventIDs` (which would withhold it from streams and — worse — block an interim
    /// hand-back drain waiting for a classification that can never arrive).
    ///
    /// Called from the wrist UI on main; `queue.async` (never `sync`) keeps the queue-order
    /// invariant intact.
    ///
    /// EDGE CASES (verified, not assumed — no machinery added for any of them):
    ///
    ///  • OVERRIDE EXPIRES MID-LOAN. Stock handles it, via the override's OWN end date, in both
    ///    places that matter. Schedules: `TemporaryScheduleOverrideHistory.resolvingRecent*`
    ///    scopes each multiplier to `[startDate, actualEndDate]` (overridesReflectingEnabled-
    ///    Duration → applyingOverride(relativeTo:)), so cycles after the end resolve unscaled
    ///    while the temps that ran DURING it still net against the scaled baseline. Target:
    ///    `GlucoseRangeSchedule.value(at:)` gates on `Date() < override.end`, so the target
    ///    snaps back on expiry. Nothing here polls or sweeps — an expired override simply
    ///    stops mattering. The journal record is a point event ("at 14:02 the wrist set this
    ///    override, which ends at 15:02"), so its meaning is unchanged by expiry: the phone
    ///    applies the same override, already expired or expiring, and treats it identically.
    ///
    ///  • HAND-BACK WITH AN OVERRIDE ACTIVE. It PERSISTS on the phone — that is the ruling, and
    ///    it is what falls out of the design: the drain applies it to the phone's LoopSettings
    ///    and nothing revokes it at loan end. The user set an override; ending Sport Mode is
    ///    not a request to cancel it.
    ///
    ///  • LOAN ENDS BY REVOCATION OR CRASH. The record either drained or it did not, and both
    ///    are safe. Mint persists to disk BEFORE returning (LoanEventJournal.mintEvent), so:
    ///    a revoke routes through `handleRevoke` → `sendHandbackOffer(recovered: true)`, which
    ///    carries every unacked event including this one; a crash/relaunch finds the undrained
    ///    journal, enters `.recoveredDrain`, and `drainRecoveredIfNeeded()` offers the same set.
    ///    If the phone is simply never reachable the record stays unacked and re-offers on a
    ///    later hand-back, exactly like an unacked dose. The only true loss window is a
    ///    process death between the wrist apply and this mint — sub-millisecond, and in that
    ///    window the override was never durable ANYWHERE, so nothing is left inconsistent.
    ///
    ///  • WATCH APP RELAUNCHES MID-LOAN. The applied override does NOT survive INTO A LOAN,
    ///    because the loan itself does not: `init` routes any live phase to `.recoveredDrain`
    ///    (never resurrect a session). So there is no state where dosing continues under an
    ///    override the sport manager has forgotten. What DOES survive is the wrist UI's copy
    ///    (stock `LoopDataManager.settings` is `@PersistedProperty`), which is display-only
    ///    once the loan is dead; the sport `WatchLoopManager.settings` is grant-scoped by
    ///    construction and is rebuilt by the NEXT grant — which carries the phone's override
    ///    (part A), i.e. this one, once the recovered drain lands. Deliberately no new
    ///    persistence: the correct source of truth after a relaunch is the phone, not a
    ///    cached wrist value.
    func loanDidRecordOverride(_ override: TemporaryScheduleOverride?) {
        let name = override.map { $0.context.presetNameForLog } ?? "cleared"
        queue.async {
            guard self.phase == .active else {
                // Outside a loan the phone owns overrides and the stock WC settings path
                // already carries them — journaling here would be a record with no loan to
                // ride home on. (ActionHUDController only calls this during a loan; this is
                // the guard for a hand-back landing between the tap and this hop.)
                SportLog.event("override", "NOT JOURNALED (\(name)) — no active loan (phase \(self.phase.rawValue)); the stock phone path owns it")
                return
            }
            guard self.phoneSupportsOverrideRecords else {
                // Skew gate: an older phone cannot decode this kind, and an
                // undecodable offer strands the loan. The override is LIVE on the wrist —
                // dosing is correct here — it simply will not follow the pod home.
                SportLog.event("override", "NOT JOURNALED (\(name)) — this phone build predates override records; the override is LIVE on the watch but will NOT follow the pod home. Update the phone app to sync overrides.")
                return
            }
            let record = LoanDoseRecord.overrideChange(override, at: self.now(), note: name)
            guard let event = try? self.journal.mintEvent(record: record, provenance: .confirmed) else {
                SportLog.event("override", "** JOURNAL MINT FAILED for \(name) — the override is LIVE on the watch but will NOT follow the pod home **")
                return
            }
            SportLog.event("override", "JOURNALED \(name) — seq \(event.seq), event \(event.id.uuidString.prefix(8)), sync \(record.syncIdentifier ?? "—") (rides the drain to the phone)")
            self.streamRecords()
        }
    }

    private func mintIntent(record: LoanDoseRecord, uncertainKind: EventProvenance.UncertainKind) -> UUID? {
        // QUEUE-ORDER INVARIANT (load-bearing both directions): callers sync INTO
        // this serial queue from dataAccessQueue/main — so no block running ON this queue
        // may ever dispatch sync onto WatchLoopManager.dataAccessQueue (ABBA deadlock),
        // and mintIntent must never be reached from this queue itself (libdispatch trap —
        // a pod-reclaim completion that ran deliverBolus here directly crashed exactly so).
        var minted: UUID?
        queue.sync {
            // A new programming command destroys pending verdict evidence: the
            // conservative .assumed record stands, chase stops (d27a40c7 semantics).
            if pendingUncertainEventID != nil {
                os_log("New command while a verdict was pending — evidence destroyed, conservative record stands", log: log, type: .default)
                chaseWorkItem?.cancel()
                pendingUncertainEventID = nil
            }
            minted = try? journal.mintEvent(record: record, provenance: .assumed(uncertainKind)).id
            if let minted = minted {
                inFlightEventIDs.insert(minted)   // withheld until loanDidEnact classifies
            }
            // The evidence-destruction branch above cleared a pending
            // chase WITHOUT streaming its standing .assumed record — the only
            // withheld-exit that didn't. A stale max-seq ack landing after this mint
            // could then ack the never-transmitted record past recovery. Stream NOW
            // (same serial-queue block, before any later ack can apply); the freshly
            // minted event is in the in-flight set and stays excluded.
            streamRecords()
        }
        return minted
    }

    func loanDidEnact(eventID: UUID?, error: PumpManagerError?) {
        guard let eventID = eventID else { return }
        queue.async {
            self.inFlightEventIDs.remove(eventID)   // classified from here — may flow
            if error == nil {
                // Certain success: the response carried the incremented odometer.
                self.journal.confirm(id: eventID)
                self.streamRecords()
                return
            }

            // A CERTAIN local refusal is not uncertainty. PodCommsError
            // .unfinalizedBolus is decided from this device's own state BEFORE any byte reaches
            // the pod (OmniPumpManager guards on podState.unfinalizedBolus?.isFinished()), so
            // the command provably never went out. Booking it as an assumed max-exposure dose
            // invents insulin: a bolus refused because an earlier one is still delivering
            // (DASH runs ~1.5 U/min, so a refusal within a minute of a prior bolus is routine)
            // would land in the ledger as if delivered. The chase then finds
            // noPendingCommand — which the booking rules treat as "leave standing" — so the
            // phantom never clears, drives automaticDosingIOBLimit headroom negative, and
            // zero-temps every cycle after it. The IOB clamp works correctly on
            // corrupt input; this is where the corruption enters.
            let certainLocalRefusal = String(describing: error).contains("unfinalizedBolus")
            let uncertain: Bool
            if certainLocalRefusal { uncertain = false }
            else if case .uncertainDelivery = error { uncertain = true }
            else { uncertain = self.pumpManager?.podLoanPendingCommandKind != nil }
            if certainLocalRefusal {
                SportLog.event("ledger", "CERTAIN refusal (pod never received it) — annulling, NOT booking: \(error.map { String(describing: $0) } ?? "?")")
            }

            if !uncertain {
                // Certain failure: stock cleared its pending command; nothing delivered.
                self.journal.annul(id: eventID)
                self.streamRecords()
                return
            }

            // Uncertain. Direction-aware journaling: keep the
            // .assumed record only when "applied" models MORE insulin. An uncertain
            // BELOW-schedule temp is re-tagged as a skipped-reduction marker instead —
            // the C-prime fingerprint if it turns out real and unresolved.
            var retaggedSkippedReduction = false
            if let events = self.journal.unackedEvents().first(where: { $0.id == eventID }),
               events.record.kind == .tempBasal || events.record.kind == .suspend,
               let rate = events.record.unitsPerHour,
               let scheduled = self.loopManager.settings.basalRateSchedule?.value(at: events.record.startDate),
               rate < scheduled {
                self.journal.amend(id: eventID, record: events.record, provenance: .assumed(.skippedReduction))
                retaggedSkippedReduction = true
            }

            // Mirror the journal's
            // direction-aware .assumed convention into the ledger. Book the assumed dose
            // ONLY when it models MORE insulin than schedule (bolus always; above-schedule
            // temps) — a skipped-reduction stays unbooked, so predecessors keep running in
            // the ledger (conservative, high-IOB direction, same as the journal). A later
            // REFUTED verdict reverses the booking; DELIVERED/exhausted/noPendingCommand
            // leave it standing, exactly like the journal record. Without this, every
            // uncertain enact leaves a persistent ledger<store gap.
            if !retaggedSkippedReduction,
               let record = self.journal.unackedEvents().first(where: { $0.id == eventID })?.record,
               let dose = record.podLoanLedgerDoseEntry(insulinType: self.pumpManager?.status.insulinType) {
                self.loopManager.ledgerRecordEnact(dose)
                SportLog.event("ledger", "assumed dose BOOKED (uncertain enact, chase pending) — \(record.kind)")
            }

            self.pendingUncertainEventID = eventID
            self.streamRecords()
            self.scheduleChase()
        }
    }
}

/// Which WCSession channel a message arrived on. `sendMessage` wakes the counterpart
/// immediately; `transferUserInfo` is queued but guaranteed and relaunch-surviving. They fail
/// independently, which is the whole reason this is recorded.
enum LoanTransportChannel: String {
    case urgent    // WCSession.sendMessage -> session(_:didReceiveMessage:)
    case queued    // WCSession.transferUserInfo -> session(_:didReceiveUserInfo:)
}

// MARK: - PumpManagerDelegate (the host duties; alert family forwards to WatchLoopManager's
// existing DeviceManagerDelegate conformance)

extension PodLoanWatchController: PumpManagerDelegate {

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {
        // Synchronous persist: stock sets podState.unacknowledgedCommand BEFORE the BLE
        // write and notifies here — flushing now gives the C10 intent-before-transmission
        // durability (porting brief §1; UserDefaults synchronous write).
        persistPumpRawValue()
    }

    func pumpManager(_ pumpManager: PumpManager, hasNewPumpEvents events: [NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool, completion: @escaping (Error?) -> Void) {
        // Dose rows are NOT stored — the ledger (fed at enact time) is the only book, and
        // these writes never persisted anyway. What this callback still carries is
        // the PUMP-RECENCY signal: a successful status read reporting events is proof of a pod
        // round-trip, and that stamp gates dosing (pumpDataTooOld) and the warm cadence.
        // The stock storage path BLOCKS its session queue on this completion — always call it.
        loopManager.notePumpDataReceived(at: lastReconciliation ?? self.now())
        completion(nil)
    }

    func pumpManager(_ pumpManager: PumpManager, didReadReservoirValue units: Double, at date: Date, completion: @escaping (Swift.Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool), Error>) -> Void) {
        // Reservoir readings are not stored (and are unreadable above 50 U on this pod
        // anyway — the odometer is the audit instrument). Stamp recency; report the value back
        // as a fresh, non-continuous reading so the manager's bookkeeping proceeds.
        loopManager.notePumpDataReceived(at: date)
        struct SimpleReservoirValue: ReservoirValue {
            let startDate: Date
            let unitVolume: Double
        }
        completion(.success((newValue: SimpleReservoirValue(startDate: date, unitVolume: units),
                             lastValue: nil, areStoredValuesContinuous: false)))
    }

    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date {
        // Was doseStore.pumpEventQueryAfterDate. The events are dropped now, so the filter
        // only bounds how much the manager re-reports; the owned stamp keeps it small.
        return loopManager.lastPumpDataDate ?? self.now().addingTimeInterval(-.hours(4))
    }

    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager) {
        // The watch loop triggers on CGM readings (enact-only-on-fresh-reading), not
        // on pump heartbeats.
    }

    func pumpManagerMustProvideBLEHeartbeat(_ pumpManager: PumpManager) -> Bool {
        return false
    }

    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError) {
        os_log("PumpManager error: %{public}@", log: log, type: .error, String(describing: error))
    }

    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) {
        loopManager.doseStore.pumpRecordsBasalProfileStartEvents = pumpRecordsBasalProfileStartEvents
    }

    func pumpManager(_ pumpManager: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) {
        os_log("Pump clock adjusted by %f", log: log, type: .default, adjustment)
    }

    func pumpManager(_ pumpManager: PumpManager, didRequestBasalRateScheduleChange basalRateSchedule: BasalRateSchedule, completion: @escaping (Error?) -> Void) {
        // The watch never accepts schedule changes; the pod's stored schedule is the
        // phone's.
        completion(WatchLoopError.configurationError("basal schedule changes are phone-only"))
    }

    func pumpManagerWillDeactivate(_ pumpManager: PumpManager) {
        os_log("PumpManager will deactivate", log: log, type: .default)
    }

    func pumpManagerPumpWasReplaced(_ pumpManager: PumpManager) {
        os_log("Pump was replaced", log: log, type: .default)
    }

    var detectedSystemTimeOffset: TimeInterval {
        return 0
    }

    var automaticDosingEnabled: Bool {
        return phase == .active
    }
}

// MARK: - PumpManagerStatusObserver

extension PodLoanWatchController: PumpManagerStatusObserver {
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {
        os_log("Pump status: %{public}@", log: log, type: .default, String(describing: status.basalDeliveryState))
    }
}

// MARK: - DeviceManagerDelegate (forwards to WatchLoopManager's conformances)

extension PodLoanWatchController: DeviceManagerDelegate {
    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        loopManager.deviceManager(manager, logEventForDeviceIdentifier: deviceIdentifier, type: type, message: message, completion: completion)
    }

    func issueAlert(_ alert: LoopKit.Alert) {
        loopManager.issueAlert(alert)
    }

    func retractAlert(identifier: LoopKit.Alert.Identifier) {
        loopManager.retractAlert(identifier: identifier)
    }

    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier, completion: @escaping (Swift.Result<Bool, Error>) -> Void) {
        loopManager.doesIssuedAlertExist(identifier: identifier, completion: completion)
    }

    func lookupAllUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {
        loopManager.lookupAllUnretracted(managerIdentifier: managerIdentifier, completion: completion)
    }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {
        loopManager.lookupAllUnacknowledgedUnretracted(managerIdentifier: managerIdentifier, completion: completion)
    }

    func recordRetractedAlert(_ alert: LoopKit.Alert, at date: Date) {
        loopManager.recordRetractedAlert(alert, at: date)
    }
}


// R40: a seize activation forces the credential's provisional epoch fresh AND mints the
// live takeover lease — the dormant expiresAt is issuedAt by contract, and carrying it
// verbatim aborted the first field seize at ladder read 1. LoanGrant is all-let by design,
// so the rewrite is an explicit re-init — every other field carried verbatim.
// Internal (not fileprivate) so the unit test can pin both rewritten fields directly.
extension LoanGrant {
    func withEpoch(_ newEpoch: Int, leaseUntil: Date) -> LoanGrant {
        LoanGrant(epoch: newEpoch, expiresAt: leaseUntil, pumpManagerRawState: pumpManagerRawState,
                  podAddress: podAddress, therapySettingsRaw: therapySettingsRaw,
                  settingsTimeZoneID: settingsTimeZoneID, doseHistory: doseHistory,
                  boundaryRecord: boundaryRecord, supportsInterimHandback: supportsInterimHandback,
                  supportsOverrideRecords: supportsOverrideRecords,
                  integralRetrospectiveCorrectionEnabled: integralRetrospectiveCorrectionEnabled,
                  phoneClosedLoopEnabled: phoneClosedLoopEnabled, carbHistory: carbHistory,
                  glucoseHistory: glucoseHistory, predictionSnapshot: predictionSnapshot,
                  lastLoopCompleted: lastLoopCompleted, lowBGWarningSettings: lowBGWarningSettings)
    }
}
