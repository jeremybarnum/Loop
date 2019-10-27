//
//  CarbCorrection.swift
//  Loop
//
//  Created by Dragan Maksimovic on 2/10/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore

/**
    Carb correction algorithm calculates the amount of carbs (in grams) needed to treat a predicted low (blood glucose predicted to fall below suspend threshold level). The calculation is based on glucose forecast scenarios, which include the effect of suspension of insulin delivery by setting the temporary basal rate to zero. If it is found that zero temping is insufficient to prevent the low, the algorithm issues a Carb Correction Notification, which includes a suggested amount of carbs needed to treat the predicted low.
 Everything below down to line 459 is part of the Carb Correction Class, an object that I guess does all of the relevant work, i.e. calculate the predictions, determine whether a warnings is warranted, and issue the warnings
 */
class CarbCorrection {
    
    /**
     Carb correction algorithm parameters:
     - carbCorrectionThreshold: Do not issue notifications if grams required are below this value, only set the badge notification to the grams required
     - carbCorrectionSkipFraction: Suggested correction grams required calculated bring predicted glucose above suspend threshold after this fraction of assumed correciton carb absorption time equal to carbCorrectionAbsorptionTime
     - expireCarbsThreshold: observed insulin counteraction below below this fraction of modeled carb absorption triggers consideration of slow carb absorption scenario
     - notificationSnoozeTime: snooze notifications within this time interval, with an exception of badge notification
     */
    private let carbCorrectionThreshold: Int = 3
    private let carbCorrectionSkipFraction: Double = 0.33
    private let expireCarbsThresholdFraction: Double = 0.7
    private let notificationSnoozeTime: TimeInterval = .minutes(4)
    
    /// Math is performed with glucose expressed in mg/dL
    private let unit = HKUnit.milligramsPerDeciliter
    
    /*Effects must be set in LoopDataManager (Q: is there a cleaner way to do this?) JB Question: what is happening here? Are these variables not mostly already defined elsewhere?; if the things in brackets are data types or whatever and those are defined elsewhere,then why are those available and the variables not? Seems like maybe he stoppe this in the middle - when he was trying to figure out if he could implement this as a call to the function */
    public var insulinEffect: [GlucoseEffect]?
    public var carbEffect: [GlucoseEffect]?
    public var carbEffectFutureFood: [GlucoseEffect]?
    public var glucoseMomentumEffect: [GlucoseEffect]?
    public var zeroTempEffect: [GlucoseEffect]?
    public var retrospectiveGlucoseEffect: [GlucoseEffect]?
    public var insulinCounteractionEffects: [GlucoseEffectVelocity]?
    
    /// Suggested carb correction in grams
    private var suggestedCarbCorrection: Int?
    /// Current glucose
    private var glucose: GlucoseValue?
    
    /// Absorption time for correction carbs
    private let carbCorrectionAbsorptionTime: TimeInterval
    
    /// State variables for diagnostic report
    private var carbCorrection: Double = 0.0
    private var carbCorrectionExpiredCarbs: Double = 0.0
    private var carbCorrectionExcessInsulin: Double = 0.0
    private var carbCorrectionStatus: String = "-"
    private var timeToLow: TimeInterval = TimeInterval.minutes(0.0)
    private var timeToLowExpiredCarbs: TimeInterval = TimeInterval.minutes(0.0)
    private var timeToLowExcessInsulin: TimeInterval = TimeInterval.minutes(0.0)
    private var carbCorrectionNotification: CarbCorrectionNotification //so is this a data type, and if so, where is that defined?
    private var counteraction: Counteraction? //where are all these seemingly loop-specific types defined?
    private var modeledCarbEffectValue: Double?
    private var currentAbsorbingFraction: Double = 0.0
    private var averageAbsorbingFraction: Double = 0.0
    private var slowAbsorbingCheck: String = "No"
    private var excessInsulinAction: String = "No"
    private var usingRetrospection: String = "No"
    private var predictedGlucoseUnexpiredCarbs: [GlucoseValue] = []
    private var lastNotificationDate: Date
    private var timeSinceLastNotification: TimeInterval = TimeInterval.minutes(0.0)
    
