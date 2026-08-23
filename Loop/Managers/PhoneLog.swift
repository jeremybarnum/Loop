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

    private static var warnedMirrorOff = false   // `queue`-confined

    private static func mirrorToICloud() {
        let fm = FileManager.default
        guard let local = localURL, fm.fileExists(atPath: local.path) else { return }
        // The export copy goes out regardless of the container's mood — it is the channel that
        // exists precisely because the container can fail (or hide) silently.
        LogExportFolder.export(file: local, as: "g7phone-latest.log")
        guard let container = fm.url(forUbiquityContainerIdentifier: nil) else {
            // The silent guard that cost an evening (2026-08-22): every provisioning layer
            // checked green while this returned nil with no trace anywhere. Once per launch.
            if !warnedMirrorOff {
                warnedMirrorOff = true
                event("session", "iCloud mirror OFF — ubiquity container unavailable (signed out, Drive off for this app, or container missing)")
            }
            return
        }
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
        LogExportFolder.export(file: local, as: name)
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
        event("session", "=== Loop phone log START — build \(build) === previous launch \(sinceLast), footprint \(Self.footprintMB), export=\(LogExportFolder.displayName ?? "off")")
        flush()
    }
}


/// A user-chosen, VISIBLE iCloud Drive folder that receives a copy of every log the pipeline
/// mirrors — the remote-observability channel for a user with no Mac.
///
/// WHY THIS EXISTS. The app's own iCloud container syncs perfectly and is invisible in every
/// Drive UI — Finder, Files, iCloud.com — because the public-document-scope registration never
/// takes (confirmed on the bench account 2026-08-22: files synced all week, folder shown
/// nowhere). An ordinary folder has no such failure mode, and an ordinary folder SHARED from
/// the caregiver's account syncs cross-account: the user picks it once, and from then on their
/// logs are on the caregiver's Mac before anyone has to ask for them. That last property is the
/// point — "send me your logs" stops being a step in every remote diagnosis.
///
/// Silent failure is the enemy this file keeps having to relearn (the container mirror's nil
/// guard cost an evening of guessing), so every distinct failure reason logs ONCE per launch,
/// and configuring the folder immediately writes a visible README so success is confirmable in
/// the Files app on the spot.
enum LogExportFolder {
    private static let bookmarkKey = "LogExportFolder.bookmark"
    private static let nameKey = "LogExportFolder.displayName"
    private static let queue = DispatchQueue(label: "com.loopkit.Loop.logExport", qos: .utility)
    private static var warnedReasons = Set<String>()   // queue-confined

    static var isConfigured: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    /// For the settings row and the session banner: "Off", or the folder's name.
    static var displayName: String? { UserDefaults.standard.string(forKey: nameKey) }

    /// Store the picked folder. Returns false only when the bookmark cannot be minted, which
    /// the settings row surfaces rather than pretending success.
    static func set(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bm = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            PhoneLog.event("export", "FAILED to bookmark the picked folder — export not configured")
            return false
        }
        UserDefaults.standard.set(bm, forKey: bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: nameKey)
        PhoneLog.event("export", "log export folder set -> \(url.lastPathComponent)")
        // Prove writability NOW, visibly: a README the user can see in Files the moment they
        // return from the picker. If this file does not appear, setup did not work — no
        // waiting for the next log event to find out.
        let marker = "Loop log sharing is set up. Log files land in this folder automatically.\n"
        exportData(Data(marker.utf8), as: "README — Loop logs.txt")
        return true
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: nameKey)
        PhoneLog.event("export", "log export folder cleared")
    }

    /// Copy `src` into the export folder under `name`, atomic-replace, coordinated (the folder
    /// is expected to be a shared iCloud folder, and NSFileCoordinator is the contract there).
    static func export(file src: URL, as name: String) {
        queue.async { performExport(name: name) { tmp in try? FileManager.default.copyItem(at: src, to: tmp) } }
    }

    private static func exportData(_ data: Data, as name: String) {
        queue.async { performExport(name: name) { tmp in try? data.write(to: tmp) } }
    }

    /// Queue-confined. `fill` writes the payload into the scratch URL.
    private static func performExport(name: String, fill: (URL) -> Void) {
        guard let bm = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let dir = try? URL(resolvingBookmarkData: bm, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            warnOnce("bookmark no longer resolves — folder deleted or share revoked; re-pick in Settings")
            return
        }
        guard dir.startAccessingSecurityScopedResource() else {
            warnOnce("security scope refused — re-pick the folder in Settings")
            return
        }
        defer { dir.stopAccessingSecurityScopedResource() }
        if stale, let fresh = try? dir.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        let fm = FileManager.default
        let tmp = dir.appendingPathComponent(".export-\(name).tmp")
        try? fm.removeItem(at: tmp)
        fill(tmp)
        guard fm.fileExists(atPath: tmp.path) else { warnOnce("scratch write failed"); return }
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: dir.appendingPathComponent(name), options: .forReplacing, error: &coordError) { dst in
            _ = try? fm.replaceItemAt(dst, withItemAt: tmp)
        }
        if let e = coordError { warnOnce("coordinated write failed (\(e.domain)#\(e.code))") }
    }

    private static func warnOnce(_ reason: String) {
        guard warnedReasons.insert(reason).inserted else { return }
        PhoneLog.event("export", "EXPORT FAILED — \(reason) (logged once per launch)")
    }
}
