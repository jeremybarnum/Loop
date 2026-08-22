//
//  PhoneLog.swift
//  Loop
//
//  Phone-side mirrored log — the counterpart to the watch's SportLog (2026-08-05).
//
//  WHY THIS EXISTS. The watch mirrors its log to iCloud, so a whole day's field analysis is a
//  grep away. The phone had nothing: everything it did went to os_log, which is invisible unless
//  someone captures a sysdiagnose or attaches Console. That blind spot blocked TWO separate
//  investigations in a single day:
//
//    • the hand-back stall — was the pod actually released, or did the phone keep holding it?
//      `GRANT +3s released=true` reports a FLAG, never an observed disconnect, and no phone-side
//      record existed to settle it.
//    • the takeover failures — 4 of 6 on build 234, every connect returning connectionLimitReached
//      while the watch's own central held nothing. Two candidates remained (the phone never let
//      go / we exhausted our own slots) and the watch log could not separate them.
//
//  Both needed the phone's own account of what its CoreBluetooth did. Neither could get it.
//
//  DESIGN. Lines append to a local file immediately (cheap); the iCloud mirror is throttled,
//  because url(forUbiquityContainerIdentifier:) can block and a per-line mirror would be absurd.
//  Reuses the serial-queue + atomic-replace discipline WatchDataManager.mirrorLogToICloud learned
//  the hard way (2026-07-20: concurrent mirrors raced and left g7watch-latest.log stale/missing).
//  Named g7phone-*.log so it sits beside g7watch-*.log in the same container without colliding.
//

import Foundation
import os.log

enum PhoneLog {
    private static let oslog = OSLog(subsystem: "com.loopkit.Loop", category: "PhoneLog")

    /// Serial: same reason WatchDataManager's mirror is serial. Interleaved writes corrupt the tail.
    private static let queue = DispatchQueue(label: "com.loopkit.Loop.phoneLog", qos: .utility)
    private static var buffer: [String] = []
    private static var lastMirror = Date.distantPast

    /// Throttle. A phone-side line is cheap; pushing it to iCloud is not.
    private static let mirrorInterval: TimeInterval = 60

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Mirrors SportLog.event's shape so both files read alike and one grep spans the pair.
    static func event(_ category: String, _ message: String) {
        os_log("%{public}@ %{public}@", log: oslog, type: .default, category, message)
        let line = "\(stamp.string(from: Date())) [\(category)] \(message)"
        queue.async {
            buffer.append(line)
            appendLocally(line)
            if Date().timeIntervalSince(lastMirror) > mirrorInterval {
                lastMirror = Date()
                mirrorToICloud()
            }
        }
    }

    /// Force the mirror now — call at moments the analysis will care about (a completed
    /// hand-back, a failed takeover), so the file on the Mac is current when it is looked at
    /// rather than up to a minute behind.
    static func flush() {
        queue.async {
            lastMirror = Date()
            mirrorToICloud()
        }
    }

    // MARK: - Files

