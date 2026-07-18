//
//  PodLoanPhoneController.swift
//  Loop
//
//  The phone half of loan protocol v2 (docs/DESIGN_LOAN_PROTOCOL_V2.md §3.1, §10).
//  Persisted state machine (podLoanedToWatch is DERIVED from this state, never a
//  volatile flag), epoch minting, grant assembly with deny-on-missing, the R8 alarm
//  inventory (exactly: T1 start-confirmation 5 min / loan-duration 6 h / paused-dosing
//  1 h repeating — deliberately NO heartbeat), record staging (the trap-cell defense),
//  and reconcile-commit-ack ordering (ack ONLY after the store writes commit).
//
//  Dependencies are injected closures so the state machine and ordering invariants
//  are testable without the live device stack; app integration wires the real
//  DeviceDataManager/WatchDataManager/AlertManager surfaces.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore
import UserNotifications
import os.log

final class PodLoanPhoneController {

    enum State: String {
        case owner, grantOffered, loaned, reconciling, reclaimPending
    }

    struct Dependencies {
        /// The current pump manager, if any (conditionally cast for lending).
        var pumpManager: () -> PumpManager?
        /// The live therapy settings (snapshot travels in the grant).
        var settings: () -> LoopSettings
        /// Pause/resume the phone's automatic dosing (loan-gated, R7).
        var setAutomaticDosingPaused: (Bool) -> Void
        /// Transport out (WCSession.transferUserInfo at integration).
        var send: ([String: Any]) -> Void
        /// Store writes.
        var addDoses: ([DoseEntry], @escaping (Error?) -> Void) -> Void
        var addCarb: (NewCarbEntry, @escaping (Error?) -> Void) -> Void
        /// 16 h insulin history for the grant.
        var doseHistory: (_ start: Date, _ completion: @escaping ([DoseEntry]) -> Void) -> Void
        /// Loud surfacing (banner + Event History line at integration).
        var issueNotice: (_ title: String, _ body: String) -> Void
        var now: () -> Date = { Date() }
    }

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanPhoneController")
    private let queue = DispatchQueue(label: "com.loopkit.Loop.PodLoanPhoneController", qos: .utility)
    private var deps: Dependencies

    private(set) var state: State {
        didSet { UserDefaults.standard.set(state.rawValue, forKey: Keys.state) }
    }
    private var epoch: Int {
        didSet { UserDefaults.standard.set(epoch, forKey: Keys.epoch) }
    }
    private var committedCursor: Int {
        didSet { UserDefaults.standard.set(committedCursor, forKey: Keys.cursor) }
    }
    /// Committed event IDs for the CURRENT epoch (secondary idempotency; the cursor
    /// is primary). Bounded: cleared when a loan fully closes.
    private var committedIDs: Set<UUID>
    /// Staged (received, not-yet-committed) events for the current epoch — persisted
    /// on every batch so a phone relaunch keeps the trap-cell defense.
    private var staged: [UUID: LoanEvent] = [:]
    private var stagedTombstones: Set<UUID> = []
    private var loanStartedAt: Date?
    private var pendingRevoke: Bool {
        didSet { UserDefaults.standard.set(pendingRevoke, forKey: Keys.pendingRevoke) }
    }
    private var t1WorkItem: DispatchWorkItem?
    private var reclaimTimeoutWork: DispatchWorkItem?

    private enum Keys {
        static let state = "PodLoanPhoneController.state"
        static let epoch = "PodLoanPhoneController.epoch"
        static let cursor = "PodLoanPhoneController.cursor"
        static let pendingRevoke = "PodLoanPhoneController.pendingRevoke"
        static let committedIDs = "PodLoanPhoneController.committedIDs"
        static let loanStartedAt = "PodLoanPhoneController.loanStartedAt"
        // §5.3.3 post-reclaim re-audit state
        static let deliveredAtGrant = "PodLoanPhoneController.deliveredAtGrant"
        static let expectedUnits = "PodLoanPhoneController.expectedUnits"
        static let watchAuditRan = "PodLoanPhoneController.watchAuditRan"
    }

