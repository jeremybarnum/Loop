//
//  WatchLogFile.swift
//  WatchApp Extension
//
//  Testing only: Sport Mode's log lines also go to a file on the watch, sent to the phone once at
//  the end of each loan (nothing is sent during a loan). Not part of the Sport Mode pull requests.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import WatchConnectivity
import WatchKit

enum WatchLogFile {
    static let url: URL? = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("watch.log")

    /// What the phone looks for on an incoming file.
    static let fileKind = "watchLog"

    /// Serial, so lines cannot interleave and a send never copies a half-finished trim.
    private static let queue = DispatchQueue(label: "com.loopkit.Loop.WatchLogFile")
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    private static let trimToBytes = 1024 * 1024

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Stamped at the call; never blocks the caller.
    static func append(_ line: String) {
        guard let url else { return }
        let data = Data("\(stamp.string(from: Date())) \(line)\n".utf8)
        queue.async {
            var size: UInt64 = 0
            if let handle = try? FileHandle(forWritingTo: url) {
                size = (try? handle.seekToEnd()) ?? 0
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
            if size > maxBytes { trim(url) }
        }
    }

    /// Keeps the newest bytes, starting on a line boundary.
    private static func trim(_ url: URL) {
        guard let all = try? Data(contentsOf: url), all.count > trimToBytes else { return }
        var slice = all.suffix(trimToBytes)
        if let newline = slice.firstIndex(of: 0x0a) { slice = slice[slice.index(after: newline)...] }
        try? Data(slice).write(to: url)
    }

    /// A loan message's kind, without its contents: "statusQuery", "doseRecordBatch".
    static func kind(of message: Any) -> String {
        Mirror(reflecting: message).children.first?.label ?? String(describing: message)
    }

    /// The battery, for the once-a-cycle line: "pwr 83%/batt", "/chg" while charging; "?" when unknown.
    @MainActor static func batteryTag() -> String {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let state: String
        switch device.batteryState {
        case .charging: state = "chg"
        case .full: state = "full"
        case .unplugged: state = "batt"
        default: state = "?"
        }
        return device.batteryLevel < 0 ? "pwr ?/\(state)" : "pwr \(Int(device.batteryLevel * 100))%/\(state)"
    }

    /// A copy of the file to the phone, queued by WatchConnectivity until the phone can take it.
    static func sendToPhone(_ reason: String) {
        SportLog.event("log", "watch log to the iPhone: \(reason)")
        queue.async {
            guard WCSession.default.activationState == .activated, let url,
                  let copy = try? copyForTransfer(url) else { return }
            WCSession.default.transferFile(copy, metadata: ["kind": fileKind])
        }
    }

    /// The transfer reads the file later, so it gets a copy the log can't change under it.
    private static func copyForTransfer(_ url: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString).log")
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}

/// Testing only: where the watch's power goes. A line every 10 seconds while the app runs (a suspended
/// app's timer doesn't fire, so a long gap between lines is time asleep), and at each wake and loop
/// cycle: the battery, the app's state, its processor time and wakeups since the last line, and how
/// many frames the glucose chart drew.
@MainActor
enum PowerLog {
    private static var timer: DispatchSourceTimer?
    private static var last: (at: Date, cpu: Double, interrupts: UInt64, idle: UInt64, timers: UInt64, frames: Int)?
    private static var chartFrames = 0

    static func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
        t.setEventHandler { MainActor.assumeIsolated { note("tick") } }
        t.resume()
        timer = t
        note("launch")
    }

    static func noteChartFrame() {
        chartFrames += 1
    }

    static func note(_ reason: String) {
        let now = Date()
        let cpu = cpuSeconds()
        let power = wakeups()
        let state: String
        switch WKApplication.shared().applicationState {
        case .active: state = "in front, screen on"
        case .inactive: state = "in front, screen off or covered"
        case .background: state = "in the background"
        @unknown default: state = "unknown"
        }
        var line = "\(reason) · \(WatchLogFile.batteryTag()) · app \(state) · cpu \(String(format: "%.1f", cpu)) s"
        if let last {
            let seconds = now.timeIntervalSince(last.at)
            line += String(format: " · since the last line (%.0f s): cpu +%.2f s, wakeups +%llu (timer +%llu, idle +%llu), chart frames +%d",
                           seconds, cpu - last.cpu, power.interrupts &- last.interrupts, power.timers &- last.timers,
                           power.idle &- last.idle, chartFrames - last.frames)
        }
        last = (now, cpu, power.interrupts, power.idle, power.timers, chartFrames)
        SportLog.event("power", line)
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func wakeups() -> (interrupts: UInt64, idle: UInt64, timers: UInt64) {
        var info = task_power_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }
        return (info.task_interrupt_wakeups, info.task_platform_idle_wakeups, info.task_timer_wakeups_bin_1 &+ info.task_timer_wakeups_bin_2)
    }
}
