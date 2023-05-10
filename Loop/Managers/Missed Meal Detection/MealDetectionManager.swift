//
//  MealDetectionManager.swift
//  Loop
//
//  Created by Anna Quinlan on 11/28/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import OSLog
import LoopCore
import LoopKit

enum MissedMealStatus: Equatable {
    case hasMissedMeal(startTime: Date, carbAmount: Double)
    case noMissedMeal
}

class MealDetectionManager {
    private let log = OSLog(category: "MealDetectionManager")
    
    public var carbRatioScheduleApplyingOverrideHistory: CarbRatioSchedule?
    public var insulinSensitivityScheduleApplyingOverrideHistory: InsulinSensitivitySchedule?
    public var maximumBolus: Double?
    
    /// The last missed meal notification that was sent
    /// Internal for unit testing
    var lastMissedMealNotification: MissedMealNotification? = UserDefaults.standard.lastMissedMealNotification {
        didSet {
            UserDefaults.standard.lastMissedMealNotification = lastMissedMealNotification
        }
    }
    
    /// Debug info for missed meal detection
    /// Timeline from the most recent check for missed meals
    private var lastEvaluatedMissedMealTimeline: [(date: Date, unexpectedDeviation: Double?, mealThreshold: Double?, rateOfChangeThreshold: Double?)] = []
    
