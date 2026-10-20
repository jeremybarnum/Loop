//
//  ObservedAbsorptionSettings.swift
//  Loop
//
//  Created by Jeremy Barnum on 5/12/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

public struct ObservedAbsorptionSettings {
    
    //TODO: decide whether to specify a level to treat to.
    
    //we need to make an assumption about how fast burning the carbs are when estimating the needed rescue carbs
    public static let assumedRescueCarbAbsorptionTimeMinutes = 45.0
    
    //when proposing rescue carbs, it only credits the amount that will get absorbed before the low hits.  But it gets exponential if the low is too soon, so this rescue carb multiplier effect needs to be limited
    public static let flooredTimeForRescueCarbs = 15.0
    
    //when adjusting future carb absorption, don't adjust very recent carb entries or entries in the future, since these may well be rescue carbs.  Some overlap between this setting and the warning delay
    public static let recentAndFutureCarbExclusionWindow = TimeInterval(minutes: 15)

    //the absorption ratio compares carbs that arrived over this many most recent minutes of counteraction readings with what Loop's carb forecast, made at the start of those minutes, expected for them
    public static let absorptionRatioWindow = TimeInterval(minutes: 15)

    //readings must cover at least this much of the window, or there is too little evidence to judge and the ratio is 1.0 (no adjustment)
    public static let absorptionRatioMinimumCoverage = TimeInterval(minutes: 10)

}

