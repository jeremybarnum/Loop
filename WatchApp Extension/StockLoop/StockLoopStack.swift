//
//  StockLoopStack.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  Assembles the watch's stores, override history, G7 manager and WatchLoopManager. The pump
//  appears only with a loan.
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import G7SensorKit

enum StockLoopStack {
    /// Both outlive any loan.
    struct Stack {
        let cgmManager: G7CGMManager
        let loopManager: WatchLoopManager
    }

    /// Stores, then the loop manager, then the CGM, whose delegate queue is the loop's device
    /// queue. nil: the stores could not be opened, so no Sport Mode.
    static func assemble() async -> Stack? {
        SportLog.event("session", "stack: assembling")
        guard let stores = await makeStores() else { return nil }

        let loopManager = WatchLoopManager(
            doseStore: stores.doseStore,
            glucoseStore: stores.glucoseStore,
            carbStore: stores.carbStore,
            overrideHistory: stores.overrideHistory
        )

        // A restored identity past its life is dropped here, or the watch would auth-fail against it.
        let cgmManager: G7CGMManager
        if let raw = loopManager.cgmManagerState.wrappedValue,
           let restored = G7CGMManager(rawState: raw),
           !WatchLoopManager.persistedSensorIsPastLife(restored.sensorActivatedAt, reportedEnd: WatchLoopManager.reportedEnd(of: restored)) {
            cgmManager = restored
            SportLog.event("cgm", "G7 state RESTORED — sensor \(restored.sensorName ?? "none"), activated \(restored.sensorActivatedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown")")
        } else {
            cgmManager = G7CGMManager()
            if let raw = loopManager.cgmManagerState.wrappedValue,
               let stale = G7CGMManager(rawState: raw) {
                loopManager.cgmManagerState.wrappedValue = nil
                SportLog.event("cgm", "G7 state DISCARDED at launch — sensor \(stale.sensorName ?? "none") is past its life; acquisition will run instead of auth-failing against a dead identity")
            } else {
                SportLog.event("cgm", "G7 state fresh — no persisted sensor; acquisition will run (new install or pre-#101 build)")
            }
        }
        SportLog.event("session", "stack: cgm wired")
        cgmManager.delegateQueue = loopManager.deviceQueue
        cgmManager.cgmManagerDelegate = loopManager

        loopManager.g7Manager = cgmManager
        loopManager.seedLastDirectG7At(cgmManager.latestReadingTimestamp)

        return Stack(cgmManager: cgmManager, loopManager: loopManager)
    }

    /// The watch's own stores. The directory name carries the LoopKit model version, since this
    /// and the stock watch app share a bundle id. Not read-only: this extension owns them.
    static func makeStores() async -> (doseStore: DoseStore, glucoseStore: GlucoseStore, carbStore: CarbStore, overrideHistory: TemporaryScheduleOverrideHistory)? {
        guard let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            SportLog.event("session", "STACK UNAVAILABLE — no documents directory")
            return nil
        }

        let storeName = "com.loopkit.LoopKit.StockLoop.Modelv6"
        let cacheStore = PersistenceController(directoryURL: documents.appendingPathComponent(storeName), isReadOnly: false)
        SportLog.event("session", "stack: store \(storeName)")
        let provenanceIdentifier = HKSource.default().bundleIdentifier

        // One override history: a second would dose unscaled while the screens showed the override.
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
