//
//  GlucoseAlertManager.swift
//  Loop
//
//  Evaluates new CGM samples against user-configured thresholds and
//  fires Loop alerts when glucose crosses below/above them.
//
//  Built because the LibreLoop integration (and other community CGM
//  paths like Nightscout Remote CGM and ShareClient) doesn't piggyback
//  on a vendor app that provides its own glucose alerts — so Loop has
//  to. CGM plugins that DO provide native alerts (e.g. Dexcom G6/G7
//  via the Dexcom app) will eventually have a per-source opt-out
//  toggle so users aren't double-alerted; v1 fires for all sources.
//
//  Glucose-level prediction alerts ("predicted low in 20 min") will
//  source from Loop's existing dosing forecast rather than running a
//  parallel predictor; that wire-up lands in a follow-up.
//

import Combine
import Foundation
import LoopAlgorithm
import LoopKit
import os.log

/// Threshold + behavior configuration for the glucose alert types.
/// Persisted via UserDefaults; settings UI mutates a published copy
/// on `GlucoseAlertManager` which then writes back.
struct GlucoseAlertConfiguration: Equatable, Codable {
    var lowThresholdMgDL: Double
    var urgentLowThresholdMgDL: Double
    var highThresholdMgDL: Double

    /// Hysteresis band: BG must rise this far above the low threshold
    /// (or drop this far below the high threshold) before the alert can
    /// re-arm. Prevents flapping at the boundary.
    var recoveryMarginMgDL: Double

    /// Re-fire interval if BG stays beyond the threshold without
    /// recovery. Matches Dexcom's pattern: gentler cadence for low/high,
    /// aggressive 5-min cadence for urgent low.
    var lowRepeatInterval: TimeInterval
    var urgentLowRepeatInterval: TimeInterval
    var highRepeatInterval: TimeInterval

    var lowEnabled: Bool
    var urgentLowEnabled: Bool
    var highEnabled: Bool

    /// Snooze (= "repeat if still beyond threshold") for low/high alerts.
    /// Default off, matching Dexcom — a single-fire-on-crossing is what
    /// most users want; turn this on to re-fire at `lowRepeatInterval` /
    /// `highRepeatInterval` while glucose stays out of range.
    /// Urgent low is always-on for safety (its repeat is non-optional).
    var lowSnoozeEnabled: Bool
    var highSnoozeEnabled: Bool

    /// User opt-in to receive Loop glucose alerts even when the current
    /// CGM provides its own native alerting. Ignored (treated as true)
    /// when the CGM doesn't provide own alerts — Loop is the only thing
    /// that can alert in that case. Default false: don't double-alert.
    var loopAlertsOverrideForOwnAlertingCGM: Bool

    /// Predicted-low alert: fires when Loop's dosing forecast says
    /// glucose will dip below `predictedLowThresholdMgDL` within
    /// `predictedLowHorizon`. Single-fire per episode (re-arms only
    /// after a cycle predicts no-low-in-horizon).
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
        loopAlertsOverrideForOwnAlertingCGM: false,
        predictedLowEnabled: true,
        predictedLowThresholdMgDL: 60,
        predictedLowHorizon: 20 * 60
    )
}

