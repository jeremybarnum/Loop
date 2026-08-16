//
//  DeviceLogThrottle.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// Collapses identical device-log lines so a BLE retry storm cannot jam the log.
///
/// A Code=11 connect-retry loop once pushed ~2,000 identical lines per second through the device
/// log — each one a synchronous NSLog plus a file append — which starved MAIN hard enough to
/// freeze the glance and rotated every piece of real evidence out of the log inside a second.
/// The BLE-layer backoff makes that storm cold; this makes even a future one cheap AND still
/// readable: an identical repeat inside the window is COUNTED rather than written, and the count
/// is flushed onto the next different line so the gap is stated instead of silent. Distinct lines
/// pass through untouched.
///
/// Its own type rather than four fields on WatchLoopManager: the lock and the three pieces of
/// state exist for nothing else, and inline they could not be tested — a throttle whose failure
/// mode is "the log eats everything during the exact incident you need the log for" is worth
/// being able to test.
final class DeviceLogThrottle {

    /// How long an identical line stays collapsed. Long enough to absorb a storm, short enough
    /// that a genuinely repeating condition still reports itself a few times a minute.
    static let window: TimeInterval = 2.0

    /// What the caller should do with the line it just built.
    enum Verdict: Equatable {
        /// Write it. `flushing` is how many identical predecessors were suppressed — zero when
        /// nothing was — and the caller reports that BEFORE the line, so a suppressed run is
        /// visible in the log rather than a silent hole.
        case write(flushing: Int)
        /// An identical line inside the window. Already counted; write nothing.
        case suppress
    }

    private let lock = NSLock()
    private var lastLine = ""
    private var lastAt = Date.distantPast
    private var suppressedCount = 0

    /// Thread-safe: the device-log delegate is called from whichever queue the CGM or pump
    /// manager happens to be on, and during a storm from several at once.
    func admit(_ line: String, at now: Date) -> Verdict {
        lock.lock()
        defer { lock.unlock() }

        if line == lastLine, now.timeIntervalSince(lastAt) < Self.window {
            suppressedCount += 1
            // The window slides on every repeat: a sustained storm stays collapsed rather than
            // punching one line through every 2 s.
            lastAt = now
            return .suppress
        }

        let flushing = suppressedCount
        suppressedCount = 0
        lastLine = line
        lastAt = now
        return .write(flushing: flushing)
    }
}
