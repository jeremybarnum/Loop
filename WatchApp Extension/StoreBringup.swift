//
//  StoreBringup.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  M1 SCAFFOLDING — watch-from-stock rebuild (docs/DESIGN_FROM_STOCK_REBUILD.md §4 M1).
//  Compile-time proof that LoopKit's persistence layer — DoseStore, GlucoseStore,
//  CarbStore, and the PersistenceController they require — links and instantiates
//  on watchOS inside the stock WatchApp Extension.
//
//  Not called from any UI or app flow; zero behavior change to the stock app.
//  Stores are built in the no-HealthKit mode LoopKit's own tests use
//  (healthKitSampleStore: nil), pending the owner ruling on watch HealthKit writes.
//  NOTE: makeStores() must not be invoked while the stock LoopDataManager is live —
//  it opens a second PersistenceController against the same local directory.
//
//  To be absorbed by later milestones: the real watch device manager (M2+) will own
//  these stores, at which point this file is deleted.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore

enum StoreBringup {

    /// Constructs the three LoopKit stores against a local (non-app-group)
    /// PersistenceController, mirroring how the stock watch LoopDataManager
    /// already builds CarbStore and GlucoseStore. DoseStore is the M1 addition:
    /// it did not previously exist anywhere on the watch.
    static func makeStores() -> (doseStore: DoseStore, glucoseStore: GlucoseStore, carbStore: CarbStore) {
        let cacheStore = PersistenceController.controllerInLocalDirectory()
        let provenanceIdentifier = HKSource.default().bundleIdentifier

        // Same construction shape as the phone's DeviceDataManager (DeviceDataManager.swift:315),
        // minus HealthKit and minus settings plumbing (settings arrive in later milestones;
        // per the design doc, missing settings deny dosing — no fabricated defaults here).
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
