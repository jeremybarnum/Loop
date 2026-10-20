//
//  ObservedAbsorptionManager.swift
//  Loop
//
//  Created by Jeremy Barnum on 5/8/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import OSLog
import LoopCore
import LoopKit


class ObservedAbsorptionManager {
    //private let log = OSLog(category: "ObservedAbsorptionManager")
    private let predictionLogger = DiagnosticLog(category: "PredictionAnalysis")

    
    /// Allows for controlling uses of the system date in unit testing
    internal var test_currentDate: Date?
    
    /// Current date. Will return the unit-test configured date if set, or the current date otherwise.
    internal var currentDate: Date {
        test_currentDate ?? Date()
    }

    internal func currentDate(timeIntervalSinceNow: TimeInterval = 0) -> Date {
        return currentDate.addingTimeInterval(timeIntervalSinceNow)
    }
    
    public init(
        test_currentDate: Date? = nil
    ) {

        self.test_currentDate = test_currentDate
    }
    
    let carbUnit = HKUnit.milligramsPerDeciliter
    let ICEUnit = HKUnit.milligramsPerDeciliterPerMinute
    
    // MARK: Absorption ratio

    /// How a ratio was reached, kept for logging and for tests.
    struct AbsorptionRatioMeasurement: Equatable {
        /// The minutes judged: `absorptionRatioWindow`, ending at the carb-effect grid point at or
        /// before the newest counteraction reading.
        let window: DateInterval
        /// How much of the window the readings actually cover.
        let covered: TimeInterval
        /// Carbs that arrived over the covered minutes, as glucose effect (mg/dL), from counteraction.
        let observedEffect: Double
        /// Carbs Loop's carb forecast, as it stood at the start of the window, expected over the
        /// same minutes (mg/dL).
        let expectedEffect: Double
        let ratio: Double
    }

    /// The share of the expected carbs that is actually arriving.
    ///
    /// Observed: insulin counteraction over the most recent `absorptionRatioWindow` of readings.
    /// The window ends on the carb effect's 5-minute grid, so both ends of the expectation are values
    /// the carb store computed rather than interpolations across the point where its record of
    /// absorbed carbs hands over to its forecast — readings fall at arbitrary seconds, the grid does not.
    /// Expected: what Loop's own carb forecast, as it stood at the START of that window, said would
    /// arrive during it. That forecast is rebuilt by handing `carbEffect` only the readings that
    /// existed then — the same carb-store call the device makes every cycle — so the expectation is
    /// whatever the configured absorption model (linear, nonlinear or adaptive) said at the time.
    /// The model decides when the remaining carbs are due; this compares that with what came.
    ///
    /// Applied to Loop's forecast of the remaining carbs, the ratio keeps their timing and changes
    /// their amount: Loop assumes slow carbs arrive later, the warning asks what happens if fewer do.
    ///
    /// - Parameters:
    ///   - insulinCounteractionEffects: the device's counteraction readings, oldest first.
    ///   - carbEffect: the device's carb effect for the entries being judged, computed from the
    ///     readings passed in — the carb store's `glucoseEffects(of:startingAt:endingAt:effectVelocities:)`.
    /// - Returns: nil when there are no readings at all.
    func measureAbsorptionRatio(
        insulinCounteractionEffects: [GlucoseEffectVelocity],
        carbEffect: ([GlucoseEffectVelocity]) throws -> [GlucoseEffect]
    ) rethrows -> AbsorptionRatioMeasurement? {
        guard let newest = insulinCounteractionEffects.last?.endDate else { return nil }
        let windowEnd = newest.dateFlooredToTimeInterval(GlucoseMath.defaultDelta)
        let window = DateInterval(start: windowEnd.addingTimeInterval(-ObservedAbsorptionSettings.absorptionRatioWindow),
                                  end: windowEnd)

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
            observed += reading.quantity.doubleValue(for: ICEUnit) * overlap.duration / 60
            expected += Self.cumulativeEffect(forecastAtWindowStart, at: overlap.end)
                - Self.cumulativeEffect(forecastAtWindowStart, at: overlap.start)
        }

