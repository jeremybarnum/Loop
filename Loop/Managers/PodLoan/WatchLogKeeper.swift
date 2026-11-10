//
//  WatchLogKeeper.swift
//  Loop
//
//  Testing only: the watch's log, sent at the end of each loan, kept in Documents/WatchLogs (the
//  latest and the 20 before it) and added to the Loop Report; and the lines it sends in between, in
//  watch-live.log there. Not part of the Sport Mode pull requests.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import WatchConnectivity

enum WatchLogKeeper {
    static let fileKind = "watchLog"
    private static let keep = 20

    private static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WatchLogs")
    }
    private static var latest: URL { folder.appendingPathComponent("watch-latest.log") }

    /// Copied at once: the system deletes the incoming file when the delegate call returns.
    static func keep(_ file: WCSessionFile) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        try? fm.copyItem(at: file.fileURL, to: folder.appendingPathComponent("watch-\(formatter.string(from: Date())).log"))
        try? fm.removeItem(at: latest)
        try? fm.copyItem(at: file.fileURL, to: latest)
        let stamped = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("watch-2") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in stamped.dropFirst(keep) { try? fm.removeItem(at: old) }
    }

    // MARK: - The watch's lines sent in between

    /// The watch's `WatchLogFile.linesFileKind`.
    static let linesFileKind = "watchLogLines"
    private static var live: URL { folder.appendingPathComponent("watch-live.log") }

    /// The watch's new lines, sent at each of its loop cycles and from the background, added to
    /// watch-live.log so a loan that never ends cleanly still leaves its lines here. Read at once:
    /// the system deletes the incoming file when the delegate call returns.
    static func keepLines(_ file: WCSessionFile) {
        guard let data = try? Data(contentsOf: file.fileURL), !data.isEmpty else { return }
        phoneQueue.async { append(data, to: live) }
    }

    // MARK: - The phone's own Sport Mode lines

    private static var phoneLog: URL { folder.appendingPathComponent("phone.log") }
    private static let phoneQueue = DispatchQueue(label: "com.loopkit.Loop.PhoneLogFile")
    private static let phoneMaxBytes: UInt64 = 2 * 1024 * 1024
    private static let phoneTrimToBytes = 1024 * 1024
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Every Sport Mode line the phone logs, stamped at the call; never blocks the caller.
    static func appendPhoneLine(_ line: String) {
        let data = Data("\(stamp.string(from: Date())) \(line)\n".utf8)
        phoneQueue.async {
            append(data, to: phoneLog)
        }
    }

    /// On `phoneQueue`. Past 2 MB the file keeps its newest 1 MB, starting on a line boundary.
    private static func append(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var size: UInt64 = 0
        if let handle = try? FileHandle(forWritingTo: url) {
            size = (try? handle.seekToEnd()) ?? 0
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        guard size > phoneMaxBytes, let all = try? Data(contentsOf: url) else { return }
        var slice = all.suffix(phoneTrimToBytes)
        if let newline = slice.firstIndex(of: 0x0a) { slice = slice[slice.index(after: newline)...] }
        try? Data(slice).write(to: url)
    }

    /// The phone's Sport Mode lines, then the latest watch log, for the Loop Report.
    static func reportSection() -> String {
        let phone = phoneQueue.sync { (try? String(contentsOf: phoneLog, encoding: .utf8)) ?? "* none yet" }
        return "## Phone Sport Mode log\n\n" + phone + "\n" + watchSection()
    }

    /// The latest watch log.
    private static func watchSection() -> String {
        guard let text = try? String(contentsOf: latest, encoding: .utf8) else {
            return "## Watch log\n* none received yet (the watch sends it at the end of each loan)"
        }
        let received = (try? FileManager.default.attributesOfItem(atPath: latest.path)[.modificationDate] as? Date)
            .map { String(describing: $0) } ?? "unknown"
        return "## Watch log\n* received: \(received)\n\n" + text
    }
}
