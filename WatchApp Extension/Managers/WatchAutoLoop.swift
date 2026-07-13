//
//  WatchAutoLoop.swift
//  WatchApp Extension
//
//  The standalone loop's policy layer. OPEN loop (today): it consumes the
//  store's already-computed recommendation and records the trail of what it
//  WOULD enact — visible, nothing dosed — exactly like open loop on the phone.
//  CLOSED loop (B2): `isClosed` becomes true and the same recommendation is
//  enacted. It does NOT compute the prediction — WatchPredictionStore is the
//  single source (the watch's LoopDataManager analog).
//
//  This mirrors Loop's separation: LoopDataManager owns the prediction and the
//  recommendedAutomaticDose; the loop()/enact path reads them. We do the same —
//  the store recomputes on every input change (glucose/carb/journal/settings),
//  posts one didUpdate, and this layer reacts to that single signal rather than
//  re-observing raw sources or running a second engine.
//
//  Design: docs/WATCH_STANDALONE_UI_AUTOLOOP.md. Rails relied on elsewhere:
//  the pod's ≤30-min temp auto-expiry (fail-safe for lenient staleness),
//  pod-layer proof limits, therapy-settings max basal in the shared math.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore
import os.log

@MainActor
final class WatchAutoLoop: ObservableObject {

    enum Decision {
        case setTemp(unitsPerHour: Double, minutes: Int)  // set/refresh a temp
        case suspend(minutes: Int)                        // bounded 0-rate temp
        case cancelTemp                                   // revert to schedule
        case scheduleFits                                 // no change needed
        case staleBG(minutes: Int)
        case noBG

        /// Open loop shows "would…" (advisory); closed loop shows the action
        /// (it was enacted). The ring/header also conveys open vs closed.
        func detailText(closed: Bool) -> String {
            switch self {
            case .setTemp(let rate, let minutes):
                return closed
                    ? String(format: NSLocalizedString("temp %.2f U/hr · %dm", comment: "Loop decision (closed): temp set"), rate, minutes)
                    : String(format: NSLocalizedString("would set %.2f U/hr · %dm", comment: "Loop decision (open): temp it would set"), rate, minutes)
            case .suspend(let minutes):
                return closed
                    ? String(format: NSLocalizedString("suspend · %dm", comment: "Loop decision (closed): suspended"), minutes)
                    : String(format: NSLocalizedString("would suspend · %dm", comment: "Loop decision (open): would suspend"), minutes)
            case .cancelTemp:
                return closed
                    ? NSLocalizedString("→ schedule", comment: "Loop decision (closed): reverted to schedule")
                    : NSLocalizedString("would revert to schedule", comment: "Loop decision (open): would revert")
            case .scheduleFits:
                return NSLocalizedString("schedule fits", comment: "Loop decision: no temp needed")
            case .staleBG(let minutes):
                return String(format: NSLocalizedString("paused — BG %dm old", comment: "Loop decision: glucose too stale to dose"), minutes)
            case .noBG:
                return NSLocalizedString("paused — no BG", comment: "Loop decision: no glucose available")
            }
        }

        /// Records a new history entry only when this changes.
        var changeKey: String {
            switch self {
            case .setTemp(let rate, _): return String(format: "temp:%.2f", rate)
            case .suspend: return "suspend"
            case .cancelTemp: return "cancel"
            case .scheduleFits: return "fits"
            case .staleBG: return "stale"
            case .noBG: return "nobg"
            }
        }
    }

    struct Cycle: Identifiable {
        let id = UUID()
        let date: Date
        let trigger: String
        let bg: HKQuantity?
        let eventual: HKQuantity?
        let math: WatchPredictionOutput.CorrectionMath?
        let decision: Decision
        let wasClosed: Bool
    }

    /// Whether the loop is CLOSED (auto-enacting). Open loop always shows the
    /// recommendation trail below; closing the loop (B2) enacts it. Per-session,
    /// default open — a standalone session never inherits yesterday's decision.
    @Published private(set) var isClosed = false
    @Published private(set) var lastCycle: Cycle?
    /// Rolling shadow-decision history, most-recent-first, for on-wrist
    /// validation (the log trail, made visible). Session-scoped.
    @Published private(set) var recentCycles: [Cycle] = []
    private static let historyLength = 12

    /// Loop's own recency rule — the same constant that gates glucose freshness
    /// on the phone loop and the HUD (via the store), not a bespoke number.
    static let bgStalenessLimit: TimeInterval = LoopCoreConstants.inputDataRecencyInterval

    private let log = OSLog(category: "WatchAutoLoop")
    private let store: WatchPredictionStore
    private let coordinator: WatchPodLoanCoordinator

