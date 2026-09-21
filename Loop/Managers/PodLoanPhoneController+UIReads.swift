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

    // MARK: - Non-blocking UI reads

    /// THE PUMP TILE MUST NEVER TAKE THE LOAN QUEUE. It draws on the main thread, and this queue
    /// is the one doing BLE work, store commits and reconcile — so a `queue.sync` from a tile
    /// refresh puts the main thread behind whatever the reclaim is currently doing. Field-proven
    /// on 2026-08-16: a settle that stalled held the queue, the tile blocked main behind it, and
    /// the ENTIRE phone UI froze until the app was force-quit. The pod was fine throughout; only
    /// the interface was gone.
    ///
    /// So the tile reads a mirror under a plain lock, refreshed opportunistically from the queue.
    /// The mirror caches the reclaim's INPUTS (its anchors and phase), never a finished
    /// `ReclaimProgress` — the derivation is re-run against a fresh `now` on every read, so the
    /// elapsed counter keeps ticking truthfully even while the queue is wedged and the snapshot
    /// itself is stale. That is exactly the case where the seconds matter most: they are the only
    /// thing distinguishing still-working from stuck.
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


    /// Captures the fields the tile derives from. MUST be called on `queue`.
    func uiSnapshot() -> UISnapshot {
        var s = UISnapshot()
        // The yielded posture counts: the tile's tap handler routes on this, and the phone is
        // not controlling the pod in a yield any more than in a loan. Before 2026-09-13 this
        // read `state != .owner` alone while the tile's LABEL said Pod on Watch — the tap fell
        // through to the stock pod screen and the user had no way back to Reclaim Now.
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

    /// Writes the mirror from data the caller already holds. MUST be called on `queue`.
    ///
    /// EVERY transition the tile draws must call this BEFORE it notifies. The async refresh below
    /// is not enough on its own: a re-render triggered by the state change would read the mirror
    /// before the async write lands, draw the PREVIOUS state, and then sit there — nothing
    /// re-renders a second time. Field-seen on 2026-08-16: the watch went live while the phone
    /// kept saying "Handing over…" until the user swiped, which forced an unrelated redraw.
    func syncUIMirror() {
        let s = uiSnapshot()
        uiMirrorLock.lock()
        uiMirror = s
        uiMirrorLock.unlock()
    }

    /// Refreshes the mirror from the queue. Cheap and idempotent; safe to call from anywhere.
    func refreshUIMirror() {
        queue.async { [weak self] in
            guard let self else { return }
            let s = self.uiSnapshot()
            self.uiMirrorLock.lock()
            self.uiMirror = s
            self.uiMirrorLock.unlock()
        }
    }

    /// The tile's read. Never blocks: it returns the last mirror and asks for a fresh one.
    var uiState: UISnapshot {
        refreshUIMirror()
        uiMirrorLock.lock()
        defer { uiMirrorLock.unlock() }
        return uiMirror
    }

    /// The single derivation, shared by the blocking accessor and the tile's non-blocking one, so
    /// the two can never drift into describing the same reclaim differently.
    static func reclaimProgress(from s: UISnapshot, now: Date) -> ReclaimProgress? {
        // `.reconciling` is part of the tapped handover, not a gap in it: the drain's records
        // are being written, and the label the user is reading was chosen by this ladder's
        // branch. Guarding on `.reclaimPending` alone dropped the phase for the length of one
        // Core Data write, which relabels a dead-watch reclaim from its branch label to the
        // generic "Reclaiming…" mid-write and then back.
        if s.ladderIsRunning, let ladderStartedAt = s.ladderStartedAt {
            let elapsed = max(now.timeIntervalSince(ladderStartedAt), 0)
            // The live handover draws a determinate bar against the drain promise — the
            // sweep is retired (field ruling). Past the promise the phase concedes and the
            // bar holds at cap; the force at 25 s is what actually resolves it. The forcing
            // phase (dead branch, or a live force mid-deferral) keeps a nil fraction: its
            // own settle bar arrives within a second.
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
        // The settle predicate is restated inline rather than read from `isReclaimSettling`:
        // that accessor takes the same serial queue this block is already running on, and a
        // nested sync onto a serial queue deadlocks. It is `isReclaimSettling` and not
        // `isReclaimSettlingOnly` that it must match, ceiling term included — the pill draws
        // this fraction BEFORE it checks whether a reclaim is in progress at all, so a bar
        // that outlived the "Reclaiming…" tile would paint itself under some other label.
        if s.isOwner, let started = s.reclaimStartedAt, !s.reclaimVerified,
           now.timeIntervalSince(started) < Self.reclaimSettleTimeout {
            let elapsed = max(now.timeIntervalSince(started), 0)
            // A settle that follows a FORCE reclaim is one operation to the user — the tile
            // just told them the watch could not be reached — so it runs ONE stage against
            // its own promise instead of the fast/slow re-baseline, which mid-force would
            // read as a second failure. The audit flavor is the marker: the force path arms
            // it before ownership flips, and it is consumed only after the verification this
            // bar is waiting on.
            if s.auditIsForceReclaim {
                // Same promise as the ordinary settle (one const, by the 2026-08-23 lean
                // ruling) — the label differs, the physics no longer do.
                return ReclaimProgress(
                    phase: .forceReclaimingPod, startedAt: started,
                    expectedBy: started.addingTimeInterval(Self.reclaimSettleExpectation),
                    fraction: min(elapsed / Self.reclaimSettleExpectation, 0.95),
                    elapsed: elapsed)
            }
            // One stage, anchored where the USER'S wait began — the tap for a phone
            // reclaim, the settle open for a watch-initiated one — so the bar is a single
            // continuous fill across the handover and the settle. Caps at 0.95 and HOLDS
            // there on an overrun: the settle's real bound is `reclaimSettleTimeout`, not
            // the expectation, so a bar that has run out of deadline must read as
            // nearly-done-and-still-working rather than as finished.
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

    /// Non-blocking twins of the predicates above, for the tile. See `UISnapshot`.
    /// Mirror-backed and lock-only — safe from any thread. The alert manager's
    /// Loop-Failure suppression gate reads this on every phone cycle completion.
    var isLoanedOutForUI: Bool { return uiState.isLoanedOut }

    /// The TILE's gate: any reclaim activity at all — the drain/force ladder OR the settle.
    /// The old gate was settle-only, so a dead-watch force showed "Pod on Watch" for the whole
    /// 25 s ladder (field, 2026-08-23): the ladder runs with state still .loaned, isSettlingOnly
    /// false throughout, and the first honest frame arrived only at .owner — by which time the
    /// settle was 5 s and the render never caught it. The mirror already carries both flags and
    /// every state change syncs it before notifying, so this is purely the gate widening.
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
