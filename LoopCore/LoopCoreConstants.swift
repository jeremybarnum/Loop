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

    /// Carbs are expected to absorb over (entered absorption time × this): the curve Loop's forecast
    /// and dosing follow. 1.0 trusts the entry as entered (ruled for the production line, 2026-10-21;
    /// stock Loop uses 1.5). Never longer than the minimum-rate time (CarbStore caps it). Passed to
    /// CarbStore as `expectedAbsorptionTimeOverrun`.
    public static let absorptionTimeOverrun = 1.0

    /// How much historical glucose to include in a dosing decision
    /// Somewhat arbitrary, but typical maximum visible in bolus glucose preview
    public static let dosingDecisionHistoricalGlucoseInterval = TimeInterval(hours: 2)
    

}

// MARK: - A time scale for Simulator testing

public extension LoopCoreConstants {
    /// Simulator testing only, behind a build flag: SPORTMODE_TIME_SCALE=N in the app's environment
    /// divides the waits that follow the sensor's 5-minute cadence by N, so a test harness whose
    /// simulated sensor reads every 300/N s runs N times faster. 1 everywhere else: on a device,
    /// without the flag, and under XCTest.
    static let simulatedTimeScale: Double = {
        #if SIMULATED_TIME_SCALE_ENABLED && targetEnvironment(simulator)
        if NSClassFromString("XCTestCase") == nil,
           let text = ProcessInfo.processInfo.environment["SPORTMODE_TIME_SCALE"],
           let scale = Double(text), scale >= 1 {
            return scale
        }
        #endif
        return 1
    }()

    /// An interval divided by the Simulator time scale (unchanged outside Simulator testing).
    static func scaled(_ interval: TimeInterval) -> TimeInterval { interval / simulatedTimeScale }
}
