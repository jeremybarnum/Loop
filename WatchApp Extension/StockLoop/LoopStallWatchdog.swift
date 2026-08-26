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

    /// STOCK PARITY (ruling 2026-08-24): the wrist runs the phone's exact ladder —
    /// 20/40 minutes time-sensitive, 1/2 hours critical, stock's words — instead of a single
    /// custom 15-minute alert with bespoke copy. Same rungs, same escalation, both devices;
    /// the mirroring dedupe is ownership, not cleverness: the PHONE's ladder is suppressed for
    /// the whole loan (AlertManager's loan gate), so during a loan only this one speaks, and
    /// outside a loan this one is disarmed, so only the phone's does.
    ///
    /// The rungs are pre-scheduled from OUTSIDE the app (UNUserNotificationCenter), so a
    /// suspended or dead watch app still alarms — the dead-man property is unchanged.
    static let rungs: [(interval: TimeInterval, isCritical: Bool)] = [
        (20 * 60, false), (40 * 60, false), (60 * 60, true), (120 * 60, true),
    ]

    /// The first rung, for tests and for anything that reasons about "the" deadline.
    static let interval: TimeInterval = rungs[0].interval

    private static let identifier = "com.loopkit.Loop.watch.loopStallWatchdog"
    private static var rungIdentifiers: [String] { rungs.map { "\(identifier).\(Int($0.interval))" } }

    /// Arm the ladder or push every rung forward. Adding requests with the same identifiers
    /// REPLACES the pending ones, so calling this on every live cycle re-defers the whole ladder.
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
            // Critical rungs request .critical; without the Critical Alerts entitlement
            // watchOS silently downgrades to time-sensitive, which is the acceptable floor.
            content.interruptionLevel = rung.isCritical ? .critical : .timeSensitive
            content.sound = rung.isCritical ? .defaultCritical : .default
            content.threadIdentifier = identifier
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: rung.interval, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(identifier).\(Int(rung.interval))",
                                             content: content, trigger: trigger))
        }
    }

    /// Disarm — a clean end / hand-back / revoke. The loop is stopping on purpose, and the
    /// PHONE's ladder re-arms at reclaim, so coverage transfers rather than lapses.
    static func disarm() {
        let center = WristAlerts.scheduler
        center.removePendingRequests(withIdentifiers: rungIdentifiers)
        center.removeDeliveredRequests(withIdentifiers: rungIdentifiers)
    }
}

// SensorBlackoutAlert (WS4b, ruled 2026-07-19) DELETED by ruling 2026-08-24: a glucose
// blackout stalls loop cycles in open and closed mode alike (missingDataError holds the
// watchdog), so the ladder above reports it on the same rungs — the separate 20-minute
// repeating alert had become a guaranteed duplicate voice for the same stall. The party
// finding it answered (a 2.5-hour silent blackout) remains covered, one octave lower.

enum HandbackStuckAlert {

    /// How long to wait for the phone's ack before giving up and resuming on the watch. ~8
    /// resends at 15 s — long enough to ride a briefly-asleep / out-of-range phone, short
    /// enough not to strand the user. The un-dosed window in the final-hang case is just
    /// open-loop scheduled basal (bounded, the validated E4 posture). Tune freely.
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


// MARK: - DeathBlackBox (2026-08-25)
// The silent-death investigation's system-side witness. The watch app has died without a
// crash report at least seven times across three days — our own instrumentation brackets
// WHEN to the second and rules out memory-at-launch; what it cannot see is WHY, because the
// killer is the OS and the OS writes its account elsewhere. MetricKit is that account:
// crash/hang/CPU diagnostics delivered on a LATER launch. Summaries go to SportLog
// ([blackbox]); full JSON lands in Documents/blackbox-<stamp>.json and rides the log pull.
// (Homed here rather than its own file to stay inside the existing target membership.)

import Foundation

#if canImport(MetricKit)
import MetricKit

final class DeathBlackBox: NSObject, MXMetricManagerSubscriber {
    static let shared = DeathBlackBox()

    /// Idempotent. Called once at session assembly — early, so a payload delivered at launch
    /// (the usual delivery moment) is not missed while the stack is still wiring.
    func arm() {
        MXMetricManager.shared.add(self)
        SportLog.event("blackbox", "MetricKit subscriber armed — system diagnostics will be captured on delivery [blackbox]")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            summarize(payload)
            persist(payload)
        }
    }

    private func summarize(_ payload: MXDiagnosticPayload) {
        for crash in payload.crashDiagnostics ?? [] {
            SportLog.event("blackbox", "CRASH diagnostic: type=\(crash.exceptionType?.stringValue ?? "-") code=\(crash.exceptionCode?.stringValue ?? "-") signal=\(crash.signal?.stringValue ?? "-") reason=\(crash.terminationReason ?? "-") build=\(crash.applicationVersion) [blackbox]")
        }
        for hang in payload.hangDiagnostics ?? [] {
            SportLog.event("blackbox", "HANG diagnostic: duration=\(hang.hangDuration) [blackbox]")
        }
        for cpu in payload.cpuExceptionDiagnostics ?? [] {
            SportLog.event("blackbox", "CPU-EXCEPTION diagnostic: totalCPU=\(cpu.totalCPUTime) sampled=\(cpu.totalSampledTime) [blackbox]")
        }
    }

    private func persist(_ payload: MXDiagnosticPayload) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = docs.appendingPathComponent("blackbox-\(stamp).json")
        do {
            try payload.jsonRepresentation().write(to: url)
            SportLog.event("blackbox", "full diagnostic payload written: \(url.lastPathComponent) [blackbox]")
        } catch {
            SportLog.event("blackbox", "payload persist FAILED: \(error) [blackbox]")
        }
    }
}
#else
final class DeathBlackBox {
    static let shared = DeathBlackBox()
    func arm() {}
}
#endif
