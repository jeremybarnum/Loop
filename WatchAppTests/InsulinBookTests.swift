//
//  InsulinBookTests.swift
//  WatchAppTests
//
//  THE INSULIN BOOK THE ALGORITHM ACTUALLY READS.
//
//  On 2026-08-18 the wrist delivered three manual boluses totalling 3.40 U inside six minutes
//  and reported `IOB 0.00` with `insulin +0` after every one of them, republishing
//  `REC bolus 1.66 U` unchanged each time. A recommendation that cannot see the insulin already
//  given cannot decrement, so the wrist kept asking for the same dose again.
//
//  The cause was a seam, not arithmetic. Two books exist: the ledger, fed at enact time, and the
//  DoseStore. The watch's DoseStore is never written — `pumpManager(_:hasNewPumpEvents:)`
//  discards every row on purpose and no other writer exists in the extension — yet
//  `fetchAlgorithmInput` built LoopAlgorithm's input from it. Nothing failed, threw, or logged;
//  the book was simply empty, which is indistinguishable from "no insulin on board".
//
//  These tests pin the seam rather than the math. They ask the one question no existing test
//  asked: does insulin that was DELIVERED reach the input the algorithm reasons from? That is
//  pure computation — no pod, no BLE, no phone — so the simulator settles it.
//

import XCTest
import LoopKit
import LoopAlgorithm
import LoopCore
import HealthKit
@testable import WatchApp

final class InsulinBookTests: XCTestCase {

