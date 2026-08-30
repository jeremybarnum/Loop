//
//  CrashRecoveryManager.swift
//  Loop
//
//  Created by Pete Schwamb on 9/17/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import LoopAlgorithm

class CrashRecoveryManager {

    private let log = DiagnosticLog(category: "CrashRecoveryManager")

    let managerIdentifier = "CrashRecoveryManager"

    private let crashAlertIdentifier = "CrashAlert"

    var doseRecoveredFromCrash: AutomaticDoseRecommendation?

    let alertIssuer: AlertIssuer

    var pendingCrashRecovery: Bool {
        return doseRecoveredFromCrash != nil
    }

    /// A stable identifier for the current boot (kern.bootsessionuuid) — changes on every
    /// device restart. Stored beside the in-flight marker so the launch check can tell a
    /// process death from a PHONE restart and label the dialog honestly (ruled 2026-08-29).
    private static var bootSessionUUID: String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    init(alertIssuer: AlertIssuer) {
        self.alertIssuer = alertIssuer

        doseRecoveredFromCrash = UserDefaults.appGroup?.inFlightAutomaticDose

        if doseRecoveredFromCrash != nil {
            // A marker written in a PREVIOUS boot session means the phone restarted (power
            // off, forced restart) — not an app crash. Same pause, same acknowledgment,
            // honest words: "Loop Crashed" after a deliberate shutdown trains the user to
            // ignore the dialog on the day it reports a real crash.
            let markerBootSession = UserDefaults.appGroup?.inFlightDoseBootSession
            let phoneRestarted = markerBootSession != nil && markerBootSession != Self.bootSessionUUID
            issueCrashAlert(phoneRestarted: phoneRestarted)
        }
    }

    func dosingStarted(dose: AutomaticDoseRecommendation) {
        UserDefaults.appGroup?.inFlightAutomaticDose = dose
        UserDefaults.appGroup?.inFlightDoseBootSession = Self.bootSessionUUID
    }

    func dosingFinished() {
        UserDefaults.appGroup?.inFlightAutomaticDose = nil
        UserDefaults.appGroup?.inFlightDoseBootSession = nil
    }

    private func issueCrashAlert(phoneRestarted: Bool) {
        let title = phoneRestarted
            ? NSLocalizedString("Loop Interrupted", comment: "Title for dose-interrupted-by-restart recovery alert")
            : NSLocalizedString("Loop Crashed", comment: "Title for crash recovery alert")
        let modalBody = phoneRestarted
            ? NSLocalizedString("The phone restarted while Loop was completing a dose command, so insulin adjustments have been paused until this dialog is closed. Dosing history may be missing that last command. Please review Insulin Delivery charts.", comment: "Modal body for dose-interrupted-by-restart recovery alert")
            : NSLocalizedString("Oh no! Loop crashed while dosing, and insulin adjustments have been paused until this dialog is closed. Dosing history may not be accurate. Please review Insulin Delivery charts, and monitor your blood glucose carefully.", comment: "Modal body for crash recovery alert")
        let modalContent = Alert.Content(title: title,
                                         body: modalBody,
                                         acknowledgeActionButtonLabel: NSLocalizedString("Continue", comment: "Default alert dismissal"))
        let notificationBody = NSLocalizedString("Insulin adjustments have been disabled!", comment: "Notification body for crash recovery alert")
        let notificationContent = Alert.Content(title: title,
                                                body: notificationBody,
                                                acknowledgeActionButtonLabel: NSLocalizedString("Continue", comment: "Default alert dismissal"))

        let identifier = Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: crashAlertIdentifier)

        let alert = Alert(identifier: identifier,
                         foregroundContent: modalContent,
                         backgroundContent: notificationContent,
                         trigger: .immediate,
                         interruptionLevel: .critical)

        Task {
            await self.alertIssuer.issueAlert(alert)
        }
    }
}

extension CrashRecoveryManager: AlertResponder {
    func acknowledgeAlert(alertIdentifier: LoopKit.Alert.AlertIdentifier) async throws {
        UserDefaults.appGroup?.inFlightAutomaticDose = nil
        doseRecoveredFromCrash = nil
    }
}