@MainActor
final class GlucoseAlertManager: ObservableObject {
    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "GlucoseAlertManager")

    static let managerIdentifier = "GlucoseAlertManager"

    static let lowAlertIdentifier: Alert.AlertIdentifier = "glucose.low"
    static let urgentLowAlertIdentifier: Alert.AlertIdentifier = "glucose.urgentLow"
    static let highAlertIdentifier: Alert.AlertIdentifier = "glucose.high"
    static let predictedLowAlertIdentifier: Alert.AlertIdentifier = "glucose.predictedLow"

    private static let userDefaultsKey = "GlucoseAlertConfiguration"

    private let alertIssuer: AlertIssuer
    private let userDefaults: UserDefaults

    @Published var configuration: GlucoseAlertConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            persistConfiguration()
        }
    }

    /// Live snapshot of whether the currently-active CGM does its own
    /// glucose-level alerting (G7 via Dexcom app, etc.). Set by
    /// DeviceDataManager whenever the CGM changes. The settings view
    /// uses this to ghost the per-alert controls and explain in the
    /// info banner.
    @Published var cgmProvidesOwnAlerts: Bool = false

    /// Whether Loop should actually fire glucose alerts right now.
    /// True unless the CGM provides its own alerts AND the user hasn't
    /// opted into the double-alert override.
    var effectiveLoopAlertsEnabled: Bool {
        if !cgmProvidesOwnAlerts { return true }
        return configuration.loopAlertsOverrideForOwnAlertingCGM
    }

    /// Per-alert hysteresis state. `inBoundary` is true when the most
    /// recent sample was on the alarm side of the threshold WITHOUT
    /// crossing back over the recovery margin since. `lastFiredAt`
    /// stamps the last time we issued the alert so the repeat-interval
    /// timer can decide whether to re-fire on a still-bad sample.
    private struct AlertState: Equatable {
        var inBoundary: Bool = false
        var lastFiredAt: Date?
    }
    private var lowState = AlertState()
    private var urgentLowState = AlertState()
    private var highState = AlertState()

    /// Predictive-low episode tracking. True while the most recent
    /// dosing forecast contained a sample below the predicted-low
    /// threshold within the configured horizon. Re-arms (resets to
    /// false) when a subsequent forecast clears.
    private var predictedLowInEpisode = false
    private var cancellables = Set<AnyCancellable>()

    init(alertIssuer: AlertIssuer, userDefaults: UserDefaults = .standard) {
        self.alertIssuer = alertIssuer
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.userDefaultsKey),
           let loaded = try? JSONDecoder().decode(GlucoseAlertConfiguration.self, from: data) {
            self.configuration = loaded
        } else {
            self.configuration = .default
        }

        // Loop posts .LoopCycleCompleted with the LoopDataManager as
        // the notification object after each dosing cycle. Use that to
        // evaluate the predictive-low alert against the freshly-computed
        // forecast.
        NotificationCenter.default.publisher(for: .LoopCycleCompleted)
            .sink { [weak self] notification in
                guard let predicted = (notification.object as? LoopDataManager)?.predictedGlucose else { return }
                Task { @MainActor in
                    await self?.evaluatePredictedGlucose(predicted)
                }
            }
            .store(in: &cancellables)
    }

    private func persistConfiguration() {
        guard let data = try? JSONEncoder().encode(configuration) else {
            os_log("Failed to encode GlucoseAlertConfiguration", log: log, type: .error)
            return
        }
        userDefaults.set(data, forKey: Self.userDefaultsKey)
    }

    /// Evaluate a batch of newly-ingested CGM samples. Only the latest
    /// (by date) is checked — alerting on stale backfill samples would
    /// be misleading. Caller should pass the freshly-received samples
    /// from `cgmManager(_:hasNew:)`.
    func evaluate(samples: [NewGlucoseSample], now: Date = Date()) async {
        guard effectiveLoopAlertsEnabled else { return }
        guard let latest = samples.max(by: { $0.date < $1.date }) else { return }
        // Don't alert on samples that are stale by the time we see them
        // (e.g. backfill catching up after a reconnect).
        guard now.timeIntervalSince(latest.date) < 6 * 60 else {
            os_log("Skipping alert evaluation for stale sample (age %{public}.0fs)",
                   log: log, type: .debug,
                   now.timeIntervalSince(latest.date))
            return
        }

        let mgdl = latest.quantity.doubleValue(for: .milligramsPerDeciliter)
        await evaluateLow(mgdl: mgdl, now: now)
        await evaluateUrgentLow(mgdl: mgdl, now: now)
        await evaluateHigh(mgdl: mgdl, now: now)
    }

    // MARK: - Per-alert evaluation

    private func evaluateLow(mgdl: Double, now: Date) async {
        guard configuration.lowEnabled else { return }
        let threshold = configuration.lowThresholdMgDL
        let recovery = threshold + configuration.recoveryMarginMgDL

        if mgdl < threshold {
            let alert = decideAndUpdate(
                state: &lowState,
                identifier: Self.lowAlertIdentifier,
                interruptionLevel: .timeSensitive,
                title: "Low Glucose",
                body: "Glucose is below \(Int(threshold)) mg/dL (current: \(Int(mgdl)))",
                repeatInterval: configuration.lowSnoozeEnabled ? configuration.lowRepeatInterval : nil,
                now: now
            )
            if let alert { await alertIssuer.issueAlert(alert) }
        } else if mgdl > recovery {
            if let retract = takeRetractIdentifier(state: &lowState, identifier: Self.lowAlertIdentifier) {
                await alertIssuer.retractAlert(identifier: retract)
            }
        }
    }

    private func evaluateUrgentLow(mgdl: Double, now: Date) async {
        guard configuration.urgentLowEnabled else { return }
        let threshold = configuration.urgentLowThresholdMgDL
        let recovery = threshold + configuration.recoveryMarginMgDL

        if mgdl < threshold {
            let alert = decideAndUpdate(
                state: &urgentLowState,
                identifier: Self.urgentLowAlertIdentifier,
                interruptionLevel: .critical,
                title: "Urgent Low Glucose",
                body: "Glucose is below \(Int(threshold)) mg/dL (current: \(Int(mgdl))). Treat now.",
                repeatInterval: configuration.urgentLowRepeatInterval,
                now: now
            )
            if let alert { await alertIssuer.issueAlert(alert) }
        } else if mgdl > recovery {
            if let retract = takeRetractIdentifier(state: &urgentLowState, identifier: Self.urgentLowAlertIdentifier) {
                await alertIssuer.retractAlert(identifier: retract)
            }
        }
    }

    private func evaluateHigh(mgdl: Double, now: Date) async {
        guard configuration.highEnabled else { return }
        let threshold = configuration.highThresholdMgDL
        let recovery = threshold - configuration.recoveryMarginMgDL

        if mgdl > threshold {
            let alert = decideAndUpdate(
                state: &highState,
                identifier: Self.highAlertIdentifier,
                interruptionLevel: .timeSensitive,
                title: "High Glucose",
                body: "Glucose is above \(Int(threshold)) mg/dL (current: \(Int(mgdl)))",
                repeatInterval: configuration.highSnoozeEnabled ? configuration.highRepeatInterval : nil,
                now: now
            )
            if let alert { await alertIssuer.issueAlert(alert) }
        } else if mgdl < recovery {
            if let retract = takeRetractIdentifier(state: &highState, identifier: Self.highAlertIdentifier) {
                await alertIssuer.retractAlert(identifier: retract)
            }
        }
    }

    /// Reset hysteresis state synchronously and return the alert
    /// identifier to retract (if any) so the caller can await
    /// `alertIssuer.retractAlert(_:)` outside the inout mutation —
    /// inout state can't survive a suspension under Swift 6.
    private func takeRetractIdentifier(state: inout AlertState, identifier: Alert.AlertIdentifier) -> Alert.Identifier? {
        let wasActive = state.inBoundary
        state = AlertState()
        guard wasActive else { return nil }
        os_log("Recovery: retracting %{public}@ alert", log: log, type: .info, identifier)
        return Alert.Identifier(managerIdentifier: Self.managerIdentifier, alertIdentifier: identifier)
    }

    /// Evaluate Loop's dosing forecast for an upcoming low excursion.
    /// Fires once per episode: when a forecast first contains a sample
    /// below the predicted-low threshold within the configured horizon.
    /// Re-arms when a subsequent forecast clears.
    func evaluatePredictedGlucose(_ predicted: [PredictedGlucoseValue], now: Date = Date()) async {
        guard effectiveLoopAlertsEnabled else { return }
        guard configuration.predictedLowEnabled else { return }

        let horizonEnd = now.addingTimeInterval(configuration.predictedLowHorizon)
        let threshold = configuration.predictedLowThresholdMgDL

        let crossesLow = predicted.contains { value in
            guard value.startDate > now, value.startDate <= horizonEnd else { return false }
            return value.quantity.doubleValue(for: .milligramsPerDeciliter) < threshold
        }

        if !crossesLow {
            // Forecast cleared — re-arm and retract any visible alert.
            if predictedLowInEpisode {
                predictedLowInEpisode = false
                os_log("Recovery: retracting predicted-low alert", log: log, type: .info)
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
                body: "Loop predicts glucose below \(Int(threshold)) mg/dL within \(Int(configuration.predictedLowHorizon / 60)) min.",
                acknowledgeActionButtonLabel: "OK"
            ),
            backgroundContent: Alert.Content(
                title: "Predicted Low Glucose",
                body: "Loop predicts glucose below \(Int(threshold)) mg/dL within \(Int(configuration.predictedLowHorizon / 60)) min.",
                acknowledgeActionButtonLabel: "OK"
            ),
            trigger: .immediate,
            interruptionLevel: .timeSensitive,
            sound: .sound(name: "alert.caf")
        )
        os_log("Issuing predicted-low alert", log: log, type: .info)
        await alertIssuer.issueAlert(alert)
    }

    /// Decide whether to fire and mutate hysteresis state synchronously.
    /// Returns the alert to issue, or nil if suppressed. Caller awaits
    /// `alertIssuer.issueAlert(_:)` separately so the inout mutation
    /// here doesn't cross a suspension point.
    ///
    /// `repeatInterval == nil` means single-fire-on-crossing: once
    /// fired, never repeats until BG recovers across the threshold.
    /// `repeatInterval == N` means re-fire every N seconds while still
    /// on the alarm side (the "snooze" behavior).
    private func decideAndUpdate(
        state: inout AlertState,
        identifier: Alert.AlertIdentifier,
        interruptionLevel: Alert.InterruptionLevel,
        title: String,
        body: String,
        repeatInterval: TimeInterval?,
        now: Date
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

        os_log("Issuing %{public}@ alert", log: log, type: .info, identifier)
        return Alert(
            identifier: Alert.Identifier(managerIdentifier: Self.managerIdentifier, alertIdentifier: identifier),
            foregroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
            backgroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
            trigger: .immediate,
            interruptionLevel: interruptionLevel,
            sound: interruptionLevel == .critical ? .sound(name: "critical.caf") : .sound(name: "alert.caf")
        )
    }
}
