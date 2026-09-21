//
//  PodLoanWatchController.swift
//  WatchApp Extension
//
//  The watch half of loan protocol v2 (docs/DESIGN_LOAN_PROTOCOL_V2.md §3.2, §10).
//  State machine, grant intake -> stock OmniPumpManager construction, the pump-host
//  delegate duties (the pump manager's report writes the book AND the journal — one
//  identity per dose, the pod-native raw), hand-back with resend-until-ack, revoke, and
//  the relaunch drain (data-first: a dead session is never resurrected). Uncertainty is
//  the pump manager's own: an unacknowledged command is resolved on its next session.
//
//  Transport is injected (`send`) so the controller is testable without WCSession;
//  the app-lifecycle integration wires WCSession.transferUserInfo/didReceiveUserInfo
//  to `send`/`handleIncoming`.
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import OmnipodKit
import WatchKit
import os.log

extension Notification.Name {
    static let podLoanPhaseDidChange = Notification.Name("com.loopkit.Loop.podLoanPhaseDidChange")

    static let manualBolusStateDidChange = Notification.Name("com.loopkit.Loop.manualBolusStateDidChange")

    static let carbAndBolusFlowDidComplete = Notification.Name("com.loopkit.Loop.carbAndBolusFlowDidComplete")
}

enum HandbackWedge: Equatable {
    case none

    case oneWay

    case sessionReestablishing

    static func classify(resendCount: Int,
                         sawUnreachable: Bool,
                         reachableNow: Bool,
                         sendsErrored: Bool) -> HandbackWedge {
        guard resendCount >= 3, !sawUnreachable, reachableNow else { return .none }
        return sendsErrored ? .sessionReestablishing : .oneWay
    }
}

final class PodLoanWatchController {
    enum Phase: String {
        case idle, requested, takingOver, active, handingBack, revoked

        case recoveredDrain
    }

    let log = OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanWatchController")
    let queue = DispatchQueue(label: "com.loopkit.Loop.PodLoanWatchController", qos: .utility)
    let loopManager: WatchLoopManager
    let journal: LoanEventJournal

    var now: () -> Date = Date.init

    var scheduler: ((_ delay: TimeInterval, _ label: String, _ work: DispatchWorkItem) -> Void)?

