//
//  WatchDosingLimitsTests.swift
//  LoopTests
//
//  The dosing-limit coverage Jeremy's own physiology cannot produce.
//
//  Field BG on the bench rig is narrow euglycemia, so the interesting DoseMath
//  verdicts — maxBasal saturation, the IOB clamp, the high-basal-threshold guard,
//  suspend — only ever appeared via the synthetic fake-BG sweep. This suite pins
//  them deterministically, at the SAME integration point WatchLoopManager uses:
//  predictedGlucose.recommendedTempBasal(...) with the watch's own arguments
//  (maxBasal, additionalActiveInsulinClamp, lastTempBasal, suspendThreshold).
//
//  It deliberately does NOT re-test DoseMath internals — LoopKit's DoseMathTests
//  own those. What is pinned here is the CONTRACT the watch depends on, including
//  the two rules that were misread during a field session.
//
//  Settings mirror Jeremy's real therapy settings from that session so the
//  expectations can be checked against the field log directly.
//

import XCTest
import HealthKit
import LoopKit

final class WatchDosingLimitsTests: XCTestCase {

    // Jeremy's settings, 2026-07-22 evening.
    private let scheduledBasal = 0.70
    private let maxBasal = 3.45
    private let suspendThreshold = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 67)

    private let basalSchedule = BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 0.70)])!
    private let isfSchedule = InsulinSensitivitySchedule(unit: .milligramsPerDeciliter,
                                                         dailyItems: [RepeatingScheduleValue(startTime: 0, value: 70.0)])!
    private let targetRange = GlucoseRangeSchedule(unit: .milligramsPerDeciliter,
                                                   dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 115))])!
    private let model = ExponentialInsulinModelPreset.rapidActingAdult

    /// The pod's rate granularity. Established empirically from the field log:
    /// 0.42 -> 0.40, 0.66 -> 0.65, 1.08 -> 1.05, 1.44 -> 1.40 — i.e. FLOOR to 0.05,
    /// not round-to-nearest (1.08 would round UP to 1.10).
    private let rateRounder: (Double) -> Double = { (($0 / 0.05).rounded(.down)) * 0.05 }

    /// A predicted curve at 5-minute spacing, as DoseMath consumes it.
    private func curve(from now: Date, values: [Double]) -> [PredictedGlucoseValue] {
        values.enumerated().map { index, mgdl in
            PredictedGlucoseValue(startDate: now.addingTimeInterval(.minutes(Double(index) * 5)),
                                  quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl))
        }
    }

    /// A flat-high curve: every point well above target, so the correction is
    /// unambiguously .aboveRange and the only thing that can limit the rate is a cap.
    private func flatHigh(from now: Date, mgdl: Double = 250, hours: Double = 6) -> [PredictedGlucoseValue] {
        curve(from: now, values: Array(repeating: mgdl, count: Int(hours * 12) + 1))
    }

    private func recommend(_ predicted: [PredictedGlucoseValue],
                           at date: Date,
                           clamp: Double? = nil,
                           lastTempBasal: DoseEntry? = nil) -> TempBasalRecommendation? {
        predicted.recommendedTempBasal(
            to: targetRange,
            at: date,
            suspendThreshold: suspendThreshold,
            sensitivity: isfSchedule,
            model: model,
            basalRates: basalSchedule,
            maxBasalRate: maxBasal,
            additionalActiveInsulinClamp: clamp,
            lastTempBasal: lastTempBasal,
            rateRounder: rateRounder
        )
    }

    // MARK: - 1. maxBasal is the ceiling

    func testFlatHighCurveSaturatesAtMaxBasalAndNeverExceedsIt() {
        let now = Date()
        // Generous clamp headroom so the IOB limit cannot be the binding constraint.
        let rec = recommend(flatHigh(from: now), at: now, clamp: 5.0)
        XCTAssertNotNil(rec, "a curve pinned at 250 must recommend insulin")
        XCTAssertEqual(rec!.unitsPerHour, maxBasal, accuracy: 0.001,
                       "saturates at maxBasal — and must never exceed the configured maximum")
    }

    // MARK: - 2. The high-basal-threshold guard (the rule misread on 2026-07-22)

    // DoseMath: if the correction is .aboveRange but the predicted MINIMUM is below
    // the target's lower bound, maxBasalRate collapses to the SCHEDULED rate:
    //
    //     if case .aboveRange(min:..., minTarget: let highBasalThreshold, ...) = correction,
    //        min.quantity < highBasalThreshold { maxBasalRate = scheduledBasalRate }
    //
    // This is the real rule — NOT "Loop doses off the minimum." Eventual above range
    // still triggers a correction; a dipping minimum just forbids exceeding schedule.
    func testMinimumBelowTargetCollapsesMaxBasalToScheduled() {
        let now = Date()
        // Eventual high (250), but an early point dips to 95 — under target's 100 floor
        // and above the 67 suspend threshold, so this is the guard, not a suspend.
        var values = [120.0, 95.0]
        values.append(contentsOf: Array(repeating: 250.0, count: 71))
        let rec = recommend(curve(from: now, values: values), at: now, clamp: 5.0)

        if let rec = rec {
            XCTAssertLessThanOrEqual(rec.unitsPerHour, scheduledBasal + 0.001,
                                     "a minimum below target forbids exceeding the scheduled rate, however high eventual is")
        }
        // nil (leave the scheduled basal alone) is equally correct here.
    }

    // MARK: - 3. Suspend threshold dominates everything

    func testAnyPointBelowSuspendThresholdRecommendsZero() {
        let now = Date()
        // Eventual is very high, but one early point is under the 67 threshold.
        var values = [110.0, 60.0]
        values.append(contentsOf: Array(repeating: 300.0, count: 71))
        let rec = recommend(curve(from: now, values: values), at: now, clamp: 5.0)

        XCTAssertNotNil(rec, "a sub-threshold prediction must produce an explicit zero temp")
        XCTAssertEqual(rec!.unitsPerHour, 0, accuracy: 0.001,
                       "suspend wins over any eventual, however high")
    }

    // MARK: - 4. The IOB clamp — reproducing the field ramp exactly

    // The clamp converts remaining IOB headroom into a rate ceiling:
    //     maxRate = additionalActiveInsulinClamp * 2 + scheduledBasalRate
    // (a 30-minute temp at rate R delivers R/2 units, so R = headroom * 2 keeps the
    // added insulin within headroom), then floors to the pod's 0.05 granularity.
    //
    // These four cases are lifted from the 2026-07-22 field log, where IOB was decaying
    // through the automatic-dosing limit and produced a smooth graduated ramp. Pinning
    // them means a future refactor that changes clamp handling fails loudly.
    func testIOBClampProducesTheObservedGraduatedRamp() {
        let now = Date()
        let cases: [(headroom: Double, expected: Double)] = [
            (-0.14, 0.40),   // field 22:17 — IOB 6.14
            (-0.02, 0.65),   // field 22:22 — IOB 6.02
            ( 0.19, 1.05),   // field 22:27 — IOB 5.81
            ( 0.37, 1.40),   // field 22:32 — IOB 5.63
        ]
        for (headroom, expected) in cases {
            let rec = recommend(flatHigh(from: now), at: now, clamp: headroom)
            XCTAssertNotNil(rec, "clamped headroom \(headroom) should still yield an explicit temp")
            XCTAssertEqual(rec!.unitsPerHour, expected, accuracy: 0.001,
                           "headroom \(headroom): expected \(expected) U/hr (headroom*2 + \(scheduledBasal), floored to 0.05)")
        }
    }

    /// Deeply negative headroom (the 7.40 U books) must withdraw basal, never add.
    func testExhaustedIOBHeadroomNeverAddsInsulin() {
        let now = Date()
        let rec = recommend(flatHigh(from: now), at: now, clamp: -1.40)   // field 22:02, IOB 7.40
        if let rec = rec {
            XCTAssertLessThanOrEqual(rec.unitsPerHour, scheduledBasal + 0.001,
                                     "with the automatic-dosing limit exceeded, the loop may only hold or withdraw")
        }
    }
}
