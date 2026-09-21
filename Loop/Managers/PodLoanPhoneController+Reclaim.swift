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

    static let requestDedupeWindow: TimeInterval = .minutes(2)

    static let requestTTL: TimeInterval = 90

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
