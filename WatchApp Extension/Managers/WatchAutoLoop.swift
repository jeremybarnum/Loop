//
//  WatchAutoLoop.swift
//  WatchApp Extension
//
//  B1 — SHADOW MODE: runs the standalone closed-loop cycle (gate on BG
//  freshness, predict, recommend) on the session cadence and LOGS what it
//  would enact. It doses NOTHING. B2 puts enactment behind these same gates
//  once shadow logs look sane on the sim and at the bench.
//
//  Design: docs/WATCH_STANDALONE_UI_AUTOLOOP.md. Rails that live elsewhere
//  and are relied on here: the pod's ≤30-min temp auto-expiry (fail-safe for
//  the lenient staleness policy), pod-layer proof limits beneath everything,
//  and therapy-settings max basal inside the shared recommendation math.
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
        case failed(String)

        /// Short form for the HUD row / toggle screen.
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
            case .failed(let message):
                return message
            }
        }
    }

    struct Cycle {
        let date: Date
        let decision: Decision
    }

    /// Per-session opt-in; OFF by default every session — closing the loop is
    /// a deliberate act on the toggle screen, never a remembered preference.
    /// (Deliberate deviation from the phone's persisted `dosingEnabled`: a
    /// standalone session should never inherit yesterday's decision.)
    @Published private(set) var isEnabled = false
    @Published private(set) var lastCycle: Cycle?

    static let cadence: TimeInterval = .minutes(5)
    /// Loop's own recency rule — the same constant that gates glucose
    /// freshness on the phone loop and the HUD, not a bespoke number.
    static let bgStalenessLimit: TimeInterval = LoopCoreConstants.inputDataRecencyInterval
    /// New-sample bursts (entry + backfill sync) collapse into one cycle.
    private static let minCycleInterval: TimeInterval = 30

    private let log = OSLog(category: "WatchAutoLoop")
    private let loopManager: LoopDataManager
    private let coordinator: WatchPodLoanCoordinator
    private lazy var engine = WatchPredictionEngine(loopManager: loopManager, coordinator: coordinator)

    private var timer: Timer?
    private var sampleObserver: NSObjectProtocol?
    private var lastCycleStart: Date = .distantPast

    init(loopManager: LoopDataManager, coordinator: WatchPodLoanCoordinator) {
        self.loopManager = loopManager
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
            startTriggers()
            runCycle(reason: "enabled")
        } else {
            isEnabled = false
            stopTriggers()
            log.default("auto-loop disabled")
        }
    }

    /// Cycle triggers: the 5-minute cadence plus every new glucose sample
    /// (dialed entry landing, backfill sync — same signal the HUD uses).
    private func startTriggers() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.cadence, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runCycle(reason: "timer") }
        }
        sampleObserver = NotificationCenter.default.addObserver(forName: GlucoseStore.glucoseSamplesDidChange, object: loopManager.glucoseStore, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.runCycle(reason: "new sample") }
        }
    }

    private func stopTriggers() {
        timer?.invalidate()
        timer = nil
        if let observer = sampleObserver {
            NotificationCenter.default.removeObserver(observer)
            sampleObserver = nil
        }
    }

    private func runCycle(reason: String) {
        guard isEnabled else { return }
        guard case .active = coordinator.phase else {
            // Session over (hand-back/revoke) — the loop dies with it.
            log.default("auto-loop disabled (session ended)")
            isEnabled = false
            stopTriggers()
            lastCycle = nil
            return
        }
        guard -lastCycleStart.timeIntervalSinceNow > Self.minCycleInterval else { return }
        lastCycleStart = Date()

        engine.latestGlucose { [weak self] sample in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }

                guard let sample else {
                    self.record(.noBG, reason: reason)
                    return
                }
                let age = -sample.startDate.timeIntervalSinceNow
                guard age <= Self.bgStalenessLimit else {
                    // Lenient staleness (design ruling): stop issuing NEW temps;
                    // the active one runs out on the pod's own ≤30-min clock.
                    self.record(.staleBG(minutes: Int(age / 60)), reason: reason)
                    return
                }

                self.engine.predict(manualBG: sample.quantity, storeEntry: false) { result in
                    Task { @MainActor in
                        guard self.isEnabled else { return }
                        switch result {
                        case .success(let output):
                            if let temp = output.recommendedTempBasal {
                                // B2 enacts here, behind these same gates.
                                self.record(.wouldSetTemp(unitsPerHour: temp.unitsPerHour, minutes: Int(temp.duration.minutes)), reason: reason)
                            } else {
                                self.record(.scheduleFits, reason: reason)
                            }
                        case .failure(let error):
                            self.record(.failed(error.localizedDescription), reason: reason)
                        }
                    }
                }
            }
        }
    }

    private func record(_ decision: Decision, reason: String) {
        lastCycle = Cycle(date: Date(), decision: decision)
        log.default("shadow cycle (%{public}@): %{public}@", reason, decision.detailText)
    }
}
