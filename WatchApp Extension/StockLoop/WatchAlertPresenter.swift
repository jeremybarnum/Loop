//
//  WatchAlertPresenter.swift
//  WatchApp Extension
//
//  LoopKit alerts on the wrist: while the watch holds the pod it is the only device that
//  hears the pump. Delivered through `WristAlerts.scheduler`, one identifier per alert.
//

import Foundation
import LoopKit
import UserNotifications

enum WatchAlertPresenter {
    /// Namespaced apart from the dead-man ladder's identifiers.
    static func requestIdentifier(for identifier: LoopKit.Alert.Identifier) -> String {
        return "sportmode.alert.\(identifier.value)"
    }

    /// Uses `backgroundContent`; a `.repeating` trigger becomes a repeating notification.
    static func present(_ alert: LoopKit.Alert) {
        let content = UNMutableNotificationContent()
        content.title = alert.backgroundContent.title
        content.body = alert.backgroundContent.body
        content.threadIdentifier = alert.identifier.managerIdentifier

        // Without the Critical Alerts entitlement a .critical request arrives time-sensitive.
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
            // Repeating triggers under 60 s are silently dropped.
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, repeatInterval), repeats: true)
        }

        WristAlerts.scheduler.add(UNNotificationRequest(identifier: requestIdentifier(for: alert.identifier),
                                                        content: content,
                                                        trigger: trigger))
    }

    /// Withdraws a pending or delivered alert when the condition clears.
    static func retract(_ identifier: LoopKit.Alert.Identifier) {
        let request = requestIdentifier(for: identifier)
        WristAlerts.scheduler.removePendingRequests(withIdentifiers: [request])
        WristAlerts.scheduler.removeDeliveredRequests(withIdentifiers: [request])
    }
}
