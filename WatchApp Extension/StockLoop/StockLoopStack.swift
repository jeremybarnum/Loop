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
    static func assemble() async -> Stack? {
        SportLog.event("session", "stack: assembling")
        guard let stores = await makeStores() else { return nil }

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
        // THE ESCAPE MUST RUN ON THIS PATH TOO (2026-08-21, ported from pure/SportMode).
        // #104's age escape — past 10d12h, honour a nil and clear the identity — lived ONLY on
        // the write path (cgmManagerDidUpdateState). Launch restored the persisted blob with no
        // age test at all, and once restored the manager auto-connects to it and the escape never
        // gets another chance. Their field case: an identity restored 19 hours past its own
        // expiry, then three days of auth failures against a sensor that no longer existed
        // (267 "unknownCharacteristic"), zero direct readings, while the replacement advertised
        // beside it the whole time. Invisible until the phone walks away, because relay covers it.
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
        // The stranded-identity rule needs to clear state and ask for a rescan; the manager is
        // owned here, and WatchLoopManager is only its delegate.
        loopManager.g7Manager = cgmManager
        G7RadioCensus.sensorSighted = { [weak loopManager] name in loopManager?.noteSensorSighted(name) }

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
    static func makeStores() async -> (doseStore: DoseStore, glucoseStore: GlucoseStore, carbStore: CarbStore, overrideHistory: TemporaryScheduleOverrideHistory)? {
        // M5 integration: a DISTINCT directory from the stock watch LoopDataManager's
        // controllerInLocalDirectory() store — resolves the M1/M4 caveat about two
        // PersistenceControllers on one directory, so assemble() can safely run beside
        // the stock manager. Full store unification remains a future cleanup.
        // NOT try!: a documents directory this app cannot reach is a reason for Sport Mode to be
        // unavailable, not a reason for the whole watch app to die on launch.
        guard let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            SportLog.event("session", "STACK UNAVAILABLE — no documents directory")
            return nil
        }
        // Same isReadOnly determination as LoopCore's controllerInLocalDirectory()
        // (its Bundle.isAppExtension helper is module-internal).
        let isAppExtension = Bundle.main.bundleURL.pathExtension == "appex"
        // The directory name carries the LoopKit MODEL VERSION, and must keep doing so.
        //
        // This branch and the SportMode fork ship under the SAME bundle identifier, so installing
        // one over the other inherits the other's store — and their LoopKit models are not the
        // same (the fork is at Modelv4, this branch at Modelv6, which changed the optionality of
        // CachedGlucoseObject attributes). Reading a v4 row through v6's non-optional accessors
        // traps inside StoredGlucoseSample(managedObject:), which is a crash on the glucose
        // INGEST path — i.e. every few minutes, forever, with no way to get back into the app.
        //
        // Versioning the path sidesteps migration entirely rather than betting on lightweight
        // migration across two branches that evolve independently. It is safe to strand the old
        // directory: everything here is a CACHE. Doses, carbs and glucose are re-seeded from the
        // grant at every takeover, and the G7 refills glucose within minutes. The one piece of
        // loan state that must survive — the event journal — is a separate JSON file in
        // Application Support (PodLoanJournalV2.json) and is untouched by this.
        let storeName = "com.loopkit.LoopKit.StockLoop.Modelv6"
        let cacheStore = PersistenceController(directoryURL: documents.appendingPathComponent(storeName), isReadOnly: isAppExtension)
        SportLog.event("session", "stack: store \(storeName)")
        let provenanceIdentifier = HKSource.default().bundleIdentifier

        // The override history no longer belongs to the stores — they hold data, not therapy
        // settings, and schedules are resolved per read and handed to the algorithm. It is
        // owned by the loop's TemporaryPresetsManager instead. Still constructed and returned
        // here so the whole stack has ONE history instance: a granted override IS recorded
        // into it at takeover, and without that basal / ISF / carb ratio all resolve UNSCALED
        // during a loan and historical temps net against the wrong baseline.
        let overrideHistory = TemporaryScheduleOverrideHistory()

        SportLog.event("session", "stack: opening stores")
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
        SportLog.event("session", "stack: stores open")
        return (doseStore, glucoseStore, carbStore, overrideHistory)
    }
}
