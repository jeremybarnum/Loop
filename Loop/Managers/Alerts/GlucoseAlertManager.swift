//
//  GlucoseAlertManager.swift
//  Loop
//
//  Multi-profile glucose alert system modelled after Dexcom G7.
//  Users have a Primary profile (always present) plus any number of
//  additional profiles (e.g. "Night", "Exercise"). Each additional
//  profile can be manually activated or auto-scheduled by day-of-week
//  + time window. The active profile's thresholds govern all alerts.
//

import Combine
import Foundation
import LoopAlgorithm
import LoopKit
import os.log

// MARK: - Configuration

struct GlucoseAlertConfiguration: Equatable, Codable {
    var lowThresholdMgDL: Double
    var urgentLowThresholdMgDL: Double
    var highThresholdMgDL: Double

    /// BG must cross this many mg/dL past the threshold before re-arming.
    var recoveryMarginMgDL: Double

    var lowRepeatInterval: TimeInterval
    var urgentLowRepeatInterval: TimeInterval
    var highRepeatInterval: TimeInterval

    var lowEnabled: Bool
    var urgentLowEnabled: Bool
    var highEnabled: Bool

    var lowSnoozeEnabled: Bool
    var highSnoozeEnabled: Bool

    var predictedLowEnabled: Bool
    var predictedLowThresholdMgDL: Double
    var predictedLowHorizon: TimeInterval

    static let `default` = GlucoseAlertConfiguration(
        lowThresholdMgDL: 70,
        urgentLowThresholdMgDL: 55,
        highThresholdMgDL: 180,
        recoveryMarginMgDL: 5,
        lowRepeatInterval: 30 * 60,
        urgentLowRepeatInterval: 5 * 60,
        highRepeatInterval: 30 * 60,
        lowEnabled: true,
        urgentLowEnabled: true,
        highEnabled: true,
        lowSnoozeEnabled: false,
        highSnoozeEnabled: false,
        predictedLowEnabled: true,
        predictedLowThresholdMgDL: 60,
        predictedLowHorizon: 20 * 60
    )
}

// MARK: - Schedule settings

/// Auto-schedule for a non-primary profile.
/// When enabled, the profile activates at `startMinuteOfDay` on each
/// `activeDays` weekday and deactivates at `stopMinuteOfDay`.
/// An overnight window (stop < start) spans into the next calendar day.
struct GlucoseAlertScheduleSettings: Equatable, Codable {
    var enabled: Bool
    /// 0 = Sunday … 6 = Saturday.
    var activeDays: Set<Int>
    var startMinuteOfDay: Int
    var stopMinuteOfDay: Int

    static let `default` = GlucoseAlertScheduleSettings(
        enabled: false,
        activeDays: Set(0...6),
        startMinuteOfDay: 22 * 60,
        stopMinuteOfDay: 9 * 60
    )

    func isActive(at date: Date) -> Bool {
        guard enabled, !activeDays.isEmpty else { return false }
        let cal = Calendar.current
        let comps = cal.dateComponents([.weekday, .hour, .minute], from: date)
        let weekday = (comps.weekday ?? 1) - 1
        let currentMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

        if startMinuteOfDay < stopMinuteOfDay {
            guard activeDays.contains(weekday) else { return false }
            return currentMinute >= startMinuteOfDay && currentMinute < stopMinuteOfDay
        } else {
            if currentMinute >= startMinuteOfDay {
                return activeDays.contains(weekday)
            } else {
                let prevWeekday = (weekday + 6) % 7
                return activeDays.contains(prevWeekday) && currentMinute < stopMinuteOfDay
            }
        }
    }
}

// MARK: - Profile

struct GlucoseAlertProfile: Equatable, Codable, Identifiable {
    var id: UUID
    var name: String
    var configuration: GlucoseAlertConfiguration
    var scheduleSettings: GlucoseAlertScheduleSettings

    static func makePrimary() -> GlucoseAlertProfile {
        GlucoseAlertProfile(id: UUID(), name: "Primary", configuration: .default, scheduleSettings: .default)
    }

    static func makeSecondary(basedOn config: GlucoseAlertConfiguration = .default) -> GlucoseAlertProfile {
        GlucoseAlertProfile(
            id: UUID(),
            name: "Night",
            configuration: config,
            scheduleSettings: .default
        )
    }
}

// MARK: - Manager

