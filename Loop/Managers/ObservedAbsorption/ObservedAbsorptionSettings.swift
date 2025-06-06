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
    
    //we need to make an assumption about how fast burning the carbs are when estimating the needed rescue carbs
    public static let assumedRescueCarbAbsorptionTimeMinutes = 45.0
    
    //when proposing rescue carbs, it only credits the amount that will get absorbed before the low hits.  But it gets exponential if the low is too soon, so this rescue carb multiplier effect needs to be limited
    public static let flooredTimeForRescueCarbs = 15.0
    
    //when adjusting future carb absorption, don't adjust very recent carb entries or entries in the future, since these may well be rescue carbs.  Some overlap between this setting and the warning delay
    public static let recentAndFutureCarbExclusionWindow = TimeInterval(minutes: 15)

}


