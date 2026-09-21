//
//  PodLoanPhoneController+Mirror.swift
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
    func supersededByLiveLoan(_ epochN: Int) -> Bool {
        guard let evidence = newestForeignLoanEvidence, evidence.epoch > epochN else { return false }
        return deps.now().timeIntervalSince(evidence.at) < 600
    }

    func engageInferredLoanYield(evidence: String) {
        guard state == .owner, !yieldingToInferredLoan else { return }
        yieldingToInferredLoan = true
        holdRenewedAt = deps.now()
        holdLapseNoticedAt = nil

        if let units = (deps.pumpManager() as? PumpConnectionLendable)?.lentDeviceInsulinDelivered {
            let asOf = deps.pumpManager()?.lastSync ?? deps.now()
            checkpointsThisLoan = 0
            auditBase = AuditBase(units: units, asOf: asOf)
            loanStartedAt = asOf
            UserDefaults.standard.set(asOf, forKey: Keys.loanStartedAt)
        }
        deps.setAutomaticDosingPaused(true)

        (deps.pumpManager() as? PumpConnectionLendable)?.releaseConnection()
        syncUIMirror()
        deps.ownershipDidChange()

        deps.issueNotice(
            NSLocalizedString("Pod Looks Controlled by the Watch", comment: "Phone notice title when the phone yields to an inferred watch loan"),
            NSLocalizedString("This phone has paused automatic dosing because the pod appears to be in use by the watch. Tap the pod tile to take it back.", comment: "Phone notice body when the phone yields to an inferred watch loan"))
        PhoneLog.event("mirror", "YIELDING to an inferred loan — \(evidence); pill=Pod on Watch, dosing paused, pod BLE released, exits: pill tap / watch revival / R40(f) prompt (R40(a): on conflict the phone yields) [mirror]")
    }

    func reclaimPodConnection() {
        (deps.pumpManager() as? PumpConnectionLendable)?.reclaimConnection()
    }

    func clearInferredLoanYield(reason: String) {
        guard yieldingToInferredLoan else { return }
        yieldingToInferredLoan = false
        syncUIMirror()
        deps.ownershipDidChange()
        PhoneLog.event("mirror", "inferred-loan yield CLEARED — \(reason) [mirror]")
    }

    func abortGrant(reason: String) {
        os_log("Grant aborted: %{public}@", log: log, type: .error, reason)
        sendMessage(.denied(LoanDenied(reason: "The loan could not start (\(reason)). The phone kept the pod.")))
        reclaimToOwner(alert: nil, reason: "grant ABORTED before it left the phone: \(reason)")
    }

    private static let grantLostProbeDelay: TimeInterval = 20

    private func armGrantLostProbe(for grantEpoch: Int) {
        queue.asyncAfter(deadline: .now() + Self.grantLostProbeDelay) { [weak self] in
            guard let self = self, self.state == .grantOffered, self.epoch == grantEpoch else { return }
            self.handbackDiag(grantEpoch, String(format: "grant unconfirmed after %.0fs — asking the watch whether it arrived (#108)", Self.grantLostProbeDelay))

            if !self.deps.watchAppInstalled() {
                self.handbackDiag(grantEpoch, "grant unconfirmed AND isWatchAppInstalled=false — one-way wedge signature")
            }
            self.sendMessage(.statusQuery(StatusQuery(epoch: grantEpoch)))
        }
    }

    func armT1(for grantEpoch: Int) {
        if grantOfferedAt == nil { grantOfferedAt = deps.now() }
        armGrantLostProbe(for: grantEpoch)

        scheduleNotification(id: NotificationID.t1, title: "Watch Loan Not Confirmed",
                             body: "The watch hasn't confirmed taking the pod. The phone will take it back.",
                             delay: .minutes(5), repeats: false)
        t1WorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .grantOffered, self.epoch == grantEpoch else { return }
            self.sendMessage(.statusQuery(StatusQuery(epoch: grantEpoch)))
            let confirm = DispatchWorkItem { [weak self] in
                guard let self = self, self.state == .grantOffered, self.epoch == grantEpoch else { return }

                self.reclaimToOwner(alert: nil, reason: "dead-man T1 expired — the watch never confirmed the takeover")
            }
            self.t1WorkItem = confirm
            self.queue.asyncAfter(deadline: .now() + 15, execute: confirm)
        }
        t1WorkItem = work
        queue.asyncAfter(deadline: .now() + .minutes(5), execute: work)
    }

    func handleTakeoverComplete(_ complete: TakeoverComplete) {
        guard complete.epoch == epoch, state == .grantOffered else { return }
        noteHoldRenewal(sentAt: complete.firstPodStatus.timestamp)
        grantOfferedAt = nil
        t1WorkItem?.cancel()
        cancelNotification(id: NotificationID.t1)

        if let atTakeover = complete.firstPodStatus.deliveredUnits {
            UserDefaults.standard.set(atTakeover, forKey: Keys.deliveredAtTakeover)

            auditBase = AuditBase(units: atTakeover, asOf: complete.firstPodStatus.timestamp)
        }
        state = .loaned

    }

    func handleTakeoverFailed(_ failed: TakeoverFailed) {
        guard failed.epoch == epoch, state == .grantOffered else { return }
        t1WorkItem?.cancel()
        cancelNotification(id: NotificationID.t1)

        reclaimToOwner(alert: nil, reason: "watch reported takeover FAILED: \(failed.reason)")
    }

    func handleStatusReport(_ report: StatusReport) {
        if report.holdsPod, report.epoch > epoch {
            if newestForeignLoanEvidence.map({ report.epoch >= $0.epoch }) ?? true {
                newestForeignLoanEvidence = (report.epoch, deps.now())
            }
            let hasCredential = UserDefaults.standard.string(forKey: Keys.dormantSeizeToken) != nil
            switch state {
            case .owner where hasCredential:
                engageInferredLoanYield(evidence: "statusReport — watch holds the pod on e\(report.epoch)")
            case .grantOffered where hasCredential:

                t1WorkItem?.cancel()
                cancelNotification(id: NotificationID.t1)
                handbackDiag(epoch, "ghost grant e\(epoch) ABANDONED — the watch answered holdsPod e\(report.epoch); yielding instead of waiting on a takeover that cannot come [mirror]")
                state = .owner
                engageInferredLoanYield(evidence: "statusReport — watch holds e\(report.epoch), ghost grant abandoned")
            case .reclaimPending:

                if var ladder = reclaimLadder, !ladder.forced, ladder.attempts < 2 {
                    sendMessage(.revoke(Revoke(epoch: report.epoch)))
                    ladder.attempts += 1
                    reclaimLadder = ladder
                    handbackDiag(epoch, "reclaim revoke RE-AIMED at e\(report.epoch) (attempt \(ladder.attempts) of 2) — the watch holds a newer loan than the one this reclaim named")
                }
            default:
                break
            }
        }
        guard report.epoch == epoch else { return }

        if state == .grantOffered, report.holdsPod {
            handleTakeoverComplete(TakeoverComplete(epoch: report.epoch, firstPodStatus: LoanPodStatus(timestamp: deps.now(), deliveredUnits: nil, reservoirLevel: nil, isSuspended: false, faultCode: report.podFault)))
        }

        if state == .grantOffered, report.knowsGrant == true, !report.holdsPod {
            let elapsed = grantOfferedAt.map { deps.now().timeIntervalSince($0) } ?? 0
            handbackDiag(report.epoch, String(format: "takeover IN PROGRESS on the watch at +%.0fs — the 5-minute dead-man runs unchanged", elapsed))
        }
        if state == .grantOffered, report.knowsGrant == false, !report.holdsPod {
            handbackDiag(report.epoch, "grant CONFIRMED LOST by the watch — reclaiming now instead of waiting out the 5-minute timer (#108)")
            t1WorkItem?.cancel()
            cancelNotification(id: NotificationID.t1)

            sendMessage(.denied(LoanDenied(reason: "The hand-over never reached the watch. The phone kept the pod. Tap Start again.")))
            reclaimToOwner(alert: nil, reason: "grant CONFIRMED LOST by the watch")
        }
        if report.podFault != nil {
            handbackDiag(report.epoch, "pod fault reported in a status report — logged only; the watch owns pod-fault surfacing during a loan")
        }
    }

}
