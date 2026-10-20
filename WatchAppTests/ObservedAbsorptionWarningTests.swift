//
//  ObservedAbsorptionWarningTests.swift
//  WatchAppTests
//
//  The predicted-low warning's carb half, end to end: a declared meal, a stream of insulin
//  counteraction readings showing how fast its carbs actually arrive, Loop's own carb math turning
//  that into a carb effect, the shared absorption ratio, and the warning decision.
//
//  What the warning is for: once carbs are declared, the insulin for them is aboard. Loop's own
//  forecast assumes every declared gram still arrives, only later if absorption is slow. The
//  warning's forecast asks the other question — what if fewer arrive — by comparing what arrived
//  over the last 15 minutes with what Loop's carb forecast, as it stood 15 minutes ago, expected for
//  those minutes, and scaling the remaining carbs by that ratio (fewer carbs, same timing).
//
//  The expectation is whatever the configured absorption model said at the time — linear,
//  nonlinear or adaptive — so these tests run real LoopKit carb and insulin math, and the model is
//  part of each test:
//  - named models (`overrunOfOne`, `stretched`, `adaptive`) pin exact numbers, and do not depend on
//    the app's constants;
//  - `device` reads the app's own `LoopCoreConstants` (the minimum absorption rate and the
//    absorption time overrun), and its tests assert only what must hold for any overrun from 1.0
//    up to the minimum multiplier, so tuning the overrun does not break them.
//  The three warning predictions are assembled as `WatchLoopManager.evaluateLowGlucoseWarning()`
//  assembles them.
//

import XCTest
import HealthKit
import LoopKit
import LoopCore
@testable import WatchApp_Extension

final class ObservedAbsorptionWarningTests: XCTestCase {

    // MARK: - The scenario

    // 45 g declared for 3 h at t0, covered by a 4.5 U bolus (carb ratio 10). ISF 50, so each gram is
    // worth 5 mg/dL. BG 160 at t0. Unless a test says otherwise everything is judged one hour after
    // the meal, when the ratio's window (45–60 min) is the entry's 35th to 50th minute of absorption.
    // On Loop's 5-minute grid, so each carb-effect point falls on a reading boundary.
    private let t0 = Date(timeIntervalSinceReferenceDate: 999_900)
    private let carbGrams = 45.0
    private let declaredAbsorptionTime: TimeInterval = .hours(3)
    private let bolusUnits = 4.5
    private let isf = 50.0
    private let carbRatio = 10.0
    private var csf: Double { isf / carbRatio }
    private let startingGlucose = 160.0

    private let mgdl = HKUnit.milligramsPerDeciliter
    private let mgdlPerMinute = HKUnit.milligramsPerDeciliter.unitDivided(by: .minute())
    private let delay = CarbMath.defaultEffectDelay
    private let piecewise = PiecewiseLinearAbsorption()

    /// The carb model a test runs under: `overrun` sets the minimum absorption rate, `expectationOverrun`
    /// the expected curve (CarbStore's `absorptionTimeOverrun` and `expectedAbsorptionTimeOverrun`).
    private struct CarbModel {
        var overrun = CarbMath.defaultAbsorptionTimeOverrun
        var expectationOverrun = CarbMath.defaultAbsorptionTimeOverrun
        var adaptive = false
        /// What the phone and watch run, from the app's constants, capped as CarbStore caps it.
        static let device = CarbModel(
            overrun: LoopCoreConstants.minimumAbsorptionRateTimeMultiplier,
            expectationOverrun: min(LoopCoreConstants.absorptionTimeOverrun,
                                    LoopCoreConstants.minimumAbsorptionRateTimeMultiplier))
        /// LoopKit's default: expectation and minimum both stretched 1.5×.
        static let stretched = CarbModel(overrun: 1.5, expectationOverrun: 1.5)
        /// As the warning was first written and tested by hand.
        static let overrunOfOne = CarbModel(overrun: 1.0, expectationOverrun: 1.0)
        /// LoopKit's `.adaptiveRateNonlinear`: expectation 1.0, minimum 1.5, observed pace carried forward.
        static let adaptive = CarbModel(overrun: 1.5, expectationOverrun: 1.0, adaptive: true)
    }

