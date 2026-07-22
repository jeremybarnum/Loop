//
//  RuntimeStateLog.swift
//  WatchApp Extension
//
//  Runtime-state instrumentation (Jeremy 2026-07-22): "I remain worried that there is a
//  difference in behavior between wrist up staring at the app / wrist down with the app
//  in foreground / wrist up in a different app / wrist down having last used another app /
//  and the charging screen."
//
//  That worry was correct, and the existing instrumentation could not answer it:
//
//  1. `WKExtensionDelegate` has FOUR relevant hooks; only `applicationDidBecomeActive`
//     and `applicationWillResignActive` were implemented, so `.inactive` (wrist down,
//     our app still frontmost) and `.background` (some other app) both printed the same
//     "BACKGROUND (resigned active)" line — precisely the two cases we needed to tell
//     apart.
//  2. Nothing measured SUSPENSION. On 2026-07-22 the +90s pod-release timer fired 3m36s
//     late; that lateness is what made us cancel a pod connection the pod had already
//     dropped, wedging the peripheral in `.disconnecting` and costing three G7 windows.
//     Suspension had to be INFERRED from three unrelated timers firing within 34 ms of
//     each other after four minutes of silence. Build 149's log shows the same shape with
//     gaps of 206s, 206s, 228s — on battery, with an HKWorkoutSession supposedly holding
//     background runtime.
//
//  So the premise of the tool — a workout session keeps us running — does NOT hold
//  unconditionally, and until we can see when it fails, every radio fix is evaluated
//  against logs that cannot say whether the app was even executing.
//
//  The heartbeat is deliberately SILENT while healthy: a 30 s timer that emits only when
//  the observed gap exceeds the tolerance. Suspension becomes a measured number rather
//  than an inference, without burying the log in "still alive" lines.
//

import Foundation
#if os(watchOS)
import WatchKit
#endif

enum RuntimeStateLog {

    /// Human-readable app runtime state. `.inactive` is the one the old binary logging
    /// erased — it is the wrist-down-but-frontmost case, where watchOS keeps us
    /// foreground-ish but dims, and it behaves differently from a true background.
    static func appStateName() -> String {
        #if os(watchOS)
        switch WKExtension.shared().applicationState {
        case .active:     return "active"
        case .inactive:   return "inactive"   // wrist down / dimmed, still frontmost
        case .background: return "background"
        @unknown default: return "unknown"
        }
        #else
        return "n/a"
        #endif
    }

    /// One compact snapshot appended to every state line, so any dropout can be
    /// correlated against all of the conditions at once.
    static func snapshot() -> String {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? " · LOW-POWER" : ""
        return "state \(appStateName()) · \(batteryTag())\(lowPower)"
    }

    // MARK: - Suspension detector

    private static var timer: DispatchSourceTimer?
    private static var lastTick = Date()
    /// 30 s cadence; anything past 45 s means we were not executing. The margin absorbs
    /// ordinary timer leeway without masking a real suspension.
    private static let interval: TimeInterval = 30
    private static let tolerance: TimeInterval = 45

    /// Start while a session is live — that is the only window where lost runtime can
    /// cost a reading or strand a pod command.
    static func startHeartbeat() {
        stopHeartbeat()
        lastTick = Date()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(2))
        t.setEventHandler {
            let now = Date()
            let gap = now.timeIntervalSince(lastTick)
            lastTick = now
            guard gap > tolerance else { return }   // healthy: stay quiet
            SportLog.event("runtime", String(format: "GAP %.0fs (expected %.0fs) — app was NOT executing · %@",
                                             gap, interval, snapshot()))
        }
        t.resume()
        timer = t
        SportLog.event("runtime", "heartbeat armed (30s; reports only gaps >45s) · \(snapshot())")
    }

    static func stopHeartbeat() {
        timer?.cancel()
        timer = nil
    }
}
