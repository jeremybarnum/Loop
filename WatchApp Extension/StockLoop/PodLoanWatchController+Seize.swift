//
//  PodLoanWatchController+Seize.swift
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

    func issueReunionPromptAlert() {
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

    enum DormantKeys {
        static let envelope = "PodLoanWatchController.dormantGrant"

        static let activeToken = "PodLoanWatchController.activeSeizeToken"
    }

    var seizeMarkerActive: Bool {
        pendingSeizeToken != nil || defaults.string(forKey: DormantKeys.activeToken) != nil
    }

    static let seizeActivationLease: TimeInterval = 5 * 60

    static let seizeAutoHandbackDisabledKey = "PodLoanWatchController.seizeAutoHandbackDisabled"

    static let unexplainedInsulinBand = 0.20
}
