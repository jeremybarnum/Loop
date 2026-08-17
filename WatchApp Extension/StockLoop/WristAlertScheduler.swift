//
//  WristAlertScheduler.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import UserNotifications

/// The notification-scheduling surface the three dead-man alerts actually use.
///
/// WHY THIS EXISTS. `WatchdogArmingTests` asserted directly against
/// `UNUserNotificationCenter.current()`, and that turned out to depend on invisible, unmanaged
/// simulator state: `add(_:)` is silently dropped when the app is not authorized — no error
/// reaches the caller, because production passes no completion handler — and a test host cannot
/// obtain authorization, since `requestAuthorization` waits on a system prompt nobody can tap
/// (verified: the callback never fires, it times out). The suite passed for months only because
/// that particular simulator had been granted authorization by some earlier interactive run of
/// the real app. Erasing the simulator destroyed the grant permanently, and `simctl privacy` has
/// no notifications service to restore it. So the tests were never deterministic; they were lucky.
///
/// WHAT IS AND IS NOT TRADED AWAY. What this suite protects is IDENTIFIER DISCIPLINE, and that is
/// our code's property, not Apple's: that `refresh()` reuses ONE identifier so a healthy loop
/// perpetually defers its own alarm, and that the three alerts own three DISTINCT identifiers so
/// disarming one cannot cancel another. A recording double sees exactly the requests our code
/// makes, so those properties stay fully covered — and they are the ones that regress when someone
/// edits an alert. What is no longer asserted is that watchOS HONOURS replacement-by-identifier.
/// That is documented platform behaviour which does not change when we refactor, and it was never
/// really being tested anyway on a simulator whose daemon was dropping every request on the floor.
///
/// Production is unchanged: the default is the real notification centre, and nothing outside tests
/// ever assigns `current`.
protocol WristAlertScheduling: AnyObject {
    func add(_ request: UNNotificationRequest)
    func removePendingRequests(withIdentifiers identifiers: [String])
    func removeDeliveredRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: WristAlertScheduling {
    func add(_ request: UNNotificationRequest) {
        // Fire-and-forget, exactly as before: no completion handler in production.
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
    /// The scheduler the dead-man alerts arm through. Tests substitute a recording double; nothing
    /// in the app ever reassigns it.
    static var scheduler: WristAlertScheduling = UNUserNotificationCenter.current()
}
