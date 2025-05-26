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

    func computeObservedAbsorptionRatio(insulinCounteractionEffects: [GlucoseEffectVelocity], expectedCarbEffects: [GlucoseEffect], contributingCarbEntries: [StoredCarbEntry]? = nil)-> Double {
//computes recent empirical ratio of observed to modeled absorption and generates an effect for the adjustment
        let intervalStart = currentDate(timeIntervalSinceNow: -TimeInterval(minutes: 20)) //only consider last 20 minutes
        let now = self.currentDate
        let delta = 5.0 //the standard loop 5 minute interval TODO: when testing, does using the other interval mess things up
        
        /// Effect caching inspired by `LoopMath.predictGlucose`
       
     
        var carbEffectValueCache = 0.0
        var ICEValueCache = 0.0
        var carbEffectCount = 0.0
        var ICECount = 0.0
        var absorptionRatio = 1.0
        
        
        let recentCarbEffects = expectedCarbEffects.filterDateRange(intervalStart, now)

        /// Carb effects are cumulative, so we have to subtract the previous effect value
        var previousEffectValue: Double = recentCarbEffects.first?.quantity.doubleValue(for: carbUnit) ?? 0//TODO: figure this out I'm worried this zero could create weird carb effects.  I think it's ok because it's only zero when there are no carb effects in which case it's fine.
        
        for effect in recentCarbEffects.dropFirst() {
            let value = effect.quantity.doubleValue(for: carbUnit)
            let difference = value - previousEffectValue
            //print("*test carbEffect added to cache")
            carbEffectValueCache += difference
            previousEffectValue = value
            if difference != 0 {carbEffectCount += 1}
        }
        //carbEffectCount = Double(recentCarbEffects.dropFirst().filter { $0.quantity.doubleValue(for: carbUnit) != 0.0 }.count) //TODO:it would be better to count differences.  There is the weird case where the array is populate to the same non-zero value.  It's a corner case, but.
//TODO: check how the effect delay works.  For a new entry, this should mean we don't start for 25-30 minutes  This is true.
        //TODO: very important.  Overalapping carb entries create problems.  More recent carb entries should potentially be privileged
        //TODO: why does carb effect average go to zero, creating infinite absorption ratio, at the third effect count.  I can't reproduce this problem.  It might be limited to the corner case of carb effect populated with constant nonzero value
        
        let averageCarbEffect = carbEffectValueCache / carbEffectCount / delta //I want it to match the units on the graph, so I'm using mg/dL/minute
        //print("*Test FutureCarbEffects:",futureCarbEffects)
        
        predictionLogger.info("carbEffectValueCache: %.1f, carbEffectCount: %.1f, CarbEffectAverage in mg/dl/minute, so divided by 5: %.1f",carbEffectValueCache, carbEffectCount, averageCarbEffect)

        let filteredICE = insulinCounteractionEffects
            .filterDateRange(intervalStart, now).dropFirst()

        for effect in filteredICE {
            let value = effect.quantity.doubleValue(for: ICEUnit)
            ICEValueCache += value
        }
        
        ICECount = Double(filteredICE.count)
        let averageICE = ICEValueCache / ICECount
        predictionLogger.info("ICESum: %.1f, ICE Count: %.1f, ICE Average in mg/dl/minute, so divided by 5: %.3f", ICEValueCache * 5, ICECount, averageICE)
        //TODO: make sure the logging isn't confusing with the averages and the column headers
        
        if carbEffectCount < ObservedAbsorptionSettings.minCarbEffectCount {absorptionRatio = 1} else {absorptionRatio = max(averageICE / averageCarbEffect, 0)} // if the carb entry is new and there is less than 3 loops of recent data, don't adjust the carb effect.  It's clunky to do this by setting the absorptionRatio to 1, but it works and is simple.  Also floor the absorption ratio at 0 so that if ICE is negative, it's not double counting too much.  This could be debated.  Also TODO: what is the overlap between this and carb entry aging.  If absorption doesn't start for 10 minutes, and we are waiting till the third entry to calculate absorptionRatio, then that's 25 minutes anyway.  Perhaps this is an overlapping entries issue.  Also need to test is observed absorption always based on 3 readings or more than that?  Also TODO: need to decide whether I care about the theoretical possibility that a 20 minute lookback could capture 4 observations.  I think I do.  Also, I don't like the hard coding of the 20 minutes.  And it's redundant with the lookback window.
        
        predictionLogger.info("Absorption Ratio: %.1f", absorptionRatio )


        
        return absorptionRatio
    }
    
    func generateObservedAbsorptionEffects(absorptionRatio: Double, carbEffects: [GlucoseEffect]) -> [GlucoseEffect] {
        
        
        let observedAbsorptionEffect: [GlucoseEffect] = carbEffects.map { effect in
            let value = effect.quantity.doubleValue(for: carbUnit) * (absorptionRatio - 1.0) //removed IRC-OCA blend concept, because IRC doesn't accumumulate during carb absorption, so there is no double count.  Previous comment: this computes the amount that needs to be subtracted from the carb effect to create the adjusted carb effect.  IRC_OCA_blend handles the IRC OCA double count risk by keeping IRC in all the calcs, and deciding how much OCA to add.  When carbs aren't absorbing, that means it's basically just IRC, which is what you want to capture exercise and settings issues.  When carbs are absorbing, it punches it up a little without fully double counting.
            let newQuantity = HKQuantity(unit: carbUnit, doubleValue: value)
            return GlucoseEffect(startDate: effect.startDate, quantity: newQuantity)
        }
        
        //print("*Test Observed Absorption Effect:", observedAbsorptionEffect)
        
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


