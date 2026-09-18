//
//  PodLoanWatchController+Delegates.swift
//  WatchApp Extension
//
//  Part of PodLoanWatchController (see PodLoanWatchController.swift). The pump-host duties: PumpManagerDelegate, PumpManagerStatusObserver, DeviceManagerDelegate.
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import OmnipodKit
import WatchKit
import os.log

// MARK: - PumpManagerDelegate (the host duties; alert family forwards to WatchLoopManager's
// existing DeviceManagerDelegate conformance)

extension PodLoanWatchController: PumpManagerDelegate {

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {
        // The phone's `rawPumpManager = pumpManager.rawValue`, on the wrist: every state change
        // lands on disk, so a relaunch mid-loan resumes from the pod's latest known state (R40(e)).
        defaults.set(pumpManager.rawState, forKey: Keys.pumpState)
    }

    func pumpManager(_ pumpManager: PumpManager, hasNewPumpEvents events: [NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool, completion: @escaping (Error?) -> Void) {
        // THE ONE WRITER of the watch's insulin book (R35 reversed, 2026-09-17): the pump
        // manager's report goes into the DoseStore through the same door, with the same flags,
        // as DeviceDataManager.pumpManager(_:hasNewPumpEvents:...) on the phone. The clock that
        // gates dosing (pumpDataTooOld) is the store's own `lastAddedPumpData`, advanced by this
        // write — an EMPTY report advances it too, which is what a status read with nothing new
        // means. The stock storage path BLOCKS its session queue on this completion (10 s) —
        // always call it, promptly; on an error the pod retains the doses for the next report.
        let loopManager = self.loopManager
        Task {
            do {
                try await loopManager.recordPumpEvents(events, lastReconciliation: lastReconciliation, replacePendingEvents: replacePendingEvents)
                completion(nil)
                self.queue.async { self.journalPumpEvents(events) }   // the same report feeds the journal
            } catch {
                SportLog.event("book", "** pump events NOT stored — \(String(describing: error)) — \(events.count) event(s) held back by the pod for the next report **")
                completion(error)
            }
        }
    }

    func pumpManager(_ pumpManager: PumpManager, didReadReservoirValue units: Double, at date: Date, completion: @escaping (Swift.Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool), Error>) -> Void) {
        // Reservoir readings are not stored (unreadable above 50 U on this pod anyway — the
        // odometer is the audit instrument, and the pump-event report is the recency clock).
        // Report the value back as a fresh, non-continuous reading so the manager's
        // bookkeeping proceeds.
        struct SimpleReservoirValue: ReservoirValue {
            let startDate: Date
            let unitVolume: Double
        }
        completion(.success((newValue: SimpleReservoirValue(startDate: date, unitVolume: units),
                             lastValue: nil, areStoredValuesContinuous: false)))
    }

    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date {
        // Stock (DeviceDataManager): the store says where its pump-event history ends.
        return loopManager.doseStore.pumpEventQueryAfterDate
    }

    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager) {
        // The watch loop triggers on CGM readings (enact-only-on-fresh-reading), not
        // on pump heartbeats.
    }

    func pumpManagerMustProvideBLEHeartbeat(_ pumpManager: PumpManager) -> Bool {
        return false
    }

    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError) {
        os_log("PumpManager error: %{public}@", log: log, type: .error, String(describing: error))
    }

    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) {
        loopManager.doseStore.pumpRecordsBasalProfileStartEvents = pumpRecordsBasalProfileStartEvents
    }

    func pumpManager(_ pumpManager: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) {
        os_log("Pump clock adjusted by %f", log: log, type: .default, adjustment)
    }

    func pumpManager(_ pumpManager: PumpManager, didRequestBasalRateScheduleChange basalRateSchedule: BasalRateSchedule, completion: @escaping (Error?) -> Void) {
        // The watch never accepts schedule changes; the pod's stored schedule is the
        // phone's.
        completion(WatchLoopError.configurationError("basal schedule changes are phone-only"))
    }

    func pumpManagerWillDeactivate(_ pumpManager: PumpManager) {
        os_log("PumpManager will deactivate", log: log, type: .default)
    }

    func pumpManagerPumpWasReplaced(_ pumpManager: PumpManager) {
        os_log("Pump was replaced", log: log, type: .default)
    }

    var detectedSystemTimeOffset: TimeInterval {
        return 0
    }

    var automaticDosingEnabled: Bool {
        return phase == .active
    }

    /// What automation is currently doing to delivery, for the driver's own status surfaces.
    /// The wrist reports this from the temp basal it last enacted: a loan that is not active
    /// is not dosing at all, and outside a temp the pod is running the scheduled rate.
    var automatedTreatmentState: AutomatedTreatmentState? {
        guard phase == .active else { return nil }
        guard let dose = loopManager.runningTempBasal() else { return .neutralNoOverride }
        let scheduled = loopManager.basalRateScheduleApplyingOverrideHistory?.value(at: now()) ?? 0
        if dose.unitsPerHour == 0 { return .minimumDelivery }
        if dose.unitsPerHour > scheduled { return .increasedInsulin }
        if dose.unitsPerHour < scheduled { return .decreasedInsulin }
        return .neutralNoOverride
    }
}

