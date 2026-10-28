//
//  RuntimeStateLog.swift
//  WatchApp Extension
//
//  The app's run state, for decisions that depend on it.
//

import Foundation
import WatchKit

enum RuntimeStateLog {
    /// .inactive and .background behave differently for runtime, so they stay distinct.
    static func appStateName() -> String {
        switch WKExtension.shared().applicationState {
        case .active:     return "active"
        case .inactive:   return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    /// App state and Low Power Mode.
    static func snapshot() -> String {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? " · LOW-POWER" : ""
        return "state \(appStateName())\(lowPower)"
    }

    // MARK: - Bench only: a 30 s heartbeat that logs suspension gaps during a loan

    private static var timer: DispatchSourceTimer?
    private static var lastTick = Date()
    private static var lastTickState = "unknown"
    private static var lastBackgroundProof = Date.distantPast
    private static let interval: TimeInterval = 30
    private static let tolerance: TimeInterval = 45
    private static let backgroundProofInterval: TimeInterval = 120

    /// Silent while running; a GAP line names the state the app went down in and woke in.
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
                    "GAP %.0fs (expected %.0fs) — app was NOT executing · went down in state %@ · woke in %@ · %@",
                    gap, interval, wentDownIn, state, snapshot()))
                return
            }

            if state == "background", now.timeIntervalSince(lastBackgroundProof) >= backgroundProofInterval {
                lastBackgroundProof = now
                SportLog.event("runtime", "BG-ALIVE — executing while backgrounded · \(snapshot())")
            }
        }
        t.resume()
        timer = t
        SportLog.event("runtime", "heartbeat armed (30s; gaps >45s + BG-ALIVE every 2min while backgrounded) · \(snapshot())")
    }

    static func stopHeartbeat() {
        timer?.cancel()
        timer = nil
    }
}
