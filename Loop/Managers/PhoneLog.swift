//
//  PhoneLog.swift
//  Loop
//
//  The phone's loan log, beside the watch's SportLog: appended locally at once, mirrored to
//  iCloud (as g7phone-*.log) at most once a minute.
//

import Foundation
import os.log

enum PhoneLog {
    private static let oslog = OSLog(subsystem: "com.loopkit.Loop", category: "PhoneLog")

    /// Serial: concurrent mirrors can leave the mirrored file missing.
    private static let queue = DispatchQueue(label: "com.loopkit.Loop.phoneLog", qos: .utility)
    private static var lastMirror = Date.distantPast

    /// `flush()` overrides it.
    private static let mirrorInterval: TimeInterval = 60

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Categories are grepped by field analysis; keep them stable.
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

    /// Mirror now, ignoring the throttle.
    static func flush() {
        queue.async {
            lastMirror = Date()
            mirrorToICloud()
        }
    }

    /// Tests point the log at their own folder, which also skips the iCloud mirror.
    static var directoryOverride: URL?

    private static var localURL: URL? {
        guard let dir = directoryOverride ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("g7phone-latest.log")
    }

    /// Rotate at 2 MB down to 1 MB, so rotation stays rare.
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    private static let trimToBytes = 1024 * 1024

    /// Failures are swallowed: logging must never disturb a loan.
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

    private static func rotate(_ url: URL) {
        guard let all = try? Data(contentsOf: url), all.count > trimToBytes else { return }
        var slice = all.suffix(trimToBytes)
        // Drop the partial first line so the file always starts on a record boundary.
        if let nl = slice.firstIndex(of: 0x0a) { slice = slice[slice.index(after: nl)...] }
        try? Data(slice).write(to: url)
    }

    private static func mirrorToICloud() {
        guard directoryOverride == nil else { return }
        let fm = FileManager.default
        guard let local = localURL, fm.fileExists(atPath: local.path) else { return }
        guard let container = fm.url(forUbiquityContainerIdentifier: nil) else { return }
        let dir = container.appendingPathComponent("Documents", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Copy then replace, so the container is never without a log.
        let cloudLatest = dir.appendingPathComponent("g7phone-latest.log")
        let tmp = dir.appendingPathComponent(".g7phone-latest.tmp")
        try? fm.removeItem(at: tmp)
        if (try? fm.copyItem(at: local, to: tmp)) != nil {
            _ = try? fm.replaceItemAt(cloudLatest, withItemAt: tmp)
        }
    }
}
