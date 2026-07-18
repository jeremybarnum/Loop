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
//    G7Client (proven transport: J-PAKE via libg7auth, connect-per-reading scheduler)
//        │ raw EGV frames / connection events
//        ▼
//    G7ClientTransportAdapter (M3, stock G7SensorDelegate seam)
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
import LoopCore
import G7SensorKit

enum StockLoopStack {

    /// Everything the assembled loop owns, strongly held.
    struct Stack {
        let client: G7Client
        let cgmManager: G7CGMManager
        let adapter: G7ClientTransportAdapter
        let loopManager: WatchLoopManager
    }

    /// Constructs and WIRES the whole stock-shaped loop:
    /// transport -> adapter -> stock CGM manager -> WatchLoopManager -> stores, with the
    /// enact seam left unconnected (`loopManager.pumpManager == nil`).
    ///
    /// The caller (M5's app integration) starts the transport (client.startSoak() /
    /// prewarmIfPending()) and supplies phone-pushed settings; in M4 nothing invokes this.
    static func assemble() -> Stack {
        let stores = makeStores()

        let loopManager = WatchLoopManager(
            doseStore: stores.doseStore,
            glucoseStore: stores.glucoseStore,
            carbStore: stores.carbStore
        )

        // The M3 CGM stack (formerly G7TransportBringup.makeStack), now delegate-wired:
        // the stock manager's CGMManagerDelegate output is the loop's input.
        let client = G7Client()
        let cgmManager = G7CGMManager()
        let adapter = G7ClientTransportAdapter(client: client, manager: cgmManager)

        cgmManager.delegateQueue = loopManager.deviceQueue
        cgmManager.cgmManagerDelegate = loopManager
        loopManager.attach(cgmStack: adapter)

        return Stack(client: client, cgmManager: cgmManager, adapter: adapter, loopManager: loopManager)
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
    static func makeStores() -> (doseStore: DoseStore, glucoseStore: GlucoseStore, carbStore: CarbStore) {
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

        let doseStore = DoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            basalProfile: nil,
            insulinSensitivitySchedule: nil,
            provenanceIdentifier: provenanceIdentifier
        )

        // Cache lengths mirror the stock watch LoopDataManager's existing choices.
        let glucoseStore = GlucoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            cacheLength: .hours(4),
            provenanceIdentifier: provenanceIdentifier
        )

        let carbStore = CarbStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            cacheLength: .hours(24),
            defaultAbsorptionTimes: LoopCoreConstants.defaultCarbAbsorptionTimes,
            provenanceIdentifier: provenanceIdentifier
        )

        return (doseStore, glucoseStore, carbStore)
    }
}