    private var storeObserver: NSObjectProtocol?
    /// The prediction we last enacted, so we act once per new prediction
    /// (ifNecessary already handles continuation between them).
    private var lastEnactedPredictionDate: Date?

    init(store: WatchPredictionStore, coordinator: WatchPodLoanCoordinator) {
        self.store = store
        self.coordinator = coordinator

        // Open loop runs whenever a session is live — react to the store's
        // single output signal, which fires on every input change and its
        // heartbeat. One source, one signal (mirrors how Loop's dosing reads
        // LoopDataManager); no timer or raw-source observers here.
        storeObserver = NotificationCenter.default.addObserver(forName: WatchPredictionStore.didUpdateNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.evaluate(trigger: "update") }
        }
    }

    deinit {
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
    }

    /// B2 will call this (behind the crown-confirm) to CLOSE the loop and begin
    /// enacting. Today the recommendation trail is always shown; nothing enacts.
    func setClosed(_ closed: Bool) {
        guard closed != isClosed, case .active = coordinator.phase else { return }
        isClosed = closed
        log.default("standalone loop %{public}@", closed ? "CLOSED (B2 will enact here)" : "opened")
    }

    /// Read the store's current recommendation and record it if the decision
    /// changed — the open-loop trail. This is the analog of Loop's loop()
    /// reading LoopDataManager.recommendedAutomaticDose; when closed (B2),
    /// enactment happens here.
    private func evaluate(trigger: String) {
        guard case .active = coordinator.phase else {
            // No live session — nothing to recommend; clear the trail.
            if lastCycle != nil || isClosed {
                isClosed = false
                lastCycle = nil
                recentCycles = []
            }
            return
        }

        let anchor = store.anchorSample

        let decision: Decision
        let bg = anchor?.quantity
        var eventual: HKQuantity?
        var math: WatchPredictionOutput.CorrectionMath?

        if anchor == nil {
            decision = .noBG
        } else if store.isAnchorStale {
            // Lenient staleness (design ruling): stop issuing NEW temps; an
            // active one runs out on the pod's own ≤30-min clock.
            let age = anchor.map { -$0.startDate.timeIntervalSinceNow } ?? 0
            decision = .staleBG(minutes: Int(age / 60))
        } else if let output = store.latestOutput {
            eventual = output.eventualBG
            math = output.correctionMath()
            if let temp = output.recommendedTempBasal {
                if temp.duration == 0 {
                    decision = .cancelTemp
                } else if temp.unitsPerHour == 0 {
                    decision = .suspend(minutes: Int(temp.duration.minutes))
                } else {
                    decision = .setTemp(unitsPerHour: temp.unitsPerHour, minutes: Int(temp.duration.minutes))
                }
            } else {
                decision = .scheduleFits
            }
            enactIfClosed(output)
        } else {
            // Fresh anchor but no successful prediction yet (settings not synced,
            // or the recompute is in flight). Wait for the next store update
            // rather than record a spurious decision.
            return
        }

        // Record only meaningful changes (see Decision.changeKey).
        guard decision.changeKey != lastCycle?.decision.changeKey else { return }

        let cycle = Cycle(date: Date(), trigger: trigger, bg: bg, eventual: eventual, math: math, decision: decision, wasClosed: isClosed)
        lastCycle = cycle
        recentCycles.insert(cycle, at: 0)
        if recentCycles.count > Self.historyLength { recentCycles.removeLast() }
        log.default("loop decision (%{public}@): %{public}@", trigger, decision.detailText(closed: isClosed))
    }

    /// Enact the store's recommendation when the loop is CLOSED — the analog of
    /// Loop's DoseEnactor: one duration-parameterized enactTempBasal straight
    /// from the recommendation (unitsPerHour + duration). Acts once per new
    /// prediction; the recommendation's ifNecessary continuation means it only
    /// carries a temp when a change/refresh is actually needed. Failures surface
    /// loudly via the coordinator; we stay closed and retry next cycle.
    private func enactIfClosed(_ output: WatchPredictionOutput) {
        guard isClosed else { return }
        guard lastEnactedPredictionDate != output.date else { return }
        // Recency guard (mirrors enactRecommendedAutomaticDose's 5-min check).
        guard abs(output.date.timeIntervalSinceNow) < .minutes(5) else { return }
        lastEnactedPredictionDate = output.date

        guard let temp = output.recommendedTempBasal else { return }  // schedule fits — no action
        log.default("closed loop enact: %.2f U/hr for %.0f min", temp.unitsPerHour, temp.duration.minutes)
        coordinator.enactTempBasal(unitsPerHour: temp.unitsPerHour, for: temp.duration)
    }
}