    private struct Run {
        let measurement: ObservedAbsorptionManager.AbsorptionRatioMeasurement?
        let ratio: Double
        let outcome: LowGlucoseWarning.Outcome
        let glucoseNow: Double
        let loopMinimum: Double        // P1: Loop's own forecast, suspend applied
        let warningMinimum: Double     // P2: the warning's forecast
    }

    private lazy var span = DateInterval(start: t0.addingTimeInterval(.days(-1)), end: t0.addingTimeInterval(.days(1)))
    private lazy var carbRatios = [AbsoluteScheduleValue(startDate: span.start, endDate: span.end, value: carbRatio)]
    private lazy var sensitivities = [AbsoluteScheduleValue(startDate: span.start, endDate: span.end,
                                                            value: HKQuantity(unit: mgdl, doubleValue: isf))]
    private lazy var sensitivitySchedule = InsulinSensitivitySchedule(
        unit: mgdl, dailyItems: [RepeatingScheduleValue(startTime: 0, value: isf)],
        timeZone: TimeZone(identifier: "UTC")!)!

    /// The declared arrival rate at `minute` after `start`, in g/min: the entered grams over the
    /// entered time, shaped by Loop's carb curve, zero during the start delay.
    private func declaredRate(atMinute minute: Double) -> Double {
        let absorbing = minute - delay.minutes
        guard absorbing > 0 else { return 0 }
        return carbGrams / declaredAbsorptionTime.minutes
            * piecewise.percentRateAtPercentTime(absorbing / declaredAbsorptionTime.minutes)
    }

    /// Counteraction readings every 5 minutes from `start` until `minutes` later, showing carbs
    /// arriving at `fraction(minute)` of the declared rate. Zero throughout = never eaten.
    private func counteraction(from start: Date, minutes: Double, skipping gap: ClosedRange<Double>? = nil,
                               _ fraction: (Double) -> Double) -> [GlucoseEffectVelocity] {
        stride(from: 0.0, to: minutes, by: 5.0).compactMap { m in
            if let gap = gap, gap.contains(m) { return nil }
            let rate = fraction(m + 2.5) * declaredRate(atMinute: m + 2.5) * csf
            return GlucoseEffectVelocity(startDate: start.addingTimeInterval(.minutes(m)),
                                         endDate: start.addingTimeInterval(.minutes(m + 5)),
                                         quantity: HKQuantity(unit: mgdlPerMinute, doubleValue: rate))
        }
    }

    /// The carb effect exactly as CarbStore builds it from a set of readings.
    private func carbEffect(_ entries: [NewCarbEntry], model: CarbModel, from start: Date,
                            readings: [GlucoseEffectVelocity]) -> [GlucoseEffect] {
        entries.map(
            to: readings,
            carbRatio: carbRatios,
            insulinSensitivity: sensitivities,
            absorptionTimeOverrun: model.overrun,
            defaultAbsorptionTime: declaredAbsorptionTime,
            delay: delay,
            initialAbsorptionTimeOverrun: model.expectationOverrun,
            absorptionModel: piecewise,
            adaptiveAbsorptionRateEnabled: model.adaptive
        ).dynamicGlucoseEffects(
            from: start,
            carbRatios: carbRatios,
            insulinSensitivities: sensitivities,
            defaultAbsorptionTime: declaredAbsorptionTime,
            absorptionModel: piecewise,
            delay: delay,
            delta: .minutes(5))
    }

    private func meal(at start: Date) -> NewCarbEntry {
        NewCarbEntry(quantity: HKQuantity(unit: .gram(), doubleValue: carbGrams),
                     startDate: start, foodType: nil, absorptionTime: declaredAbsorptionTime)
    }

