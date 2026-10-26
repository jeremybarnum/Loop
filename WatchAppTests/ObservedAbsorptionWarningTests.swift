//
//  ObservedAbsorptionWarningTests.swift
//  WatchAppTests
//
//  The predicted-low warning's absorption ratio and assessment, from carbs arriving at a chosen share
//  of the entered rate. Ported from the production line's tests to the LoopAlgorithm package: the
//  ratio is measured against the entries as entered (the yardstick ruled 2026-10-20/21), whatever
//  curve dosing follows.
//

import XCTest
import LoopKit
import LoopCore
import LoopAlgorithm
@testable import WatchApp

final class ObservedAbsorptionWarningTests: XCTestCase {

    // 45 g declared for 3 h at t0, covered by a 4.5 U bolus (carb ratio 10). ISF 50, so each gram is
    // worth 5 mg/dL. BG 160 at t0. Judged one hour after the meal unless a test says otherwise.
    private let t0 = Date(timeIntervalSinceReferenceDate: 999_900)
    private let carbGrams = 45.0
    private let declaredAbsorptionTime: TimeInterval = 3 * 3600
    private let bolusUnits = 4.5
    private let isf = 50.0
    private let carbRatio = 10.0
    private var csf: Double { isf / carbRatio }
    private let startingGlucose = 160.0
    private let delay = CarbMath.defaultEffectDelay
    private let piecewise = PiecewiseLinearAbsorption()

