//
//  WristAlertScheduler.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
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

// MARK: - Pod and CGM alerts on the wrist
//
// While the watch holds the pod it is the only device that can hear the pump. A pod fault, an
// occlusion or an empty reservoir arrives as a `LoopKit.Alert`, and the phone's own alert manager
// is not watching a pump it does not have — so without this, a pod alarm during a loan reached
// neither screen (it was only logged). Ported from next-dev (WatchAlertPresenter.swift, 2026-09).
// Delivery goes through `WristAlerts.scheduler`, the dead-man ladder's seam, under its own
// identifier family so a retraction can never reach the ladder.

enum WatchAlertPresenter {
    /// Namespaced so a retraction cannot reach the dead-man ladder's identifiers, which are
    /// owned by `LoopStallWatchdog` and live in a different family.
    static func requestIdentifier(for identifier: LoopKit.Alert.Identifier) -> String {
        return "sportmode.alert.\(identifier.value)"
    }

    /// Present an alert on the wrist now, or at its scheduled moment.
    ///
    /// `backgroundContent` is the text used: the wrist has no foreground alert presentation of
    /// its own, so what the user sees is always the notification. A `.repeating` trigger is
    /// honoured as a repeating notification — the pod alerts that use it are the ones the user
    /// must not be able to sleep through.
    static func present(_ alert: LoopKit.Alert) {
        let content = UNMutableNotificationContent()
        content.title = alert.backgroundContent.title
        content.body = alert.backgroundContent.body
        content.threadIdentifier = alert.identifier.managerIdentifier

        // Without the Critical Alerts entitlement watchOS delivers a .critical request as
        // time-sensitive instead, which is the acceptable floor rather than a failure.
        switch alert.interruptionLevel {
        case .critical:
            content.interruptionLevel = .critical
            content.sound = .defaultCritical
        case .timeSensitive:
            content.interruptionLevel = .timeSensitive
            content.sound = .default
        case .active:
            content.interruptionLevel = .active
            content.sound = .default
        }

        let trigger: UNNotificationTrigger?
        switch alert.trigger {
        case .immediate:
            trigger = nil
        case .delayed(let interval):
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        case .repeating(let repeatInterval):
            // The notification centre refuses a repeating trigger under 60 s and drops the
            // request silently, so a shorter interval is raised to the floor rather than lost.
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, repeatInterval), repeats: true)
        }

        WristAlerts.scheduler.add(UNNotificationRequest(identifier: requestIdentifier(for: alert.identifier),
                                                        content: content,
                                                        trigger: trigger))
    }

    /// Withdraw an alert, pending or already delivered. A driver retracts when the condition
    /// clears — an occlusion alarm left standing on the wrist after the pod recovered is worse
    /// than one that never fired, because the next one carries no weight.
    static func retract(_ identifier: LoopKit.Alert.Identifier) {
        let request = requestIdentifier(for: identifier)
        WristAlerts.scheduler.removePendingRequests(withIdentifiers: [request])
        WristAlerts.scheduler.removeDeliveredRequests(withIdentifiers: [request])
    }
}