    private func run(_ label: String, model: CarbModel = .device, mealAt start: Date? = nil,
                     judgedAtMinute minutes: Double = 60, skipping gap: ClosedRange<Double>? = nil,
                     arriving fraction: @escaping (Double) -> Double) -> Run {
        let start = start ?? t0
        let now = start.addingTimeInterval(.minutes(minutes))
        let entries = [meal(at: start)]
        let ice = counteraction(from: start, minutes: minutes, skipping: gap, fraction)

        let manager = ObservedAbsorptionManager(test_currentDate: now)
        let effect: ([GlucoseEffectVelocity]) -> [GlucoseEffect] = { readings in
            self.carbEffect(entries, model: model, from: start, readings: readings)
        }
        let measurement = manager.measureAbsorptionRatio(insulinCounteractionEffects: ice, carbEffect: effect)
        let ratio = manager.computeObservedAbsorptionRatio(insulinCounteractionEffects: ice, carbEffect: effect)

        // What the device builds every cycle: the carb effect from all readings, and the warning's
        // extra effect on top of it. The meal is older than the recent-carb exclusion, so the
        // effect to scale is the whole carb effect.
        let carbEffectNow = effect(ice)
        let observedAbsorptionEffect = manager.generateObservedAbsorptionEffects(absorptionRatio: ratio,
                                                                                 carbEffects: carbEffectNow)

        let insulinModels = PresetInsulinModelProvider(defaultRapidActingModel: nil)
        let insulinEffect = [DoseEntry(type: .bolus, startDate: start, endDate: start, value: bolusUnits, unit: .units)]
            .glucoseEffects(insulinModelProvider: insulinModels, longestEffectDuration: .hours(6),
                            insulinSensitivity: sensitivitySchedule)
        let suspendEffect = [DoseEntry(type: .tempBasal, startDate: now, endDate: now.addingTimeInterval(.hours(6)),
                                       value: -1.0, unit: .unitsPerHour)]
            .glucoseEffects(insulinModelProvider: insulinModels, longestEffectDuration: .hours(6),
                            insulinSensitivity: sensitivitySchedule)

        // BG now from what actually happened — the bolus so far plus the carbs that actually
        // arrived — not from Loop's carb effect, which below its minimum curve counts carbs it
        // assumes arrived rather than ones that did.
        let insulinSoFar = ObservedAbsorptionManager.cumulativeEffect(insulinEffect, at: now)
        let carbsSoFar = ice.reduce(0) {
            $0 + $1.quantity.doubleValue(for: mgdlPerMinute) * $1.endDate.timeIntervalSince($1.startDate).minutes
        }
        let glucoseNow = startingGlucose + insulinSoFar + carbsSoFar
        let glucose = SimpleGlucoseValue(startDate: now, quantity: HKQuantity(unit: mgdl, doubleValue: glucoseNow))

        func predict(_ extra: [[GlucoseEffect]]) -> [PredictedGlucoseValue] {
            LoopMath.predictGlucose(startingAt: glucose, momentum: [], effects: [carbEffectNow, insulinEffect] + extra)
        }
        let p1 = predict([suspendEffect])
        let p2 = predict([observedAbsorptionEffect])
        let p3 = predict([observedAbsorptionEffect, suspendEffect])

        // Timing windows opened wide on purpose: these tests are about whether the carb forecast
        // predicts a low at all, not when the user is told. The gates have their own tests.
        let settings = LoanLowBGWarningSettings(
            enabled: true, nightWarningsEnabled: true,
            dayWarningOffset: 5, nightWarningOffset: 5,
            warningSnooze: .minutes(9), dontWarnIfSooner: 0, dontWarnIfLater: .hours(6),
            delayAfterCarbEntry: .minutes(30),
            nightStartMinutes: 22 * 60 + 30, nightEndMinutes: 6 * 60 + 30,
            glucoseUnitString: mgdl.unitString, lastNotificationTime: nil)

        let (outcome, _) = LowGlucoseWarning.evaluate(LowGlucoseWarning.Inputs(
            predictionWithZeroTemp: p1,
            predictionWithObservedAbsorption: p2,
            predictionWithObservedAbsorptionAndZeroTemp: p3,
            absorptionRatio: ratio,
            suspendThreshold: HKQuantity(unit: mgdl, doubleValue: 70),
            displayUnit: mgdl,
            insulinSensitivity: isf, carbRatio: carbRatio,
            correctionTarget: 100,
            mostRecentCarbEntryDate: start,
            lastNotificationTime: nil,
            now: now,
            settings: settings))

        func minimum(_ p: [PredictedGlucoseValue]) -> Double {
            p.map { $0.quantity.doubleValue(for: mgdl) }.min() ?? .nan
        }
        let result = Run(measurement: measurement, ratio: ratio, outcome: outcome, glucoseNow: glucoseNow,
                         loopMinimum: minimum(p1), warningMinimum: minimum(p2))
        print(String(format: "[observed-absorption] %@ · minimum %.1f expected %.1f%@ · ratio %.2f (observed %.1f / expected %.1f mg/dL) · BG now %.0f · Loop min %.0f · warning min %.0f · %@",
                     label, model.overrun, model.expectationOverrun, model.adaptive ? " adaptive" : "", ratio,
                     measurement?.observedEffect ?? .nan, measurement?.expectedEffect ?? .nan,
                     glucoseNow, result.loopMinimum, result.warningMinimum, String(describing: outcome)))
        return result
    }

