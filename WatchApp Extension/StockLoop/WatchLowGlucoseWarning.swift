//
//  WatchLowGlucoseWarning.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import UserNotifications

/// How the watch delivers the predicted-low warning. The decision itself is shared with the phone
/// (`LowGlucoseWarning`); while the watch holds the pod it is the device that can answer the
/// question — the phone's books are missing every dose the watch has enacted since the grant — so
/// it owns the warning for the duration of the loan and the phone stands down.
enum WatchLowGlucoseWarning {

    // MARK: - Delivery

    static let notificationIdentifier = "com.loopkit.Loop.watch.lowBGWarning"

    /// Posts immediately. Replacing the pending request under the same identifier means a fresh
    /// warning supersedes a stale one rather than stacking on the wrist.
    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        content.threadIdentifier = notificationIdentifier
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: nil))
    }


    /// Hand-back, revoke, or any other end of the loan: the phone takes the warning back, so
    /// anything still on the wrist should go with it.
    static func clearDelivered() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
    }
}
