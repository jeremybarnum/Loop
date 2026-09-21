//
//  PodLoanWatchController+Handback.swift
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

    private func ingestGrantGlucose(_ grant: LoanGrant) {
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

    func beginHandback() {
        #if targetEnvironment(simulator)
        if defaults.bool(forKey: "sim.fakeLoanFlow") { simDriveHandback(); return }
        #endif
        queue.async {
            guard self.phase == .active, self.pumpManager != nil else { return }
            guard !self.handbackRequested else { return }
            self.reunionPromptActive = false
            self.handbackRequested = true
            self.handbackFailure = nil
            self.handbackResendCount = 0
            self.handbackSawUnreachable = false
            self.handbackSawUrgentSendError = false
            self.urgentSendWedged = false

            self.handbackDeadline = self.now().addingTimeInterval(HandbackStuckAlert.interval)
            self.handbackStartedAt = self.now()
            HandbackStuckAlert.arm()
            guard self.phoneSupportsInterimHandback else {
                SportLog.event("loan", "HAND-BACK started (legacy single-phase — phone predates interim drains)")
                self.finalizeHandback()
                return
            }
            SportLog.event("loan", "HAND-BACK requested — draining \(self.journal.unackedEvents().count) events; still in control (WS1)")
            self.sendHandbackOffer(freshened: false, recovered: false)
        }
    }

    func cancelHandback() {
        queue.async {
            guard self.phase == .active, self.handbackRequested else { return }
            self.handbackRequested = false
            self.resendWorkItem?.cancel()
            self.handbackDeadline = nil
            self.handbackStartedAt = nil
            HandbackStuckAlert.disarm()
            SportLog.event("loan", "HAND-BACK cancelled — Sport Mode continues")
        }
    }

    func handbackTimedOut(unreachable: Bool = false, refusal: String? = nil) {
        let why: String
        if let refusal { why = "REFUSED by the phone — \(refusal)" }
        else if unreachable { why = "not possible — iPhone not reachable, no offer sent" }
        else { why = "timed out (\(Int(HandbackStuckAlert.interval))s) — iPhone never acked" }
        handbackFailure = (now(), refusal ?? (unreachable
            ? NSLocalizedString("iPhone not reachable — still running", comment: "Glance transient: End failed, phone unreachable")
            : NSLocalizedString("iPhone didn't respond — still running", comment: "Glance transient: End failed, no ack")))
        resendWorkItem?.cancel()
        handbackDeadline = nil
        handbackStartedAt = nil
        let wasFinal = (phase == .handingBack)
        let wedge = HandbackWedge.classify(resendCount: handbackResendCount,
                                           sawUnreachable: handbackSawUnreachable,
                                           reachableNow: isPhoneReachable(),
                                           sendsErrored: handbackSawUrgentSendError)
        let wedgeSuffix: String
        switch wedge {
        case .sessionReestablishing:
            wedgeSuffix = " · ** \(handbackResendCount) offers, phone reachable, zero acks — but the sends themselves ERRORED: session re-establishing (#113 variant B), usually self-heals in 1-2 min **"
        case .oneWay:
            wedgeSuffix = " · ** \(handbackResendCount) offers, phone REACHABLE throughout, zero acks — transport wedge (#113 variant A); restarting the WATCH app is the known recovery **"
        case .none:
            wedgeSuffix = ""
        }
        handbackRequested = false
        finalOfferSent = false
        if wasFinal {
            SportLog.event("loan", "HAND-BACK \(why) (final); staying RELEASED — the pod is let go and the records keep offering; the phone resumes when the offer lands\(wedgeSuffix)")
            teardownPump()
            finalOfferSentAt = nil
            deliveredAtTakeover = nil
            onLoanActiveChanged?(false)

            phase = .recoveredDrain
            sendHandbackOffer(freshened: false, recovered: true)
            issueProtocolAlert(title: NSLocalizedString("End Not Confirmed", comment: "Watch alert title: the phone has not confirmed a hand-back"),
                               body: NSLocalizedString("The watch has stopped dosing and keeps sending its records. If your iPhone hasn't taken over in a minute or two, open Loop on the iPhone and tap the pod tile.", comment: "Watch alert body: released but unconfirmed hand-back"))
        } else {
            SportLog.event("loan", "HAND-BACK \(why) (interim); Sport Mode continues on the watch\(wedgeSuffix)")
        }
        switch wedge {
        case .sessionReestablishing:

            SportLog.event("loan", "hand-back wedge variant B (session re-establishing) — no alert; expected to clear on its own")
        case .oneWay:

            if !wasFinal {
                issueProtocolAlert(title: "End Not Confirmed",
                                   body: "Your iPhone is reachable but hasn't confirmed. Reopening Loop on both devices usually clears this.")
            }
        case .none:
            break
        }

        HandbackStuckAlert.disarm()
    }

    func finalizeHandback() {
        resendWorkItem?.cancel()
        finalOfferSent = false
        guard let manager = pumpManager else {
            handbackRequested = false
            phase = .handingBack
            finalOfferSent = true
            sendHandbackOffer(freshened: false, recovered: false)
            return
        }
        handbackRequested = false
        phase = .handingBack

        loopManager.dumpIOBDecomp("HAND-BACK", at: self.now())
        SportLog.event("loan", "drain complete — finalizing hand-back (loop dosing stops now)")

        let runningTemp: DoseEntry? = {
            if case .tempBasal(let dose) = manager.status.basalDeliveryState { return dose }
            return nil
        }()
        loopManager.pumpManager = nil

        if runningTemp != nil {
            SportLog.event("loan", String(format: "hand-back: our temp (%.2f U/hr until %@) stays live until the phone cancels it on reclaim (R33, phone-enforced)",
                                          runningTemp?.unitsPerHour ?? 0,
                                          runningTemp.map { ISO8601DateFormatter().string(from: $0.endDate) } ?? "—"))
        }

        do {
            let finalize: (Bool) -> Void = { freshened in
                self.queue.async {
                    self.finalOfferSent = true
                    self.sendHandbackOffer(freshened: freshened, recovered: false)
                }
            }
            if manager.isConnectionReady {
                manager.podLoanReadStatus { first in
                    let delivered = manager.podLoanInsulinDelivered
                    if first, delivered != nil, delivered == self.deliveredAtTakeover {
                        manager.podLoanReadStatus { second in finalize(second) }
                    } else {
                        finalize(first)
                    }
                }
            } else {
                SportLog.event("loan", "hand-back: freshen SKIPPED — no live pod link; the phone's reclaim read is authoritative")
                finalize(false)
            }
        }
    }

    func sendHandbackOffer(freshened: Bool, recovered: Bool) {
        guard let epoch = epoch ?? journal.activeEpoch else { return }
        var odometer: LoanOdometerSnapshot?
        if let start = deliveredAtTakeover,
           let latest = pumpManager?.podLoanInsulinDelivered ?? revokeCapturedDelivered {
            odometer = LoanOdometerSnapshot(deliveredAtStart: start, deliveredLatest: latest, freshenSucceeded: freshened,
                                            asOf: pumpManager?.podLoanInsulinDeliveredAt ?? revokeCapturedDeliveredAt)
        }
        let offerEvents = journal.unackedEvents()
        let offer = HandbackOffer(
            epoch: epoch,
            handedBackAt: self.now(),
            finalStatus: pumpManager.map { _ in currentPodStatus() },
            odometer: odometer,
            events: offerEvents,
            tombstones: journal.pendingTombstones(),
            recovered: recovered,
            released: phase != .active,

            watchClosedLoopEnabled: recovered ? nil : loopManager.closedLoopEnabledNonBlocking,

            seizeToken: defaults.string(forKey: DormantKeys.activeToken).flatMap(UUID.init(uuidString:)),

            lastLoopCompleted: loopManager.lastLoopCompleted)
        if offer.released == true, finalOfferSentAt == nil { finalOfferSentAt = self.now() }
        handbackResendCount += 1

        if handbackResendCount == 1 || handbackResendCount % 4 == 0 {
            SportLog.event("loan", "hand-back offer attempt \(handbackResendCount) — waiting for iPhone ack")
        }

        let live = !recovered && phase != .revoked && phase != .recoveredDrain
        let reachableNow = isPhoneReachable()
        if !reachableNow { handbackSawUnreachable = true }
        if live, !reachableNow {
            handbackTimedOut(unreachable: true)
            return
        }
        if lastHandbackReachable != reachableNow {
            SportLog.event("loan", reachableNow
                ? "hand-back: iPhone reachable — offer should ack shortly"
                : "drain: iPhone UNREACHABLE — offer queued, will land when it returns")
            lastHandbackReachable = reachableNow
        }
        sendMessage(.handbackOffer(offer), urgentOnly: live)

        resendWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            if let deadline = self.handbackDeadline, self.now() >= deadline,
               self.phase == .handingBack || (self.phase == .active && self.handbackRequested) {
                self.handbackTimedOut()
                return
            }

            let drain = self.phase == .revoked || self.phase == .recoveredDrain
            if drain, self.handbackResendCount >= Self.maxDrainResends {
                let wedge = HandbackWedge.classify(resendCount: self.handbackResendCount,
                                                   sawUnreachable: self.handbackSawUnreachable,
                                                   reachableNow: self.isPhoneReachable(),
                                                   sendsErrored: self.handbackSawUrgentSendError)
                SportLog.event("loan", "drain GIVING UP after \(self.handbackResendCount) unacked offer(s) [\(wedge)] — the phone owns the pod and has already committed these records; closing to idle")
                self.resendWorkItem?.cancel()
                self.teardownPump()
                self.journal.end()
                self.phase = .idle
                self.epoch = nil
                self.deliveredAtTakeover = nil
                self.handbackDeadline = nil
                self.handbackStartedAt = nil
                self.finalOfferSentAt = nil
                self.handbackRequested = false
                self.finalOfferSent = false
                HandbackStuckAlert.disarm()
                self.onLoanActiveChanged?(false)
                SportLog.event("loan", "CLOSED — drain abandoned, pod already the phone's")
                return
            }
            if self.phase == .handingBack || drain
                || (self.phase == .active && self.handbackRequested) {
                self.sendHandbackOffer(freshened: freshened, recovered: recovered)
            }
        }
        resendWorkItem = work
        schedule(after: 15, label: "handback-resend", execute: work)
    }

    func handleAck(_ ack: HandbackAck) {
        guard let current = epoch ?? journal.activeEpoch, ack.epoch == current else {
            SportLog.event("loan", "ack IGNORED ev=\(ack.epoch) — ours ev=\(epoch.map(String.init) ?? "nil") journal ev=\(journal.activeEpoch.map(String.init) ?? "nil"); stale redelivery or epoch mismatch")
            return
        }
        journal.applyAck(committedCursor: ack.committedCursor)
        guard journal.unackedEvents().isEmpty else { return }

        if phase == .active && handbackRequested {
            finalizeHandback()
            return
        }
        guard phase == .handingBack || phase == .revoked || phase == .recoveredDrain else { return }

        if phase == .handingBack && !finalOfferSent { return }

        resendWorkItem?.cancel()

        let ackWait = finalOfferSentAt.map { self.now().timeIntervalSince($0) }
        SportLog.event("loan", String(format: "ack RECEIVED %@ after the final offer — releasing the pod now",
                                      ackWait.map { String(format: "+%.1fs", $0) } ?? "(no offer stamp)"))
        let releaseBegan = self.now()
        teardownPump()
        SportLog.event("loan", String(format: "pod BLE teardown returned in %.2fs — the phone's standing connect can land from here",
                                      self.now().timeIntervalSince(releaseBegan)))
        finalOfferSentAt = nil
        journal.end()
        phase = .idle
        epoch = nil
        deliveredAtTakeover = nil
        handbackDeadline = nil
        handbackStartedAt = nil
        HandbackStuckAlert.disarm()
        onLoanActiveChanged?(false)
        defaults.removeObject(forKey: DormantKeys.activeToken)
        reunionPromptActive = false
        SportLog.event("loan", "CLOSED — records drained, pod released, cursor \(ack.committedCursor)")
    }

    func handleRevoke(_ revoke: Revoke) {
        if revoke.epoch > (lastRevokedEpoch ?? Int.min) {
            lastRevokedEpoch = revoke.epoch
        }
        guard let current = epoch ?? journal.activeEpoch, revoke.epoch == current else {
            SportLog.event("loan", "revoke ev=\(revoke.epoch) matched no live session (epoch \(epoch.map(String.init) ?? "nil"), phase \(phase.rawValue)) — RECORDED; any grant at or below ev=\(revoke.epoch) will now be refused")

            if phase == .active, (epoch ?? Int.min) > revoke.epoch {
                sendHoldsPodStatusReport(reason: "stale revoke e\(revoke.epoch) refused")
            }
            return
        }
        guard phase != .idle else { return }

        handbackRequested = false
        handbackDeadline = nil
        handbackStartedAt = nil
        HandbackStuckAlert.disarm()

        revokeCapturedDelivered = pumpManager?.podLoanInsulinDelivered
        revokeCapturedDeliveredAt = pumpManager?.podLoanInsulinDeliveredAt
        loopManager.pumpManager = nil
        teardownPump()
        phase = .revoked
        onLoanActiveChanged?(false)
        SportLog.event("loan", "REVOKED — phone reclaimed the pod, draining records")
        sendHandbackOffer(freshened: false, recovered: true)
    }

    func drainRecoveredIfNeeded() {
        queue.async {
            if let epoch = self.pendingInterruptedTakeoverEpoch {
                self.pendingInterruptedTakeoverEpoch = nil
                SportLog.event("loan", "START INTERRUPTED — takeover was in flight at relaunch; failing it to the phone, epoch \(epoch)")
                self.sendMessage(.takeoverFailed(TakeoverFailed(epoch: epoch, reason: "watch relaunched during takeover")))
            }
            guard self.phase == .recoveredDrain else { return }
            self.sendHandbackOffer(freshened: false, recovered: true)
        }
    }

    func handleStatusQuery(_ query: StatusQuery) {
        guard let current = epoch, query.epoch == current else {
            if phase != .active, (epoch ?? Int.min) < query.epoch {
                SportLog.event("loan", "status query for epoch \(query.epoch) — we have \(epoch.map(String.init) ?? "none") and hold no pod: the grant never reached us (#108)")
                sendMessage(.statusReport(StatusReport(
                    epoch: query.epoch,
                    mode: currentMode(),
                    lastDirectGlucoseAge: nil,
                    lastEventSeq: 0,
                    podFault: nil,
                    holdsPod: false,
                    knowsGrant: false)))
            } else if phase == .active, (epoch ?? Int.min) > query.epoch {
                sendHoldsPodStatusReport(reason: "status query for stale e\(query.epoch)")
            }
            return
        }
        let report = StatusReport(
            epoch: current,
            mode: currentMode(),
            lastDirectGlucoseAge: loopManager.latestGlucoseAge,
            lastEventSeq: journal.lastEventSeq,
            podFault: pumpManager?.podLoanFaultDescription,
            holdsPod: phase == .active,
            knowsGrant: true)
        sendMessage(.statusReport(report))
    }

    func currentMode() -> LoanDosingMode {
        return .closedDirect
    }

    func currentPodStatus() -> LoanPodStatus {
        LoanPodStatus(
            timestamp: self.now(),
            deliveredUnits: pumpManager?.podLoanInsulinDelivered,
            reservoirLevel: nil,
            isSuspended: false,
            faultCode: pumpManager?.podLoanFaultDescription)
    }

}
