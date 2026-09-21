//
//  PodLoanWatchController+Grant.swift
//  StockLoop
//
//  Part of PodLoanWatchController (see PodLoanWatchController.swift). Split by concern; stored properties live in the core class.
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
    enum DormantKeys {
        static let envelope = "PodLoanWatchController.dormantGrant"

        static let activeToken = "PodLoanWatchController.activeSeizeToken"
    }

    var seizeMarkerActive: Bool {
        pendingSeizeToken != nil || defaults.string(forKey: DormantKeys.activeToken) != nil
    }

    static let seizeActivationLease: TimeInterval = 5 * 60

    func confirmSeize() {
        queue.async {
            guard self.phase == .idle || self.phase == .recoveredDrain, let offer = self.seizeOffer,
                  let dormant = self.storedDormantGrant(), dormant.seizeToken == offer.token else {
                SportLog.event("seize", "confirm arrived with no live offer — ignored [seize]")
                return
            }
            self.seizeOffer = nil

            let newEpoch = max(dormant.grant.epoch,
                               (self.epoch ?? 0) + 1,
                               (self.journal.activeEpoch ?? 0) + 1,
                               self.defaults.integer(forKey: Keys.highWaterEpoch) + 1,
                               (self.lastRevokedEpoch ?? 0) + 1)

            let leaseUntil = self.now().addingTimeInterval(Self.seizeActivationLease)
            self.pendingSeizeToken = dormant.seizeToken

            self.cancelStaleQueuedRequests(context: "seize confirmed")
            SportLog.event("seize", String(format: "SEIZE confirmed — activating dormant grant (issued %@, epoch %d→%d, lease +%.0fs, token …%@) [seize]",
                                           DateFormatter.localizedString(from: dormant.issuedAt, dateStyle: .short, timeStyle: .short),
                                           dormant.grant.epoch, newEpoch, Self.seizeActivationLease,
                                           String(dormant.seizeToken.uuidString.suffix(8))))
            self.phase = .requested
            self.attemptStartedAt = self.now()
            self.seizeActivationInFlight = true
            self.handleGrant(dormant.grant.withEpoch(newEpoch, leaseUntil: leaseUntil))
            self.seizeActivationInFlight = false
        }
    }

    func dismissSeize() {
        queue.async {
            guard self.seizeOffer != nil else { return }
            self.seizeOffer = nil
            self.lastIdleNote = NSLocalizedString("Offline start cancelled.", comment: "Glance note after dismissing a seize offer")
            SportLog.event("seize", "seize offer DISMISSED [seize]")
            self.notifyUI()
        }
    }

    static let seizeAutoHandbackDisabledKey = "PodLoanWatchController.seizeAutoHandbackDisabled"

    func noteReachabilityChanged(_ reachable: Bool) {
        queue.async {
            guard reachable else { return }
            guard self.phase == .active,
                  self.defaults.string(forKey: DormantKeys.activeToken) != nil,
                  !self.handbackRequested, !self.reunionPromptActive else { return }
            guard !self.defaults.bool(forKey: Self.seizeAutoHandbackDisabledKey) else {
                SportLog.event("seize", "phone returned during a seized loan — reunion prompt DISABLED by kill switch [seize]")
                return
            }
            guard !self.seizeReunionDebounceArmed else { return }
            self.seizeReunionDebounceArmed = true
            SportLog.event("seize", "phone REACHABLE during a seized loan — reunion prompt in 30s unless it flickers away [seize]")
            self.schedule(after: 30, label: "seize-reunion-debounce") { [weak self] in
                guard let self = self else { return }
                self.seizeReunionDebounceArmed = false
                guard self.phase == .active,
                      self.defaults.string(forKey: DormantKeys.activeToken) != nil,
                      !self.handbackRequested, !self.reunionPromptActive else { return }
                guard self.isPhoneReachable() else {
                    SportLog.event("seize", "phone flickered away before the reunion debounce — seized loan continues [seize]")
                    return
                }
                self.reunionPromptActive = true
                SportLog.event("seize", "phone is back — REUNION PROMPT raised (R40(f): the hand-back stays the user's deliberate act) [seize]")
                self.notifyUI()
                self.issueReunionPromptAlert()

                self.sendHoldsPodStatusReport(reason: "reunion prompt raised")
            }
        }
    }

    func sendHoldsPodStatusReport(reason: String) {
        guard phase == .active, let current = epoch else { return }
        sendMessage(.statusReport(StatusReport(
            epoch: current,
            mode: currentMode(),
            lastDirectGlucoseAge: loopManager.latestGlucoseAge,
            lastEventSeq: journal.lastEventSeq,
            podFault: pumpManager?.podLoanFaultDescription,
            holdsPod: true,
            knowsGrant: true)))
        SportLog.event("seize", "statusReport sent — holdsPod e\(current) (\(reason)) [seize]")
    }

    func confirmReunionHandback() {
        queue.async {
            guard self.reunionPromptActive, self.phase == .active else { return }
            self.reunionPromptActive = false
            SportLog.event("seize", "reunion prompt: HAND BACK chosen — normal hand-back begins [seize]")
            self.notifyUI()
            self.beginHandback()
        }
    }

    func dismissReunionPrompt() {
        queue.async {
            guard self.reunionPromptActive else { return }
            self.reunionPromptActive = false
            SportLog.event("seize", "reunion prompt: KEEP chosen — seized loan continues [seize]")
            self.notifyUI()

            self.sendHoldsPodStatusReport(reason: "Keep chosen")
        }
    }

    private func issueReunionPromptAlert() {
        let title = NSLocalizedString("iPhone Is Back", comment: "Watch alert title when the phone returns during a seized loan")
        let body = NSLocalizedString("Sport Mode is still running without it. Open the app to hand the pod back, or keep going.", comment: "Watch alert body when the phone returns during a seized loan")
        Task { @MainActor in
            loopManager.issueAlert(Alert(
                identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "seizeReunionPrompt"),
                foregroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                backgroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                trigger: .immediate))
        }
    }

    func handleDormantGrant(_ dormant: DormantGrant) {
        guard let data = try? LoanProtocol.encoder.encode(dormant) else {
            SportLog.event("seize", "dormant grant arrived but failed to re-encode — NOT stored [seize]")
            return
        }
        defaults.set(data, forKey: DormantKeys.envelope)
        SportLog.event("seize", String(format: "dormant grant refreshed — issued %@, %d dose record(s), token …%@ [seize]",
                                       DateFormatter.localizedString(from: dormant.issuedAt, dateStyle: .none, timeStyle: .medium),
                                       dormant.grant.doseHistory.count,
                                       String(dormant.seizeToken.uuidString.suffix(8))))
    }

    func storedDormantGrant() -> DormantGrant? {
        guard let data = defaults.data(forKey: DormantKeys.envelope) else { return nil }
        return try? LoanProtocol.decoder.decode(DormantGrant.self, from: data)
    }

    static let unexplainedInsulinBand = 0.20

    static func insulinTheCopyCannotExplain(copyTotal: Double, copyAt: Date, podTotal: Double, now: Date,
                                            records: [LoanDoseRecord], schedule: BasalRateSchedule?) -> Double {
        guard now > copyAt, podTotal >= copyTotal else { return 0 }
        let rateEvents = records.filter { $0.kind != .bolus }.enumerated().map {
            LoanEvent(id: UUID(), seq: $0.offset + 1, provenance: .confirmed, record: $0.element, loggedAt: now)
        }
        var expected = LoanReconciler.expectedInsulin(events: rateEvents, schedule: schedule, from: copyAt, to: now)
        for bolus in records where bolus.kind == .bolus {
            guard let amount = bolus.amount, amount > 0 else { continue }
            let end = bolus.endDate ?? bolus.startDate
            if end > bolus.startDate {
                let overlap = min(end, now).timeIntervalSince(max(bolus.startDate, copyAt))
                if overlap > 0 { expected += amount * overlap / end.timeIntervalSince(bolus.startDate) }
            } else if bolus.startDate >= copyAt, bolus.startDate <= now {
                expected += amount
            }
        }
        let unexplained = ((podTotal - copyTotal - expected) * 1000).rounded() / 1000
        return unexplained > unexplainedInsulinBand ? unexplained : 0
    }

    func bookInsulinTheCopyCannotExplain(podTotal: Double, epoch: Int) {
        defer { takeoverCopyTotal = nil; takeoverCopyRecords = [] }
        guard let copy = takeoverCopyTotal else {
            SportLog.event("loan", "takeover book check SKIPPED — the copy carried no pod total to compare against")
            return
        }
        let at = self.now()
        let unexplained = Self.insulinTheCopyCannotExplain(copyTotal: copy.units, copyAt: copy.asOf, podTotal: podTotal, now: at,
                                                           records: takeoverCopyRecords,
                                                           schedule: loopManager.settings.basalRateSchedule)
        let age = at.timeIntervalSince(copy.asOf) / 60
        guard unexplained > 0 else {
            SportLog.event("loan", String(format: "takeover book check CLEAN — pod total %.2f → %.2f U over %.1f min is explained by the copy's records and the schedule",
                                          copy.units, podTotal, age))
            return
        }
        let entry = DoseEntry(type: .bolus, startDate: at, endDate: at, value: unexplained, unit: .units,
                              decisionId: nil, deliveredUnits: unexplained,
                              syncIdentifier: "PODLOAN-WATCHGAP-e\(epoch)",
                              insulinType: pumpManager?.status.insulinType)
        let gate = DispatchSemaphore(value: 0)
        var failure: Error?
        let loopManager = self.loopManager
        Task {
            do { try await loopManager.seedInsulinHistory([entry]) } catch { failure = error }
            gate.signal()
        }
        gate.wait()
        if let failure {
            SportLog.event("loan", String(format: "** takeover book check: %.2f U UNEXPLAINED and the booking FAILED — %@ **", unexplained, String(describing: failure)))
            return
        }
        SportLog.event("loan", String(format: "** takeover book check: pod total %.2f → %.2f U over %.1f min; %.2f U the copy cannot explain — BOOKED as a bolus now (insulin on board errs high, dosing errs low) **",
                                      copy.units, podTotal, age, unexplained))
        startNote = (at, String(format: NSLocalizedString("%.2f U the watch had no record of — counted as insulin on board", comment: "Glance: unexplained insulin booked at takeover (1: units)"), unexplained))
    }

    func returnToRestingPhase() {
        if journal.hasUndrainedEvents {
            phase = .recoveredDrain
            sendHandbackOffer(freshened: false, recovered: true)
        } else {
            phase = .idle
        }
    }

    func requestLoan(watchBuild: String) {
        #if targetEnvironment(simulator)

        let simFakeFlow = defaults.bool(forKey: "sim.fakeLoanFlow")
        SportLog.event("loan", "Start (sim): sim.fakeLoanFlow=\(simFakeFlow) — \(simFakeFlow ? "FAKE flow driver" : "REAL loan protocol")")
        if simFakeFlow { simDriveStart(); return }
        #endif
        queue.async {
            guard self.phase == .idle || self.phase == .recoveredDrain else {
                SportLog.event("loan", "Start ignored — not idle (phase \(self.phase.rawValue))")
                return
            }
            if self.phase == .recoveredDrain {
                SportLog.event("loan", "Start over a parked drain — \(self.journal.unackedEvents().count) undrained event(s) keep resending; a seize would fold them in [seize]")
            }
            self.phase = .requested
            self.attemptStartedAt = self.now()
            self.lastIdleNote = nil

            let reachable = self.isPhoneReachable()

            let timeout: TimeInterval = reachable ? 60 : 8
            SportLog.event("loan", "REQUEST sent (build \(watchBuild)) — awaiting grant\(reachable ? "" : " (phone unreachable — short \(Int(timeout))s timeout)")")
            self.sendMessage(.request(LoanRequest(watchBuild: watchBuild, supportsSeize: true, sentAt: self.now())))

            self.requestTimeoutWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.phase == .requested else { return }

                defer { self.notifyUI() }
                self.returnToRestingPhase()

                self.cancelStaleQueuedRequests(context: "request timed out")

                if let dormant = self.storedDormantGrant() {
                    self.seizeOffer = (issuedAt: dormant.issuedAt, token: dormant.seizeToken)
                    self.lastIdleNote = nil
                    SportLog.event("seize", String(format: "REQUEST TIMED OUT (reachable=%@) — offering offline start (credential issued %@) [seize]",
                                                   self.isPhoneReachable() ? "Y" : "N",
                                                   DateFormatter.localizedString(from: dormant.issuedAt, dateStyle: .short, timeStyle: .short)))
                    return
                }

                if self.isPhoneReachable() {
                    SportLog.event("loan", "REQUEST TIMED OUT with phone REACHABLE — one-way wedge signature (#113)")
                }
                self.lastIdleNote = NSLocalizedString("No response from iPhone — check the phone (loan refused, or busy) and try again.", comment: "Glance: loan request timed out")
                SportLog.event("loan", "REQUEST TIMED OUT — no grant in \(Int(timeout))s (phone refused / busy / unreachable)")
            }
            self.requestTimeoutWork = work
            self.schedule(after: timeout, label: "request-timeout", execute: work)
        }
    }

    static func decodeTherapySettings(raw: Data, supplement: Data?) -> LoopSettings? {
        var decodedSettings: LoopSettings?
        if let raw = (try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil)) as? LoopSettings.RawValue {
            decodedSettings = LoopSettings(rawValue: raw)
        }

        if var s = decodedSettings, let data = supplement,
           let supplement = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            if let raw = supplement["basalRateSchedule"] as? BasalRateSchedule.RawValue {
                s.basalRateSchedule = BasalRateSchedule(rawValue: raw)
            }
            if let raw = supplement["insulinSensitivitySchedule"] as? InsulinSensitivitySchedule.RawValue {
                s.insulinSensitivitySchedule = InsulinSensitivitySchedule(rawValue: raw)
            }
            if let raw = supplement["carbRatioSchedule"] as? CarbRatioSchedule.RawValue {
                s.carbRatioSchedule = CarbRatioSchedule(rawValue: raw)
            }
            if let raw = supplement["defaultRapidActingModel"] as? ExponentialInsulinModelPreset.RawValue {
                s.defaultRapidActingModel = ExponentialInsulinModelPreset(rawValue: raw)
            }
            decodedSettings = s
            SportLog.event("loan", "grant settings supplement applied — basal \(s.basalRateSchedule == nil ? "MISSING" : "ok"), ISF \(s.insulinSensitivitySchedule == nil ? "MISSING" : "ok"), CR \(s.carbRatioSchedule == nil ? "MISSING" : "ok"), model \(s.defaultRapidActingModel.map { String(describing: $0) } ?? "default")")
        }
        return decodedSettings
    }

    func handleGrant(_ grant: LoanGrant) {
        SportLog.event("loan", "GRANT received — epoch \(grant.epoch), \(grant.pumpManagerRawState.count)B pod state")

        if !seizeActivationInFlight { pendingSeizeToken = nil }

        guard phase == .idle || phase == .requested || phase == .recoveredDrain else {
            SportLog.event("loan", "grant ignored — wrong phase (\(phase.rawValue))")

            if phase == .active, (epoch ?? Int.min) >= grant.epoch {
                sendHoldsPodStatusReport(reason: "stale grant e\(grant.epoch) refused")
            }
            return
        }
        requestTimeoutWork?.cancel()

        func rejectGrant(_ reason: String, notifyPhone: Bool) {
            SportLog.event("loan", "grant REJECTED — \(reason); returning to resting so Start works again")
            if notifyPhone {
                sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: reason)))
            }
            returnToRestingPhase()
        }
        guard self.now() < grant.expiresAt || seizeActivationInFlight else {
            rejectGrant("grant expired", notifyPhone: true)
            return
        }
        if let known = epoch, grant.epoch <= known, !seizeActivationInFlight {
            rejectGrant("stale epoch \(grant.epoch) (known \(known))", notifyPhone: false)
            return
        }

        if let revoked = lastRevokedEpoch, grant.epoch <= revoked {
            rejectGrant("epoch \(grant.epoch) at or below the last revoke (ev=\(revoked)); the phone already asked for the pod back",
                        notifyPhone: true)
            return
        }

        if !seizeActivationInFlight, grant.epoch <= defaults.integer(forKey: Keys.highWaterEpoch) {
            rejectGrant("epoch \(grant.epoch) already accepted once (high-water \(defaults.integer(forKey: Keys.highWaterEpoch))) — a late duplicate",
                        notifyPhone: false)
            return
        }

        let decodedSettings = Self.decodeTherapySettings(raw: grant.therapySettingsRaw, supplement: grant.therapySettingsSupplementRaw)
        let missing: String? = {
            guard let s = decodedSettings else { return "settings snapshot" }
            if s.basalRateSchedule == nil { return "basal schedule" }
            if s.insulinSensitivitySchedule == nil { return "insulin sensitivity" }
            if s.carbRatioSchedule == nil { return "carb ratio" }
            if s.glucoseTargetRangeSchedule == nil { return "glucose target range" }
            if s.maximumBasalRatePerHour == nil { return "max basal rate" }
            if s.maximumBolus == nil { return "max bolus" }
            return nil
        }()
        if let missing = missing {
            returnToRestingPhase()
            lastIdleNote = String(format: NSLocalizedString("Can't start: %@ didn't arrive from the phone. Check therapy settings and try again.", comment: "Glance: grant refused for incomplete settings (1: missing field)"), missing)
            SportLog.event("loan", "grant REFUSED — therapy settings incomplete (\(missing))")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "therapy settings incomplete: \(missing)")))
            return
        }

        if seizeActivationInFlight, journal.hasUndrainedEvents {
            let carried = journal.adoptEpoch(grant.epoch)
            SportLog.event("seize", "journal FOLDED — \(carried) undrained event(s) carried into epoch \(grant.epoch); the drain rides this loan's stream [seize]")

            if let token = pendingSeizeToken {
                defaults.set(token.uuidString, forKey: DormantKeys.activeToken)
                pendingSeizeToken = nil
                SportLog.event("seize", "reunion token …\(String(token.uuidString.suffix(8))) persisted at FOLD — the folded drain needs the retro-ack door [seize]")
            }
        } else {
            do {
                try journal.begin(epoch: grant.epoch)
            } catch {
                rejectGrant("undrained prior loan must drain first", notifyPhone: true)
                return
            }
        }

        epoch = grant.epoch

        defaults.set(max(defaults.integer(forKey: Keys.highWaterEpoch), grant.epoch), forKey: Keys.highWaterEpoch)
        phoneSupportsInterimHandback = grant.supportsInterimHandback ?? false
        phoneSupportsOverrideRecords = grant.supportsOverrideRecords ?? false
        handbackRequested = false
        finalOfferSent = false

        attemptStartedAt = self.now()
        lastTakeoverReadAt = nil
        takeoverMaxReadGap = 0
        PodLoanConnectClock.reset()

        PodLoanConnectClock.appStateProbe = { RuntimeStateLog.appStateName() }
        RuntimeStateLog.probeTimerDeferral("takeover-start")
        phase = .takingOver
        loopManager.settings = decodedSettings!

        var payload: [String: Any] = ["raw": grant.therapySettingsRaw,
                                      "interim": grant.supportsInterimHandback ?? false,
                                      "overrideRecords": grant.supportsOverrideRecords ?? false]
        if let supplement = grant.therapySettingsSupplementRaw { payload["supplement"] = supplement }
        defaults.set(payload, forKey: Keys.grantedTherapySettings)

        if let raw = grant.activeOverrideRaw {
            if let plist = (try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil)) as? TemporaryScheduleOverride.RawValue,
               let override = TemporaryScheduleOverride(rawValue: plist) {
                loopManager.scheduleOverride = override
            } else {
                SportLog.event("override", "grant carried an override the watch could NOT decode — this loan doses UNSCALED; re-tap the preset on the wrist")
            }
        }

        loopManager.setIntegralRetrospectiveCorrection(grant.integralRetrospectiveCorrectionEnabled ?? false)

        loopManager.setClosedLoopEnabled(grant.phoneClosedLoopEnabled ?? false,
                                         reason: grant.phoneClosedLoopEnabled == nil
                                            ? "(older phone sent no loop mode — defaulting open)"
                                            : "inherited from the phone at grant")

        if let phoneLoop = grant.lastLoopCompleted {
            loopManager.seedLastLoopCompleted(phoneLoop, source: "phone at grant")
        }

        ingestPredictionSnapshot(grant)

        if let s = decodedSettings {
            let now = self.loopManager.now()
            let isf = s.insulinSensitivitySchedule?.quantity(at: now).doubleValue(for: .milligramsPerDeciliter)
            let cr = s.carbRatioSchedule?.value(at: now)
            let basal = s.basalRateSchedule?.value(at: now)
            let target = s.glucoseTargetRangeSchedule?.quantityRange(at: now)
            let lo = target?.lowerBound.doubleValue(for: .milligramsPerDeciliter)
            let hi = target?.upperBound.doubleValue(for: .milligramsPerDeciliter)
            let csf = (isf != nil && cr != nil && cr! > 0) ? isf! / cr! : nil
            SportLog.event("settings", String(
                format: "granted @now — ISF %@ mg/dL/U · CR %@ g/U · CSF %@ mg/dL/g · basal %@ U/hr · target %@-%@ · maxBasal %@ U/hr · maxBolus %@ U",
                isf.map { String(format: "%.0f", $0) } ?? "nil",
                cr.map { String(format: "%.1f", $0) } ?? "nil",
                csf.map { String(format: "%.2f", $0) } ?? "nil",
                basal.map { String(format: "%.2f", $0) } ?? "nil",
                lo.map { String(format: "%.0f", $0) } ?? "nil",
                hi.map { String(format: "%.0f", $0) } ?? "nil",
                s.maximumBasalRatePerHour.map { String(format: "%.2f", $0) } ?? "nil",
                s.maximumBolus.map { String(format: "%.2f", $0) } ?? "nil"))

            if let o = self.loopManager.scheduleOverride, o.isActive(at: now) {
                let f = o.settings.effectiveInsulinNeedsScaleFactor
                SportLog.event("settings", String(
                    format: "override ACTIVE '%@' × %.2f insulin needs — effective ISF %@ mg/dL/U · CR %@ g/U · basal %@ U/hr (dosing uses THESE, not the schedule above)",
                    o.context.presetNameForLog,
                    f,
                    isf.map { String(format: "%.0f", $0 / f) } ?? "nil",
                    cr.map { String(format: "%.1f", $0 / f) } ?? "nil",
                    basal.map { String(format: "%.2f", $0 * f) } ?? "nil"))
            }
        }

        guard let rawValue = (try? PropertyListSerialization.propertyList(from: grant.pumpManagerRawState, options: [], format: nil)) as? [String: Any],
              var rawState = rawValue["state"] as? PumpManager.RawStateValue else {
            teardownPump()
            returnToRestingPhase()
            lastIdleNote = NSLocalizedString("Couldn't read the pod from the phone. Try again.", comment: "Glance: pump snapshot rejected")
            SportLog.event("loan", "grant FAILED — could not rebuild the pump from the phone's snapshot")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "pump state snapshot rejected")))
            return
        }

        takeoverCachedHandle = nil
        var cachedHandle: String?
        if var podRaw = rawState["podState"] as? [String: Any],
           let address = podRaw["address"] as? UInt32 {
            cachedHandle = PodLoanBleIdentifierCache.identifier(forPodAddress: address)
            if let cachedHandle {
                takeoverCachedHandle = (address, cachedHandle)
                podRaw["bleIdentifier"] = cachedHandle
                rawState["podState"] = podRaw
            }
            SportLog.event("loan", String(format: "handle for pod %08X: %@", address,
                                          cachedHandle.map { "CACHED \($0) — skipping discovery" } ?? "none yet — will discover"))
        }

        rawState["podConnectionReleased"] = false
        guard let manager = OmniPumpManager(rawState: rawState) else {
            teardownPump()
            returnToRestingPhase()
            lastIdleNote = NSLocalizedString("Couldn't read the pod from the phone. Try again.", comment: "Glance: pump snapshot rejected")
            SportLog.event("loan", "grant FAILED — could not rebuild the pump from the phone's snapshot")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "pump state snapshot rejected")))
            return
        }

        manager.pumpManagerDelegate = self
        manager.delegateQueue = queue
        pumpManager = manager
        defaults.set(manager.rawState, forKey: Keys.pumpState)

        if let units = manager.podLoanInsulinDelivered, let asOf = manager.podLoanInsulinDeliveredAt {
            takeoverCopyTotal = (units, asOf)
        } else {
            takeoverCopyTotal = nil
        }
        takeoverCopyRecords = grant.doseHistory
        guard ingestGrantHistory(grant) else {
            teardownPump()
            returnToRestingPhase()
            lastIdleNote = NSLocalizedString("Couldn't build the insulin book from the phone's history. Try again.", comment: "Glance: insulin book seed failed")
            SportLog.event("loan", "grant FAILED — the insulin book could not be seeded from the phone's history")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "insulin book seed failed")))
            return
        }

        let discover = takeoverCachedHandle == nil
        let armed = manager.podLoanBeginTakeover(discover: discover)
        SportLog.event("loan", "pump rebuilt — \(armed ? (discover ? "takeover scan armed" : "cached handle — the first read dials") : "no pod address!")")

        SportLog.event("loan", String(format: "takeover ladder start — lease %+.0fs, epoch %d%@",
                                      grant.expiresAt.timeIntervalSince(now()), grant.epoch,
                                      seizeMarkerActive ? " [seize]" : ""))
        queue.async { [weak self] in self?.attemptTakeoverRead(manager: manager, grant: grant, attempt: 0) }
    }

    func setTakeoverSessionListener(_ armed: Bool) {
        guard armed else {
            PodLoanConnectClock.podLoanOnSessionEstablished = nil
            takeoverBackstop?.cancel()
            takeoverBackstop = nil
            takeoverRetryAction = nil
            return
        }
        PodLoanConnectClock.podLoanOnSessionEstablished = { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                guard self.phase == .takingOver, let action = self.takeoverRetryAction else { return }
                SportLog.event("loan", "takeover: pod session ESTABLISHED (stack event) — reading now instead of waiting for the backstop")
                self.takeoverRetryAction = nil
                self.takeoverBackstop?.cancel()
                self.takeoverBackstop = nil
                self.schedule(after: 0.25, label: "session-event-settle") { action() }
            }
        }
    }

    func attemptTakeoverRead(manager: OmniPumpManager, grant: LoanGrant, attempt: Int, driver: String = "initial") {
        let maxAttempts = 14
        manager.podLoanReadStatus { [weak self] success in
            guard let self = self else { return }
            self.queue.async {
                guard self.phase == .takingOver, self.epoch == grant.epoch else {
                    SportLog.event("loan", "TAKEOVER SUPERSEDED — epoch \(grant.epoch) abandoned mid-ladder (now phase \(self.phase.rawValue), epoch \(self.epoch.map(String.init) ?? "nil"))")
                    return
                }

                guard self.now() < grant.expiresAt else {
                    self.teardownPump()
                    self.returnToRestingPhase()

                    let wedged = PodLoanConnectClock.wedgeSignature(since: self.attemptStartedAt)
                    if wedged {
                        self.lastIdleNote = NSLocalizedString("The pod didn't answer. Turn watch Bluetooth off and on, then try again.", comment: "Glance: takeover failed with the BLE-wedge signature")
                    } else {
                        self.lastIdleNote = NSLocalizedString("Sport Mode start expired before the pod answered. Tap Start to try again.", comment: "Glance: grant lease expired mid-takeover")
                    }
                    SportLog.event("loan", "TAKEOVER ABORTED — grant lease expired mid-takeover after \(attempt + 1) read(s), epoch \(grant.epoch), wedgeSignature=\(wedged)\(self.seizeMarkerActive ? " [seize]" : "")")
                    self.sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "grant expired mid-takeover")))
                    return
                }
                if success, let delivered = manager.podLoanInsulinDelivered {
                    self.revokeCapturedDelivered = nil
                    self.revokeCapturedDeliveredAt = nil
                    self.deliveredAtTakeover = delivered
                    self.defaults.set(delivered, forKey: Keys.deliveredAtTakeover)
                    self.phase = .active

                    if let token = self.pendingSeizeToken {
                        self.defaults.set(token.uuidString, forKey: DormantKeys.activeToken)
                        self.pendingSeizeToken = nil
                        SportLog.event("seize", "seized loan ACTIVE — reunion token …\(String(token.uuidString.suffix(8))) persisted for the offer echo [seize]")
                    }
                    self.loopManager.pumpManager = manager
                    self.onLoanActiveChanged?(true)
                    let takeoverSecs = self.attemptStartedAt.map { self.now().timeIntervalSince($0) } ?? -1
                    SportLog.event("loan", String(format: "ACTIVE — epoch %d, pod taken after %d read(s) in %.1fs [takeover-timing], odometer %.2f U, final read driver=%@ · %@",
                                                  grant.epoch, attempt + 1, takeoverSecs, delivered, driver, RuntimeStateLog.snapshot()))
                    self.sendMessage(.takeoverComplete(TakeoverComplete(epoch: grant.epoch, firstPodStatus: self.currentPodStatus())))

                    self.bookInsulinTheCopyCannotExplain(podTotal: delivered, epoch: grant.epoch)
                    self.loopManager.loop()
                } else if attempt + 1 < maxAttempts {
                    if attempt == 0 {
                        SportLog.event("loan", "connecting to pod… (BLE session establishing; typically ~17s, budget ~40s)")
                    }

                    let readElapsed = self.attemptStartedAt.map { self.now().timeIntervalSince($0) } ?? -1

                    let readNow = self.now()
                    if let prev = self.lastTakeoverReadAt {
                        self.takeoverMaxReadGap = max(self.takeoverMaxReadGap, readNow.timeIntervalSince(prev))
                    }
                    self.lastTakeoverReadAt = readNow

                    if attempt < 3 { RuntimeStateLog.probeTimerDeferral("ladder-read\(attempt + 1)") }

                    SportLog.event("loan", String(format: "takeover read %d/%d driver=%@ (+%.1fs) — pod BLE state %@ · %@ · %@ · %@",
                                                  attempt + 1, maxAttempts, driver, readElapsed,
                                                  manager.podLoanConnectionStateDescription,
                                                  PodLoanConnectClock.summary(since: self.attemptStartedAt),
                                                  self.g7StateForContention(),
                                                  RuntimeStateLog.snapshot()))

                    let fireRetry: (String) -> Void = { [weak self] nextDriver in
                        guard let self = self else { return }
                        self.takeoverRetryAction = nil
                        self.takeoverBackstop = nil
                        guard self.phase == .takingOver, self.epoch == grant.epoch else {
                            SportLog.event("loan", "TAKEOVER SUPERSEDED — epoch \(grant.epoch) abandoned between reads (now phase \(self.phase.rawValue), epoch \(self.epoch.map(String.init) ?? "nil"))")
                            return
                        }
                        self.attemptTakeoverRead(manager: manager, grant: grant, attempt: attempt + 1, driver: nextDriver)
                    }
                    self.takeoverRetryAction = { fireRetry("event") }
                    let backstop = DispatchWorkItem { fireRetry("backstop") }
                    self.takeoverBackstop = backstop
                    self.schedule(after: 8, label: "takeover-read", execute: backstop)
                } else {
                    self.teardownPump()
                    self.returnToRestingPhase()
                    let failSecs = self.attemptStartedAt.map { self.now().timeIntervalSince($0) } ?? -1

                    let stalled = self.takeoverMaxReadGap > 20
                    let wedged = !stalled && PodLoanConnectClock.wedgeSignature(since: self.attemptStartedAt)
                    if stalled {
                        self.lastIdleNote = String(format: NSLocalizedString(
                            "Sport Mode didn't start — the watch app stopped running mid-connect (%@). Your phone still has the pod. Keep the watch awake — wrist up or screen on — and try again.",
                            comment: "Glance: takeover failed because the app was suspended"), batteryTag())
                    } else {
                        self.lastIdleNote = NSLocalizedString(
                            "Sport Mode didn't start — the pod couldn't be reached. Your phone still has it and is still looping.",
                            comment: "Glance: takeover failed — the pod link never established")
                    }
                    SportLog.event("loan", String(format: "TAKEOVER FAILED wedge=%@ — %@ after %d reads in %.1fs [takeover-timing], max inter-read gap %.1fs (event-driven; 8s backstop when no event fires), %@, final BLE state %@, %@, %@, epoch %d%@",
                                                  wedged ? "YES" : "no",
                                                  stalled ? "ladder STALLED (our polling was deferred; see cb: for whether the link was up)" : "pod unreachable",
                                                  maxAttempts, failSecs, self.takeoverMaxReadGap, batteryTag(),
                                                  manager.podLoanConnectionStateDescription,
                                                  PodLoanConnectClock.summary(since: self.attemptStartedAt),
                                                  RuntimeStateLog.snapshot(), grant.epoch,
                                                  self.seizeMarkerActive ? " [seize]" : ""))

                    self.sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: stalled ? "watch app suspended mid-takeover" : (wedged ? "watch Bluetooth wedged — toggle needed" : "couldn't establish the pod link"))))
                    if let trusted = self.takeoverCachedHandle, PodLoanConnectClock.connectCount == 0 {
                        PodLoanBleIdentifierCache.forget(podAddress: trusted.address)
                        SportLog.event("loan", "takeover: cached handle \(trusted.handle) never connected — FORGOTTEN; the next Start discovers")
                    }
                }
            }
        }
    }
}
