//
//  DiabetifyTransformTests.swift
//  LoopTests
//
//  *** DIABETIFY *** bench-transform unit tests (Jeremy's spec, 2026-07-29).
//  Pins the affine map y = 3.0*(x - 80) + 115 clamped to [40, 400], the 3x delta
//  amplification, the [NewGlucoseSample] substitution's field preservation (store
//  identity — date + syncIdentifier — must survive the rewrite, per the #69 dose/
//  sample identity discipline), and the flag's default-FALSE contract that makes
//  the call sites (WatchLoopManager/DeviceDataManager processCGMReadingResult)
//  identity passthroughs unless g7.diabetify is deliberately set.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

final class DiabetifyTransformTests: XCTestCase {

    private var priorFlagValue: Any?

    override func setUp() {
        super.setUp()
        // The flag lives in UserDefaults.standard (test host = the Loop app):
        // stash whatever is there and start each test from the key-absent state.
        priorFlagValue = UserDefaults.standard.object(forKey: DiabetifyTransform.defaultsKey)
        UserDefaults.standard.removeObject(forKey: DiabetifyTransform.defaultsKey)
    }

    override func tearDown() {
        if let prior = priorFlagValue {
            UserDefaults.standard.set(prior, forKey: DiabetifyTransform.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: DiabetifyTransform.defaultsKey)
        }
        super.tearDown()
    }

    // MARK: - Affine values (spec: 80→115, 90→145, 70→85)

    func testAffineValues() {
        XCTAssertEqual(DiabetifyTransform.apply(80), 115, accuracy: 1e-9)
        XCTAssertEqual(DiabetifyTransform.apply(90), 145, accuracy: 1e-9)
        XCTAssertEqual(DiabetifyTransform.apply(70), 85, accuracy: 1e-9)
        // Typical euglycemic band maps into a diabetic-looking band.
        XCTAssertEqual(DiabetifyTransform.apply(100), 175, accuracy: 1e-9)
        XCTAssertEqual(DiabetifyTransform.apply(135), 280, accuracy: 1e-9)
    }

    // MARK: - Clamps

    func testClampFloor() {
        // Real 20 → 3*(20-80)+115 = -65 → clamped to the 40 floor.
        XCTAssertEqual(DiabetifyTransform.apply(20), 40, accuracy: 1e-9)
        // Exact floor boundary: 3*(55-80)+115 = 40 — unclamped landing on the floor.
        XCTAssertEqual(DiabetifyTransform.apply(55), 40, accuracy: 1e-9)
        XCTAssertEqual(DiabetifyTransform.apply(54), 40, accuracy: 1e-9)   // just below: clamped
        XCTAssertEqual(DiabetifyTransform.apply(56), 43, accuracy: 1e-9)   // just above: affine
    }

    func testClampCeiling() {
        // Real 180 → 3*(180-80)+115 = 415 → clamped to the 400 ceiling.
        XCTAssertEqual(DiabetifyTransform.apply(180), 400, accuracy: 1e-9)
        // Exact ceiling boundary: 3*(175-80)+115 = 400 — unclamped landing on the ceiling.
        XCTAssertEqual(DiabetifyTransform.apply(175), 400, accuracy: 1e-9)
        XCTAssertEqual(DiabetifyTransform.apply(176), 400, accuracy: 1e-9) // just above: clamped
        XCTAssertEqual(DiabetifyTransform.apply(174), 397, accuracy: 1e-9) // just below: affine
    }

    // MARK: - Delta amplification (Δy = 3Δx away from the clamps)

    func testDeltaAmplification() {
        let pairs: [(Double, Double)] = [(85, 95), (100, 120), (70, 71), (130, 160), (60, 170)]
        for (a, b) in pairs {
            let dy = DiabetifyTransform.apply(b) - DiabetifyTransform.apply(a)
            XCTAssertEqual(dy, 3.0 * (b - a), accuracy: 1e-9,
                           "Δy for raw pair (\(a), \(b)) must be 3Δx away from clamps")
        }
    }

    func testMonotonicNonDecreasingAcrossClamps() {
        // Stateless pointwise map sanity across the whole plausible raw range,
        // including through both clamp corners.
        var previous = -Double.infinity
        for raw in stride(from: 10.0, through: 250.0, by: 0.5) {
            let y = DiabetifyTransform.apply(raw)
            XCTAssertGreaterThanOrEqual(y, previous, "map must be monotone at raw=\(raw)")
            XCTAssertGreaterThanOrEqual(y, 40)
            XCTAssertLessThanOrEqual(y, 400)
            previous = y
        }
    }

