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

    /// Everything the assembled loop owns, strongly held.
    struct Stack {
        let cgmManager: G7CGMManager
        let loopManager: WatchLoopManager
    }

    /// Constructs and WIRES the whole stock-shaped loop:
    /// stock G7 CGM manager -> WatchLoopManager -> stores, with the enact seam left
    /// unconnected (`loopManager.pumpManager == nil`).
    ///
    /// There is no transport to start. G7CGMManager builds its own CBCentralManager eagerly and
    /// begins scanning as soon as Bluetooth powers on, exactly as it does on the phone; the sensor
    /// authenticates the DEVICE, so the Dexcom watch app's session is what admits us. Our only job
    /// is to be running when a reading arrives — see StockLoopSession's keepalive.
    static func assemble() async -> Stack {
        let stores = await makeStores()

        let loopManager = WatchLoopManager(
            doseStore: stores.doseStore,
            glucoseStore: stores.glucoseStore,
            carbStore: stores.carbStore,
            overrideHistory: stores.overrideHistory
        )

        // Stock, delegate-wired: the manager's CGMManagerDelegate output is the loop's input.
        //
        // Restore persisted state (the stock phone pattern — DeviceDataManager
        // rebuilds its CGM manager from rawState). The bare init here meant every launch and
        // every app update forgot the adopted sensor and reran the acquisition lottery against
        // D2W's ~15s ride windows, leaving the watch relay-covered until it won again.
        // WatchLoopManager persists rawState on cgmManagerDidUpdateState; a corrupt or
        // absent blob falls back to the bare init.
        let cgmManager: G7CGMManager
        if let raw = UserDefaults.standard.dictionary(forKey: WatchLoopManager.cgmStateDefaultsKey),
           let restored = G7CGMManager(rawState: raw) {
            cgmManager = restored
            SportLog.event("cgm", "G7 state RESTORED — sensor \(restored.sensorName ?? "none"), activated \(restored.sensorActivatedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown")")
        } else {
            cgmManager = G7CGMManager()
            SportLog.event("cgm", "G7 state fresh — no persisted sensor; acquisition will run (new install or pre-#101 build)")
        }
        cgmManager.delegateQueue = loopManager.deviceQueue
        cgmManager.cgmManagerDelegate = loopManager

        return Stack(cgmManager: cgmManager, loopManager: loopManager)
    }

    /// The three LoopKit stores against a local (non-app-group) PersistenceController —
    /// carried over verbatim from M1's StoreBringup, which this retires.
    ///
    /// Same construction shape as the phone's DeviceDataManager (DeviceDataManager.swift:315),
    /// in the no-HealthKit mode LoopKit's own tests use (healthKitSampleStore: nil, pending
    /// the owner ruling on watch HealthKit writes — design doc §5.3 #6). DoseStore is built
    /// with nil basal/sensitivity schedules: settings arrive with M5 integration, and missing
    /// settings deny dosing — no fabricated defaults.
    ///
    /// NOTE (unchanged from M1): must not be invoked while the stock watch LoopDataManager is
    /// live — it would open a second PersistenceController against the same local directory.
    /// M5 integration resolves this by unifying store ownership (one PersistenceController).
    static func makeStores() async -> (doseStore: DoseStore, glucoseStore: GlucoseStore, carbStore: CarbStore, overrideHistory: TemporaryScheduleOverrideHistory) {
        // M5 integration: a DISTINCT directory from the stock watch LoopDataManager's
        // controllerInLocalDirectory() store — resolves the M1/M4 caveat about two
        // PersistenceControllers on one directory, so assemble() can safely run beside
        // the stock manager. Full store unification remains a future cleanup.
        let documents = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // Same isReadOnly determination as LoopCore's controllerInLocalDirectory()
        // (its Bundle.isAppExtension helper is module-internal).
        let isAppExtension = Bundle.main.bundleURL.pathExtension == "appex"
        let cacheStore = PersistenceController(directoryURL: documents.appendingPathComponent("com.loopkit.LoopKit.StockLoop"), isReadOnly: isAppExtension)
        let provenanceIdentifier = HKSource.default().bundleIdentifier

        // The override history no longer belongs to the stores — they hold data, not therapy
        // settings, and schedules are resolved per read and handed to the algorithm. It is
        // owned by the loop's TemporaryPresetsManager instead. Still constructed and returned
        // here so the whole stack has ONE history instance: a granted override IS recorded
        // into it at takeover, and without that basal / ISF / carb ratio all resolve UNSCALED
        // during a loan and historical temps net against the wrong baseline.
        let overrideHistory = TemporaryScheduleOverrideHistory()

        let doseStore = await DoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            provenanceIdentifier: provenanceIdentifier
        )

        // Cache lengths mirror the stock watch LoopDataManager's existing choices.
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

        // The shared history is RETURNED, not swallowed. The watch records the
        // granted override into it exactly as the phone's LoopDataManager does
        // (:270 overrideHistory.recordOverride) — without that, basal/ISF/carb-ratio all
        // resolve UNSCALED during a loan and historical temps net against the wrong
        // baseline. Overrides ARE active on the watch during a loan; do not assume
        // otherwise and drop this return value.
        return (doseStore, glucoseStore, carbStore, overrideHistory)
    }
}
