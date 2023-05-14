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
    public static let dontNotifyIfSooner = TimeInterval(minutes: 5)
    
    /// don't notify if the low is coming later than this.  it's far away, things might change, and there is plenty of time for rescue carbs
    public static let dontNotifyIfLater = TimeInterval(minutes: 45)
    //we need to make an assumption about how fast burning the carbs are when estimating the needed rescue carbs
    
    public static let assumedRescueCarbAbsorptionTimeMinutes = 60.0
    
    public static let flooredTimeForRescueCarbs = 10.0
    
    public static let notificationInterval = TimeInterval(minutes: 1)

}
