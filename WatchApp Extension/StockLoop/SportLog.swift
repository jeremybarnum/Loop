//
//  SportLog.swift
//  WatchApp Extension
//
//  Unified watch-side logging for Sport Mode. The rebuild left the M5 loan protocol
//  and loop on OSLog (system log only) while G7 kept its own file log — so on a
//  TestFlight (distribution-signed) build, whose container isn't reachable via
//  devicectl, the protocol narrative was invisible without a Mac + Console.app.
//
//  SportLog owns the on-device log file (Documents/g7watch.log) and mirrors to the system
//  log. The diagnostics page reads LogFile.tail() and offers a share sheet, so logs can be
//  read and sent from the wrist — no Mac, no devicectl.
//
//  The substrate below (log/LogFile/LogSink/batteryTag) is deliberately here rather than
//  inside any one subsystem: it is the app's logging infrastructure, and hiding it inside a
//  component means that component cannot be removed without taking logging with it.
//
//  Use for MILESTONE events (state transitions, grants, hand-backs, verdicts, radio
//  arbitration, watchdog) — not per-reading spam; the file is size-capped.
//

import Foundation
import os.log
#if os(watchOS)
import WatchKit
#endif


// MARK: - Logging

private let logFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"   // date + time: a log spanning midnight/days must be unambiguous (2026-07-25)
    return f
}()

/// A process-wide sink so the verbatim `log(...)` calls in the ported handshake can be
/// mirrored into the SwiftUI log view without threading a logger through every function.
final class LogSink: @unchecked Sendable {
    static let shared = LogSink()
    var handler: ((String) -> Void)?
}

/// Timestamped logging: to the Xcode console (NSLog) AND to the active client's log view.
func log(_ items: Any...) {
    let msg = items.map { "\($0)" }.joined(separator: " ")
    let line = "\(logFmt.string(from: Date())) \(msg)"
    NSLog("%@", line)
    LogSink.shared.handler?(line)
    LogFile.append(line)
}

/// Battery %/state tag (watchOS only) — for correlating dead-gaps with power throttling.
/// e.g. "pwr 41%/batt", "pwr 88%/chg". Off-wrist + low battery is when the workout keepalive
/// gets throttled, which is exactly when the long read-gaps appear.
func batteryTag() -> String {
    #if os(watchOS)
    let dev = WKInterfaceDevice.current()
    dev.isBatteryMonitoringEnabled = true
    let lvl = dev.batteryLevel
    let st: String
    switch dev.batteryState {
    case .charging:  st = "chg"
    case .full:      st = "full"
    case .unplugged: st = "batt"
    default:         st = "?"
    }
    return lvl < 0 ? "pwr ?/\(st)" : "pwr \(Int(lvl * 100))%/\(st)"
    #else
    return "pwr n/a"
    #endif
}

/// The single on-device log file (Documents/g7watch.log): G7 transport AND — via
/// SportLog — the M5 loan protocol + loop. Read/shared from the diagnostics page
/// (SportLog.tail), so a TestFlight build needs no Mac/devicectl. Size-capped so it
/// can't grow unbounded (the review's unbounded-log finding).
enum LogFile {
    static let url: URL? = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("g7watch.log")

    private static let queue = DispatchQueue(label: "com.loopkit.Loop.LogFile")
    private static let maxBytes: UInt64 = 512 * 1024   // rotate near half a MB
    private static let trimToBytes = 256 * 1024        // keep the most recent quarter-MB

    static func append(_ line: String) {
        guard let url else { return }
        let data = Data((line + "\n").utf8)
        queue.async {
            var size: UInt64 = 0
            if let h = try? FileHandle(forWritingTo: url) {
                size = (try? h.seekToEnd()) ?? 0
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: url)   // first line creates the file
            }
            if size > maxBytes { rotate(url) }
        }
    }

    /// Keep only the most recent `trimToBytes`, cut at a clean line boundary.
    private static func rotate(_ url: URL) {
        guard let all = try? Data(contentsOf: url), all.count > trimToBytes else { return }
        var slice = all.suffix(trimToBytes)
        if let nl = slice.firstIndex(of: 0x0a) { slice = slice[slice.index(after: nl)...] }
        try? Data(slice).write(to: url)
    }

    /// The tail of the log as text, for the on-wrist viewer / share sheet.
    static func tail(maxBytes: Int = 24 * 1024) -> String {
        return queue.sync {
            guard let url, let all = try? Data(contentsOf: url) else { return "" }
            var slice = all.suffix(maxBytes)
            if all.count > maxBytes, let nl = slice.firstIndex(of: 0x0a) {
                slice = slice[slice.index(after: nl)...]
            }
            return String(decoding: slice, as: UTF8.self)
        }
    }
}

enum SportLog {
    private static let oslog = OSLog(subsystem: "com.loopkit.Loop", category: "SportMode")

    static func event(_ category: String, _ message: String) {
        os_log("%{public}@ %{public}@", log: oslog, type: .default, category, message)
        log("[\(category)] \(message)")
    }
}
