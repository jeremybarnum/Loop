//
//  ObservedAbsorption.swift
//  LoopCore
//
//  The predicted-low warning's absorption ratio and the carb effect it adds. Ported from the
//  production line's `ObservedAbsorptionManager` (2026-10-20/21); the logic is unchanged.
//

import Foundation
import LoopAlgorithm

public enum ObservedAbsorption {
    /// Entries this recent (or in the future) are left out of the expectation and the scaling: they
    /// are usually rescue carbs, and scaling those down would argue for treating a low that is
    /// already being treated.
    public static let recentAndFutureCarbExclusionWindow: TimeInterval = 15 * 60
    /// The ratio compares carbs that arrived over this many most recent minutes of counteraction
    /// readings with what the entries' carb forecast, made at the start of those minutes, expected.
    public static let absorptionRatioWindow: TimeInterval = 15 * 60
    /// Readings must cover at least this much of the window, or the ratio is 1.0 (no adjustment).
    public static let absorptionRatioMinimumCoverage: TimeInterval = 10 * 60

    /// How a ratio was reached, kept for logging and for tests.
    public struct Measurement: Equatable {
        /// The minutes judged: the window, ending at the carb-effect grid point at or before the
        /// newest counteraction reading.
        public let window: DateInterval
        /// How much of the window the readings actually cover.
        public let covered: TimeInterval
        /// Carbs that arrived over the covered minutes, as glucose effect (mg/dL), from counteraction.
        public let observedEffect: Double
        /// Carbs the forecast, as it stood at the start of the window, expected over the same minutes.
        public let expectedEffect: Double
        public let ratio: Double
    }

    /// The share of the expected carbs that is actually arriving.
    ///
    /// Observed: insulin counteraction over the most recent window of readings, ending on the carb
    /// effect's 5-minute grid. Expected: what the carb forecast, as it stood at the START of that
    /// window, said would arrive during it — rebuilt by handing `carbEffect` only the readings that
    /// existed then. The caller's `carbEffect` is the entries on their entered absorption times.
    ///
    /// Applied to the forecast of the remaining carbs, the ratio keeps their timing and changes their
    /// amount: Loop assumes slow carbs arrive later, the warning asks what happens if fewer do.
    /// - Returns: nil when there are no readings at all.
    public static func measureRatio(
        insulinCounteractionEffects: [GlucoseEffectVelocity],
        carbEffect: ([GlucoseEffectVelocity]) throws -> [GlucoseEffect]
    ) rethrows -> Measurement? {
        guard let newest = insulinCounteractionEffects.last?.endDate else { return nil }
        let windowEnd = newest.dateFlooredToTimeInterval(GlucoseMath.defaultDelta)
        let window = DateInterval(start: windowEnd.addingTimeInterval(-absorptionRatioWindow), end: windowEnd)
        let forecastAtWindowStart = try carbEffect(insulinCounteractionEffects.filter { $0.endDate <= window.start })

        // Both sides over exactly the same minutes: wherever a reading overlaps the window, what it
        // showed arriving, and what the forecast expected for that stretch.
        var covered: TimeInterval = 0
        var observed = 0.0
        var expected = 0.0
        for reading in insulinCounteractionEffects where reading.endDate > window.start && reading.endDate > reading.startDate {
            guard let overlap = DateInterval(start: reading.startDate, end: reading.endDate).intersection(with: window),
                  overlap.duration > 0 else { continue }
            covered += overlap.duration
            observed += reading.quantity.doubleValue(for: .milligramsPerDeciliterPerMinute) * overlap.duration / 60
            expected += cumulativeEffect(forecastAtWindowStart, at: overlap.end)
                - cumulativeEffect(forecastAtWindowStart, at: overlap.start)
        }
        let ratio: Double
        if covered < absorptionRatioMinimumCoverage {
            ratio = 1.0   // too little evidence to judge: no adjustment
        } else if expected <= 0 {
            ratio = 1.0   // nothing was expected in these minutes, so there is nothing to scale
        } else {
            ratio = max(observed / expected, 0)
        }
        return Measurement(window: window, covered: covered, observedEffect: observed, expectedEffect: expected, ratio: ratio)
    }

    /// A cumulative effect timeline's value at `date`, interpolated: zero before the first point, flat after the last.
    public static func cumulativeEffect(_ effects: [GlucoseEffect], at date: Date) -> Double {
        guard let after = effects.firstIndex(where: { $0.startDate >= date }) else {
            return effects.last?.quantity.doubleValue(for: .milligramsPerDeciliter) ?? 0
        }
        let next = effects[after]
        guard after > 0 else {
            return next.startDate == date ? next.quantity.doubleValue(for: .milligramsPerDeciliter) : 0
        }
        let previous = effects[after - 1]
        let span = next.startDate.timeIntervalSince(previous.startDate)
        let fraction = span > 0 ? date.timeIntervalSince(previous.startDate) / span : 1
        let a = previous.quantity.doubleValue(for: .milligramsPerDeciliter), b = next.quantity.doubleValue(for: .milligramsPerDeciliter)
        return a + (b - a) * fraction
    }

    /// What the ratio adds to the carb effect: (ratio − 1) × the effect, same timing.
    public static func effect(absorptionRatio: Double, carbEffects: [GlucoseEffect]) -> [GlucoseEffect] {
        carbEffects.map { effect in
            GlucoseEffect(startDate: effect.startDate,
                          quantity: LoopQuantity(unit: .milligramsPerDeciliter,
                                                 doubleValue: effect.quantity.doubleValue(for: .milligramsPerDeciliter) * (absorptionRatio - 1.0)))
        }
    }
}