    private func steady(_ fraction: Double) -> (Double) -> Double { { _ in fraction } }
    /// 150% of the declared rate for the first 45 minutes, then `after`.
    private func fastStart(then after: Double) -> (Double) -> Double { { $0 < 45 ? 1.5 : after } }

    // MARK: - The scenario itself

    /// Guards the setup, not the warning: if Loop's own forecast went low, a warning test could pass
    /// for the wrong reason.
    func testLoopsOwnForecastStaysAboveTheWarningLevelInEveryScenario() {
        for model in [CarbModel.device, .overrunOfOne, .stretched] {
            for (label, fraction) in [("0%", steady(0)), ("33%", steady(1.0 / 3.0)), ("50%", steady(0.5)),
                                      ("80%", steady(0.8)), ("150%", steady(1.5)),
                                      ("fast then 30%", fastStart(then: 0.3)), ("fast then stop", fastStart(then: 0))] {
                XCTAssertGreaterThan(run(label, model: model, arriving: fraction).loopMinimum, 65, label)
            }
        }
    }

    // MARK: - The ratio against an expectation that is the entered rate (overrun 1.0)

    /// With an overrun of 1.0 Loop's forecast expects the entered rate, so the ratio is the share
    /// of the entered rate actually arriving. (Slightly high when slow from the start: below Loop's
    /// minimum curve its forecast runs over the entered time plus the 10-minute delay.)
    func testWithAnEnteredRateExpectationTheRatioIsTheShareArriving() {
        for fraction in [0.0, 1.0 / 3.0, 0.5, 0.8] {
            XCTAssertEqual(run("\(fraction)", model: .overrunOfOne, arriving: steady(fraction)).ratio,
                           fraction, accuracy: 0.06, "arriving at \(fraction) of entered")
        }
    }

    /// The case the old ratio could not see: a fast start keeps the entry above Loop's minimum
    /// curve, where Loop's carb effect up to now IS the counteraction, so comparing against it
    /// read 1.0. Against the forecast as it stood 15 minutes ago it reads the slowdown.
    func testASlowdownAfterAFastStartIsSeen() {
        XCTAssertEqual(run("fast then 30%", model: .overrunOfOne, arriving: fastStart(then: 0.3)).ratio,
                       0.3, accuracy: 0.05)
    }

    /// The other case the old ratio could not see: credited carbs that stop. It stopped at the first
    /// zero step and returned 1.0.
    func testCarbsThatStopArrivingReadZero() {
        for model in [CarbModel.device, .overrunOfOne, .stretched] {
            XCTAssertEqual(run("fast then stop", model: model, arriving: fastStart(then: 0)).ratio, 0, accuracy: 0.01)
        }
    }