    private var carbRatios: [AbsoluteScheduleValue<Double>] {
        [AbsoluteScheduleValue(startDate: t0.addingTimeInterval(-86400), endDate: t0.addingTimeInterval(86400), value: carbRatio)]
    }
    private var sensitivities: [AbsoluteScheduleValue<LoopQuantity>] {
        [AbsoluteScheduleValue(startDate: t0.addingTimeInterval(-86400), endDate: t0.addingTimeInterval(86400),
                               value: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: isf))]
    }

    /// The declared arrival rate `minute` after the entry's start, in g/min: the entered grams over the
    /// entered time, shaped by Loop's carb curve, zero during the start delay.
    private func declaredRate(atMinute minute: Double) -> Double {
        let absorbing = minute - delay / 60
        guard absorbing > 0 else { return 0 }
        return carbGrams / (declaredAbsorptionTime / 60) * piecewise.percentRateAtPercentTime(absorbing / (declaredAbsorptionTime / 60))
    }

    /// Counteraction readings every 5 minutes from t0 for `minutes`, carbs arriving at `fraction(minute)`
    /// of the declared rate (the minute being the reading's midpoint).
    private func counteraction(minutes: Double, fraction: (Double) -> Double) -> [GlucoseEffectVelocity] {
        stride(from: 0.0, to: minutes, by: 5.0).map { m in
            GlucoseEffectVelocity(startDate: t0.addingTimeInterval(m * 60), endDate: t0.addingTimeInterval((m + 5) * 60),
                                  quantity: LoopQuantity(unit: .milligramsPerDeciliterPerMinute,
                                                         doubleValue: fraction(m + 2.5) * declaredRate(atMinute: m + 2.5) * csf))
        }
    }

    private var meal: FixtureCarbEntry {
        FixtureCarbEntry(absorptionTime: declaredAbsorptionTime, startDate: t0,
                         quantity: LoopQuantity(unit: .gram, doubleValue: carbGrams))
    }

    /// The carb effect as the algorithm builds it; `asEntered` is the warning's call (entered time, 1.0).
    private func carbEffect(_ readings: [GlucoseEffectVelocity], asEntered: Bool) -> [GlucoseEffect] {
        [meal].map(to: readings, carbRatio: carbRatios, insulinSensitivity: sensitivities,
                   initialAbsorptionTimeOverrun: asEntered ? 1.0 : CarbMath.defaultAbsorptionTimeOverrun)
            .dynamicGlucoseEffects(from: t0, carbRatios: carbRatios, insulinSensitivities: sensitivities)
    }

    private func ratio(minutes: Double = 60, fraction: @escaping (Double) -> Double) throws -> Double {
        let ice = counteraction(minutes: minutes, fraction: fraction)
        return try XCTUnwrap(ObservedAbsorption.measureRatio(insulinCounteractionEffects: ice) {
            self.carbEffect($0, asEntered: true)
        }).ratio
    }

    private func steady(_ f: Double) -> (Double) -> Double { { _ in f } }
    private func fastStart(then after: Double) -> (Double) -> Double { { $0 < 45 ? 1.5 : after } }

    // MARK: - The ratio is the share of the entered rate arriving

    func testTheRatioIsTheShareOfTheEnteredRateArriving() throws {
        for f in [0.0, 1.0 / 3.0, 0.5, 0.8] {
            XCTAssertEqual(try ratio(fraction: steady(f)), f, accuracy: 0.06, "arriving at \(f) of entered")
        }
    }

    func testASlowdownAfterAFastStartIsSeen() throws {
        XCTAssertEqual(try ratio(fraction: fastStart(then: 0.3)), 0.3, accuracy: 0.05)
    }

    func testCarbsThatStopArrivingReadZero() throws {
        XCTAssertEqual(try ratio(fraction: fastStart(then: 0)), 0, accuracy: 0.01)
    }

    func testCarbsFasterThanExpectedReadAboveOne() throws {
        XCTAssertGreaterThan(try ratio(fraction: steady(1.5)), 1.2)
    }

    func testTooFewReadingsMakeNoAdjustment() throws {
        // One reading covers 5 minutes of the 15-minute window: under the 10-minute minimum coverage.
        let ice = Array(counteraction(minutes: 60, fraction: steady(0.3)).suffix(1))
        let measured = try XCTUnwrap(ObservedAbsorption.measureRatio(insulinCounteractionEffects: ice) { self.carbEffect($0, asEntered: true) })
        XCTAssertEqual(measured.ratio, 1.0, "too little evidence to judge")
    }

    // MARK: - The assessment from an algorithm run

    /// A display run's input and output as the devices pass them, built from what actually happened:
    /// the bolus, the carbs that arrived, BG now from both.
    private func assess(fraction: @escaping (Double) -> Double, minutes: Double = 60,
                        glucoseAge: TimeInterval = 0, pumpDataAge: TimeInterval? = 0,
                        settings: LowBGWarningSettings = LowBGWarningSettings(enabled: true, nightWarningsEnabled: true,
                                                                              dayWarningOffset: 5, nightWarningOffset: 5,
                                                                              dontWarnIfSooner: 0, dontWarnIfLater: 6 * 3600)) -> LowGlucoseWarning.Assessment {
        let now = t0.addingTimeInterval(minutes * 60)
        let ice = counteraction(minutes: minutes, fraction: fraction)
        let model = ExponentialInsulinModelPreset.rapidActingAdult
        let insulinEffect = [BasalRelativeDose(type: .bolus, startDate: t0, endDate: t0, volume: bolusUnits, insulinModel: model)]
            .glucoseEffects(insulinSensitivityHistory: sensitivities)
        let insulinSoFar = ObservedAbsorption.cumulativeEffect(insulinEffect, at: now)
        let carbsSoFar = ice.reduce(0) { $0 + $1.quantity.doubleValue(for: .milligramsPerDeciliterPerMinute) * 5 }
        let glucoseNow = startingGlucose + insulinSoFar + carbsSoFar

        let range = t0.addingTimeInterval(-86400)...t0.addingTimeInterval(86400)
        let input = AlgorithmInputFixture(
            predictionStart: now,
            glucoseHistory: [FixtureGlucoseSample(startDate: now.addingTimeInterval(-glucoseAge),
                                                  quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: glucoseNow))],
            doses: [], carbEntries: [meal],
            basal: [AbsoluteScheduleValue(startDate: range.lowerBound, endDate: range.upperBound, value: 1.0)],
            sensitivity: sensitivities, carbRatio: carbRatios,
            target: [AbsoluteScheduleValue(startDate: range.lowerBound, endDate: range.upperBound,
                                           value: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 100)...LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 110))],
            suspendThreshold: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 70),
            maxBolus: 5, maxBasalRate: 3, recommendationInsulinType: .novolog, recommendationType: .manualBolus)
        let output = LoopAlgorithmOutputFixture(
            recommendationResult: .failure(NSError(domain: "unused", code: 0)),
            predictedGlucose: [],
            effects: LoopAlgorithmEffects(insulin: insulinEffect, carbs: carbEffect(ice, asEntered: false), carbStatus: [],
                                          retrospectiveCorrection: [], momentum: [], insulinCounteraction: ice,
                                          retrospectiveGlucoseDiscrepancies: []),
            dosesRelativeToBasal: [])
        return LowGlucoseWarning.assess(input: input, output: output, lastPumpDataDate: pumpDataAge.map { now.addingTimeInterval(-$0) },
                                        scheduledBasal: input.basal, now: now, settings: settings)
    }

    func testSlowCarbsWarnAndOnPaceCarbsDoNot() throws {
        let onPace = assess(fraction: steady(1.0))
        XCTAssertEqual(onPace.decision?.outcome, LowGlucoseWarning.Outcome.none, "carbs on pace: the bolus is covered")
        XCTAssertEqual(onPace.absorptionRatio, 1.0, accuracy: 0.06)

        let stopped = assess(fraction: fastStart(then: 0))
        XCTAssertEqual(stopped.absorptionRatio, 0, accuracy: 0.01)
        XCTAssertNotEqual(stopped.decision?.outcome, LowGlucoseWarning.Outcome.none, "the rest of the meal is not coming: warn")
        XCTAssertNotNil(stopped.decision?.context)
    }

    func testTheZeroTempRaisesTheForecast() {
        let a = assess(fraction: steady(0.5))
        let p3Min = a.predictionWithObservedAbsorptionAndZeroTemp.map { $0.quantity.doubleValue(for: .milligramsPerDeciliter) }.min() ?? .nan
        let p2Min = a.predictionWithObservedAbsorption.map { $0.quantity.doubleValue(for: .milligramsPerDeciliter) }.min() ?? .nan
        XCTAssertGreaterThan(p3Min, p2Min, "withholding basal raises the observed-absorption forecast")
    }

    func testStaleDataSkipsRatherThanDecides() {
        XCTAssertNil(assess(fraction: steady(0), glucoseAge: 16 * 60).decision, "glucose older than 15 minutes")
        XCTAssertNil(assess(fraction: steady(0), pumpDataAge: nil).decision, "no pump data")
        XCTAssertNil(assess(fraction: steady(0), pumpDataAge: 16 * 60).decision, "pump data older than 15 minutes")
    }

    func testSwitchedOffDecidesNothingAndWithdraws() {
        let off = assess(fraction: steady(0), settings: LowBGWarningSettings(enabled: false))
        XCTAssertEqual(off.decision?.outcome, LowGlucoseWarning.Outcome.none)
        XCTAssertEqual(off.decision?.lowStillPredicted, false)
    }
}
