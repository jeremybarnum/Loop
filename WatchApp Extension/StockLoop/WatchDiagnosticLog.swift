//
//  WatchDiagnosticLog.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import os.log

/// A watch-side stand-in for the phone app's `DiagnosticLog`.
///
/// It exists so the observed-absorption sources compile into this target UNMODIFIED. Those files
/// live in the phone app and log through `DiagnosticLog`, which in turn depends on the phone's
/// `DiagnosticLog+Subsystem` and `SharedLogging` — none of which the watch links. Providing the
/// same small surface here means the absorption ALGORITHM has exactly one copy shared by both
/// devices, rather than a retyped wrist edition free to drift from the phone's. Same reasoning as
/// the loan protocol compiling into four targets from one file.
///
/// Deliberately not an exact clone: there is no `SharedLogging` mirror, and every line is also
/// appended to `SportLog` so absorption-ratio arithmetic lands in the same greppable wrist log as
/// the rest of a loan instead of only in the system log, which is far harder to pull off a watch.
public class DiagnosticLog {

    private let category: String
    private let log: OSLog

    public init(subsystem: String, category: String) {
        self.category = category
        self.log = OSLog(subsystem: subsystem, category: category)
    }

    public convenience init(category: String) {
        self.init(subsystem: "com.loopkit.Loop.watch", category: category)
    }

    public func debug(_ message: StaticString, _ args: CVarArg...) {
        emit(message, type: .debug, args)
    }

    public func info(_ message: StaticString, _ args: CVarArg...) {
        emit(message, type: .info, args)
    }

    public func `default`(_ message: StaticString, _ args: CVarArg...) {
        emit(message, type: .default, args)
    }

    public func error(_ message: StaticString, _ args: CVarArg...) {
        emit(message, type: .error, args)
    }

    private func emit(_ message: StaticString, type: OSLogType, _ args: [CVarArg]) {
        switch args.count {
        case 0: os_log(message, log: log, type: type)
        case 1: os_log(message, log: log, type: type, args[0])
        case 2: os_log(message, log: log, type: type, args[0], args[1])
        case 3: os_log(message, log: log, type: type, args[0], args[1], args[2])
        case 4: os_log(message, log: log, type: type, args[0], args[1], args[2], args[3])
        case 5: os_log(message, log: log, type: type, args[0], args[1], args[2], args[3], args[4])
        default: os_log(message, log: log, type: type, args)
        }

        // The wrist mirror renders the format string RAW and appends the arguments beside it,
        // rather than running String(format:) over a caller-supplied format. That is deliberate:
        // a specifier that does not match its argument is a crash, and no diagnostic line is worth
        // taking down the device that is currently driving the pod.
        let rendered = args.isEmpty
            ? message.description
            : message.description + " · " + args.map { String(describing: $0) }.joined(separator: " ")
        SportLog.event(category, rendered)
    }
}
