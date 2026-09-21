//
//  PodLoanPhoneController+Records.swift
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
    func handleBatch(_ batch: DoseRecordBatch) {
        guard batch.epoch == epoch, state == .loaned || state == .reclaimPending else {
            handbackDiag(batch.epoch, "batch DROPPED — \(batch.events.count) event(s) ev=\(batch.epoch) vs phone ev=\(epoch), state=\(state.rawValue) (recovered via the offer path if the watch still resends)")

            if batch.epoch > epoch, newestForeignLoanEvidence.map({ batch.epoch >= $0.epoch }) ?? true {
                newestForeignLoanEvidence = (batch.epoch, deps.now())
            }

            if state == .owner, batch.epoch > epoch,
               UserDefaults.standard.string(forKey: Keys.dormantSeizeToken) != nil {
                engageInferredLoanYield(evidence: "future-epoch batch e\(batch.epoch) at .owner (live seized loan streaming)")
            }

            if state == .owner, batch.epoch <= epoch,
               lastClosedSessionRevokeAt.map({ deps.now().timeIntervalSince($0) >= 20 }) ?? true {
                lastClosedSessionRevokeAt = deps.now()
                handbackDiag(batch.epoch, "records from a CLOSED session — the watch still thinks it holds the pod; revoke e\(batch.epoch) sent again")
                sendMessage(.revoke(Revoke(epoch: batch.epoch)))
            }
            return
        }
        noteHoldRenewal(sentAt: batch.sentAt)
        stage(events: batch.events, tombstones: batch.tombstones)

        if let snap = batch.odometer {
            considerCheckpoint(snap, context: "batch")
        }
    }

    func installPodLinkCensus() {
        WatchDataManager.podLinkCensus = { [weak self] in
            guard let self, let lendable = self.deps.pumpManager() as? PumpConnectionLendable else {
                return "no pump manager"
            }
            return "released=\(lendable.isConnectionReleased) \(lendable.connectionDiagnostics() ?? "no diagnostics")"
        }
    }

    func handbackDiag(_ epoch: Int, _ text: String) {
        os_log("HANDBACK-DIAG e%d: %{public}@", log: log, type: .default, epoch, text)

        PhoneLog.event("loan", "e\(epoch) \(text)")
        sendMessage(.diag(LoanDiag(epoch: epoch, text: text)))
    }

    func handleHandbackOffer(_ offer: HandbackOffer) {
        if let token = offer.seizeToken, state == .owner || state == .reclaimPending, offer.epoch > epoch,
           token.uuidString == UserDefaults.standard.string(forKey: Keys.dormantSeizeToken) {
            if state == .reclaimPending {
                cancelReclaimLadder()
                handbackDiag(offer.epoch, "[seize] retro-ack arrived MID-RECLAIM — ladder stood down; the aimed revoke got its drain")
            }
            handbackDiag(offer.epoch, "[seize] RETRO-ACK — offer for a SEIZED loan (token …\(String(token.uuidString.suffix(8)))); adopting epoch \(epoch)→\(offer.epoch) as .loaned, reconciling on the normal path")

            clearInferredLoanYield(reason: "retro-ack — the inferred loan is now the adopted loan e\(offer.epoch)")
            epoch = offer.epoch
            state = .loaned
            holdRenewedAt = offer.handedBackAt
            holdLapseNoticedAt = nil

            auditBase = nil
            checkpointsThisLoan = 0
            worstWindowThisLoan = 0
            UserDefaults.standard.removeObject(forKey: Keys.deliveredAtTakeover)

            let anchor = max(offer.events.map(\.record.startDate).min() ?? offer.handedBackAt,
                             deps.now().addingTimeInterval(-.hours(6)))
            loanStartedAt = anchor
            UserDefaults.standard.set(anchor, forKey: Keys.loanStartedAt)
        }

        let isStale = offer.epoch < epoch
        guard offer.epoch == epoch || isStale else {
            os_log("Hand-back offer DROPPED: offer.epoch %d > phone.epoch %d — watch ahead of phone; loan may be stranded (needs reclaim or new request)",
                   log: log, type: .error, offer.epoch, epoch)
            handbackDiag(offer.epoch, "offer DROPPED epoch \(offer.epoch) > phone \(epoch) — phone behind, loan stranded")
            return
        }
        handbackDiag(offer.epoch, "offer RX ev=\(offer.events.count) released=\(offer.released.map { $0 ? "final" : "interim" } ?? "nil") stale=\(isStale) state=\(state.rawValue)")

        if commitInFlight {
            let storedIsFinal = coalescedOffers[offer.epoch]?.released == true
            if !(storedIsFinal && offer.released != true) {
                coalescedOffers[offer.epoch] = offer
            }
            handbackDiag(offer.epoch, "offer COALESCED behind the in-flight write (#118) — \(coalescedOffers.count) waiting")
            return
        }

        let isFinal = offer.released ?? true
        if !isStale, !isFinal { noteHoldRenewal(sentAt: offer.handedBackAt) }
        let canTransition = state == .loaned || state == .reclaimPending || state == .grantOffered
        if !isStale, canTransition, deps.isBluetoothPoweredOff() {
            handbackDiag(offer.epoch, "hand-back REFUSED — this phone's Bluetooth is off, so it could not reclaim the pod; the watch keeps the loan")
            sendMessage(.denied(LoanDenied(reason: NSLocalizedString("iPhone Bluetooth is off — still running", comment: "Hand-back refused: shown on the watch glance"))))
            return
        }
        if !isStale, isFinal, canTransition {
            state = .reconciling

            handbackDiag(offer.epoch, "commit done — ACKing now; the watch cannot release the pod until this lands")
            if let watchClosed = offer.watchClosedLoopEnabled {
                deps.noteWatchClosedLoop(watchClosed)
                handbackDiag(offer.epoch, "loop mode INHERITED from the wrist — phone will resume \(watchClosed ? "CLOSED" : "OPEN")")
            }

            if let watchLoop = offer.lastLoopCompleted {
                deps.noteWatchLoopCompleted(watchLoop)
                handbackDiag(offer.epoch, String(format: "loop recency INHERITED from the wrist — last cycle %.0fs ago", deps.now().timeIntervalSince(watchLoop)))
            }
        }

        let auditThisOffer = !isStale && isFinal && state == .reconciling

        stage(events: offer.events, tombstones: offer.tombstones)

        if !isStale, offer.epoch == epoch, offer.released == false, let snap = offer.odometer {
            considerCheckpoint(snap, context: "interim-offer")
        }

        let ownEventIDs = isStale ? Set(offer.events.map(\.id)) : nil
        let events = staged.values
            .filter { !stagedTombstones.contains($0.id) && !committedIDs.contains($0.id) }
            .filter { ownEventIDs?.contains($0.id) ?? true }
            .sorted { $0.seq < $1.seq }

        let allStagedEvents = staged.values
            .filter { !stagedTombstones.contains($0.id) }
            .sorted { $0.seq < $1.seq }

        let loanStart = loanStartedAt ?? offer.handedBackAt.addingTimeInterval(-.hours(2))
        let input = LoanReconciler.Input(
            events: events,
            schedule: deps.settings().basalRateSchedule,
            loanStart: loanStart,
            loanEnd: offer.handedBackAt,

            isFinalHandback: isFinal)
        let outcome = LoanReconciler.reconcile(input)

        if auditThisOffer {
            let expected = LoanReconciler.expectedInsulin(events: allStagedEvents, schedule: deps.settings().basalRateSchedule,
                                                          from: loanStart, to: offer.handedBackAt)

            let delivered = offer.odometer.map { $0.deliveredLatest - $0.deliveredAtStart }
            let drainCont = outcome.doses.reduce(0.0) { $0 + $1.programmedUnits }
            let drainFloor = outcome.doses.reduce(0.0) { $0 + (($1.programmedUnits * 20).rounded(.down) / 20) }
            let loanMin = offer.handedBackAt.timeIntervalSince(loanStart) / 60
            handbackDiag(offer.epoch, String(format:
                "reconcile[provisional]: delivered=%@ expected=%.3f residual=%@ (tol 0.05) · thisDrain cont=%.3f floor=%.3f · loanMin=%.0f cycles=%d fresh=%@",
                delivered.map { String(format: "%.3f", $0) } ?? "n/a", expected,
                delivered.map { String(format: "%+.3f", $0 - expected) } ?? "n/a",
                drainCont, drainFloor,
                loanMin, allStagedEvents.count, offer.odometer?.freshenSucceeded == true ? "Y" : "N"))

            if isFinal, let start = offer.odometer?.deliveredAtStart {
                let windowStart = auditBase?.units ?? start
                let windowExpected = auditBase.map {
                    LoanReconciler.expectedInsulin(events: allStagedEvents, schedule: deps.settings().basalRateSchedule,
                                                   from: $0.asOf, to: offer.handedBackAt)
                } ?? expected
                if checkpointsThisLoan > 0 {
                    handbackDiag(offer.epoch, String(format:
                        "[checkpoint] verdict window narrowed by %d checkpoint(s): anchor %.3f U (loan start %.3f), window expected %.3f (loan %.3f)",
                        checkpointsThisLoan, windowStart, start, windowExpected, expected))
                }
                pendingHandbackAudit = PendingHandbackAudit(
                    epoch: offer.epoch, deliveredAtStart: windowStart, expected: windowExpected,
                    loanMinutes: loanMin, cycles: allStagedEvents.count,
                    watchLatest: offer.odometer?.deliveredLatest,
                    watchFreshened: offer.odometer?.freshenSucceeded == true,
                    takeoverUnits: start, wholeLoanExpected: expected)
            }
        }

        let doses = outcome.doses

        let committable = events.filter { $0.id != outcome.openEventID }

        let sane = doses.filter { $0.endDate >= $0.startDate }
        if sane.count != doses.count {
            let bad = doses.filter { $0.endDate < $0.startDate }
            handbackDiag(offer.epoch, "** DROPPED \(bad.count) impossible dose(s) (end before start) — writing \(sane.count) of \(doses.count). First: \(bad[0].type) \(bad[0].startDate) -> \(bad[0].endDate) **")
        }

        let writeStart = deps.now()
        handbackDiag(offer.epoch, "write START \(sane.count) dose(s) (final=\(isFinal))")

        commitInFlight = true
        deps.addPumpEvents(newPumpEvents(from: sane), offer.handedBackAt) { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    self.commitInFlight = false
                    self.handbackDiag(offer.epoch, "write FAILED: \(String(describing: error))")
                    os_log("Reconcile write failed: %{public}@", log: self.log, type: .fault, String(describing: error))

                    if let reason = self.pendingForceReclaimReason {
                        self.pendingForceReclaimReason = nil
                        self.forceReclaimToOwner(reason: reason)
                    }
                    return
                }

                var backfillEarliestStart: Date? = nil

                let finishCommit: (Error?) -> Void = { [weak self] backfillError in
                    guard let self = self else { return }
                    self.queue.async {
                        self.commitInFlight = false
                        if let backfillError = backfillError {
                            self.handbackDiag(offer.epoch, "backfill FAILED: \(String(describing: backfillError))")
                            os_log("Loan dose backfill failed: %{public}@", log: self.log, type: .fault, String(describing: backfillError))

                            if let reason = self.pendingForceReclaimReason {
                                self.pendingForceReclaimReason = nil
                                self.forceReclaimToOwner(reason: reason)
                            }
                            return
                        }

                        if !isStale {
                            for carb in outcome.carbs {
                                self.deps.addCarb(carb.entry, carb.eventID.uuidString) { _ in }
                            }

                            for gone in outcome.deletedCarbs {
                                self.handbackDiag(offer.epoch, String(format: "carb DELETE from wrist — %.0f g @ %@ sync=%@", gone.grams, String(describing: gone.startDate), gone.syncIdentifier.map { String($0.prefix(8)) } ?? "nil"))
                                self.deps.deleteCarb(gone) { error in

                                    self.handbackDiag(offer.epoch, error == nil
                                        ? String(format: "carb DELETE applied on phone — %.0f g", gone.grams)
                                        : String(format: "carb DELETE MISSED on phone — %.0f g: %@", gone.grams, String(describing: error!)))
                                }
                            }
                        } else if !outcome.carbs.isEmpty {
                            self.handbackDiag(offer.epoch, "stale offer — \(outcome.carbs.count) carb(s) NOT committed (a dead loan cannot add carbs)")
                        }

                        if !isStale, let change = outcome.overrideChange {
                            self.applyWatchOverride(change, epoch: offer.epoch, isFinal: isFinal)
                        }

                        let newCursor = events.map(\.seq).max() ?? self.committedCursor
                        if !isStale {
                            self.committedCursor = max(self.committedCursor, newCursor)
                            self.committedIDs.formUnion(committable.map(\.id))
                            self.persistCommittedIDs()
                            self.sendMessage(.handbackAck(HandbackAck(epoch: self.epoch, committedCursor: self.committedCursor)))
                            self.handbackDiag(self.epoch, String(format: "write DONE %.0fms → ACK cursor %d", self.deps.now().timeIntervalSince(writeStart) * 1000, self.committedCursor))
                            if isFinal, self.state == .reconciling {
                                self.finishLoanAfterCommit()
                            } else if !isFinal {
                                os_log("Interim drain committed to cursor %d — watch still dosing", log: self.log, type: .default, self.committedCursor)
                            }
                        } else {
                            self.sendMessage(.handbackAck(HandbackAck(epoch: offer.epoch, committedCursor: newCursor, stale: true)))
                        }

                        if let earliest = (sane.map(\.startDate) + (backfillEarliestStart.map { [$0] } ?? [])).min() {
                            self.deps.insulinHistoryRewritten(earliest)
                        }

                        self.retireGapBookingIfExplained(
                            offerEpoch: offer.epoch,
                            dosesJustCommitted: sane,
                            carbsJustCommitted: isStale ? 0 : outcome.carbs.count)
                        self.drainAfterCommit()
                    }
                }

                let backfillOutcome = LoanReconciler.reconcile(LoanReconciler.Input(
                    events: allStagedEvents,
                    schedule: self.deps.settings().basalRateSchedule,
                    loanStart: loanStart,
                    loanEnd: offer.handedBackAt,
                    isFinalHandback: isFinal))
                let backfill = self.storeIdentifiedDoses(from: self.truncatingOverlaps(
                    backfillOutcome.doses.filter { $0.endDate >= $0.startDate }))
                if isStale || backfill.isEmpty {
                    if isStale {
                        self.handbackDiag(offer.epoch, "backfill SKIPPED — a stale offer speaks only for its own records (#102)")
                    }
                    finishCommit(nil)
                } else {
                    self.handbackDiag(offer.epoch, "backfill \(backfill.count) loan-window dose(s) by store identity (e44 boundary)")
                    backfillEarliestStart = backfill.map(\.startDate).min()
                    self.deps.backfillDoses(backfill, finishCommit)
                }
            }
        }
    }

    func drainAfterCommit() {
        if let reason = pendingForceReclaimReason {
            pendingForceReclaimReason = nil
            forceReclaimToOwner(reason: reason)
        }
        if let next = coalescedOffers.popFirst()?.value {
            handleHandbackOffer(next)
        }
    }

    private func applyWatchOverride(_ change: LoanReconciler.OverrideChange, epoch: Int, isFinal: Bool) {
        let current = deps.scheduleOverride()
        let phase = isFinal ? "final" : "interim"
        switch change {
        case .set(let override):
            guard current?.syncIdentifier != override.syncIdentifier else {
                os_log("[override] from watch: SKIPPED — %{public}@ already applied (sync %{public}@)",
                       log: log, type: .default, Self.overrideNameForLog(override), override.syncIdentifier.uuidString)
                handbackDiag(epoch, "[override] SKIPPED (already applied) \(Self.overrideNameForLog(override))")
                return
            }
            deps.applyScheduleOverride(override)
            let ends = override.duration.isInfinite ? "indefinite" : ISO8601DateFormatter().string(from: override.scheduledEndDate)
            os_log("[override] from watch: APPLIED %{public}@ · insulin needs %.0f%% · target %{public}@ · ends %{public}@ · sync %{public}@ (%{public}@ drain)",
                   log: log, type: .default, Self.overrideNameForLog(override),
                   override.settings.effectiveInsulinNeedsScaleFactor * 100,
                   Self.targetForLog(override), ends, override.syncIdentifier.uuidString, phase)
            handbackDiag(epoch, String(format: "[override] APPLIED %@ · needs %.0f%% · target %@ · ends %@ (%@ drain)",
                                       Self.overrideNameForLog(override),
                                       override.settings.effectiveInsulinNeedsScaleFactor * 100,
                                       Self.targetForLog(override), ends, phase))
        case .cleared:
            guard current != nil else {
                os_log("[override] from watch: SKIPPED clear — the phone holds no override", log: log, type: .default)
                handbackDiag(epoch, "[override] SKIPPED clear (phone already has none)")
                return
            }
            deps.applyScheduleOverride(nil)
            os_log("[override] from watch: CLEARED %{public}@ — phone schedules resolve unscaled again (%{public}@ drain)",
                   log: log, type: .default, current.map(Self.overrideNameForLog) ?? "—", phase)
            handbackDiag(epoch, "[override] CLEARED \(current.map(Self.overrideNameForLog) ?? "—") (\(phase) drain)")
        }
    }

    static func overrideNameForLog(_ override: TemporaryScheduleOverride) -> String {
        switch override.context {
        case .preMeal: return "pre-meal"
        case .activity(let preset): return "\(preset.activityType.symbol) \(preset.activityType.name)"
        case .preset(let preset): return "\(preset.symbol) \(preset.name)"
        case .custom: return "custom"
        }
    }

    private static func targetForLog(_ override: TemporaryScheduleOverride) -> String {
        guard let range = override.settings.targetRange else { return "unchanged" }
        return String(format: "%.0f-%.0f",
                      range.lowerBound.doubleValue(for: .milligramsPerDeciliter),
                      range.upperBound.doubleValue(for: .milligramsPerDeciliter))
    }

    private func finishLoanAfterCommit() {
        cancelReclaimLadder()
        cancelNotification(id: NotificationID.duration)
        cancelNotification(id: NotificationID.paused)

        if supersededByLiveLoan(epoch) {
            let liveEpoch = newestForeignLoanEvidence?.epoch ?? epoch + 1
            pendingRevoke = false
            state = .owner
            staged = [:]
            stagedTombstones = []
            persistStaged()
            pendingHandbackAudit = nil
            clearAuditAnchors()
            PhoneLog.event("mirror", "drain e\(epoch) closed UNDER live e\(liveEpoch) — books committed, audit moot, custody NOT resumed [mirror]")
            engageInferredLoanYield(evidence: "superseding loan e\(liveEpoch) streamed during the e\(epoch) drain")
            return
        }
        reclaimPodConnection()
        pendingRevoke = false
        state = .owner
        deps.setAutomaticDosingPaused(false)
        staged = [:]
        stagedTombstones = []
        persistStaged()

        UserDefaults.standard.removeObject(forKey: Keys.deliveredAtGrant)
    }

}
