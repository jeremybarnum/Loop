//
//  WristAlertScheduler.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import UserNotifications

protocol WristAlertScheduling: AnyObject {
    func add(_ request: UNNotificationRequest)
    func removePendingRequests(withIdentifiers identifiers: [String])
    func removeDeliveredRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: WristAlertScheduling {
    func add(_ request: UNNotificationRequest) {
        add(request, withCompletionHandler: nil)
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredRequests(withIdentifiers identifiers: [String]) {
        removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

enum WristAlerts {
    static var scheduler: WristAlertScheduling = UNUserNotificationCenter.current()
}
