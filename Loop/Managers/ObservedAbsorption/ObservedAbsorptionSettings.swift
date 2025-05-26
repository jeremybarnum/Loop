//
//  ObservedAbsorptionSettings.swift
//  Loop
//
//  Created by Jeremy Barnum on 5/12/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation

public struct ObservedAbsorptionSettings {
    //level that is considered a low for purposes of warning TODO: figure out HKUnit
    public static let bloodGlucoseLevelConsideredLowForWarnings = 45.0
    
    /// don't notify if the low is coming sooner than this.  it's obvious and will annoy the user.
    public static let dontNotifyIfSooner = TimeInterval(minutes: 5)
    
    /// don't notify if the low is coming later than this.  it's far away, things might change, and there is plenty of time for rescue carbs
    public static let dontNotifyIfLater = TimeInterval(minutes: 90)
    
    //we need to make an assumption about how fast burning the carbs are when estimating the needed rescue carbs
    public static let assumedRescueCarbAbsorptionTimeMinutes = 45.0
    
    //when proposing rescue carbs, it only credits the amount that will get absorbed before the low hits.  But it gets exponential if the low is too soon, so this rescue carb multiplier effect needs to be limited
    public static let flooredTimeForRescueCarbs = 15.0
    
    //to avoid repeating warnings, don't warn if the warning has happened more recently than this
    public static let notificationInterval = TimeInterval(minutes: 1)
    
    //when adjusting future carb absorption, don't adjust very recent carb entries or entries in the future, since these may well be rescue carbs.  Some overlap between this setting and the warning delay
    public static let recentAndFutureCarbExclusionWindow = TimeInterval(minutes: 15)
    
    //don't warn if the carbs have been taken inside on this window, to avoid warnings in low confidence situations
    public static let warningDelay = TimeInterval(minutes: 30)

}

