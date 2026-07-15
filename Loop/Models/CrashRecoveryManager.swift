//
//  CrashRecoveryManager.swift
//  Loop
//
//  Created by Pete Schwamb on 9/17/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

class CrashRecoveryManager {

    private let log = DiagnosticLog(category: "CrashRecoveryManager")

    let managerIdentifier = "CrashRecoveryManager"

    private let crashAlertIdentifier = "CrashAlert"

    var doseRecoveredFromCrash: AutomaticDoseRecommendation?

    let alertIssuer: AlertIssuer

    var pendingCrashRecovery: Bool {
        return doseRecoveredFromCrash != nil
    }

    init(alertIssuer: AlertIssuer) {
        self.alertIssuer = alertIssuer

        doseRecoveredFromCrash = UserDefaults.appGroup?.inFlightAutomaticDose

        // SHOW-MODE fix: a watch-loan grant can strand `inFlightAutomaticDose`. At
        // grant, a loop cycle can enact a dose concurrently with the pod being
        // released for the loan; that enact hits a disconnecting pod, its completion
        // handler never fires, and `dosingFinished()` is never called — so the flag
        // stays armed for the whole loan. If the app is then terminated during the
        // loan (e.g. the phone is powered off), this reads at next launch as a false
        // "Loop crashed while dosing." A loan being active is detectable:
        // `dosingEnabledBeforeWatchLoan` is non-nil from grant until hand-back/reclaim,
        // and during a loan the phone's own dosing is paused (no other in-flight dose
        // is possible). So in that case the flag is a stale grant-race artifact, not a
        // real mid-dose crash — the handoff was deliberate and §4c reconciles the
        // loan's delivery at hand-back — so clear it and suppress the false alert.
        let loanWasActive = UserDefaults.appGroup?.dosingEnabledBeforeWatchLoan != nil
        log.default("CrashRecovery init: inFlightAutomaticDose set=%{public}@, loanWasActive=%{public}@",
                    String(describing: doseRecoveredFromCrash != nil), String(describing: loanWasActive))

        if doseRecoveredFromCrash != nil, loanWasActive {
            UserDefaults.appGroup?.inFlightAutomaticDose = nil
            doseRecoveredFromCrash = nil
            log.default("CrashRecovery: suppressed stale flag stranded by an active watch loan (grant race)")
        }

        if doseRecoveredFromCrash != nil {
            log.default("CrashRecovery: issuing 'Loop Crashed' alert — flag survived to launch with NO active loan (separate cause)")
            issueCrashAlert()
        }
    }

    func dosingStarted(dose: AutomaticDoseRecommendation) {
        UserDefaults.appGroup?.inFlightAutomaticDose = dose
        log.default("CrashRecovery: dosingStarted — inFlightAutomaticDose ARMED")
    }

    func dosingFinished() {
        UserDefaults.appGroup?.inFlightAutomaticDose = nil
        log.default("CrashRecovery: dosingFinished — inFlightAutomaticDose cleared")
    }

    private func issueCrashAlert() {
        let title = NSLocalizedString("Loop Crashed", comment: "Title for crash recovery alert")
        let modalBody = NSLocalizedString("Oh no! Loop crashed while dosing, and insulin adjustments have been paused until this dialog is closed. Dosing history may not be accurate. Please review Insulin Delivery charts, and monitor your blood glucose carefully.", comment: "Modal body for crash recovery alert")
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

        self.alertIssuer.issueAlert(alert)
    }
}

extension CrashRecoveryManager: AlertResponder {
    func acknowledgeAlert(alertIdentifier: LoopKit.Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        UserDefaults.appGroup?.inFlightAutomaticDose = nil
        doseRecoveredFromCrash = nil
    }
}

