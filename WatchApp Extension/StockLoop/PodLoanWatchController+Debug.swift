//
//  PodLoanWatchController+Debug.swift
//  StockLoop
//
//  Part of PodLoanWatchController (see PodLoanWatchController.swift). Split by concern; stored properties live in the core class.
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import OmnipodKit
import WatchKit
import os.log

extension PodLoanWatchController {
    struct DebugSnapshot {
        let phase: Phase
        let epoch: Int?
        let mode: LoanDosingMode
        let hasPumpManager: Bool
        let deliveredUnits: Double?
        let podFault: String?
        let lastEventSeq: Int
        let unackedCount: Int
        let lastIdleNote: String?

        let startedAt: Date?

        let handbackPending: Bool

        let handbackStartedAt: Date?

        let phoneReachable: Bool

        let handbackFailedAt: Date?
        let handbackFailureText: String?
        let startNoteAt: Date?
        let startNoteText: String?

        let seizeOfferIssuedAt: Date?

        let reunionPromptVisible: Bool
    }

    var isLoanActive: Bool {
        return queue.sync { phase == .active }
    }

    var podBeepsOnManualBolus: Bool {
        pumpManager?.podLoanBeepsOnManualBolus ?? false
    }

    var isLoanActiveNonBlocking: Bool {
        loanActiveMirrorLock.lock()
        defer { loanActiveMirrorLock.unlock() }
        return _loanActiveMirror
    }

    var isResumingNonBlocking: Bool {
        loanActiveMirrorLock.lock()
        defer { loanActiveMirrorLock.unlock() }
        return _resumingMirror
    }

    var mirroredDebugSnapshot: DebugSnapshot? {
        snapshotMirrorLock.lock()
        defer { snapshotMirrorLock.unlock() }
        return _snapshotMirror
    }

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
                lastIdleNote: lastIdleNote,
                startedAt: attemptStartedAt,
                handbackPending: handbackRequested,
                handbackStartedAt: handbackStartedAt,
                phoneReachable: isPhoneReachable(),
                handbackFailedAt: handbackFailure?.at,
                handbackFailureText: handbackFailure?.text,
                startNoteAt: startNote?.at,
                startNoteText: startNote?.text,
                seizeOfferIssuedAt: seizeOffer?.issuedAt,
                reunionPromptVisible: reunionPromptActive)
    }

    func debugReadStatus(completion: @escaping (Bool?) -> Void) {
        queue.async {
            guard let manager = self.pumpManager else { completion(nil); return }
            manager.podLoanReadStatus { ok in completion(ok) }
        }
    }

}
