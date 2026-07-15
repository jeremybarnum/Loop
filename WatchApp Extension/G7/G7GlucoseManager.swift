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
        client.onEGV = { [weak self] mgdl, date in
            self?.inject(mgdl: mgdl, at: date)
        }
    }

    /// Start the phone-free reader (pending-connect reacquire + workout keepalive).
    func start() { log("loop-bridge: G7GlucoseManager START (reconnect mode)"); client.startSoak() }
    func stop()  { log("loop-bridge: G7GlucoseManager STOP"); client.stopSoak() }

    private func inject(mgdl: Int, at date: Date) {
        // The G7 emits one EGV per ~5 min; guard a duplicate within a window.
        if let last = lastInjected, date.timeIntervalSince(last) < 60 {
            log("loop-bridge: EGV \(mgdl) mg/dL skipped (duplicate <60s)")
            return
        }
        lastInjected = date
        log("loop-bridge: injecting EGV \(mgdl) mg/dL → glucoseStore")

        let sample = NewGlucoseSample(
            date: date,
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(mgdl)),
            condition: nil,
            trend: nil,
            trendRate: nil,
            isDisplayOnly: false,
            wasUserEntered: false,   // real CGM → full effects (momentum / retrospective correction)
            syncIdentifier: "g7-\(Int(date.timeIntervalSince1970))"
        )
        loopManager.glucoseStore.addGlucoseSamples([sample]) { [weak self] result in
            switch result {
            case .success(let stored):
                log("loop-bridge: stored \(stored.count) sample(s) ✓ → loop tick")
            case .failure(let error):
                log("*** loop-bridge: glucoseStore INJECTION FAILED: \(error) ***")
            }
            DispatchQueue.main.async {
                // New glucose is a loop tick: run the prediction and (if the loop is closed) enact.
                // Refresh even after a store failure so staleness surfaces rather than freezes.
                self?.predictionStore.refresh(force: true, loopWorthy: true)
            }
        }
    }
}
