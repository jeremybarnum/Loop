//
//  PodLoanPhoneController+Grant.swift
//  Loop
//
//  Part of PodLoanPhoneController (see PodLoanPhoneController.swift). Split by concern; stored properties live in the core class.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore
import UserNotifications
import os.log

extension PodLoanPhoneController {
    func handleRequest(_ request: LoanRequest) {
        if let sentAt = request.sentAt {
            let age = deps.now().timeIntervalSince(sentAt)
            if age > Self.requestTTL {
                os_log("Loan request STALE — sent %.0fs ago (TTL %.0fs); ignored as a queued-channel ghost",
                       log: log, type: .default, age, Self.requestTTL)
                PhoneLog.event("loan", String(format: "request STALE — sent %.0fs ago (TTL %.0fs) — ignored, no grant", age, Self.requestTTL))
                return
            }
        }

        if let id = request.requestID, id == lastRequestID,
           let seenAt = lastRequestAt,
           deps.now().timeIntervalSince(seenAt) < Self.requestDedupeWindow {
            os_log("Duplicate loan request %{public}@ ignored (transport redelivery, %.1fs after the first)",
                   log: log, type: .default, id, deps.now().timeIntervalSince(seenAt))
            return
        }
        if let id = request.requestID {
            lastRequestID = id
            lastRequestAt = deps.now()
        }

        if let seize = request.supportsSeize {
            UserDefaults.standard.set(seize, forKey: Keys.watchSupportsSeize)
        }
        guard request.supportedVersions.contains(LoanProtocol.version) else {
            sendMessage(.nack(ProtocolNack(seenVersion: request.supportedVersions.max())))
            return
        }
        guard !grantInFlight else {
            deny("A grant is already in progress.")
            return
        }
        guard state == .owner else {
            switch state {
            case .grantOffered, .reconciling, .reclaimPending:

                os_log("Loan request while %{public}@ — recovering stale state and granting", log: log, type: .default, state.rawValue)
                forceReclaimToOwner(reason: "new request while \(state.rawValue)")
                beginGrant()
            case .loaned:

                os_log("Loan request while LOANED — revoking the previous loan first", log: log, type: .default)
                reclaimNow()
                deny("Reclaiming the previous loan from the watch — try Start again in a few seconds.")
            case .owner:
                break
            }
            return
        }
        beginGrant()
    }

    func deny(_ reason: String) {
        os_log("Loan denied: %{public}@", log: log, type: .default, reason)
        sendMessage(.denied(LoanDenied(reason: reason)))
    }