    /**
     Initialize
     - Parameters:
     - carbCorrectionAbsorptionTime: Absorption time for correction carbs
     - Returns: Carb Correction customized with carb correction absorption time
     */
    init(_ carbCorrectionAbsorptionTime: TimeInterval) {
        self.carbCorrectionAbsorptionTime = carbCorrectionAbsorptionTime /*oh I think I get the self thing.  To the extent that a class takes parameters that need initialization, and that you might want to initialize them by setting them to be equal to variables with the same name, you use self. thing to specify which is the property of the class or object */
        self.carbCorrectionNotification.grams = 0
        self.carbCorrectionNotification.lowPredictedIn = .minutes(0.0)
        self.carbCorrectionNotification.gramsRemaining = 0
        self.carbCorrectionNotification.type = .noCorrection
        self.lastNotificationDate = Date().addingTimeInterval(-notificationSnoozeTime)
    }
    //I still don't understand exactly why you need initializers but this is setting some initial values for the absorption class
    /**
     Calculates suggested carb correction and issues notification if need be
     - Parameters:
     - glucose: Most recent glucose
     - Returns:
     - suggestedCarbCorrection: Suggested carb correction in grams, if needed
     */
    public func updateCarbCorrection(_ glucose: GlucoseValue) throws -> Int? { //why the underscore there? something about the parameter name not being necessary/being ignored

        self.glucose = glucose
        suggestedCarbCorrection = nil
        
        guard glucoseMomentumEffect != nil else {
            carbCorrectionStatus = "Error: momentum effects not available"
            throw LoopError.missingDataError(.momentumEffect)
        }
       
        guard carbEffect != nil else {
            carbCorrectionStatus = "Error: carb effects not available"
            throw LoopError.missingDataError(.carbEffect)
        }
        
        guard insulinEffect != nil else {
            carbCorrectionStatus = "Error: insulin effects not available"
            throw LoopError.missingDataError(.insulinEffect)
        }
        
        guard zeroTempEffect != nil else {
            carbCorrectionStatus = "Error: zero temp effects not available"
            throw LoopError.invalidData(details: "zeroTempEffect not available, updateCarbCorrection failed")
        }
        
        counteraction = recentInsulinCounteraction()
        guard let currentCounteraction = counteraction?.currentCounteraction, let averageCounteraction = counteraction?.averageCounteraction else {
            carbCorrectionStatus = "Error: calculation of insulin counteraction failed."
            return( suggestedCarbCorrection )
        }
        
        guard let modeledCarbEffect = modeledCarbAbsorption() else {
            carbCorrectionStatus = "Error: calculation of modeled carb absorption failed."
            return( suggestedCarbCorrection )
        }
        modeledCarbEffectValue = modeledCarbEffect
        
        carbCorrection = 0.0
        carbCorrectionExpiredCarbs = 0.0
        timeToLow = TimeInterval.minutes(0.0)
        timeToLowExpiredCarbs = TimeInterval.minutes(0.0)
        
        var useRetrospection: Bool = false
        usingRetrospection = "No"
        if let retroLast = retrospectiveGlucoseEffect?.last?.quantity.doubleValue(for: unit), let retroFirst = retrospectiveGlucoseEffect?.first?.quantity.doubleValue(for: unit) {
            if retroLast > retroFirst {
                useRetrospection = true
                usingRetrospection = "Yes"
            }
        } else {
            carbCorrectionStatus = "Error: retrospective glucose effects not available"
            throw LoopError.invalidData(details: "Could not compute carbs required, updateCarbCorrection failed")
        }
        
        var effects: PredictionInputEffect
        if useRetrospection {
            effects = [.carbs, .insulin, .momentum, .zeroTemp, .retrospection]
        } else {
            effects = [.carbs, .insulin, .momentum, .zeroTemp]
        }
        do {
            (carbCorrection, timeToLow) = try carbsRequired(effects)
        } catch {
            carbCorrectionStatus = "Error: glucose prediction failed with effects: \(effects)."
            throw LoopError.invalidData(details: "Could not compute carbs required, updateCarbCorrection failed")
        }
        
        slowAbsorbingCheck = "No"
        excessInsulinAction = "No"
        if modeledCarbEffect > 0.0 {
            currentAbsorbingFraction = currentCounteraction / modeledCarbEffect //here he is figuring out if absorption is less than half of the expected amount on a spot basis
            averageAbsorbingFraction = averageCounteraction / modeledCarbEffect//and here he is doing the same on an average basis
            if (currentAbsorbingFraction < 0.5 * expireCarbsThresholdFraction && averageAbsorbingFraction < expireCarbsThresholdFraction) {
                slowAbsorbingCheck = "Yes"
                if useRetrospection {
                    effects = [.unexpiredCarbs, .insulin, .momentum, .zeroTemp, .retrospection]
                } else {
                    effects = [.unexpiredCarbs, .insulin, .momentum, .zeroTemp]
                }
                do {
                    (carbCorrectionExpiredCarbs, timeToLowExpiredCarbs) = try carbsRequired(effects) //I don't get this
                } catch {
                    carbCorrectionStatus = "Error: glucose prediction failed with effects: \(effects)."
                    throw LoopError.invalidData(details: "Could not compute carbs required when past carbs expired, updateCarbCorrection failed")
                }
            }
        } else {
            currentAbsorbingFraction = 0.0
            averageAbsorbingFraction = 0.0
            if (averageCounteraction < 0.0  && currentCounteraction < averageCounteraction  && carbCorrection == 0) {
                excessInsulinAction = "Yes"
                usingRetrospection = "Yes"
                effects = [.carbs, .insulin, .momentum, .retrospection, .zeroTemp]
                do {
                    (carbCorrectionExcessInsulin, timeToLowExcessInsulin) = try carbsRequired(effects)
                } catch {
                    carbCorrectionStatus = "Error: glucose prediction failed with effects: \(effects)."
                    throw LoopError.invalidData(details: "Could not compute carbs required when excess insulin detected, updateCarbCorrection failed")
                }
                carbCorrection = carbCorrectionExcessInsulin // I don't understand why there is a different approach needed for slow absorbing versus excess insulin.  Seems insufficiently generic.
                timeToLow = timeToLowExcessInsulin
            }
        }
        
        carbCorrectionNotification.grams = Int(ceil(1.1 * carbCorrection))
        suggestedCarbCorrection = carbCorrectionNotification.grams
        carbCorrectionNotification.lowPredictedIn = timeToLow
        carbCorrectionNotification.gramsRemaining = Int(ceil(1.1 * carbCorrectionExpiredCarbs))
        carbCorrectionNotification.type = .noCorrection
        
        carbCorrectionStatus = "Successfully completed."
        
        // for diagnostic only
        effects = [.unexpiredCarbs]
        predictedGlucoseUnexpiredCarbs = try predictGlucose(using: effects)
        
        timeSinceLastNotification = -lastNotificationDate.timeIntervalSinceNow
        
        // no correction needed
        if ( carbCorrectionNotification.grams == 0 && carbCorrectionNotification.gramsRemaining < carbCorrectionThreshold) {
            NotificationManager.clearCarbCorrectionNotification()
            return( suggestedCarbCorrection )
        }
        
        // suggestedCarbCorrecction > 0, always send badge notification
        NotificationManager.sendCarbCorrectionNotificationBadge(carbCorrectionNotification.grams)
        
        // badge correction only
        if (carbCorrectionNotification.grams < carbCorrectionThreshold &&
            carbCorrectionNotification.gramsRemaining < carbCorrectionThreshold) {
            carbCorrectionNotification.type = .correction
            NotificationManager.clearCarbCorrectionNotification()
            return( suggestedCarbCorrection )
        }
        
        // carb correction notification, no warning
        if ( carbCorrectionNotification.grams >= carbCorrectionThreshold && carbCorrectionNotification.gramsRemaining < carbCorrectionThreshold) {
            carbCorrectionNotification.type = .correction
            if timeSinceLastNotification > notificationSnoozeTime {
                NotificationManager.sendCarbCorrectionNotification(carbCorrectionNotification)
                    lastNotificationDate = Date()
            }
            return( suggestedCarbCorrection )
        }
        
        // warning slow absorbing carbs
        if (carbCorrectionNotification.grams < carbCorrectionThreshold && carbCorrectionNotification.gramsRemaining >= carbCorrectionThreshold) {
            carbCorrectionNotification.type = .warning
            if timeSinceLastNotification > notificationSnoozeTime {
                NotificationManager.sendCarbCorrectionNotification(carbCorrectionNotification)
                lastNotificationDate = Date()
            }
            return( suggestedCarbCorrection )
        }

        // correction notification and warning
        if ( carbCorrectionNotification.grams >= carbCorrectionThreshold && carbCorrectionNotification.gramsRemaining >= carbCorrectionThreshold) {
            carbCorrectionNotification.type = .correctionPlusWarning
            if timeSinceLastNotification > notificationSnoozeTime {
                NotificationManager.sendCarbCorrectionNotification(carbCorrectionNotification)
                lastNotificationDate = Date()
            }
            return( suggestedCarbCorrection )
        }
        
        // we should never get to this point
        return( suggestedCarbCorrection )
    }
    
