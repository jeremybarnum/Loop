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

    // ─── TUNABLES — safe to change for your own build ────────────────────────

    /// How long the closed loop may go without completing a cycle before the
    /// alert fires. Refreshed on every live cycle, so it only fires on a genuine
    /// stall. 15 min = three G7 reading intervals: tolerates a normal RF gap or
    /// two, catches a real stall promptly. (The phone's AT-REST loop-not-running
    /// ladder starts at 20 min — a workout warrants a tighter window.)
    static let interval: TimeInterval = 15 * 60

    /// How disruptive the "loop stopped" alert is.
    ///   false (DEFAULT) → .timeSensitive: a wrist haptic + on-screen card that
    ///     can break through Focus, but does NOT force sound through the silent
    ///     switch / Do Not Disturb. Deliberately non-blaring so it can't disrupt
    ///     an equestrian competition round.
    ///   true → .critical: pierces silent mode / DND with sound — louder and more
    ///     insistent. Requires the Critical Alerts entitlement; without it watchOS
    ///     silently downgrades to time-sensitive.
    /// Change this one flag to trade non-disruption against insistence.
    static let useCriticalAlert = false

    // ─────────────────────────────────────────────────────────────────────────

    private static let identifier = "com.loopkit.Loop.watch.loopStallWatchdog"

    /// Arm the watchdog or push its deadline forward. Adding a request with the
    /// same identifier REPLACES the pending one, so calling this on every live
    /// cycle simply re-defers the alert.
    static func refresh() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Sport Mode Loop Stopped", comment: "Title: the watch closed loop has stopped completing cycles")
        content.body = NSLocalizedString("The watch hasn't looped in a while — check your pod and glucose. Your pod reverts to its scheduled basal when its last temp expires.", comment: "Body: the watch closed loop has stopped completing cycles")
        content.interruptionLevel = useCriticalAlert ? .critical : .timeSensitive
        content.sound = useCriticalAlert ? .defaultCritical : .default
        content.threadIdentifier = identifier
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    /// Disarm — a clean end / hand-back / revoke. The loop is stopping on purpose.
    static func disarm() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

/// WS4b (ruled 2026-07-19): notification-only dead-man for DIRECT G7 readings
/// during a loan. Same pre-scheduled pattern as LoopStallWatchdog — armed at loan
/// start, re-deferred by every direct reading, fires from OUTSIDE a suspended app.
/// Distinct from the loop watchdog: this fires in OPEN loop too (the loop watchdog
/// is closed-cycle-keyed) — a 2.5-hour silent blackout must never happen again
/// (party finding 2026-07-18). Repeats every 20 min while the blackout persists;
/// no automatic actions (C8 pattern).
enum SensorBlackoutAlert {

    /// Two missed reading cycles beyond the display staleness gate (ruled: 20 min).
    static let interval: TimeInterval = 20 * 60

    private static let identifier = "sportmode.sensorBlackout"

    /// Arm, or push forward after a fresh direct reading.
    static func refresh() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("No G7 Readings", comment: "Sensor-blackout alert title")
        content.body = NSLocalizedString("No direct G7 reading for 20 minutes. Sport Mode won't dose without readings — check the watch's position relative to the sensor.", comment: "Sensor-blackout alert body")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: true)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    static func disarm() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

/// Wrong-code alert (2026-07-24): the G7 handshake failed AES-verify repeatedly, which —
/// once a transient dropped-chunk is ruled out by the ≥2 threshold — almost always means
/// the sensor pairing code is wrong. Unlike the watchdogs above, this fires IMMEDIATELY on
/// detection: the user needs to know NOW, on the wrist, that the code is the problem and can
/// be re-entered (they may be mid-workout with no iPhone). Fired/cleared from
/// G7Client.needsSensorCode's didSet; the glance also shows a re-enter banner.
enum SensorCodeAlert {
    private static let identifier = "sportmode.sensorCode"

    static func fire() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Check Sensor Code", comment: "Wrong-code alert title")
        content.body = NSLocalizedString("The new G7 wouldn't authenticate — its 4-digit code may be wrong. Re-enter it on the watch (or iPhone).", comment: "Wrong-code alert body")
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        content.threadIdentifier = identifier
        // Immediate (1s) rather than a future deadline — this is a "here and now" problem.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
