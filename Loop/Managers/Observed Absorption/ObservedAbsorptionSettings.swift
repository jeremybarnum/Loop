//
//  ObservedAbsorptionSettings.swift
//  Loop
//
//  Created by Jeremy Barnum on 5/12/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation

public struct ObservedAbsorptionSettings {
    /// don't notify if the low is coming sooner than this.  it's obvious and will annoy the user.
    public static let dontNotifyIfSooner = TimeInterval(minutes: 10)
    
    /// don't notify if the low is coming later than this.  it's far away, things might change, and there is plenty of time for rescue carbs
    public static let dontNotifyIfLater = TimeInterval(minutes: 35)
    
    //we need to make an assumption about how fast burning the carbs are when estimating the needed rescue carbs
    public static let assumedRescueCarbAbsorptionTimeMinutes = 60.0
    
    //when proposing rescue carbs, it only credits the amount that will get absorbed before the low hits.  But it gets exponential if the low is too soon, so this rescue carb multiplier effect needs to be limited
    public static let flooredTimeForRescueCarbs = 30.0
    
    //to avoid repeating warnings, don't warn if the warning has happened more recently than this
    public static let notificationInterval = TimeInterval(minutes: 9)
    
    //when calculating the observedAbsorption ratio, use a recent observation window that is this number
    public static let observationWindow = TimeInterval(minutes: 30)
    
    //when adjusting future carb absorption, don't adjust very recent carb entries or entries in the future, since these may well be rescue carbs.  Some overlap between this setting and the warning delay
    public static let recentAndFutureCarbExclusionWindow = TimeInterval(minutes: 15)
    
    //don't warn if the carbs have been taken inside on this window, to avoid warnings in low confidence situations
    public static let warningDelay = TimeInterval(minutes: 40)
    
    //don't produce observed absorption efects until there are at least 3 observed carb effects
    public static let minCarbEffectCount = 3.0
    
    //toggle betweeen insulin-centric notification and carb centric notification.  If COB is Nil or very low, the assumption is it's all insulin driven, and if zero temping isn't enough, rescue carbs are defiitely needed.
    public static let minCOBforRescueCarbsDefinitelyNeeed = 3.0
    
    //user can decide how much OAE they want to add to IRC.  0% is like turning off warning, 100% is probably a lot of double count
    public static let IRC_OCA_blend = 0.65
    
    //user can decide how much OAE they want to add to IRC.  Below 25% is like turning off the warnings.
    public static let lowEndOfIRC_OCASlider = 0.25
    
    //user can decide how much OAE they want to add to IRC.  Above 75% is probably a lot of double counting and will lead to overwarning.
    public static let highEndOfIRC_OCASlider = 0.75
    
}