    /**
     Calculates suggested carb correction required given considered effects
     - Parameters:
     - effects: Effects contribution to glucose forecast
     - Returns:
     - (carbCorrection, timeToLow) tuple of grams required and time interval to predicted low
     - Throws: error if settings are not available
     */
    private func carbsRequired(_ effects: PredictionInputEffect) throws -> (Double, TimeInterval) {
        
        var carbCorrection: Double = 0.0
        var timeToLow: TimeInterval = TimeInterval.minutes(0.0)
        let carbRatioSchedule: CarbRatioSchedule? = UserDefaults.appGroup?.carbRatioSchedule
        let insulinSensitivitySchedule: InsulinSensitivitySchedule? = UserDefaults.appGroup?.insulinSensitivitySchedule
        let insulinModelSettings: InsulinModelSettings? = UserDefaults.appGroup?.insulinModelSettings
        let settings: LoopSettings = UserDefaults.appGroup?.loopSettings ?? LoopSettings()
        
        // Get settings, otherwise throw error
        guard
            let insulinActionDuration = insulinModelSettings?.model.effectDuration,
            let suspendThreshold = settings.suspendThreshold?.quantity.doubleValue(for: .milligramsPerDeciliter),
            let sensitivity = insulinSensitivitySchedule?.averageValue(),
            let carbRatio = carbRatioSchedule?.averageValue()
            else {
                self.suggestedCarbCorrection = nil
                throw LoopError.invalidData(details: "Settings not available, updateCarbCorrection failed")
        }
        
        // ignore dips below suspend threshold within the initial skip interval
        let carbCorrectionSkipInterval: TimeInterval = self.carbCorrectionSkipFraction * carbCorrectionAbsorptionTime
        
        let predictedGlucoseForCarbCorrection = try predictGlucose(using: effects)
        guard let currentDate = predictedGlucoseForCarbCorrection.first?.startDate else {
            throw LoopError.invalidData(details: "Glucose prediction failed, updateCarbCorrection failed")
        }
        
        let startDate = currentDate.addingTimeInterval(carbCorrectionSkipInterval)
        let endDate = currentDate.addingTimeInterval(insulinActionDuration)
        let predictedLowGlucose = predictedGlucoseForCarbCorrection.filter{ $0.startDate >= startDate && $0.startDate <= endDate && $0.quantity.doubleValue(for: .milligramsPerDeciliter) < suspendThreshold} //ok this is the key point - it checks if any parts of the future prediction are below the suspend threshold; I think this returns an array of times and values that are below the threshold - that must be what the filter does
        if predictedLowGlucose.count > 0 { // I think this is looping through the array and for each low value doing something -  sort of an area under the curve thing to figure out how many carbs
            for glucose in predictedLowGlucose {
                let glucoseTime = glucose.startDate.timeIntervalSince(currentDate) //so I think for each low BG, it's calculating the distance from now.  This dot syntax on these variables are confusing
                let anticipatedAbsorbedFraction = min(1.0, glucoseTime.minutes / carbCorrectionAbsorptionTime.minutes) //ok this is critical - he is making some statement about how quickly you want to come back up, I think.  But what is glucoseTime? oh right - he's saying - if I take the correction now, how much will have absorbed by that point. And he's saying - if all the carbs are absorbed before the first low, then fine, I can count all the carbs.  But if not, I need to assume only a fraction absorbs, which is equal to the earliest low.  But is there a problem? because if there is a lower low later,
                let requiredCorrection = (( suspendThreshold - glucose.quantity.doubleValue(for: .milligramsPerDeciliter)) / anticipatedAbsorbedFraction) * carbRatio / sensitivity
                if requiredCorrection > carbCorrection {
                    carbCorrection = requiredCorrection // ah ok he loops through all the potential corrections and if the next one is bigger, he sets it to that.  So it's basically the max of the array.  It's a recognition that a less severe low that comes sooner is harder to treat; but usually, if you get enough warning, you can count on full absorption, and so you just treat the lowest low
                }
            }
            if let lowGlucose = predictedGlucoseForCarbCorrection.first( where:
                {$0.quantity.doubleValue(for: .milligramsPerDeciliter) < suspendThreshold} ) {
                timeToLow = lowGlucose.startDate.timeIntervalSince(currentDate) // this is clear - computing the time to the first glucose below the suspend threshold
            }
        }

        return (carbCorrection, timeToLow)
    }

