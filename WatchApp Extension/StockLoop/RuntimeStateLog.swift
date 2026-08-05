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
        // Include the keepalive here too (2026-08-04). It was already on the heartbeat/GAP/
        // deferral lines but NOT on the [app] ACTIVE / RESIGN ACTIVE lines — which are exactly
        // the ones that show the screen going dark. Jeremy, field: during reclaim "the watch
        // screen seems to go dark kind of aggressively... it sort of wants to go back to the
        // clock screen", wrist up, 38% battery. A live HKWorkoutSession keeps the app frontmost
        // on wrist raise, so whether one was running at that instant decides between "the
        // session ended when the watch's part finished, and this is ordinary watchOS behaviour"
        // and "something dropped the session while the hand-back was still in flight".
        return "state \(appStateName()) · \(keepaliveTag()) · \(batteryTag())\(lowPower)"
    }

    // MARK: - Suspension detector

    private static var timer: DispatchSourceTimer?
    private static var lastTick = Date()
    /// State observed at the last HEALTHY tick — i.e. the state we were in when execution
    /// stopped. The GAP line used to snapshot state AFTER the wake, which always reports the
    /// state we came back to and never the one we went down in (#82).
    private static var lastTickState = "unknown"
    private static var lastBackgroundProof = Date.distantPast
    /// 30 s cadence; anything past 45 s means we were not executing. The margin absorbs
    /// ordinary timer leeway without masking a real suspension.
    private static let interval: TimeInterval = 30
    private static let tolerance: TimeInterval = 45
    /// One BG-ALIVE line every 2 min: enough to prove background execution across a whole
    /// night, sparse enough not to bury the log.
    private static let backgroundProofInterval: TimeInterval = 120

    /// Set by `WorkoutKeepalive` at init so every runtime line can say whether the keepalive
    /// that is supposed to be holding us up was actually alive at that moment. Sampled from
    /// the heartbeat queue, so the implementation must be thread-safe.
    static var keepaliveProbe: (() -> String)?

    private static func keepaliveTag() -> String { keepaliveProbe?() ?? "keepalive ?" }

    // MARK: - #86: direct timer-deferral meter

    /// Measure how late a scheduled block ACTUALLY runs.
    ///
    /// Until now the deferral was INFERRED from gaps between takeover-ladder reads, which cannot
    /// separate "watchOS deferred our timer" from "the read itself blocked". This asks for a known
    /// delay on the same queue kind the ladder uses and reports what it got, so the two become
    /// distinguishable. Fire-and-forget; nothing waits on it.
    ///
    /// Reports only when late by more than `tolerance`, so a healthy run stays quiet — but ALWAYS
    /// reports on the first probe of an attempt (`label` carrying "start") so each ladder has at
    /// least one datapoint even when the OS is behaving.
    static func probeTimerDeferral(_ label: String, requested: TimeInterval = 3.0,
                                   tolerance: TimeInterval = 1.0) {
        let asked = Date()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + requested) {
            let actual = Date().timeIntervalSince(asked)
            let late = actual - requested
            guard late > tolerance || label.contains("start") else { return }
            SportLog.event("runtime", String(format:
                "timer-probe [%@] asked %.1fs got %.1fs (late %+.1fs) · %@ · %@",
                label, requested, actual, late, keepaliveTag(), snapshot()))
        }
    }

    /// Start while a session is live — that is the only window where lost runtime can
    /// cost a reading or strand a pod command.
    static func startHeartbeat() {
        stopHeartbeat()
        lastTick = Date()
        lastTickState = appStateName()
        lastBackgroundProof = .distantPast
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(2))
        t.setEventHandler {
            let now = Date()
            let gap = now.timeIntervalSince(lastTick)
            let wentDownIn = lastTickState        // captured BEFORE we overwrite it
            lastTick = now
            let state = appStateName()
            lastTickState = state

            if gap > tolerance {
                SportLog.event("runtime", String(format:
                    "GAP %.0fs (expected %.0fs) — app was NOT executing · went down in state %@ · woke in %@ · %@ · %@",
                    gap, interval, wentDownIn, state, keepaliveTag(), snapshot()))
                return
            }
            // A healthy tick while genuinely BACKGROUNDED is the only direct evidence that
            // WKBackgroundModes=workout-processing is doing its job (#82) — before build 199
            // the app was suspended within seconds of backgrounding, so this line could never
            // appear. Absence of BG-ALIVE across a night is the failure signal; one line every
            // 2 min is the pass signal.
            if state == "background", now.timeIntervalSince(lastBackgroundProof) >= backgroundProofInterval {
                lastBackgroundProof = now
                SportLog.event("runtime", "BG-ALIVE — executing while backgrounded · \(keepaliveTag()) · \(snapshot())")
            }
        }
        t.resume()
        timer = t
        SportLog.event("runtime", "heartbeat armed (30s; gaps >45s + BG-ALIVE every 2min while backgrounded) · \(keepaliveTag()) · \(snapshot())")
    }

    static func stopHeartbeat() {
        timer?.cancel()
        timer = nil
    }
}
