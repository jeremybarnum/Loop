//
//  LowBGWarningSettings.swift
//  LoopCore
//
//  The predicted-low warning's settings as one value: what the phone's Alert Management screen
//  stores, what a loan grant hands the watch, and what the decision reads. Glucose values are
//  mg/dL, as the settings screen shows them.
//

import Foundation
import LoopAlgorithm

public struct LowBGWarningSettings: Codable, Equatable {
    /// The master switch. Off means no predicted-low warning on either device.
    public var enabled: Bool
    /// Whether warnings are allowed during the night window at all.
    public var nightWarningsEnabled: Bool
    /// Subtracted from the suspend threshold to get the warning level, mg/dL.
    public var dayWarningOffset: Double
    public var nightWarningOffset: Double
    /// Minimum gap between two warnings.
    public var warningSnooze: TimeInterval
    /// Don't warn about a low that is closer than this — too late to act on usefully.
    public var dontWarnIfSooner: TimeInterval
    /// ...or farther away than this — too speculative.
    public var dontWarnIfLater: TimeInterval
    /// Suppress most verdicts for this long after a carb entry, so declaring a meal doesn't
    /// immediately warn about the low it is already treating.
    public var delayAfterCarbEntry: TimeInterval
    /// Night window as minutes since local midnight; wrapping past midnight is expected.
    public var nightStartMinutes: Int
    public var nightEndMinutes: Int
    /// When the last warning went out, so the snooze carries across a loan's start and end. nil = never.
    public var lastNotificationTime: Date?

    public init(enabled: Bool = false, nightWarningsEnabled: Bool = false,
                dayWarningOffset: Double = 5, nightWarningOffset: Double = 10,
                warningSnooze: TimeInterval = 9 * 60, dontWarnIfSooner: TimeInterval = 5 * 60,
                dontWarnIfLater: TimeInterval = 45 * 60, delayAfterCarbEntry: TimeInterval = 30 * 60,
                nightStartMinutes: Int = 22 * 60 + 30, nightEndMinutes: Int = 6 * 60 + 30,
                lastNotificationTime: Date? = nil) {
        self.enabled = enabled
        self.nightWarningsEnabled = nightWarningsEnabled
        self.dayWarningOffset = dayWarningOffset
        self.nightWarningOffset = nightWarningOffset
        self.warningSnooze = warningSnooze
        self.dontWarnIfSooner = dontWarnIfSooner
        self.dontWarnIfLater = dontWarnIfLater
        self.delayAfterCarbEntry = delayAfterCarbEntry
        self.nightStartMinutes = nightStartMinutes
        self.nightEndMinutes = nightEndMinutes
        self.lastNotificationTime = lastNotificationTime
    }

    /// The night test, including the wrap case where the window crosses midnight.
    public func isNightTime(at date: Date, calendar: Calendar = .current) -> Bool {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if nightStartMinutes <= nightEndMinutes {
            return minutes >= nightStartMinutes && minutes <= nightEndMinutes
        } else {
            return minutes >= nightStartMinutes || minutes <= nightEndMinutes
        }
    }

    /// Her warning replaces the predicted-low alert of Loop's glucose alerts: that one is not
    /// evaluated and its setting is hidden. One switch, so turning it back on is one line.
    public static let replacesGlucoseAlertsPredictedLow = true
}

// MARK: - Stored on the phone (the Alert Management screen's keys, as on the production line)

extension UserDefaults {
    private enum LowBGWarningKey: String {
        case enabled = "com.loopkit.Loop.lowBGNotificationsEnabled"
        case nightEnabled = "com.loopkit.Loop.nightLowBGNotificationsEnabled"
        case dayOffset = "com.loopkit.Loop.dayWarningOffset"
        case nightOffset = "com.loopkit.Loop.nightWarningOffset"
        case snooze = "com.loopkit.Loop.warningSnooze"
        case sooner = "com.loopkit.Loop.dontWarnIfSooner"
        case later = "com.loopkit.Loop.dontWarnIfLater"
        case carbDelay = "com.loopkit.Loop.delayAfterCarbEntry"
        case lastWarning = "com.loopkit.Loop.lowBGWarningLastNotificationTime"
    }

    /// Minutes and mg/dL as the settings screen stores them; nil keys read as the defaults.
    public var lowBGWarningSettings: LowBGWarningSettings {
        get {
            let d = LowBGWarningSettings()
            func minutes(_ key: LowBGWarningKey, _ fallback: TimeInterval) -> TimeInterval {
                (object(forKey: key.rawValue) as? Int).map { TimeInterval($0) * 60 } ?? fallback
            }
            func mgdl(_ key: LowBGWarningKey, _ fallback: Double) -> Double {
                (object(forKey: key.rawValue) as? Int).map(Double.init) ?? fallback
            }
            return LowBGWarningSettings(
                enabled: object(forKey: LowBGWarningKey.enabled.rawValue) as? Bool ?? d.enabled,
                nightWarningsEnabled: object(forKey: LowBGWarningKey.nightEnabled.rawValue) as? Bool ?? d.nightWarningsEnabled,
                dayWarningOffset: mgdl(.dayOffset, d.dayWarningOffset),
                nightWarningOffset: mgdl(.nightOffset, d.nightWarningOffset),
                warningSnooze: minutes(.snooze, d.warningSnooze),
                dontWarnIfSooner: minutes(.sooner, d.dontWarnIfSooner),
                dontWarnIfLater: minutes(.later, d.dontWarnIfLater),
                delayAfterCarbEntry: minutes(.carbDelay, d.delayAfterCarbEntry),
                lastNotificationTime: object(forKey: LowBGWarningKey.lastWarning.rawValue) as? Date)
        }
        set {
            set(newValue.enabled, forKey: LowBGWarningKey.enabled.rawValue)
            set(newValue.nightWarningsEnabled, forKey: LowBGWarningKey.nightEnabled.rawValue)
            set(Int(newValue.dayWarningOffset), forKey: LowBGWarningKey.dayOffset.rawValue)
            set(Int(newValue.nightWarningOffset), forKey: LowBGWarningKey.nightOffset.rawValue)
            set(Int(newValue.warningSnooze / 60), forKey: LowBGWarningKey.snooze.rawValue)
            set(Int(newValue.dontWarnIfSooner / 60), forKey: LowBGWarningKey.sooner.rawValue)
            set(Int(newValue.dontWarnIfLater / 60), forKey: LowBGWarningKey.later.rawValue)
            set(Int(newValue.delayAfterCarbEntry / 60), forKey: LowBGWarningKey.carbDelay.rawValue)
            set(newValue.lastNotificationTime, forKey: LowBGWarningKey.lastWarning.rawValue)
        }
    }

    /// When the last predicted-low warning went out on this device: the snooze anchor.
    public var lowBGWarningLastNotificationTime: Date? {
        get { object(forKey: LowBGWarningKey.lastWarning.rawValue) as? Date }
        set { set(newValue, forKey: LowBGWarningKey.lastWarning.rawValue) }
    }

    /// Moves the snooze anchor forward to `date` if it is later (the other device warned more recently).
    public func adoptLowBGWarningLastNotificationTime(_ date: Date?) {
        guard let date else { return }
        if lowBGWarningLastNotificationTime.map({ date > $0 }) ?? true { lowBGWarningLastNotificationTime = date }
    }
}