    private static var localURL: URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("g7phone-latest.log")
    }

    private static func appendLocally(_ line: String) {
        guard let url = localURL else { return }
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func mirrorToICloud() {
        let fm = FileManager.default
        guard let local = localURL, fm.fileExists(atPath: local.path) else { return }
        guard let container = fm.url(forUbiquityContainerIdentifier: nil) else { return }   // iCloud off
        let dir = container.appendingPathComponent("Documents", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Atomic replace, never remove-then-copy — that is exactly how the watch's latest.log
        // went MISSING rather than merely stale when a crash landed between the two steps.
        let cloudLatest = dir.appendingPathComponent("g7phone-latest.log")
        let tmp = dir.appendingPathComponent(".g7phone-latest.tmp")
        try? fm.removeItem(at: tmp)
        if (try? fm.copyItem(at: local, to: tmp)) != nil {
            _ = try? fm.replaceItemAt(cloudLatest, withItemAt: tmp)
        }
    }

    /// Rotate the outgoing session's g7phone-latest.log to a stamped g7phone-<yyyyMMdd-HHmmss>.log
    /// before startSession truncates it — without this, everything since the last launch was lost
    /// twice over (local remove + the forced first mirror overwriting the cloud copy too) and no
    /// g7phone-*.log snapshot had EVER survived (item B6, field-confirmed 2026-08-13: the container
    /// held 20 g7watch-*.log archives and zero g7phone-*.log). Same latest+stamped+prune scheme as
    /// WatchDataManager.mirrorLogToICloud. Runs on `queue`.
    private static func archivePreviousSession() {
        let fm = FileManager.default
        guard let local = localURL, fm.fileExists(atPath: local.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "g7phone-\(formatter.string(from: Date())).log"
        let dir = local.deletingLastPathComponent()
        try? fm.copyItem(at: local, to: dir.appendingPathComponent(name))
        prune(in: dir)
        guard let container = fm.url(forUbiquityContainerIdentifier: nil) else { return }   // iCloud off
        let cloudDir = container.appendingPathComponent("Documents", isDirectory: true)
        try? fm.createDirectory(at: cloudDir, withIntermediateDirectories: true)
        // Archive from the LOCAL file, not the cloud latest: local is complete to the last
        // append, while the cloud latest can be up to `mirrorInterval` (60s) stale.
        try? fm.copyItem(at: local, to: cloudDir.appendingPathComponent(name))
        prune(in: cloudDir)
    }

    /// Keep newest 20 stamped archives in `dir`; g7phone-latest.log is exempt (it's the rolling
    /// current copy) and the .g7phone-latest.tmp scratch file is excluded by the .log extension
    /// filter. Stamp format sorts lexicographically, so string sort == time sort. Mirrors the
    /// prune in WatchDataManager.mirrorLogToICloud — g7watch- prefix there can't collide with
    /// g7phone- here.
    private static func prune(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let stamped = entries
            .filter { $0.pathExtension == "log" && $0.lastPathComponent.hasPrefix("g7phone-") && $0.lastPathComponent != "g7phone-latest.log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in stamped.dropFirst(20) { try? fm.removeItem(at: old) }
    }

    /// Truncate at launch so the file tracks the current session rather than growing forever —
    /// but archive the outgoing session first (archivePreviousSession), or its content is
    /// destroyed here and then again by the forced mirror below, with nothing ever preserved.
    private static let launchStampKey = "PhoneLog.lastLaunchAt"

    /// Resident footprint in MB, or "?" if the kernel declines. Reported at launch because a
    /// process killed for memory has no opportunity to report anything afterwards.
    private static var footprintMB: String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return "?" }
        return String(format: "%.0f MB", Double(info.phys_footprint) / 1024 / 1024)
    }

    static func startSession(build: String) {
        queue.async {
            archivePreviousSession()   // must precede the remove — last chance to save the prior session
            if let url = localURL { try? FileManager.default.removeItem(at: url) }
            buffer.removeAll()
        }
        // LAUNCH FORENSICS. The line above truncates, so a relaunch that dies immediately leaves
        // an archive containing nothing but its own banner — which is exactly what the field
        // produced on 2026-08-21: three archives, one line each, at 15:44:55, 15:46:32 and
        // 15:48:37. Three launches in four minutes, and the banner alone cannot say whether that
        // was jetsam, a crash, or the user force-quitting.
        //
        // Two numbers make it diagnosable. The gap since the previous launch separates "restarted
        // immediately" from "restarted hours later", and the memory footprint at launch is what
        // distinguishes jetsam from everything else. Neither is inferable after the fact, and the
        // user is only reachable weekly, so an unlogged occurrence is a lost month.
        let previous = UserDefaults.standard.object(forKey: launchStampKey) as? Date
        UserDefaults.standard.set(Date(), forKey: launchStampKey)
        let sinceLast = previous.map { String(format: "%.0fs ago", Date().timeIntervalSince($0)) } ?? "first seen"
        event("session", "=== Loop phone log START — build \(build) === previous launch \(sinceLast), footprint \(Self.footprintMB)")
        flush()
    }
}
