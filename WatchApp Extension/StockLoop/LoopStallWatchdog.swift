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

    /// STOCK PARITY (ruling 2026-08-24): the wrist runs the phone's ladder — 20 and 40 minutes,
    /// 1 and 2 hours, stock's words — instead of a single custom 15-minute alert with bespoke
    /// copy. The mirroring dedupe is ownership, not cleverness: the PHONE's ladder is suppressed
    /// for the whole loan (AlertManager's loan gate), so during a loan only this one speaks, and
    /// outside a loan this one is disarmed, so only the phone's does.
    ///
    /// Every rung is time-sensitive (control document, section 4: anything about dosing is
    /// time-sensitive, nothing is critical). Stock's 1 h and 2 h rungs are critical on the phone;
    /// this build has no Critical Alerts entitlement, so watchOS already delivered those two as
    /// time-sensitive, and asking for that level changes nothing the looper feels.
    ///
    /// The rungs are pre-scheduled from OUTSIDE the app (UNUserNotificationCenter), so a
    /// suspended or dead watch app still alarms — the dead-man property is unchanged.
    static let rungs: [TimeInterval] = [20 * 60, 40 * 60, 60 * 60, 120 * 60]

    /// The first rung, for tests and for anything that reasons about "the" deadline.
    static let interval: TimeInterval = rungs[0]

    private static let identifier = "com.loopkit.Loop.watch.loopStallWatchdog"
    private static var rungIdentifiers: [String] { rungs.map { "\(identifier).\(Int($0))" } }

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
            // Names the device: the phone's own ladder can reach the wrist too (2026-10-21).
            content.title = NSLocalizedString("Loop Failure (Watch)", comment: "The notification title for a loop failure on the watch")
            content.body = String(format: NSLocalizedString("Loop has not completed successfully in %@", comment: "The notification alert describing a long-lasting loop failure. The substitution parameter is the time interval since the last loop"),
                                  formatter.string(from: rung)?.localizedLowercase ?? "\(Int(rung / 60)) minutes")
            content.interruptionLevel = .timeSensitive
            content.sound = .default
            content.threadIdentifier = identifier
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: rung, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(identifier).\(Int(rung))",
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

/// With no loan running, fires if the watch hears nothing from the phone (control row 3; ported
/// from next-dev 1406bc8e with the reviewed words of 5c99fd7e). Every word from the phone pushes
/// it out (`PodLoanWatchController.notePhoneHeard`); pre-scheduled, so it fires even if the watch
/// app is not running. Nothing takes the pod: the looper is told, and Start is one tap away.
enum NotHearingFromPhoneAlert {
    /// After the phone's own pre-scheduled Loop Failure (20 min), which reaches the wrist when the
    /// phone is near or through a cellular watch's relay; the watch's is the backup for a dead
    /// phone or a watch with no route to it.
    static let interval: TimeInterval = 25 * 60

    private static let identifier = "sportmode.notHearingFromPhone"

    static func arm(after interval: TimeInterval = NotHearingFromPhoneAlert.interval) {
        let center = WristAlerts.scheduler
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Not Hearing From iPhone", comment: "Watch alert title: no word from the phone and no loan running")
        content.body = NSLocalizedString("Your iPhone is probably not looping (off or out of range). Sport Mode on the watch is available to take over.", comment: "Watch alert body: no word from the phone and no loan running")
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

// MARK: - DeathBlackBox (ported from next-dev, 2026-08-25)
// The silent-death investigation's system-side witness. The watch app dies without a crash
// report — our own instrumentation brackets WHEN to the second and rules out
// memory-at-launch; what it cannot see is WHY, because the killer is the OS and the OS
// writes its account elsewhere. MetricKit is that account: crash/hang/CPU diagnostics
// delivered on a LATER launch. Summaries go to SportLog ([blackbox]); full JSON lands in
// Documents/blackbox-<stamp>.json and rides the log pull.
// (Homed here rather than its own file to stay inside the existing target membership.)

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
