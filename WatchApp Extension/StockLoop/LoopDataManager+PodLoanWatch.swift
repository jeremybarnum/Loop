//
//  LoopDataManager+PodLoanWatch.swift
//  WatchApp Extension
//
//  Sport Mode on the watch's LoopDataManager: the phone relay context, the G7 pairing code,
//  phone contexts that arrive during a loan, and overrides on the wrist's dosing.
//

import Foundation
import LoopKit
import LoopCore
import WatchConnectivity
import G7SensorKit   // direct-auth pairing codes arrive inside the phone's cgmManagerState

extension LoopDataManager {

    /// Called from `activeContext`'s `didSet`.
    func podLoanNoteContextChange(_ oldValue: WatchContext?) {
        // The phone's onboarding input to the gate, logged on change.
        let flag = activeContext?.isOnboardingCompleted
        if flag != oldValue?.isOnboardingCompleted || (oldValue == nil) != (activeContext == nil) {
            SportLog.event("gate", "phone context: onboardingCompleted=\(flag.map { String($0) } ?? "nil") (context \(activeContext == nil ? "NIL" : "present"), watchAuthored=\(activeContext?.isWatchAuthored == true)) [onboarding-gate]")
        }
    }

    /// Called from `updateContext(_:)`.
    func podLoanNotePhoneRelayContext(_ context: WatchContext) {
        // Keep the phone's relay apart from the active context, which is the watch's during a loan.
        if !context.isWatchAuthored {
            phoneRelayContext = context
        }
    }

    /// Called from `updateContext(_:)`.
    func podLoanReadPairingCode(from context: WatchContext) {
        // The phone's G7 state rides in each context (wrapped under "state"); take the pairing code
        // and let the manager adopt a sensor change by identity.
        if !context.isWatchAuthored, let wrapped = context.cgmManagerState {
            let raw = wrapped["state"] as? [String: Any] ?? wrapped
            let code = raw["pairingCode"] as? String
            let phoneSensor = raw["sensorID"] as? String
            ExtensionDelegate.sharedIfAvailable()?.stockLoopSession?.stack.cgmManager
                .receivePairingCode(code, phoneSensorID: phoneSensor)
        }
    }

    /// Called from `updateContext(_:)` when a phone context is refused mid-loan.
    func podLoanAbsorbPhoneContextDuringLoan(_ context: WatchContext) {
        // Still store the relayed reading and post the notification the ingest path hangs off.
        if let newGlucoseSample = context.newGlucoseSample {
            Task {
                try? await self.glucoseStore?.addGlucoseSamples([newGlucoseSample])
            }
        }
        NotificationCenter.default.post(name: LoopDataManager.didUpdateContextNotification, object: self)
    }

    /// Non-nil only while the wrist is dosing.
    var loanDosingManagerIfActive: WatchLoopManager? {
        guard let session = ExtensionDelegate.sharedIfAvailable()?.stockLoopSession,
              session.loanController.isLoanActiveNonBlocking else { return nil }
        return session.stack.loopManager
    }

    /// Applies an override to the wrist's dosing during a loan, then the UI, then (best-effort)
    /// the phone, which is often off during a loan.
    func applyOverrideDuringLoan(_ manager: WatchLoopManager,
                                         _ override: TemporaryScheduleOverride?,
                                         _ watchInfoUpdate: LoopSettingsUserInfo,
                                         presetId: String?,
                                         alertIdentifier: String?) async {
        manager.applyWristOverride(override)
        watchInfo = watchInfoUpdate
        do {
            try await WCSession.default.sendSetPreset(presetIdentifier: presetId, alertIdentifier: alertIdentifier)
        } catch {
            SportLog.event("override", "phone not told (\(error)) — the wrist holds the pod, so its own dosing is authoritative")
        }
    }
}
