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

    /// Rotate near 2 MB, keeping the most recent 1 MB — the same shape as the watch's LogFile
    /// (512 KB / 256 KB there), sized for the phone's slower growth (~1.2 MB a week). Without
    /// this the file grew without bound: the only truncation path was a session start that was
    /// never called.
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    private static let trimToBytes = 1024 * 1024

    private static func appendLocally(_ line: String) {
        guard let url = localURL else { return }
        let data = Data((line + "\n").utf8)
        var size: UInt64 = 0
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            size = (try? handle.seekToEnd()) ?? 0
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        if size > maxBytes { rotate(url) }
    }

    /// Keep only the most recent `trimToBytes`, cut at a clean line boundary.
    private static func rotate(_ url: URL) {
        guard let all = try? Data(contentsOf: url), all.count > trimToBytes else { return }
        var slice = all.suffix(trimToBytes)
        if let nl = slice.firstIndex(of: 0x0a) { slice = slice[slice.index(after: nl)...] }
        try? Data(slice).write(to: url)
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
}
