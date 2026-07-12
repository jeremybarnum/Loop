//
//  Date.swift
//  WatchApp Extension
//
//  Created by Bharat Mediratta on 6/26/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation


extension Date {
    static var earliestGlucoseCutoff: Date {
        // 10h: the prediction algorithm's ICE window (dynamic carb absorption
        // observes glucose against insulin effects across the carb history).
        return Date(timeIntervalSinceNow: .hours(-10))
    }

    static var staleGlucoseCutoff: Date {
        return Date(timeIntervalSinceNow: .minutes(-5))
    }
}
