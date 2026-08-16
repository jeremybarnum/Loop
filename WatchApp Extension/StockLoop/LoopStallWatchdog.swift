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
        // Wrist copy (field-corrected 2026-08-06). Dropped two things from the original: the
        // opening clause, which restated the title, and "check your pod" — during a loan the pod
        // is driven by the watch and there is nothing the user can inspect. KEPT "check your
        // glucose": a sensor gap is by far the most common cause, and it IS the right action,
        // since a stalled loop means nothing is watching BG. Temp hedged because the watchdog
        // fires at 15 min and a temp usually outlasts that.
        content.body = NSLocalizedString("Check your glucose. Your pod returns to scheduled basal when its temp expires.", comment: "Body: the watch closed loop has stopped completing cycles")
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

    private static let sinceFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Arm, or push forward after a fresh direct reading.
    ///
    /// The body names the TIME of the last reading rather than an elapsed duration, because the
    /// trigger REPEATS: "for 20 minutes" is a lie from the second firing onward, while "since
    /// 14:05" stays true however long the blackout runs. It is stamped here, at the moment of
    /// that reading, which is the only place the fact is known — the notification itself is
    /// composed 20 minutes before it lands.
    ///
    /// It no longer blames sensor geometry. All the watch observes is silence; the causes it
    /// cannot distinguish include a post-takeover G7 stand-down that self-recovers, a held pod
    /// link starving acquisition, and a sensor session that simply ended. Dexcom's own watch app
    /// reads the same sensor independently, so it is the one check that tells the user whether
    /// the sensor stopped or only Sport Mode's link to it did — which is worth naming while this
    /// build is young and "is it me or the app?" is the live question.
    static func refresh() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("No Direct G7 Readings", comment: "Sensor-blackout alert title")
        content.body = String(
            format: NSLocalizedString("Nothing since %@. May clear on its own — check Dexcom's app to see if the sensor is reporting.", comment: "Sensor-blackout alert body (1: time of the last direct reading)"),
            sinceFormatter.string(from: Date()))
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

/// #67 (2026-07-28): the hand-back to the iPhone never got acked within the budget — the
/// phone is unreachable, or silently dropping offers (#35). Pre-scheduled like the watchdogs
/// above so the wrist alert fires FROM OUTSIDE a suspended app (a hand-back can hang while the
/// app is backgrounded). Armed at the End tap (beginHandback), disarmed on ack / cancel / a
/// phone revoke. On expiry the watch also resumes Sport Mode locally in the SAME loop mode
/// (PodLoanWatchController.handbackTimedOut) — the two are coordinated at the same deadline.
enum HandbackStuckAlert {

    /// How long to wait for the phone's ack before giving up and resuming on the watch. ~8
    /// resends at 15 s — long enough to ride a briefly-asleep / out-of-range phone, short
    /// enough not to strand the user. The un-dosed window in the final-hang case is just
    /// open-loop scheduled basal (bounded, the validated E4 posture). Tune freely.
    static let interval: TimeInterval = 2 * 60

    private static let identifier = "sportmode.handbackStuck"

    static func arm() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
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
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
