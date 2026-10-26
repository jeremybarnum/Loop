//
//  LowGlucoseWarningAlerter.swift
//  LoopCore
//
//  Delivers the predicted-low warning through Loop's alert system (the device's `AlertIssuer`):
//  "very likely" as critical, the other two as time-sensitive (D3); re-issued with fresh numbers
//  while the verdict holds, no sooner than the snooze setting allows, under one identifier so each
//  replaces the last; withdrawn when the low is no longer predicted (D1). Her wording (D4).
//

import Foundation
import LoopKit

@MainActor
public final class LowGlucoseWarningAlerter {
    public static let managerIdentifier = "LowGlucoseWarning"
    static let alertIdentifier: Alert.AlertIdentifier = "predictedLowWarning"
    static var identifier: Alert.Identifier {
        Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: alertIdentifier)
    }

    private weak var alertIssuer: AlertIssuer?
    private let defaults: UserDefaults

    private static let showingKey = "com.loopkit.Loop.lowBGWarningShowing"

    /// The device's alert issuer and where it keeps the warning's state (the phone: standard
    /// defaults, beside the settings; the watch: its own).
    public init(alertIssuer: AlertIssuer, defaults: UserDefaults) {
        self.alertIssuer = alertIssuer
        self.defaults = defaults
    }

    /// When the last warning went out: the snooze anchor, carried across a loan's start and end.
    public var lastNotificationTime: Date? {
        get { defaults.lowBGWarningLastNotificationTime }
        set { defaults.lowBGWarningLastNotificationTime = newValue }
    }

    /// A warning is showing on this device (persisted, so a relaunch neither repeats nor forgets it).
    public private(set) var isShowing: Bool {
        get { defaults.bool(forKey: Self.showingKey) }
        set { defaults.set(newValue, forKey: Self.showingKey) }
    }

    /// Moves the snooze anchor forward to `date` if it is later (a loan's start or end).
    public func adoptLastNotificationTime(_ date: Date?) {
        defaults.adoptLowBGWarningLastNotificationTime(date)
    }

    /// The settings with this device's snooze anchor, for the decision.
    public func settingsForDecision(_ settings: LowBGWarningSettings) -> LowBGWarningSettings {
        var s = settings
        s.lastNotificationTime = lastNotificationTime
        return s
    }

    /// Acts on one assessment. A skipped assessment (stale data, compression low) changes nothing.
    public func handle(_ assessment: LowGlucoseWarning.Assessment, now: Date, log: (String) -> Void = { _ in }) async {
        guard let decision = assessment.decision else { return }
        if let context = decision.context,
           let message = LowGlucoseWarning.messages(for: decision.outcome, context: context) {
            await issue(title: message.title, body: message.body, critical: decision.outcome == .carbsDefinitelyNeeded)
            lastNotificationTime = now
            log("issued: \(message.title)")
        } else if isShowing, !decision.lowStillPredicted {
            await withdraw()
            log("withdrawn: low no longer predicted")
        }
    }

    /// This device stops warning (the other device holds the pod, or the feature was switched off):
    /// a warning it showed is withdrawn, so no stale one remains.
    public func standDown() async {
        guard isShowing else { return }
        await withdraw()
    }

    /// The settings screen's test: the most urgent verdict's alert, through the same path.
    public func issueTest() async {
        await issue(title: "Very likely low in 20 mins",
                    body: "Take between 10 and 15 carbs. Low will happen even if any old carbs fully absorb. (Test)",
                    critical: true)
    }

    private func issue(title: String, body: String, critical: Bool) async {
        let content = Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK")
        let alert = Alert(identifier: Self.identifier, foregroundContent: content, backgroundContent: content,
                          trigger: .immediate, interruptionLevel: critical ? .critical : .timeSensitive)
        await alertIssuer?.issueAlert(alert)
        isShowing = true
    }

    private func withdraw() async {
        await alertIssuer?.retractAlert(identifier: Self.identifier)
        isShowing = false
    }
}
