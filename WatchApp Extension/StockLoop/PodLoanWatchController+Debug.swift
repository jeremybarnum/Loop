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
        /// The last End that did not complete — the glance shows its text briefly.
        let handbackFailedAt: Date?
        let handbackFailureText: String?
        /// R40(b): a seize offer is pending (normal request timed out with a stored
        /// credential); the glance renders the deliberate confirm with this age.
        let seizeOfferIssuedAt: Date?
        /// R40(f): the phone returned during a seized loan — the glance renders the
        /// hand-back-or-keep prompt on the active screen.
        let reunionPromptVisible: Bool
    }

    /// True while this watch owns the pod (phase .active) — the carb/bolus flow
    /// routes delivery LOCALLY during a loan (the phone's pod link is released).
    var isLoanActive: Bool {
        return queue.sync { phase == .active }
    }

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
                suspendEndsAt: nil,
                lastIdleNote: lastIdleNote,
                startedAt: attemptStartedAt,
                handbackPending: handbackRequested,
                handbackStartedAt: handbackStartedAt,
                phoneReachable: isPhoneReachable(),
                handbackFailedAt: handbackFailure?.at,
                handbackFailureText: handbackFailure?.text,
                seizeOfferIssuedAt: seizeOffer?.issuedAt,
                reunionPromptVisible: reunionPromptActive)
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

}
