//
//  LoopCoreConstants.swift
//  LoopCore
//
//  Created by Pete Schwamb on 10/16/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

public enum LoopCoreConstants {
    /// The amount of time since a given date that input data should be considered valid
    public static let inputDataRecencyInterval = TimeInterval(minutes: 15)
    
    /// The amount of time in the future a glucose value should be considered valid
    public static let futureGlucoseDataInterval = TimeInterval(minutes: 5)

    public static let defaultCarbAbsorptionTimes: CarbStore.DefaultAbsorptionTimes = (fast: .minutes(60), medium: .hours(3), slow: .hours(5))

    /// Carbs are assumed to absorb at least as fast as their grams over (entered absorption time ×
    /// this): Loop's minimum absorption rate. Passed to CarbStore as `absorptionTimeOverrun`.
    public static let minimumAbsorptionRateTimeMultiplier = 1.5

    /// Carbs are expected to absorb over (entered absorption time × this): the curve Loop's forecast,
    /// dosing and the predicted-low warning's expectation follow. 1.0 trusts the entry as entered.
    /// Never longer than the minimum-rate time (CarbStore caps it). Passed to CarbStore as
    /// `expectedAbsorptionTimeOverrun`.
    public static let absorptionTimeOverrun = 1.5

    /// How much historical glucose to include in a dosing decision
    /// Somewhat arbitrary, but typical maximum visible in bolus glucose preview
    public static let dosingDecisionHistoricalGlucoseInterval = TimeInterval(hours: 2)
    

}
