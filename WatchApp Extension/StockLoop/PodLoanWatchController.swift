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

    private(set) var phase: Phase {
        didSet { UserDefaults.standard.set(phase.rawValue, forKey: Keys.phase) }
    }
    private var epoch: Int? {
        didSet { UserDefaults.standard.set(epoch, forKey: Keys.epoch) }
    }

    private var pumpManager: OmniPumpManager?
    /// Odometer at takeover, for the hand-back snapshot pair (§1.4).
    private var deliveredAtTakeover: Double?
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
            loopManager.issueAlert(Alert(
                identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "sessionEnded"),
                foregroundContent: Alert.Content(title: "Session Ended", body: "The watch loop session ended. Records are being returned to the phone.", acknowledgeActionButtonLabel: "OK"),
                backgroundContent: Alert.Content(title: "Session Ended", body: "The watch loop session ended. Records are being returned to the phone.", acknowledgeActionButtonLabel: "OK"),
                trigger: .immediate))
        } else if phase != .idle {
            // No records to drain but a stale phase: reset cleanly.
            phase = .idle
            epoch = nil
        }
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
        case .request, .takeoverComplete, .takeoverFailed, .doseRecordBatch, .handbackOffer, .statusReport:
            os_log("Ignoring phone-bound message kind on watch", log: log, type: .default)
        }
    }

    // MARK: - Request / Grant / Takeover (§2.1-2.3)

    func requestLoan(watchBuild: String) {
        queue.async {
            guard self.phase == .idle else {
                SportLog.event("loan", "Start ignored — not idle (phase \(self.phase.rawValue))")
                return
            }
            self.phase = .requested
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

        do {
            try journal.begin(epoch: grant.epoch)
        } catch {
            // An undrained prior loan must drain first — refuse, never clobber.
            SportLog.event("loan", "grant REJECTED — undrained prior loan must drain first")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "undrained prior loan")))
            return
        }

        epoch = grant.epoch
        phase = .takingOver

        // Therapy settings snapshot: the ONLY dosing limits (R1/R16); missing -> the
        // loop's own configuration gates deny. Frozen for the loan (spec §8).
        if let raw = (try? PropertyListSerialization.propertyList(from: grant.therapySettingsRaw, options: [], format: nil)) as? LoopSettings.RawValue,
           let settings = LoopSettings(rawValue: raw) {
            loopManager.settings = settings
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
        SportLog.event("loan", "pump rebuilt — connecting to pod for the takeover status read")

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
                if success, let delivered = manager.podLoanInsulinDelivered {
                    self.deliveredAtTakeover = delivered
                    self.phase = .active
                    self.loopManager.pumpManager = manager
                    self.loopManager.loanDoseRecorder = self
                    self.onLoanActiveChanged?(true)
                    SportLog.event("loan", "ACTIVE — epoch \(grant.epoch), pod taken after \(attempt + 1) read(s), odometer \(String(format: "%.2f", delivered)) U")
                    self.sendMessage(.takeoverComplete(TakeoverComplete(epoch: grant.epoch, firstPodStatus: self.currentPodStatus())))
                } else if attempt + 1 < maxAttempts {
                    if attempt == 0 {
                        SportLog.event("loan", "connecting to pod… (BLE session establishing, up to ~40s)")
                    }
                    self.queue.asyncAfter(deadline: .now() + 3) {
                        guard self.phase == .takingOver, self.epoch == grant.epoch else { return }
                        self.attemptTakeoverRead(manager: manager, grant: grant, attempt: attempt + 1)
                    }
                } else {
                    self.teardownPump()
                    self.phase = .idle
                    self.lastIdleNote = NSLocalizedString("Pod didn't answer after 40s. Check the pod is nearby and awake, then try again.", comment: "Glance: pod unreachable at takeover")
                    SportLog.event("loan", "TAKEOVER FAILED — pod unreachable after \(maxAttempts) reads (~40s), epoch \(grant.epoch)")
                    self.sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "pod unreachable at takeover")))
                }
            }
        }
    }

    /// 16 h insulin history + the R2 boundary record enter the watch DoseStore with
    /// deterministic sync identifiers (idempotent under grant redelivery).
    private func ingestGrantHistory(_ grant: LoanGrant) {
        var entries: [DoseEntry] = []
        var records = grant.doseHistory
        if let boundary = grant.boundaryRecord { records.append(boundary) }
        for (index, record) in records.enumerated() {
            guard let entry = Self.doseEntry(from: record, syncIdentifier: "loanv2-grant-\(grant.epoch)-\(index)") else { continue }
            entries.append(entry)
        }
        guard !entries.isEmpty else { return }
        loopManager.doseStore.addDoses(entries, from: nil) { error in
            if let error = error {
                os_log("Grant history ingest failed: %{public}@", log: OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanWatchController"), type: .error, String(describing: error))
            }
        }
    }

    private static func doseEntry(from record: LoanDoseRecord, syncIdentifier: String) -> DoseEntry? {
        switch record.kind {
        case .bolus:
            guard let units = record.amount else { return nil }
            return DoseEntry(type: .bolus, startDate: record.startDate, endDate: record.endDate ?? record.startDate, value: units, unit: .units, syncIdentifier: syncIdentifier)
        case .tempBasal, .boundaryTruncation:
            guard let rate = record.unitsPerHour, let end = record.endDate else { return nil }
            return DoseEntry(type: .tempBasal, startDate: record.startDate, endDate: end, value: rate, unit: .unitsPerHour, syncIdentifier: syncIdentifier)
        case .suspend:
            guard let end = record.endDate else { return nil }
            return DoseEntry(type: .tempBasal, startDate: record.startDate, endDate: end, value: 0, unit: .unitsPerHour, syncIdentifier: syncIdentifier)
        case .resume, .carb, .plumbingCancel, .modeChange:
            return nil
        }
    }

    // MARK: - Hand-back (§3.2 HANDING_BACK)

    func beginHandback() {
        queue.async {
            guard self.phase == .active, let manager = self.pumpManager else { return }
            self.phase = .handingBack
            SportLog.event("loan", "HAND-BACK started — draining \(self.journal.unackedEvents().count) events")
            self.loopManager.pumpManager = nil  // no dosing during hand-back

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
                        self.queue.async { self.sendHandbackOffer(freshened: freshened, recovered: false) }
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
    }

    private func sendHandbackOffer(freshened: Bool, recovered: Bool) {
        guard let epoch = epoch ?? journal.activeEpoch else { return }
        var odometer: LoanOdometerSnapshot?
        if let start = deliveredAtTakeover, let latest = pumpManager?.podLoanInsulinDelivered {
            odometer = LoanOdometerSnapshot(deliveredAtStart: start, deliveredLatest: latest, freshenSucceeded: freshened)
        }
        let offer = HandbackOffer(
            epoch: epoch,
            handedBackAt: Date(),
            finalStatus: pumpManager.map { _ in currentPodStatus() },
            odometer: odometer,
            events: journal.unackedEvents(),
            tombstones: journal.pendingTombstones(),
            recovered: recovered)
        sendMessage(.handbackOffer(offer))

        // Resend until ack (rows 9/10): same event IDs every retry by construction.
        resendWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.phase == .handingBack || self.phase == .revoked || self.phase == .recoveredDrain {
                self.sendHandbackOffer(freshened: freshened, recovered: recovered)
            }
        }
        resendWorkItem = work
        queue.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func handleAck(_ ack: HandbackAck) {
        guard let current = epoch ?? journal.activeEpoch, ack.epoch == current else { return }
        journal.applyAck(committedCursor: ack.committedCursor)
        guard journal.unackedEvents().isEmpty else { return }

        // Fully drained: release the pod ONLY now (kept from v1).
        resendWorkItem?.cancel()
        chaseWorkItem?.cancel()
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
        loopManager.pumpManager = nil
        chaseWorkItem?.cancel()
        teardownPump()
        phase = .revoked
        onLoanActiveChanged?(false)
        SportLog.event("loan", "REVOKED — phone reclaimed the pod, draining records")
        sendHandbackOffer(freshened: false, recovered: true)
    }

    /// Drains a relaunch-recovered journal once the transport is available.
    func drainRecoveredIfNeeded() {
        queue.async {
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
            lastDirectGlucoseAge: nil,  // wired at UI/G7 integration (sovereignty signal)
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
                lastIdleNote: lastIdleNote)
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
        guard attempt < delays.count else { return }
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
        let events = journal.unackedEvents()
        let tombstones = journal.pendingTombstones()
        guard !events.isEmpty || !tombstones.isEmpty else { return }
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
        }
        return minted
    }

    func loanDidEnact(eventID: UUID?, error: PumpManagerError?) {
        guard let eventID = eventID else { return }
        queue.async {
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