    /// Timeline from the most recent detection of an missed meal
    private var lastDetectedMissedMealTimeline: [(date: Date, unexpectedDeviation: Double?, mealThreshold: Double?, rateOfChangeThreshold: Double?)] = []
    
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
        carbRatioScheduleApplyingOverrideHistory: CarbRatioSchedule?,
        insulinSensitivityScheduleApplyingOverrideHistory: InsulinSensitivitySchedule?,
        maximumBolus: Double?,
        test_currentDate: Date? = nil
    ) {
        self.carbRatioScheduleApplyingOverrideHistory = carbRatioScheduleApplyingOverrideHistory
        self.insulinSensitivityScheduleApplyingOverrideHistory = insulinSensitivityScheduleApplyingOverrideHistory
        self.maximumBolus = maximumBolus
        self.test_currentDate = test_currentDate
    }
    
    // MARK: SlowAbsorption Detection

 /*   func observedAbsorption(insulinCounteractionEffects: [GlucoseEffectVelocity], carbEffects: [GlucoseEffect])->[GlucoseEffect] {
//computes recent empirical ratio of observed to modeled absorption and generates an effect for the adjustment
        let intervalStart = currentDate(timeIntervalSinceNow: -TimeInterval(minutes: 20)) //only consider last 20 minutes
        let now = self.currentDate
        let delta = 5.0 //the standard loop 5 minute interval
        
        /// Effect caching inspired by `LoopMath.predictGlucose`
       
        let carbUnit = HKUnit.milligramsPerDeciliter
        let ICEUnit = HKUnit.milligramsPerDeciliterPerMinute
        var carbEffectValueCache = 0.0
        var ICEValueCache = 0.0
        var carbEffectCount = 0.0
        var ICECount = 0.0
        var absorptionRatio = 0.0
        
        
        let recentCarbEffects = carbEffects.filterDateRange(intervalStart, now)
        print("Carb Effects unfiltered:",carbEffects)
        print("now:",now)
        print("2 hour interval:",currentDate(timeIntervalSinceNow: TimeInterval(hours: 2)))
        
        let futureCarbEffects = carbEffects.filterDateRange(now, currentDate(timeIntervalSinceNow: TimeInterval(hours: 2)))
        
        /// Carb effects are cumulative, so we have to subtract the previous effect value
        var previousEffectValue: Double = recentCarbEffects.first?.quantity.doubleValue(for: carbUnit) ?? 0//I'm worried this zero could create weird carb effects
        
        for effect in recentCarbEffects.dropFirst() {
            let value = effect.quantity.doubleValue(for: carbUnit)
            let difference = value - previousEffectValue
            carbEffectValueCache += difference
            previousEffectValue = value
        }
        carbEffectCount = Double(recentCarbEffects.dropFirst().count)
        
        let averageCarbEffect = carbEffectValueCache / carbEffectCount / delta //I want it to match the units on the graph, so I'm using mg/dL/minute
        print("*Test FutureCarbEffects:",futureCarbEffects)
        
        print("*Test CarbEffect Sum:",carbEffectValueCache,"CarbEffectCount:",carbEffectCount,"CarbEffectAverage:",averageCarbEffect)

        let filteredICE = insulinCounteractionEffects
            .filterDateRange(intervalStart, now).dropFirst()

        for effect in filteredICE {
            let value = effect.quantity.doubleValue(for: ICEUnit)
            ICEValueCache += value
        }
        
        ICECount = Double(filteredICE.count)
        let averageICE = ICEValueCache / ICECount
        print("*Test ICESUm:",ICEValueCache,"ICE Count:",ICECount,"ICE Average:",averageICE)
        
        absorptionRatio = averageICE / averageCarbEffect
        
        print("*Test Absorption Ratio:", absorptionRatio)
        

        let observedAbsorptionEffect: [GlucoseEffect] = futureCarbEffects.map { effect in
            let value = effect.quantity.doubleValue(for: carbUnit) * (absorptionRatio - 1.0)
            let newQuantity = HKQuantity(unit: carbUnit, doubleValue: value)
            return GlucoseEffect(startDate: effect.startDate, quantity: newQuantity)
        }
        
        print("*Test Observed Absorption Effect:", observedAbsorptionEffect)
        
        return observedAbsorptionEffect
        
    }
    
    */
    // MARK: Meal Detection
    func hasMissedMeal(insulinCounteractionEffects: [GlucoseEffectVelocity], carbEffects: [GlucoseEffect], completion: @escaping (MissedMealStatus) -> Void) {
        let delta = TimeInterval(minutes: 5)

        let intervalStart = currentDate(timeIntervalSinceNow: -MissedMealSettings.maxRecency)
        let intervalEnd = currentDate(timeIntervalSinceNow: -MissedMealSettings.minRecency)
        let now = self.currentDate

        let filteredCarbEffects = carbEffects.filterDateRange(intervalStart, now)
            
        /// Compute how much of the ICE effect we can't explain via our entered carbs
        /// Effect caching inspired by `LoopMath.predictGlucose`
        var effectValueCache: [Date: Double] = [:]
        let unit = HKUnit.milligramsPerDeciliter

        /// Carb effects are cumulative, so we have to subtract the previous effect value
        var previousEffectValue: Double = filteredCarbEffects.first?.quantity.doubleValue(for: unit) ?? 0

        /// Counteraction effects only take insulin into account, so we need to account for the carb effects when computing the unexpected deviations
        for effect in filteredCarbEffects {
            let value = effect.quantity.doubleValue(for: unit)
            /// We do `-1 * (value - previousEffectValue)` because this will compute the carb _counteraction_ effect
            effectValueCache[effect.startDate] = (effectValueCache[effect.startDate] ?? 0) +  -1 * (value - previousEffectValue)
            previousEffectValue = value
        }

        let processedICE = insulinCounteractionEffects
            .filterDateRange(intervalStart, now)
            .compactMap {
                /// Clamp starts & ends to `intervalStart...now` since our algorithm assumes all effects occur within that interval
                let start = max($0.startDate, intervalStart)
                let end = min($0.endDate, now)

                guard let effect = $0.effect(from: start, to: end) else {
                    let item: GlucoseEffect? = nil // FIXME: we get a compiler error if we try to return `nil` directly
                    return item
                }

                return GlucoseEffect(startDate: effect.endDate.dateCeiledToTimeInterval(delta),
                                     quantity: effect.quantity)
            }
        
        for effect in processedICE {
            let value = effect.quantity.doubleValue(for: unit)
            effectValueCache[effect.startDate] = (effectValueCache[effect.startDate] ?? 0) + value
        }
        
        var unexpectedDeviation: Double = 0
        var mealTime = now
        
        /// Dates the algorithm uses when computing effects
        /// Have the range go from newest -> oldest time
        let summationRange = LoopMath.simulationDateRange(from: intervalStart,
                                                to: now,
                                                delta: delta)
                                      .reversed()
        
        /// Dates the algorithm is allowed to check for the presence of a missed meal
        let dateSearchRange = Set(LoopMath.simulationDateRange(from: intervalStart,
                                                     to: intervalEnd,
                                                     delta: delta))
        
        /// Timeline used for debug purposes
        var missedMealTimeline: [(date: Date, unexpectedDeviation: Double?, mealThreshold: Double?, rateOfChangeThreshold: Double?)] = []
        
        for pastTime in summationRange {
            guard let unexpectedEffect = effectValueCache[pastTime] else {
                missedMealTimeline.append((pastTime, nil, nil, nil))
                continue
            }
            
            unexpectedDeviation += unexpectedEffect

            guard dateSearchRange.contains(pastTime) else {
                /// This time is too recent to check for a missed meal
                missedMealTimeline.append((pastTime, unexpectedDeviation, nil, nil))
                continue
            }
            
            /// Find the threshold based on a minimum of `missedMealGlucoseRiseThreshold` of change per minute
            let minutesAgo = now.timeIntervalSince(pastTime).minutes
            let rateThreshold = MissedMealSettings.glucoseRiseThreshold * minutesAgo
            
            /// Find the total effect we'd expect to see for a meal with `carbThreshold`-worth of carbs that started at `pastTime`
            guard let mealThreshold = self.effectThreshold(mealStart: pastTime, carbsInGrams: MissedMealSettings.minCarbThreshold) else {
                continue
            }
            
            missedMealTimeline.append((pastTime, unexpectedDeviation, mealThreshold, rateThreshold))
            
            /// Use the higher of the 2 thresholds to ensure noisy CGM data doesn't cause false-positives for more recent times
            let effectThreshold = max(rateThreshold, mealThreshold)

            if unexpectedDeviation >= effectThreshold {
                mealTime = pastTime
            }
        }
        
        self.lastEvaluatedMissedMealTimeline = missedMealTimeline.reversed()
        
        let mealTimeTooRecent = now.timeIntervalSince(mealTime) < MissedMealSettings.minRecency
        guard !mealTimeTooRecent else {
            completion(.noMissedMeal)
            return
        }

        self.lastDetectedMissedMealTimeline = missedMealTimeline.reversed()
        
        let carbAmount = self.determineCarbs(mealtime: mealTime, unexpectedDeviation: unexpectedDeviation)
        completion(.hasMissedMeal(startTime: mealTime, carbAmount: carbAmount ?? MissedMealSettings.minCarbThreshold))
    }
    
    private func determineCarbs(mealtime: Date, unexpectedDeviation: Double) -> Double? {
        var mealCarbs: Double? = nil
        
        /// Search `carbAmount`s from `minCarbThreshold` to `maxCarbThreshold` in 5-gram increments,
        /// seeing if the deviation is at least `carbAmount` of carbs
        for carbAmount in stride(from: MissedMealSettings.minCarbThreshold, through: MissedMealSettings.maxCarbThreshold, by: 5) {
            if
                let modeledCarbEffect = effectThreshold(mealStart: mealtime, carbsInGrams: carbAmount),
                unexpectedDeviation >= modeledCarbEffect
            {
                mealCarbs = carbAmount
            }
        }
        
        return mealCarbs
    }
    
    private func effectThreshold(mealStart: Date, carbsInGrams: Double) -> Double? {
        guard
            let carbRatio = carbRatioScheduleApplyingOverrideHistory?.value(at: mealStart),
            let insulinSensitivity = insulinSensitivityScheduleApplyingOverrideHistory?.value(at: mealStart)
        else {
            return nil
        }
        
        return carbsInGrams / carbRatio * insulinSensitivity
    }
    
    // MARK: Notification Generation
    /// Searches for any potential missed meals and sends a notification.
    /// A missed meal notification can be delivered a maximum of every  `MissedMealSettings.maxRecency - MissedMealSettings.minRecency` minutes.
    ///
    /// - Parameters:
    ///    - insulinCounteractionEffects: the current insulin counteraction effects that have been observed
    ///    - carbEffects: the effects of any active carb entries. Must include effects from `currentDate() - MissedMealSettings.maxRecency` until `currentDate()`.
    ///    - pendingAutobolusUnits: any autobolus units that are still being delivered. Used to delay the missed meal notification to avoid notifying during an autobolus.
    ///    - bolusDurationEstimator: estimator of bolus duration that takes the units of the bolus as an input. Used to delay the missed meal notification to avoid notifying during an autobolus.
    func generateMissedMealNotificationIfNeeded(
        insulinCounteractionEffects: [GlucoseEffectVelocity],
        carbEffects: [GlucoseEffect],
        pendingAutobolusUnits: Double? = nil,
        bolusDurationEstimator: @escaping (Double) -> TimeInterval?
    ) {
        hasMissedMeal(insulinCounteractionEffects: insulinCounteractionEffects, carbEffects: carbEffects) {[weak self] status in
            self?.manageMealNotifications(for: status, pendingAutobolusUnits: pendingAutobolusUnits, bolusDurationEstimator: bolusDurationEstimator)
        }
    }
    
    
    // Internal for unit testing
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
    
    // MARK: Logging
    
    /// Generates a diagnostic report about the current state
    ///
    /// - parameter completionHandler: A closure called once the report has been generated. The closure takes a single argument of the report string.
    func generateDiagnosticReport(_ completionHandler: @escaping (_ report: String) -> Void) {
        let report = [
            "## MealDetectionManager",
            "",
            "* lastMissedMealNotificationTime: \(String(describing: lastMissedMealNotification?.deliveryTime))",
            "* lastMissedMealCarbEstimate: \(String(describing: lastMissedMealNotification?.carbAmount))",
            "* lastEvaluatedMissedMealTimeline:",
            lastEvaluatedMissedMealTimeline.reduce(into: "", { (entries, entry) in
                entries.append("  * date: \(entry.date), unexpectedDeviation: \(entry.unexpectedDeviation ?? -1), meal-based threshold: \(entry.mealThreshold ?? -1), change-based threshold: \(entry.rateOfChangeThreshold ?? -1) \n")
            }),
            "* lastDetectedMissedMealTimeline:",
            lastDetectedMissedMealTimeline.reduce(into: "", { (entries, entry) in
                entries.append("  * date: \(entry.date), unexpectedDeviation: \(entry.unexpectedDeviation ?? -1), meal-based threshold: \(entry.mealThreshold ?? -1), change-based threshold: \(entry.rateOfChangeThreshold ?? -1) \n")
            })
        ]
        
        completionHandler(report.joined(separator: "\n"))
    }
}
