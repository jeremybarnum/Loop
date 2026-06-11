//
//  CriticalAlertAlarmScheduler.swift
//  Loop
//
//  On iOS 26+ builds without the Critical Alerts entitlement, this schedules
//  an AlarmKit alarm as the audible critical-alert channel instead of the
//  AVAudioPlayer + AVAudioSession + volume-booster + vibration hack in
//  CriticalAlertAudioPlayer. AlarmKit breaks through the silent switch, Focus
//  and Do Not Disturb with a system-rendered alarm, and is far more reliable
//  than driving the system volume ourselves.
//
//  Requires the user to grant AlarmKit authorization (requested during
//  onboarding). When AlarmKit is unavailable (iOS < 26) or unauthorized,
//  callers fall back to CriticalAlertAudioPlayer.
//

import Foundation
import LoopKit
import os.log

#if canImport(AlarmKit)
import AlarmKit
import struct SwiftUI.Color   // Color only; `import SwiftUI` would make `Alert` ambiguous with LoopKit.Alert
#endif

@MainActor
final class CriticalAlertAlarmScheduler {
    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "CriticalAlertAlarmScheduler")

    /// Maps an issued alert to the AlarmKit alarm scheduled for it, so the
    /// alarm can be cancelled when the alert is acknowledged or retracted.
    private var alarmsByAlert: [Alert.Identifier: UUID] = [:]

    /// True only if AlarmKit is available (iOS 26+) AND the user authorized it.
    /// When false, callers should use the CriticalAlertAudioPlayer fallback.
    var isAuthorizedAndAvailable: Bool {
        guard #available(iOS 26, *) else { return false }
        #if canImport(AlarmKit)
        return AlarmManager.shared.authorizationState == .authorized
        #else
        return false
        #endif
    }

    /// Request AlarmKit authorization if it hasn't been decided yet. Called
    /// during onboarding. No-op below iOS 26 or once already granted/denied.
    static func requestAuthorization() async {
        guard #available(iOS 26, *) else { return }
        #if canImport(AlarmKit)
        guard AlarmManager.shared.authorizationState == .notDetermined else { return }
        do {
            _ = try await AlarmManager.shared.requestAuthorization()
        } catch {
            os_log("AlarmKit authorization request failed: %{public}@",
                   log: OSLog(subsystem: "com.loopkit.Loop", category: "CriticalAlertAlarmScheduler"),
                   type: .error, String(describing: error))
        }
        #endif
    }

    /// Schedule an immediate AlarmKit alarm for the alert. Returns true if an
    /// alarm was scheduled (so the caller skips the audio fallback), false if
    /// AlarmKit isn't usable and the caller should fall back.
    @discardableResult
    func scheduleAlarm(for alert: Alert) -> Bool {
        guard #available(iOS 26, *), isAuthorizedAndAvailable else { return false }
        #if canImport(AlarmKit)
        // Replace any existing alarm for this alert.
        cancelAlarm(for: alert.identifier)

        let title = alert.backgroundContent.title

        let stopButton = AlarmButton(
            text: LocalizedStringResource(stringLiteral: NSLocalizedString("Stop", comment: "Stop button on the AlarmKit critical alarm")),
            textColor: .white,
            systemImageName: "stop.circle"
        )
        let presentation = AlarmPresentation(
            alert: AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: title),
                stopButton: stopButton
            )
        )
        let attributes = AlarmAttributes<EmptyAlarmMetadata>(presentation: presentation, tintColor: .red)

        // Fire immediately. No countdownDuration (preAlert nil) → alert-only,
        // so no Widget Extension / Live Activity is required. Default alarm
        // sound (our .caf alarm sounds aren't guaranteed AlarmKit-compatible).
        let configuration = AlarmManager.AlarmConfiguration<EmptyAlarmMetadata>.alarm(schedule: .fixed(Date()), attributes: attributes)

        let id = UUID()
        alarmsByAlert[alert.identifier] = id
        let log = self.log
        let identifier = alert.identifier
        Task {
            do {
                _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
                os_log("Scheduled AlarmKit alarm %{public}@ for %{public}@", log: log, type: .info, id.uuidString, String(describing: identifier))
            } catch {
                os_log("Failed to schedule AlarmKit alarm for %{public}@: %{public}@", log: log, type: .error, String(describing: identifier), String(describing: error))
            }
        }
        return true
        #else
        return false
        #endif
    }

    /// Cancel/stop the AlarmKit alarm scheduled for the given alert, if any.
    func cancelAlarm(for identifier: Alert.Identifier) {
        guard #available(iOS 26, *) else { return }
        #if canImport(AlarmKit)
        guard let id = alarmsByAlert.removeValue(forKey: identifier) else { return }
        // stop() ends a ringing alarm; cancel() removes a scheduled one. The
        // alarm may be in either state, so try both and ignore errors.
        try? AlarmManager.shared.stop(id: id)
        try? AlarmManager.shared.cancel(id: id)
        os_log("Cancelled AlarmKit alarm %{public}@ for %{public}@", log: log, type: .info, id.uuidString, String(describing: identifier))
        #endif
    }
}

#if canImport(AlarmKit)
/// Minimal metadata for Loop critical-alert alarms. We present an alert-only
/// alarm (no countdown / custom Live Activity), so this carries nothing.
@available(iOS 26, *)
struct EmptyAlarmMetadata: AlarmMetadata {
    init() {}
}
#endif