    func beginGrant() {
        guard let pump = deps.pumpManager() else {
            deny("No pump is set up on the phone.")
            return
        }
        guard let lendable = pump as? PumpConnectionLendable else {
            deny("This pump can't be loaned to the watch (\(type(of: pump))).")
            return
        }

        if yieldingToInferredLoan {
            clearInferredLoanYield(reason: "new loan request — a granted loan supersedes the inferred one")
            reclaimPodConnection()
        }

        if let started = reclaimStartedAt,
           deps.now().timeIntervalSince(started) < Self.reclaimSettleTimeout,
           reclaimVerifiedAt == nil {
            os_log("Grant deferred: pod still returning from the last reclaim (%.0fs into settle, round-trip not yet verified) — deny-and-retry",
                   log: log, type: .default, deps.now().timeIntervalSince(started))
            deny("The pod is still returning from the last session. Try Start again in a few seconds.")
            attemptReclaimVerificationNow(started: started)
            return
        }

        let settings = deps.settings()

        var loanSettings = settings
        let strategyOverridden = settings.automaticDosingStrategy != .tempBasalOnly
        loanSettings.automaticDosingStrategy = .tempBasalOnly
        if strategyOverridden {
            PhoneLog.event("loan", "dosing strategy overridden for the loan — phone \(settings.automaticDosingStrategy) → wrist tempBasalOnly; the phone's own setting is untouched")
        }
        guard settings.basalRateSchedule != nil,
              settings.insulinSensitivitySchedule != nil,
              settings.carbRatioSchedule != nil,
              settings.glucoseTargetRangeSchedule != nil,
              settings.maximumBasalRatePerHour != nil,
              settings.maximumBolus != nil else {
            deny("Therapy settings are incomplete; the watch can't dose without them.")
            return
        }

        grantInFlight = true
        deps.setAutomaticDosingPaused(true)
        deps.cancelTempBasalForGrant { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                self.grantInFlight = false
                if let error = error {
                    self.deps.setAutomaticDosingPaused(false)

                    self.deny("The iPhone couldn't reach its pod (\(error.localizedDescription)). The phone kept the pod.")
                    return
                }
                self.continueGrant(settings: settings, loanSettings: loanSettings, pump: pump, lendable: lendable)
            }
        }
    }

    private func continueGrant(settings: LoopSettings, loanSettings: LoopSettings,
                               pump: PumpManager, lendable: PumpConnectionLendable) {
                let handedOverAt = deps.now()

        if let delivered = lendable.lentDeviceInsulinDelivered {
            UserDefaults.standard.set(delivered, forKey: Keys.deliveredAtGrant)

            auditBase = AuditBase(units: delivered, asOf: handedOverAt)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.deliveredAtGrant)
            auditBase = nil
        }
        checkpointsThisLoan = 0
        worstWindowThisLoan = 0

        UserDefaults.standard.removeObject(forKey: Keys.deliveredAtTakeover)

        let releaseEpoch = epoch + 1
        handbackDiag(releaseEpoch, "GRANT — releasing pod BLE (wasReleased=\(lendable.isConnectionReleased))")
        lendable.releaseConnection()
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak lendable] in
            guard let self = self, let lendable = lendable else { return }

            self.handbackDiag(releaseEpoch, "GRANT +3s — pod BLE released=\(lendable.isConnectionReleased) linkUp=\(lendable.isConnectionReady)")
            if lendable.isConnectionReady {
                self.handbackDiag(releaseEpoch, "GRANT +3s — ** STILL CONNECTED after release — the watch's takeover will be refused (single-central pod) **")
            }
            PhoneLog.flush()
        }

        epoch += 1
        state = .grantOffered
        committedCursor = 0
        committedIDs = []
        persistCommittedIDs()

        pendingForceReclaimReason = nil
        coalescedOffers.removeAll()
        staged = [:]
        stagedTombstones = []
        persistStaged()
        loanStartedAt = handedOverAt
        UserDefaults.standard.set(handedOverAt, forKey: Keys.loanStartedAt)
        holdRenewedAt = handedOverAt
        holdLapseNoticedAt = nil

        let grantEpoch = epoch

        assembleGrant(epoch: grantEpoch, referenceDate: handedOverAt,
                      expiresAt: handedOverAt.addingTimeInterval(.minutes(5)),
                      pumpRaw: pump.rawValue, loanSettingsRaw: loanSettings.rawValue,
                      settings: settings) { [weak self] grant in
            guard let self = self else { return }
            guard self.state == .grantOffered, self.epoch == grantEpoch else { return }
            guard let grant = grant else {
                self.abortGrant(reason: "snapshot encoding failed")
                return
            }
            self.sendMessage(.grant(grant))
            self.armT1(for: grantEpoch)
        }
    }

    private func assembleGrant(epoch grantEpoch: Int, referenceDate: Date, expiresAt: Date,
                               pumpRaw: [String: Any], loanSettingsRaw: [String: Any],
                               settings: LoopSettings,
                               completion: @escaping (LoanGrant?) -> Void) {
        let historyStart = referenceDate.addingTimeInterval(-.hours(16))

        let glucoseStart = referenceDate.addingTimeInterval(-.hours(3))
        deps.doseHistory(historyStart) { [weak self] history in
            guard let self = self else { return }
            self.deps.carbHistory(historyStart) { [weak self] carbs in
                guard let self = self else { return }
                self.deps.glucoseHistory(glucoseStart) { [weak self] glucose in
                    guard let self = self else { return }
                    self.queue.async {
                        guard let stateData = try? PropertyListSerialization.data(fromPropertyList: pumpRaw, format: .binary, options: 0),
                              let settingsData = try? PropertyListSerialization.data(fromPropertyList: loanSettingsRaw, format: .binary, options: 0) else {
                            completion(nil)
                            return
                        }

                        let activeOverride = self.deps.scheduleOverride().flatMap {
                            $0.hasFinished() ? nil : $0
                        }
                        let overrideData: Data? = activeOverride.flatMap { o in
                            try? PropertyListSerialization.data(fromPropertyList: o.rawValue, format: .binary, options: 0)
                        }
                        if let o = activeOverride {
                            if overrideData == nil {
                                os_log("[override] grant: FAILED to encode active override %{public}@ — the wrist will dose UNSCALED",
                                       log: self.log, type: .error, Self.overrideNameForLog(o))
                            } else {
                                os_log("[override] grant: carrying %{public}@ · insulin needs %.0f%% · sync %{public}@",
                                       log: self.log, type: .default, Self.overrideNameForLog(o),
                                       o.settings.effectiveInsulinNeedsScaleFactor * 100,
                                       o.syncIdentifier.uuidString)
                            }
                        }

                        var supplement: [String: Any] = [:]
                        supplement["basalRateSchedule"] = settings.basalRateSchedule?.rawValue
                        supplement["insulinSensitivitySchedule"] = settings.insulinSensitivitySchedule?.rawValue
                        supplement["carbRatioSchedule"] = settings.carbRatioSchedule?.rawValue
                        supplement["defaultRapidActingModel"] = settings.defaultRapidActingModel?.rawValue
                        let supplementData = supplement.isEmpty ? nil
                            : try? PropertyListSerialization.data(fromPropertyList: supplement, format: .binary, options: 0)
                        os_log("[grant] settings supplement: basal=%{public}@ isf=%{public}@ cr=%{public}@ model=%{public}@ bytes=%{public}d",
                               log: self.log, type: .default,
                               settings.basalRateSchedule == nil ? "MISSING" : "ok",
                               settings.insulinSensitivitySchedule == nil ? "MISSING" : "ok",
                               settings.carbRatioSchedule == nil ? "MISSING" : "ok",
                               settings.defaultRapidActingModel.map { String(describing: $0) } ?? "MISSING (wrist will assume rapid-acting adult)",
                               supplementData?.count ?? 0)

                        self.handbackDiag(grantEpoch, "[grant] supplement \(supplementData?.count ?? 0)B · seeds: \(history.count) dose, \(carbs.count) carb, \(glucose.count) glucose · podState \(stateData.count)B · settings \(settingsData.count)B")
                        let grant = LoanGrant(
                            epoch: grantEpoch,
                            expiresAt: expiresAt,
                            pumpManagerRawState: stateData,
                            podAddress: 0,
                            therapySettingsRaw: settingsData,
                            settingsTimeZoneID: settings.basalRateSchedule?.timeZone.identifier ?? TimeZone.current.identifier,
                            doseHistory: history.compactMap(Self.loanRecord(from:)),
                            supportsInterimHandback: true,
                            supportsOverrideRecords: true,

                            integralRetrospectiveCorrectionEnabled: UserDefaults.standard.integralRetrospectiveCorrectionEnabled,

                            phoneClosedLoopEnabled: settings.dosingEnabled,
                            carbHistory: carbs,
                            glucoseHistory: glucose,
                            activeOverrideRaw: overrideData,
                            therapySettingsSupplementRaw: supplementData,

                            lastLoopCompleted: self.deps.lastLoopCompleted())
                        completion(grant)
                    }
                }
            }
        }
    }

    private static let dormantRefreshInterval: TimeInterval = .minutes(30)

    private static let bookRefreshFloor: TimeInterval = 30

    private static func settingsFingerprint(_ s: LoopSettings) -> String {
        let basal = s.basalRateSchedule.map { String(describing: $0.items) } ?? "-"
        let isf = s.insulinSensitivitySchedule.map { String(describing: $0.items) } ?? "-"
        let cr = s.carbRatioSchedule.map { String(describing: $0.items) } ?? "-"
        let targets = s.glucoseTargetRangeSchedule.map { String(describing: $0.items) } ?? "-"
        return "\(basal)|\(isf)|\(cr)|\(targets)|\(String(describing: s.maximumBolus))|\(String(describing: s.maximumBasalRatePerHour))|\(s.dosingEnabled)"
    }

    func dormantSeizeToken() -> UUID {
        if let raw = UserDefaults.standard.string(forKey: Keys.dormantSeizeToken),
           let token = UUID(uuidString: raw) {
            return token
        }
        let token = UUID()
        UserDefaults.standard.set(token.uuidString, forKey: Keys.dormantSeizeToken)
        return token
    }

    func considerDormantRefresh(bookChanged: Bool = false) {
        queue.async { [weak self] in self?.queue_considerDormantRefresh(bookChanged: bookChanged) }
    }

    private func queue_considerDormantRefresh(bookChanged: Bool = false) {
        guard state == .owner else { return }
        guard UserDefaults.standard.bool(forKey: Keys.watchSupportsSeize) else { return }
        guard let pump = deps.pumpManager(),
              let lendable = pump as? PumpConnectionLendable,
              !lendable.isConnectionReleased else { return }
        let settings = deps.settings()

        guard settings.maximumBolus != nil, settings.maximumBasalRatePerHour != nil,
              settings.basalRateSchedule != nil else { return }

        let fingerprint = Self.settingsFingerprint(settings) + "|e\(epoch)"
        let periodicDue = lastDormantRefreshAt.map { deps.now().timeIntervalSince($0) >= Self.dormantRefreshInterval } ?? true
        let settingsChanged = fingerprint != lastDormantSettingsFingerprint
        guard periodicDue || settingsChanged || bookChanged else { return }
        if !periodicDue, !settingsChanged, let last = lastDormantRefreshAt {
            let wait = Self.bookRefreshFloor - deps.now().timeIntervalSince(last)
            if wait > 0 {
                guard !trailingDormantRefreshPending else { return }
                trailingDormantRefreshPending = true
                queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.trailingDormantRefreshPending = false
                    self?.queue_considerDormantRefresh(bookChanged: true)
                }
                return
            }
        }

        var loanSettings = settings
        loanSettings.automaticDosingStrategy = .tempBasalOnly
        let issuedAt = deps.now()
        let token = dormantSeizeToken()
        let provisionalEpoch = epoch + 1

        lastDormantRefreshAt = issuedAt
        lastDormantSettingsFingerprint = fingerprint
        assembleGrant(epoch: provisionalEpoch, referenceDate: issuedAt, expiresAt: issuedAt,
                      pumpRaw: pump.rawValue, loanSettingsRaw: loanSettings.rawValue,
                      settings: settings) { [weak self] grant in
            guard let self = self else { return }
            guard let grant = grant else {
                self.lastDormantRefreshAt = nil
                return
            }
            guard self.state == .owner else { return }
            self.sendMessage(.dormantGrant(DormantGrant(grant: grant, issuedAt: issuedAt, seizeToken: token)))
            PhoneLog.event("seize", "dormant grant refreshed — \(grant.doseHistory.count) dose record(s), token …\(String(token.uuidString.suffix(8))) [seize]")
        }
    }

}