@MainActor
final class GlucoseAlertManager: ObservableObject {
    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "GlucoseAlertManager")

    static let managerIdentifier = "GlucoseAlertManager"
    static let lowAlertIdentifier: Alert.AlertIdentifier = "glucose.low"
    static let urgentLowAlertIdentifier: Alert.AlertIdentifier = "glucose.urgentLow"
    static let highAlertIdentifier: Alert.AlertIdentifier = "glucose.high"
    static let predictedLowAlertIdentifier: Alert.AlertIdentifier = "glucose.predictedLow"

    private static let profilesKey = "GlucoseAlertProfiles"
    private static let activeProfileIDKey = "GlucoseAlertActiveProfileID"
    private static let overrideKey = "GlucoseAlertLoopOverride"
    private static let legacyConfigKey = "GlucoseAlertConfiguration"
    private static let legacyPrimaryKey = "GlucoseAlertPrimaryConfig"
    private static let legacyAlternateKey = "GlucoseAlertAlternateProfile"
    // Keys written by intermediate WIP builds — never part of a release, must be
    // cleaned up on first launch so stale data can't interfere with CGM restoration.
    private static let wipeOnMigrationKeys: [String] = [
        "GlucoseAlertSchedules",
        "GlucoseAlertActiveScheduleIndex",
    ]

    private let alertIssuer: AlertIssuer
    private let userDefaults: UserDefaults

    /// Ordered list of profiles; `profiles[0]` is always Primary.
    @Published var profiles: [GlucoseAlertProfile] {
        didSet { guard profiles != oldValue else { return }; persistProfiles() }
    }

    /// ID of the currently-active profile.
    @Published var activeProfileID: UUID {
        didSet {
            guard activeProfileID != oldValue else { return }
            userDefaults.set(activeProfileID.uuidString, forKey: Self.activeProfileIDKey)
        }
    }

    @Published var loopAlertsOverrideForOwnAlertingCGM: Bool {
        didSet { userDefaults.set(loopAlertsOverrideForOwnAlertingCGM, forKey: Self.overrideKey) }
    }

    @Published var cgmProvidesOwnAlerts: Bool = false

    var effectiveLoopAlertsEnabled: Bool {
        !cgmProvidesOwnAlerts || loopAlertsOverrideForOwnAlertingCGM
    }

    // MARK: - Profile access

    var primaryProfile: GlucoseAlertProfile { profiles[0] }

    func profile(id: UUID) -> GlucoseAlertProfile? {
        profiles.first { $0.id == id }
    }

    func activeProfile(at date: Date = Date()) -> GlucoseAlertProfile {
        profile(id: activeProfileID) ?? primaryProfile
    }

    func activeConfiguration(at date: Date = Date()) -> GlucoseAlertConfiguration {
        activeProfile(at: date).configuration
    }

    // MARK: - Profile management

    func activate(profileID: UUID) {
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        activeProfileID = profileID
    }

    func addProfile() -> UUID {
        let base = activeProfile().configuration
        let new = GlucoseAlertProfile.makeSecondary(basedOn: base)
        profiles.append(new)
        return new.id
    }

    func removeProfile(id: UUID) {
        guard profiles.count > 1, profiles[0].id != id else { return }
        if activeProfileID == id { activeProfileID = profiles[0].id }
        profiles.removeAll { $0.id == id }
    }

    // MARK: - Scheduling

    /// Per-profile tracking of whether we were in the scheduled window on the last check.
    private var wasInScheduledWindow: [UUID: Bool] = [:]

    private func checkSchedule(at now: Date) {
        for profile in profiles.dropFirst() {
            guard profile.scheduleSettings.enabled else { continue }
            let inWindow = profile.scheduleSettings.isActive(at: now)
            let wasIn = wasInScheduledWindow[profile.id] ?? false

            if inWindow && !wasIn && activeProfileID == primaryProfile.id {
                os_log("Schedule: activating profile '%{public}@'", log: log, type: .info, profile.name)
                activeProfileID = profile.id
            } else if !inWindow && wasIn && activeProfileID == profile.id {
                os_log("Schedule: deactivating profile '%{public}@'", log: log, type: .info, profile.name)
                activeProfileID = primaryProfile.id
            }
            wasInScheduledWindow[profile.id] = inWindow
        }
    }

    // MARK: - Next transition label

    func nextTransitionLabel(for profileID: UUID, at now: Date = Date()) -> String? {
        guard let profile = profile(id: profileID), profile.scheduleSettings.enabled else { return nil }
        guard let transition = nextScheduledTransition(settings: profile.scheduleSettings, at: now) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE h:mm a"
        let dateStr = fmt.string(from: transition.at)
        return transition.activating
            ? "Scheduled to turn on: \(dateStr)"
            : "Scheduled to turn off: \(dateStr)"
    }

    private func nextScheduledTransition(
        settings: GlucoseAlertScheduleSettings,
        at now: Date
    ) -> (activating: Bool, at: Date)? {
        let cal = Calendar.current
        let currentlyInWindow = settings.isActive(at: now)

        for dayOffset in 0...8 {
            guard let candidateDay = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let weekday = cal.component(.weekday, from: candidateDay) - 1

            if settings.activeDays.contains(weekday),
               let startDate = minuteDate(settings.startMinuteOfDay, on: candidateDay, cal: cal),
               startDate > now, !currentlyInWindow {
                return (activating: true, at: startDate)
            }

            let isStopDay: Bool
            if settings.startMinuteOfDay < settings.stopMinuteOfDay {
                isStopDay = settings.activeDays.contains(weekday)
            } else {
                isStopDay = settings.activeDays.contains((weekday + 6) % 7)
            }
            if isStopDay,
               let stopDate = minuteDate(settings.stopMinuteOfDay, on: candidateDay, cal: cal),
               stopDate > now, currentlyInWindow {
                return (activating: false, at: stopDate)
            }
        }
        return nil
    }

    private func minuteDate(_ minuteOfDay: Int, on day: Date, cal: Calendar) -> Date? {
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        comps.second = 0
        return cal.date(from: comps)
    }

    func formatMinuteOfDay(_ minuteOfDay: Int) -> String {
        var comps = DateComponents()
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        guard let date = Calendar.current.date(from: comps) else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }

    // MARK: - Hysteresis

    private struct AlertState: Equatable {
        var inBoundary: Bool = false
        var lastFiredAt: Date?
    }
    private var lowState = AlertState()
    private var urgentLowState = AlertState()
    private var highState = AlertState()
    private var predictedLowInEpisode = false
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var pendingTestUrgentLow: Bool = false

    // MARK: - Init

    init(alertIssuer: AlertIssuer, userDefaults: UserDefaults = .standard) {
        self.alertIssuer = alertIssuer
        self.userDefaults = userDefaults

        var loadedProfiles: [GlucoseAlertProfile]
        var migratedOverride = false
        var didMigrate = false

        if let data = userDefaults.data(forKey: Self.profilesKey),
           let saved = try? JSONDecoder().decode([GlucoseAlertProfile].self, from: data), !saved.isEmpty {
            loadedProfiles = saved
        } else {
            didMigrate = true
            // Migration from the v1 flat format (single GlucoseAlertConfiguration with
            // loopAlertsOverrideForOwnAlertingCGM embedded) or the two-profile WIP format.
            var primary = GlucoseAlertProfile.makePrimary()
            if let data = userDefaults.data(forKey: Self.legacyPrimaryKey),
               let cfg = try? JSONDecoder().decode(GlucoseAlertConfiguration.self, from: data) {
                primary.configuration = cfg
            } else if let data = userDefaults.data(forKey: Self.legacyConfigKey),
                      let cfg = try? JSONDecoder().decode(GlucoseAlertConfiguration.self, from: data) {
                primary.configuration = cfg
                // v1 stored loopAlertsOverrideForOwnAlertingCGM inside the config blob.
                if let override = (try? JSONDecoder().decode(LegacyV1Config.self, from: data))?.loopAlertsOverrideForOwnAlertingCGM {
                    migratedOverride = override
                }
            }
            loadedProfiles = [primary]

            if let data = userDefaults.data(forKey: Self.legacyAlternateKey),
               let alt = try? JSONDecoder().decode(LegacyAlternateProfile.self, from: data) {
                var secondary = GlucoseAlertProfile.makeSecondary(basedOn: alt.configuration)
                secondary.name = alt.name
                secondary.scheduleSettings = alt.scheduleSettings
                loadedProfiles.append(secondary)
            }
        }

        self.profiles = loadedProfiles

        let savedIDStr = userDefaults.string(forKey: Self.activeProfileIDKey)
        let savedID = savedIDStr.flatMap(UUID.init)
        if let id = savedID, loadedProfiles.contains(where: { $0.id == id }) {
            self.activeProfileID = id
        } else {
            self.activeProfileID = loadedProfiles[0].id
        }

        self.loopAlertsOverrideForOwnAlertingCGM = didMigrate && migratedOverride
            ? migratedOverride
            : userDefaults.bool(forKey: Self.overrideKey)

        if didMigrate {
            // Write new format and erase all legacy + WIP keys atomically so
            // stale data from intermediate builds can never cause decode failures
            // or interfere with CGM restoration on subsequent launches.
            if let data = try? JSONEncoder().encode(loadedProfiles) {
                userDefaults.set(data, forKey: Self.profilesKey)
            }
            let keysToRemove = [Self.legacyConfigKey, Self.legacyPrimaryKey, Self.legacyAlternateKey]
                + Self.wipeOnMigrationKeys
            for key in keysToRemove { userDefaults.removeObject(forKey: key) }
        }

        NotificationCenter.default.publisher(for: .LoopCycleCompleted)
            .sink { [weak self] notification in
                guard let predicted = (notification.object as? LoopDataManager)?.predictedGlucose else { return }
                Task { @MainActor in await self?.evaluatePredictedGlucose(predicted) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Test support

    func armTestUrgentLowOnNextReading() {
        pendingTestUrgentLow = true
        os_log("Test: armed", log: log, type: .info)
    }

    func cancelTestUrgentLow() { pendingTestUrgentLow = false }

    // MARK: - Persistence

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        userDefaults.set(data, forKey: Self.profilesKey)
    }

    // MARK: - Evaluation

    func evaluate(samples: [NewGlucoseSample], now: Date = Date()) async {
        guard effectiveLoopAlertsEnabled else { return }
        checkSchedule(at: now)
        guard let latest = samples.max(by: { $0.date < $1.date }) else { return }
        guard now.timeIntervalSince(latest.date) < 6 * 60 else {
            os_log("Skipping stale sample", log: log, type: .debug)
            return
        }
        let config = activeConfiguration(at: now)
        let mgdl: Double
        if pendingTestUrgentLow {
            mgdl = max(20, config.urgentLowThresholdMgDL - 5)
            pendingTestUrgentLow = false
        } else {
            mgdl = latest.quantity.doubleValue(for: .milligramsPerDeciliter)
        }
        await evaluateLow(mgdl: mgdl, config: config, now: now)
        await evaluateUrgentLow(mgdl: mgdl, config: config, now: now)
        await evaluateHigh(mgdl: mgdl, config: config, now: now)
    }

    private func evaluateLow(mgdl: Double, config: GlucoseAlertConfiguration, now: Date) async {
        guard config.lowEnabled else { return }
        let threshold = config.lowThresholdMgDL
        if mgdl < threshold {
            let alert = decideAndUpdate(
                state: &lowState, identifier: Self.lowAlertIdentifier, interruptionLevel: .timeSensitive,
                title: "Low Glucose",
                body: "Glucose is below \(Int(threshold)) mg/dL (current: \(Int(mgdl)))",
                repeatInterval: config.lowSnoozeEnabled ? config.lowRepeatInterval : nil, now: now
            )
            if let alert { await alertIssuer.issueAlert(alert) }
        } else if mgdl > threshold + config.recoveryMarginMgDL {
            if let id = takeRetractID(state: &lowState, identifier: Self.lowAlertIdentifier) {
                await alertIssuer.retractAlert(identifier: id)
            }
        }
    }

    private func evaluateUrgentLow(mgdl: Double, config: GlucoseAlertConfiguration, now: Date) async {
        guard config.urgentLowEnabled else { return }
        let threshold = config.urgentLowThresholdMgDL
        if mgdl < threshold {
            let alert = decideAndUpdate(
                state: &urgentLowState, identifier: Self.urgentLowAlertIdentifier, interruptionLevel: .critical,
                title: "Urgent Low Glucose",
                body: "Glucose is below \(Int(threshold)) mg/dL (current: \(Int(mgdl))). Treat now.",
                repeatInterval: config.urgentLowRepeatInterval, now: now
            )
            if let alert { await alertIssuer.issueAlert(alert) }
        } else if mgdl > threshold + config.recoveryMarginMgDL {
            if let id = takeRetractID(state: &urgentLowState, identifier: Self.urgentLowAlertIdentifier) {
                await alertIssuer.retractAlert(identifier: id)
            }
        }
    }

    private func evaluateHigh(mgdl: Double, config: GlucoseAlertConfiguration, now: Date) async {
        guard config.highEnabled else { return }
        let threshold = config.highThresholdMgDL
        if mgdl > threshold {
            let alert = decideAndUpdate(
                state: &highState, identifier: Self.highAlertIdentifier, interruptionLevel: .timeSensitive,
                title: "High Glucose",
                body: "Glucose is above \(Int(threshold)) mg/dL (current: \(Int(mgdl)))",
                repeatInterval: config.highSnoozeEnabled ? config.highRepeatInterval : nil, now: now
            )
            if let alert { await alertIssuer.issueAlert(alert) }
        } else if mgdl < threshold - config.recoveryMarginMgDL {
            if let id = takeRetractID(state: &highState, identifier: Self.highAlertIdentifier) {
                await alertIssuer.retractAlert(identifier: id)
            }
        }
    }

    private func takeRetractID(state: inout AlertState, identifier: Alert.AlertIdentifier) -> Alert.Identifier? {
        let wasActive = state.inBoundary
        state = AlertState()
        guard wasActive else { return nil }
        return Alert.Identifier(managerIdentifier: Self.managerIdentifier, alertIdentifier: identifier)
    }

    func evaluatePredictedGlucose(_ predicted: [PredictedGlucoseValue], now: Date = Date()) async {
        guard effectiveLoopAlertsEnabled else { return }
        let config = activeConfiguration(at: now)
        guard config.predictedLowEnabled else { return }
        let horizonEnd = now.addingTimeInterval(config.predictedLowHorizon)
        let threshold = config.predictedLowThresholdMgDL
        let crossesLow = predicted.contains {
            $0.startDate > now && $0.startDate <= horizonEnd
                && $0.quantity.doubleValue(for: .milligramsPerDeciliter) < threshold
        }
        if !crossesLow {
            if predictedLowInEpisode {
                predictedLowInEpisode = false
                await alertIssuer.retractAlert(
                    identifier: Alert.Identifier(managerIdentifier: Self.managerIdentifier, alertIdentifier: Self.predictedLowAlertIdentifier)
                )
            }
            return
        }
        guard !predictedLowInEpisode else { return }
        predictedLowInEpisode = true
        let alert = Alert(
            identifier: Alert.Identifier(managerIdentifier: Self.managerIdentifier, alertIdentifier: Self.predictedLowAlertIdentifier),
            foregroundContent: Alert.Content(
                title: "Predicted Low Glucose",
                body: "Loop predicts glucose below \(Int(threshold)) mg/dL within \(Int(config.predictedLowHorizon / 60)) min.",
                acknowledgeActionButtonLabel: "OK"),
            backgroundContent: Alert.Content(
                title: "Predicted Low Glucose",
                body: "Loop predicts glucose below \(Int(threshold)) mg/dL within \(Int(config.predictedLowHorizon / 60)) min.",
                acknowledgeActionButtonLabel: "OK"),
            trigger: .immediate, interruptionLevel: .timeSensitive, sound: .sound(name: "alert.caf")
        )
        await alertIssuer.issueAlert(alert)
    }

    private func decideAndUpdate(
        state: inout AlertState, identifier: Alert.AlertIdentifier,
        interruptionLevel: Alert.InterruptionLevel,
        title: String, body: String, repeatInterval: TimeInterval?, now: Date
    ) -> Alert? {
        let shouldFire: Bool
        if !state.inBoundary {
            shouldFire = true
        } else if let repeatInterval, let last = state.lastFiredAt, now.timeIntervalSince(last) >= repeatInterval {
            shouldFire = true
        } else {
            shouldFire = false
        }
        state.inBoundary = true
        guard shouldFire else { return nil }
        state.lastFiredAt = now
        return Alert(
            identifier: Alert.Identifier(managerIdentifier: Self.managerIdentifier, alertIdentifier: identifier),
            foregroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
            backgroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
            trigger: .immediate, interruptionLevel: interruptionLevel,
            sound: interruptionLevel == .critical ? .sound(name: "critical.caf") : .sound(name: "alert.caf")
        )
    }
}

// MARK: - Legacy migration shims

/// v1 stored loopAlertsOverrideForOwnAlertingCGM inside GlucoseAlertConfiguration.
/// Decode only the one field we need to migrate.
private struct LegacyV1Config: Codable {
    var loopAlertsOverrideForOwnAlertingCGM: Bool?
}

private struct LegacyAlternateProfile: Codable {
    var name: String
    var configuration: GlucoseAlertConfiguration
    var scheduleSettings: GlucoseAlertScheduleSettings
}