    func testCarbsFasterThanExpectedReadAboveOne() {
        for model in [CarbModel.device, .overrunOfOne, .stretched] {
            XCTAssertGreaterThan(run("150%", model: model, arriving: steady(1.5)).ratio, 1.2)
        }
    }

    // MARK: - The ratio under a stretched expectation (LoopKit's default 1.5)

    /// With the expectation stretched 1.5×, the ratio is measured against the stretched rate: a
    /// third of the ENTERED rate is about half of what Loop expected.
    func testUnderAStretchedExpectationTheRatioIsMeasuredAgainstTheStretchedRate() {
        let third = run("33%", model: .stretched, arriving: steady(1.0 / 3.0)).ratio
        let half = run("50%", model: .stretched, arriving: steady(0.5)).ratio
        XCTAssertEqual(third, 0.5, accuracy: 0.08)
        XCTAssertEqual(half, 0.75, accuracy: 0.1)
        XCTAssertLessThan(run("fast then 30%", model: .stretched, arriving: fastStart(then: 0.3)).ratio, 0.6)
    }

    // MARK: - The ratio under the devices' own model, whatever the overrun

    /// Slow carbs read between their share of the ENTERED rate (overrun 1.0) and that share
    /// stretched by the minimum multiplier (overrun at its cap) — and always below 1.
    func testOnTheDevicesModelSlowCarbsReadBetweenTheirShareAndItsStretch() {
        let stretch = LoopCoreConstants.minimumAbsorptionRateTimeMultiplier
        for fraction in [1.0 / 3.0, 0.5] {
            let ratio = run("\(fraction)", arriving: steady(fraction)).ratio
            XCTAssertGreaterThanOrEqual(ratio, fraction - 0.06, "arriving at \(fraction) of entered")
            XCTAssertLessThanOrEqual(ratio, fraction * stretch + 0.1, "arriving at \(fraction) of entered")
            XCTAssertLessThan(ratio, 1, "arriving at \(fraction) of entered")
        }
    }

    func testOnTheDevicesModelASlowdownAfterAFastStartIsSeen() {
        XCTAssertLessThan(run("fast then 30%", arriving: fastStart(then: 0.3)).ratio, 0.6)
    }

    // MARK: - Adaptive: the expectation carries the history

    /// Under adaptive absorption Loop's forecast already runs at the pace observed so far, so a meal
    /// slow from the start and still slow reads as on-pace: the ratio measures a CHANGE of pace,
    /// not a shortfall against the entry. Pinned so the property is a decision, not a surprise.
    /// (80%, not slower: below Loop's minimum curve the forecast runs on that curve instead.)
    func testUnderAdaptiveAbsorptionASteadilySlowMealReadsAsOnPace() {
        let r = run("80% adaptive, 90 min", model: .adaptive, judgedAtMinute: 90, arriving: steady(0.8))
        XCTAssertEqual(r.ratio, 1.0, accuracy: 0.15)
    }

    func testUnderAdaptiveAbsorptionASlowdownIsStillSeen() {
        let slowdown: (Double) -> Double = { $0 < 75 ? 1.0 : 0.3 }
        XCTAssertLessThan(run("100% then 30% adaptive, 90 min", model: .adaptive, judgedAtMinute: 90,
                              arriving: slowdown).ratio, 0.5)
    }

    // MARK: - The measurement's mechanics

    /// A meal and its readings off Loop's 5-minute grid. The window ends on the grid (here 100 s
    /// before the newest reading), and both sides are taken over the same minutes, so the grid does
    /// not shift one against the other. The slowdown starts before the window so that every minute
    /// in it is slow.
    func testAMealOffTheGridIsJudgedOverTheSameMinutes() {
        let offGrid = t0.addingTimeInterval(100)
        XCTAssertEqual(run("fast then 30% from 40 min, off grid", model: .overrunOfOne, mealAt: offGrid,
                           arriving: { $0 < 40 ? 1.5 : 0.3 }).ratio, 0.3, accuracy: 0.05)
    }

