//
//  WatchPodLoanCoordinator.swift
//  WatchApp Extension
//
//  The watch side of the pod loan. Asks the phone (Loop) to loan the pod over
//  WatchConnectivity, takes the pod over directly via OmniBLECore using the keys
//  the phone returns, drives suspend/resume/bolus/status while the phone is away,
//  and hands the pod back with a summary of what it did.
//
//  Pairs with WatchDataManager on the phone (PodLoanRequestUserInfo ->
//  PodLoanGrantUserInfo reply; PodHandbackUserInfo on hand back).
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import WatchConnectivity
import OmniBLECore

@MainActor
final class WatchPodLoanCoordinator: ObservableObject {

    enum Phase: Equatable {
        case idle             // no loan
        case requesting       // asked the phone, awaiting grant + takeover
        case denied(String)   // phone declined the loan
        case armed            // hold the keys, pod not yet taken over (phone still owns it)
        case active           // holding the pod
        case handingBack      // sending the journal to the phone
        case done             // handed back
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status: PodProofStatus?
    @Published private(set) var busy = false
    @Published var lastError: String?

    /// Live summary of what the watch has done during the loan (for display).
    var liveSummary: String? {
        #if targetEnvironment(simulator)
        if Self.isSimulatorDemo, phase == .done { return "Delivered 1.5 U · Suspended 12m" }
        #endif
        return controller.loanJournalSummary
    }

    /// Whether the phone can currently be reached to hand the pod back. Hand-back needs
    /// this (WatchConnectivity to send the loan journal, and the phone's Bluetooth on to
    /// reclaim the pod over BLE). Since Show Mode is entered with the phone's BT OFF, this
    /// is often false when the user tries to end — the UI checks it to warn rather than
    /// silently no-op. Always true in the sim demo so the demo end-flow still runs.
    var phoneReachable: Bool {
        if Self.isSimulatorDemo { return true }
        return WCSession.default.isReachable
    }

    // MARK: - Session basal state (for the status page)

    /// The basal rate the watch has set this session (U/hr), or nil when the pod is on
    /// its scheduled basal (nothing set, or a resume since). Journal-backed on hardware;
    /// demo-mirrored on the sim. Display-only.
    var sessionBasalRate: Double? {
        if Self.isSimulatorDemo { return demoBasalRate }
        guard let events = controller.loanJournal?.events else { return nil }
        for event in events.reversed() {
            switch event.kind {
            case .tempBasal(let rate, _): return rate
            case .resume, .suspend: return nil   // scheduled / suspended (see sessionSuspended)
            default: continue
            }
        }
        return nil
    }

    /// Whether the watch's last delivery change this session was a suspend. Unlike the
    /// journal's own isSuspended, a later temp basal counts as un-suspending (the pod
    /// resumes delivery at the programmed rate).
    var sessionSuspended: Bool {
        if Self.isSimulatorDemo { return status?.deliveryStatus == "Suspended" }
        guard let events = controller.loanJournal?.events else { return false }
        for event in events.reversed() {
            switch event.kind {
            case .suspend: return true
            case .resume, .tempBasal: return false
            default: continue
            }
        }
        return false
    }

    /// Total insulin bolused by the watch this session (U) — the journal's discrete
    /// bolus records, the same accounting the hand-back summary reports. 0 if none.
    var sessionBolusUnits: Double {
        if Self.isSimulatorDemo { return demoBolusTotal }
        return controller.loanJournal?.totalBolusUnits ?? 0
    }

    /// Sim-demo mirrors of session state (the demo has no loan journal).
    private var demoBasalRate: Double?
    private var demoBolusTotal: Double = 0

    /// Hard cap on any single correction bolus from the watch (safety bound). The
    /// dial can't exceed this. (BG-gating is a later phase; this is the current bound.)
    static let maxBolusUnits: Double = 1.0
    /// The amount the bolus dial starts at.
    static let defaultBolusUnits: Double = 0.5

    /// Hard cap on the watch temp-basal RATE (U/hr), mirroring the bolus cap.
    static let maxTempBasalRate: Double = 1.0
    /// The rate the basal dial starts at.
    static let defaultBasalRate: Double = 0.5
    /// Fixed duration for every watch temp basal. From the user's view it's just
    /// "set the basal" (no duration UI); it's long enough to cover a competition,
    /// and the pod auto-reverts to the scheduled basal when it expires — a safety
    /// backstop if the watch dies. The phone reasserts its own basal on hand-back.
    static let tempBasalDuration: TimeInterval = 3 * 60 * 60   // 3 hours

    /// True only in the watchOS simulator (which has no Bluetooth, so it can never
    /// reach a pod). When true, the methods below route to the simulator demo path
    /// (see the extension at the bottom) instead of WatchConnectivity/BLE, so the
    /// whole Show Mode flow is walkable on the sim. Compile-time FALSE on a real
    /// watch — the demo path can never execute on hardware.
    #if targetEnvironment(simulator)
    static let isSimulatorDemo = true
    #else
    static let isSimulatorDemo = false
    #endif

