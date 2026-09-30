//
//  LoopStallWatchdog.swift
//  WatchApp Extension
//
//  The wrist's dead-man alarms (loop stopped; hand-back stuck), pre-scheduled and pushed
//  forward while progress continues, so they fire even if the app is suspended.
//

import Foundation
import UserNotifications

/// The phone's Loop-Failure ladder on the wrist; only one of the two ladders is armed at a time.
enum LoopStallWatchdog {
    static let rungs: [(interval: TimeInterval, isCritical: Bool)] = [
        (20 * 60, false), (40 * 60, false), (60 * 60, true), (120 * 60, true),
    ]

    /// The first rung — the single number for anything that reasons about "the" deadline.
    static let interval: TimeInterval = rungs[0].interval

    private static let identifier = "com.loopkit.Loop.watch.loopStallWatchdog"
    private static var rungIdentifiers: [String] { rungs.map { "\(identifier).\(Int($0.interval))" } }

    /// Re-adds each rung under its own identifier, which replaces the pending one: that is the
    /// dead-man.
    static func refresh() {
        let center = WristAlerts.scheduler
        let formatter = DateComponentsFormatter()
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        for rung in rungs {
            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("Loop Failure", comment: "The notification title for a loop failure")
            content.body = String(format: NSLocalizedString("Loop has not completed successfully in %@", comment: "The notification alert describing a long-lasting loop failure. The substitution parameter is the time interval since the last loop"),
                                  formatter.string(from: rung.interval)?.localizedLowercase ?? "\(Int(rung.interval / 60)) minutes")

            // Without the Critical Alerts entitlement a .critical rung arrives time-sensitive.
            content.interruptionLevel = rung.isCritical ? .critical : .timeSensitive
            content.sound = rung.isCritical ? .defaultCritical : .default
            content.threadIdentifier = identifier
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: rung.interval, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(identifier).\(Int(rung.interval))",
                                             content: content, trigger: trigger))
        }
    }

    /// For a loop stopped on purpose; the phone re-arms its ladder at reclaim.
    static func disarm() {
        let center = WristAlerts.scheduler
        center.removePendingRequests(withIdentifiers: rungIdentifiers)
        center.removeDeliveredRequests(withIdentifiers: rungIdentifiers)
    }
}

/// Fires when the watch is still looking for a sensor it has never connected to and the app has
/// been in the background for a while: discovery scans poorly with the app out of sight, and
/// bringing it to the front is what gets the sensor found.
enum SensorSearchAlert {
    static let interval: TimeInterval = 10 * 60
    private static let identifier = "g7.sensorSearch"

    static func arm() {
        let center = WristAlerts.scheduler
        center.removePendingRequests(withIdentifiers: [identifier])
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Sensor Not Found", comment: "Watch sensor-search alert title")
        content.body = NSLocalizedString("Loop on your watch is still looking for your sensor. Open Loop and keep it open until it connects.", comment: "Watch sensor-search alert body")
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        content.threadIdentifier = identifier
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    static func disarm() {
        let center = WristAlerts.scheduler
        center.removePendingRequests(withIdentifiers: [identifier])
        center.removeDeliveredRequests(withIdentifiers: [identifier])
    }
}

/// Fires if a hand-back never completes.
enum HandbackStuckAlert {
    /// Covers two offers and a pod read; shorter would abandon a hand-back mid-commit.
    static let interval: TimeInterval = 2 * 60

    private static let identifier = "sportmode.handbackStuck"

    static func arm() {
        let center = WristAlerts.scheduler
        center.removePendingRequests(withIdentifiers: [identifier])
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Couldn't End Sport Mode", comment: "Hand-back-stuck alert title")
        content.body = NSLocalizedString("The iPhone didn't respond, so Sport Mode is still running on your watch. Tap End to try again.", comment: "Hand-back-stuck alert body")
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        content.threadIdentifier = identifier
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    static func disarm() {
        let center = WristAlerts.scheduler
        center.removePendingRequests(withIdentifiers: [identifier])
        center.removeDeliveredRequests(withIdentifiers: [identifier])
    }
}
