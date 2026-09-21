//
//  PodLoanPhoneController+Wiring.swift
//  Loop
//
//  PODLOAN: how the phone's loan controller is wired to the stock managers. The controller
//  takes injected closures so the state machine is testable without the app; this is the one
//  place those closures are built from the real DeviceDataManager, LoopDataManager,
//  SettingsManager and the WatchConnectivity session. WatchDataManager keeps a one-line hook.
//

import HealthKit
import UIKit
import WatchConnectivity
import LoopAlgorithm
import LoopKit
import LoopCore

extension WatchDataManager {
    func makePodLoanController() -> PodLoanPhoneController {
        return PodLoanPhoneController(dependencies: .init(
            pumpManager: { [weak self] in self?.deviceManager.pumpManager },
            settings: { [weak self] in self?.settingsManager.loopSettings ?? LoopSettings() },
            setAutomaticDosingPaused: { [weak self] paused in
                guard let self = self else { return }
                if paused {
                    self.deviceManager.alertManager?.clearLoopNotRunningNotificationsForLoanGrant()
                } else {
                    DispatchQueue.main.async { [weak self] in

                        Task { await self?.deviceManager.alertManager?.rescheduleLoopNotRunningNotifications(Date()) }
                    }
                }
            },
            send: { [weak self] dictionary in
                guard let session = self?.watchSession else { return }

                let kind: String? = LoanMessage.peekKind(transport: dictionary)

                let size = (dictionary[LoanProtocol.userInfoKey] as? Data)?.count ?? 0

                if kind == "dormantGrant" {
                    for transfer in session.outstandingUserInfoTransfers
                    where LoanMessage.peekKind(transport: transfer.userInfo) == "dormantGrant" {
                        transfer.cancel()
                    }
                }
                guard LoanMessage.isInteractiveHandshake(transport: dictionary),
                      session.isReachable else {
                    self?.log.default("Loan send kind=%{public}@ path=queued (interactive=%{public}@ reachable=%{public}@ bytes=%{public}d)",
                                      kind ?? "?", String(describing: LoanMessage.isInteractiveHandshake(transport: dictionary)),
                                      String(describing: session.isReachable), size)
                    PhoneLog.event("wc", "send \(kind ?? "?") path=queued bytes=\(size) (interactive=\(LoanMessage.isInteractiveHandshake(transport: dictionary)) reachable=\(session.isReachable))")
                    session.transferUserInfo(dictionary)
                    return
                }

                let grantRidesBothChannels = (kind == "grant")
                self?.log.default("Loan send kind=%{public}@ path=urgent bytes=%{public}d", kind ?? "?", size)
                PhoneLog.event("wc", "send \(kind ?? "?") path=urgent\(grantRidesBothChannels ? "+queued" : "") bytes=\(size)")
                session.sendMessage(dictionary, replyHandler: nil, errorHandler: { [weak self] error in
                    guard !grantRidesBothChannels else {
                        PhoneLog.event("wc", "urgent send FAILED grant — \(error.localizedDescription) — the queued copy carries it")
                        return
                    }
                    self?.log.error("Loan urgent send FAILED kind=%{public}@ — %{public}@ — falling back to queued", kind ?? "?", String(describing: error))
                    PhoneLog.event("wc", "urgent send FAILED \(kind ?? "?") bytes=\(size) — \(error.localizedDescription) — falling back to queued")
                    session.transferUserInfo(dictionary)
                })
                if grantRidesBothChannels { session.transferUserInfo(dictionary) }
            },
            addPumpEvents: { [weak self] events, lastReconciliation, completion in
                guard let self = self else { completion(nil); return }

                Task {
                    do {
                        try await self.deviceManager.doseStore.addPumpEvents(events, lastReconciliation: lastReconciliation, replacePendingEvents: false)
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            },
            addCarb: { [weak self] entry, syncIdentifier, completion in
                guard let self = self else { completion(nil); return }

                Task {
                    do {
                        _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<StoredCarbEntry, Error>) in
                            self.deviceManager.carbStore.addCarbEntry(entry, syncIdentifier: syncIdentifier) { c.resume(with: $0) }
                        }
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            },

            deleteCarb: { [weak self] gone, completion in
                guard let self = self else { completion(nil); return }
                let window = gone.startDate.addingTimeInterval(-.hours(1))
                Task {
                    guard let entries = try? await self.deviceManager.carbStore.getCarbEntries(start: window) else { completion(nil); return }
                    let match = entries.first { entry in
                        if let id = gone.syncIdentifier, let entryID = entry.syncIdentifier { return id == entryID }
                        return abs(entry.startDate.timeIntervalSince(gone.startDate)) < 1
                            && abs(entry.quantity.doubleValue(for: .gram) - gone.grams) < 0.01
                    }
                    guard let victim = match else {
                        let lineup = entries.map { e in
                            String(format: "%.0fg@%@ sync=%@", e.quantity.doubleValue(for: .gram),
                                   DateFormatter.localizedString(from: e.startDate, dateStyle: .none, timeStyle: .medium),
                                   e.syncIdentifier.map { String($0.prefix(8)) } ?? "nil")
                        }.joined(separator: " | ")
                        self.log.default("PODLOAN carb delete: no match for %.0f g @ %{public}@ · candidates: %{public}@",
                                         gone.grams, String(describing: gone.startDate), lineup)
                        completion(NSError(domain: "PodLoan.carbDelete", code: 404, userInfo: [
                            NSLocalizedDescriptionKey: "no match among \(entries.count) candidate(s): \(lineup)"]))
                        return
                    }
                    do {
                        _ = try await self.deviceManager.carbStore.deleteCarbEntry(victim)
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            },

            watchAppInstalled: { WCSession.isSupported() && WCSession.default.isWatchAppInstalled },
            scheduleOverride: { [weak self] in
                self?.temporaryPresetsManager.scheduleOverride
            },
            applyScheduleOverride: { [weak self] override in

                self?.temporaryPresetsManager.scheduleOverride = override
            },

            noteWatchClosedLoop: { [weak self] closed in
                DispatchQueue.main.async {
                    self?.settingsManager.mutateLoopSettings { $0.dosingEnabled = closed }
                }
            },
            lastLoopCompleted: { [weak self] in

                self?.loopDataManager.lastLoopCompleted
            },
            noteWatchLoopCompleted: { [weak self] date in
                DispatchQueue.main.async {
                    self?.loopDataManager.seedLastLoopCompleted(fromWatch: date)
                }
            },
            doseHistory: { [weak self] start, completion in
                guard let self = self else { completion([]); return }
                Task {
                    completion((try? await self.deviceManager.doseStore.getNormalizedDoseEntries(start: start)) ?? [])
                }
            },
            carbHistory: { [weak self] start, completion in
                guard let self = self else { completion([]); return }

                self.deviceManager.carbStore.getCarbEntries(start: start) { result in
                    guard case .success(let entries) = result else { completion([]); return }
                    completion(entries.map { e in
                        LoanCarbRecord(syncIdentifier: e.syncIdentifier,
                                       provenanceIdentifier: e.provenanceIdentifier,
                                       syncVersion: e.syncVersion,
                                       startDate: e.startDate,
                                       grams: e.quantity.doubleValue(for: .gram),
                                       absorptionTime: e.absorptionTime,
                                       foodType: e.foodType,
                                       userCreatedDate: e.userCreatedDate,
                                       userUpdatedDate: e.userUpdatedDate)
                    })
                }
            },
            glucoseHistory: { [weak self] start, completion in
                guard let self = self else { completion([]); return }

                Task {
                    guard let samples = try? await self.deviceManager.glucoseStore.getGlucoseSamples(start: start, end: nil) else { completion([]); return }
                    let mgdl = LoopUnit.milligramsPerDeciliter
                    let mgdlPerMin = mgdl.unitDivided(by: .minute)
                    completion(samples.map { s in
                        LoanGlucoseRecord(syncIdentifier: s.syncIdentifier,
                                          startDate: s.startDate,
                                          valueMgdl: s.quantity.doubleValue(for: mgdl),
                                          trendRateMgdlPerMin: s.trendRate?.doubleValue(for: mgdlPerMin),
                                          isDisplayOnly: s.isDisplayOnly,
                                          wasUserEntered: s.wasUserEntered)
                    })
                }
            },
            issueNotice: { [weak self] title, body in
                self?.log.error("PodLoan notice: %{public}@ - %{public}@", title, body)
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "podloan.notice.\(UUID().uuidString)", content: content, trigger: nil))
            },
            ownershipDidChange: { [weak self] in

                DispatchQueue.main.async {
                    guard let deviceManager = self?.deviceManager else { return }
                    NotificationCenter.default.post(name: .PumpManagerChanged, object: deviceManager)
                }
            },
            isConnectionReady: { [weak self] in

                (self?.deviceManager.pumpManager as? PumpConnectionLendable)?.isConnectionReady ?? true
            },
            cancelTempBasalAfterPodReturn: { [weak self] completion in

                guard let self = self else { return completion(nil) }
                Task {
                    do {
                        try await self.loopDataManager.cancelTempBasalAfterPodReturn()
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            },
            cancelTempBasalForGrant: { [weak self] completion in

                guard let self = self else { return completion(nil) }
                Task {
                    do {
                        try await self.loopDataManager.cancelTempBasalForPodLoan(reason: .podLoanGrant)
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            },
            openLoopForUncertainReconciliation: { [weak self] in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    self.settingsManager.mutateLoopSettings { $0.dosingEnabled = false }
                }
            },
            issueUrgentNotice: { [weak self] title, body in

                self?.log.error("PodLoan URGENT: %{public}@ - %{public}@", title, body)
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "podloan.urgent.\(UUID().uuidString)", content: content, trigger: nil))
            },
            bookGapDose: { [weak self] entry, completion in

                guard let self = self else { return completion(false) }
                Task {
                    do {
                        try await self.deviceManager.doseStore.addDoses([entry], from: nil)
                        completion(true)
                    } catch {
                        completion(false)
                    }
                }
            },
            deleteGapDose: { [weak self] syncIdentifier, completion in
                guard let self = self else { return completion(false) }

                let stub = DoseEntry(type: .bolus, startDate: Date(), endDate: Date(),
                                     value: 0, unit: .units, decisionId: nil, syncIdentifier: syncIdentifier,
                                     manuallyEntered: true)
                self.deviceManager.doseStore.deleteDose(stub) { error in
                    completion(error == nil)
                }
            },
            backfillDoses: { [weak self] doses, completion in

                guard let self = self else { completion(nil); return }
                Task {
                    do {
                        try await self.deviceManager.doseStore.syncDoseEntries(doses)
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            },

            insulinHistoryRewritten: { [weak self] earliestStart in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    guard UIApplication.shared.isProtectedDataAvailable else {
                        PhoneLog.event("loan", "insulinHistoryRewritten display refresh SKIPPED — protected data locked (pre-first-unlock launch); the next cycle repaints [locked-launch]")
                        return
                    }
                    self.loopDataManager.insulinHistoryRewritten(startingAt: earliestStart)

                }
            },
            whenProtectedDataAvailable: { work in
                DispatchQueue.main.async {
                    if UIApplication.shared.isProtectedDataAvailable {
                        work()
                    } else {
                        PhoneLog.event("loan", "launch store work DEFERRED — protected data locked (pre-first-unlock launch); resuming on unlock [locked-launch]")
                        var token: NSObjectProtocol?
                        token = NotificationCenter.default.addObserver(
                            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                            object: nil, queue: .main) { _ in
                            if let token = token { NotificationCenter.default.removeObserver(token) }
                            work()
                        }
                    }
                }
            },

            beginReclaimBackgroundTask: { [weak self] in self?.beginReclaimBackgroundTask() },
            endReclaimBackgroundTask: { [weak self] in self?.endReclaimBackgroundTask() },
            isWatchReachable: { [weak self] in self?.watchSession?.isReachable ?? false },
            isBluetoothPoweredOff: { [weak self] in self?.deviceManager.bluetoothProvider.bluetoothState == .poweredOff },
            lastWatchContactAt: { [weak self] in self?.lockedLastWatchContact.value ?? nil },
            latestGlucoseDate: { [weak self] in self?.deviceManager.glucoseStore.latestGlucose?.startDate }
        ))
    }
}