// MARK: - PumpManagerStatusObserver

extension PodLoanWatchController: PumpManagerStatusObserver {
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {
        os_log("Pump status: %{public}@", log: log, type: .default, String(describing: status.basalDeliveryState))
    }
}

// MARK: - DeviceManagerDelegate (forwards to WatchLoopManager's conformances)

extension PodLoanWatchController: DeviceManagerDelegate {
    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        loopManager.deviceManager(manager, logEventForDeviceIdentifier: deviceIdentifier, type: type, message: message, completion: completion)
    }

    func issueAlert(_ alert: LoopKit.Alert) {
        loopManager.issueAlert(alert)
    }

    func retractAlert(identifier: LoopKit.Alert.Identifier) {
        loopManager.retractAlert(identifier: identifier)
    }

    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier) async throws -> Bool {
        try await loopManager.doesIssuedAlertExist(identifier: identifier)
    }

    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] {
        try await loopManager.lookupAllUnretracted(managerIdentifier: managerIdentifier)
    }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] {
        try await loopManager.lookupAllUnacknowledgedUnretracted(managerIdentifier: managerIdentifier)
    }

    func recordRetractedAlert(_ alert: LoopKit.Alert, at date: Date) {
        loopManager.recordRetractedAlert(alert, at: date)
    }
}

// R40: a seize activation forces the credential's provisional epoch fresh AND mints the
// live takeover lease — the dormant expiresAt is issuedAt by contract, and carrying it
// verbatim aborted the first field seize at ladder read 1. LoanGrant is all-let by design,
// so the rewrite is an explicit re-init — every other field carried verbatim (this line's
// field list: override carry + settings supplement instead of her low-BG settings).
// Internal (not fileprivate) so the unit test can pin both rewritten fields directly.
extension LoanGrant {
    func withEpoch(_ newEpoch: Int, leaseUntil: Date) -> LoanGrant {
        LoanGrant(epoch: newEpoch, expiresAt: leaseUntil, pumpManagerRawState: pumpManagerRawState,
                  podAddress: podAddress, therapySettingsRaw: therapySettingsRaw,
                  settingsTimeZoneID: settingsTimeZoneID, doseHistory: doseHistory,
                  supportsInterimHandback: supportsInterimHandback,
                  supportsOverrideRecords: supportsOverrideRecords,
                  integralRetrospectiveCorrectionEnabled: integralRetrospectiveCorrectionEnabled,
                  phoneClosedLoopEnabled: phoneClosedLoopEnabled, carbHistory: carbHistory,
                  glucoseHistory: glucoseHistory, predictionSnapshot: predictionSnapshot,
                  activeOverrideRaw: activeOverrideRaw,
                  therapySettingsSupplementRaw: therapySettingsSupplementRaw,
                  lastLoopCompleted: lastLoopCompleted)
    }
}
