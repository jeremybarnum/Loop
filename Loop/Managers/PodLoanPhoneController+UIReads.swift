//
//  PodLoanPhoneController+UIReads.swift
//  Loop
//
//  Part of PodLoanPhoneController (see PodLoanPhoneController.swift). Split by concern; stored properties live in the core class.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore
import UserNotifications
import os.log

extension PodLoanPhoneController {
    struct UISnapshot: Equatable {
        var isLoanedOut = false
        var isTakeoverInProgress = false
        var isSettlingOnly = false
        var ladderIsRunning = false
        var ladderStartedAt: Date?
        var ladderPhase: ReclaimProgress.Phase = .draining
        var ladderForceAt: Date?
        var isOwner = true
        var reclaimStartedAt: Date?
        var reclaimVerified = true
        var auditIsForceReclaim = false
        var displayAnchor: Date?
    }

    func uiSnapshot() -> UISnapshot {
        var s = UISnapshot()

        s.isLoanedOut = state != .owner || yieldingToInferredLoan
        s.isTakeoverInProgress = state == .grantOffered
        s.isSettlingOnly = state == .owner && reclaimStartedAt != nil && reclaimVerifiedAt == nil
        if let ladder = reclaimLadder {
            s.ladderIsRunning = state == .reclaimPending || state == .reconciling
            s.ladderStartedAt = ladder.startedAt
            s.ladderPhase = ladder.phase
            s.ladderForceAt = ladder.forceAt
        }
        s.isOwner = state == .owner
        s.reclaimStartedAt = reclaimStartedAt
        s.reclaimVerified = reclaimVerifiedAt != nil
        s.auditIsForceReclaim = pendingHandbackAudit?.flavor == .forceReclaim
        s.displayAnchor = reclaimDisplayAnchor
        return s
    }

    func syncUIMirror() {
        let s = uiSnapshot()
        uiMirrorLock.lock()
        uiMirror = s
        uiMirrorLock.unlock()
    }

    func refreshUIMirror() {
        queue.async { [weak self] in
            guard let self else { return }
            let s = self.uiSnapshot()
            self.uiMirrorLock.lock()
            self.uiMirror = s
            self.uiMirrorLock.unlock()
        }
    }

    var uiState: UISnapshot {
        refreshUIMirror()
        uiMirrorLock.lock()
        defer { uiMirrorLock.unlock() }
        return uiMirror
    }

    static func reclaimProgress(from s: UISnapshot, now: Date) -> ReclaimProgress? {
        if s.ladderIsRunning, let ladderStartedAt = s.ladderStartedAt {
            let elapsed = max(now.timeIntervalSince(ladderStartedAt), 0)

            var phase = s.ladderPhase
            var fraction: Double?
            if phase == .draining {
                fraction = min(elapsed / Self.liveHandoverExpectation, 0.95)
                if elapsed >= Self.liveHandoverExpectation { phase = .watchNotAnswering }
            }
            return ReclaimProgress(phase: phase, startedAt: ladderStartedAt,
                                   expectedBy: phase == .draining
                                       ? ladderStartedAt.addingTimeInterval(Self.liveHandoverExpectation)
                                       : (s.ladderForceAt ?? ladderStartedAt),
                                   fraction: fraction,
                                   elapsed: elapsed)
        }

        if s.isOwner, let started = s.reclaimStartedAt, !s.reclaimVerified,
           now.timeIntervalSince(started) < Self.reclaimSettleTimeout {
            let elapsed = max(now.timeIntervalSince(started), 0)

            if s.auditIsForceReclaim {
                return ReclaimProgress(
                    phase: .forceReclaimingPod, startedAt: started,
                    expectedBy: started.addingTimeInterval(Self.reclaimSettleExpectation),
                    fraction: min(elapsed / Self.reclaimSettleExpectation, 0.95),
                    elapsed: elapsed)
            }

            let anchor = s.displayAnchor ?? started
            let waitElapsed = max(now.timeIntervalSince(anchor), 0)
            return ReclaimProgress(
                phase: .reconnectingToPod, startedAt: anchor,
                expectedBy: anchor.addingTimeInterval(Self.reclaimSettleExpectation),
                fraction: min(waitElapsed / Self.reclaimSettleExpectation, 0.95),
                elapsed: waitElapsed)
        }
        return nil
    }

    var isLoanedOutForUI: Bool { return uiState.isLoanedOut }

    var isReclaimActivityForUI: Bool {
        let s = uiState
        return s.isSettlingOnly || s.ladderIsRunning
    }
    var isPodLoanedOutForUI: Bool { return uiState.isLoanedOut }
    var isPodTakeoverInProgressForUI: Bool { return uiState.isTakeoverInProgress }
    var reclaimProgressForUI: ReclaimProgress? {
        return Self.reclaimProgress(from: uiState, now: Date())
    }

}
