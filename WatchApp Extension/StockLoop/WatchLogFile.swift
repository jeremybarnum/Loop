//
//  WatchLogFile.swift
//  WatchApp Extension
//
//  Testing only: Sport Mode's log lines also go to a file on the watch, sent to the phone once at
//  the end of each loan. Its new lines also go to the phone in between: at the end of each loop cycle,
//  when the app leaves the screen, and at a sensor reading 15 minutes after the last send, so a loan
//  that never ends cleanly still leaves its lines on the phone. Not part of the Sport Mode pull requests.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import CoreBluetooth
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

    /// The lines not yet sent to the phone.
    private static let unsent: URL? = url?.deletingLastPathComponent().appendingPathComponent("watch-unsent.log")

    /// Stamped at the call; never blocks the caller.
    static func append(_ line: String) {
        guard let url else { return }
        let data = Data("\(stamp.string(from: Date())) \(line)\n".utf8)
        queue.async {
            write(data, to: url)
            if let unsent { write(data, to: unsent) }
        }
    }

    // MARK: - Sending new lines to the phone

    /// The phone adds files of this kind to its Documents/WatchLogs/watch-live.log.
    static let linesFileKind = "watchLogLines"
    private static let sendQueue = DispatchQueue(label: "com.loopkit.Loop.WatchLogFile.send", qos: .utility)
    private static let backgroundInterval: TimeInterval = 15 * 60
    private static var lastSent = Date.distantPast   // `sendQueue`-confined

    /// At each sensor reading: a send when the last was 15 minutes ago or more, so the lines reach the
    /// phone without Loop being opened.
    static func sendIfDue() {
        sendQueue.async {
            guard Date().timeIntervalSince(lastSent) >= backgroundInterval else { return }
            send()
        }
    }

    static func sendNow() {
        sendQueue.async { send() }
    }

    /// On `sendQueue`. Transfers queue while the phone is out of reach.
    private static func send() {
        let session = WCSession.default
        guard session.activationState == .activated,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        lastSent = Date()
        let directory = caches.appendingPathComponent("WatchLogOut", isDirectory: true)
        // Files whose transfer has finished; the system may still be reading one that is outstanding.
        let outstanding = Set(session.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
        for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where !outstanding.contains(old.lastPathComponent) {
            try? FileManager.default.removeItem(at: old)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = directory.appendingPathComponent("watch-lines-\(UUID().uuidString).log")
        let moved: Bool = queue.sync {
            guard let unsent, FileManager.default.fileExists(atPath: unsent.path) else { return false }
            return (try? FileManager.default.moveItem(at: unsent, to: lines)) != nil
        }
        if moved { session.transferFile(lines, metadata: ["kind": linesFileKind]) }
    }

    /// On `queue`.
    private static func write(_ data: Data, to url: URL) {
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

/// Testing only: one line each time the app's main thread went half a second or more without taking
/// new work, with what the loop's queue was running. watchOS ends the app when a phone message waits
/// too long for the main thread; these lines count how close the app comes, without a crash report.
/// A background timer asks the main thread to answer four times a second and counts the ticks that pass
/// before it does. Ticks, not clock time: a suspended app's timer doesn't fire, so time asleep isn't counted.
enum MainThreadLog {
    private static let queue = DispatchQueue(label: "MainThreadLog", qos: .utility)
    private static let interval = 0.25
    // On `queue`.
    private static var timer: DispatchSourceTimer?
    private static var asked = false
    private static var missed = 0
    // On the main thread.
    @MainActor private static var laneWork: String?
    @MainActor private static var laneWorkEnded: Date?
    @MainActor private static var lastCPU = 0.0

    static func start() {
        queue.async {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
            t.setEventHandler {
                if asked { missed += 1; return }
                asked = true
                DispatchQueue.main.async {
                    let missed: Int = queue.sync { defer { self.missed = 0; asked = false }; return self.missed }
                    MainActor.assumeIsolated { answered(afterMissing: missed) }
                }
            }
            t.resume()
            timer = t
        }
    }

    /// The loop's queue began or finished one piece of work (WatchLoopManager.onLane).
    @MainActor static func laneBegan(_ work: String) { laneWork = work; laneWorkEnded = nil }
    @MainActor static func laneEnded() { laneWorkEnded = Date() }

    @MainActor private static func answered(afterMissing missed: Int) {
        let cpu = mainThreadCPUSeconds()
        defer { lastCPU = cpu }
        guard missed >= 2 else { return }
        let held = Double(missed) * interval
        let during: String
        if let laneWork, let ended = laneWorkEnded {
            during = Date().timeIntervalSince(ended) < held + 2 * interval ? "as the queue finished \(laneWork)" : "queue idle"
        } else if let laneWork {
            during = "while the queue ran \(laneWork)"
        } else {
            during = "queue idle"
        }
        SportLog.event("app", String(format: "main thread held at least %.1f s (its cpu +%.2f s), %@", held, cpu - lastCPU, during))
    }

    /// Processor time the calling thread has used.
    private static func mainThreadCPUSeconds() -> Double {
        var t = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t) == 0 else { return 0 }
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1_000_000_000
    }
}

/// Testing only: one line when the pod or the sensor connects again after a long silence, with how
/// long it was and where the app stood. The watch's Bluetooth can hold every connection while it waits
/// to change its own address, until the screen lights or the app in front wakes; these lines count
/// such gaps without a sysdiagnose.
enum RadioLog {
    private static let lock = NSLock()
    private static var lastReached: [String: Date] = [:]
    private static var place = "launched"
    private static var placeSince = Date()

    static var inFront: Bool { lock.lock(); defer { lock.unlock() }; return place == "in front" }

    /// The app moved: in front, leaving the front, behind the clock, back from behind the clock.
    static func app(_ now: String) {
        lock.lock(); place = now; placeSince = Date(); lock.unlock()
        WatchLogFile.append("[app] \(now)")
    }

    /// The pod or the sensor connected. Silent unless its last connection was over 7 minutes ago.
    static func reached(_ device: String) {
        let now = Date()
        lock.lock()
        let last = lastReached[device]
        lastReached[device] = now
        let (place, since) = (self.place, placeSince)
        lock.unlock()
        guard let last, now.timeIntervalSince(last) > 420 else { return }
        WatchLogFile.append(String(format: "[radio] %@ connected again after %.0f s · app %@ for the last %.0f s",
                                   device, now.timeIntervalSince(last), place, now.timeIntervalSince(since)))
    }
}

/// Testing only: a workaround for a watchOS fault. About every 20 minutes the watch's Bluetooth changes
/// its own address; with a connection pending it holds every connection until its scan is restarted,
/// and with the screen dark and the app behind the clock nothing restarts it. A scan started and
/// stopped by the app restarts it. This is the one place that does so, for the pod and the sensor:
/// when the pod's connection has been pending for a minute, or the app runs behind the clock more
/// than two minutes after the sensor last connected, start and stop a scan, at most once a minute.
/// It is checked when watchOS wakes the app and when the pod is dialed, not on a timer.
/// Two minutes, not an overdue reading: a hold sets between readings, and the wake that could end it
/// (a message from the phone) may come before the next reading is due. Within those two minutes the
/// cycle's own pod connection restarts the scan. A restart with no change waiting does nothing.
final class ScanRestart: NSObject, CBCentralManagerDelegate {
    static let shared = ScanRestart()

    private let queue = DispatchQueue(label: "ScanRestart")
    private var central: CBCentralManager?
    private var podPendingSince: Date?
    private var sensorLastConnected: Date?
    private var lastRestart = Date.distantPast
    /// Matches no device; a scan request is all that is needed.
    private let filter = CBUUID(string: "7B1C0001-5C0A-4E0B-9A57-2F6D0C4E7A10")

    /// No timer: the rule runs when watchOS wakes the app (`appWoken`) and when the pod is dialed.
    /// With the app suspended neither happens, and the rule does nothing.
    func start() {
        queue.async {
            guard self.central == nil else { return }
            self.central = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    /// watchOS handed the app a background task: a message from the phone, or a Bluetooth event.
    func appWoken() { queue.async { self.check() } }

    func podConnectRequested() { queue.async { if self.podPendingSince == nil { self.podPendingSince = Date() }; self.check() } }
    func podConnected() { queue.async { self.podPendingSince = nil } }
    func sensorConnected() { queue.async { self.sensorLastConnected = Date() } }

    private func check() {
        let now = Date()
        let podWait = podPendingSince.map { now.timeIntervalSince($0) } ?? 0
        let sensorWait = sensorLastConnected.map { now.timeIntervalSince($0) } ?? 0
        guard podWait > 60 || (sensorWait > 120 && !RadioLog.inFront) else { return }
        guard now.timeIntervalSince(lastRestart) > 60 else { return }
        guard let central, central.state == .poweredOn else {
            WatchLogFile.append("[radio] scan restart wanted but Bluetooth is not ready")
            return
        }
        lastRestart = now
        WatchLogFile.append(String(format: "[radio] scan restart: pod pending %.0f s, sensor silent %.0f s", podWait, sensorWait))
        central.scanForPeripherals(withServices: [filter], options: nil)
        queue.asyncAfter(deadline: .now() + 1) { central.stopScan() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}
}