    private let controller = PodProofController()

    /// Keys the phone granted, retained in memory so the pod can be claimed after
    /// the phone goes away (which frees the pod's BLE connection). Cleared on
    /// hand-back. In-memory only — survives suspension, lost on app termination.
    private var heldGrant: PodLoanGrantUserInfo?

    // MARK: - Loan lifecycle

    /// Ask the phone to loan us the pod, then take it over with the returned keys.
    func requestLoan() {
        if Self.isSimulatorDemo { demoStart(); return }
        guard !busy else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            lastError = "iPhone not reachable — bring it close to start Show Mode."
            return
        }
        busy = true
        phase = .requesting
        lastError = nil

        let request = PodLoanRequestUserInfo(requestedAt: Date())
        session.sendMessage(request.rawValue, replyHandler: { [weak self] reply in
            Task { @MainActor in self?.handleGrantReply(reply) }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.busy = false
                self?.phase = .idle
                self?.lastError = "Couldn't start Show Mode: \(error.localizedDescription)"
            }
        })
    }

    private func handleGrantReply(_ reply: [String: Any]) {
        guard let grant = PodLoanGrantUserInfo(rawValue: reply) else {
            busy = false
            phase = .idle
            lastError = "Unexpected reply from iPhone."
            return
        }
        guard grant.granted,
              grant.ltk != nil,
              grant.controllerId != nil,
              grant.podId != nil,
              grant.podAddress != nil,
              grant.messageNumber != nil
        else {
            busy = false
            phase = .denied(grant.denialReason ?? "iPhone couldn't start Show Mode.")
            return
        }

        // Borrow only transfers the keys — it does NOT attempt the takeover. The
        // phone still holds the pod's single BLE connection, so a takeover here would
        // just burn its full connect timeout (~2 min) and fail. Go straight to
        // .armed; the takeover happens on Claim, once the phone is off and the slot
        // is free. (The armed screen tells the user to power the phone off and Claim.)
        heldGrant = grant
        busy = false
        phase = .armed
        lastError = nil
    }

    /// Take the pod over using keys the phone already granted — no phone contact
    /// required. Use after the iPhone is powered off (or its Bluetooth turned off),
    /// which frees the pod's BLE connection for the watch.
    func claim() {
        if Self.isSimulatorDemo { demoClaim(); return }
        guard !busy, phase == .armed, let grant = heldGrant else { return }
        lastError = nil
        takeOver(using: grant)
    }

    /// Drop the retained keys and return to idle (user abandoned an armed loan).
    func cancelArmed() {
        guard phase == .armed, !busy else { return }
        heldGrant = nil
        phase = .idle
        lastError = nil
    }

    /// Return to idle after a completed hand-back so a new loan can be started
    /// without force-quitting the app. (BUG-1)
    func reset() {
        guard !busy else { return }
        heldGrant = nil
        status = nil
        lastError = nil
        phase = .idle
    }

    /// Take the pod over from a granted key set. Succeeds when the pod's BLE slot
    /// is free (phone off / not currently connected). If the phone still holds the
    /// pod, this fails and we drop to `.armed` — keeping the keys — so the user can
    /// power the phone off and Claim.
    private func takeOver(using grant: PodLoanGrantUserInfo) {
        guard let ltk = grant.ltk,
              let controllerId = grant.controllerId,
              let podId = grant.podId,
              let podAddress = grant.podAddress,
              let messageNumber = grant.messageNumber
        else {
            busy = false
            phase = .idle
            lastError = "Pod keys were incomplete."
            return
        }

        busy = true
        controller.takeOverExternalPod(ltk: ltk,
                                       controllerId: controllerId,
                                       podId: podId,
                                       podAddress: podAddress,
                                       messageNumber: messageNumber) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let status):
                    self.status = status
                    self.phase = .active
                    self.lastError = nil
                case .failure:
                    // We still hold the keys — the pod is just unreachable, almost
                    // always because the phone still owns the connection. Stay armed
                    // so the user can power the phone off and Claim again.
                    self.phase = .armed
                    self.lastError = "Couldn't reach the pod. Make sure your iPhone's Bluetooth is off, then try again."
                }
            }
        }
    }

    // MARK: - Pod control (only while the loan is active)

    func suspend() {
        if Self.isSimulatorDemo { demoSuspend(); return }
        runPodCommand { self.controller.suspend(completion: $0) }
    }
    func resume() {
        if Self.isSimulatorDemo { demoResume(); return }
        runPodCommand { self.controller.resume(completion: $0) }
    }
    func bolus(units: Double) {
        let capped = min(max(units, 0), Self.maxBolusUnits)
        guard capped > 0 else { return }
        if Self.isSimulatorDemo { demoBolus(units: capped); return }
        runPodCommand { self.controller.bolus(units: capped, completion: $0) }
    }
    /// Set the pod's basal to an absolute rate (U/hr). 0 = suspend. Capped at
    /// maxTempBasalRate; snapped to the pod's 0.05 U/hr resolution. Implemented as a
    /// fixed-duration temp basal (see tempBasalDuration) that auto-reverts.
    func setBasalRate(_ rate: Double) {
        let snapped = (min(max(rate, 0), Self.maxTempBasalRate) / 0.05).rounded() * 0.05
        if snapped <= 0 { suspend(); return }   // 0 U/hr = suspend
        if Self.isSimulatorDemo { demoSetTempBasal(rate: snapped); return }
        runPodCommand { self.controller.setTempBasal(rate: snapped, duration: Self.tempBasalDuration, completion: $0) }
    }
    func refreshStatus() {
        if Self.isSimulatorDemo { return }
        runPodCommand { self.controller.getStatus(completion: $0) }
    }

    private func runPodCommand(_ operation: (@escaping (Result<PodProofStatus, Error>) -> Void) -> Void) {
        guard !busy, phase == .active else { return }
        busy = true
        lastError = nil
        operation { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let status): self.status = status
                case .failure(let error): self.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Hand back to the phone

    /// Send the loan journal to the phone and, once the phone acknowledges,
    /// release the pod so the phone can reclaim it. The pod is NOT released until
    /// the phone confirms receipt — so a failed hand-back leaves us still holding
    /// it rather than orphaning the pod.
    func handBack() {
        if Self.isSimulatorDemo { demoHandBack(); return }
        guard !busy, phase == .active else { return }
        let session = WCSession.default
        guard session.isReachable else {
            lastError = "iPhone not reachable — bring it close to end Show Mode."
            return
        }
        busy = true
        phase = .handingBack
        lastError = nil

        let summary = controller.loanJournalSummary ?? "No loan activity recorded."
        let journalData = controller.loanJournal?.encoded() ?? Data()
        let handback = PodHandbackUserInfo(handedBackAt: Date(), summary: summary, journalData: journalData)

        session.sendMessage(handback.rawValue, replyHandler: { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                _ = self.controller.endLoan()   // finalize the journal
                self.controller.releasePod()    // phone acked — safe to let go
                self.heldGrant = nil            // phone owns the pod again; keys are now stale
                self.busy = false
                self.phase = .done
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                // Phone didn't confirm — keep holding the pod; the user can retry.
                self?.busy = false
                self?.phase = .active
                self?.lastError = "Couldn't reach iPhone to end Show Mode: \(error.localizedDescription). Still in control on your watch."
            }
        })
    }
}

