//
//  PodLoanPhoneController+Hold.swift
//  Loop
//
//  The phone knows when the watch last looped — and says so when it stops.
//
//  Every loop cycle the watch computes and lands sends its ordinary record batch, empty or not,
//  stamped with its send time. When those stop while this phone is beside the body, the phone
//  WARNS: the watch may be off or out of battery, and then nobody is adjusting insulin. It does
//  not take the pod back by itself. That is the user's decision (the pod tile) — a watch that is
//  alive but unheard is still dosing, and a phone that took the pod behind its back would dose
//  beside a watch that knows nothing of the phone's insulin. Before this there was no signal at
//  all: a silent watch was noticed by a person or not at all (2026-09-08: four hours).
//

import Foundation
import LoopKit

extension PodLoanPhoneController {
    static let watchSilenceThreshold: TimeInterval = .minutes(15)

    static let watchSilenceGrace: TimeInterval = .minutes(5)

    static let watchSilenceWarningOffsets: [TimeInterval] = [0, .minutes(20), .minutes(40)]

    static let nearTheBodyWindow: TimeInterval = .minutes(11)

    private enum HoldKeys {
        static let renewedAt = "PodLoanPhoneController.holdRenewedAt"
        static let noticedAt = "PodLoanPhoneController.holdLapseNoticedAt"
        static let warningsIssued = "PodLoanPhoneController.watchSilenceWarningsIssued"
    }

    var holdRenewedAt: Date? {
        get { UserDefaults.standard.object(forKey: HoldKeys.renewedAt) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: HoldKeys.renewedAt) }
    }

    var holdLapseNoticedAt: Date? {
        get { UserDefaults.standard.object(forKey: HoldKeys.noticedAt) as? Date }
        set {
            UserDefaults.standard.set(newValue, forKey: HoldKeys.noticedAt)
            if newValue == nil { UserDefaults.standard.removeObject(forKey: HoldKeys.warningsIssued) }
        }
    }

    private var watchSilenceWarningsIssued: Int {
        get { UserDefaults.standard.integer(forKey: HoldKeys.warningsIssued) }
        set { UserDefaults.standard.set(newValue, forKey: HoldKeys.warningsIssued) }
    }

    func clearAuditAnchors() {
        checkpointsThisLoan = 0
        auditBase = nil
        loanStartedAt = nil
        UserDefaults.standard.removeObject(forKey: Keys.loanStartedAt)
        UserDefaults.standard.removeObject(forKey: Keys.deliveredAtTakeover)
        UserDefaults.standard.removeObject(forKey: Keys.deliveredAtGrant)
    }

    func noteHoldRenewal(sentAt: Date?) {
        let now = deps.now()
        let stamp = min(sentAt ?? now, now)
        guard stamp > (holdRenewedAt ?? .distantPast) else { return }
        holdRenewedAt = stamp
        if holdLapseNoticedAt != nil, now.timeIntervalSince(stamp) <= Self.watchSilenceThreshold {
            holdLapseNoticedAt = nil
            handbackDiag(epoch, "watch REPORTING again — the silence warning stands down")
        }
    }

    func considerHoldLapse() {
        queue.async { self.queue_considerHoldLapse() }
    }

    func queue_considerHoldLapse() {
        let told = state == .owner && yieldingToInferredLoan
        let renewedAt = told ? [holdRenewedAt, newestForeignLoanEvidence?.at].compactMap { $0 }.max() : holdRenewedAt
        guard state == .loaned || state == .grantOffered || told, let renewed = renewedAt else {
            if holdLapseNoticedAt != nil { holdLapseNoticedAt = nil }
            return
        }
        let now = deps.now()
        let silence = now.timeIntervalSince(renewed)
        guard silence > Self.watchSilenceThreshold,
              let reading = deps.latestGlucoseDate(), now.timeIntervalSince(reading) <= Self.nearTheBodyWindow else {
            if holdLapseNoticedAt != nil { holdLapseNoticedAt = nil }
            return
        }
        guard let noticed = holdLapseNoticedAt else {
            holdLapseNoticedAt = now
            handbackDiag(epoch, String(format: "watch SILENT — no report for %.0f min with this phone beside the body; first warning in %.0f min unless it reports",
                                       silence / 60, Self.watchSilenceGrace / 60))
            return
        }
        let issued = watchSilenceWarningsIssued
        guard issued < Self.watchSilenceWarningOffsets.count,
              now.timeIntervalSince(noticed) >= Self.watchSilenceGrace + Self.watchSilenceWarningOffsets[issued] else { return }
        watchSilenceWarningsIssued = issued + 1
        handbackDiag(epoch, String(format: "watch SILENT %.0f min — warning %d of %d issued; the pod stays assigned to the watch until the user takes it back",
                                   silence / 60, issued + 1, Self.watchSilenceWarningOffsets.count))
        deps.issueUrgentNotice(
            NSLocalizedString("Watch Not Reporting", comment: "Phone warning title: the watch has stopped reporting loop cycles during a session"),
            String(format: NSLocalizedString("The watch hasn't reported a loop for %1$.0f minutes. The pod is still assigned to it. If the watch is off or out of battery, tap the pod tile to bring the pod back to this phone.", comment: "Phone warning body: watch silent mid-session (1: minutes)"), (silence / 60).rounded()))
    }
}
