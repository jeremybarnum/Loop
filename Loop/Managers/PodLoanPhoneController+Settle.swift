//
//  PodLoanPhoneController+Settle.swift
//  Loop
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

    static let reclaimEscalateAfter: TimeInterval = 12

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

    func chaseReclaimVerification(started: Date, attempt: Int = 0) {
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
}
