//
//  WatchAutoLoop.swift
//  WatchApp Extension
//
//  B1 — SHADOW MODE: the standalone closed-loop policy layer. It does NOT
//  compute the prediction — WatchPredictionStore is the single source (the
//  watch's LoopDataManager analog) — it CONSUMES the store's already-computed
//  recommendation and records what it would enact each time that recommendation
//  changes. Doses nothing; B2 puts enactment behind the same gates.
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
        case wouldSetTemp(unitsPerHour: Double, minutes: Int)
        case scheduleFits
        case staleBG(minutes: Int)
        case noBG

        /// Short form for the HUD row / loop screen.
        var detailText: String {
            switch self {
            case .wouldSetTemp(let rate, let minutes):
                return String(format: NSLocalizedString("would set %.2f U/hr · %dm", comment: "Auto-loop decision: temp it would enact"), rate, minutes)
            case .scheduleFits:
                return NSLocalizedString("schedule fits", comment: "Auto-loop decision: no temp needed")
            case .staleBG(let minutes):
                return String(format: NSLocalizedString("paused — BG %dm old", comment: "Auto-loop decision: glucose too stale to dose"), minutes)
            case .noBG:
                return NSLocalizedString("paused — no BG", comment: "Auto-loop decision: no glucose available")
            }
        }

        /// Records a new history entry only when this changes — so the log
        /// captures meaningful changes, not every 60-second re-evaluation.
        /// (Stale minutes and small eventual drifts don't spam the history.)
        var changeKey: String {
            switch self {
            case .wouldSetTemp(let rate, _): return String(format: "temp:%.2f", rate)
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
    }

    /// Per-session opt-in; OFF by default every session — closing the loop is
    /// a deliberate act on the toggle screen, never a remembered preference.
    /// (Deliberate deviation from the phone's persisted `dosingEnabled`: a
    /// standalone session should never inherit yesterday's decision.)
    @Published private(set) var isEnabled = false
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

    init(store: WatchPredictionStore, coordinator: WatchPodLoanCoordinator) {
        self.store = store
        self.coordinator = coordinator
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }

        if enabled {
            // The loop only exists inside a live session — same single-writer
            // boundary as everything else the watch does to the pod.
            guard case .active = coordinator.phase else { return }
            isEnabled = true
            log.default("auto-loop ENABLED (shadow mode — logging only, no dosing)")
            startObserving()
            evaluate(trigger: "enabled")
        } else {
            isEnabled = false
            stopObserving()
            recentCycles = []
            lastCycle = nil
            log.default("auto-loop disabled")
        }
    }

    /// React to the store's single output signal — which already fires on every
    /// input change (glucose/carb/journal/settings) and on its 60-second
    /// heartbeat. No separate timer or raw-source observers: one source, one
    /// signal, mirroring how Loop's dosing reads LoopDataManager.
    private func startObserving() {
        storeObserver = NotificationCenter.default.addObserver(forName: WatchPredictionStore.didUpdateNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.evaluate(trigger: "update") }
        }
    }

    private func stopObserving() {
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
            self.storeObserver = nil
        }
    }

    /// Read the store's current recommendation and record it if the decision
    /// changed. This is the shadow analog of Loop's loop() reading
    /// LoopDataManager.recommendedAutomaticDose; B2 enacts here.
    private func evaluate(trigger: String) {
        guard isEnabled else { return }
        guard case .active = coordinator.phase else {
            // Session over (hand-back/revoke) — the loop dies with it.
            log.default("auto-loop disabled (session ended)")
            isEnabled = false
            stopObserving()
            lastCycle = nil
            recentCycles = []
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
                decision = .wouldSetTemp(unitsPerHour: temp.unitsPerHour, minutes: Int(temp.duration.minutes))
            } else {
                decision = .scheduleFits
            }
        } else {
            // Fresh anchor but no successful prediction yet (settings not synced,
            // or the recompute is in flight). Wait for the next store update
            // rather than record a spurious decision.
            return
        }

        // Record only meaningful changes (see Decision.changeKey).
        guard decision.changeKey != lastCycle?.decision.changeKey else { return }

        let cycle = Cycle(date: Date(), trigger: trigger, bg: bg, eventual: eventual, math: math, decision: decision)
        lastCycle = cycle
        recentCycles.insert(cycle, at: 0)
        if recentCycles.count > Self.historyLength { recentCycles.removeLast() }
        log.default("shadow decision (%{public}@): %{public}@", trigger, decision.detailText)
    }
}
