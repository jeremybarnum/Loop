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
    var liveSummary: String? { controller.loanJournalSummary }

    /// The single fixed bolus size this build offers (safety: no arbitrary dosing).
    static let fixedBolusUnits: Double = 0.5

    private let controller = PodProofController()

    /// Keys the phone granted, retained in memory so the pod can be claimed after
    /// the phone goes away (which frees the pod's BLE connection). Cleared on
    /// hand-back. In-memory only — survives suspension, lost on app termination.
    private var heldGrant: PodLoanGrantUserInfo?

    // MARK: - Loan lifecycle

    /// Ask the phone to loan us the pod, then take it over with the returned keys.
    func requestLoan() {
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
            lastError = "Unexpected loan reply from iPhone."
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
                    self.lastError = "Couldn't reach the pod. Make sure your iPhone is powered off, then try again."
                }
            }
        }
    }

    // MARK: - Pod control (only while the loan is active)

    func suspend() { runPodCommand { self.controller.suspend(completion: $0) } }
    func resume() { runPodCommand { self.controller.resume(completion: $0) } }
    func bolus() { runPodCommand { self.controller.bolus(units: Self.fixedBolusUnits, completion: $0) } }
    func refreshStatus() { runPodCommand { self.controller.getStatus(completion: $0) } }

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
