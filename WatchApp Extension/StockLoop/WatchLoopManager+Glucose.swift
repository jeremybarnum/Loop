//
//  WatchLoopManager+Glucose.swift
//  WatchApp Extension
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import G7SensorKit
import WatchConnectivity
import os.log

extension WatchLoopManager: CGMManagerDelegate {
    func startDateToFilterNewData(for manager: CGMManager) -> Date? {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        return glucoseStore.latestGlucose?.startDate
    }

    func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        log.default("CGMManager:%{public}@ did update with %{public}@", String(describing: type(of: manager)), String(describing: readingResult))
        processCGMReadingResult(manager, readingResult: readingResult) {
            let now = self.now()

            if case .newData = readingResult, now.timeIntervalSince(self.lastCGMLoopTrigger) > .minutes(4.2) {
                self.log.default("Triggering loop from new CGM data at %{public}@", String(describing: now))
                self.lastCGMLoopTrigger = now

                self.checkPumpDataAndLoop()
            }

            if case .newData = readingResult {
                Self.queueLogTransferThrottled()
            }
        }
    }

    var latestGlucoseAge: TimeInterval? {
        return glucoseStore.latestGlucose.map { self.now().timeIntervalSince($0.startDate) }
    }

    private static var lastLogTransfer = Date.distantPast
    static func queueLogTransferThrottled() {
        guard Date().timeIntervalSince(lastLogTransfer) > 4.5 * 60 else { return }
        guard WCSession.default.activationState == .activated, let url = LogFile.url else { return }
        lastLogTransfer = Date()
        WCSession.default.transferFile(url, metadata: ["kind": "g7watch.log"])
    }

    private func processCGMReadingResult(_ manager: CGMManager, readingResult: CGMReadingResult, completion: @escaping () -> Void) {
        switch readingResult {
        case .newData(let rawValues):
            let values = rawValues

            dropAlreadyStored(values) { kept in

            let deliveredCount = values.count
            let latest = kept.max(by: { $0.date < $1.date }) ?? values.max(by: { $0.date < $1.date })
            let latestDesc: String = {
                guard let s = latest else { return "none" }
                let mgdl = Int(s.quantity.doubleValue(for: .milligramsPerDeciliter).rounded())
                return "\(mgdl) mg/dL age \(Int(self.now().timeIntervalSince(s.date)))s"
            }()
            let batchTag = deliveredCount > 1 ? " BATCH(backfill+live)" : ""

            if deliveredCount > 0 { self.noteGlucoseSource(directG7: true) }

            SportLog.event("glucose",
                "INGEST src=direct-G7 kept=\(kept.count)/\(deliveredCount) · latest \(latestDesc)\(batchTag)")
            guard !kept.isEmpty else { completion(); return }
            Task {
                do {
                    _ = try await self.glucoseStore.addGlucoseSamples(kept)

                    if let newest = kept.map(\.date).max(),
                       (self.glucoseStore.latestGlucose?.startDate ?? .distantPast) < newest.addingTimeInterval(-1) {
                        SportLog.event("glucose", "STORE LATEST IS STALE after a write — wrote up to \(newest), store says \(self.glucoseStore.latestGlucose.map { String(describing: $0.startDate) } ?? "nil") [glucose-store]")
                    }
                } catch {
                    self.log.error("Failure adding glucose samples: %{public}@", String(describing: error))
                    SportLog.event("glucose", "STORE WRITE FAILED — \(kept.count) reading(s) NOT written: \(error) [glucose-store]")
                }

                self.dataAccessQueue.async { self.publishOwnGlucoseContextWhenIdle() }
                completion()
            }
            }
        case .unreliableData:

            log.default("CGM reported unreliable data")
            completion()
        case .noData:
            completion()
        case .error(let error):
            log.error("CGM reading error: %{public}@", String(describing: error))
            completion()
        }
    }

    func cgmManager(_ manager: CGMManager, hasNew events: [PersistedCgmEvent]) {
        log.default("CGM event(s): %{public}d", events.count)
    }

    @MainActor
    func ingestPhoneGlucoseFromContext() {
        guard pumpManager != nil else { return }

        guard let ctx = ExtensionDelegate.sharedIfAvailable()?.loopManager.phoneRelayContext,
              let sample = ctx.newGlucoseSample else { return }
        deviceQueue.async {
            if sample.syncIdentifier == self.lastPhoneFallbackSyncId { return }
            self.lastPhoneFallbackSyncId = sample.syncIdentifier

            if let latest = self.glucoseStore.latestGlucose?.startDate, latest >= sample.date { return }
            self.dropAlreadyStored([sample]) { kept in
            guard !kept.isEmpty else { return }
            Task {
                do {
                    _ = try await self.glucoseStore.addGlucoseSamples(kept)
                } catch {
                    self.log.error("phone-BG fallback add failed: %{public}@", String(describing: error))
                    return
                }
                let mgdl = Int(sample.quantity.doubleValue(for: .milligramsPerDeciliter))
                self.noteGlucoseSource(directG7: false)
                SportLog.event("glucose",
                    "INGEST src=phone-relay stored=1/1 · latest \(mgdl) mg/dL age \(Int(self.now().timeIntervalSince(sample.date)))s (direct-G7 gap)")
                SportLog.event("loan", "phone-BG fallback: ingested \(mgdl) mg/dL syncId=\(sample.syncIdentifier ?? "?") (direct-G7 gap) — triggering loop")
                let now = self.now()
                if now.timeIntervalSince(self.lastCGMLoopTrigger) > .minutes(4.2) {
                    self.lastCGMLoopTrigger = now
                    self.checkPumpDataAndLoop()
                }
            }
            }
        }
    }

    private static func sensorIdentity(_ syncIdentifier: String?) -> String? {
        guard let s = syncIdentifier, let sp = s.firstIndex(of: " ") else { return nil }
        let tail = s[s.index(after: sp)...]
        return tail.isEmpty ? nil : String(tail)
    }

    private func dropAlreadyStored(_ samples: [NewGlucoseSample],
                                   completion: @escaping ([NewGlucoseSample]) -> Void) {
        let wanted = samples.compactMap { Self.sensorIdentity($0.syncIdentifier) }
        guard !wanted.isEmpty else { completion(samples); return }

        let since = self.now().addingTimeInterval(-.minutes(30))
        Task {
            guard let stored = try? await glucoseStore.getGlucoseSamples(start: since, end: nil) else {
                completion(samples)
                return
            }
            let seen = Set(stored.compactMap { Self.sensorIdentity($0.syncIdentifier) })
            guard !seen.isEmpty else { completion(samples); return }
            var dropped: [String] = []
            let kept = samples.filter { s in
                guard let id = Self.sensorIdentity(s.syncIdentifier), seen.contains(id) else { return true }
                dropped.append(id)
                return false
            }
            if !dropped.isEmpty {
                SportLog.event("glucose", "#83 dedup: dropped \(dropped.count) already-filed reading(s) [\(dropped.joined(separator: ", "))] — same sensor stamp, different device name tag")
            }
            completion(kept)
        }
    }

    #if targetEnvironment(simulator)

    @MainActor
    func simIngestPhoneGlucose() {
        let ctx = ExtensionDelegate.sharedIfAvailable()?.loopManager.activeContext
        guard let quantity = ctx?.glucose, let date = ctx?.glucoseDate else { return }
        deviceQueue.async {
            if let latest = self.glucoseStore.latestGlucose?.startDate, latest >= date { return }
            let sample = NewGlucoseSample(
                date: date,
                quantity: quantity,
                condition: nil,
                trend: ctx?.glucoseTrend,
                trendRate: ctx?.glucoseTrendRate,
                isDisplayOnly: false,
                wasUserEntered: false,
                syncIdentifier: "sim-\(Int(date.timeIntervalSince1970))")
            Task {
                do {
                    _ = try await self.glucoseStore.addGlucoseSamples([sample])
                } catch {
                    self.log.error("SIM glucose add failed: %{public}@", String(describing: error))
                }

                let now = self.now()
                if now.timeIntervalSince(self.lastCGMLoopTrigger) > .minutes(4.2) {
                    self.lastCGMLoopTrigger = now
                    SportLog.event("sim", "SIM CGM \(Int(quantity.doubleValue(for: .milligramsPerDeciliter))) mg/dL (phone sim) — triggering real loop")
                    self.checkPumpDataAndLoop()
                }
            }
        }
    }
    #endif

    func cgmManagerWantsDeletion(_ manager: CGMManager) {
        log.default("CGM manager requested deletion (ignored on watch)")
    }

    static let cgmStateDefaultsKey = "g7.cgmManagerRawState"

    func cgmManagerDidUpdateState(_ manager: CGMManager) {
        guard manager is G7CGMManager else { return }
        let raw = manager.rawState
        let sensorID = raw["sensorID"] as? String

        if sensorID == nil,
           let stored = defaults.dictionary(forKey: Self.cgmStateDefaultsKey),
           let storedID = stored["sensorID"] as? String {
            let activated = stored["activatedAt"] as? Date
            let expired = Self.persistedSensorIsPastLife(activated, now: now())
            if !expired {
                if lastPersistedSensorID != nil {
                    SportLog.event("cgm", "G7 state: manager forgot sensor \(storedID) — KEEPING the persisted identity (#104: nil means unknown, not forget)")
                    lastPersistedSensorID = nil
                }
                return
            }
            SportLog.event("cgm", "G7 state: sensor \(storedID) is past its 10-day life — honouring the clear")
        }

        defaults.set(raw, forKey: Self.cgmStateDefaultsKey)
        if sensorID != lastPersistedSensorID {
            lastPersistedSensorID = sensorID
            SportLog.event("cgm", "G7 state persisted — sensor \(sensorID ?? "none") (survives relaunch/update)")
        }
    }

    func credentialStoragePrefix(for manager: CGMManager) -> String {
        return "com.loopkit.Loop.WatchLoopManager"
    }

    func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {
        log.default("CGM status did update")
    }

    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        log.default("Device %{public}@: %{public}@", deviceIdentifier ?? "unknown", message)

        let source = manager is G7CGMManager ? "cgm" : "pod-ble"

        let line = "\(type) \(deviceIdentifier ?? "—"): \(message)"
        switch deviceLogThrottle.admit(line, at: now()) {
        case .suppress:
            completion?(nil)
            return
        case .write(let flushing):
            if flushing > 0 {
                SportLog.event(source, "(previous line repeated ×\(flushing) — suppressed)")
            }
        }
        SportLog.event(source, line)
        completion?(nil)
    }

    func issueAlert(_ alert: LoopKit.Alert) {
        log.default("Alert issued: %{public}@", alert.identifier.value)
    }

    func retractAlert(identifier: LoopKit.Alert.Identifier) {
        log.default("Alert retracted: %{public}@", identifier.value)
    }

    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier) async throws -> Bool {
        false
    }

    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] {
        []
    }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] {
        []
    }

    func recordRetractedAlert(_ alert: LoopKit.Alert, at date: Date) {
        log.default("Retracted alert recorded: %{public}@", alert.identifier.value)
    }
}

extension WatchLoopManager: DoseStoreDelegate {
    func scheduledBasalHistory(from start: Date, to end: Date) async throws -> [AbsoluteScheduleValue<Double>] {
        try await settingsProvider.getBasalHistory(startDate: start, endDate: end)
    }

    func doseStoreHasUpdatedPumpEventData(_ doseStore: DoseStore) {
    }
}