    /**
     Calculates suggested carb correction required given considered effects
     - Parameters:
     - effects: Effects contribution to glucose forecast
     - Returns:
     - prediction: Timeline of predicted glucose values
     - Throws: LoopError.missingDataError if glucose is missing or LoopError.configurationError(.insulinModel) if insulin model undefined
     
     is this the same prediction functions as usual? why is it fileprivate?
     */
    fileprivate func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue] {
        
        guard let model = UserDefaults.appGroup?.insulinModelSettings?.model else {
            throw LoopError.configurationError(.insulinModel)
        }
        
        guard let glucose = self.glucose else {
            throw LoopError.missingDataError(.glucose)
        }
        
        var momentum: [GlucoseEffect] = []
        var effects: [[GlucoseEffect]] = []
        
        if inputs.contains(.carbs), let carbEffect = self.carbEffect {
            effects.append(carbEffect)
        }
        
        if inputs.contains(.unexpiredCarbs), let futureCarbEffect = self.carbEffectFutureFood {
            effects.append(futureCarbEffect)
        }
        
        if inputs.contains(.insulin), let insulinEffect = self.insulinEffect {
            effects.append(insulinEffect)
        }
        
        if inputs.contains(.retrospection), let retrospectionEffect = self.retrospectiveGlucoseEffect {
            effects.append(retrospectionEffect)
        }
        
        if inputs.contains(.momentum), let momentumEffect = self.glucoseMomentumEffect {
            momentum = momentumEffect
        }
        
        if inputs.contains(.zeroTemp) {
            effects.append(self.zeroTempEffect!) //TO DO: why is this force unwrapped? seems bad
        }
        
        var prediction = LoopMath.predictGlucose(startingAt: glucose, momentum: momentum, effects: effects)// this is key, so the prediction is the sum of the effects, which are calculated in their own functions
        
        let finalDate = glucose.startDate.addingTimeInterval(model.effectDuration)
        if let last = prediction.last, last.startDate < finalDate {
            prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
        }
        
        return prediction
    }
    
    /**
     Calculates modeled carb absorption
     - Returns:
     - modeledCarbEffect: modeled carb effect expressed as impact on blood glucose in mg/dL over the next 5 minutes
     
        I think he needs this to estimate future impact of partially absorbing carbs 
     */
    fileprivate func modeledCarbAbsorption() -> Double? {
        let effects: PredictionInputEffect = [.carbs]
        var predictedGlucose: [GlucoseValue]?
        var modeledCarbEffect: Double?
        
        do {
            predictedGlucose = try predictGlucose(using: effects)
        }
        catch {
            return( modeledCarbEffect )
        }
        
        guard let modeledCarbOnlyGlucose = predictedGlucose else {
            return( modeledCarbEffect )
        }
        
        if modeledCarbOnlyGlucose.count < 2 {
            return( modeledCarbEffect )
        }
        
        if modeledCarbOnlyGlucose.count == 2 {
            let glucose1 = modeledCarbOnlyGlucose[0].quantity.doubleValue(for: unit)
            let glucose2 = modeledCarbOnlyGlucose[1].quantity.doubleValue(for: unit)
            modeledCarbEffect = glucose2 - glucose1
        } else {
            let glucose1 = modeledCarbOnlyGlucose[1].quantity.doubleValue(for: unit)
            let glucose2 = modeledCarbOnlyGlucose[2].quantity.doubleValue(for: unit)
            modeledCarbEffect = glucose2 - glucose1
        }
        return( modeledCarbEffect )
    }
  
    /**
     Calculates recent insulin counteraction
     - Returns:
     - counteraction: tuple of (currentCounteraction, averageCounteraction) representing current counteraction computed using linear regression over the past 20 min and evaluate at latest glucose time, and average counteraction computed over the past 20 min
     */
    fileprivate func recentInsulinCounteraction() -> Counteraction {
        
        //var counteraction: Counteraction it's complaining this this isn't initialized before use.  It's supposed to be a tuple of recent and average counteraction.  But it's not clear how to initialize. in the meantime I just made the error handling bad.
        
        guard let latestGlucoseDate = glucose?.startDate else {
            return(counteraction ?? (0,0)) //to do - this is some sort of error handling.  After fixing the chained optional in line 439 I replaced prior "return(counteraction)" with this thing.  I need to figure out what's actually going on and do it properly.  This is error handling anyway so not sure we need all these optionals.
        }
        
        guard let counterActions = insulinCounteractionEffects?.filterDateRange(latestGlucoseDate.addingTimeInterval(.minutes(-20)), latestGlucoseDate) else {
            return( counteraction ?? (0,0))
        }
        
        let counteractionValues = counterActions.map( { $0.effect.quantity.doubleValue(for: unit) } )
        let counteractionTimes = counterActions.map( { $0.effect.startDate.timeIntervalSince(latestGlucoseDate).minutes } )

        guard counteractionValues.count > 2 else {
            return( counteraction ?? (0,0) )
        }
        
        let insulinCounteractionFit = linearRegression(counteractionTimes, counteractionValues)
        counteraction?.currentCounteraction = insulinCounteractionFit(0.0) //in this line and the line below I fixed some optional chaining thing per xcode suggesting by adding the question mark after counteraction.
        counteraction?.averageCounteraction = average( counteractionValues )
        
        return( counteraction ?? (0,0) )
    }
    
    fileprivate func average(_ input: [Double]) -> Double {
        return input.reduce(0, +) / Double(input.count)
    }
    
    fileprivate func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        return zip(a,b).map(*)
    }
    
    fileprivate func linearRegression(_ xs: [Double], _ ys: [Double]) -> (Double) -> Double {
        let sum1 = average(multiply(ys, xs)) - average(xs) * average(ys)
        let sum2 = average(multiply(xs, xs)) - pow(average(xs), 2)
        let slope = sum1 / sum2
        let intercept = average(ys) - slope * average(xs)
        return { x in intercept + slope * x }
    }

}

