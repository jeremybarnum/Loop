//
//  SensorReadinessTests.swift
//  WatchAppTests
//
//  The Start gate v2. The first gate measured freshness against suspended time and refused
//  every watch that had been asleep — i.e. every watch. This one answers from state alone:
//  identity present, auth proven within 24 h, radio not contradicting the identity. These
//  tests are the truth table, plus the watchdog that backstops the ~1-2% residue.
//

import XCTest
import LoopKit
import LoopCore
@testable import WatchApp_Extension

final class SensorReadinessTests: XCTestCase {

    private var cacheDir: URL!
    private var cacheStore: PersistenceController!
    private var journalDir: URL!
    private var defaults: UserDefaults!
    private var clock: Date!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cacheStore = PersistenceController(directoryURL: cacheDir)
        journalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "SensorReadinessTests-\(UUID().uuidString)")!
        clock = Date()
    }

    override func tearDown() {
        cacheStore = nil; cacheDir = nil; journalDir = nil; defaults = nil
        super.tearDown()
    }

    private func makeManager(identity: String?, lastDirectAgo: TimeInterval?) -> WatchLoopManager {
        if let id = identity {
            defaults.set(["sensorID": id, "activatedAt": clock.addingTimeInterval(-.hours(24))],
                         forKey: WatchLoopManager.cgmStateDefaultsKey)
        }
        if let ago = lastDirectAgo {
            defaults.set(clock.addingTimeInterval(-ago), forKey: WatchLoopManager.Keys.lastDirectReadingAt)
        }
        let doseStore = DoseStore(
            healthKitSampleStore: nil, cacheStore: cacheStore,
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            basalProfile: nil, insulinSensitivitySchedule: nil, provenanceIdentifier: "Readiness")
        let glucoseStore = GlucoseStore(
            healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(4),
            provenanceIdentifier: "Readiness")
        let carbStore = CarbStore(
            healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(24),
            defaultAbsorptionTimes: LoopCoreConstants.defaultCarbAbsorptionTimes,
            provenanceIdentifier: "Readiness")
        let m = WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore)
        m.defaults = defaults
        m.now = { [unowned self] in self.clock }
        return m
    }

    // MARK: - The truth table

    func testIdentityPlusRecentAuthIsReady() {
        let m = makeManager(identity: "DXCMu0", lastDirectAgo: .hours(3))
        XCTAssertEqual(m.sensorReadiness, .ready, "overnight suspension must not demote a healthy setup")
    }

    /// V3's defining case: identity present, stamp never written (fresh key after an update).
    /// The first launch of build 111 hit exactly this and was wrongly blocked under v2.
    func testIdentityWithNoStampAtAllIsReady() {
        let m = makeManager(identity: "DXCMu0", lastDirectAgo: nil)
        XCTAssertEqual(m.sensorReadiness, .ready)
    }

    func testNoIdentityIsUnprovenNotAFault() {
        let m = makeManager(identity: nil, lastDirectAgo: nil)
        XCTAssertEqual(m.sensorReadiness, .unproven)
    }

    /// V3: a stale stamp no longer demotes — the identity is the proof (adoption requires
    /// auth), and the 12-minute in-loan watchdog is the specified backstop for the residue.
    /// This is the case that blocked the first post-update launch under v2.
    func testStaleStampWithValidIdentityIsReadyUnderV3() {
        let m = makeManager(identity: "DXCMu0", lastDirectAgo: .hours(30))
        XCTAssertEqual(m.sensorReadiness, .ready)
    }

    func testExpiredIdentityIsUnproven() {
        let m = makeManager(identity: "DXCMu0", lastDirectAgo: nil)
        clock = clock.addingTimeInterval(.hours(11 * 24))   // sensor activated 24h before clock; now 12 days past
        XCTAssertEqual(m.sensorReadiness, .unproven, "a corpse past its life proves nothing")
    }

    /// The three-day field failure, as the gate would now see it: identity held, but the radio
    /// keeps sighting a different sensor. Two sightings suffice for the GATE (the override
    /// itself still needs its own higher bar) — the gate must not bless an identity the switch
    /// logic is accumulating evidence against.
    func testForeignSightingsMakeItWrongSensorEvenWithRecentAuth() {
        let m = makeManager(identity: "DXCMdu", lastDirectAgo: .hours(1))
        m.noteSensorSighted("DXCMu0"); clock = clock.addingTimeInterval(5 * 60)
        m.noteSensorSighted("DXCMu0")
        XCTAssertEqual(m.sensorReadiness, .wrongSensor)
    }

    /// The gym case, caught in self-review: a neighbour's G7 sighted twice while HER sensor is
    /// actively delivering must not block. Foreign evidence only counts against a silent sensor.
    func testForeignSightingsWithOwnSensorDeliveringStaysReady() {
        let m = makeManager(identity: "DXCMdu", lastDirectAgo: 10 * 60)   // delivering 10 min ago
        m.noteSensorSighted("DXCMzz"); clock = clock.addingTimeInterval(5 * 60)
        m.noteSensorSighted("DXCMzz")
        XCTAssertEqual(m.sensorReadiness, .ready)
    }

    // MARK: - The watchdog behind the gate

    private func makeController(_ m: WatchLoopManager) -> PodLoanWatchController {
        PodLoanWatchController(loopManager: m, journal: LoanEventJournal(directory: journalDir), defaults: defaults)
    }

    func testWatchdogStaysQuietWhenAReadingArrivedAfterTakeover() {
        let m = makeManager(identity: "DXCMu0", lastDirectAgo: nil)
        let c = makeController(m)
        let takeover = clock.addingTimeInterval(-10 * 60)
        defaults.set(clock.addingTimeInterval(-5 * 60), forKey: WatchLoopManager.Keys.lastDirectReadingAt)
        XCTAssertFalse(c.directG7WatchdogShouldWarn(takeoverAt: takeover))
    }

    func testWatchdogWarnsWhenTheOnlyReadingPredatesTakeover() {
        let m = makeManager(identity: "DXCMu0", lastDirectAgo: .hours(2))
        let c = makeController(m)
        XCTAssertTrue(c.directG7WatchdogShouldWarn(takeoverAt: clock.addingTimeInterval(-12 * 60)),
                      "a reading from before the loan is not evidence the loan's sensor path works")
    }

    func testWatchdogWarnsWhenNothingEverArrived() {
        let m = makeManager(identity: "DXCMu0", lastDirectAgo: nil)
        let c = makeController(m)
        XCTAssertTrue(c.directG7WatchdogShouldWarn(takeoverAt: clock.addingTimeInterval(-12 * 60)))
    }
}
