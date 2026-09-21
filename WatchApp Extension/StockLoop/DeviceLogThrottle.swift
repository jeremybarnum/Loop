//
//  DeviceLogThrottle.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

final class DeviceLogThrottle {
    static let window: TimeInterval = 2.0

    enum Verdict: Equatable {
        case write(flushing: Int)

        case suppress
    }

    private let lock = NSLock()
    private var lastLine = ""
    private var lastAt = Date.distantPast
    private var suppressedCount = 0

    func admit(_ line: String, at now: Date) -> Verdict {
        lock.lock()
        defer { lock.unlock() }

        if line == lastLine, now.timeIntervalSince(lastAt) < Self.window {
            suppressedCount += 1

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