    /// One reading missing from the window: the other two still cover 10 minutes, and both sides
    /// are taken over those 10 minutes only.
    func testAMissingReadingIsLeftOutOfBothSides() {
        let r = run("fast then 30%, 50–55 missing", model: .overrunOfOne, skipping: 50...50,
                    arriving: fastStart(then: 0.3))
        XCTAssertEqual(r.measurement?.covered ?? 0, .minutes(10), accuracy: 1)
        XCTAssertEqual(r.ratio, 0.3, accuracy: 0.05)
    }

    /// Two readings missing: too little evidence to judge, so no adjustment.
    func testTooFewReadingsMakeNoAdjustment() {
        let r = run("0%, 45–55 missing", model: .overrunOfOne, skipping: 45...50, arriving: steady(0))
        XCTAssertEqual(r.ratio, 1.0)
    }

    /// Counteraction below zero (insulin acting faster than modelled, exercise) is not negative carbs.
    func testNegativeCounteractionReadsZeroNotNegative() {
        let r = run("negative", model: .overrunOfOne, arriving: { $0 < 45 ? 1.0 : -0.5 })
        XCTAssertEqual(r.ratio, 0)
    }

    /// Long after the entry has finished, Loop expects nothing, so there is nothing to scale.
    func testNothingExpectedMakesNoAdjustment() {
        let r = run("finished", model: .overrunOfOne, judgedAtMinute: 240, arriving: steady(1.0))
        XCTAssertEqual(r.measurement?.expectedEffect ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(r.ratio, 1.0)
    }

    func testTheCumulativeEffectIsInterpolatedBetweenPoints() {
        let effects = [0.0, 10.0, 30.0].enumerated().map {
            GlucoseEffect(startDate: t0.addingTimeInterval(.minutes(Double($0.offset) * 5)),
                          quantity: HKQuantity(unit: mgdl, doubleValue: $0.element))
        }
        XCTAssertEqual(ObservedAbsorptionManager.cumulativeEffect(effects, at: t0.addingTimeInterval(-60)), 0)
        XCTAssertEqual(ObservedAbsorptionManager.cumulativeEffect(effects, at: t0), 0)
        XCTAssertEqual(ObservedAbsorptionManager.cumulativeEffect(effects, at: t0.addingTimeInterval(.minutes(7.5))), 20, accuracy: 1e-9)
        XCTAssertEqual(ObservedAbsorptionManager.cumulativeEffect(effects, at: t0.addingTimeInterval(.minutes(60))), 30)
    }

    // MARK: - The warning, under the devices' own model, whatever the overrun

    func testCarbsNeverEatenWarnOfALow() {
        XCTAssertNotEqual(run("0%", arriving: steady(0)).outcome, .none)
    }

    func testCarbsThatStopArrivingWarnOfALow() {
        XCTAssertNotEqual(run("fast then stop", arriving: fastStart(then: 0)).outcome, .none)
    }

    func testCarbsAtAThirdOfTheEnteredRateWarnOfALow() {
        XCTAssertNotEqual(run("33%", arriving: steady(1.0 / 3.0)).outcome, .none)
    }

    func testCarbsFasterThanExpectedDoNotWarn() {
        XCTAssertEqual(run("150%", arriving: steady(1.5)).outcome, .none)
    }

    // MARK: - The warning, with an entered-rate expectation

    func testWithAnEnteredRateExpectationSlowCarbsWarnOfALow() {
        for fraction in [0.0, 1.0 / 3.0, 0.5] {
            XCTAssertNotEqual(run("\(fraction)", model: .overrunOfOne, arriving: steady(fraction)).outcome, .none,
                              "arriving at \(fraction) of entered")
        }
        XCTAssertEqual(run("150%", model: .overrunOfOne, arriving: steady(1.5)).outcome, .none)
    }
}
