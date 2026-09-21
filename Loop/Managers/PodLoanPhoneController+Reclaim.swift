//
//  PodLoanPhoneController+Reclaim.swift
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
    static let reclaimSettleTimeout: TimeInterval = .minutes(5)

    static let reclaimSettleExpectation: TimeInterval = 10

    private static let reclaimEscalateAfter: TimeInterval = 12

    static let requestDedupeWindow: TimeInterval = .minutes(2)

    static let requestTTL: TimeInterval = 90

    func beginReclaimSettleWindow() {
        let started = deps.now()
        reclaimStartedAt = started
        reclaimEscalated = false
        reclaimVerifiedAt = nil
        syncUIMirror()
        reclaimVerifyInFlight = false
        reclaimLinkUpAt = nil
        reclaimStaleReads = 0

        if let anchor = reclaimDisplayAnchor, started.timeIntervalSince(anchor) < 60 {
        } else {
            reclaimDisplayAnchor = started
        }

        deps.beginReclaimBackgroundTask()
        reclaimSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.reclaimStartedAt == started else { return }
            os_log("Reclaim settle CEILING reached (%.0fs) without a verified round-trip — clearing anyway",
                   log: self.log, type: .error, Self.reclaimSettleTimeout)

            let ble = (self.deps.pumpManager() as? PumpConnectionLendable)?.connectionDiagnostics()
            self.handbackDiag(self.epoch, String(
                format: "settle CEILING at %.0fs — NO verified round-trip; clearing anyway · ble: %@",
                Self.reclaimSettleTimeout, ble ?? "no diagnostics from the pump manager"))
            self.reclaimStartedAt = nil
            self.syncUIMirror()
            self.reclaimDisplayAnchor = nil
            self.deps.endReclaimBackgroundTask()

            if let pending = self.pendingHandbackAudit, pending.flavor == .forceReclaim {
                self.pendingHandbackAudit = nil
                self.handbackDiag(pending.epoch, "** R37: audit NEVER RAN — pod unreachable through the settle window. Session UNVERIFIED, loop OPENS **")
                self.deps.setAutomaticDosingPaused(false)
                self.deps.openLoopForUncertainReconciliation()
                self.armOpenLoopReminder()

                self.deps.issueUrgentNotice("Watch Session Unverified", Self.sessionUnverifiedBody)
            }
            self.deps.ownershipDidChange()
        }
        reclaimSettleWork = work

        queue.asyncAfter(wallDeadline: .now() + Self.reclaimSettleTimeout, execute: work)
        chaseReclaimVerification(started: started)
    }

    private func chaseReclaimVerification(started: Date, attempt: Int = 0) {
        guard reclaimStartedAt == started, reclaimVerifiedAt == nil else { return }

        if reclaimLinkUpAt == nil, deps.isConnectionReady() {
            let up = deps.now()
            reclaimLinkUpAt = up
            let waited = up.timeIntervalSince(started)

            handbackDiag(epoch, String(format: "settle: link up +%.1fs (tick %d)", waited, attempt))
        }

        if reclaimLinkUpAt == nil, !reclaimEscalated,
           deps.now().timeIntervalSince(started) >= Self.reclaimEscalateAfter,
           let lendable = deps.pumpManager() as? PumpConnectionLendable {
            reclaimEscalated = true
            let bleBefore = lendable.connectionDiagnostics() ?? "none"
            let outcome = lendable.escalateConnectionReclaim() ?? "the pump manager had nothing to escalate"
            handbackDiag(epoch, String(format: "settle: link still down at +%.0fs — escalating: %@ · ble before: %@",
                                       deps.now().timeIntervalSince(started), outcome, bleBefore))
        }

        attemptReclaimVerificationNow(started: started)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.chaseReclaimVerification(started: started, attempt: attempt + 1)
        }
    }

    func attemptReclaimVerificationNow(started: Date) {
        guard reclaimStartedAt == started, reclaimVerifiedAt == nil else { return }
        if deps.isConnectionReady(), !reclaimVerifyInFlight, let pump = deps.pumpManager() {
            reclaimVerifyInFlight = true
            let read: (@escaping (Date?) -> Void) -> Void
            if let lendable = pump as? PumpConnectionLendable {
                read = { done in
                    lendable.refreshLentDeviceStatus { _ in pump.ensureCurrentPumpData { done($0) } }
                }
            } else {
                read = { done in pump.ensureCurrentPumpData { done($0) } }
            }
            read { [weak self] lastSync in
                guard let self = self else { return }
                self.queue.async {
                    self.reclaimVerifyInFlight = false
                    guard self.reclaimStartedAt == started, self.reclaimVerifiedAt == nil else { return }

                    if let sync = lastSync, sync > started {
                        let elapsed = self.deps.now().timeIntervalSince(started)
                        self.reclaimVerifiedAt = self.deps.now()
                        self.reclaimSettleWork?.cancel()
                        self.reclaimStartedAt = nil
                        self.syncUIMirror()
                        self.reclaimDisplayAnchor = nil
                        self.deps.endReclaimBackgroundTask()

                        let linkWait = self.reclaimLinkUpAt.map { $0.timeIntervalSince(started) } ?? elapsed
                        let readWait = max(elapsed - linkWait, 0)

                        self.handbackDiag(self.epoch,
                            String(format: "reclaim VERIFIED — pod round-trip complete +%.0fs (link +%.1fs, stale reads %d, read +%.1fs)",
                                   elapsed, linkWait, self.reclaimStaleReads, readWait))
                        self.deps.ownershipDidChange()

                        self.finishPendingHandbackAudit(elapsed: elapsed)
                    } else {
                        self.reclaimStaleReads += 1
                        os_log("Settle: status read %d did not advance lastSync — link %{public}@",
                               log: self.log, type: .default, self.reclaimStaleReads,
                               self.reclaimLinkUpAt == nil ? "still down" : "already up")

                        PhoneLog.event("loan", String(format: "e%d settle: read %d stale — link %@",
                                                      self.epoch, self.reclaimStaleReads,
                                                      self.reclaimLinkUpAt == nil ? "still down" : "already up"))
                    }
                }
            }
        }
    }

    func finishPendingHandbackAudit(elapsed: TimeInterval) {
        defer { clearAuditAnchors() }
        guard let pending = pendingHandbackAudit else { return }
        pendingHandbackAudit = nil

        if let latest = (deps.pumpManager() as? PumpConnectionLendable)?.lentDeviceInsulinDelivered {
            let delivered = latest - pending.deliveredAtStart
            let residual = ((delivered - pending.expected) * 1000).rounded() / 1000

            let loanDelivered = pending.takeoverUnits.map { latest - $0 }
            let loanResidual: Double? = {
                guard let d = loanDelivered, let e = pending.wholeLoanExpected else { return nil }
                return d - e
            }()

            let drift = pending.watchLatest.map { latest - $0 }
            handbackDiag(pending.epoch, String(format:
                "reconcile[%@]: delivered=%.3f expected=%.3f residual=%+.3f (tol 0.05) · loan total %@ resid %@ · %d checkpoint(s) · loanMin=%.0f cycles=%d · odometer read by PHONE +%.0fs after reclaim · vs watch endpoint %@ (watch fresh=%@)",
                pending.flavor == .forceReclaim ? "FORCE-RECLAIM" : "AUTHORITATIVE",
                delivered, pending.expected, residual,
                loanDelivered.map { String(format: "%.3f", $0) } ?? "n/a",
                loanResidual.map { String(format: "%+.3f", $0) } ?? "n/a",
                checkpointsThisLoan,
                pending.loanMinutes, pending.cycles, elapsed,
                drift.map { String(format: "%+.3f", $0) } ?? "n/a",
                pending.watchFreshened ? "Y" : "N"))
            UserDefaults.standard.set(loanDelivered ?? delivered, forKey: Keys.deliveredAuthoritative)

            if let lr = loanResidual, abs(lr) > 0.5, abs(residual) <= Self.checkpointBand {
                handbackDiag(pending.epoch, String(format:
                    "** [checkpoint] loan-total residual %+.3f U exceeds ±0.5 while every window reconciled — possible systematic drip; diagnostic only **", lr))
            }
            switch pending.flavor {
            case .handback:

                bankResidual(loanResidual ?? residual,
                             worstWindow: max(worstWindowThisLoan, abs(residual)),
                             epoch: pending.epoch)
                applyReconciliationVerdict(residual: residual, epoch: pending.epoch)
            case .forceReclaim:
                applyForceReclaimVerdict(residual: residual, epoch: pending.epoch)
            }
        } else if pending.flavor == .forceReclaim {
            handbackDiag(pending.epoch, "** R37: reclaim round-trip landed but no odometer — session UNVERIFIED, loop OPENS **")
            deps.setAutomaticDosingPaused(false)
            deps.openLoopForUncertainReconciliation()
            armOpenLoopReminder()
            deps.issueUrgentNotice("Watch Session Unverified", Self.sessionUnverifiedBody)
        } else {
            handbackDiag(pending.epoch, "reconcile[AUTHORITATIVE]: pod reachable but reported no odometer — keeping the provisional line")
        }

        deps.cancelTempBasalAfterPodReturn { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    self.handbackDiag(pending.epoch, "R33 temp cancel FAILED — pod keeps the watch's temp until the next cycle · \(String(describing: error))")
                } else {
                    self.handbackDiag(pending.epoch, "R33 temp cancelled — pod reverts to the user's schedule until the phone's next reading")
                }
            }
        }
    }

    struct ReclaimLadder {
        enum Branch: String { case live = "LIVE", dead = "DEAD" }
        var branch: Branch
        let startedAt: Date

        var forceAt: Date

        var attempts: Int

        var forced: Bool
        var phase: ReclaimProgress.Phase {
            if forced || branch == .dead { return .forcing }
            return .draining
        }
    }

    static let watchContactLivenessWindow: TimeInterval = 330

    private static let liveResendDelay: TimeInterval = 10
    private static let liveForceDelay: TimeInterval = 25

    static let liveHandoverExpectation: TimeInterval = 10

    private func scheduleLadderRung(after delay: TimeInterval, label: String, execute work: DispatchWorkItem) {
        if let scheduler = scheduler {
            scheduler(delay, label, work)
        } else {
            queue.asyncAfter(wallDeadline: .now() + delay, execute: work)
        }
    }

    enum Keys {
        static let state = "PodLoanPhoneController.state"
        static let epoch = "PodLoanPhoneController.epoch"
        static let cursor = "PodLoanPhoneController.cursor"
        static let pendingRevoke = "PodLoanPhoneController.pendingRevoke"
        static let committedIDs = "PodLoanPhoneController.committedIDs"
        static let loanStartedAt = "PodLoanPhoneController.loanStartedAt"

        static let deliveredAtGrant = "PodLoanPhoneController.deliveredAtGrant"

        static let deliveredAtTakeover = "PodLoanPhoneController.deliveredAtTakeover"

        static let gapBooking = "PodLoanPhoneController.gapBooking"

        static let pendingForceAudit = "PodLoanPhoneController.pendingForceAudit"

        static let deliveredAuthoritative = "PodLoanPhoneController.deliveredAuthoritative"

        static let residualHistory = "PodLoanPhoneController.residualHistory"

        static let residualHistoryPurged = "PodLoanPhoneController.residualHistoryPurged.2026-08-13"

        static let auditBase = "PodLoanPhoneController.auditBase"

        static let windowWorstHistory = "PodLoanPhoneController.windowResidualWorst"

        static let watchSupportsSeize = "PodLoanPhoneController.watchSupportsSeize"

        static let dormantSeizeToken = "PodLoanPhoneController.dormantSeizeToken"

        static let yieldingToInferredLoan = "PodLoanPhoneController.yieldingToInferredLoan"
    }

    enum NotificationID {
        static let t1 = "podloan.t1"
        static let duration = "podloan.6h"
        static let paused = "podloan.paused1h"

        static let openLoop = "podloan.openloop"

        static func placeholder(_ index: Int) -> String { "podloan.placeholder.\(index)" }
    }

    enum ReminderLadder {
        static let placeholderRungs: [TimeInterval] = [.hours(2), .hours(4)]
        static let openLoopDelay: TimeInterval = .hours(1)
    }

    var isPodTakeoverInProgress: Bool {
        return state == .grantOffered
    }

    var podIsOnLoan: Bool {
        switch state {
        case .owner: return yieldingToInferredLoan
        case .grantOffered, .loaned, .reconciling, .reclaimPending: return true
        }
    }

    func reclaimNow() {
        queue.async {
            guard self.podIsOnLoan else { return }

            self.clearInferredLoanYield(reason: "pill tap — reclaimNow (the inherited exit)")
            self.reclaimDisplayAnchor = self.deps.now()

            self.deps.beginReclaimBackgroundTask()
            self.pendingRevoke = true

            let revokeEpoch = self.supersededByLiveLoan(self.epoch)
                ? (self.newestForeignLoanEvidence?.epoch ?? self.epoch) : self.epoch
            if revokeEpoch != self.epoch {
                self.handbackDiag(self.epoch, "reclaim revoke AIMED at e\(revokeEpoch) — fresh evidence of a loan this phone never granted (mirror)")
            }
            self.sendMessage(.revoke(Revoke(epoch: revokeEpoch)))
            self.reclaimPodConnection()
            self.state = .reclaimPending
            self.armReclaimLadder()
        }
    }

    private func armReclaimLadder() {
        cancelReclaimLadder()

        let reachable = deps.isWatchReachable()
        let lastContact = deps.lastWatchContactAt()
        let contactAge = lastContact.map { deps.now().timeIntervalSince($0) }
        let heardRecently = (contactAge ?? .greatestFiniteMagnitude) < Self.watchContactLivenessWindow
        let branch: ReclaimLadder.Branch = (reachable || heardRecently) ? .live : .dead

        let resendDelay: TimeInterval? = branch == .live ? Self.liveResendDelay : nil
        let forceDelay: TimeInterval = branch == .live ? Self.liveForceDelay : 0

        let started = deps.now()
        reclaimLadder = ReclaimLadder(branch: branch,
                                      startedAt: started,
                                      forceAt: started.addingTimeInterval(forceDelay),
                                      attempts: 1,
                                      forced: false)

        let ageText = contactAge.map { String(format: "%.1fs ago", $0) } ?? "never"
        let planText = branch == .live
            ? String(format: "resend +%.0fs, force +%.0fs", Self.liveResendDelay, Self.liveForceDelay)
            : "force NOW (dead branch waits for nothing; the revoke is fire-and-forget)"
        handbackDiag(epoch, String(format: "reclaim ladder %@ — last watch contact %@, reachable %d · %@",
                                   branch.rawValue, ageText, reachable ? 1 : 0, planText))

        scheduleRungs(resendIn: resendDelay, forceIn: forceDelay)
    }

    private func scheduleRungs(resendIn resendDelay: TimeInterval?, forceIn forceDelay: TimeInterval) {
        reclaimResendWork?.cancel()
        reclaimTimeoutWork?.cancel()

        if let resendDelay = resendDelay {
            let resend = DispatchWorkItem { [weak self] in
                guard let self = self, self.state == .reclaimPending,
                      var ladder = self.reclaimLadder, !ladder.forced else { return }

                guard ladder.attempts < 2 else { return }

                let resendEpoch = self.supersededByLiveLoan(self.epoch)
                    ? (self.newestForeignLoanEvidence?.epoch ?? self.epoch) : self.epoch
                self.sendMessage(.revoke(Revoke(epoch: resendEpoch)))
                ladder.attempts += 1
                self.reclaimLadder = ladder
                self.handbackDiag(self.epoch, "reclaim revoke RESENT (attempt \(ladder.attempts) of 2) — no drain yet on the \(ladder.branch.rawValue) branch")
            }
            reclaimResendWork = resend
            scheduleLadderRung(after: max(resendDelay, 0), label: "reclaim-resend", execute: resend)
        } else {
            reclaimResendWork = nil
        }

        let force = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .reclaimPending, let ladder = self.reclaimLadder else { return }

            self.reclaimLadder?.forced = true

            let holding = self.supersededByLiveLoan(self.epoch)
                ? " (watch holds newer loan e\(self.newestForeignLoanEvidence?.epoch ?? 0) — refused, not silent)" : ""
            self.forceReclaimToOwner(reason: "reclaim ladder spent on the \(ladder.branch.rawValue) branch — \(ladder.attempts) revoke attempt(s), watch did not drain\(holding)")
        }
        reclaimTimeoutWork = force
        scheduleLadderRung(after: max(forceDelay, 0), label: "reclaim-force", execute: force)
    }

    func cancelReclaimLadder() {
        reclaimResendWork?.cancel()
        reclaimResendWork = nil
        reclaimTimeoutWork?.cancel()
        reclaimTimeoutWork = nil
        reclaimLadder = nil
    }

    func forceReclaimToOwner(reason: String) {
        os_log("Force reclaim to OWNER: %{public}@", log: log, type: .default, reason)

        if commitInFlight {
            handbackDiag(epoch, "force reclaim DEFERRED (#118) — a hand-back commit is writing; runs when it lands")
            pendingForceReclaimReason = reason
            return
        }
        cancelReclaimLadder()
        cancelNotification(id: NotificationID.paused)
        cancelNotification(id: NotificationID.duration)

        let events = staged.values
            .filter { !stagedTombstones.contains($0.id) && !committedIDs.contains($0.id) }
            .sorted { $0.seq < $1.seq }
        if !events.isEmpty {
            let input = LoanReconciler.Input(
                events: events, schedule: deps.settings().basalRateSchedule,
                loanStart: loanStartedAt ?? deps.now().addingTimeInterval(-.hours(2)),
                loanEnd: deps.now())
            let outcome = LoanReconciler.reconcile(input)

            let boluses = outcome.doses.filter { $0.type == .bolus }
            let bolusUnits = boluses.reduce(0.0) { $0 + ($1.deliveredUnits ?? $1.programmedUnits) }
            let rateGross = outcome.doses.filter { $0.type != .bolus }.reduce(0.0) { $0 + $1.programmedUnits }
            handbackDiag(epoch, String(format:
                "force reclaim SALVAGE — %d staged event(s) → %d dose(s): %.3f U bolus + %d rate record(s) (%.3f U gross programmed), %d carb(s), %d delete(s); loop resumes CLOSED on these books (no odometer check — OBS-9)",
                events.count, outcome.doses.count, bolusUnits, outcome.doses.count - boluses.count,
                rateGross, outcome.carbs.count, outcome.deletedCarbs.count))
            deps.addPumpEvents(newPumpEvents(from: outcome.doses), deps.now()) { _ in }

            if let earliest = outcome.doses.map(\.startDate).min() {
                deps.insulinHistoryRewritten(earliest)
            }
            for carb in outcome.carbs { deps.addCarb(carb.entry, carb.eventID.uuidString) { _ in } }
            for gone in outcome.deletedCarbs {
                deps.deleteCarb(gone) { error in
                    self.handbackDiag(self.epoch, error == nil
                        ? String(format: "carb DELETE applied on phone (recovery) — %.0f g", gone.grams)
                        : String(format: "carb DELETE MISSED on phone (recovery) — %.0f g: %@", gone.grams, String(describing: error!)))
                }
            }

            committedIDs.formUnion(events.map(\.id))
            persistCommittedIDs()

            if let newCursor = events.map(\.seq).max() {
                committedCursor = max(committedCursor, newCursor)
            }

            deps.issueNotice(
                NSLocalizedString("Watch Session Ended Without Hand-Back", comment: "Phone notice title after a force reclaim salvaged staged records"),
                NSLocalizedString("Automatic dosing is paused while Loop checks the pod's insulin total. This usually takes seconds.", comment: "Phone notice body after a force reclaim salvaged staged records"))
        }

        let auditArmed = armForceReclaimAudit()

        reclaimPodConnection()
        pendingRevoke = false
        state = .owner

        if !auditArmed {
            deps.setAutomaticDosingPaused(false)
        }
        beginReclaimSettleWindow()
        staged = [:]
        stagedTombstones = []
        persistStaged()
    }

    @discardableResult
    private func armForceReclaimAudit() -> Bool {
        let start = loanStartedAt ?? deps.now().addingTimeInterval(-.hours(2))
        let anchor: (units: Double, asOf: Date)?
        if let base = auditBase {
            anchor = (base.units, base.asOf)
        } else if let units = (UserDefaults.standard.object(forKey: Keys.deliveredAtTakeover) as? Double)
                            ?? (UserDefaults.standard.object(forKey: Keys.deliveredAtGrant) as? Double) {
            anchor = (units, start)
        } else {
            anchor = nil
        }
        guard let anchor = anchor, let schedule = deps.settings().basalRateSchedule else {
            handbackDiag(epoch, "** R37 force-reclaim audit IMPOSSIBLE — no start odometer/schedule; loop OPENS on principle (cannot verify => do not resume) **")
            deps.openLoopForUncertainReconciliation()
            armOpenLoopReminder()
            deps.issueUrgentNotice("Watch Session Unverified", Self.sessionUnverifiedBody)
            return false
        }
        let allEvents = staged.values.sorted { $0.seq < $1.seq }
        let expected = LoanReconciler.expectedInsulin(events: allEvents, schedule: schedule,
                                                      from: anchor.asOf, to: deps.now())

        let takeoverUnits = UserDefaults.standard.object(forKey: Keys.deliveredAtTakeover) as? Double
        let wholeLoanExpected = takeoverUnits.map {
            _ in LoanReconciler.expectedInsulin(events: allEvents, schedule: schedule, from: start, to: deps.now())
        }
        pendingHandbackAudit = PendingHandbackAudit(
            epoch: epoch, deliveredAtStart: anchor.units, expected: expected,
            loanMinutes: deps.now().timeIntervalSince(start) / 60, cycles: 0,
            watchLatest: nil, watchFreshened: false, flavor: .forceReclaim,
            takeoverUnits: takeoverUnits, wholeLoanExpected: wholeLoanExpected)

        handbackDiag(epoch, String(format:
            "R37 audit armed — expected %.3f U from %d record(s) + schedule fill over window since %@ (%d checkpoint(s)); verdict on the reclaim round-trip",
            expected, allEvents.count,
            checkpointsThisLoan > 0 ? String(format: "last sync %.0f min ago", deps.now().timeIntervalSince(anchor.asOf) / 60) : "takeover",
            checkpointsThisLoan))
        return true
    }

    func watchDidBecomeReachable() {
        queue.async {
            guard self.pendingRevoke else { return }
            self.sendMessage(.revoke(Revoke(epoch: self.epoch)))
            if var ladder = self.reclaimLadder, self.state == .reclaimPending, !ladder.forced,
               ladder.attempts < 2 {
                ladder.attempts += 1
                self.reclaimLadder = ladder
            }
        }
    }

}