struct CarbCorrectionNotificationOption: OptionSet {
    let rawValue: Int
    
    static let noCorrection = CarbCorrectionNotificationOption(rawValue: 1 << 0)
    static let correction = CarbCorrectionNotificationOption(rawValue: 1 << 1)
    static let warning = CarbCorrectionNotificationOption(rawValue: 1 << 2)

    static let correctionPlusWarning: CarbCorrectionNotificationOption = [.correction, .warning]
}

typealias CarbCorrectionNotification = (grams: Int, lowPredictedIn: TimeInterval, gramsRemaining: Int, type: CarbCorrectionNotificationOption)

typealias Counteraction = (currentCounteraction: Double?, averageCounteraction: Double?)

extension CarbCorrection {
    /// Generates a diagnostic report about the current state
    ///
    /// - parameter completion: A closure called once the report has been generated. The closure takes a single argument of the report string.
    func generateDiagnosticReport(_ completion: @escaping (_ report: String) -> Void) {
        var report: [String] = [
            "## Carb Correction Notification",
            "",
            "Status: \(carbCorrectionStatus)",
            "Current glucose [mg/dL]: \(String(describing: glucose?.quantity.doubleValue(for: unit)))",
            "Current glucose date: \(String(describing: glucose?.startDate))",
            "timeSinceLastNotification [min]: \(timeSinceLastNotification.minutes)",
            "Suggested carb correction [g]: \(String(describing: carbCorrectionNotification.grams))",
            "Low predicted in [min]: \(String(describing: carbCorrectionNotification.lowPredictedIn.minutes))",
            "Slow absorbing carbs remaining [g]: \(String(describing: carbCorrectionNotification.gramsRemaining))",
            "Carb correction type: \(String(describing: carbCorrectionNotification.type))",
            "Recent insulin counteraction [mg/dL/5min]: \(String(describing: counteraction))",
            "Modeled carb effect [mg/dL/5min]: \(String(describing: modeledCarbEffectValue))",
            "currentAbsorbingFraction: \(currentAbsorbingFraction)",
            "averageAbsorbingFraction: \(averageAbsorbingFraction)",
            "Check slow carb absorption: \(slowAbsorbingCheck)",
            "carbCorrectionExpiredCarbs [g]: \(carbCorrectionExpiredCarbs)",
            "timeToLowExpiredCarbs [min]: \(timeToLowExpiredCarbs.minutes)",
            "Check excess insulin action: \(excessInsulinAction)",
            "carbCorrectionExcessInsulin [g]: \(carbCorrectionExcessInsulin)",
            "timeToLowExcessInsulin [min]: \(timeToLowExcessInsulin.minutes)",
            "Using retrospection: \(usingRetrospection)",
            "carbCorrectionThreshold [g]: \(carbCorrectionThreshold)",
            "expireCarbsThresholdFraction: \(expireCarbsThresholdFraction)",
            "carbCorrectionSkipFraction: \(carbCorrectionSkipFraction)",
            "carbCorrectionAbsorptionTime [min]: \(carbCorrectionAbsorptionTime.minutes)",
            "notificationSnoozeTime [min]: \(notificationSnoozeTime.minutes)",
            "----------------------------",
            "Predicted glucose from unexpired carbs: \(String(describing: predictedGlucoseUnexpiredCarbs))"
        ]
        report.append("")
        completion(report.joined(separator: "\n"))
    }
    
}
