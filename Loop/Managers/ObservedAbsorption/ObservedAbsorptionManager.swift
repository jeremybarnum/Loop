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
    
    // MARK: SlowAbsorption Detection
    
    func computeObservedAbsorptionRatio(insulinCounteractionEffects: [GlucoseEffectVelocity], expectedCarbEffects: [GlucoseEffect]) -> Double {
        
        let now = self.currentDate
        
        // Step 1: Find 3 consecutive non-zero carb velocities going backwards from now
        let recentModeledCarbEffects = expectedCarbEffects.filter { $0.startDate <= now }
            .sorted { $0.startDate < $1.startDate }
        
        guard recentModeledCarbEffects.count >= 4 else {
            predictionLogger.info("Insufficient carb effects for absorption ratio calculation")
            return 1.0
        }
        
        var carbVelocities: [(timestamp: Date, velocity: Double)] = []
        
        // Start from the most recent and work backwards
        for i in stride(from: recentModeledCarbEffects.count - 1, through: 1, by: -1) {
            let currentEffect = recentModeledCarbEffects[i].quantity.doubleValue(for: carbUnit)
            let previousEffect = recentModeledCarbEffects[i - 1].quantity.doubleValue(for: carbUnit)
            let velocity = (currentEffect - previousEffect) / 5.0 // Convert to mg/dL/minute
            
            if velocity == 0 {
                // Hit a zero velocity, stop here and use what we have
                break
            }
            
            carbVelocities.append((timestamp: recentModeledCarbEffects[i].startDate, velocity: velocity))
            
            if carbVelocities.count == 3 {
                break // Found our 3 consecutive non-zero velocities
            }
        }
        
        guard carbVelocities.count == 3 else {
            predictionLogger.info("Could not find 3 consecutive non-zero carb velocities, found: %d", carbVelocities.count)
            return 1.0
        }
        
        // carbVelocities is now [newest, middle, oldest] - reverse for chronological order
        carbVelocities.reverse()
        let averageCarbVelocity = carbVelocities.map { $0.velocity }.reduce(0, +) / 3.0
        
        // Step 2: Find matching ICE values
        let newestCarbTimestamp = carbVelocities.last!.timestamp // Most recent carb velocity timestamp
        let sortedICE = insulinCounteractionEffects.sorted { $0.startDate < $1.startDate }
        
        guard sortedICE.count >= 3 else {
            predictionLogger.info("Insufficient ICE data for absorption ratio calculation")
            return 1.0
        }
        
        // Find ICE value closest to newest carb velocity timestamp
        var closestIndex = 0
        var minTimeDifference = abs(sortedICE[0].startDate.timeIntervalSince(newestCarbTimestamp))
        
        for i in 1..<sortedICE.count {
            let timeDifference = abs(sortedICE[i].startDate.timeIntervalSince(newestCarbTimestamp))
            if timeDifference < minTimeDifference {
                minTimeDifference = timeDifference
                closestIndex = i
            }
        }
        
        // Ensure we can get 3 ICE values ending at closestIndex
        guard closestIndex >= 2 else {
            predictionLogger.info("Not enough ICE data before closest match for 3-value average")
            return 1.0
        }
        
        let iceValues = [
            sortedICE[closestIndex - 2].quantity.doubleValue(for: ICEUnit),
            sortedICE[closestIndex - 1].quantity.doubleValue(for: ICEUnit),
            sortedICE[closestIndex].quantity.doubleValue(for: ICEUnit)
        ]
        let averageICE = iceValues.reduce(0, +) / 3.0
        
        // Step 3: Calculate ratio
        guard averageCarbVelocity > 0 else {
            predictionLogger.info("Average carb velocity is zero or negative")
            return 1.0
        }
        
        let absorptionRatio = max(averageICE / averageCarbVelocity, 0.0)
        
        predictionLogger.info("Carb velocities: [%.3f, %.3f, %.3f], avg: %.3f mg/dL/min",
                             carbVelocities[0].velocity, carbVelocities[1].velocity, carbVelocities[2].velocity, averageCarbVelocity)
        predictionLogger.info("ICE values: [%.3f, %.3f, %.3f], avg: %.3f mg/dL/min",
                             iceValues[0], iceValues[1], iceValues[2], averageICE)
        predictionLogger.info("Absorption Ratio: %.3f", absorptionRatio)
        
        return absorptionRatio
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


