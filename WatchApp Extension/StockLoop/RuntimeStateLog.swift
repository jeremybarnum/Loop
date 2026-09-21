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
    static func appStateName() -> String {
        #if os(watchOS)
        switch WKExtension.shared().applicationState {
        case .active:     return "active"
        case .inactive:   return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
        #else
        return "n/a"
        #endif
    }

    static func snapshot() -> String {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? " · LOW-POWER" : ""

        return "state \(appStateName()) · \(keepaliveTag()) · \(batteryTag())\(lowPower)"
    }

    private static var timer: DispatchSourceTimer?
    private static var lastTick = Date()

    private static var lastTickState = "unknown"
    private static var lastBackgroundProof = Date.distantPast

    private static let interval: TimeInterval = 30
    private static let tolerance: TimeInterval = 45

    private static let backgroundProofInterval: TimeInterval = 120

    static var keepaliveProbe: (() -> String)?

    private static func keepaliveTag() -> String { keepaliveProbe?() ?? "keepalive ?" }

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

    private static let stallLock = NSLock()
    private static var pingSentAt: Date?
    private static var stallReportedFor: Date?

    private static var mainMark = "—"
    private static var mainMarkAt = Date()
    private static var lastStallReportAt: Date?

    static func mark(_ label: String) {
        stallLock.lock(); mainMark = label; mainMarkAt = Date(); stallLock.unlock()
    }

    private static let stallThreshold: TimeInterval = 2.0
    private static var stallTimer: DispatchSourceTimer?

    static func startMainStallDetector() {
        stopMainStallDetector()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(200))
        t.setEventHandler {
            stallLock.lock()
            let outstanding = pingSentAt
            let alreadyReported = stallReportedFor
            stallLock.unlock()

            if let sent = outstanding {
                let stuckFor = Date().timeIntervalSince(sent)
                if stuckFor > stallThreshold, alreadyReported != sent {
                    stallLock.lock()
                    stallReportedFor = sent

                    lastStallReportAt = Date()
                    let where_ = mainMark
                    let markAge = Date().timeIntervalSince(mainMarkAt)
                    stallLock.unlock()
                    SportLog.event("runtime", String(format:
                        "MAIN STALLED — main thread has not run for %.1fs (still stuck) · last main entry: %@ (%.1fs ago) · %@",
                        stuckFor, where_, markAge, keepaliveTag()))
                }

                else if stuckFor > stallThreshold, let last = lastStallReportAt,
                        Date().timeIntervalSince(last) >= 10 {
                    stallLock.lock()
                    lastStallReportAt = Date()
                    let where_ = mainMark
                    stallLock.unlock()
                    SportLog.event("runtime", String(format:
                        "MAIN STILL STALLED — %.0fs and counting · last main entry: %@", stuckFor, where_))
                }
                return
            }

            let sent = Date()
            stallLock.lock(); pingSentAt = sent; stallLock.unlock()
            DispatchQueue.main.async {
                let waited = Date().timeIntervalSince(sent)
                stallLock.lock()
                pingSentAt = nil
                let wasReported = (stallReportedFor == sent)
                if wasReported { stallReportedFor = nil }
                stallLock.unlock()

                if wasReported {
                    SportLog.event("runtime", String(format: "MAIN RECOVERED — main was blocked for %.1fs", waited))
                }
            }
        }
        t.resume()
        stallTimer = t
    }

    static func stopMainStallDetector() {
        stallTimer?.cancel()
        stallTimer = nil
        stallLock.lock(); pingSentAt = nil; stallReportedFor = nil; stallLock.unlock()
    }

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
            let wentDownIn = lastTickState
            lastTick = now
            let state = appStateName()
            lastTickState = state

            if gap > tolerance {
                SportLog.event("runtime", String(format:
                    "GAP %.0fs (expected %.0fs) — app was NOT executing · went down in state %@ · woke in %@ · %@ · %@",
                    gap, interval, wentDownIn, state, keepaliveTag(), snapshot()))
                return
            }

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
