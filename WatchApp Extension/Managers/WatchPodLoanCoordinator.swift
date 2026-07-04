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

    // MARK: - Loan lifecycle

    /// Ask the phone to loan us the pod, then take it over with the returned keys.
    func requestLoan() {
        guard !busy else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            lastError = "iPhone not reachable — bring it close to start the loan."
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
                self?.lastError = "Loan request failed: \(error.localizedDescription)"
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
              let ltk = grant.ltk,
              let controllerId = grant.controllerId,
              let podId = grant.podId,
              let podAddress = grant.podAddress,
              let messageNumber = grant.messageNumber
        else {
            busy = false
            phase = .denied(grant.denialReason ?? "iPhone declined the loan.")
            return
        }

        // Take the pod over directly from the keys — no re-pairing.
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
                case .failure(let error):
                    self.phase = .idle
                    self.lastError = "Takeover failed: \(error.localizedDescription)"
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
            lastError = "iPhone not reachable — bring it close to hand the pod back."
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
                self.busy = false
                self.phase = .done
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                // Phone didn't confirm — keep holding the pod; the user can retry.
                self?.busy = false
                self?.phase = .active
                self?.lastError = "Hand-back not confirmed by iPhone: \(error.localizedDescription). Still holding the pod."
            }
        })
    }
}
