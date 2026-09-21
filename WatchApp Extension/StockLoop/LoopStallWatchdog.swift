//
//  LoopStallWatchdog.swift
//  WatchApp Extension
//
//  H19 (ported from g7-build-next e3177ad1) — DEAD-MAN'S SWITCH for the watch
//  closed loop; spec §2.4 row 16 / drill D16.
//
//  watchOS suspends the app when the wrist drops; the HKWorkoutSession keepalive is
//  what keeps the loop running in the background. If that keepalive dies (or readings
//  stop for a long stretch), the process is SUSPENDED and cannot raise an alarm
//  itself — so the alarm must be PRE-SCHEDULED: a local notification armed to fire in
//  the future and pushed forward on every successful closed-loop cycle. As long as
//  the loop keeps completing cycles the alert is perpetually re-deferred and never
//  fires; if the loop stalls, nothing defers it and watchOS delivers it FROM OUTSIDE
//  the (dead) app. Mirrors the phone's loop-not-running watchdog, relocated to the
//  watch and keyed to the watch's own loop.
//

import Foundation
import UserNotifications

enum LoopStallWatchdog {
    static let rungs: [(interval: TimeInterval, isCritical: Bool)] = [
        (20 * 60, false), (40 * 60, false), (60 * 60, true), (120 * 60, true),
    ]

    static let interval: TimeInterval = rungs[0].interval

    private static let identifier = "com.loopkit.Loop.watch.loopStallWatchdog"
    private static var rungIdentifiers: [String] { rungs.map { "\(identifier).\(Int($0.interval))" } }

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

            content.interruptionLevel = rung.isCritical ? .critical : .timeSensitive
            content.sound = rung.isCritical ? .defaultCritical : .default
            content.threadIdentifier = identifier
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: rung.interval, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(identifier).\(Int(rung.interval))",
                                             content: content, trigger: trigger))
        }
    }

    static func disarm() {
        let center = WristAlerts.scheduler
        center.removePendingRequests(withIdentifiers: rungIdentifiers)
        center.removeDeliveredRequests(withIdentifiers: rungIdentifiers)
    }
}

enum HandbackStuckAlert {
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
