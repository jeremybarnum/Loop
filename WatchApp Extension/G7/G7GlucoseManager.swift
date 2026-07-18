//
//  G7GlucoseManager.swift
//  Bridges the phone-free G7 reader into the watch loop.
//
//  Runs G7Client (the validated pending-connect reacquire), and on every fresh EGV injects it as a
//  real CGM sample (wasUserEntered = false → full effects incl. momentum / retrospective correction)
//  into the loop's glucose store, then pokes the prediction store to run a loop tick. This is the
//  phone-free replacement for the phone's CGM stream that used to arrive over WatchConnectivity.
//

import Foundation
import HealthKit
import LoopKit

/// File-log alias for app code (WatchAutoLoop etc.), where `log` is shadowed by an OSLog member.
/// Lands in Documents/g7watch.log alongside the G7 BLE trace so one file tells the whole story.
func fileLog(_ line: String) { log(line) }

final class G7GlucoseManager {
    let client = G7Client()
    private unowned let loopManager: LoopDataManager
    private unowned let predictionStore: WatchPredictionStore
    private var lastInjected: Date?

    init(loopManager: LoopDataManager, predictionStore: WatchPredictionStore) {
        self.loopManager = loopManager
        self.predictionStore = predictionStore
        client.reconnectMode = true   // the validated pending-connect reacquire (NOT background scan)
        client.onEGV = { [weak self] mgdl, date, timestamp in
            self?.inject(mgdl: mgdl, at: date, timestamp: timestamp)
        }
    }

    /// Start the phone-free reader (pending-connect reacquire + workout keepalive).
    func start() { log("loop-bridge: G7GlucoseManager START (reconnect mode)"); client.startSoak() }
    func stop()  { log("loop-bridge: G7GlucoseManager STOP"); client.stopSoak() }
    /// Foreground re-arm of the keepalive (background relaunch leaves it dead — HK error 14).
    func ensureKeepalive() { client.ensureKeepalive() }

    private func inject(mgdl: Int, at date: Date, timestamp: UInt32) {
        // `date` is the on-body measurement time (not read-completion time). The G7 emits one EGV
        // per ~5 min; guard a duplicate within a window (a re-read has the SAME measurement date).
        if let last = lastInjected, date.timeIntervalSince(last) < 60 {
            log("loop-bridge: EGV \(mgdl) mg/dL skipped (duplicate <60s)")
            return
        }
        lastInjected = date

        // H1: clamp to the G7's reportable range and carry the range condition,
        // exactly as stock G7GlucoseMessage.condition does (below G7 minimum →
        // .belowRange @ 40; above maximum → .aboveRange @ 400). A real severe LOW
        // thus enters as 40/.belowRange and DRIVES A SUSPEND rather than being
        // dropped. Asymmetry by design: a low always reaches the loop (safe
        // direction); the state-0x06 gate upstream is what rejects non-confident
        // (warmup/error) readings. In practice the sensor already clamps at 40,
        // so this is correctness hardening more than an active hazard.
        let condition: GlucoseCondition?
        let clamped: Int
        if mgdl < 40 { clamped = 40; condition = .belowRange }
        else if mgdl > 400 { clamped = 400; condition = .aboveRange }
        else { clamped = mgdl; condition = nil }
        log("loop-bridge: injecting EGV \(mgdl) mg/dL\(condition != nil ? " (\(condition!.rawValue) → \(clamped))" : "") → glucoseStore")

        let sample = NewGlucoseSample(
            date: date,
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(clamped)),
            condition: condition,
            trend: nil,
            trendRate: nil,
            isDisplayOnly: false,
            wasUserEntered: false,   // real CGM → full effects (momentum / retrospective correction)
            syncIdentifier: "g7-\(timestamp)"   // sensor-clock reading id → a RE-READ of the same EGV dedups in the store
        )
        loopManager.glucoseStore.addGlucoseSamples([sample]) { [weak self] result in
            switch result {
            case .success(let stored):
                log("loop-bridge: stored \(stored.count) sample(s) ✓ → loop tick")
            case .failure(let error):
                log("*** loop-bridge: glucoseStore INJECTION FAILED: \(error) ***")
            }
            DispatchQueue.main.async {
                // DISPLAY-only refresh. On a successful store, addGlucoseSamples already posted
                // glucoseSamplesDidChange, which drives the store's own loopWorthy refresh → the
                // enact; adding loopWorthy here too was a redundant SECOND enact-trigger per reading
                // (a contributor to the pod-command storm). We keep a forced display refresh so
                // staleness surfaces even after a store failure (where no observer fires).
                self?.predictionStore.refresh(force: true)
            }
        }
    }
}