    private enum NotificationID {
        static let t1 = "podloan.t1"           // start-confirmation, 5 min (R8)
        static let duration = "podloan.6h"     // loan-duration reminder, 6 h (R8)
        static let paused = "podloan.paused1h" // paused-dosing reminder, 1 h repeating (R8)
        /// Silent informational notice carrying the bench reclaim action — NOT an
        /// alarm (R8's inventory governs alarms); replaced by real UI later.
        static let onLoan = "podloan.onloan"
    }

    /// Derived — what v1 kept as the volatile `podLoanedToWatch` flag (:480/:697).
    var podIsOnLoan: Bool {
        switch state {
        case .owner: return false
        case .grantOffered, .loaned, .reconciling, .reclaimPending: return true
        }
    }

    init(dependencies: Dependencies) {
        self.deps = dependencies
        self.state = State(rawValue: UserDefaults.standard.string(forKey: Keys.state) ?? "") ?? .owner
        self.epoch = UserDefaults.standard.object(forKey: Keys.epoch) as? Int ?? 0
        self.committedCursor = UserDefaults.standard.object(forKey: Keys.cursor) as? Int ?? 0
        self.pendingRevoke = UserDefaults.standard.bool(forKey: Keys.pendingRevoke)
        self.loanStartedAt = UserDefaults.standard.object(forKey: Keys.loanStartedAt) as? Date
        if let raw = UserDefaults.standard.array(forKey: Keys.committedIDs) as? [String] {
            self.committedIDs = Set(raw.compactMap(UUID.init(uuidString:)))
        } else {
            self.committedIDs = []
        }
        loadStaged()

        // Relaunch during a non-owner state: dosing stays paused (persisted-state
        // derivation is the whole point). Re-post the recovery affordance so the user
        // is never stranded with no way back to OWNER (bug E), and re-arm the reclaim
        // escalation if we were mid-reclaim.
        if podIsOnLoan {
            deps.setAutomaticDosingPaused(true)
            // Transient states (reconciling / reclaim-pending / grant-offered) should
            // resolve quickly; a relaunch still sitting in one means it stranded, so
            // give it a bounded self-heal to OWNER (records preserved). LOANED is NOT
            // healed — a relaunch during a real multi-hour loan is normal (R8); its
            // recovery is a new request or the escape hatch, never a timer.
            if state == .reconciling || state == .reclaimPending {
                armPausedReminder()
                let stranded = state
                queue.asyncAfter(deadline: .now() + 120) { [weak self] in
                    guard let self = self, self.state == stranded else { return }
                    self.forceReclaimToOwner(reason: "relaunched into \(stranded.rawValue), no hand-back")
                }
            } else if state == .grantOffered {
                // The T1 alarm doesn't survive relaunch; re-arm the auto-reclaim.
                armT1(for: epoch)
            }
        }
    }

    // MARK: - Incoming

    func handleIncoming(userInfo: [String: Any]) {
        queue.async { self.handleIncomingOnQueue(userInfo) }
    }

    private func handleIncomingOnQueue(_ userInfo: [String: Any]) {
        let message: LoanMessage?
        do {
            message = try LoanMessage.decode(fromTransport: userInfo)
        } catch {
            sendMessage(.nack(ProtocolNack(seenVersion: nil)))
            deps.issueNotice("Loan Protocol Error", "The watch sent a message this phone build cannot read. Update one of the builds. Nothing was discarded.")
            return
        }
        guard let message = message else { return }

        switch message {
        case .request(let request):
            handleRequest(request)
        case .takeoverComplete(let complete):
            handleTakeoverComplete(complete)
        case .takeoverFailed(let failed):
            handleTakeoverFailed(failed)
        case .doseRecordBatch(let batch):
            handleBatch(batch)
        case .handbackOffer(let offer):
            handleHandbackOffer(offer)
        case .statusReport(let report):
            handleStatusReport(report)
        case .nack:
            deps.issueNotice("Loan Protocol Error", "The watch could not read this phone's messages. Update one of the builds.")
        case .grant, .handbackAck, .revoke, .statusQuery, .denied:
            break  // watch-bound kinds
        }
    }

