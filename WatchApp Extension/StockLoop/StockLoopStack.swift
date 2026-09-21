//
//  StockLoopStack.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  M4 of the watch-from-stock rebuild (docs/DESIGN_FROM_STOCK_REBUILD.md §4 M4): the single
//  assembly point for the stock-shaped watch closed loop. Absorbs and retires the earlier
//  bring-up scaffolding:
//    - M1 StoreBringup.makeStores()        -> makeStores() here (same construction, verbatim)
//    - M3 G7TransportBringup.makeStack()   -> the CGM stack construction inside assemble()
//
//  Assembled graph:
//
//        │ raw EGV frames / connection events
//        ▼
//        ▼
//    G7CGMManager (stock G7SensorKit-watchOS: parse, dedup, reliability gating, clamping)
//        │ CGMManagerDelegate (delegateQueue = WatchLoopManager.deviceQueue)
//        ▼
//    WatchLoopManager (this milestone: the phone's LoopDataManager policy paths in miniature)
//        │ GlucoseStore ── CarbStore ── DoseStore (LoopKit, real persistence, M1)
//        │ recency gating (LoopCoreConstants.inputDataRecencyInterval)
//        │ prediction (LoopMath.predictGlucose over store-derived effects)
//        │ recommendation (DoseMath recommendedTempBasal, IOB clamp inside the call)
//        ▼
//    PumpManager enact seam ──── UNCONNECTED in M4 (M5: the loaned OmniPumpManager, M2)
//
//  M4 IS CONSTRUCTION + COMPILE PROOF ONLY. assemble() has no call sites in the app flow;
//  nothing starts the transport, nothing doses, zero behavior change to the stock watch app.
//  M5 integration gives ownership of this stack to the app lifecycle (and must then also
//  reconcile store ownership with the stock watch LoopDataManager — see makeStores()).
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import G7SensorKit

enum StockLoopStack {
    struct Stack {
        let cgmManager: G7CGMManager
        let loopManager: WatchLoopManager
    }

    static func assemble() async -> Stack? {
        SportLog.event("session", "stack: assembling")
        guard let stores = await makeStores() else { return nil }

        let loopManager = WatchLoopManager(
            doseStore: stores.doseStore,
            glucoseStore: stores.glucoseStore,
            carbStore: stores.carbStore,
            overrideHistory: stores.overrideHistory
        )

        let cgmManager: G7CGMManager
        if let raw = UserDefaults.standard.dictionary(forKey: WatchLoopManager.cgmStateDefaultsKey),
           let restored = G7CGMManager(rawState: raw),
           !WatchLoopManager.persistedSensorIsPastLife(restored.sensorActivatedAt) {
            cgmManager = restored
            SportLog.event("cgm", "G7 state RESTORED — sensor \(restored.sensorName ?? "none"), activated \(restored.sensorActivatedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown")")
        } else {
            cgmManager = G7CGMManager()
            if let raw = UserDefaults.standard.dictionary(forKey: WatchLoopManager.cgmStateDefaultsKey),
               let stale = G7CGMManager(rawState: raw) {
                UserDefaults.standard.removeObject(forKey: WatchLoopManager.cgmStateDefaultsKey)
                SportLog.event("cgm", "G7 state DISCARDED at launch — sensor \(stale.sensorName ?? "none") is past its life; acquisition will run instead of auth-failing against a dead identity")
            } else {
                SportLog.event("cgm", "G7 state fresh — no persisted sensor; acquisition will run (new install or pre-#101 build)")
            }
        }
        SportLog.event("session", "stack: cgm wired")
        cgmManager.delegateQueue = loopManager.deviceQueue
        cgmManager.cgmManagerDelegate = loopManager

        loopManager.g7Manager = cgmManager

        return Stack(cgmManager: cgmManager, loopManager: loopManager)
    }

    static func makeStores() async -> (doseStore: DoseStore, glucoseStore: GlucoseStore, carbStore: CarbStore, overrideHistory: TemporaryScheduleOverrideHistory)? {
        guard let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            SportLog.event("session", "STACK UNAVAILABLE — no documents directory")
            return nil
        }

        let storeName = "com.loopkit.LoopKit.StockLoop.Modelv6"
        let cacheStore = PersistenceController(directoryURL: documents.appendingPathComponent(storeName), isReadOnly: false)
        SportLog.event("session", "stack: store \(storeName)")
        let provenanceIdentifier = HKSource.default().bundleIdentifier

        let overrideHistory = TemporaryScheduleOverrideHistory()

        SportLog.event("session", "stack: opening stores")
        let doseStore = await DoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            provenanceIdentifier: provenanceIdentifier
        )

        let glucoseStore = await GlucoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            cacheLength: .hours(4),
            provenanceIdentifier: provenanceIdentifier
        )

        let carbStore = CarbStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            cacheLength: .hours(24),
            provenanceIdentifier: provenanceIdentifier
        )

        SportLog.event("session", "stack: stores open")
        return (doseStore, glucoseStore, carbStore, overrideHistory)
    }
}
