//
//  PodLoanWatchController+Resume.swift
//  WatchApp Extension
//
//  Bringing a live loan back after the app dies or the watch reboots, the way the phone
//  resumes after its own relaunch. What cannot be rebuilt falls back to a recovered drain.
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

    /// At .userInitiated with a background assertion: at the queue's own QoS a freshly powered
    /// watch can stall the rebuild for many seconds.
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

    /// Every exit from the rebuild ends here, so the UI never sits on a finished resume.
    func endResuming() {
        loanActiveMirrorLock.lock()
        _resumingMirror = false
        loanActiveMirrorLock.unlock()
        _ = loopManager.endAwaitingPumpManager()
        notifyUI()
    }

    /// Settings first, then the pump manager; either unreadable degrades to a recovered drain.
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

        // Through the property, so didSet updates the main-safe mirrors.
        phase = .active
        loopManager.pumpManager = manager
        onLoanActiveChanged?(true)

        // Seed the reconciliation stamp, or the first cycle refuses with "pump data too old".
        let lastSync = manager.lastSync
        let readingWaited = loopManager.endAwaitingPumpManager()
        Task { [loopManager] in
            if let lastSync { try? await loopManager.recordPumpEvents([], lastReconciliation: lastSync, replacePendingEvents: false) }
            loopManager.updateDisplayState()
            // Run the cycle for a reading that arrived mid-rebuild.
            if readingWaited {
                SportLog.event("loan", "RESUME: a reading arrived while the pump manager was being built — running its cycle now")
                loopManager.checkPumpDataAndLoop()
            }
        }
        SportLog.event("loan", "RESUMED — epoch \(epoch ?? -1) rebuilt from saved pod state after a relaunch (R40(e): stock relaunch) · \(RuntimeStateLog.snapshot())")
    }

    /// For a session that cannot resume: records may not have reached the phone yet.
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