    // MARK: - Grant (§2.2)

    private func handleRequest(_ request: LoanRequest) {
        guard request.supportedVersions.contains(LoanProtocol.version) else {
            sendMessage(.nack(ProtocolNack(seenVersion: request.supportedVersions.max())))
            return
        }
        guard state == .owner else {
            // A NEW request means the watch is NOT in a loan — so a lingering
            // non-owner state is stale. Recover instead of refusing forever (bug E).
            switch state {
            case .grantOffered, .reconciling, .reclaimPending:
                // No live watch dosing in these states → safe to reset and grant now.
                os_log("Loan request while %{public}@ — recovering stale state and granting", log: log, type: .default, state.rawValue)
                forceReclaimToOwner(reason: "new request while \(state.rawValue)")
                beginGrant()
            case .loaned:
                // Possibly a live loan → don't steal the pod silently. Revoke (single-
                // writer preserved); the reclaim escalation forces to owner if the watch
                // is gone. The user retries in a moment.
                os_log("Loan request while LOANED — revoking the previous loan first", log: log, type: .default)
                reclaimNow()
                deny("Reclaiming the previous loan from the watch — try Start again in a few seconds.")
            case .owner:
                break
            }
            return
        }
        beginGrant()
    }

    /// Refuse the request AND tell the watch why (so it shows the reason instead of
    /// hanging on "requesting…"), plus a local phone banner for good measure.
    private func deny(_ reason: String) {
        os_log("Loan denied: %{public}@", log: log, type: .default, reason)
        sendMessage(.denied(LoanDenied(reason: reason)))
        deps.issueNotice("Sport Mode Not Started", reason)
    }

    private func beginGrant() {
        guard let pump = deps.pumpManager() else {
            deny("No pump is set up on the phone.")
            return
        }
        guard let lendable = pump as? PumpConnectionLendable else {
            deny("This pump can't be loaned to the watch (\(type(of: pump))).")
            return
        }

        // Deny-on-missing (R1/R16): the grant is refused, never defaulted.
        let settings = deps.settings()
        guard settings.basalRateSchedule != nil,
              settings.insulinSensitivitySchedule != nil,
              settings.carbRatioSchedule != nil,
              settings.glucoseTargetRangeSchedule != nil,
              settings.maximumBasalRatePerHour != nil,
              settings.maximumBolus != nil else {
            deny("Therapy settings are incomplete; the watch can't dose without them.")
            return
        }

        // Boundary record (R2/C5): capture the running temp BEFORE release closes its
        // record; the pod keeps executing it — this is bookkeeping, not a command.
        var boundary: LoanDoseRecord?
        let handedOverAt = deps.now()
        if case .tempBasal(let dose) = pump.status.basalDeliveryState {
            boundary = LoanDoseRecord(
                kind: .boundaryTruncation,
                startDate: dose.startDate,
                endDate: handedOverAt,
                unitsPerHour: dose.unitsPerHour)
        }

        // §5.3.3: capture the odometer NOW (the phone was polling until this moment)
        // so the post-reclaim re-audit has a loan-start baseline even if the watch
        // dies before ever sending one.
        if let delivered = lendable.lentDeviceInsulinDelivered {
            UserDefaults.standard.set(delivered, forKey: Keys.deliveredAtGrant)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.deliveredAtGrant)
        }
        UserDefaults.standard.set(false, forKey: Keys.watchAuditRan)
        UserDefaults.standard.removeObject(forKey: Keys.expectedUnits)

        // Pause dosing, then stop bidding for the pod (C5 truncation happens inside).
        deps.setAutomaticDosingPaused(true)
        lendable.releaseConnection()

        epoch += 1
        state = .grantOffered
        committedCursor = 0
        committedIDs = []
        persistCommittedIDs()
        staged = [:]
        stagedTombstones = []
        persistStaged()
        loanStartedAt = handedOverAt
        UserDefaults.standard.set(handedOverAt, forKey: Keys.loanStartedAt)

