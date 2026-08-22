//
//  SensorSwitchTests.swift
//  WatchAppTests
//
//  The positive-evidence override on #104. First T1D field session (2026-08-21): a sensor
//  changed on day 9.4, #104 kept the dead identity, and the watch failed auth for three days
//  while the new sensor advertised beside it. The override drops a persisted identity only on
//  the one observation a false forget cannot produce: a DIFFERENT sensor repeatedly sighted
//  while the persisted one delivers nothing.
//

import XCTest
import LoopKit
import LoopCore
@testable import WatchApp_Extension

final class SensorSwitchTests: XCTestCase {

    private var cacheDir: URL!
    private var cacheStore: PersistenceController!
    private var defaults: UserDefaults!
    private var clock: Date!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cacheStore = PersistenceController(directoryURL: cacheDir)
        defaults = UserDefaults(suiteName: "SensorSwitchTests-\(UUID().uuidString)")!
        clock = Date()
    }

    override func tearDown() {
        cacheStore = nil
        cacheDir = nil
        defaults = nil
        super.tearDown()
    }

    private func makeManager(persistedSensor: String?) -> WatchLoopManager {
        if let id = persistedSensor {
            defaults.set(["sensorID": id, "activatedAt": clock.addingTimeInterval(-.hours(24))],
                         forKey: WatchLoopManager.cgmStateDefaultsKey)
        }
        let doseStore = DoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            basalProfile: nil,
            insulinSensitivitySchedule: nil,
            provenanceIdentifier: "SensorSwitchTests")
        let glucoseStore = GlucoseStore(
            healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(4),
            provenanceIdentifier: "SensorSwitchTests")
        let carbStore = CarbStore(
            healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(24),
            defaultAbsorptionTimes: LoopCoreConstants.defaultCarbAbsorptionTimes,
            provenanceIdentifier: "SensorSwitchTests")
        let manager = WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore)
        manager.defaults = defaults
        manager.now = { [unowned self] in self.clock }
        return manager
    }

    /// Sight the foreign sensor on the G7's real ~5-minute cadence until thresholds are met.
    private func sightRepeatedly(_ manager: WatchLoopManager, name: String, times: Int) {
        for _ in 0..<times {
            manager.noteSensorSighted(name)
            clock = clock.addingTimeInterval(5 * 60)
        }
    }

    /// The field case: dead identity persisted, new sensor advertising, no direct reading ever.
    func testForeignSensorSightedWhilePersistedOneSilentDropsTheIdentityAndRescans() {
        let manager = makeManager(persistedSensor: "DXCMdu")
        var rescans = 0
        let fired = expectation(description: "rescan requested")
        manager.requestSensorRescan = { rescans += 1; fired.fulfill() }

        sightRepeatedly(manager, name: "DXCMu0", times: 4)   // 4 sightings over 15 min of virtual time

        wait(for: [fired], timeout: 5)   // the rescan hops through DispatchQueue.main
        XCTAssertEqual(rescans, 1)
        XCTAssertNil(defaults.dictionary(forKey: WatchLoopManager.cgmStateDefaultsKey),
                     "the stale identity must be cleared BEFORE the rescan, or #104 resurrects it")
    }

    /// The case #104 exists for must stay protected: sightings of the PERSISTED sensor are not
    /// evidence of anything, however many arrive.
    func testSightingsOfTheOwnSensorNeverFire() {
        let manager = makeManager(persistedSensor: "DXCMdu")
        var rescans = 0
        manager.requestSensorRescan = { rescans += 1 }

        sightRepeatedly(manager, name: "DXCMdu", times: 10)

        XCTAssertEqual(rescans, 0)
        XCTAssertNotNil(defaults.dictionary(forKey: WatchLoopManager.cgmStateDefaultsKey))
    }

    /// Two different foreign names must not pool their evidence — a busy environment (gym,
    /// household with two G7 users) restarts the count on every name change.
    func testDifferentForeignNamesDoNotPoolEvidence() {
        let manager = makeManager(persistedSensor: "DXCMdu")
        var rescans = 0
        manager.requestSensorRescan = { rescans += 1 }

        manager.noteSensorSighted("DXCMaa"); clock = clock.addingTimeInterval(5 * 60)
        manager.noteSensorSighted("DXCMbb"); clock = clock.addingTimeInterval(5 * 60)
        manager.noteSensorSighted("DXCMaa"); clock = clock.addingTimeInterval(5 * 60)
        manager.noteSensorSighted("DXCMbb"); clock = clock.addingTimeInterval(5 * 60)

        XCTAssertEqual(rescans, 0, "alternating names reset the evidence each time")
    }

    /// A burst of sightings inside one connection window must not satisfy the span requirement.
    func testABurstWithoutTimeSpanDoesNotFire() {
        let manager = makeManager(persistedSensor: "DXCMdu")
        var rescans = 0
        manager.requestSensorRescan = { rescans += 1 }

        for _ in 0..<6 { manager.noteSensorSighted("DXCMu0") }   // clock never advances

        XCTAssertEqual(rescans, 0, "six sightings in one instant are one observation, not six")
    }

    /// With no persisted identity there is nothing to override — the guard must be inert.
    func testNoPersistedIdentityMeansNoOverride() {
        let manager = makeManager(persistedSensor: nil)
        var rescans = 0
        manager.requestSensorRescan = { rescans += 1 }

        sightRepeatedly(manager, name: "DXCMu0", times: 6)

        XCTAssertEqual(rescans, 0)
    }
}