    private var cacheDir: URL!
    private var cacheStore: PersistenceController!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insulin-book-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cacheStore = PersistenceController(directoryURL: cacheDir)
    }

    override func tearDown() {
        cacheStore = nil
        cacheDir = nil
        super.tearDown()
    }

    private func makeManager() async -> WatchLoopManager {
        let doseStore = await DoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            provenanceIdentifier: "InsulinBookTests")
        let glucoseStore = await GlucoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            cacheLength: .hours(4),
            provenanceIdentifier: "InsulinBookTests")
        let carbStore = CarbStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            cacheLength: .hours(24),
            provenanceIdentifier: "InsulinBookTests")

        var settings = LoopSettings()
        settings.basalRateSchedule = BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 0.7)])
        settings.insulinSensitivitySchedule = InsulinSensitivitySchedule(
            unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: 70)])
        settings.carbRatioSchedule = CarbRatioSchedule(
            unit: .gram, dailyItems: [RepeatingScheduleValue(startTime: 0, value: 7)])
        settings.glucoseTargetRangeSchedule = GlucoseRangeSchedule(
            unit: .milligramsPerDeciliter,
            dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 115))])
        settings.maximumBolus = 10
        settings.maximumBasalRatePerHour = 4
        settings.suspendThreshold = GlucoseThreshold(unit: .milligramsPerDeciliter, value: 80)

        return WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore,
                                carbStore: carbStore, settings: settings)
    }

    /// A high, flat run — high enough that a correction is genuinely warranted, so the
    /// recommendation is a real number rather than a floor.
    private func seedGlucose(_ manager: WatchLoopManager, mgdl: Double = 250) async {
        let now = Date()
        let samples: [NewGlucoseSample] = (0..<12).reversed().map { i in
            NewGlucoseSample(
                date: now.addingTimeInterval(-Double(i) * 5 * 60),
                quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl),
                condition: nil, trend: .flat, trendRate: nil,
                isDisplayOnly: false, wasUserEntered: false,
                syncIdentifier: "insulin-book-\(i)")
        }
        _ = try? await manager.glucoseStore.addGlucoseSamples(samples)
    }

    private func bolus(_ units: Double, minutesAgo: Double) -> DoseEntry {
        let start = Date().addingTimeInterval(-minutesAgo * 60)
        return DoseEntry(type: .bolus, startDate: start, endDate: start,
                         value: units, unit: .units,
                         decisionId: nil,
                         insulinType: .novolog)
    }

    private func settle(_ seconds: TimeInterval = 2.0) {
        let done = expectation(description: "settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    /// The IOB **the algorithm dosed with** — not the one on the glance.
    ///
    /// These are two different numbers from two different books, which is the trap that made
    /// the original defect so hard to see. `glanceData().iob` prefers the LEDGER
    /// (`sessionLedger?.insulinOnBoard`) and so was right all along; the field log shows it
    /// tracking every bolus (0.20 -> 1.85 -> 3.21) during the very session in which dosing
    /// reported `IOB 0.00`. Asserting on the glance therefore proves nothing about dosing —
    /// verified, not assumed: the first draft of these tests did exactly that and stayed GREEN
    /// with the defect deliberately reintroduced.
    ///
    /// `predictionBreakdown.iobUnits` carries `activeInsulin`, which is LoopAlgorithm's own
    /// output, so it is the figure that actually sized the dose.
    private func dosingIOB(_ manager: WatchLoopManager) -> Double? {
        manager.refreshPredictionForGlance()
        settle()
        return manager.glanceData().predictionBreakdown?.iobUnits
    }

    // MARK: -

    /// THE REGRESSION. A bolus in the book must appear as insulin on board.
    ///
    /// This is the whole defect in one assertion: before the fix the ledger held the dose, the
    /// algorithm read the store, and the answer came back 0.00 — for a bolus given two minutes
    /// earlier, of which essentially none has acted yet.
    func testASeededBolusBecomesInsulinOnBoard() async {
        let manager = await makeManager()
        await seedGlucose(manager)
        manager.ledgerSeed(finished: [bolus(2.0, minutesAgo: 2)], live: [])

        guard let onBoard = dosingIOB(manager) else {
            return XCTFail("a live ledger must produce an IOB figure, not nil")
        }
        XCTAssertGreaterThan(onBoard, 1.5,
                             "2.0 U given two minutes ago is almost entirely unabsorbed — an IOB near zero means the algorithm is not reading the book that holds it")
    }

    /// The enact path, not just the seed. `ledgerRecordEnact` is what a delivered bolus calls.
    func testAnEnactedBolusReachesTheAlgorithm() async {
        let manager = await makeManager()
        await seedGlucose(manager)
        manager.ledgerSeed(finished: [], live: [])

        let before = dosingIOB(manager) ?? 0
        manager.ledgerRecordEnact(bolus(1.5, minutesAgo: 0))
        settle()
        let after = dosingIOB(manager) ?? 0

        XCTAssertGreaterThan(after - before, 1.0,
                             "delivering 1.5 U must move IOB — this is the seam between the book that records doses and the input the algorithm reasons from")
    }

    /// THE OVERBOLUS PATH, stated directly.
    ///
    /// The field symptom was not a wrong IOB in the abstract — it was `REC bolus 1.66 U`
    /// republished unchanged after each of three boluses. Insulin already on board must reduce
    /// what the wrist asks for next, or following the recommendation stacks doses.
    func testARecommendationDecrementsAfterInsulinIsGiven() async {
        let manager = await makeManager()
        await seedGlucose(manager)
        manager.ledgerSeed(finished: [], live: [])

        let empty = expectation(description: "first recommendation")
        var first: Double?
        manager.recommendManualBolus { if case .success(let r) = $0 { first = r.amount }; empty.fulfill() }
        wait(for: [empty], timeout: 20)

        guard let firstAmount = first, firstAmount > 0.2 else {
            return XCTFail("a flat 250 mg/dL against a 100-115 target must recommend a correction; got \(String(describing: first))")
        }

        manager.ledgerRecordEnact(bolus(firstAmount, minutesAgo: 0))
        settle()

        let second = expectation(description: "second recommendation")
        var next: Double?
        manager.recommendManualBolus { if case .success(let r) = $0 { next = r.amount }; second.fulfill() }
        wait(for: [second], timeout: 20)

        guard let nextAmount = next else {
            return XCTFail("the second recommendation must compute")
        }
        XCTAssertLessThan(nextAmount, firstAmount - 0.1,
                          "taking \(firstAmount) U must reduce the next recommendation; an unchanged figure is the stacking path the wrist showed in the field")
    }

    /// ONE WRIST, ONE IOB.
    ///
    /// The defect's real signature was not a wrong number but two numbers: the glance read the
    /// ledger and showed 1.85 U while the algorithm read the empty store and dosed on 0.00, on
    /// the same screen in the same second. Whatever else changes, these two must not diverge —
    /// a wrist that displays one IOB and doses with another is worse than one that is simply
    /// wrong, because the displayed figure vouches for the hidden one.
    func testTheDisplayedIOBAndTheDosingIOBAreTheSameNumber() async {
        let manager = await makeManager()
        await seedGlucose(manager)
        manager.ledgerSeed(finished: [bolus(2.0, minutesAgo: 3)], live: [])

        manager.refreshPredictionForGlance()
        settle()
        let data = manager.glanceData()

        guard let shown = data.iob, let dosed = data.predictionBreakdown?.iobUnits else {
            return XCTFail("both IOB figures must exist before they can be compared")
        }
        XCTAssertEqual(shown, dosed, accuracy: 0.05,
                       "the glance showed \(shown) U and the algorithm dosed on \(dosed) U — that is the 2026-08-18 defect exactly")
    }

    /// No book means NO DOSING — never a silent empty one.
    ///
    /// R35 bans a store fallback precisely because the fallback is invisible: an empty history
    /// and "no insulin on board" are the same number, and the second one licenses a full dose.
    func testWithoutALedgerTheAlgorithmRefusesRatherThanAssumingZero() async {
        let manager = await makeManager()
        await seedGlucose(manager)
        // Deliberately no ledgerSeed — this is the un-granted state.

        let done = expectation(description: "recommendation attempted")
        var failed = false
        manager.recommendManualBolus { if case .failure = $0 { failed = true }; done.fulfill() }
        wait(for: [done], timeout: 20)

        XCTAssertTrue(failed,
                      "with no insulin book the watch must refuse; returning a recommendation here would be a full dose computed against an assumed-zero IOB")
    }
}