    // MARK: - Flag contract (default FALSE → call sites are identity passthroughs)

    func testFlagDefaultsToFalse() {
        // Key absent (setUp removed it): the transform must be OFF by default.
        XCTAssertFalse(DiabetifyTransform.isActive)
    }

    func testFlagReadsUserDefaults() {
        UserDefaults.standard.set(true, forKey: DiabetifyTransform.defaultsKey)
        XCTAssertTrue(DiabetifyTransform.isActive)
        UserDefaults.standard.set(false, forKey: DiabetifyTransform.defaultsKey)
        XCTAssertFalse(DiabetifyTransform.isActive)
    }

    func testFlagOffCallSiteShapeIsIdentity() {
        // Both call sites gate with exactly this ternary; with the flag off the
        // ORIGINAL samples flow through untouched — substitute() is never invoked.
        let samples = [makeSample(mgdl: 90)]
        let result = DiabetifyTransform.isActive
            ? DiabetifyTransform.substitute(samples, log: { _ in XCTFail("must not log when off") })
            : samples
        XCTAssertEqual(result, samples)
    }

    // MARK: - Substitution (field preservation + logging)

    func testSubstituteTransformsQuantityAndPreservesIdentity() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let trendRate = HKQuantity(unit: HKUnit.milligramsPerDeciliter.unitDivided(by: .minute()),
                                   doubleValue: 1.5)
        let sample = NewGlucoseSample(date: date,
                                      quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 90),
                                      condition: nil,
                                      trend: .up,
                                      trendRate: trendRate,
                                      isDisplayOnly: false,
                                      wasUserEntered: false,
                                      syncIdentifier: "0102030405",
                                      syncVersion: 7)
        var logged: [String] = []
        let out = DiabetifyTransform.substitute([sample]) { logged.append($0) }

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].quantity.doubleValue(for: .milligramsPerDeciliter), 145, accuracy: 1e-9)
        // Store identity survives the rewrite: dedup/ordering/recency untouched.
        XCTAssertEqual(out[0].date, date)
        XCTAssertEqual(out[0].syncIdentifier, "0102030405")
        XCTAssertEqual(out[0].syncVersion, 7)
        XCTAssertEqual(out[0].trend, .up)
        XCTAssertEqual(out[0].isDisplayOnly, false)
        XCTAssertEqual(out[0].wasUserEntered, false)
        // trendRate scales by the map's derivative (3x) to match the transformed series.
        XCTAssertEqual(out[0].trendRate!.doubleValue(for: HKUnit.milligramsPerDeciliter.unitDivided(by: .minute())),
                       4.5, accuracy: 1e-9)
        // Ringfence: one greppable log line per reading.
        XCTAssertEqual(logged, ["raw=90 → 145"])
    }

    func testSubstituteBatchPreservesOrderAndCount() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let raws: [Double] = [70, 80, 90, 20, 180]
        let samples = raws.enumerated().map { i, mgdl in
            makeSample(mgdl: mgdl, date: base.addingTimeInterval(Double(i) * 300), syncIdentifier: "sync-\(i)")
        }
        var logged: [String] = []
        let out = DiabetifyTransform.substitute(samples) { logged.append($0) }

        XCTAssertEqual(out.count, raws.count)
        XCTAssertEqual(logged.count, raws.count)
        let expected: [Double] = [85, 115, 145, 40, 400]
        for (i, sample) in out.enumerated() {
            XCTAssertEqual(sample.quantity.doubleValue(for: .milligramsPerDeciliter), expected[i], accuracy: 1e-9)
            XCTAssertEqual(sample.syncIdentifier, "sync-\(i)")
            XCTAssertEqual(sample.date, base.addingTimeInterval(Double(i) * 300))
        }
    }

    // MARK: - Helpers

    private func makeSample(mgdl: Double,
                            date: Date = Date(timeIntervalSince1970: 1_700_000_000),
                            syncIdentifier: String = "test-sync") -> NewGlucoseSample {
        return NewGlucoseSample(date: date,
                                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl),
                                condition: nil,
                                trend: nil,
                                trendRate: nil,
                                isDisplayOnly: false,
                                wasUserEntered: false,
                                syncIdentifier: syncIdentifier)
    }
}
