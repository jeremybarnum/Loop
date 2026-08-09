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
import LoopCore
import OmnipodKit
import WatchKit
import os.log

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

    /// #67 follow-up (2026-08-03): is the counterpart app reachable right now
    /// (WCSession.isReachable at integration)? Injected so the controller stays testable.
    /// Default true = behave exactly as before wherever it is not wired.
    var isPhoneReachable: () -> Bool = { true }
    /// Last reachability logged during a hand-back, so the log records TRANSITIONS rather
    /// than repeating the same line every 15 s resend.
    private var lastHandbackReachable: Bool?

    /// Injected transport: dictionary -> WCSession.transferUserInfo (integration step).
    var send: (([String: Any]) -> Void)?

    /// Fires on loan lifecycle edges: true when the loan becomes ACTIVE (the session
    /// owner starts the G7 transport — closedDirect needs glucose), false when the
    /// pod is released/revoked/failed (transport stops, loop input pauses).
    var onLoanActiveChanged: ((Bool) -> Void)?

    /// R26 (reverse arbiter): the pod TAKEOVER outranks the G7 — during the bounded
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
    /// moment permission to let go is being sent. Field symptom (Jeremy, 2026-08-04): the carb
    /// and insulin records are already visible on the phone while "Reclaiming…" persists another
    /// 20-50s. The records being visible proves the commit landed; the wait is the ack.
    ///
    /// Takeover already solved this class with a keepalive holder for its ~40s ladder; the
    /// return path never got one. This is that hook. It changes NO safety property — the
    /// release stays gated on the ack — it just stops the ack from being starved.
    var onHandbackRuntimeHold: ((Bool) -> Void)?

    private(set) var phase: Phase {
        didSet {
            UserDefaults.standard.set(phase.rawValue, forKey: Keys.phase)
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
        }
    }
    private var epoch: Int? {
        didSet { UserDefaults.standard.set(epoch, forKey: Keys.epoch) }
    }

    private var pumpManager: OmniPumpManager?
    /// Odometer at takeover, for the hand-back snapshot pair (§1.4).
    private var deliveredAtTakeover: Double?
    /// When the current Start attempt began (request sent) — drives the R24 glance
    /// progress bar. Meaningful only while phase is requested/takingOver.
    private var attemptStartedAt: Date?
    /// #86: wall-clock of the previous takeover-ladder read, and the largest gap seen between two
    /// consecutive reads this attempt. A read is event-driven when the pod stack's session-
    /// established callback fires (fast — no fixed period) and backstop-driven otherwise, on an
    /// 8 s timer (was a 3 s metronome pre-2026-08-03). So an ordinary backstop-only run reads
    /// ~8 s apart; a gap far past THAT means the APP STOPPED EXECUTING mid-connect — not that the
    /// pod went quiet. Distinguishing those two is the whole point: they send the user to
    /// opposite places. (See `driver` on `attemptTakeoverRead` for the per-read tag.)
    private var lastTakeoverReadAt: Date?
    /// #86: the pending takeover retry, held so the session-established event can fire it early.
    /// The ACTION is a plain closure and the BACKSTOP is the cancellable timer — they must not
    /// be the same object. 213 stored one DispatchWorkItem for both, then did cancel() followed
    /// by perform(); a cancelled work item releases its block and performs nothing, so the
    /// ladder stopped dead the instant the event fired (field 2026-08-03 18:33:24, epoch 147:
    /// "session ESTABLISHED" logged, then silence, no retry and no timeout).
    private var takeoverRetryAction: (() -> Void)?
    private var takeoverBackstop: DispatchWorkItem?
    private var takeoverMaxReadGap: TimeInterval = 0
    /// Hand-back offer resend counter (reset when a drain begins) — makes an
    /// unreachable-phone wait self-documenting in the log.
    private var handbackResendCount = 0
    /// WS1 (ruled 2026-07-19): a hand-back has been REQUESTED but the watch is still
    /// in control — phase stays .active, dosing and boluses continue, the journal
    /// drains via interim offers (released=false), and the user can cancel. Only when
    /// the drain is fully acked does finalizeHandback() stop dosing and send the
    /// final (released=true) offer. In-memory only: any relaunch ends the loan.
    private var handbackRequested = false
    /// WS1 capability gate (REAL-3): interim offers only when the granting phone
    /// understands them; false/nil grant → legacy single-phase hand-back.
    private var phoneSupportsInterimHandback = false
    /// #68B: only mint .overrideChange when the granting phone can decode it.
    private var phoneSupportsOverrideRecords = false
    /// WS1 round-2 fix: finalizeHandback flips phase BEFORE its ~3-15s of pod work
    /// (temp-cancel + status reads); a duplicate interim ack arriving in that window
    /// must NOT close the loan (the final offer hasn't been sent — the phone would
    /// strand in .loaned forever). The close path requires this flag in .handingBack.
    private var finalOfferSent = false
    /// WS1 round-3 fix: a pod COMMAND's journal event exists from MINT time, but its
    /// delivery classification (confirmed / uncertain / annulled) only lands at the
    /// enact COMPLETION seconds later — a resend or stream in that window would carry
    /// it to the phone, whose interim commit has no unwind for a later annul.
    /// Events in this set are withheld from streams and interim offers until their
    /// loanDidEnact classifies them. (Carb records mint CONFIRMED — never in-flight.)
    private var inFlightEventIDs: Set<UUID> = []
    /// The single in-flight uncertainty being chased (mirrors the crude
    /// UncertainCommandRecord — one at a time; a NEW programming command destroys the
    /// verdict evidence and the conservative record stands, per d27a40c7 semantics).
    private var pendingUncertainEventID: UUID?
    private var chaseWorkItem: DispatchWorkItem?
    private var resendWorkItem: DispatchWorkItem?
    /// #67: when the LIVE hand-back gives up waiting for the phone's ack and resumes on the
    /// watch. Set at the End tap (beginHandback), cleared on ack/cancel/timeout. Nil for a
    /// recovered/revoke drain (no local loan to resume — those keep resending).
    private var handbackDeadline: Date?
    /// When the CURRENT hand-back began — the anchor for the reclaim progress bar (2026-08-04).
    /// Set and cleared in lockstep with `handbackDeadline`, which already marks exactly the
    /// hand-back's lifetime, so there is no second lifecycle to keep in step.
    private var handbackStartedAt: Date?
    /// When the FINAL (released=true) offer was sent — the clock the ack is racing.
    /// Splits "Reclaiming…" into the two intervals we could not previously tell apart:
    /// waiting for the phone's permission, versus iOS actually freeing the pod's BLE slot.
    private var finalOfferSentAt: Date?
    private var requestTimeoutWork: DispatchWorkItem?
    /// Surfaced on the glance idle screen after a failed/timed-out start, so the user
    /// sees WHY instead of a silent return to idle.
    private(set) var lastIdleNote: String?
    /// OBS-1 (audit 2026-07-20): a start (requested/takingOver) was in flight when the
    /// app was killed or replaced. init() can't send — `send` is wired afterward — so
    /// it stashes the epoch here and drainRecoveredIfNeeded() (post-wiring) fails the
    /// takeover to the phone, which would otherwise strand in .grantOffered.
    private var pendingInterruptedTakeoverEpoch: Int?
    /// Manual bounded suspend end (R3/R4); a running bounded suspend survives
    /// hand-back (46f16d01) and reports mode .suspended.
    private var manualSuspendEnd: Date?

    private enum Keys {
        static let phase = "PodLoanWatchController.phase"
        static let epoch = "PodLoanWatchController.epoch"
        static let pumpRawValue = "PodLoanWatchController.pumpManagerRawValue"
    }

    init(loopManager: WatchLoopManager, journal: LoanEventJournal = LoanEventJournal()) {
        self.loopManager = loopManager
        self.journal = journal
        self.phase = Phase(rawValue: UserDefaults.standard.string(forKey: Keys.phase) ?? "") ?? .idle
        self.epoch = UserDefaults.standard.object(forKey: Keys.epoch) as? Int

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
                // OBS-1 (field epochs 21 & 27): a start was in flight at kill/replace.
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

    private func issueSessionEndedAlert() {
        loopManager.issueAlert(Alert(
            identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "sessionEnded"),
            foregroundContent: Alert.Content(title: "Session Ended", body: "The watch loop session ended. Records are being returned to the phone.", acknowledgeActionButtonLabel: "OK"),
            backgroundContent: Alert.Content(title: "Session Ended", body: "The watch loop session ended. Records are being returned to the phone.", acknowledgeActionButtonLabel: "OK"),
            trigger: .immediate))
    }

    // MARK: - Incoming (wired from the WCSession delegate at integration)

    func handleIncoming(userInfo: [String: Any]) {
        queue.async { self.handleIncomingOnQueue(userInfo: userInfo) }
    }

    private func handleIncomingOnQueue(userInfo: [String: Any]) {
        let message: LoanMessage?
        do {
            message = try LoanMessage.decode(fromTransport: userInfo)
        } catch {
            // §2.9: never ack-and-drop. Nack + loud surfacing.
            os_log("Undecodable v2 payload: %{public}@", log: log, type: .fault, String(describing: error))
            sendMessage(.nack(ProtocolNack(seenVersion: nil)))
            issueProtocolAlert(body: "The phone sent a message this watch build cannot read. Update one of the builds.")
            return
        }
        guard let message = message else { return }  // not a v2 payload

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
            issueProtocolAlert(body: "The phone could not read this watch's messages. Update one of the builds.")
        case .denied(let denied):
            // The phone refused — show why instead of hanging on "requesting…".
            requestTimeoutWork?.cancel()
            if phase == .requested || phase == .idle {
                phase = .idle
                lastIdleNote = denied.reason
            }
            SportLog.event("loan", "DENIED by phone — \(denied.reason)")
        case .diag(let d):
            SportLog.event("phone", d.text)   // #35: phone hand-back breadcrumb → iCloud mirror
        case .request, .takeoverComplete, .takeoverFailed, .doseRecordBatch, .handbackOffer, .statusReport:
            os_log("Ignoring phone-bound message kind on watch", log: log, type: .default)
        }
    }

    // MARK: - Request / Grant / Takeover (§2.1-2.3)

    func requestLoan(watchBuild: String) {
        #if targetEnvironment(simulator)
        // Default in the sim: run the REAL loan protocol against the phone's simulated
        // Omnipod (OmniPumpManager fakes pod comms in-sim). The watch-only fake-flow driver
        // stays available behind a flag for when no paired phone is running.
        // #61 (2026-08-08): log the flag VALUE at the decision — on 2026-08-07 a fresh container
        // with the flag absent still drove the fake path, which contradicts this gate as read;
        // the suspect is a stale embedded binary, and this line settles it either way.
        let simFakeFlow = UserDefaults.standard.bool(forKey: "sim.fakeLoanFlow")
        SportLog.event("loan", "Start (sim): sim.fakeLoanFlow=\(simFakeFlow) — \(simFakeFlow ? "FAKE flow driver" : "REAL loan protocol")")
        if simFakeFlow { simDriveStart(); return }
        #endif
        queue.async {
            guard self.phase == .idle else {
                SportLog.event("loan", "Start ignored — not idle (phase \(self.phase.rawValue))")
                return
            }
            self.phase = .requested
            self.attemptStartedAt = Date()
            self.lastIdleNote = nil
            SportLog.event("loan", "REQUEST sent (build \(watchBuild)) — awaiting grant")
            self.sendMessage(.request(LoanRequest(watchBuild: watchBuild)))

            // No grant in 25 s → the phone refused, is busy, or isn't reachable. Return
            // to idle with a visible reason instead of hanging on "requesting…".
            self.requestTimeoutWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.phase == .requested else { return }
                self.phase = .idle
                self.lastIdleNote = NSLocalizedString("No response from iPhone — check the phone (loan refused, or busy) and try again.", comment: "Glance: loan request timed out")
                SportLog.event("loan", "REQUEST TIMED OUT — no grant in 25s (phone refused / busy / unreachable)")
            }
            self.requestTimeoutWork = work
            self.queue.asyncAfter(deadline: .now() + 25, execute: work)
        }
    }

    #if targetEnvironment(simulator)
    // MARK: - Simulator flow driver (task #61) — NEVER compiled into a device build.
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
            self.attemptStartedAt = Date()
            self.phase = .requested
            self.queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.phase == .requested else { return }
                self.attemptStartedAt = Date()          // reset anchor for the ~10s takeover bar
                self.phase = .takingOver
            }
            self.queue.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                guard let self, self.phase == .takingOver else { return }
                self.epoch = (self.epoch ?? 0) + 1
                self.phase = .active
                self.loopManager.setClosedLoopEnabled(false)   // R23: loans start OPEN
                self.simStartGlucoseFeed()                     // stage 2: feed phone-sim BG → real loop
            }
        }
    }

    private func simDriveHandback() {
        queue.async {
            guard self.phase == .active else { return }
            SportLog.event("sim", "SIM hand-back — draining to idle")
            self.handbackRequested = true
            self.queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
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

        /// STRANDED-PHASE FIX (backlog triage, 2026-08-06). `requestTimeoutWork?.cancel()` used to
        /// run as the FIRST line — before any validation. Every rejection below then returned
        /// without restoring `phase`, so a rejected grant left the controller at `.requested`
        /// with no timeout pending and nothing to move it. `requestLoan` guards on
        /// `phase == .idle` (:283), so from then on Start was a silent no-op: Sport Mode
        /// unstartable until the app was relaunched or debugReset was tapped.
        ///
        /// Cancelling here — after the phase check, before the rejections — keeps the original
        /// intent (a grant that we are going to ACT on stops the timeout) while every rejection
        /// path goes through `rejectGrant`, which restores `.idle` so the timeout's job is done
        /// by the state instead.
        guard phase == .idle || phase == .requested else {
            SportLog.event("loan", "grant ignored — wrong phase (\(phase.rawValue))")
            return
        }
        requestTimeoutWork?.cancel()

        /// Every rejection must leave the controller startable. Logs the reason, tells the phone
        /// where the protocol expects it, and returns to .idle.
        func rejectGrant(_ reason: String, notifyPhone: Bool) {
            SportLog.event("loan", "grant REJECTED — \(reason); returning to idle so Start works again")
            if notifyPhone {
                sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: reason)))
            }
            phase = .idle
        }
        guard Date() < grant.expiresAt else {
            // Row 2: a late grant self-rejects; the phone's T1 already reclaimed.
            rejectGrant("grant expired", notifyPhone: true)
            return
        }
        if let known = epoch, grant.epoch <= known {
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

        // Therapy settings snapshot: the ONLY dosing limits (R1/R16); frozen for the
        // loan (spec §8). WS4a (ruled 2026-07-19): validate COMPLETENESS at the loan
        // boundary and refuse with a stated reason — an incomplete config must be a
        // legible denial, not a per-cycle configurationError mid-session (the REG-3
        // failure class: builds 113-116 lost the schedules in serialization and died
        // silently every cycle at the party). Validated BEFORE journal.begin so a
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
            phase = .idle
            lastIdleNote = String(format: NSLocalizedString("Can't start: %@ didn't arrive from the phone. Check therapy settings and try again.", comment: "Glance: grant refused for incomplete settings (1: missing field)"), missing)
            SportLog.event("loan", "grant REFUSED — therapy settings incomplete (\(missing))")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "therapy settings incomplete: \(missing)")))
            return
        }

        do {
            try journal.begin(epoch: grant.epoch)
        } catch {
            // An undrained prior loan must drain first — refuse, never clobber.
            rejectGrant("undrained prior loan must drain first", notifyPhone: true)
            return
        }

        epoch = grant.epoch
        phoneSupportsInterimHandback = grant.supportsInterimHandback ?? false   // WS1 REAL-3 gate
        phoneSupportsOverrideRecords = grant.supportsOverrideRecords ?? false    // #68B skew gate
        chaseWorkItem?.cancel()         // round-3 liveness: fresh loan, no chase residue
        pendingUncertainEventID = nil
        inFlightEventIDs = []
        handbackRequested = false
        finalOfferSent = false
        // R24 bar anchor: ALWAYS re-anchor at grant. The grant round-trip is WCSession
        // roulette (0.5s to 15s observed on hardware) while the takeover itself is the
        // predictable part (~5s with the scan fix) — so the determinate bar measures
        // the takeover only; the request stage renders indeterminate. This also keeps
        // a late queued grant (after the 25s timeout) from inheriting a dead anchor.
        attemptStartedAt = Date()
        lastTakeoverReadAt = nil          // #86: fresh ladder, fresh stall measurement
        takeoverMaxReadGap = 0
        PodLoanConnectClock.reset()       // #86: connect/disconnect stamps describe THIS attempt
        // #86: stamp every BLE edge with the execution state it fired in. The flapping has only
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
        // R23 OVERTURNED 2026-08-04 (Jeremy): "if phone closed, watch closed. If phone open,
        // watch open." R23 reset every loan to OPEN/advisory and its amendment went further,
        // removing any influence of the phone's mode on the wrist; both are superseded — the
        // reason is intuitiveness for a second user, not a change of confidence in the
        // fail-safe, so a broader release may revert to always-open.
        //
        // Frozen at the grant like the therapy settings. nil (a phone predating the field)
        // → false, i.e. exactly the old start-OPEN rule, so build skew degrades to the
        // previous behavior rather than to an unintended closed loop.
        loopManager.setClosedLoopEnabled(grant.phoneClosedLoopEnabled ?? false,
                                         reason: grant.phoneClosedLoopEnabled == nil
                                            ? "(older phone sent no loop mode — defaulting open)"
                                            : "inherited from the phone at grant")
        // INSTRUMENTATION ONLY (#45): stash the phone's prediction decomposition + echo it into the
        // log, BEFORE the takeover read / first prediction refresh, so [predict-diff] and [iob-diff]
        // Leg 1 have the phone baseline in hand. The serial dataAccessQueue guarantees the stash
        // lands before the first diff.
        ingestPredictionSnapshot(grant)

        // Log what the watch ACTUALLY received. The grant validates completeness but has
        // never recorded the VALUES, so verifying any prediction against real settings
        // meant asking Jeremy or back-solving them from observed effects — and on
        // 2026-07-22 that inference was wrong (derived ISF 90 / CR 19 against actual
        // 70 / 15, because the insulin-effect window includes pre-loan dose history, not
        // just the loan odometer). Two settings-transfer bugs have already hidden here
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
            phase = .idle
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
        // #72: the grant's LIVE temp record (still-delivering at takeover, omitted from the
        // seed) gates and parameterizes the re-arm — it corroborates that the PHONE's books
        // also believe the temp is running (guards the stale-C5-signature corner across
        // back-to-back loans), and its endDate is the only way to restore a 0 U/hr temp's span.
        let liveTempRecord = grant.seedDoseEntries(finishedBy: Date()).live.first { $0.type == .tempBasal }
        let scanning = manager.podLoanBeginTakeover(liveTempStart: liveTempRecord?.startDate,
                                                    liveTempEnd: liveTempRecord?.endDate)
        SportLog.event("loan", "pump rebuilt — \(scanning ? "scanning for the pod by address" : "no pod address!") for takeover")
        // #72: beginTakeover re-armed the C5-cancelled inherited temp (if any) so THIS watch
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
        // 2026-07-15 pod-side timeout ruling (~40s) — instead of failing on the first,
        // pre-connection read.
        attemptTakeoverRead(manager: manager, grant: grant, attempt: 0)
    }

    /// Up to 14 reads while the pod's BLE session establishes — fast when the session-established
    /// event drives them (no fixed period), up to ~112s if every read falls through to the 8s
    /// backstop (was "~40s (14 × 3s)" before the event-driven rework; that number no longer
    /// applies to either path).
    /// #86 (2026-08-03): the takeover waits for the pod stack's own session-established EVENT
    /// instead of inferring readiness from a polled CBPeripheral.state.
    ///
    /// The pre-stock build was trivially reliable here because it did exactly this: it parked
    /// the takeover completion and finished on podCommsDidEstablishSession. The from-stock
    /// rewrite replaced that with a 3 s poll of peripheral.state — read from the loan
    /// controller's queue, where that property is not valid. Field 2026-08-03 epoch 143, app
    /// running perfectly (max inter-read gap 3.3 s), the reads contradicted the connect
    /// callbacks every time: read 4 reported "disconnected" 0.3 s after didConnect, read 9
    /// "connecting" 0.5 s after didConnect. bleRunSession bails on that stale value, so no byte
    /// was ever sent and the pod hung up on the silent link — seven connections, 3.5-3.6 s each.
    ///
    /// So: the event now drives the retry, and the 3 s metronome becomes a slow backstop. A
    /// short debounce after the event lets the peripheral state propagate to our queue before
    /// the read, since the guard downstream still consults it.
    ///
    /// Deliberately NOT applied to the E4 steady-state reclaim, which is 40-for-40 in the field
    /// precisely because it never re-enters this configuration path. Takeover-only, which is
    /// the "special protocol for the initial takeover" ruling.
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
                self.queue.asyncAfter(deadline: .now() + 0.25) { action() }   // the action still lives
            }
        }
    }

    /// `driver` says WHY this particular read fired: "initial" (attempt 0), "event" (the pod
    /// stack's session-established callback ran it early), or "backstop" (the 8s timer fired with
    /// no event). #86 max-instrumentation pass (2026-08-07): before this, the fast/slow split
    /// documented in the takeover-timing analysis (read count 2-5 => ~3s/read, 6+ => ~8s/read,
    /// exactly the backstop period) had to be INFERRED by cross-referencing the "session
    /// ESTABLISHED" log line against the read line that followed it. Stamping the driver directly
    /// on every read line makes that split a single grep instead of a reconstruction.
    private func attemptTakeoverRead(manager: OmniPumpManager, grant: LoanGrant, attempt: Int, driver: String = "initial") {
        let maxAttempts = 14
        manager.podLoanReadStatus { [weak self] success in
            guard let self = self else { return }
            self.queue.async {
                guard self.phase == .takingOver, self.epoch == grant.epoch else {
                    // OBS-1 (verdict completeness): a takeover must never vanish without a verdict.
                    // This fires when the in-flight ladder for grant.epoch was superseded — the user
                    // re-tapped Start (phase left .takingOver) or a newer grant bumped the epoch.
                    // Log-only (AUDIT_SYNTHESIS sanctions a "superseded" line, not a behavior change).
                    SportLog.event("loan", "TAKEOVER SUPERSEDED — epoch \(grant.epoch) abandoned mid-ladder (now phase \(self.phase.rawValue), epoch \(self.epoch.map(String.init) ?? "nil"))")
                    return
                }
                // CRITICAL (audit 2026-07-20): the grant's ~5-min lease is validated
                // once at intake, but this ladder can run FAR past its nominal ~40s
                // when the app is suspended mid-ladder — field epoch 27 ran 23 min
                // because a TestFlight update froze the queue timers, which then
                // drained late on wake. Past the lease, the phone is entitled to have
                // T1-reclaimed the pod; flipping .active here would put TWO controllers
                // on one pod. Re-check the lease every iteration and abort BEFORE
                // honoring a successful read — expiry outranks a good status.
                guard Date() < grant.expiresAt else {
                    self.teardownPump()
                    self.phase = .idle
                    self.lastIdleNote = NSLocalizedString("Sport Mode start expired before the pod answered. Tap Start to try again.", comment: "Glance: grant lease expired mid-takeover")
                    SportLog.event("loan", "TAKEOVER ABORTED — grant lease expired mid-takeover after \(attempt + 1) read(s), epoch \(grant.epoch)")
                    self.sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "grant expired mid-takeover")))
                    return
                }
                if success, let delivered = manager.podLoanInsulinDelivered {
                    self.deliveredAtTakeover = delivered
                    self.phase = .active
                    self.loopManager.pumpManager = manager
                    self.loopManager.loanDoseRecorder = self
                    self.onLoanActiveChanged?(true)
                    let takeoverSecs = self.attemptStartedAt.map { Date().timeIntervalSince($0) } ?? -1
                    SportLog.event("loan", String(format: "ACTIVE — epoch %d, pod taken after %d read(s) in %.1fs [takeover-timing], odometer %.2f U, final read driver=%@ · %@",
                                                  grant.epoch, attempt + 1, takeoverSecs, delivered, driver, RuntimeStateLog.snapshot()))
                    self.sendMessage(.takeoverComplete(TakeoverComplete(epoch: grant.epoch, firstPodStatus: self.currentPodStatus())))
                    // #69: refresh the glance eventual + IOB from the just-seeded insulin/carbs/
                    // glucose NOW (display-only, no enact) so the prediction reflects the seeded
                    // carbs at takeover instead of the stale pre-loan value until the first G7
                    // reading drives a full cycle. The seeds completed well before this point.
                    self.loopManager.refreshPredictionForGlance()
                    // E4 STAGE 1 (task #40, 2026-07-21): time-separate the radios. The
                    // takeover is done and the initial status is read, so the pod BLE
                    // connection isn't needed until the next dose. Release it (orphan
                    // the pod — it runs its last basal natively; keys/state untouched)
                    // so G7 acquisition has the watch's radio uncontested. STAGE 1 is
                    // OPEN-LOOP validation: no reconnect-to-dose choreography yet, so
                    // keep the loop OPEN. If G7 catch recovers toward the standalone
                    // 94% (E1), Stage 2 adds the per-dose reclaim→enact→release.
                    if UserDefaults.standard.bool(forKey: "g7.e4ReleasePod") {
                        // E4 v2 (field 2026-07-21): releasing AT takeover broke G7
                        // entirely — a "connects-but-can't-read" loop, the pod cancel
                        // left it stuck .disconnecting and poisoned the shared BLE
                        // budget (the same watchOS teardown demon that causes the
                        // missed windows). DEFER the release: take the free first read
                        // with the pod connected (Jeremy's "first connection is always
                        // good"), then cancel a SETTLED, idle connection ~90s later,
                        // which should tear down cleaner than a fresh one.
                        SportLog.event("loan", "E4: pod release DEFERRED +90s (v2 — release a settled connection after first reads)")
                        let scheduledReleaseAt = Date().addingTimeInterval(90)
                        self.queue.asyncAfter(deadline: .now() + 90) { [weak self] in
                            guard let self = self, self.phase == .active, self.epoch == grant.epoch,
                                  UserDefaults.standard.bool(forKey: "g7.e4ReleasePod") else { return }
                            // Same before/after capture as the post-dose release. This is
                            // the one that fired 3m36s LATE on 2026-07-22 (app suspended),
                            // by which point the pod had self-disconnected — so we cancelled
                            // nothing and wedged the peripheral. `before` says outright
                            // whether the link was still alive when we pulled it, and the
                            // scheduled-vs-actual delay says whether runtime was stolen.
                            let before = manager.podLoanConnectionStateDescription
                            let lateBy = Date().timeIntervalSince(scheduledReleaseAt)
                            // #72: ORPHAN, not release — E4 drops the BLE link but the watch
                            // remains the controller; the C5 record-close in releaseConnection()
                            // is handover accounting and was silently truncating the running temp
                            // at every E4 release (killing live IOB tracking ~90s in).
                            manager.podLoanOrphanConnection()
                            self.lastPodLinkContact = Date()
                            SportLog.event("loan", String(format: "E4: pod BLE released (+90s deferred, %.0fs late) — state was %@ at cancel%@",
                                                          lateBy,
                                                          before,
                                                          before == "connected" ? "" : " ** cancelled a link that was ALREADY GONE **"))
                            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                                guard let self = self, let manager = self.pumpManager else { return }
                                let after = manager.podLoanConnectionStateDescription
                                SportLog.event("loan", "E4: post-release pod state \(after)\(after.hasPrefix("DISCONNECTING") ? " ** WEDGED — poisoning signature **" : "")")
                            }
                        }
                    }
                } else if attempt + 1 < maxAttempts {
                    if attempt == 0 {
                        SportLog.event("loan", "connecting to pod… (BLE session establishing; typically ~17s, budget ~40s)")
                    }
                    // #42 diagnosis: log the pod BLE state each failed read so "unreachable"
                    // shows WHY — stuck disconnected (pod not advertising / still held by the
                    // phone) vs connecting-but-no-response.
                    let readElapsed = self.attemptStartedAt.map { Date().timeIntervalSince($0) } ?? -1
                    // #86: measure the inter-read gap. Backstop-driven reads land ~8 s apart (event-
                    // driven reads can be much faster) — a gap well past 8 s is suspended-app time,
                    // not pod silence.
                    let readNow = Date()
                    if let prev = self.lastTakeoverReadAt {
                        self.takeoverMaxReadGap = max(self.takeoverMaxReadGap, readNow.timeIntervalSince(prev))
                    }
                    self.lastTakeoverReadAt = readNow
                    // #86: probe the NEXT inter-read interval directly, so a stalled ladder says
                    // whether the OS deferred our timer or the read itself blocked. Only on the
                    // first few reads — this is a meter, not a metronome.
                    if attempt < 3 { RuntimeStateLog.probeTimerDeferral("ladder-read\(attempt + 1)") }
                    // #86: pair OUR observation with the BLE stack's own timestamps. If didConnect
                    // reads +12s while this poll is landing at +68s, the link was up and only our
                    // deferred timer was late — fix the ladder. If didConnect says "never", the
                    // radio genuinely hasn't connected — fix the keepalive. The poll alone cannot
                    // distinguish those, which is why this line exists.
                    SportLog.event("loan", String(format: "takeover read %d/%d driver=%@ (+%.1fs) — pod BLE state %@ · %@ · %@",
                                                  attempt + 1, maxAttempts, driver, readElapsed,
                                                  manager.podLoanConnectionStateDescription,
                                                  PodLoanConnectClock.summary(since: self.attemptStartedAt),
                                                  RuntimeStateLog.snapshot()))
                    // #86: the retry is now a cancellable work item so the session-established
                    // event can run it IMMEDIATELY. The timer is a backstop at 8 s (was a 3 s
                    // metronome) — with the event driving progress, polling faster only burns
                    // the attempt budget against a stale state read.
                    let fireRetry: (String) -> Void = { [weak self] nextDriver in
                        guard let self = self else { return }
                        self.takeoverRetryAction = nil
                        self.takeoverBackstop = nil
                        guard self.phase == .takingOver, self.epoch == grant.epoch else {
                            // OBS-1: the ladder was superseded during the 3s inter-attempt wait
                            // (re-Start or a newer epoch). Emit the verdict instead of vanishing.
                            SportLog.event("loan", "TAKEOVER SUPERSEDED — epoch \(grant.epoch) abandoned between reads (now phase \(self.phase.rawValue), epoch \(self.epoch.map(String.init) ?? "nil"))")
                            return
                        }
                        self.attemptTakeoverRead(manager: manager, grant: grant, attempt: attempt + 1, driver: nextDriver)
                    }
                    self.takeoverRetryAction = { fireRetry("event") }
                    let backstop = DispatchWorkItem { fireRetry("backstop") }
                    self.takeoverBackstop = backstop
                    self.queue.asyncAfter(deadline: .now() + 8, execute: backstop)
                } else {
                    self.teardownPump()
                    self.phase = .idle
                    let failSecs = self.attemptStartedAt.map { Date().timeIntervalSince($0) } ?? -1
                    // #86 (2026-07-31, ORIGINAL finding): the takeover ladder ran with NO keepalive
                    // — startSoak() only fired once the loan went ACTIVE, which needs a takeover
                    // that already succeeded — so the whole connect phase was unprotected and, on
                    // low battery, watchOS suspended the app mid-ladder. Observed 2026-07-31, epochs
                    // 81-83 at 15%: reads stalled 86 s and 70 s, each resuming only on a wrist raise,
                    // and three takeovers failed in a row while the pod was fine. Keeping this
                    // account rather than deleting it — see Jeremy's standing "don't lose the
                    // narrative" instruction — but it is HISTORY, not current behavior: the 2026-08-06
                    // keepalive-ownership refactor wired `onTakeoverRadioHold` to the same
                    // WorkoutKeepalive that soak/handback use (StockLoopSession.swift), so from
                    // build ~244 on, .takingOver DOES hold runtime for the whole ladder. The
                    // `takeoverMaxReadGap > 20` heuristic below still catches a suspension if the
                    // keepalive itself fails to start/renew (HK auth denied, session error) — the
                    // #86 max-instrumentation pass (2026-08-07) put `RuntimeStateLog.snapshot()` on
                    // every read line specifically so that question no longer needs inference: if a
                    // future stall shows "keepalive running(takeover)" on every read, the keepalive
                    // held and the stall is something else; if it shows "keepalive off" or
                    // "DENIED"/"FAILED", the keepalive itself is the failure.
                    //
                    // The old note blamed the pod ("check the pod is nearby and awake") and quoted
                    // a 40 s timeout that no longer matches the ~180 s ladder. Blaming the pod for
                    // a suspended app sends the user to the wrong place — so say which one it was.
                    let stalled = self.takeoverMaxReadGap > 20
                    if stalled {
                        // Say ONLY what was measured. An earlier draft of this note told the user
                        // to charge; the field data refutes that — epoch 80 took over fine at 20%
                        // while the wrist was up, and epoch 78 ran unsuspended at 65% under the
                        // same pre-08-06 no-keepalive condition. What tracks the outcome is whether
                        // anything kept the app awake during the connect, not the battery level.
                        // Guessing a remedy is how the previous note ended up blaming a healthy pod.
                        self.lastIdleNote = String(format: NSLocalizedString(
                            "Sport Mode didn't start — the watch app stopped running mid-connect (%@). Your phone still has the pod. Keep the watch awake — wrist up or screen on — and try again.",
                            comment: "Glance: takeover failed because the app was suspended"), batteryTag())
                    } else {
                        // 2026-08-05, epoch 221: root-caused, and it is NOT the pod. Every connect
                        // returned CBErrorDomain#11 (connectionLimitReached) — a limit on THIS
                        // APP's CoreBluetooth slots, not a busy or sleeping pod. The phone had
                        // released cleanly (its own log: `GRANT +3s … linkUp=false`) and the pod's
                        // census held one disconnected device. The slot was ours: the G7 client
                        // leaves an armed pending connect alive across a takeover
                        // and a pending connect reserves a slot. Hence the
                        // gap signature — re-takeovers at 12/14/15 s all succeeded, the one after a
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
                    SportLog.event("loan", String(format: "TAKEOVER FAILED — %@ after %d reads in %.1fs [takeover-timing], max inter-read gap %.1fs (event-driven; 8s backstop when no event fires), %@, final BLE state %@, %@, %@, epoch %d",
                                                  stalled ? "ladder STALLED (our polling was deferred; see cb: for whether the link was up)" : "pod unreachable",
                                                  maxAttempts, failSecs, self.takeoverMaxReadGap, batteryTag(),
                                                  manager.podLoanConnectionStateDescription,
                                                  PodLoanConnectClock.summary(since: self.attemptStartedAt),
                                                  RuntimeStateLog.snapshot(), grant.epoch))
                    // The reason string is rendered verbatim in the PHONE's notification body
                    // ("The watch could not take the pod (…). The phone kept it."), so it carries
                    // the same obligation as the wrist note above: do not blame the pod for a
                    // connection slot we were holding ourselves.
                    self.sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: stalled ? "watch app suspended mid-takeover" : "couldn't establish the pod link")))
                }
            }
        }
    }

    // MARK: - E4 Stage 2 (task #40): reconnect the orphaned pod to dose, then re-release

    /// Wired to WatchLoopManager via StockLoopSession. Called just before a dose while
    /// E4 time-separation has the pod orphaned. completion(true) = pod connected & ready;
    /// (false) = couldn't reconnect in the bounded window → caller SKIPS the dose (pod
    /// keeps running its baseline). Uses podLoanReadStatus as the connection probe —
    /// idempotent and exactly what the takeover ladder uses, so no double-dose risk.
    /// When the pod link was last confirmed alive (successful reclaim read or release).
    /// The reclaim succeeded twice and then failed five times on 2026-07-22 with no visible
    /// difference; idle duration is one of the few candidate discriminators left, so it is
    /// measured rather than eyeballed from timestamps.
    private var lastPodLinkContact: Date?
    /// Highest epoch the phone has ever revoked — survives an unmatched revoke (see handleRevoke).
    private var lastRevokedEpoch: Int?

    /// #81 (2026-07-30 forensics): the reclaim must not start INSIDE the G7's connect+auth
    /// burst. Across 140 ladders spanning five days, the single discriminator is how much
    /// live G7 GATT session remains when the reclaim starts: >1s remaining → 0/45 success;
    /// closing within 1s → 62/69; no link → 23/26 (p ≈ 2.7e-27). A G7 SCAN in flight is
    /// harmless (4/4) — the contended resource is the connection initiator, not the scanner.
    ///
    /// It regressed via two changes that only co-occurred on 2026-07-30: the loop trigger
    /// moved to the phone-BG fallback (fires ~1s AFTER G7 connect, i.e. mid-handshake, where
    /// the watch's own glucose packet used to fire at handshake END), and #54 made scan-adopt
    /// primary (a one-shot scan is contention-sensitive where the old queued pending-connect
    /// with its read-6 escalation was not). Jul 25-26, live sensor, old paths: 59/59.
    ///
    /// The enact path already waits (WatchLoopManager :1822) — but the "pump data N min old"
    /// pre-cycle refresh reclaims BEFORE any arbitration, which is the caller that failed all
    /// day. Gating here covers every caller.
    ///
    /// #97: is the pod's standing auto-connect bid currently RELEASED? E4-OFF assumes the pod
    /// is held; after an E4 release has disarmed the bid, that assumption is false and nothing
    /// re-arms it. Lock-free read of the manager's own flag; safe from any thread.
    var podConnectionIsReleased: Bool {
        return pumpManager?.isConnectionReleased ?? false
    }

    func reclaimPodForDose(_ completion: @escaping (Bool) -> Void) {
        queue.async {
            guard self.phase == .active, let manager = self.pumpManager else { completion(false); return }
            let idle = self.lastPodLinkContact.map { Date().timeIntervalSince($0) }
            SportLog.event("loan", String(format: "E4: reclaim starting — pod BLE state %@, released=%@, idle %@",
                                          manager.podLoanConnectionStateDescription,
                                          manager.isConnectionReleased ? "yes" : "no",
                                          idle.map { String(format: "%.0fs", $0) } ?? "unknown"))
            guard manager.isConnectionReleased else {
                self.lastPodLinkContact = Date()
                completion(true)
                return
            }   // still connected — nothing to do
            // NO RADIO STAND-DOWN, and nothing left to stand down. #82 and R26 both existed to
            // stop OUR G7 reader from occupying the radio during the pod's ladder — #82 was
            // retired by #84 for stranding the radio when the app suspended mid-ladder, and R26's
            // radio half retired with the reader itself. The CGM is now stock G7SensorKit riding
            // the Dexcom watch app's session; this app never drives the sensor radio, so the pod
            // ladder has no contender to yield to or hold off.
            SportLog.event("loan", "E4: reclaiming pod to dose (scan-adopt primary, #54)")
            manager.reclaimConnection()
            // #54 (build ~178): scan-adopt is the PRIMARY reclaim, not a mid-ladder fallback.
            // Field data (build 157, overnight 44/44): the bare pending-connect "won" a reclaim
            // only ~2% of the time — an E4-orphaned pod self-disconnects ~3 min after last contact,
            // and the gentle bid is a coin-flip against a self-disconnected pod (caught a 578s-idle
            // pod once, missed 518s- and 259s-idle pods entirely). The scan-adopt escalation carried
            // ~98% of reclaims anyway, just 15s later — that 15s IS the 30-40s takeover Jeremy saw.
            // Arm the fresh-central address scan up front; recreateCentral's poweredOn handler
            // re-connects the bare bid too, so both paths race from t=0. The read ladder below is
            // the success probe; the release path cancels an unfinished scan (cancelLoanScan).
            manager.podLoanEscalateReclaim()
            self.attemptReclaimRead(manager: manager, attempt: 0, completion: completion)
        }
    }

    /// Budget MATCHES the takeover ladder (14 reads / ~40s), and for the same reason.
    ///
    /// This was 8 reads / ~16s on the premise that "a bonded pod reconnect is seconds".
    /// That premise only holds for a WARM pod: the overnight E5 run reclaimed every
    /// 5 minutes and succeeded 84/84 — but in 2-4 reads, always well inside 16s. It
    /// silently validated the warm case only.
    ///
    /// Field 2026-07-22 11:17-11:53 (build 149) showed the cold case: with the pod
    /// E4-released and then idle 8+ minutes it self-disconnects (~3 min after last
    /// contact), and every reclaim failed — 8/8 — while the TAKEOVER of the very same
    /// pod minutes earlier succeeded in 4 reads on its 40s budget. So the pod was
    /// reachable throughout; the reclaim was simply giving up first. Each failure left
    /// pump data unrefreshed, so pumpDataTooOld re-deadlocked the loop with the age
    /// climbing 15 -> 45 min.
    ///
    /// Radio cost is acceptable: the reclaim starts immediately after a reading, and
    /// the next G7 window is ~5 min out, so even a full 40s leaves ~4 min of margin —
    /// and E5 already proved a pod exchange every single cycle costs 0% catch rate.
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
                    self.lastPodLinkContact = Date()
                    SportLog.event("loan", "E4: pod reconnected for dose (after \(attempt + 1) read(s)) — state \(manager.podLoanConnectionStateDescription)")
                    completion(true)
                } else if attempt + 1 < maxAttempts {
                    // Per-attempt visibility. `podLoanReadStatus` returns a bare Bool, so
                    // 14 failed reads said only "it didn't work" — three separate theories
                    // (cold pod, suspension, spurious release) were raised and falsified
                    // against that silence on 2026-07-22. Report what the BLE layer
                    // actually sees each attempt: a peripheral stuck .disconnecting (2),
                    // one never reaching .connected (0/1), and a connected pod failing its
                    // status read are three different bugs that looked identical.
                    SportLog.event("loan", "E4: reclaim read \(attempt + 1)/\(maxAttempts) failed — pod BLE state \(manager.podLoanConnectionStateDescription), released=\(manager.isConnectionReleased)")
                    // #54 (build ~178): scan-adopt is now armed UP FRONT in reclaimPodForDose, so the
                    // whole ladder rides the takeover-grade path from read 0 — no mid-ladder escalation.
                    // The fresh central's poweredOn handler races the bare bid and the address scan;
                    // these reads just poll for the winner. (Was: bare-connect first, escalate at read 6,
                    // which burned ~15s on the ~98% of reclaims the bare bid never won.)
                    self.queue.asyncAfter(deadline: .now() + 2) {
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

    /// Re-release the pod after a dose — but only after a SETTLE delay. The v1 lesson
    /// (build 139): cancelling a freshly-established connection poisons the BLE stack;
    /// the connection has only been up for the dose (~seconds), so give it a moment to
    /// settle before releasing (mirrors the +90s deferred release at takeover).
    func releasePodAfterDose() {
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self, self.phase == .active, let manager = self.pumpManager,
                  manager.isConnectionReleased == false,
                  UserDefaults.standard.bool(forKey: "g7.e4ReleasePod") else { return }
            // Capture the peripheral BEFORE and AFTER the cancel. The E4-v1 poisoning
            // signature is a peripheral left in .disconnecting, and on 2026-07-22 we could
            // only infer it minutes later from a central recreate. Cancelling a link the pod
            // has ALREADY dropped is the suspected trigger, so "what state were we in when
            // we cancelled" is the load-bearing fact — and a state that is not .connected
            // going in means there was nothing to cancel.
            let before = manager.podLoanConnectionStateDescription
            // #72: ORPHAN, not release — same as the deferred takeover release: E4 keeps the
            // watch as controller, so the running temp's record must NOT close here.
            manager.podLoanOrphanConnection()
            self.lastPodLinkContact = Date()
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self, let manager = self.pumpManager else { return }
                let after = manager.podLoanConnectionStateDescription
                SportLog.event("loan", "E4: pod re-released after dose (+12s settle) — state \(before) -> \(after) (+3s)\(after.hasPrefix("DISCONNECTING") ? " ** WEDGED — this is the poisoning signature **" : "")")
            }
        }
    }

    /// INSTRUMENTATION (#69 wipe-audit): how many doses the sport DoseStore holds in the IOB window,
    /// logged at a labeled point in the wipe-then-seed. The seed writes on top, so a nonzero count
    /// AFTER the wipe is a prior-epoch survivor (the takeover-IOB-inflation bug). Passes the count to
    /// `then` so the caller can gate a force-repurge on it.
    private func auditDoseCount(_ label: String, at t: Date, _ then: @escaping (Int) -> Void) {
        let ds = loopManager.doseStore
        let start = t.addingTimeInterval(-Swift.min(ds.longestEffectDuration, .hours(8)))
        ds.getNormalizedDoseEntries(start: start, end: t) { result in
            let n: Int
            if case .success(let doses) = result { n = doses.count } else { n = -1 }
            SportLog.event("wipe-audit", "\(label): DoseStore holds \(n) dose(s)")
            then(n)
        }
    }

    /// 16 h insulin history enters the watch DoseStore as PUMP EVENTS (idempotent under
    /// grant redelivery). Seeded via `addPumpEvents` — NOT the `addDoses` side door — so
    /// stock `InsulinMath.reconciled()` runs at the store: it collapses any same-start
    /// overlap to a single dose AND puts the seed in the same reconciliation world as the
    /// watch's own enacted temps, so the watch's first temp truncates the seeded (open)
    /// running temp instead of overlapping its tail (Fix 2). Net-basal netting rides the
    /// watch's basalProfile, which is frozen to the grant schedule for the loan, so seeded
    /// temps net against the delivery-time schedule with no stamped rate (the pump-event
    /// table does not persist scheduledBasalRate anyway — it is re-derived at read). The
    /// redundant running-temp `boundaryRecord` is no longer emitted by the phone (Fix 1);
    /// `seedDoseEntries` still tolerates it for older phones and `reconciled()` would collapse
    /// it regardless. See docs/DESIGN_LOAN_ADDPUMPEVENTS.md.
    private func ingestGrantHistory(_ grant: LoanGrant) {
        // WIPE-THEN-SEED (IOB dedup, 2026-07-22). Epoch-keyed syncIds mean each takeover would
        // otherwise re-insert the same 16 h under fresh identifiers, compounding IOB across
        // epochs. The grant IS ground truth at takeover (it already contains this watch's
        // journal-reconciled doses), so wipe both tables, then seed. lastPumpEventsReconciliation
        // is set to the takeover instant so the reconciled seed persists into the delivery
        // store; the takeover's own status read refreshes it via checkPumpDataAndLoop.
        let doseStore = loopManager.doseStore
        let seamLog = OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanWatchController")
        let seedReconciliation = Date()
        // #72 (2026-07-28, supersedes Fix 2's trim): the seed carries FINISHED history only. A
        // dose still DELIVERING at takeover (running temp, mid-flight bolus) is OMITTED — the
        // grant's podState blob already carries it, and this watch's pump manager reports it as a
        // live MUTABLE dose on the first status read (stock ownership, exactly how the phone books
        // its own running temp). IOB then TRACKS its delivery in real time (Jeremy's 0.50 → 0.57)
        // and the eventual cancel/expiry books ACTUAL units under the pod-native raw — no seeded
        // row exists to swallow it. Fix 2's trim, once #69 made identity dedup work, froze the
        // temp at the takeover instant and understated IOB for the temp's remaining life.
        // FIELD-LOG NOTE: when liveNote is non-empty, SEED-IN IOB reads LOW by the live dose's
        // contribution until the first pod read lands (seconds), so [iob-diff] Δwire<0 then
        // Δreconcile>0 by ~the same amount is EXPECTED, not a bug.
        let (entries, liveDoses) = grant.seedDoseEntries(finishedBy: seedReconciliation)
        // #73/#74 SHADOW LEDGER: the single-owner session timeline gets the same split — no
        // wipe needed on its side (a new ledger IS the wipe). Runs alongside the store path;
        // [ledger-diff] compares them every cycle.
        loopManager.ledgerSeed(finished: entries, live: liveDoses)
        // #1 handover-IOB diagnostic: seed magnitude + the double-seed detector (should now
        // always read "no" — the phone stopped sending the boundaryRecord in Fix 1).
        let grossImpliedSum = entries.reduce(0.0) { $0 + $1.programmedUnits }
        let boundaryDup = Self.boundaryDuplicatesHistory(grant)
        let liveNote = liveDoses.isEmpty ? "" :
            String(format: "; %d live dose(s) omitted — pod state owns them (#72), latest ends +%.0fm",
                   liveDoses.count, (liveDoses.map { $0.endDate }.max()!.timeIntervalSince(seedReconciliation)) / 60)
        doseStore.deleteAllPumpEvents { error in
            if let error = error {
                os_log("Grant ingest: pump-event wipe failed: %{public}@", log: seamLog, type: .error, String(describing: error))
            }
            doseStore.insulinDeliveryStore.purgeCachedInsulinDeliveryObjects(before: nil) { error in
                if let error = error {
                    os_log("Grant ingest: delivery-store purge failed: %{public}@", log: seamLog, type: .error, String(describing: error))
                }
                // The seed writes ON TOP of the store, so after the wipe it MUST be empty — any dose
                // still present is a prior-epoch survivor (the takeover-IOB-inflation bug: build 177
                // seeded a lone 2 U bolus on top of 10 stale temps → SEED-IN 3.38 vs phone 2.00).
                // seedNow() carries the seed; it's gated below on a verified-empty audit that
                // force-repurges a dirty store first, and logs the leak either way (#69 wipe-audit).
                func seedNow() {
                    // NewPumpEvent identity lives in `raw` (its hex becomes the dose syncIdentifier —
                    // PumpEvent DISCARDS DoseEntry.syncIdentifier). The phone's syncId IS hex(raw) of
                    // what its pump manager reported, so LoanSeedIdentity.raw() hex-DECODES it back to
                    // the original bytes (#69 double-hex fix): the rebuilt pump manager's inevitable
                    // re-reports of inherited podState doses then land on the SAME row via the raw
                    // uniqueness constraint instead of a second copy (the +1.15U cycle-1 bolus echo),
                    // and re-seeds across epochs upsert-dedup even if the wipe misfires. Non-hex ids
                    // (epoch-keyed fallback) keep utf8, as before. Live doses are NOT here (#72 —
                    // omitted by seedDoseEntries(finishedBy:), pod state owns them).
                    let events = entries.map { dose -> NewPumpEvent in
                        NewPumpEvent(date: dose.startDate, dose: dose,
                                     raw: LoanSeedIdentity.raw(forSyncIdentifier: dose.syncIdentifier ?? UUID().uuidString),
                                     title: Self.pumpEventTitle(for: dose.type))
                    }
                    // An EMPTY seed (cleared phone history, or all-live doses) still goes through
                    // addPumpEvents: it stamps lastPumpEventsReconciliation = takeover instant
                    // (assigned before the empty-guard, pinned by
                    // testEmptyPumpEventsStillRefreshesLastAddedPumpData) so pumpDataTooOld can't
                    // deadlock the first cycle. replacePendingEvents:false (#72): a pod-owned live-
                    // dose report that raced ahead of the seed must NOT be purged — the wipe already
                    // cleared stale mutable rows, and every manager report (replace:true) self-heals
                    // any that leak past it.
                    doseStore.addPumpEvents(events, lastReconciliation: seedReconciliation, replacePendingEvents: false) { error in
                        if let error = error {
                            os_log("Grant history ingest failed: %{public}@", log: seamLog, type: .error, String(describing: error))
                        } else {
                            SportLog.event("loan", String(format: "insulin books rebuilt from grant — %d records (wipe-then-seed, addPumpEvents) · grossImpliedΣ=%.2fU · boundaryDup=%@%@%@",
                                                           events.count, grossImpliedSum,
                                                           boundaryDup ? "YES" : "no",
                                                           boundaryDup ? " (#1 double-seed — expected gone post-Fix1)" : "",
                                                           liveNote))
                        }
                        self.loopManager.invalidateInsulinEffect()
                        // SEED-IN IOB anchor (#1): the watch's IOB right after seeding, to compare
                        // against the phone's IOB at grant time — closes the takeover-fidelity loop.
                        doseStore.insulinOnBoard(at: seedReconciliation) { result in
                            if case .success(let iob) = result {
                                // Prime the cached IOB so the glance + stock HUD show it AT takeover
                                // instead of blank until the first loop cycle (#69 glance consistency;
                                // the glance COB already reads its store live).
                                self.loopManager.primeInsulinOnBoard(iob)
                                SportLog.event("loan", String(format: "SEED-IN IOB=%.2fU @ takeover (%d seeded doses%@)", iob.value, events.count, liveNote))
                                // INSTRUMENTATION ONLY (#69): record the phone/seed IOB anchors and dump
                                // the per-dose decomposition, so the first post-takeover cycle can emit
                                // [iob-diff] (phone vs seed vs cycle1) and localize the ~0.3U leak.
                                self.loopManager.recordTakeoverIOBAnchors(
                                    phone: grant.predictionSnapshot?.iobUnits,
                                    phoneDate: grant.predictionSnapshot?.iobDate,
                                    seed: iob.value,
                                    at: seedReconciliation)
                                self.loopManager.dumpIOBDecomp("SEED-IN", at: seedReconciliation)
                            }
                        }
                    }
                }
                // Verified-empty gate (#69 wipe-audit): count what survived delete+purge. Clean → seed.
                // Dirty → the wipe leaked; log loudly, dump the survivors, force a second delete+purge,
                // re-count (so we learn whether the leak is even delete+purge-clearable), then seed.
                self.auditDoseCount("after wipe (pre-seed)", at: seedReconciliation) { survivors in
                    guard survivors > 0 else { seedNow(); return }
                    SportLog.event("wipe-audit", "** WIPE LEAK: \(survivors) prior-epoch dose(s) survived delete+purge — force-repurging before seed **")
                    self.loopManager.dumpIOBDecomp("WIPE-LEAK-SURVIVORS", at: seedReconciliation)
                    doseStore.deleteAllPumpEvents { _ in
                        doseStore.insulinDeliveryStore.purgeCachedInsulinDeliveryObjects(before: nil) { _ in
                            self.auditDoseCount("after forced repurge", at: seedReconciliation) { residual in
                                if residual > 0 {
                                    SportLog.event("wipe-audit", "** REPURGE INEFFECTIVE: \(residual) dose(s) STILL present — seeding on top (leak is not delete+purge-clearable) **")
                                }
                                seedNow()
                            }
                        }
                    }
                }
            }
        }
        ingestGrantCarbs(grant)
        ingestGrantGlucose(grant)
    }

    /// Make the watch carb store an authoritative MIRROR of the phone's at takeover (Jeremy
    /// 2026-07-26): WIPE it, then replace with the grant's carbs via `setSyncCarbObjects` (which
    /// `purgeCachedCarbObjectsUnconditionally` before inserting). This is the phantom-COB fix (#65).
    /// The previous `syncCarbObjects` UPSERTED on (syncIdentifier, provenanceIdentifier) and never
    /// deleted absent entries, so a prior-epoch residual — or a carb the user DELETED on the phone
    /// (→ empty grant, which used to early-return and wipe nothing) — survived on the watch,
    /// absorbing and pushing dosing until it aged past the 24 h cache. With a true replace, an empty
    /// grant wipes to zero, so phone-side deletions propagate. Safe because carbs are ONE-WAY
    /// phone→watch in v1: watch-entered carbs are not returned (see `loanDidRecordCarbs`), so the
    /// watch never legitimately holds a carb the phone doesn't. Full bidirectional sync is #49/#66.
    private func ingestGrantCarbs(_ grant: LoanGrant) {
        let phoneCOB = grant.predictionSnapshot?.cobGrams
        let phoneCOBStr = phoneCOB.map { String(format: "%.1f", $0) } ?? "n/a"
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
            // [cob-diff] (#65): after a true wipe-then-replace the watch holds EXACTLY the phone's
            // carbs, so watch COB(post) should ≈ phoneCOB and Δ(post−phone) ≈ 0. A residual now would
            // mean the wipe itself failed (not an upsert leak). `post` is a pre-settle read (static
            // absorption) so a small +Δ vs the phone's dynamic COB is expected, not a defect.
            self?.loopManager.glanceCarbsOnBoard { cob in
                let postV = cob ?? 0
                let vsPhone = phoneCOB.map { postV - $0 }
                SportLog.event("cob-diff", String(format: "REPLACE %@ · phoneCOB=%@ g · watch COB(post)=%.2f g · replaced %.0f g · Δ(post−phone)=%@ g%@ · [%@]",
                                                   source, phoneCOBStr, postV, seededGrams,
                                                   vsPhone.map { String(format: "%+.2f", $0) } ?? "—",
                                                   (vsPhone ?? 0) > 2.0 ? " ⚠ residual (wipe failed?)" : "", manifest))
            }
        }
        // Carb effect is cached; force a recompute so the replaced COB reaches the first
        // prediction instead of waiting for a CGM-triggered invalidation (build 134 lesson).
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
                // 2026-08-03: same "INGEST src=" key as the direct-G7 and phone-relay paths, so
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

    /// INSTRUMENTATION ONLY (#45): stash the phone's grant prediction snapshot on the watch loop
    /// manager (so `[predict-diff]` can subtract it) and echo it to the log at takeover, next to the
    /// SEED-IN IOB/COB lines. No-op when the grant carries no snapshot (older phone / stale caches).
    private func ingestPredictionSnapshot(_ grant: LoanGrant) {
        loopManager.stashPhonePredictionSnapshot(grant.predictionSnapshot)
        guard let s = grant.predictionSnapshot else { return }
        let now = Date()
        SportLog.event("snapshot", String(format:
            "RX phone@grant — eventual %.0f start %.0f@%.0fs IOB %.2f@%.0fs COB %.0f · impact mom %+.0f ins %+.0f carb %+.0f RC %+.0f · momPts %d rcDisc %d · snapAge %.0fs",
            s.eventualMgdl, s.startGlucoseMgdl, now.timeIntervalSince(s.startGlucoseDate),
            s.iobUnits, now.timeIntervalSince(s.iobDate), s.cobGrams,
            s.impactMomentumMgdl, s.impactInsulinMgdl, s.impactCarbMgdl, s.impactRCMgdl,
            s.momentumPointCount, s.rcDiscrepancyCount, now.timeIntervalSince(s.snapshotAt)))
    }

    /// #1 double-seed detector: is the grant's running-temp `boundaryRecord` ALSO present
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

    /// WS1: request a hand-back WITHOUT giving up control. Phase stays .active —
    /// dosing, boluses, and the G7 loop all continue; the journal drains via interim
    /// offers. When the drain is fully acked, finalizeHandback() stops dosing and
    /// sends the final offer. Cancelable until then.
    func beginHandback() {
        #if targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: "sim.fakeLoanFlow") { simDriveHandback(); return }
        #endif
        queue.async {
            guard self.phase == .active, self.pumpManager != nil else { return }
            guard !self.handbackRequested else { return }
            self.handbackRequested = true
            self.handbackResendCount = 0
            // #67: bound the wait for the phone's ack. Pre-scheduled alert fires from a suspended
            // app; the resend loop resumes Sport Mode on the watch at the same deadline. Covers
            // both the interim-drain path below and the legacy single-phase finalize.
            self.handbackDeadline = Date().addingTimeInterval(HandbackStuckAlert.interval)
            self.handbackStartedAt = Date()
            HandbackStuckAlert.arm()
            guard self.phoneSupportsInterimHandback else {
                // REAL-3 skew gate: an old phone treats ANY offer as final — go
                // straight to the legacy single-phase hand-back (stop, then offer).
                SportLog.event("loan", "HAND-BACK started (legacy single-phase — phone predates interim drains)")
                self.finalizeHandback()
                return
            }
            SportLog.event("loan", "HAND-BACK requested — draining \(self.journal.unackedEvents().count) events; still in control (WS1)")
            self.sendHandbackOffer(freshened: false, recovered: false)
        }
    }

    /// WS1: abort a requested hand-back while still in the drain (phase .active).
    /// After finalize the pod has stopped taking watch commands — too late to cancel.
    func cancelHandback() {
        queue.async {
            guard self.phase == .active, self.handbackRequested else { return }
            self.handbackRequested = false
            self.resendWorkItem?.cancel()
            self.handbackDeadline = nil
            self.handbackStartedAt = nil
            HandbackStuckAlert.disarm()   // #67: aborted before the budget — no stuck alert
            SportLog.event("loan", "HAND-BACK cancelled — Sport Mode continues")
        }
    }

    /// #67: the phone never acked the hand-back within the budget (unreachable, or silently
    /// dropping offers — #35). We stayed the pod's SOLE OWNER throughout — interim: still dosing;
    /// final: dosing stopped but the pod is STILL HELD (release only on the final ack) — so
    /// recovery is clean: resume Sport Mode on the watch in the SAME loop mode (never auto-open
    /// or auto-close — Jeremy 2026-07-28). Unacked records stay in the journal and re-offer on a
    /// later hand-back (the phone dedups by event ID); the odometer reconciles the totals then.
    /// The pre-scheduled HandbackStuckAlert delivers the wrist notification (even from a suspended
    /// app, in which case this state restore runs on the next wake).
    private func handbackTimedOut() {
        resendWorkItem?.cancel()
        handbackDeadline = nil
        handbackStartedAt = nil
        let wasFinal = (phase == .handingBack)
        handbackRequested = false
        finalOfferSent = false
        if wasFinal, let manager = pumpManager {
            // finalize nilled loopManager.pumpManager but self.pumpManager still HOLDS the pod —
            // re-point the loop and re-loop, no re-takeover needed.
            phase = .active
            loopManager.pumpManager = manager
            loopManager.loanDoseRecorder = self
            SensorBlackoutAlert.refresh()   // dosing resumes → re-arm the blackout dead-man
            onLoanActiveChanged?(true)
            SportLog.event("loan", "HAND-BACK timed out (final, \(Int(HandbackStuckAlert.interval))s) — iPhone never acked; resumed Sport Mode on the watch (still holding the pod)")
            loopManager.checkPumpDataAndLoop()   // re-establish a temp this cycle
        } else {
            // Interim hang: never stopped dosing; phase already .active. Just abort the drain.
            SportLog.event("loan", "HAND-BACK timed out (interim, \(Int(HandbackStuckAlert.interval))s) — iPhone never acked; Sport Mode continues on the watch")
        }
        // HandbackStuckAlert is intentionally NOT disarmed here — its pre-scheduled notification
        // is the user's signal that End didn't complete. It self-expires; a later successful
        // hand-back re-arms a fresh one.
    }

    /// WS1: the drain is fully acked while still active — NOW stop dosing, close the
    /// loop-temp record, freshen the odometer, and send the FINAL (released) offer.
    /// The pod's BLE link is still held until the final ack (kept from v1: release
    /// ONLY after the phone has committed everything).
    private func finalizeHandback() {
        // Verify finding REAL-2: a stale INTERIM resend timer (armed 0-15s ago) must
        // not fire during the ~3-12s of temp-cancel + status reads below — once phase
        // flips it would send released=true prematurely and the phone would reclaim
        // while this device is still commanding the pod.
        resendWorkItem?.cancel()
        finalOfferSent = false   // round-2 fix: close path waits for the real final offer
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
        SensorBlackoutAlert.disarm()   // dosing stopped — a blackout alert would mislead

        // DESIGN-5: cancel the leftover LOOP temp — but a running bounded manual
        // suspend is preserved (46f16d01); the pod auto-resumes at its expiry (R3).
        let suspendActive = (self.manualSuspendEnd ?? .distantPast) > Date()
        let cancelIfNeeded: (@escaping () -> Void) -> Void = { proceed in
            if case .tempBasal = manager.status.basalDeliveryState, !suspendActive {
                // #73/#74 shadow ledger: the safe-cancel truncates the open temp in the ledger
                // too — otherwise a failed-offer resume keeps a phantom full-span temp
                // (adversarial review). Zero-length 0-temp = pure truncation marker.
                let cancelAt = Date()
                self.loopManager.ledgerRecordEnact(DoseEntry(
                    type: .tempBasal, startDate: cancelAt, endDate: cancelAt,
                    value: 0, unit: .unitsPerHour))
                manager.enactTempBasal(unitsPerHour: 0, for: 0) { _ in proceed() }
            } else {
                proceed()
            }
        }

        cancelIfNeeded {
            // Freshen the odometer (OQ-5: one retry on a zero delta), then offer.
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
        if let start = deliveredAtTakeover, let latest = pumpManager?.podLoanInsulinDelivered {
            odometer = LoanOdometerSnapshot(deliveredAtStart: start, deliveredLatest: latest, freshenSucceeded: freshened)
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
            handedBackAt: Date(),
            finalStatus: pumpManager.map { _ in currentPodStatus() },
            odometer: odometer,
            events: offerEvents,
            tombstones: journal.pendingTombstones(),
            recovered: recovered,
            released: phase != .active,   // WS1: interim while still dosing; final after finalize
            // R23 overturned 2026-08-04 (Jeremy): the phone inherits the wrist's loop mode on
            // the way back, mirroring the grant's outbound inheritance. Read through the
            // NON-BLOCKING mirror: this runs on `queue`, and `closedLoopEnabled` would sync
            // onto dataAccessQueue — the #64 deadlock direction.
            watchClosedLoopEnabled: loopManager.closedLoopEnabledNonBlocking)
        if offer.released == true, finalOfferSentAt == nil { finalOfferSentAt = Date() }
        handbackResendCount += 1
        // Self-documenting limbo (party finding: 97 silent minutes of 15s resends):
        // log the attempt count each minute so the wait is visible in the log.
        if handbackResendCount == 1 || handbackResendCount % 4 == 0 {
            SportLog.event("loan", "hand-back offer attempt \(handbackResendCount) — waiting for iPhone ack")
        }
        // #67 follow-up (2026-08-03): say WHY the wait is happening. Field 2026-08-02 23:58 —
        // End was tapped with the phone unreachable, and the only feedback for 120 s was
        // "ending…". `reachable false` was on every send line in the log the whole time: the
        // signal existed, we just never surfaced it. Log transitions here; the glance note is
        // driven off DebugSnapshot.phoneReachable. NOTE we do NOT abort on unreachable —
        // reachability flaps, and the queued offer lands the moment the phone returns (that
        // night: ack in 47 ms once reachable). Fast feedback, slow abort.
        let reachableNow = isPhoneReachable()
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
            // #67: give up after the budget and resume Sport Mode on the watch (we stayed the
            // pod's sole owner throughout). Only the LIVE hand-back (deadline set) — a
            // recovered/revoke drain has no local loan to resume, so it keeps resending.
            if let deadline = self.handbackDeadline, Date() >= deadline,
               self.phase == .handingBack || (self.phase == .active && self.handbackRequested) {
                self.handbackTimedOut()
                return
            }
            if self.phase == .handingBack || self.phase == .revoked || self.phase == .recoveredDrain
                || (self.phase == .active && self.handbackRequested) {   // WS1 interim drain
                self.sendHandbackOffer(freshened: freshened, recovered: recovered)
            }
        }
        resendWorkItem = work
        queue.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func handleAck(_ ack: HandbackAck) {
        guard let current = epoch ?? journal.activeEpoch, ack.epoch == current else { return }
        // Round-4 fix: the phone acks MAX-seq, but withholding (in-flight /
        // chase-pending events) creates seq GAPS a max-seq cursor can't represent —
        // an ack covering a later carb would skip a withheld command forever. Cap
        // the applied cursor below the lowest withheld seq so those events stay
        // unacked and drain once classified (the phone dedups commits by event ID,
        // so the later out-of-order stream still commits exactly once).
        var withheld = inFlightEventIDs
        if let pending = pendingUncertainEventID { withheld.insert(pending) }
        var cursorToApply = ack.committedCursor
        if !withheld.isEmpty,
           let minWithheldSeq = journal.unackedEvents().filter({ withheld.contains($0.id) }).map(\.seq).min() {
            cursorToApply = min(cursorToApply, minWithheldSeq - 1)
        }
        journal.applyAck(committedCursor: cursorToApply)
        guard journal.unackedEvents().isEmpty else { return }

        // WS1: the drain completed while STILL DOSING — now stop the loop's pod,
        // close records, and send the final (released) offer. The close below runs
        // on that final offer's ack. Round-2 gate: never finalize while a verdict
        // chase is live (its withheld event also keeps unackedEvents non-empty —
        // this is the explicit belt to that suspender).
        if phase == .active && handbackRequested {
            // Round-4 belt: no finalize while ANY command is unclassified (in-flight
            // OR chase-pending) — the withheld-seq cursor cap above is the suspender.
            guard pendingUncertainEventID == nil, inFlightEventIDs.isEmpty else { return }
            finalizeHandback()
            return
        }
        guard phase == .handingBack || phase == .revoked || phase == .recoveredDrain else { return }
        // Round-2 fix: during finalize's pod-ops window (phase flipped, journal
        // empty, final offer NOT yet sent) a duplicate interim ack must not close
        // the loan — the phone would never receive released=true and strand .loaned.
        if phase == .handingBack && !finalOfferSent { return }

        // Fully drained: release the pod ONLY now (kept from v1).
        resendWorkItem?.cancel()
        chaseWorkItem?.cancel()
        // Round-3 liveness fix: chase/in-flight residue must not cross loan
        // boundaries — the finalize gate reads pendingUncertainEventID, and a stale
        // flag from THIS loan would block the NEXT loan's drain indefinitely.
        pendingUncertainEventID = nil
        inFlightEventIDs = []
        // Splits "Reclaiming…" into its two candidate components: how long the watch waited
        // for PERMISSION to release (the phone's ack), versus how long the release itself took.
        // The ack only rides WCSession's immediate channel while the watch is reachable, so a
        // wrist dropped after End pushes it into the queued path.
        let ackWait = finalOfferSentAt.map { Date().timeIntervalSince($0) }
        SportLog.event("loan", String(format: "ack RECEIVED %@ after the final offer — releasing the pod now",
                                      ackWait.map { String(format: "+%.1fs", $0) } ?? "(no offer stamp)"))
        let releaseBegan = Date()
        teardownPump()
        SportLog.event("loan", String(format: "pod BLE teardown returned in %.2fs — the phone's standing connect can land from here",
                                      Date().timeIntervalSince(releaseBegan)))
        finalOfferSentAt = nil
        journal.end()
        phase = .idle
        epoch = nil
        deliveredAtTakeover = nil
        manualSuspendEnd = nil
        handbackDeadline = nil
        handbackStartedAt = nil
        HandbackStuckAlert.disarm()   // #67: hand-back completed cleanly
        onLoanActiveChanged?(false)
        SportLog.event("loan", "CLOSED — records drained, pod released, cursor \(ack.committedCursor)")
    }

    // MARK: - Revoke (§3.2)

    private func handleRevoke(_ revoke: Revoke) {
        // SPLIT-BRAIN GUARD (2026-08-05). Record that the phone asked for the pod back BEFORE
        // the epoch match, and log it — this used to `return` in silence.
        //
        // The hole it closes: the watch's request patience is 25s (:304) but a grant's lease is
        // 5 MINUTES (PodLoanPhoneController :603). A grant delivered on the queued path can land
        // after the watch has given up and dropped to .idle with `epoch` still nil. If the phone
        // revoked in between, that revoke matched nothing here and vanished; the late grant then
        // arrived un-expired into .idle — an accepting phase (:383) — and the watch took the pod.
        // The phone meanwhile ignores the resulting takeoverComplete (it requires .grantOffered,
        // PodLoanPhoneController :662), times out, and forceReclaimToOwner sets state = .owner
        // AND setAutomaticDosingPaused(false). Both sides then believe they own the pod.
        //
        // The pod is single-central so they cannot drive it at the same instant — but E4 frees
        // the radio 90s after takeover and 12s after every dose, so they would ALTERNATE, each
        // dosing off its own books with no sight of the other's insulin.
        //
        // Remembering the epoch is enough: the phone increments on every grant, so a legitimate
        // later grant is > this and still passes. Crude was immune the same way (it refused a
        // grant older than the last revoke, WatchPodLoanCoordinator :475-479).
        if revoke.epoch > (lastRevokedEpoch ?? Int.min) {
            lastRevokedEpoch = revoke.epoch
        }
        guard let current = epoch ?? journal.activeEpoch, revoke.epoch == current else {
            SportLog.event("loan", "revoke ev=\(revoke.epoch) matched no live session (epoch \(epoch.map(String.init) ?? "nil"), phase \(phase.rawValue)) — RECORDED; any grant at or below ev=\(revoke.epoch) will now be refused")
            return
        }
        guard phase != .idle else { return }
        // Stop dosing, zero post-revoke pod commands (DESIGN-6), drain what we have.
        handbackRequested = false   // WS1: phone-initiated revoke supersedes a pending drain
        handbackDeadline = nil
        handbackStartedAt = nil
        HandbackStuckAlert.disarm()   // #67: the phone took over — no stuck alert
        loopManager.pumpManager = nil
        chaseWorkItem?.cancel()
        pendingUncertainEventID = nil   // round-3 liveness: no cross-loan chase residue
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
        guard let current = epoch, query.epoch == current else { return }
        let report = StatusReport(
            epoch: current,
            mode: currentMode(),
            lastDirectGlucoseAge: loopManager.latestGlucoseAge,  // WS4c sovereignty signal
            lastEventSeq: journal.lastEventSeq,
            podFault: pumpManager?.podLoanFaultDescription,
            holdsPod: phase == .active)
        sendMessage(.statusReport(report))
    }

    private func currentMode() -> LoanDosingMode {
        if (manualSuspendEnd ?? .distantPast) > Date() { return .suspended }
        // closedPhoneFed/cgmViewer/pausedStale arrive with the picker integration (R20).
        return .closedDirect
    }

    private func currentPodStatus() -> LoanPodStatus {
        LoanPodStatus(
            timestamp: Date(),
            deliveredUnits: pumpManager?.podLoanInsulinDelivered,
            reservoirLevel: nil,
            isSuspended: (manualSuspendEnd ?? .distantPast) > Date(),
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
        /// When the current Start attempt began (R24 progress bar); only meaningful
        /// while phase is requested/takingOver.
        let startedAt: Date?
        /// WS1: a hand-back is requested and draining while the watch is still in
        /// control (phase .active) — the glance shows "ending…" + Cancel.
        let handbackPending: Bool
        /// When the current hand-back began — anchors the reclaim progress bar.
        let handbackStartedAt: Date?
        /// #67 follow-up (2026-08-03): can we reach the iPhone right now? The ONLY thing the
        /// watch needs to know — it does not care whether the phone is out of range, has
        /// Bluetooth off, or is powered down; all three are "can't reach it" and all three
        /// have the same remedy. Drives the hand-back wrist note.
        let phoneReachable: Bool
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
    /// (:498) — so it is occupied for the whole duration of a bolus, a takeover ladder or an
    /// E4 reclaim. GlanceViewModel polls on a 2s MAIN-THREAD timer, so every one of those
    /// polls blocked the main thread for the length of the pod operation. On the wrist that
    /// is the bolus screen freezing until delivery completes and then unfreezing as the
    /// haptic lands (Jeremy, build 223) — and it would equally freeze the UI during any long
    /// pod operation. An adversarial review flagged this exact 2Hz-sync pattern and I wrongly
    /// filed it as harmless precedent.
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
                suspendEndsAt: (manualSuspendEnd ?? .distantPast) > Date() ? manualSuspendEnd : nil,
                lastIdleNote: lastIdleNote,
                startedAt: attemptStartedAt,
                handbackPending: handbackRequested,
                handbackStartedAt: handbackStartedAt,
                phoneReachable: isPhoneReachable())
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

    /// Bench-only: force the watch controller back to idle (clears a stuck phase after
    /// a failed attempt). Does NOT touch the pod — just local state; the phone recovers
    /// on its own T1 or via re-enabling Closed Loop.
    func debugReset() {
        queue.async {
            self.chaseWorkItem?.cancel()
            self.resendWorkItem?.cancel()
            self.teardownPump()
            self.loopManager.pumpManager = nil
            self.phase = .idle
            self.epoch = nil
            self.pendingUncertainEventID = nil
            self.inFlightEventIDs = []
            self.handbackRequested = false
            self.finalOfferSent = false
            SportLog.event("loan", "DEBUG RESET — watch controller forced to idle")
        }
    }

    // MARK: - Internals

    private func sendMessage(_ message: LoanMessage) {
        guard let dictionary = try? message.transportDictionary() else { return }
        send?(dictionary)
    }

    private func issueProtocolAlert(body: String) {
        loopManager.issueAlert(Alert(
            identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "protocolNack"),
            foregroundContent: Alert.Content(title: "Loan Protocol Error", body: body, acknowledgeActionButtonLabel: "OK"),
            backgroundContent: Alert.Content(title: "Loan Protocol Error", body: body, acknowledgeActionButtonLabel: "OK"),
            trigger: .immediate))
    }

    private func persistPumpRawValue() {
        guard let manager = pumpManager else { return }
        // Same {managerIdentifier, state} shape the phone persists (Common/Models/
        // PumpManager.swift rawValue — that file is phone-target-only, so built here).
        UserDefaults.standard.set(["managerIdentifier": "Omnipod", "state": manager.rawState], forKey: Keys.pumpRawValue)
    }

    private func teardownPump() {
        // EXPLICITLY drop the BLE link before dropping the manager (2026-08-04).
        //
        // This used to rely on deallocation alone: nil the delegate, nil the manager, and trust
        // ARC to tear down BlePodComms -> BluetoothManager -> CBCentralManager. That is the
        // weakest release path in the codebase, and it was being used at the ONE moment the pod
        // must actually become free. Nothing ever called cancelPeripheralConnection, nothing
        // removed the pod from autoConnectIDs, and any lingering reference kept the link — so
        // the pod stayed CONNECTED (and therefore not advertising), and the phone's standing
        // connect could not land no matter how aggressive it is.
        //
        // Field evidence (Jeremy, 2026-08-04): during "Reclaiming…" the phone's pump status
        // read minutes old — from BEFORE the loan — so the phone genuinely did not have the pod.
        // Measured: the watch reported CLOSED 0.9-7.2s after End, yet the phone did not reach a
        // verified round-trip for another 85-99s. And crude never had this, because crude never
        // had this teardown path. E4 meanwhile releases explicitly every five minutes and logs a
        // clean `state connected -> disconnected (+3s)`.
        //
        // podLoanOrphanConnection is the right primitive rather than releaseConnection: it does
        // the disconnect + cancelLoanScan WITHOUT the C5 record-close, which finalizeHandback
        // has already performed and which ledgerClear below supersedes anyway.
        SportLog.event("handback", "teardownPump: releasing BLE explicitly (see PODLOAN orphan log for the identifier)")
        pumpManager?.podLoanOrphanConnection()
        pumpManager?.pumpManagerDelegate = nil
        pumpManager = nil
        UserDefaults.standard.removeObject(forKey: Keys.pumpRawValue)
        // #73/#74: the session ledger ends with the session.
        loopManager.ledgerClear()
    }

    // MARK: - Uncertainty chase (the genuinely-additive layer-1 piece, d27a40c7 port)

    private func scheduleChase(attempt: Int = 0) {
        let delays: [TimeInterval] = [5, 20, 60]
        guard attempt < delays.count else {
            // Chase exhausted: the conservative .assumed record STANDS (R22 layers
            // settle it at hand-back) — resolve the pending flag so the record can
            // stream/commit and a WS1 drain isn't blocked behind a dead chase.
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
                        // hand-back layers (R22) settle it — never guess here.
                        self.pendingUncertainEventID = nil
                        self.streamRecords()   // the withheld .assumed record may flow now
                    case .delivered:
                        self.journal.confirm(id: eventID)
                        self.pendingUncertainEventID = nil
                        self.streamRecords()
                        SportLog.event("verdict", "DELIVERED — pod confirmed the uncertain command")
                    case .refuted(let kind):
                        // #74: reverse the ledger's assumed booking BEFORE annulling
                        // (the record lookup needs the event still present). A
                        // skipped-reduction was never booked → removeDose no-ops.
                        if let event = self.journal.unackedEvents().first(where: { $0.id == eventID }),
                           case .assumed(let kind) = event.provenance, kind != .skippedReduction,
                           let dose = event.record.podLoanLedgerDoseEntry(insulinType: nil) {
                            // skippedReduction was never booked — removing would rely on
                            // "no ±2s neighbor" luck (adversarial review); guard explicitly.
                            self.loopManager.ledgerRemoveDose(type: dose.type, startingAt: dose.startDate)
                        }
                        self.journal.annul(id: eventID)
                        self.pendingUncertainEventID = nil
                        self.streamRecords()
                        SportLog.event("verdict", "REFUTED \(kind) — command never reached the pod, record annulled")
                        self.alertRefuted(kind: kind)
                    case .unreachable:
                        self.scheduleChase(attempt: attempt + 1)
                    }
                }
            }
        }
        chaseWorkItem = work
        queue.asyncAfter(deadline: .now() + delays[attempt], execute: work)
    }

    private func alertRefuted(kind: OmniPumpManager.PodLoanPendingKind) {
        switch kind {
        case .bolus:
            WKInterfaceDevice.current().play(.failure)
            loopManager.issueAlert(Alert(
                identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "refutedBolus"),
                foregroundContent: Alert.Content(title: "Bolus Did Not Deliver", body: "The pod never received the bolus. Bolus again if you still need it.", acknowledgeActionButtonLabel: "OK"),
                backgroundContent: Alert.Content(title: "Bolus Did Not Deliver", body: "The pod never received the bolus. Bolus again if you still need it.", acknowledgeActionButtonLabel: "OK"),
                trigger: .immediate))
        case .resume:
            WKInterfaceDevice.current().play(.failure)
            loopManager.issueAlert(Alert(
                identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "refutedResume"),
                foregroundContent: Alert.Content(title: "Resume Did Not Apply", body: "Delivery is still suspended. Resume again.", acknowledgeActionButtonLabel: "OK"),
                backgroundContent: Alert.Content(title: "Resume Did Not Apply", body: "Delivery is still suspended. Resume again.", acknowledgeActionButtonLabel: "OK"),
                trigger: .immediate))
        default:
            break
        }
    }

    /// Best-effort streaming (§2.4): the phone accumulates the record even if the
    /// watch later dies. Loss is harmless — the cursor and IDs absorb redelivery.
    private func streamRecords() {
        guard phase == .active, let epoch = epoch else { return }
        // R5 (verify rounds 2+3): events that are IN-FLIGHT (mint→classification) or
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
        SportLog.event("handback", String(format: "stream: %d event(s), %d tombstone(s)", events.count, tombstones.count))
        sendMessage(.doseRecordBatch(DoseRecordBatch(epoch: epoch, events: events, tombstones: tombstones)))
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
            startDate: Date(),
            endDate: Date().addingTimeInterval(duration),
            unitsPerHour: unitsPerHour),
            uncertainKind: .tempUncertain)
    }

    func loanWillEnactBolus(units: Double) -> UUID? {
        return mintIntent(record: LoanDoseRecord(kind: .bolus, startDate: Date(), amount: units),
                          uncertainKind: .bolusUncertain)
    }

    /// SUPPRESSED in v1 (Jeremy 2026-07-26): carbs are ONE-WAY phone→watch. A watch-entered carb is
    /// NOT returned to the phone — the takeover wipe-then-replace (`ingestGrantCarbs`) is the single
    /// source of truth, and returning a watch carb would need the idempotent phone-side ingest that
    /// isn't built yet (#49/#66); without it a returned carb could double-count on the phone. Carb
    /// entry during a loan isn't part of v1, so this is a guard: we do NOT mint a `.carb` journal
    /// event or stream it. Re-enable the round-trip (restore the mint + streamRecords below) when the
    /// phone-side idempotent carb ingest lands. The carb-entry UI still calls this; it just no-ops.
    /// #49/#66 (2026-08-04): watch-entered carbs now follow the pod home.
    ///
    /// Rides the ordinary journal, exactly like the override path — which means it inherits the
    /// per-loan seq, the commit cursor, resend-until-ack and the hand-back drain for free. The
    /// phone side was already complete: LoanReconciler turns a .carb record into a NewCarbEntry
    /// (LoanReconciler.swift:183-189) and both commit sites run behind
    /// `.filter { !stagedTombstones.contains($0.id) && !committedIDs.contains($0.id) }`, so a
    /// redelivered record is dropped before it can reach addCarb. That protocol-level gate is
    /// what #66 asked for; NewCarbEntry itself carries no identity (CarbStore mints a fresh
    /// syncIdentifier on every addCarbEntry), so the store can never dedupe and the cursor has
    /// to be the guard.
    ///
    /// No skew gate needed, unlike .overrideChange: .carb is an original kind that every phone
    /// build in the field can already decode.
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

    /// R30 (#89): journal a carb the WRIST deleted, so the deletion follows the pod home.
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

    /// #68 part B: journal a WRIST-enacted override change so it follows the pod home.
    ///
    /// Rides the ordinary journal, exactly like the (currently suppressed) carb path: it
    /// inherits the per-loan seq, the commit cursor, resend-until-ack, and the hand-back drain —
    /// which is precisely what makes a phone-ABSENT override still reach the phone. A bespoke
    /// WC message would be dropped on the floor the moment the phone is out of range, and Sport
    /// Mode's whole premise is that it is.
    ///
    /// Minted `.confirmed`, NOT through `mintIntent`: this is not a pod command. There is no
    /// transmission to be uncertain about and no verdict to chase, so it must never enter
    /// `inFlightEventIDs` (which would withhold it from streams and — worse — block a WS1
    /// hand-back drain waiting for a classification that can never arrive).
    ///
    /// Called from the wrist UI on main; `queue.async` (never `sync`) keeps the #64 queue-order
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
    ///    later hand-back (#67), exactly like an unacked dose. The only true loss window is a
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
                // Skew gate (#68B): an older phone cannot decode this kind, and an
                // undecodable offer strands the loan. The override is LIVE on the wrist —
                // dosing is correct here — it simply will not follow the pod home.
                SportLog.event("override", "NOT JOURNALED (\(name)) — this phone build predates override records; the override is LIVE on the watch but will NOT follow the pod home. Update the phone app to sync overrides.")
                return
            }
            let record = LoanDoseRecord.overrideChange(override, at: Date(), note: name)
            guard let event = try? self.journal.mintEvent(record: record, provenance: .confirmed) else {
                SportLog.event("override", "** JOURNAL MINT FAILED for \(name) — the override is LIVE on the watch but will NOT follow the pod home **")
                return
            }
            SportLog.event("override", "JOURNALED \(name) — seq \(event.seq), event \(event.id.uuidString.prefix(8)), sync \(record.syncIdentifier ?? "—") (rides the drain to the phone)")
            self.streamRecords()
        }
    }

    private func mintIntent(record: LoanDoseRecord, uncertainKind: EventProvenance.UncertainKind) -> UUID? {
        // QUEUE-ORDER INVARIANT (#64, load-bearing both directions): callers sync INTO
        // this serial queue from dataAccessQueue/main — so no block running ON this queue
        // may ever dispatch sync onto WatchLoopManager.dataAccessQueue (ABBA deadlock),
        // and mintIntent must never be reached from this queue itself (libdispatch trap —
        // the #64 crash: the E4 reclaim completion ran deliverBolus here directly).
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
            // Round-5 fix: the evidence-destruction branch above cleared a pending
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

            // #99 (2026-08-08): a CERTAIN local refusal is not uncertainty. PodCommsError
            // .unfinalizedBolus is decided from this device's own state BEFORE any byte reaches
            // the pod (OmniPumpManager guards on podState.unfinalizedBolus?.isFinished()), so
            // the command provably never went out. Booking it as an assumed max-exposure dose
            // invented insulin: field 2026-08-08 00:04:48 — a 2.05 U bolus was refused because
            // the 1.15 U from 38 s earlier was still delivering (DASH runs ~1.5 U/min), and the
            // ledger jumped 5.56 -> 8.34 U on a dose that never existed. The chase then found
            // noPendingCommand — which the booking rules treat as "leave standing" — so the
            // phantom never cleared, drove automaticDosingIOBLimit headroom negative, and
            // zero-temped the rest of the night. The IOB clamp was working correctly on
            // corrupt input; this is where the corruption entered.
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

            // Uncertain. Direction-aware journaling (R5, ad280327 C1/C2): keep the
            // .assumed record only when "applied" models MORE insulin. An uncertain
            // BELOW-schedule temp is re-tagged as a skipped-reduction marker instead —
            // the C-prime fingerprint (R22) if it turns out real and unresolved.
            var retaggedSkippedReduction = false
            if let events = self.journal.unackedEvents().first(where: { $0.id == eventID }),
               events.record.kind == .tempBasal || events.record.kind == .suspend,
               let rate = events.record.unitsPerHour,
               let scheduled = self.loopManager.settings.basalRateSchedule?.value(at: events.record.startDate),
               rate < scheduled {
                self.journal.amend(id: eventID, record: events.record, provenance: .assumed(.skippedReduction))
                retaggedSkippedReduction = true
            }

            // #74 cutover blocker (uncertain-command cluster): mirror the journal's
            // direction-aware .assumed convention into the ledger. Book the assumed dose
            // ONLY when it models MORE insulin than schedule (bolus always; above-schedule
            // temps) — a skipped-reduction stays unbooked, so predecessors keep running in
            // the ledger (conservative, high-IOB direction, same as R5). A later REFUTED
            // verdict reverses the booking; DELIVERED/exhausted/noPendingCommand leave it
            // standing, exactly like the journal record. Without this, every uncertain
            // enact left a persistent ledger<store gap (documented shadow-mode blocker).
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

// MARK: - PumpManagerDelegate (the host duties; alert family forwards to WatchLoopManager's
// existing DeviceManagerDelegate conformance from M4)

extension PodLoanWatchController: PumpManagerDelegate {

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {
        // Synchronous persist: stock sets podState.unacknowledgedCommand BEFORE the BLE
        // write and notifies here — flushing now gives the C10 intent-before-transmission
        // durability (porting brief §1; UserDefaults synchronous write).
        persistPumpRawValue()
    }

    func pumpManager(_ pumpManager: PumpManager, hasNewPumpEvents events: [NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool, completion: @escaping (Error?) -> Void) {
        // The stock storage path BLOCKS its session queue on this completion — always call it.
        loopManager.doseStore.addPumpEvents(events, lastReconciliation: lastReconciliation, replacePendingEvents: replacePendingEvents) { error in
            completion(error)
        }
    }

    func pumpManager(_ pumpManager: PumpManager, didReadReservoirValue units: Double, at date: Date, completion: @escaping (Swift.Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool), Error>) -> Void) {
        loopManager.doseStore.addReservoirValue(units, at: date) { value, previousValue, areStoredValuesContinuous, error in
            if let error = error {
                completion(.failure(error))
            } else if let value = value {
                completion(.success((newValue: value, lastValue: previousValue, areStoredValuesContinuous: areStoredValuesContinuous)))
            }
        }
    }

    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date {
        return loopManager.doseStore.pumpEventQueryAfterDate
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
        // phone's (R10).
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

// MARK: - DeviceManagerDelegate (forwards to WatchLoopManager's M4 conformances)

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