// MARK: - Simulator demo mode
//
// The watchOS simulator has no Bluetooth, so it can never reach a pod. When
// `isSimulatorDemo` is true (simulator only — compile-time false on a real watch), the
// methods above route here instead of WatchConnectivity/BLE, walking the real phases
// with faked data + small delays. This makes the whole Show Mode flow reviewable on the
// sim — no pod, no TestFlight. It can never execute on hardware.
private extension WatchPodLoanCoordinator {
    func demoStatus(_ delivery: String, delivered: Double) -> PodProofStatus {
        PodProofStatus(deliveryStatus: delivery, podProgress: "Running", reservoirLevel: 128,
                       insulinDelivered: delivered, bolusNotDelivered: 0,
                       lastProgrammingMessageSeqNum: 5, timeActive: 3600, alerts: "None")
    }

    func demoStart() {
        lastError = nil
        phase = .requesting
        busy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.phase = .armed
            self.busy = false
        }
    }

    func demoClaim() {
        busy = true
        demoBasalRate = nil
        demoBolusTotal = 0
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.status = self.demoStatus("Scheduled Basal", delivered: 0)
            self.phase = .active
            self.lastError = nil
            self.busy = false
        }
    }

    func demoSuspend() {
        let delivered = status?.insulinDelivered ?? 0
        busy = true
        demoBasalRate = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.status = self.demoStatus("Suspended", delivered: delivered)
            self.busy = false
        }
    }

    func demoResume() {
        let delivered = status?.insulinDelivered ?? 0
        busy = true
        demoBasalRate = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.status = self.demoStatus("Scheduled Basal", delivered: delivered)
            self.busy = false
        }
    }

    func demoBolus(units: Double) {
        let delivered = (status?.insulinDelivered ?? 0) + units
        busy = true
        demoBolusTotal += units
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.status = self.demoStatus("Bolusing", delivered: delivered)
            self.busy = false
        }
    }

    func demoSetTempBasal(rate: Double) {
        let delivered = status?.insulinDelivered ?? 0
        busy = true
        demoBasalRate = rate
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.status = self.demoStatus(String(format: "Temp basal %.2f U/hr", rate), delivered: delivered)
            self.busy = false
        }
    }

    func demoHandBack() {
        lastError = nil
        phase = .handingBack
        busy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.phase = .done
            self.busy = false
        }
    }
}