    func schedule(after delay: TimeInterval, label: String, execute work: DispatchWorkItem) {
        let armedEpoch = epoch
        let armedAt = now()
        SportLog.event("timer", "armed \(label) +\(fmtDelay(delay)) e=\(armedEpoch.map(String.init) ?? "-")")
        let wrapper = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if work.isCancelled {
                SportLog.event("timer", "skipped \(label) — cancelled before its deadline")
                return
            }
            let late = self.now().timeIntervalSince(armedAt) - delay
            let lateNote = late > 1.0 ? String(format: " late %.1fs", late) : ""
            let epochNote = armedEpoch != self.epoch
                ? " ** armed e=\(armedEpoch.map(String.init) ?? "-") firing e=\(self.epoch.map(String.init) ?? "-") — cross-epoch **"
                : ""
            SportLog.event("timer", "fired \(label) +\(self.fmtDelay(delay))\(lateNote)\(epochNote)")
            work.perform()
        }
        if let scheduler = scheduler {
            scheduler(delay, label, wrapper)
        } else {
            queue.asyncAfter(deadline: .now() + delay, execute: wrapper)
        }
    }

    func schedule(after delay: TimeInterval, label: String, execute body: @escaping () -> Void) {
        schedule(after: delay, label: label, execute: DispatchWorkItem(block: body))
    }

    private func fmtDelay(_ d: TimeInterval) -> String {
        d < 1 ? String(format: "%.2fs", d) : String(format: "%.0fs", d)
    }

    var defaults: UserDefaults = .standard

    var isPhoneReachable: () -> Bool = { true }

    var lastHandbackReachable: Bool?

    var handbackSawUnreachable = false

    var handbackSawUrgentSendError = false

    func noteUrgentSendFailed() {
        queue.async { self.handbackSawUrgentSendError = true }
        urgentSendWedged = true
    }

    var urgentSendWedged = false

    var send: (([String: Any]) -> Void)?

    var cancelQueuedLoanRequests: (() -> Int)?

    func cancelStaleQueuedRequests(context: String) {
        guard let cancelled = cancelQueuedLoanRequests?(), cancelled > 0 else { return }
        SportLog.event("loan", "cancelled \(cancelled) queued loan request(s) — \(context); a delivered ghost would re-grant over whatever this watch does next")
    }

    var onLoanActiveChanged: ((Bool) -> Void)?

    var onTakeoverRadioHold: ((Bool) -> Void)?

    var onHandbackRuntimeHold: ((Bool) -> Void)?

    var handbackFailure: (at: Date, text: String)?

    var startNote: (at: Date, text: String)?

    var takeoverCopyTotal: (units: Double, asOf: Date)?
    var takeoverCopyRecords: [LoanDoseRecord] = []
    var phase: Phase {
        didSet {
            defaults.set(phase.rawValue, forKey: Keys.phase)
            loanActiveMirrorLock.lock()
            _loanActiveMirror = (phase == .active)
            loanActiveMirrorLock.unlock()
            if (oldValue == .takingOver) != (phase == .takingOver) {
                onTakeoverRadioHold?(phase == .takingOver)
                setTakeoverSessionListener(phase == .takingOver)
            }

            if (oldValue == .handingBack) != (phase == .handingBack) {
                onHandbackRuntimeHold?(phase == .handingBack)
            }

            if oldValue != phase {
                NotificationCenter.default.post(name: .podLoanPhaseDidChange, object: nil)
            }
        }
    }
    var epoch: Int? {
        didSet { defaults.set(epoch, forKey: Keys.epoch) }
    }

    func notifyUI() {
        NotificationCenter.default.post(name: .podLoanPhaseDidChange, object: nil)
    }

    var pumpManager: OmniPumpManager?

    var deliveredAtTakeover: Double?

    var attemptStartedAt: Date?

    var lastTakeoverReadAt: Date?

    var takeoverRetryAction: (() -> Void)?
    var takeoverBackstop: DispatchWorkItem?
    var takeoverMaxReadGap: TimeInterval = 0

    var handbackResendCount = 0

    var handbackRequested = false

    var phoneSupportsInterimHandback = false

    var phoneSupportsOverrideRecords = false

    var finalOfferSent = false
    var resendWorkItem: DispatchWorkItem?

    static let maxDrainResends = 20

    var handbackDeadline: Date?

    var handbackStartedAt: Date?

    var finalOfferSentAt: Date?
    var requestTimeoutWork: DispatchWorkItem?

    var lastIdleNote: String?

    var pendingInterruptedTakeoverEpoch: Int?

    var takeoverCachedHandle: (address: UInt32, handle: String)?

    enum Keys {
        static let phase = "PodLoanWatchController.phase"
        static let epoch = "PodLoanWatchController.epoch"

        static let pumpState = "PodLoanWatchController.pumpState"

        static let deliveredAtTakeover = "PodLoanWatchController.deliveredAtTakeover"

        static let grantedTherapySettings = "PodLoanWatchController.grantedTherapySettings"

        static let highWaterEpoch = "PodLoanWatchController.highWaterEpoch"
    }

    init(loopManager: WatchLoopManager, journal: LoanEventJournal = LoanEventJournal(),
         defaults: UserDefaults = .standard) {
        self.loopManager = loopManager
        self.journal = journal
        self.defaults = defaults
        self.phase = Phase(rawValue: defaults.string(forKey: Keys.phase) ?? "") ?? .idle
        self.epoch = defaults.object(forKey: Keys.epoch) as? Int

        let savedPumpState = phase == .active ? defaults.dictionary(forKey: Keys.pumpState) : nil
        if let savedPumpState {
            pendingResumeState = savedPumpState

            loanActiveMirrorLock.lock()
            _loanActiveMirror = true
            _resumingMirror = true
            loanActiveMirrorLock.unlock()
            loopManager.beginAwaitingPumpManager()
        } else if journal.hasUndrainedEvents {
            phase = .recoveredDrain
            issueSessionEndedAlert()
        } else {
            switch phase {
            case .idle:
                break
            case .requested, .takingOver:

                pendingInterruptedTakeoverEpoch = epoch
                lastIdleNote = NSLocalizedString("Sport Mode start was interrupted. Tap Start to try again.", comment: "Glance: start interrupted by relaunch")
                phase = .idle
                epoch = nil
            case .active, .handingBack, .revoked, .recoveredDrain:

                phase = .recoveredDrain
                issueSessionEndedAlert()
            }
        }
    }

    private var pendingResumeState: PumpManager.RawStateValue?

    func resumeIfNeeded() {
        let rebuild = DispatchWorkItem(qos: .userInitiated, flags: .enforceQoS) {
            guard let saved = self.pendingResumeState else { return }
            self.pendingResumeState = nil
            self.resumeSavedLoanOnQueue(saved)
        }
        queue.async(execute: rebuild)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Sport Mode resume") { expired in
            if !expired { rebuild.wait() }
        }
    }

    private func endResuming() {
        loanActiveMirrorLock.lock()
        _resumingMirror = false
        loanActiveMirrorLock.unlock()
        _ = loopManager.endAwaitingPumpManager()
        notifyUI()
    }

    private func resumeSavedLoanOnQueue(_ savedState: PumpManager.RawStateValue) {
        defer { endResuming() }

        guard let payload = defaults.dictionary(forKey: Keys.grantedTherapySettings),
              let raw = payload["raw"] as? Data,
              let settings = Self.decodeTherapySettings(raw: raw, supplement: payload["supplement"] as? Data),
              settings.basalRateSchedule != nil else {
            defaults.removeObject(forKey: Keys.pumpState)
            defaults.removeObject(forKey: Keys.grantedTherapySettings)
            phase = .recoveredDrain
            issueSessionEndedAlert()
            SportLog.event("loan", "RESUME failed — therapy settings unreadable; falling back to a recovered drain")
            return
        }

        SportLog.event("loan", "RESUME: building the pump manager from saved state")
        guard let manager = OmniPumpManager(rawState: savedState) else {
            defaults.removeObject(forKey: Keys.pumpState)
            defaults.removeObject(forKey: Keys.grantedTherapySettings)
            phase = .recoveredDrain
            issueSessionEndedAlert()
            SportLog.event("loan", "RESUME failed — saved pod state unreadable; falling back to a recovered drain")
            return
        }
        SportLog.event("loan", "RESUME: pump manager built")
        loopManager.settings = settings
        phoneSupportsInterimHandback = payload["interim"] as? Bool ?? false
        phoneSupportsOverrideRecords = payload["overrideRecords"] as? Bool ?? false
        deliveredAtTakeover = defaults.object(forKey: Keys.deliveredAtTakeover) as? Double
        manager.pumpManagerDelegate = self
        manager.delegateQueue = queue
        pumpManager = manager

        phase = .active
        loopManager.pumpManager = manager
        onLoanActiveChanged?(true)

        let lastSync = manager.lastSync
        let readingWaited = loopManager.endAwaitingPumpManager()
        Task { [loopManager] in
            if let lastSync { try? await loopManager.recordPumpEvents([], lastReconciliation: lastSync, replacePendingEvents: false) }
            loopManager.updateDisplayState()
            if readingWaited {
                SportLog.event("loan", "RESUME: a reading arrived while the pump manager was being built — running its cycle now")
                loopManager.checkPumpDataAndLoop()
            }
        }
        SportLog.event("loan", "RESUMED — epoch \(epoch ?? -1) rebuilt from saved pod state after a relaunch (R40(e): stock relaunch) · \(RuntimeStateLog.snapshot())")
    }

    private func issueSessionEndedAlert() {
        let title = NSLocalizedString("Sport Mode Ended", comment: "Watch alert title on relaunch after the app died mid-loan")
        let body = NSLocalizedString("The watch app restarted. Insulin and carb records may not be on the phone yet.", comment: "Watch alert body on relaunch after the app died mid-loan")
        Task { @MainActor in
            loopManager.issueAlert(Alert(
                identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "sessionEnded"),
                foregroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                backgroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                trigger: .immediate))
        }
    }

    func handleIncoming(userInfo: [String: Any], channel: LoanTransportChannel) {
        queue.async { self.handleIncomingOnQueue(userInfo: userInfo, channel: channel) }
    }

    private func handleIncomingOnQueue(userInfo: [String: Any], channel: LoanTransportChannel) {
        let message: LoanMessage?
        do {
            message = try LoanMessage.decode(fromTransport: userInfo)
        } catch {
            os_log("Undecodable v2 payload: %{public}@", log: log, type: .fault, String(describing: error))
            sendMessage(.nack(ProtocolNack(seenVersion: nil)))
            return
        }
        guard let message = message else { return }

        SportLog.event("loan", "RX \(message.kindLabel) ch=\(channel.rawValue) — ours ev=\(epoch.map(String.init) ?? "nil") phase=\(phase.rawValue)")

        switch message {
        case .grant(let grant):
            handleGrant(grant)
        case .handbackAck(let ack):
            handleAck(ack)
        case .revoke(let revoke):
            handleRevoke(revoke)
        case .statusQuery(let query):
            handleStatusQuery(query)
        case .nack:

            SportLog.event("loan", "phone NACKed our payload — build mismatch; the loan will not start")
        case .denied(let denied):

            if (phase == .active && handbackRequested) || phase == .handingBack {
                handbackTimedOut(refusal: denied.reason)
                return
            }

            requestTimeoutWork?.cancel()
            if phase == .requested || phase == .idle || phase == .recoveredDrain {
                returnToRestingPhase()
                lastIdleNote = denied.reason
                notifyUI()
            }
            SportLog.event("loan", "DENIED by phone — \(denied.reason)")
        case .diag(let d):
            SportLog.event("phone", d.text)
        case .dormantGrant(let dormant):
            handleDormantGrant(dormant)
        case .request, .takeoverComplete, .takeoverFailed, .doseRecordBatch, .handbackOffer, .statusReport:
            os_log("Ignoring phone-bound message kind on watch", log: log, type: .default)
        }
    }

    func sendMessage(_ message: LoanMessage, urgentOnly: Bool = false) {
        guard var dictionary = try? message.transportDictionary() else { return }
        if urgentOnly { dictionary["urgentOnly"] = true }
        send?(dictionary)
    }

    func issueProtocolAlert(title: String, body: String) {
        Task { @MainActor in
            loopManager.issueAlert(Alert(
                identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "protocolNack"),
                foregroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                backgroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                trigger: .immediate))
        }
    }

    func teardownPump() {
        SportLog.event("handback", "teardownPump: releasing BLE explicitly (see PODLOAN release log for the identifier)")
        pumpManager?.releaseConnection()
        pumpManager?.pumpManagerDelegate = nil
        pumpManager = nil
        defaults.removeObject(forKey: Keys.pumpState)
        defaults.removeObject(forKey: Keys.deliveredAtTakeover)
        defaults.removeObject(forKey: Keys.grantedTherapySettings)

        let loopManager = self.loopManager
        Task { await loopManager.resetInsulinBook(reason: "teardown") }

        loopManager.applyWristOverride(nil)
    }

    func streamRecords(renewal: Bool = false) {
        guard phase == .active, let epoch = epoch else { return }
        let events = journal.unackedEvents()
        let tombstones = journal.pendingTombstones()
        let empty = events.isEmpty && tombstones.isEmpty
        guard renewal || !empty else { return }

        var odometer: LoanOdometerSnapshot?
        if let start = deliveredAtTakeover, let latest = pumpManager?.podLoanInsulinDelivered,
           let asOf = pumpManager?.podLoanInsulinDeliveredAt {
            odometer = LoanOdometerSnapshot(deliveredAtStart: start, deliveredLatest: latest,
                                            freshenSucceeded: false, asOf: asOf)
        }
        if !empty {
            SportLog.event("handback", String(format: "stream: %d event(s), %d tombstone(s)%@", events.count, tombstones.count,
                                              odometer.map { String(format: " · odo %.2f U @ %@ [checkpoint]", $0.deliveredLatest, DateFormatter.localizedString(from: $0.asOf ?? .distantPast, dateStyle: .none, timeStyle: .medium)) } ?? ""))
        }

        sendMessage(.doseRecordBatch(DoseRecordBatch(epoch: epoch, events: events, tombstones: tombstones,
                                                     odometer: odometer, sentAt: self.now())),
                    urgentOnly: empty)
    }

    func renewHold() {
        queue.async { self.streamRecords(renewal: true) }
    }

    var seizeOffer: (issuedAt: Date, token: UUID)?

    var seizeActivationInFlight = false

    var pendingSeizeToken: UUID?

    var seizeReunionDebounceArmed = false

    var reunionPromptActive = false

    var simGlucoseTimer: DispatchSourceTimer?

    var revokeCapturedDelivered: Double?

    var revokeCapturedDeliveredAt: Date?
    var lastRevokedEpoch: Int?

    let loanActiveMirrorLock = NSLock()
    var _loanActiveMirror = false

    var _resumingMirror = false

    let snapshotMirrorLock = NSLock()

    var _snapshotMirror: DebugSnapshot?
}

enum LoanTransportChannel: String {
    case urgent
    case queued
}
