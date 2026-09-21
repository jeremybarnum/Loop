//
//  PodLoanPhoneController.swift
//  Loop
//
//  The phone half of loan protocol v2 (docs/DESIGN_LOAN_PROTOCOL_V2.md §3.1, §10).
//  Persisted state machine (podLoanedToWatch is DERIVED from this state, never a
//  volatile flag), epoch minting, grant assembly with deny-on-missing, the alarm
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

    struct ReclaimProgress: Equatable {
        enum Phase: Equatable {
            case draining

            case watchNotAnswering

            case forcing

            case reconnectingToPod

            case forceReclaimingPod
        }
        let phase: Phase

        let startedAt: Date

        let expectedBy: Date

        let fraction: Double?

        let elapsed: TimeInterval
    }

    struct Dependencies {
        var pumpManager: () -> PumpManager?

        var settings: () -> LoopSettings

        var setAutomaticDosingPaused: (Bool) -> Void

        var send: ([String: Any]) -> Void

        var addPumpEvents: ([NewPumpEvent], _ lastReconciliation: Date?, @escaping (Error?) -> Void) -> Void

        var addCarb: (NewCarbEntry, String, @escaping (Error?) -> Void) -> Void

        var deleteCarb: (LoanReconciler.DeletedCarb, @escaping (Error?) -> Void) -> Void = { _, done in done(nil) }

        var watchAppInstalled: () -> Bool = { true }

        var scheduleOverride: () -> TemporaryScheduleOverride? = { nil }
        var applyScheduleOverride: (TemporaryScheduleOverride?) -> Void = { _ in }

        var noteWatchClosedLoop: (Bool) -> Void = { _ in }

        var lastLoopCompleted: () -> Date? = { nil }

        var noteWatchLoopCompleted: (Date) -> Void = { _ in }

        var doseHistory: (_ start: Date, _ completion: @escaping ([DoseEntry]) -> Void) -> Void

        var carbHistory: (_ start: Date, _ completion: @escaping ([LoanCarbRecord]) -> Void) -> Void = { _, done in done([]) }

        var glucoseHistory: (_ start: Date, _ completion: @escaping ([LoanGlucoseRecord]) -> Void) -> Void = { _, done in done([]) }

        var issueNotice: (_ title: String, _ body: String) -> Void

        var ownershipDidChange: () -> Void = {}

        var isConnectionReady: () -> Bool = { true }

        var cancelTempBasalAfterPodReturn: (@escaping (Error?) -> Void) -> Void = { $0(nil) }

        var cancelTempBasalForGrant: (@escaping (Error?) -> Void) -> Void = { $0(nil) }

        var openLoopForUncertainReconciliation: () -> Void = {}

        var issueUrgentNotice: (_ title: String, _ body: String) -> Void = { _, _ in }

        var bookGapDose: (_ entry: DoseEntry, _ completion: @escaping (Bool) -> Void) -> Void = { _, done in done(false) }

        var deleteGapDose: (_ syncIdentifier: String, _ completion: @escaping (Bool) -> Void) -> Void = { _, done in done(false) }

        var backfillDoses: (_ doses: [DoseEntry], _ completion: @escaping (Error?) -> Void) -> Void = { _, done in done(nil) }

        var insulinHistoryRewritten: (_ earliestDoseStart: Date) -> Void = { _ in }

        var whenProtectedDataAvailable: (@escaping () -> Void) -> Void = { $0() }

        var beginReclaimBackgroundTask: () -> Void = {}
        var endReclaimBackgroundTask: () -> Void = {}
        var isWatchReachable: () -> Bool = { false }

        var isBluetoothPoweredOff: () -> Bool = { false }

        var lastWatchContactAt: () -> Date? = { nil }

        var latestGlucoseDate: () -> Date? = { nil }
        var now: () -> Date = { Date() }
    }

    static let bookUnattributedInsulinOnForceReclaim = true

    let log = OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanPhoneController")
    let queue = DispatchQueue(label: "com.loopkit.Loop.PodLoanPhoneController", qos: .utility)
    var deps: Dependencies

    func handleIncoming(userInfo: [String: Any]) {
        queue.async { self.handleIncomingOnQueue(userInfo) }
    }

    func handleIncomingOnQueue(_ userInfo: [String: Any]) {
        let message: LoanMessage?
        do {
            message = try LoanMessage.decode(fromTransport: userInfo)
        } catch {
            sendMessage(.nack(ProtocolNack(seenVersion: nil)))
            warnProtocolMismatch()
            return
        }
        hasWarnedProtocolMismatch = false
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

            os_log("Loan protocol skew — the WATCH could not decode a message from this phone", log: log, type: .fault)
        case .grant, .handbackAck, .revoke, .statusQuery, .denied, .diag, .dormantGrant:
            break
        }
    }

    func reclaimToOwner(alert: (title: String, body: String)?, reason: String) {
        handbackDiag(epoch, "loan ABANDONED — back to phone control: \(reason)")

        cancelReclaimLadder()
        deps.endReclaimBackgroundTask()

        grantOfferedAt = nil
        clearAuditAnchors()
        reclaimPodConnection()
        state = .owner
        deps.setAutomaticDosingPaused(false)
        if let alert = alert { deps.issueNotice(alert.title, alert.body) }
    }

    func stage(events: [LoanEvent], tombstones: [UUID]) {
        for event in events { staged[event.id] = event }
        stagedTombstones.formUnion(tombstones)
        persistStaged()
    }

    func sendMessage(_ message: LoanMessage) {
        guard let dictionary = try? message.transportDictionary() else { return }
        deps.send(dictionary)
    }

    static func loanRecord(from dose: DoseEntry) -> LoanDoseRecord? {
        switch dose.type {
        case .bolus:
            return LoanDoseRecord(kind: .bolus, startDate: dose.startDate, endDate: dose.endDate, amount: dose.deliveredUnits ?? dose.programmedUnits,
                                  syncIdentifier: dose.syncIdentifier, insulinType: dose.insulinType)
        case .tempBasal:

            return LoanDoseRecord(kind: .tempBasal, startDate: dose.startDate, endDate: dose.endDate, unitsPerHour: dose.unitsPerHour,
                                  syncIdentifier: dose.syncIdentifier, insulinType: dose.insulinType,
                                  deliveredUnits: dose.deliveredUnits)
        case .suspend:
            return LoanDoseRecord(kind: .suspend, startDate: dose.startDate, endDate: dose.endDate, unitsPerHour: 0,
                                  syncIdentifier: dose.syncIdentifier, insulinType: dose.insulinType,
                                  deliveredUnits: dose.deliveredUnits)
        case .basal, .resume:
            return nil
        }
    }

    init(dependencies: Dependencies) {
        self.deps = dependencies
        self.state = State(rawValue: UserDefaults.standard.string(forKey: Keys.state) ?? "") ?? .owner
        self.epoch = UserDefaults.standard.object(forKey: Keys.epoch) as? Int ?? 0

        self.yieldingToInferredLoan = UserDefaults.standard.bool(forKey: Keys.yieldingToInferredLoan)
        self.committedCursor = UserDefaults.standard.object(forKey: Keys.cursor) as? Int ?? 0
        self.pendingRevoke = UserDefaults.standard.bool(forKey: Keys.pendingRevoke)
        self.loanStartedAt = UserDefaults.standard.object(forKey: Keys.loanStartedAt) as? Date
        if let raw = UserDefaults.standard.array(forKey: Keys.committedIDs) as? [String] {
            self.committedIDs = Set(raw.compactMap(UUID.init(uuidString:)))
        } else {
            self.committedIDs = []
        }
        loadStaged()

        if let d = UserDefaults.standard.dictionary(forKey: Keys.auditBase),
           let units = d["units"] as? Double, let asOf = d["asOf"] as? Date,
           (d["epoch"] as? Int) == self.epoch {
            self.auditBase = AuditBase(units: units, asOf: asOf)
            self.checkpointsThisLoan = d["count"] as? Int ?? 0
        }
        installPodLinkCensus()

        if !UserDefaults.standard.bool(forKey: Keys.residualHistoryPurged) {
            if var history = UserDefaults.standard.array(forKey: Keys.residualHistory) as? [Double] {
                let before = history.count
                history.removeAll { $0 > 0.5 }
                if history.count != before {
                    UserDefaults.standard.set(history, forKey: Keys.residualHistory)
                }
            }
            UserDefaults.standard.set(true, forKey: Keys.residualHistoryPurged)
        }

        if let saved = UserDefaults.standard.dictionary(forKey: Keys.pendingForceAudit),
           let e = saved["epoch"] as? Int, let atStart = saved["atStart"] as? Double,
           let expected = saved["expected"] as? Double, let loanMinutes = saved["loanMinutes"] as? Double {
            pendingHandbackAudit = PendingHandbackAudit(
                epoch: e, deliveredAtStart: atStart, expected: expected,
                loanMinutes: loanMinutes, cycles: 0,
                watchLatest: nil, watchFreshened: false, flavor: .forceReclaim)
            queue.async { [weak self] in
                guard let self = self else { return }
                self.handbackDiag(e, "R37 audit RE-ARMED after relaunch — verdict still owed")
                self.beginReclaimSettleWindow()
            }
        }

        deps.whenProtectedDataAvailable { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                self.retryPersistedGapDeleteIfAny()

                self.cancelOpenLoopReminderIfLoopClosed()
            }
        }

        if podIsOnLoan {
            deps.setAutomaticDosingPaused(true)

            if state == .reconciling || state == .reclaimPending {
                let stranded = state
                queue.asyncAfter(deadline: .now() + 120) { [weak self] in
                    guard let self = self, self.state == stranded else { return }
                    self.forceReclaimToOwner(reason: "relaunched into \(stranded.rawValue), no hand-back")
                }
            } else if state == .grantOffered {
                armT1(for: epoch)
            }
        }
    }

    let uiMirrorLock = NSLock()
    var uiMirror = UISnapshot()

    var reclaimStartedAt: Date?
    var reclaimSettleWork: DispatchWorkItem?

    var reclaimVerifiedAt: Date?
    var reclaimVerifyInFlight = false

    var reclaimLinkUpAt: Date?

    var reclaimEscalated = false
    var reclaimStaleReads = 0

    var reclaimDisplayAnchor: Date?

    var lastRequestID: String?
    var lastRequestAt: Date?

    var hasWarnedProtocolMismatch = false

    var checkpointsThisLoan = 0

    var worstWindowThisLoan: Double = 0

    var commitInFlight = false

    var coalescedOffers: [Int: HandbackOffer] = [:]

    var grantInFlight = false
    var pendingForceReclaimReason: String?
    var committedIDs: Set<UUID>

    var staged: [UUID: LoanEvent] = [:]
    var stagedTombstones: Set<UUID> = []
    var loanStartedAt: Date?
    var t1WorkItem: DispatchWorkItem?
    var reclaimTimeoutWork: DispatchWorkItem?
    var reclaimResendWork: DispatchWorkItem?

    var reclaimLadder: ReclaimLadder?

    var scheduler: ((_ delay: TimeInterval, _ label: String, _ work: DispatchWorkItem) -> Void)?

    var lastDormantRefreshAt: Date?

    var trailingDormantRefreshPending = false

    var lastClosedSessionRevokeAt: Date?
    var lastDormantSettingsFingerprint: String?

    var newestForeignLoanEvidence: (epoch: Int, at: Date)?

    var grantOfferedAt: Date?

    var yieldingToInferredLoan: Bool {
        didSet { UserDefaults.standard.set(yieldingToInferredLoan, forKey: Keys.yieldingToInferredLoan) }
    }

    var state: State {
        didSet {
            UserDefaults.standard.set(state.rawValue, forKey: Keys.state)

            if oldValue != state {
                if oldValue != .owner, state == .owner {
                    beginReclaimSettleWindow()
                }

                syncUIMirror()
                deps.ownershipDidChange()
            }
        }
    }

    var epoch: Int {
        didSet { UserDefaults.standard.set(epoch, forKey: Keys.epoch) }
    }

    var committedCursor: Int {
        didSet { UserDefaults.standard.set(committedCursor, forKey: Keys.cursor) }
    }

    var auditBase: AuditBase? {
        didSet {
            if let b = auditBase {
                UserDefaults.standard.set(["units": b.units, "asOf": b.asOf, "epoch": epoch,
                                           "count": checkpointsThisLoan],
                                          forKey: Keys.auditBase)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.auditBase)
            }
        }
    }

    var pendingHandbackAudit: PendingHandbackAudit? {
        didSet {
            if let p = pendingHandbackAudit, p.flavor == .forceReclaim {
                UserDefaults.standard.set(["epoch": p.epoch, "atStart": p.deliveredAtStart,
                                           "expected": p.expected, "loanMinutes": p.loanMinutes],
                                          forKey: Keys.pendingForceAudit)
            } else if oldValue?.flavor == .forceReclaim {
                UserDefaults.standard.removeObject(forKey: Keys.pendingForceAudit)
            }
        }
    }

    var pendingRevoke: Bool {
        didSet { UserDefaults.standard.set(pendingRevoke, forKey: Keys.pendingRevoke) }
    }
}