        let ratio: Double
        if covered < ObservedAbsorptionSettings.absorptionRatioMinimumCoverage {
            ratio = 1.0   // too little evidence to judge: no adjustment
        } else if expected <= 0 {
            ratio = 1.0   // Loop expected nothing in these minutes, so there is nothing to scale
        } else {
            ratio = max(observed / expected, 0)
        }
        return AbsorptionRatioMeasurement(window: window, covered: covered,
                                          observedEffect: observed, expectedEffect: expected, ratio: ratio)
    }

    /// `measureAbsorptionRatio`, reduced to the ratio and logged; 1.0 when there is nothing to judge.
    func computeObservedAbsorptionRatio(
        insulinCounteractionEffects: [GlucoseEffectVelocity],
        carbEffect: ([GlucoseEffectVelocity]) throws -> [GlucoseEffect]
    ) rethrows -> Double {
        guard let m = try measureAbsorptionRatio(insulinCounteractionEffects: insulinCounteractionEffects,
                                                 carbEffect: carbEffect) else {
            predictionLogger.info("Absorption ratio: no counteraction readings, 1.0")
            return 1.0
        }
        predictionLogger.info("Absorption ratio %.3f: observed %.1f mg/dL vs expected %.1f mg/dL over %.1f of the last %.0f min of readings",
                              m.ratio, m.observedEffect, m.expectedEffect, m.covered / 60, m.window.duration / 60)
        return m.ratio
    }

    /// A cumulative effect timeline's value at `date`, interpolated between its points: zero before
    /// the first, flat after the last.
    static func cumulativeEffect(_ effects: [GlucoseEffect], at date: Date) -> Double {
        let unit = HKUnit.milligramsPerDeciliter
        guard let after = effects.firstIndex(where: { $0.startDate >= date }) else {
            return effects.last?.quantity.doubleValue(for: unit) ?? 0
        }
        let next = effects[after]
        guard after > 0 else {
            return next.startDate == date ? next.quantity.doubleValue(for: unit) : 0
        }
        let previous = effects[after - 1]
        let span = next.startDate.timeIntervalSince(previous.startDate)
        let fraction = span > 0 ? date.timeIntervalSince(previous.startDate) / span : 1
        let a = previous.quantity.doubleValue(for: unit), b = next.quantity.doubleValue(for: unit)
        return a + (b - a) * fraction
    }

    func generateObservedAbsorptionEffects(absorptionRatio: Double, carbEffects: [GlucoseEffect]) -> [GlucoseEffect] {
        
        
        let observedAbsorptionEffect: [GlucoseEffect] = carbEffects.map { effect in
            let value = effect.quantity.doubleValue(for: carbUnit) * (absorptionRatio - 1.0) //removed IRC-OCA blend concept, because IRC doesn't accumumulate during carb absorption, so there is no double count.  Previous comment: this computes the amount that needs to be subtracted from the carb effect to create the adjusted carb effect.  IRC_OCA_blend handles the IRC OCA double count risk by keeping IRC in all the calcs, and deciding how much OCA to add.  When carbs aren't absorbing, that means it's basically just IRC, which is what you want to capture exercise and settings issues.  When carbs are absorbing, it punches it up a little without fully double counting.
            let newQuantity = HKQuantity(unit: carbUnit, doubleValue: value)
            return GlucoseEffect(startDate: effect.startDate, quantity: newQuantity)
        }
        
        return observedAbsorptionEffect
        
    }
    


   //TODO: stuff that might be useful for unit testing
        
        /* Internal for unit testing
        func manageMealNotifications(for status: MissedMealStatus, pendingAutobolusUnits: Double? = nil, bolusDurationEstimator getBolusDuration: (Double) -> TimeInterval?) {
            // We should remove expired notifications regardless of whether or not there was a meal
            NotificationManager.removeExpiredMealNotifications()
            
            // Figure out if we should deliver a notification
            let now = self.currentDate
            let notificationTimeTooRecent = now.timeIntervalSince(lastMissedMealNotification?.deliveryTime ?? .distantPast) < (MissedMealSettings.maxRecency - MissedMealSettings.minRecency)
            
            guard
                case .hasMissedMeal(let startTime, let carbAmount) = status,
                !notificationTimeTooRecent,
                UserDefaults.standard.missedMealNotificationsEnabled
            else {
                // No notification needed!
                return
            }
            
            var clampedCarbAmount = carbAmount
            if
                let maxBolus = maximumBolus,
                let currentCarbRatio = carbRatioScheduleApplyingOverrideHistory?.quantity(at: now).doubleValue(for: .gram())
            {
                let maxAllowedCarbAutofill = maxBolus * currentCarbRatio
                clampedCarbAmount = min(clampedCarbAmount, maxAllowedCarbAutofill)
            }
            
            log.debug("Delivering a missed meal notification")
            
            /// Coordinate the missed meal notification time with any pending autoboluses that `update` may have started
            /// so that the user doesn't have to cancel the current autobolus to bolus in response to the missed meal notification
            if
                let pendingAutobolusUnits,
                pendingAutobolusUnits > 0,
                let estimatedBolusDuration = getBolusDuration(pendingAutobolusUnits),
                estimatedBolusDuration < MissedMealSettings.maxNotificationDelay
            {
                NotificationManager.sendMissedMealNotification(mealStart: startTime, amountInGrams: clampedCarbAmount, delay: estimatedBolusDuration)
                lastMissedMealNotification = MissedMealNotification(deliveryTime: now.advanced(by: estimatedBolusDuration),
                                                                    carbAmount: clampedCarbAmount)
            } else {
                NotificationManager.sendMissedMealNotification(mealStart: startTime, amountInGrams: clampedCarbAmount)
                lastMissedMealNotification = MissedMealNotification(deliveryTime: now, carbAmount: clampedCarbAmount)
            }
        }
        */
        
    }


