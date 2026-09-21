//
//  PodLoanWatchController+Start.swift
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

    func g7StateForContention() -> String {
        loopManager.g7ContentionSummary
    }

    func ingestGrantHistory(_ grant: LoanGrant) -> Bool {
        let seedReconciliation = self.now()
        let (entries, liveDoses) = grant.seedDoseEntries(finishedBy: seedReconciliation)
        let epoch = grant.epoch
        let grossImpliedSum = entries.reduce(0.0) { $0 + $1.programmedUnits }
        let liveNote = liveDoses.isEmpty ? "" :
            String(format: "; %d live — delivery tracked from pod state (#72), latest ends +%.0fm",
                   liveDoses.count, (liveDoses.map { $0.endDate }.max()!.timeIntervalSince(seedReconciliation)) / 60)

        let gate = DispatchSemaphore(value: 0)
        var seedError: Error?
        let loopManager = self.loopManager
        Task {
            await loopManager.resetInsulinBook(reason: "new grant (epoch \(epoch))")
            do { try await loopManager.seedInsulinHistory(entries) } catch { seedError = error }
            gate.signal()
        }
        gate.wait()
        if let seedError {
            SportLog.event("loan", "** INSULIN BOOK SEED FAILED — \(String(describing: seedError)) — refusing the takeover: a wrist without the phone's history must not dose **")
            return false
        }
        SportLog.event("loan", String(format: "insulin book seeded from grant — %d finished record(s) under the phone's identities%@ · grossImpliedΣ=%.2fU",
                                       entries.count, liveNote, grossImpliedSum))

        loopManager.primeIOBFromStore(at: seedReconciliation) { iob in
            guard let iob = iob else {
                SportLog.event("loan", "SEED-IN IOB unavailable (no schedule yet)")
                return
            }
            SportLog.event("loan", String(format: "SEED-IN IOB=%.2fU @ takeover (%d seeded doses: %d finished%@)",
                                          iob, entries.count + liveDoses.count, entries.count, liveNote))
            self.loopManager.dumpIOBDecomp("SEED-IN", at: seedReconciliation)
        }
        ingestGrantCarbs(grant)
        ingestGrantGlucose(grant)
        return true
    }

    func ingestGrantCarbs(_ grant: LoanGrant) {
        let phoneCOB = grant.predictionSnapshot?.cobGrams
        let phoneCOBStr = phoneCOB.map { String(format: "%.1f", $0) } ?? "n/a"

        let snapshotAge = grant.predictionSnapshot.map { self.now().timeIntervalSince($0.snapshotAt) }
        let carbs = grant.carbHistory ?? []
        let objects: [SyncCarbObject] = carbs.map { c in
            SyncCarbObject(
                absorptionTime: c.absorptionTime,
                createdByCurrentApp: false,
                foodType: c.foodType,
                grams: c.grams,
                startDate: c.startDate,
                uuid: nil,
                provenanceIdentifier: c.provenanceIdentifier,
                syncIdentifier: c.syncIdentifier,
                syncVersion: c.syncVersion,
                userCreatedDate: c.userCreatedDate,
                userUpdatedDate: c.userUpdatedDate,
                userDeletedDate: nil,
                operation: .create,
                addedDate: nil,
                supercededDate: nil)
        }
        let seededGrams = carbs.reduce(0.0) { $0 + $1.grams }
        let source = (grant.carbHistory == nil) ? "absent(old phone)"
                   : (carbs.isEmpty ? "empty(deleted on phone)→wipe" : "\(objects.count) entr\(objects.count == 1 ? "y" : "ies")")
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let manifest = carbs.isEmpty ? "—" : carbs.map { c in
            String(format: "%.1fg@%@ sync=%@ prov=%@", c.grams, tf.string(from: c.startDate),
                   c.syncIdentifier ?? "nil", String(c.provenanceIdentifier.prefix(12)))
        }.joined(separator: " | ")

        loopManager.carbStore.setSyncCarbObjects(objects) { [weak self] error in
            if let error = error {
                os_log("Grant carb replace failed: %{public}@", log: OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanWatchController"), type: .error, String(describing: error))
                return
            }

            guard let self = self else { return }
            let expectedIDs = Set(carbs.compactMap { $0.syncIdentifier })
            let readFrom = (carbs.map(\.startDate).min() ?? self.now()).addingTimeInterval(-3600)
            self.loopManager.carbStore.getCarbEntries(start: readFrom) { result in
                var verdict: String
                switch result {
                case .failure(let e):

                    verdict = " ⚠ wipe UNVERIFIED (read-back failed: \(e))"
                case .success(let stored):
                    let storedIDs = Set(stored.compactMap { $0.syncIdentifier })
                    let residual = storedIDs.subtracting(expectedIDs)
                    let missing = expectedIDs.subtracting(storedIDs)
                    let dupes = stored.count - storedIDs.count
                    if residual.isEmpty && missing.isEmpty && dupes == 0 {
                        verdict = " · wipe verified \(stored.count)/\(expectedIDs.count)"
                    } else {
                        verdict = String(format: " ⚠ WIPE FAILED — %d residual, %d missing, %d duplicate",
                                         residual.count, missing.count, dupes)
                    }
                }
                self.loopManager.glanceCarbsOnBoard { cob in
                    let postV = cob ?? 0
                    let vsPhone = phoneCOB.map { postV - $0 }

                    let ageStr = snapshotAge.map { "\(Int($0.rounded()))s" } ?? "n/a"
                    SportLog.event("cob-diff", String(format: "REPLACE %@ · phoneCOB=%@ g (snapshot age %@) · watch COB(post)=%.2f g · replaced %.0f g · Δ(post−phone)=%@ g (observation freshness, not a model split)%@ · [%@]",
                                                       source, phoneCOBStr, ageStr, postV, seededGrams,
                                                       vsPhone.map { String(format: "%+.2f", $0) } ?? "—",
                                                       verdict, manifest))
                }
            }
        }
    }

    func ingestGrantGlucose(_ grant: LoanGrant) {
        guard let records = grant.glucoseHistory, !records.isEmpty else { return }
        let mgdl = LoopUnit.milligramsPerDeciliter
        let mgdlPerMin = mgdl.unitDivided(by: .minute)
        let samples: [NewGlucoseSample] = records.map { r in
            NewGlucoseSample(
                date: r.startDate,
                quantity: LoopQuantity(unit: mgdl, doubleValue: r.valueMgdl),
                condition: nil,
                trend: nil,
                trendRate: r.trendRateMgdlPerMin.map { LoopQuantity(unit: mgdlPerMin, doubleValue: $0) },
                isDisplayOnly: r.isDisplayOnly,
                wasUserEntered: r.wasUserEntered,
                syncIdentifier: r.syncIdentifier ?? "loanv2-glucose-\(Int(r.startDate.timeIntervalSince1970 * 1000))")
        }

        loopManager.notePhoneGlucoseDelivered()
        Task {
            do {
                let stored = try await loopManager.glucoseStore.addGlucoseSamples(samples)

                SportLog.event("glucose", "INGEST src=grant-seed stored=\(stored.count)/\(samples.count) · loan takeover warm-up")
                SportLog.event("loan", "seeded \(stored.count) glucose sample\(stored.count == 1 ? "" : "s") from the phone (momentum/RC warm-up)")
            } catch {
                os_log("Grant glucose ingest failed: %{public}@", log: OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanWatchController"), type: .error, String(describing: error))
            }
        }
    }

    func ingestPredictionSnapshot(_ grant: LoanGrant) {
        loopManager.stashPhonePredictionSnapshot(grant.predictionSnapshot)
        guard let s = grant.predictionSnapshot else { return }
        let now = self.now()
        SportLog.event("snapshot", String(format:
            "RX phone@grant — eventual %.0f start %.0f@%.0fs IOB %.2f@%.0fs COB %.0f · impact mom %+.0f ins %+.0f carb %+.0f RC %+.0f · momPts %d rcDisc %d · snapAge %.0fs",
            s.eventualMgdl, s.startGlucoseMgdl, now.timeIntervalSince(s.startGlucoseDate),
            s.iobUnits, now.timeIntervalSince(s.iobDate), s.cobGrams,
            s.impactMomentumMgdl, s.impactInsulinMgdl, s.impactCarbMgdl, s.impactRCMgdl,
            s.momentumPointCount, s.rcDiscrepancyCount, now.timeIntervalSince(s.snapshotAt)))
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
