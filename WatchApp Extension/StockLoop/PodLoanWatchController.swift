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

    /// Injected transport: dictionary -> WCSession.transferUserInfo (integration step).
    var send: (([String: Any]) -> Void)?

    /// Fires on loan lifecycle edges: true when the loan becomes ACTIVE (the session
    /// owner starts the G7 transport — closedDirect needs glucose), false when the
    /// pod is released/revoked/failed (transport stops, loop input pauses).
    var onLoanActiveChanged: ((Bool) -> Void)?

    /// Fix B (radio arbiter): the quiet verdict chase also yields to an active G7
    /// handshake (the crude Verify chase was loudDrop==false). Wired by the session.
    var isRadioBusy: (() -> Bool)?

    /// R26 (reverse arbiter): the pod TAKEOVER outranks the G7 — during the bounded
    /// ~40s ladder the G7 client stands down, because G7 scans/handshakes starve pod
    /// BLE session establishment on the single watch radio. Wired by the session;
    /// fired with true on entering .takingOver and false on leaving it (any exit).
    var onTakeoverRadioHold: ((Bool) -> Void)?

    private(set) var phase: Phase {
        didSet {
            UserDefaults.standard.set(phase.rawValue, forKey: Keys.phase)
            if (oldValue == .takingOver) != (phase == .takingOver) {
                onTakeoverRadioHold?(phase == .takingOver)
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
        if UserDefaults.standard.bool(forKey: "sim.fakeLoanFlow") { simDriveStart(); return }
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
        requestTimeoutWork?.cancel()
        SportLog.event("loan", "GRANT received — epoch \(grant.epoch), \(grant.pumpManagerRawState.count)B pod state")
        guard phase == .idle || phase == .requested else {
            SportLog.event("loan", "grant ignored — wrong phase (\(phase.rawValue))")
            return
        }
        guard Date() < grant.expiresAt else {
            // Row 2: a late grant self-rejects; the phone's T1 already reclaimed.
            SportLog.event("loan", "grant REJECTED — expired before takeover")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "grant expired")))
            return
        }
        if let known = epoch, grant.epoch <= known {
            SportLog.event("loan", "grant REJECTED — stale epoch \(grant.epoch) (known \(known))")
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
            SportLog.event("loan", "grant REJECTED — undrained prior loan must drain first")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "undrained prior loan")))
            return
        }

        epoch = grant.epoch
        phoneSupportsInterimHandback = grant.supportsInterimHandback ?? false   // WS1 REAL-3 gate
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
        phase = .takingOver
        loopManager.settings = decodedSettings!
        // Frozen-at-grant like the therapy settings above: run the RC implementation the
        // GRANTING phone runs, instead of silently assuming Standard. nil (older phone) →
        // Standard, the pre-existing behavior.
        loopManager.setIntegralRetrospectiveCorrection(grant.integralRetrospectiveCorrectionEnabled ?? false)
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
        let scanning = manager.podLoanBeginTakeover()
        SportLog.event("loan", "pump rebuilt — \(scanning ? "scanning for the pod by address" : "no pod address!") for takeover")

        // First pod status = the takeover proof (§2.3). The pod's BLE session takes
        // SECONDS to establish after construction (scan → connect → EAP-AKA), but a
        // status read fails INSTANTLY with .podNotConnected until it's up
        // (BlePodComms.bleRunSession guard). So retry on a bounded schedule — the
        // 2026-07-15 pod-side timeout ruling (~40s) — instead of failing on the first,
        // pre-connection read.
        attemptTakeoverRead(manager: manager, grant: grant, attempt: 0)
    }

    /// ~40s of retries (14 × 3s) while the pod's BLE session establishes.
    private func attemptTakeoverRead(manager: OmniPumpManager, grant: LoanGrant, attempt: Int) {
        let maxAttempts = 14
        manager.podLoanReadStatus { [weak self] success in
            guard let self = self else { return }
            self.queue.async {
                guard self.phase == .takingOver, self.epoch == grant.epoch else { return }
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
                    SportLog.event("loan", "ACTIVE — epoch \(grant.epoch), pod taken after \(attempt + 1) read(s), odometer \(String(format: "%.2f", delivered)) U")
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
                            manager.releaseConnection()
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
                        SportLog.event("loan", "connecting to pod… (BLE session establishing, up to ~40s)")
                    }
                    // #42 diagnosis: log the pod BLE state each failed read so "unreachable"
                    // shows WHY — stuck disconnected (pod not advertising / still held by the
                    // phone) vs connecting-but-no-response.
                    SportLog.event("loan", "takeover read \(attempt + 1)/\(maxAttempts) — pod BLE state \(manager.podLoanConnectionStateDescription)")
                    self.queue.asyncAfter(deadline: .now() + 3) {
                        guard self.phase == .takingOver, self.epoch == grant.epoch else { return }
                        self.attemptTakeoverRead(manager: manager, grant: grant, attempt: attempt + 1)
                    }
                } else {
                    self.teardownPump()
                    self.phase = .idle
                    self.lastIdleNote = NSLocalizedString("Pod didn't answer after 40s. Check the pod is nearby and awake, then try again.", comment: "Glance: pod unreachable at takeover")
                    SportLog.event("loan", "TAKEOVER FAILED — pod unreachable after \(maxAttempts) reads (~40s), final BLE state \(manager.podLoanConnectionStateDescription), epoch \(grant.epoch)")
                    self.sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "pod unreachable at takeover")))
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
            SportLog.event("loan", "E4: reclaiming pod to dose")
            manager.reclaimConnection()
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
                guard self.phase == .active else { completion(false); return }
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
                    // ESCALATION (157): the bare pending-connect is probabilistic — field
                    // 2026-07-22 caught a 578s-idle pod in 6s and then missed 518s- AND
                    // 259s-idle pods entirely, while every scan-adopt takeover landed in
                    // 2-4 reads. If the gentle connect hasn't settled by read 6 (~15s),
                    // rebuild the central and arm the takeover-grade address scan; the
                    // remaining ~25s of ladder budget rides the stronger path.
                    if attempt + 1 == 6 {
                        SportLog.event("loan", "E4: reclaim ESCALATED at read 6/\(maxAttempts) — fresh central + scan-adopt (takeover-grade)")
                        manager.podLoanEscalateReclaim()
                    }
                    self.queue.asyncAfter(deadline: .now() + 2) {
                        guard self.phase == .active else { completion(false); return }
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
            manager.releaseConnection()
            self.lastPodLinkContact = Date()
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self, let manager = self.pumpManager else { return }
                let after = manager.podLoanConnectionStateDescription
                SportLog.event("loan", "E4: pod re-released after dose (+12s settle) — state \(before) -> \(after) (+3s)\(after.hasPrefix("DISCONNECTING") ? " ** WEDGED — this is the poisoning signature **" : "")")
            }
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
        let entries = grant.seedDoseEntries()
        // #1 handover-IOB diagnostic: seed magnitude + the double-seed detector (should now
        // always read "no" — the phone stopped sending the boundaryRecord in Fix 1).
        let grossImpliedSum = entries.reduce(0.0) { $0 + $1.programmedUnits }
        let boundaryDup = Self.boundaryDuplicatesHistory(grant)
        // WIPE-THEN-SEED (IOB dedup, 2026-07-22). Epoch-keyed syncIds mean each takeover would
        // otherwise re-insert the same 16 h under fresh identifiers, compounding IOB across
        // epochs. The grant IS ground truth at takeover (it already contains this watch's
        // journal-reconciled doses), so wipe both tables, then seed. lastPumpEventsReconciliation
        // is set to the takeover instant so the reconciled seed persists into the delivery
        // store; the takeover's own status read refreshes it via checkPumpDataAndLoop.
        let doseStore = loopManager.doseStore
        let seamLog = OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanWatchController")
        let seedReconciliation = Date()
        // Diagnostic (review note): does the seed include an open, future-ending temp? Its
        // [now→end] tail inflates SEED-IN IOB slightly until the watch's first temp trims it
        // (Fix 2), which explains the small SEED-IN → first-cycle IOB drop. If IOB drops with NO
        // open temp present, suspect the reservoir read-branch instead.
        let openTemps = entries.filter { $0.type == .tempBasal && $0.endDate > seedReconciliation }
        let openTempNote = openTemps.isEmpty ? "" :
            String(format: "; %d open temp(s), latest ends +%.0fm (tail trims on first watch temp)",
                   openTemps.count, (openTemps.map { $0.endDate }.max()!.timeIntervalSince(seedReconciliation)) / 60)
        doseStore.deleteAllPumpEvents { error in
            if let error = error {
                os_log("Grant ingest: pump-event wipe failed: %{public}@", log: seamLog, type: .error, String(describing: error))
            }
            doseStore.insulinDeliveryStore.purgeCachedInsulinDeliveryObjects(before: nil) { error in
                if let error = error {
                    os_log("Grant ingest: delivery-store purge failed: %{public}@", log: seamLog, type: .error, String(describing: error))
                }
                guard !entries.isEmpty else {
                    self.loopManager.invalidateInsulinEffect()
                    return
                }
                // NewPumpEvent identity lives in `raw` (its hex becomes the dose syncIdentifier);
                // the epoch-keyed seed syncId gives each dose a distinct raw → upsert-dedup on
                // re-delivery, distinct rows otherwise (DoseStore uniqueness constraint on raw).
                let events = entries.map { dose in
                    NewPumpEvent(date: dose.startDate, dose: dose,
                                 raw: Data((dose.syncIdentifier ?? UUID().uuidString).utf8),
                                 title: Self.pumpEventTitle(for: dose.type))
                }
                doseStore.addPumpEvents(events, lastReconciliation: seedReconciliation, replacePendingEvents: true) { error in
                    if let error = error {
                        os_log("Grant history ingest failed: %{public}@", log: seamLog, type: .error, String(describing: error))
                    } else {
                        SportLog.event("loan", String(format: "insulin books rebuilt from grant — %d records (wipe-then-seed, addPumpEvents) · grossImpliedΣ=%.2fU · boundaryDup=%@%@",
                                                       events.count, grossImpliedSum,
                                                       boundaryDup ? "YES" : "no",
                                                       boundaryDup ? " (#1 double-seed — expected gone post-Fix1)" : ""))
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
                            SportLog.event("loan", String(format: "SEED-IN IOB=%.2fU @ takeover (%d seeded doses%@)", iob.value, events.count, openTempNote))
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
        }
        ingestGrantCarbs(grant)
        ingestGrantGlucose(grant)
    }

    /// Seed the phone's active carbs so the watch loop predicts with COB (#49). Uses
    /// syncCarbObjects — which upserts on (syncIdentifier, provenanceIdentifier) — so a
    /// re-takeover re-sending the same carbs updates in place instead of double-counting,
    /// and the phone's provenance is preserved (createdByCurrentApp = false: these are the
    /// phone's entries, not the watch's, which also keeps them from colliding with carbs
    /// entered on the wrist).
    private func ingestGrantCarbs(_ grant: LoanGrant) {
        // INSTRUMENTATION ONLY (#65): phone COB rides in the prediction snapshot, so [cob-diff] needs
        // no extra grant field.
        let phoneCOBStr = (grant.predictionSnapshot?.cobGrams).map { String(format: "%.1f", $0) } ?? "n/a"
        guard let carbs = grant.carbHistory, !carbs.isEmpty else {
            // INSTRUMENTATION ONLY (#65): the empty-grant path is today SILENT — the exact fingerprint
            // of a deleted-carbs handover. syncCarbObjects upserts only, so any prior-epoch residual is
            // NOT wiped here; it persists (absorbing) until it ages past the 24h cache. Behavior is
            // unchanged (still an early return); we just leave a trace.
            let why = (grant.carbHistory == nil) ? "absent (old phone)" : "empty (deleted on phone)"
            loopManager.glanceCarbsOnBoard { residual in
                SportLog.event("cob-diff", String(format: "carb seed SKIPPED — carbHistory %@ · phoneCOB=%@ g · watch residual=%@ g — residual NOT wiped (upsert-only); persists until 24h cache age",
                                                   why, phoneCOBStr, residual.map { String(format: "%.2f", $0) } ?? "—"))
            }
            return
        }
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
        loopManager.carbStore.syncCarbObjects(objects) { [weak self] error in
            if let error = error {
                os_log("Grant carb ingest failed: %{public}@", log: OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanWatchController"), type: .error, String(describing: error))
            } else {
                SportLog.event("loan", "seeded \(objects.count) carb entr\(objects.count == 1 ? "y" : "ies") from the phone (COB carry-over)")
                // INSTRUMENTATION ONLY (#65): three-way [cob-diff] — phone COB (from the grant
                // prediction snapshot) vs watch COB after seeding vs grams seeded. Δ(post−seeded) > 0
                // means a prior-epoch residual survived alongside this seed (the phantom-COB signature);
                // >> seededGrams means a double-count. Per-entry manifest catches duplication across epochs.
                let tf = DateFormatter()
                tf.dateFormat = "HH:mm"
                let manifest = carbs.map { c in
                    String(format: "%.1fg@%@ sync=%@ prov=%@", c.grams, tf.string(from: c.startDate),
                           c.syncIdentifier ?? "nil", String(c.provenanceIdentifier.prefix(12)))
                }.joined(separator: " | ")
                self?.loopManager.glanceCarbsOnBoard { cob in
                    let postV = cob ?? 0
                    let excess = postV - seededGrams
                    SportLog.event("cob-diff", String(format: "phoneCOB=%@ g · watch COB(post)=%.2f g · seeded %d entr%@ (%.0f g) · Δ(post−seeded)=%+.2f g%@ · [%@]",
                                                       phoneCOBStr, postV, objects.count, objects.count == 1 ? "y" : "ies",
                                                       seededGrams, excess, abs(excess) > 0.5 ? " ⚠ residual/dup" : "", manifest))
                }
            }
        }
        // Carb effect is cached; force a recompute so the seeded COB reaches the first
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
        loopManager.glucoseStore.addGlucoseSamples(samples) { result in
            switch result {
            case .success(let stored):
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
            SportLog.event("loan", "HAND-BACK cancelled — Sport Mode continues")
        }
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
            released: phase != .active)   // WS1: interim while still dosing; final after finalize
        handbackResendCount += 1
        // Self-documenting limbo (party finding: 97 silent minutes of 15s resends):
        // log the attempt count each minute so the wait is visible in the log.
        if handbackResendCount == 1 || handbackResendCount % 4 == 0 {
            SportLog.event("loan", "hand-back offer attempt \(handbackResendCount) — waiting for iPhone ack")
        }
        sendMessage(.handbackOffer(offer))

        // Resend until ack (rows 9/10): same event IDs every retry by construction.
        resendWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
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
        teardownPump()
        journal.end()
        phase = .idle
        epoch = nil
        deliveredAtTakeover = nil
        manualSuspendEnd = nil
        onLoanActiveChanged?(false)
        SportLog.event("loan", "CLOSED — records drained, pod released, cursor \(ack.committedCursor)")
    }

    // MARK: - Revoke (§3.2)

    private func handleRevoke(_ revoke: Revoke) {
        guard let current = epoch ?? journal.activeEpoch, revoke.epoch == current else { return }
        guard phase != .idle else { return }
        // Stop dosing, zero post-revoke pod commands (DESIGN-6), drain what we have.
        handbackRequested = false   // WS1: phone-initiated revoke supersedes a pending drain
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
    }

    /// True while this watch owns the pod (phase .active) — the carb/bolus flow
    /// routes delivery LOCALLY during a loan (the phone's pod link is released).
    var isLoanActive: Bool {
        return queue.sync { phase == .active }
    }

    func debugSnapshot() -> DebugSnapshot {
        return queue.sync {
            DebugSnapshot(
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
                handbackPending: handbackRequested)
        }
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
        // Dropping the manager tears down BlePodComms and its BluetoothManager — the
        // watch stops bidding for the pod's single BLE slot (zombie-bidder :1009).
        pumpManager?.pumpManagerDelegate = nil
        pumpManager = nil
        UserDefaults.standard.removeObject(forKey: Keys.pumpRawValue)
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
            if self.isRadioBusy?() == true {
                // Fix B: BG wins the radio — re-arm the next chase attempt instead of
                // colliding with the in-flight G7 handshake.
                self.scheduleChase(attempt: attempt + 1)
                return
            }
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
        // Instrumentation (#69, 2026-07-25): summarize what the WATCH streams so the phone-side
        // reconcile can be compared against the source — localizes the hand-back insulin
        // over-count (records carry full temp windows; overlaps are not truncated). "implied Σ"
        // is the sum of rate×window (temps) + bolus amounts, i.e. what the phone will ingest.
        var streamImpliedU = 0.0
        for e in events {
            if let rate = e.record.unitsPerHour, let end = e.record.endDate {
                streamImpliedU += rate * end.timeIntervalSince(e.record.startDate) / 3600
            } else if e.record.kind == .bolus, let amt = e.record.amount {
                streamImpliedU += amt
            }
        }
        SportLog.event("handback", String(format: "stream: %d event(s), implied Σ=%.2fU, %d tombstone(s)", events.count, streamImpliedU, tombstones.count))
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

    /// Record-only journal entry (no pod command): a loan-time CARB entry rides the
    /// resend-until-ack record channel to the phone's carb store — durable with the
    /// phone unreachable (the reachable-only WC relay it replaces dropped carbs
    /// silently mid-sport, verify finding 2026-07-18). Confirmed at mint — nothing
    /// about a carb record can be delivery-uncertain — and deliberately does NOT
    /// disturb a pending verdict chase (it is not a programming command).
    func loanDidRecordCarbs(_ entry: NewCarbEntry) {
        queue.async {
            guard self.phase == .active else { return }
            _ = try? self.journal.mintEvent(
                record: LoanDoseRecord(kind: .carb,
                                       startDate: entry.startDate,
                                       amount: entry.quantity.doubleValue(for: .gram()),
                                       absorptionTime: entry.absorptionTime),
                provenance: .confirmed)
            self.streamRecords()
        }
    }

    private func mintIntent(record: LoanDoseRecord, uncertainKind: EventProvenance.UncertainKind) -> UUID? {
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

            let uncertain: Bool
            if case .uncertainDelivery = error { uncertain = true }
            else { uncertain = self.pumpManager?.podLoanPendingCommandKind != nil }

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
            if let events = self.journal.unackedEvents().first(where: { $0.id == eventID }),
               events.record.kind == .tempBasal || events.record.kind == .suspend,
               let rate = events.record.unitsPerHour,
               let scheduled = self.loopManager.settings.basalRateSchedule?.value(at: events.record.startDate),
               rate < scheduled {
                self.journal.amend(id: eventID, record: events.record, provenance: .assumed(.skippedReduction))
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
