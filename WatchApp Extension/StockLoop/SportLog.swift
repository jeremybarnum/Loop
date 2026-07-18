//
//  SportLog.swift
//  WatchApp Extension
//
//  Unified watch-side logging for Sport Mode. The rebuild left the M5 loan protocol
//  and loop on OSLog (system log only) while G7 kept its own file log — so on a
//  TestFlight (distribution-signed) build, whose container isn't reachable via
//  devicectl, the protocol narrative was invisible without a Mac + Console.app.
//
//  SportLog routes the important protocol/loop events into the SAME on-device file
//  the G7 transport writes (g7watch.log via LogFile), AND mirrors to the system log.
//  The diagnostics page reads LogFile.tail() and offers a share sheet, so logs can be
//  read and sent from the wrist — no Mac, no devicectl.
//
//  Use for MILESTONE events (state transitions, grants, hand-backs, verdicts, radio
//  arbitration, watchdog) — not per-reading spam; the file is size-capped.
//

import Foundation
import os.log

enum SportLog {
    private static let oslog = OSLog(subsystem: "com.loopkit.Loop", category: "SportMode")

    static func event(_ category: String, _ message: String) {
        os_log("%{public}@ %{public}@", log: oslog, type: .default, category, message)
        // `log(...)` is the G7 module's global sink → NSLog + on-screen sink + LogFile.
        log("[\(category)] \(message)")
    }
}
