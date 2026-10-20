//
//  ObservedAbsorptionWarningTests.swift
//  WatchAppTests
//
//  The predicted-low warning's carb half, end to end: declared meals, a stream of insulin
//  counteraction readings showing how fast their carbs actually arrive, Loop's own carb math, and
//  the shared `LowGlucoseWarning.assess` — the same function the phone and the watch call — from
//  the ratio through the three forecasts to the decision.
//
//  What the warning is for: once carbs are declared, the insulin for them is aboard. Loop's own
//  forecast assumes every declared gram still arrives, only later if absorption is slow. The
//  warning's forecast asks the other question — what if fewer arrive — by comparing what arrived
//  over the last 15 minutes with what Loop's carb forecast, as it stood 15 minutes ago, expected for
//  those minutes, and scaling the remaining carbs by that ratio (fewer carbs, same timing).
//
//  The expectation is whatever the configured absorption model said at the time, so the model is
//  part of each test:
//  - named models (`overrunOfOne`, `stretched`, `adaptive`) pin exact numbers, and do not depend on
//    the app's constants;
//  - `device` reads the app's own `LoopCoreConstants` (the minimum absorption rate and the
//    absorption time overrun), and its tests assert only what must hold for any overrun from 1.0
//    up to the minimum multiplier, so tuning the overrun does not break them.
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
    /// `scale` multiplies sensitivity and carb ratio, as an active override does.
    private struct CarbModel {
        var overrun = CarbMath.defaultAbsorptionTimeOverrun
        var expectationOverrun = CarbMath.defaultAbsorptionTimeOverrun
        var adaptive = false
        var scale = (isf: 1.0, carbRatio: 1.0)
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
        let assessment: LowGlucoseWarning.Assessment
        let glucoseNow: Double
        var ratio: Double { assessment.absorptionRatio }
        var outcome: LowGlucoseWarning.Outcome { assessment.outcome }
        /// P1: Loop's own forecast, suspend applied.
        var loopMinimum: Double { Self.minimum(assessment.predictionWithZeroTemp) }
        /// P2: the warning's forecast.
        var warningMinimum: Double { Self.minimum(assessment.predictionWithObservedAbsorption) }
        static func minimum(_ p: [PredictedGlucoseValue]) -> Double {
            p.map { $0.quantity.doubleValue(for: .milligramsPerDeciliter) }.min() ?? .nan
        }
    }

    /// The declared arrival rate `minute` after an entry's start, in g/min: the entered grams over
    /// the entered time, shaped by Loop's carb curve, zero during the start delay.
    private func declaredRate(atMinute minute: Double, grams: Double? = nil) -> Double {
        let absorbing = minute - delay.minutes
        guard absorbing > 0 else { return 0 }
        return (grams ?? carbGrams) / declaredAbsorptionTime.minutes
            * piecewise.percentRateAtPercentTime(absorbing / declaredAbsorptionTime.minutes)
    }

    /// Counteraction readings every 5 minutes from `start` until `minutes` later, at `rate(minute)`
    /// mg/dL/min, the minute being the reading's midpoint. Readings starting inside `gap` are missing.
    private func counteraction(from start: Date, minutes: Double, skipping gap: ClosedRange<Double>? = nil,
                               rate: (Double) -> Double) -> [GlucoseEffectVelocity] {
        stride(from: 0.0, to: minutes, by: 5.0).compactMap { m in
            if let gap = gap, gap.contains(m) { return nil }
            return GlucoseEffectVelocity(startDate: start.addingTimeInterval(.minutes(m)),
                                         endDate: start.addingTimeInterval(.minutes(m + 5)),
                                         quantity: HKQuantity(unit: mgdlPerMinute, doubleValue: rate(m + 2.5)))
        }
    }

    private func schedules(_ model: CarbModel) -> (carbRatios: [AbsoluteScheduleValue<Double>],
                                                    sensitivities: [AbsoluteScheduleValue<HKQuantity>],
                                                    sensitivity: InsulinSensitivitySchedule) {
        let start = t0.addingTimeInterval(.days(-1)), end = t0.addingTimeInterval(.days(1))
        let isf = self.isf * model.scale.isf
        return ([AbsoluteScheduleValue(startDate: start, endDate: end, value: carbRatio * model.scale.carbRatio)],
                [AbsoluteScheduleValue(startDate: start, endDate: end, value: HKQuantity(unit: mgdl, doubleValue: isf))],
                InsulinSensitivitySchedule(unit: mgdl, dailyItems: [RepeatingScheduleValue(startTime: 0, value: isf)],
                                           timeZone: TimeZone(identifier: "UTC")!)!)
    }

    /// The carb effect exactly as CarbStore builds it from a set of readings.
    private func carbEffect(_ entries: [NewCarbEntry], model: CarbModel, from start: Date,
                            readings: [GlucoseEffectVelocity]) -> [GlucoseEffect] {
        let s = schedules(model)
        return entries.map(
            to: readings,
            carbRatio: s.carbRatios,
            insulinSensitivity: s.sensitivities,
            absorptionTimeOverrun: model.overrun,
            defaultAbsorptionTime: declaredAbsorptionTime,
            delay: delay,
            initialAbsorptionTimeOverrun: model.expectationOverrun,
            absorptionModel: piecewise,
            adaptiveAbsorptionRateEnabled: model.adaptive
        ).dynamicGlucoseEffects(
            from: start,
            carbRatios: s.carbRatios,
            insulinSensitivities: s.sensitivities,
            defaultAbsorptionTime: declaredAbsorptionTime,
            absorptionModel: piecewise,
            delay: delay,
            delta: .minutes(5))
    }

    private func meal(at start: Date, grams: Double? = nil) -> NewCarbEntry {
        NewCarbEntry(quantity: HKQuantity(unit: .gram(), doubleValue: grams ?? carbGrams),
                     startDate: start, foodType: nil, absorptionTime: declaredAbsorptionTime)
    }

    /// One meal, its carbs arriving at `fraction(minute)` of the declared rate.
    private func run(_ label: String, model: CarbModel = .device, mealAt start: Date? = nil,
                     judgedAtMinute minutes: Double = 60, skipping gap: ClosedRange<Double>? = nil,
                     arriving fraction: @escaping (Double) -> Double) -> Run {
        let start = start ?? t0
        return assess(label, model: model, start: start, minutes: minutes, entries: [meal(at: start)],
                      readings: counteraction(from: start, minutes: minutes, skipping: gap) {
                          fraction($0) * self.declaredRate(atMinute: $0) * self.csf
                      })
    }

    /// The shared assessment, fed as the devices feed it.
    private func assess(_ label: String, model: CarbModel, start: Date, minutes: Double,
                        entries: [NewCarbEntry], readings ice: [GlucoseEffectVelocity],
                        glucoseAge: TimeInterval = 0, pumpDataAge: TimeInterval? = 0) -> Run {
        let now = start.addingTimeInterval(.minutes(minutes))
        let effect: ([NewCarbEntry], [GlucoseEffectVelocity]) -> [GlucoseEffect] = { entries, readings in
            self.carbEffect(entries, model: model, from: start, readings: readings)
        }
        // For the numbers only: what the ratio saw, for the same entries the assessment judges.
        let judged = entries.filter { $0.startDate <= now.addingTimeInterval(-ObservedAbsorptionSettings.recentAndFutureCarbExclusionWindow) }
        let measurement = ObservedAbsorptionManager().measureAbsorptionRatio(insulinCounteractionEffects: ice) {
            effect(judged, $0)
        }

        let sensitivity = schedules(model).sensitivity
        let insulinModels = PresetInsulinModelProvider(defaultRapidActingModel: nil)
        let insulinEffect = [DoseEntry(type: .bolus, startDate: start, endDate: start, value: bolusUnits, unit: .units)]
            .glucoseEffects(insulinModelProvider: insulinModels, longestEffectDuration: .hours(6),
                            insulinSensitivity: sensitivity)
        let suspendEffect = [DoseEntry(type: .tempBasal, startDate: now, endDate: now.addingTimeInterval(.hours(6)),
                                       value: -1.0, unit: .unitsPerHour)]
            .glucoseEffects(insulinModelProvider: insulinModels, longestEffectDuration: .hours(6),
                            insulinSensitivity: sensitivity)

        // BG now from what actually happened — the bolus so far plus the carbs that actually arrived —
        // not from Loop's carb effect, which below its minimum curve counts carbs it assumes arrived.
        let insulinSoFar = ObservedAbsorptionManager.cumulativeEffect(insulinEffect, at: now)
        let carbsSoFar = ice.reduce(0) {
            $0 + $1.quantity.doubleValue(for: mgdlPerMinute) * $1.endDate.timeIntervalSince($1.startDate).minutes
        }
        let glucoseNow = startingGlucose + insulinSoFar + carbsSoFar
        let glucose = SimpleGlucoseValue(startDate: now.addingTimeInterval(-glucoseAge),
                                         quantity: HKQuantity(unit: mgdl, doubleValue: glucoseNow))

        // Timing windows opened wide on purpose: these tests are about whether the carb forecast
        // predicts a low at all, not when the user is told. The gates have their own tests.
        let settings = LoanLowBGWarningSettings(
            enabled: true, nightWarningsEnabled: true,
            dayWarningOffset: 5, nightWarningOffset: 5,
            warningSnooze: .minutes(9), dontWarnIfSooner: 0, dontWarnIfLater: .hours(6),
            delayAfterCarbEntry: .minutes(30),
            nightStartMinutes: 22 * 60 + 30, nightEndMinutes: 6 * 60 + 30,
            glucoseUnitString: mgdl.unitString, lastNotificationTime: nil)

        let assessment = LowGlucoseWarning.assess(LowGlucoseWarning.Ingredients(
            glucose: glucose,
            lastPumpDataDate: pumpDataAge.map { now.addingTimeInterval(-$0) },
            momentum: [],
            carbEffect: effect(entries, ice),
            insulinEffect: insulinEffect,
            retrospectiveEffect: [],
            suspendEffect: suspendEffect,
            insulinCounteractionEffects: ice,
            carbEntries: entries,
            carbEffectOf: effect,
            longestEffectDuration: .hours(6),
            suspendThreshold: HKQuantity(unit: mgdl, doubleValue: 70),
            displayUnit: mgdl,
            insulinSensitivity: isf * model.scale.isf,
            carbRatio: carbRatio * model.scale.carbRatio,
            correctionTarget: 100,
            lastNotificationTime: nil,
            now: now,
            settings: settings))

        let result = Run(measurement: measurement, assessment: assessment, glucoseNow: glucoseNow)
        print(String(format: "[observed-absorption] %@ · minimum %.1f expected %.1f%@ · ratio %.2f (observed %.1f / expected %.1f mg/dL) · BG now %.0f · Loop min %.0f · warning min %.0f · %@",
                     label, model.overrun, model.expectationOverrun, model.adaptive ? " adaptive" : "", result.ratio,
                     measurement?.observedEffect ?? .nan, measurement?.expectedEffect ?? .nan,
                     glucoseNow, result.loopMinimum, result.warningMinimum, String(describing: result.outcome)))
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

    // MARK: - Rulings (2026-10-20)

    /// (1) Overlapping meals share one blended ratio: a main course on pace and a dessert whose carbs
    /// never arrive read somewhere between the two.
    func testOverlappingMealsShareOneBlendedRatio() {
        let dessert = meal(at: t0.addingTimeInterval(.minutes(20)), grams: 30)
        let readings = counteraction(from: t0, minutes: 60) { self.declaredRate(atMinute: $0) * self.csf }
        let r = assess("main on pace + dessert never arrives", model: .overrunOfOne, start: t0, minutes: 60,
                       entries: [meal(at: t0), dessert], readings: readings)
        XCTAssertGreaterThan(r.ratio, 0.1)
        XCTAssertLessThan(r.ratio, 0.9)
    }

    /// (2) Rescue carbs eaten in the last 15 minutes are kept out of the expectation and the scaling,
    /// but their arrival counts in the observed rate: they really are raising BG, so the ratio rises.
    func testRecentRescueCarbsRaiseTheRatio() {
        let tabs = NewCarbEntry(quantity: HKQuantity(unit: .gram(), doubleValue: 15),
                                startDate: t0.addingTimeInterval(.minutes(48)), foodType: nil, absorptionTime: .minutes(30))
        let mealStopped = { (m: Double) in m < 45 ? 1.5 * self.declaredRate(atMinute: m) * self.csf : 0 }
        let tabsArriving = { (m: Double) in m > 50 ? 0.5 * self.csf : 0 }   // 0.5 g/min from minute 50
        let without = assess("meal stopped", model: .overrunOfOne, start: t0, minutes: 60,
                             entries: [meal(at: t0)], readings: counteraction(from: t0, minutes: 60, rate: mealStopped))
        let with = assess("meal stopped + tabs", model: .overrunOfOne, start: t0, minutes: 60,
                          entries: [meal(at: t0), tabs],
                          readings: counteraction(from: t0, minutes: 60) { mealStopped($0) + tabsArriving($0) })
        XCTAssertEqual(without.ratio, 0, accuracy: 0.01)
        XCTAssertGreaterThan(with.ratio, 0.2)
    }

    /// (3) Exercise mid-meal: counteraction below zero reads as nothing arriving, and warns — the
    /// warning's job is the low, not the diagnosis.
    func testExerciseMidMealWarns() {
        let r = run("exercise", model: .overrunOfOne, arriving: { $0 < 45 ? 1.0 : -0.5 })
        XCTAssertEqual(r.ratio, 0)
        XCTAssertNotEqual(r.outcome, .none)
    }

    /// (4) An edited entry is the truth, backwards too: the same arrival judged against a smaller
    /// corrected entry reads higher.
    func testAnEditedEntryIsJudgedAsEdited() {
        let readings = counteraction(from: t0, minutes: 60) { 0.5 * self.declaredRate(atMinute: $0) * self.csf }
        let asEntered = assess("45 g", model: .overrunOfOne, start: t0, minutes: 60,
                               entries: [meal(at: t0)], readings: readings)
        let corrected = assess("edited to 30 g", model: .overrunOfOne, start: t0, minutes: 60,
                               entries: [meal(at: t0, grams: 30)], readings: readings)
        XCTAssertGreaterThan(corrected.ratio, asEntered.ratio * 1.3)
    }

    /// (5) A noisy reading in the middle of the window cancels: its jump up and its jump back.
    func testANoisyReadingInTheMiddleOfTheWindowCancels() {
        let clean = { (m: Double) in 0.5 * self.declaredRate(atMinute: m) * self.csf }
        let spike = { (m: Double) -> Double in   // +3 mg/dL/min for 50–55, −3 for 55–60: one reading 15 mg/dL high
            m > 50 && m < 55 ? clean(m) + 3 : (m > 55 && m < 60 ? clean(m) - 3 : clean(m))
        }
        let a = assess("clean", model: .overrunOfOne, start: t0, minutes: 60, entries: [meal(at: t0)],
                       readings: counteraction(from: t0, minutes: 60, rate: clean))
        let b = assess("one noisy reading", model: .overrunOfOne, start: t0, minutes: 60, entries: [meal(at: t0)],
                       readings: counteraction(from: t0, minutes: 60, rate: spike))
        XCTAssertEqual(a.ratio, b.ratio, accuracy: 0.01)
    }

    /// (6) An override divides sensitivity and carb ratio by the same factor, so a gram is worth the
    /// same and the ratio is unchanged.
    func testAnOverrideDoesNotChangeTheRatio() {
        let override = TemporaryScheduleOverrideSettings(unit: mgdl, targetRange: nil, insulinNeedsScaleFactor: 0.5)
        var withOverride = CarbModel.overrunOfOne
        withOverride.scale = (isf: override.insulinSensitivityMultiplier!, carbRatio: override.carbRatioMultiplier!)
        let plain = run("50%", model: .overrunOfOne, arriving: steady(0.5))
        let overridden = run("50%, 50% override", model: withOverride, arriving: steady(0.5))
        XCTAssertEqual(plain.ratio, overridden.ratio, accuracy: 0.001)
    }

    // MARK: - Loop's recency rules

    func testOldGlucoseMakesNoWarningAndNoForecast() {
        let readings = counteraction(from: t0, minutes: 60) { _ in 0 }
        let r = assess("glucose 20 min old", model: .overrunOfOne, start: t0, minutes: 60,
                       entries: [meal(at: t0)], readings: readings, glucoseAge: .minutes(20))
        XCTAssertEqual(r.outcome, .none)
        XCTAssertTrue(r.assessment.predictionWithObservedAbsorption.isEmpty)
    }

    func testFutureGlucoseMakesNoWarning() {
        let readings = counteraction(from: t0, minutes: 60) { _ in 0 }
        XCTAssertEqual(assess("glucose 10 min ahead", model: .overrunOfOne, start: t0, minutes: 60,
                              entries: [meal(at: t0)], readings: readings, glucoseAge: .minutes(-10)).outcome, .none)
    }

    func testStaleOrMissingPumpDataMakesNoWarning() {
        let readings = counteraction(from: t0, minutes: 60) { _ in 0 }
        for age in [TimeInterval.minutes(20), nil] {
            XCTAssertEqual(assess("pump data \(String(describing: age))", model: .overrunOfOne, start: t0, minutes: 60,
                                  entries: [meal(at: t0)], readings: readings, pumpDataAge: age).outcome, .none)
        }
    }

    /// The same never-eaten meal does warn with fresh data, so the three tests above fail for the
    /// reason they name.
    func testFreshDataDoesWarn() {
        let readings = counteraction(from: t0, minutes: 60) { _ in 0 }
        XCTAssertNotEqual(assess("fresh", model: .overrunOfOne, start: t0, minutes: 60,
                                 entries: [meal(at: t0)], readings: readings).outcome, .none)
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
        XCTAssertEqual(run("0%, 45–55 missing", model: .overrunOfOne, skipping: 45...50, arriving: steady(0)).ratio, 1.0)
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