        let grantEpoch = epoch
        deps.doseHistory(handedOverAt.addingTimeInterval(-.hours(16))) { [weak self] history in
            guard let self = self else { return }
            self.queue.async {
                guard self.state == .grantOffered, self.epoch == grantEpoch else { return }
                guard let stateData = try? PropertyListSerialization.data(fromPropertyList: pump.rawValue, format: .binary, options: 0),
                      let settingsData = try? PropertyListSerialization.data(fromPropertyList: settings.rawValue, format: .binary, options: 0) else {
                    self.abortGrant(reason: "snapshot encoding failed")
                    return
                }
                let grant = LoanGrant(
                    epoch: grantEpoch,
                    expiresAt: handedOverAt.addingTimeInterval(.minutes(5)),
                    pumpManagerRawState: stateData,
                    podAddress: 0,
                    therapySettingsRaw: settingsData,
                    settingsTimeZoneID: settings.basalRateSchedule?.timeZone.identifier ?? TimeZone.current.identifier,
                    doseHistory: history.compactMap(Self.loanRecord(from:)),
                    boundaryRecord: boundary)
                self.sendMessage(.grant(grant))
                self.armT1(for: grantEpoch)
            }
        }
    }

    private func abortGrant(reason: String) {
        os_log("Grant aborted: %{public}@", log: log, type: .error, reason)
        sendMessage(.denied(LoanDenied(reason: "The loan could not start (\(reason)). The phone kept the pod.")))
        reclaimToOwner(alert: ("Pod Loan Failed", "The loan could not start (\(reason)). The phone kept the pod."))
    }

    /// T1 (R8): 5 min start-confirmation, cancelled by TakeoverComplete. Row 4:
    /// query-before-reclaim — a watch whose TakeoverComplete was lost gets one chance
    /// to prove it holds the pod before auto-reclaim.
    private func armT1(for grantEpoch: Int) {
        scheduleNotification(id: NotificationID.t1, title: "Watch Loan Not Confirmed",
                             body: "The watch never confirmed taking the pod. The phone reclaimed it.",
                             delay: .minutes(5), repeats: false)
        t1WorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .grantOffered, self.epoch == grantEpoch else { return }
            self.sendMessage(.statusQuery(StatusQuery(epoch: grantEpoch)))
            let confirm = DispatchWorkItem { [weak self] in
                guard let self = self, self.state == .grantOffered, self.epoch == grantEpoch else { return }
                self.reclaimToOwner(alert: ("Watch Loan Failed", "The watch never confirmed taking the pod. The phone reclaimed it."))
            }
            self.t1WorkItem = confirm
            self.queue.asyncAfter(deadline: .now() + 15, execute: confirm)
        }
        t1WorkItem = work
        queue.asyncAfter(deadline: .now() + .minutes(5), execute: work)
    }

    private func handleTakeoverComplete(_ complete: TakeoverComplete) {
        guard complete.epoch == epoch, state == .grantOffered else { return }
        t1WorkItem?.cancel()
        cancelNotification(id: NotificationID.t1)
        state = .loaned
        scheduleNotification(id: NotificationID.duration, title: "Pod Still On Loan",
                             body: "The pod has been on the watch for 6 hours.",
                             delay: .hours(6), repeats: false)

        // Silent on-loan notice with the escape-hatch action (long-press → Reclaim
        // Pod). The bench trigger for drills 12/13; the UI phase replaces it.
        let content = UNMutableNotificationContent()
        content.title = "Pod Is On the Watch"
        content.body = "The watch is running the loop. Long-press for the escape hatch."
        content.categoryIdentifier = NotificationManager.podLoanCategoryIdentifier
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: NotificationID.onLoan, content: content, trigger: nil))
    }

    private func handleTakeoverFailed(_ failed: TakeoverFailed) {
        guard failed.epoch == epoch, state == .grantOffered else { return }
        t1WorkItem?.cancel()
        cancelNotification(id: NotificationID.t1)
        reclaimToOwner(alert: ("Watch Loan Failed", "The watch could not take the pod (\(failed.reason)). The phone kept it."))
    }

    private func handleStatusReport(_ report: StatusReport) {
        guard report.epoch == epoch else { return }
        // Row 4: the query-before-reclaim answer.
        if state == .grantOffered, report.holdsPod {
            handleTakeoverComplete(TakeoverComplete(epoch: report.epoch, firstPodStatus: LoanPodStatus(timestamp: deps.now(), deliveredUnits: nil, reservoirLevel: nil, isSuspended: false, faultCode: report.podFault)))
        }
        if let fault = report.podFault {
            deps.issueNotice("Pod Fault During Loan", "The pod reported a fault while on the watch: \(fault). Check the pod.")
        }
    }

    // MARK: - Records (§2.4-2.6)

    private func handleBatch(_ batch: DoseRecordBatch) {
        guard batch.epoch == epoch, state == .loaned || state == .reclaimPending else { return }
        stage(events: batch.events, tombstones: batch.tombstones)
    }

    private func handleHandbackOffer(_ offer: HandbackOffer) {
        // Stale epoch (rows 13/14): the records still drain — they are historical
        // truth, idempotent by ID — but loan STATE is untouched and the ack says
        // stale so the sender stops retrying. Dead loans cannot speak.
        let isStale = offer.epoch < epoch
        guard offer.epoch == epoch || isStale else { return }

        if !isStale {
            guard state == .loaned || state == .reclaimPending || state == .grantOffered else {
                // Duplicate offer after commit: re-ack idempotently (row 10).
                sendMessage(.handbackAck(HandbackAck(epoch: epoch, committedCursor: committedCursor)))
                return
            }
            state = .reconciling
        }

        stage(events: offer.events, tombstones: offer.tombstones)
        let events = staged.values
            .filter { !stagedTombstones.contains($0.id) && !committedIDs.contains($0.id) && $0.seq > committedCursor }
            .sorted { $0.seq < $1.seq }

        let loanStart = loanStartedAt ?? offer.handedBackAt.addingTimeInterval(-.hours(2))
        let input = LoanReconciler.Input(
            events: events,
            odometer: offer.odometer,
            schedule: deps.settings().basalRateSchedule,
            loanStart: loanStart,
            loanEnd: offer.handedBackAt)
        let outcome = LoanReconciler.reconcile(input)

        // §5.3.3 audit inputs: the expected total over the WHOLE loan (all staged
        // events, not just this drain) and whether the watch's own audit ran.
        if !isStale {
            let allEvents = staged.values.filter { !stagedTombstones.contains($0.id) }.sorted { $0.seq < $1.seq }
            let expected = LoanReconciler.expectedInsulin(events: allEvents, schedule: deps.settings().basalRateSchedule,
                                                          from: loanStart, to: offer.handedBackAt)
            UserDefaults.standard.set(expected, forKey: Keys.expectedUnits)
            UserDefaults.standard.set(offer.odometer?.freshenSucceeded == true, forKey: Keys.watchAuditRan)
        }

        var doses = outcome.doses
        if let positive = outcome.positiveRemainderUnits {
            // R6 valve: timed at hand-back, zero decay elapsed — conservative.
            doses.append(DoseEntry(type: .bolus, startDate: offer.handedBackAt, endDate: offer.handedBackAt,
                                   value: positive, unit: .units,
                                   syncIdentifier: "loanv2-audit-\(offer.epoch)"))
        }

        // Write-doses-first; ack ONLY after commit (a897d22c). Failure: no ack, stay
        // reconciling, 1 h reminder repeats (row 11) — never dose on incomplete records.
        deps.addDoses(doses) { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    os_log("Reconcile write failed: %{public}@", log: self.log, type: .fault, String(describing: error))
                    self.deps.issueNotice("Watch Records Not Saved", "The watch session's records could not be saved. Dosing stays paused; will retry on the next hand-back attempt.")
                    self.armPausedReminder()
                    return
                }

                for carb in outcome.carbs {
                    self.deps.addCarb(carb) { _ in }  // merge-not-replace at integration
                }

                if let shortfall = outcome.residualShortfallUnits {
                    // The RULED layer-3 notice, verbatim (R22).
                    self.deps.issueNotice("Pod Delivery Check",
                        String(format: "The pod delivered %.2f U less than the watch session recorded. Records were not changed. Possible causes: pod fault, occlusion, or an interrupted command. Check the pod and review the session in Event History.", shortfall))
                }

                let newCursor = events.map(\.seq).max() ?? self.committedCursor
                if !isStale {
                    self.committedCursor = max(self.committedCursor, newCursor)
                    self.committedIDs.formUnion(events.map(\.id))
                    self.persistCommittedIDs()
                    self.sendMessage(.handbackAck(HandbackAck(epoch: self.epoch, committedCursor: self.committedCursor)))
                    self.finishLoanAfterCommit()
                } else {
                    self.sendMessage(.handbackAck(HandbackAck(epoch: offer.epoch, committedCursor: newCursor, stale: true)))
                }
            }
        }
    }

    private func finishLoanAfterCommit() {
        cancelNotification(id: NotificationID.duration)
        cancelNotification(id: NotificationID.paused)
        cancelNotification(id: NotificationID.onLoan)
        (deps.pumpManager() as? PumpConnectionLendable)?.reclaimConnection()
        pendingRevoke = false
        state = .owner
        deps.setAutomaticDosingPaused(false)
        staged = [:]
        stagedTombstones = []
        persistStaged()
        schedulePostReclaimReAudit(recordsCommitted: true)
    }

    /// §5.3.3: the phone asks the pod the same forensic questions after reclaim,
    /// shrinking the dead-watch blind window. Override for tests; the default runs
    /// the real audit 90 s after reclaim (BLE session re-establishment time).
    var postReclaimReAudit: (() -> Void)?
    private func schedulePostReclaimReAudit(recordsCommitted: Bool) {
        queue.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self = self else { return }
            if let override = self.postReclaimReAudit {
                override()
            } else {
                self.performReAudit(recordsCommitted: recordsCommitted)
            }
        }
    }

    /// The audit itself. Two modes:
    /// - recordsCommitted (normal close): compare the pod's own delivered-delta to
    ///   the committed record. If the watch's audit never ran (dead odometer), the
    ///   R6 valve applies here: positive remainder enters IOB timed-late; negative
    ///   surfaces the RULED notice (fingerprints closed at commit — R22's ambiguity
    ///   route). If the watch's audit DID run, discrepancies are notice-only.
    /// - !recordsCommitted (escape-hatch reclaim, records still owed): NOTICE-ONLY
    ///   against the schedule expectation — entries here could double-count with a
    ///   late-arriving drain, so the valve waits for reconcile.
    private func performReAudit(recordsCommitted: Bool) {
        guard let lendable = deps.pumpManager() as? PumpConnectionLendable,
              let atGrant = UserDefaults.standard.object(forKey: Keys.deliveredAtGrant) as? Double else { return }
        let watchAuditRan = UserDefaults.standard.bool(forKey: Keys.watchAuditRan)

        lendable.refreshLentDeviceStatus { [weak self] success in
            guard let self = self, success else { return }
            self.queue.async {
                guard let now = (self.deps.pumpManager() as? PumpConnectionLendable)?.lentDeviceInsulinDelivered else { return }
                let delivered = now - atGrant

                let expected: Double
                if recordsCommitted, let e = UserDefaults.standard.object(forKey: Keys.expectedUnits) as? Double {
                    expected = e
                } else if let schedule = self.deps.settings().basalRateSchedule, let start = self.loanStartedAt {
                    expected = LoanReconciler.expectedInsulin(events: [], schedule: schedule, from: start, to: self.deps.now())
                } else {
                    return
                }

                let remainder = delivered - expected
                os_log("Post-reclaim re-audit: delivered %.2f, expected %.2f, remainder %.2f (recordsCommitted %d, watchAuditRan %d)",
                       log: self.log, type: .default, delivered, expected, remainder, recordsCommitted ? 1 : 0, watchAuditRan ? 1 : 0)
                guard abs(remainder) > LoanReconciler.pulseTolerance else {
                    UserDefaults.standard.removeObject(forKey: Keys.deliveredAtGrant)
                    return
                }

                if !recordsCommitted {
                    self.deps.issueNotice("Pod Audit (Records Pending)",
                        String(format: "Since the loan began the pod delivered %.2f U versus %.2f U expected from the schedule. The watch's records have not arrived yet; nothing was changed.", delivered, expected))
                } else if watchAuditRan {
                    self.deps.issueNotice("Pod Audit Discrepancy",
                        String(format: "A post-reclaim check found the pod delivered %.2f U versus %.2f U recorded. Records were not changed. Review the session in Event History.", delivered, expected))
                } else if remainder > 0 {
                    // R6 valve, phone-side: the watch never audited; unrecorded insulin
                    // enters IOB timed at reclaim (zero decay - conservative).
                    self.deps.addDoses([DoseEntry(type: .bolus, startDate: self.deps.now(), endDate: self.deps.now(),
                                                  value: remainder, unit: .units,
                                                  syncIdentifier: "loanv2-reaudit-\(self.epoch)")]) { _ in }
                    self.deps.issueNotice("Pod Audit",
                        String(format: "The pod delivered %.2f U more than the watch session recorded. The extra insulin was added to your records at reclaim time.", remainder))
                } else {
                    // The RULED layer-3 notice, verbatim (R22).
                    self.deps.issueNotice("Pod Delivery Check",
                        String(format: "The pod delivered %.2f U less than the watch session recorded. Records were not changed. Possible causes: pod fault, occlusion, or an interrupted command. Check the pod and review the session in Event History.", -remainder))
                }
                if recordsCommitted {
                    UserDefaults.standard.removeObject(forKey: Keys.deliveredAtGrant)
                }
            }
        }
    }

    // MARK: - Escape hatch (§3.1 RECLAIM_PENDING, R7)

    func reclaimNow() {
        queue.async {
            guard self.podIsOnLoan else { return }
            self.pendingRevoke = true
            self.cancelNotification(id: NotificationID.onLoan)
            self.sendMessage(.revoke(Revoke(epoch: self.epoch)))
            (self.deps.pumpManager() as? PumpConnectionLendable)?.reclaimConnection()
            self.state = .reclaimPending
            self.armPausedReminder()
            // §5.3.3 dead-watch path: audit against the schedule, notice-only.
            self.schedulePostReclaimReAudit(recordsCommitted: false)
            // R7 override, made real: if the watch never drains within 45 s (dead /
            // gone / already handed off), force back to OWNER so we never strand.
            self.reclaimTimeoutWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.state == .reclaimPending else { return }
                self.forceReclaimToOwner(reason: "reclaim timed out — watch did not drain")
            }
            self.reclaimTimeoutWork = work
            self.queue.asyncAfter(deadline: .now() + 45, execute: work)
        }
    }

    /// The R7 explicit override, made real: abandon a stuck/stale loan and return to
    /// OWNER unconditionally. Records are NOT dropped blindly — any staged events are
    /// written to the store first (records are truth; never understate IOB), then the
    /// pod is reclaimed and dosing restored. Used when a new request proves the old
    /// loan is dead, when reclaim times out, or on a relaunch into a stranded state.
    func forceReclaimToOwner(reason: String) {
        os_log("Force reclaim to OWNER: %{public}@", log: log, type: .default, reason)
        reclaimTimeoutWork?.cancel()
        cancelNotification(id: NotificationID.onLoan)
        cancelNotification(id: NotificationID.paused)
        cancelNotification(id: NotificationID.duration)

        // Preserve known insulin: reconcile staged events records-only (no odometer)
        // and write them before we drop them.
        let events = staged.values
            .filter { !stagedTombstones.contains($0.id) && !committedIDs.contains($0.id) }
            .sorted { $0.seq < $1.seq }
        if !events.isEmpty {
            let input = LoanReconciler.Input(
                events: events, odometer: nil, schedule: deps.settings().basalRateSchedule,
                loanStart: loanStartedAt ?? deps.now().addingTimeInterval(-.hours(2)),
                loanEnd: deps.now())
            let outcome = LoanReconciler.reconcile(input)
            deps.addDoses(outcome.doses) { _ in }
            for carb in outcome.carbs { deps.addCarb(carb) { _ in } }
            deps.issueNotice("Sport Mode Reset", "A previous watch loan was ended without a clean hand-back; its records were saved. Check Event History and the pod.")
        }

        (deps.pumpManager() as? PumpConnectionLendable)?.reclaimConnection()
        pendingRevoke = false
        state = .owner
        deps.setAutomaticDosingPaused(false)
        staged = [:]
        stagedTombstones = []
        persistStaged()
    }

    /// Re-send a parked revoke on any sign of watch life (kept from v1).
    func watchDidBecomeReachable() {
        queue.async {
            if self.pendingRevoke {
                self.sendMessage(.revoke(Revoke(epoch: self.epoch)))
            }
        }
    }

    // MARK: - Helpers

    private func reclaimToOwner(alert: (title: String, body: String)) {
        cancelNotification(id: NotificationID.onLoan)
        (deps.pumpManager() as? PumpConnectionLendable)?.reclaimConnection()
        state = .owner
        deps.setAutomaticDosingPaused(false)
        deps.issueNotice(alert.title, alert.body)
    }

    private func stage(events: [LoanEvent], tombstones: [UUID]) {
        for event in events { staged[event.id] = event }
        stagedTombstones.formUnion(tombstones)
        persistStaged()
    }

    private func sendMessage(_ message: LoanMessage) {
        guard let dictionary = try? message.transportDictionary() else { return }
        deps.send(dictionary)
    }

    private static func loanRecord(from dose: DoseEntry) -> LoanDoseRecord? {
        switch dose.type {
        case .bolus:
            return LoanDoseRecord(kind: .bolus, startDate: dose.startDate, endDate: dose.endDate, amount: dose.deliveredUnits ?? dose.programmedUnits)
        case .tempBasal:
            return LoanDoseRecord(kind: .tempBasal, startDate: dose.startDate, endDate: dose.endDate, unitsPerHour: dose.unitsPerHour)
        case .suspend:
            return LoanDoseRecord(kind: .suspend, startDate: dose.startDate, endDate: dose.endDate, unitsPerHour: 0)
        case .basal, .resume:
            return nil
        }
    }

    // MARK: - R8 notifications (the COMPLETE alarm inventory)

    private func scheduleNotification(id: String, title: String, body: String, delay: TimeInterval, repeats: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: repeats)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func cancelNotification(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    private func armPausedReminder() {
        scheduleNotification(id: NotificationID.paused, title: "Automatic Dosing Paused",
                             body: "Dosing has been paused since the pod loan ended without complete records. Reconcile or re-enable Closed Loop to override.",
                             delay: .hours(1), repeats: true)
    }

    // MARK: - Staging persistence (trap-cell defense survives phone relaunch)

    private var stagedFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PodLoanStagedRecordsV2.json")
    }

    private struct StagedState: Codable {
        let epoch: Int
        let events: [LoanEvent]
        let tombstones: [UUID]
    }

    private func persistStaged() {
        let snapshot = StagedState(epoch: epoch, events: Array(staged.values), tombstones: Array(stagedTombstones))
        if let data = try? LoanProtocol.encoder.encode(snapshot) {
            try? data.write(to: stagedFileURL, options: .atomic)
        }
    }

    private func loadStaged() {
        guard let data = try? Data(contentsOf: stagedFileURL),
              let snapshot = try? LoanProtocol.decoder.decode(StagedState.self, from: data),
              snapshot.epoch == epoch else { return }
        for event in snapshot.events { staged[event.id] = event }
        stagedTombstones.formUnion(snapshot.tombstones)
    }

    private func persistCommittedIDs() {
        UserDefaults.standard.set(committedIDs.map(\.uuidString), forKey: Keys.committedIDs)
    }
}
