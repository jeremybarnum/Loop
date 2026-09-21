//
//  PodLoanWatchController+Resume.swift
//  WatchApp Extension
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import OmnipodKit
import WatchKit
import os.log

extension PodLoanWatchController {

    func resumeIfNeeded() {
        let rebuild = DispatchWorkItem(qos: .userInitiated, flags: .enforceQoS) {
            guard let saved = self.pendingResumeState else { return }
            self.pendingResumeState = nil
            self.resumeSavedLoanOnQueue(saved)
        }
        queue.async(execute: rebuild)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Sport Mode resume") { expired in
            if !expired { rebuild.wait() }
        }
    }

    func endResuming() {
        loanActiveMirrorLock.lock()
        _resumingMirror = false
        loanActiveMirrorLock.unlock()
        _ = loopManager.endAwaitingPumpManager()
        notifyUI()
    }

    func resumeSavedLoanOnQueue(_ savedState: PumpManager.RawStateValue) {
        defer { endResuming() }

        guard let payload = defaults.dictionary(forKey: Keys.grantedTherapySettings),
              let raw = payload["raw"] as? Data,
              let settings = Self.decodeTherapySettings(raw: raw, supplement: payload["supplement"] as? Data),
              settings.basalRateSchedule != nil else {
            defaults.removeObject(forKey: Keys.pumpState)
            defaults.removeObject(forKey: Keys.grantedTherapySettings)
            phase = .recoveredDrain
            issueSessionEndedAlert()
            SportLog.event("loan", "RESUME failed — therapy settings unreadable; falling back to a recovered drain")
            return
        }

        SportLog.event("loan", "RESUME: building the pump manager from saved state")
        guard let manager = OmniPumpManager(rawState: savedState) else {
            defaults.removeObject(forKey: Keys.pumpState)
            defaults.removeObject(forKey: Keys.grantedTherapySettings)
            phase = .recoveredDrain
            issueSessionEndedAlert()
            SportLog.event("loan", "RESUME failed — saved pod state unreadable; falling back to a recovered drain")
            return
        }
        SportLog.event("loan", "RESUME: pump manager built")
        loopManager.settings = settings
        phoneSupportsInterimHandback = payload["interim"] as? Bool ?? false
        phoneSupportsOverrideRecords = payload["overrideRecords"] as? Bool ?? false
        deliveredAtTakeover = defaults.object(forKey: Keys.deliveredAtTakeover) as? Double
        manager.pumpManagerDelegate = self
        manager.delegateQueue = queue
        pumpManager = manager

        phase = .active
        loopManager.pumpManager = manager
        onLoanActiveChanged?(true)

        let lastSync = manager.lastSync
        let readingWaited = loopManager.endAwaitingPumpManager()
        Task { [loopManager] in
            if let lastSync { try? await loopManager.recordPumpEvents([], lastReconciliation: lastSync, replacePendingEvents: false) }
            loopManager.updateDisplayState()
            if readingWaited {
                SportLog.event("loan", "RESUME: a reading arrived while the pump manager was being built — running its cycle now")
                loopManager.checkPumpDataAndLoop()
            }
        }
        SportLog.event("loan", "RESUMED — epoch \(epoch ?? -1) rebuilt from saved pod state after a relaunch (R40(e): stock relaunch) · \(RuntimeStateLog.snapshot())")
    }

    func issueSessionEndedAlert() {
        let title = NSLocalizedString("Sport Mode Ended", comment: "Watch alert title on relaunch after the app died mid-loan")
        let body = NSLocalizedString("The watch app restarted. Insulin and carb records may not be on the phone yet.", comment: "Watch alert body on relaunch after the app died mid-loan")
        Task { @MainActor in
            loopManager.issueAlert(Alert(
                identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "sessionEnded"),
                foregroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                backgroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                trigger: .immediate))
        }
    }
}
