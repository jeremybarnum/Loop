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
        /// Store writes. Loan insulin goes through the pump-event path (not addDoses) so
        /// it lands in the PumpEvent table (Event History), is run through stock
        /// InsulinMath.reconciled() at the store (overlap truncation), and mirrors into
        /// InsulinDeliveryStore/HealthKit — behaving exactly like real pump insulin (#69/#52).
        var addPumpEvents: ([NewPumpEvent], _ lastReconciliation: Date?, @escaping (Error?) -> Void) -> Void
        var addCarb: (NewCarbEntry, @escaping (Error?) -> Void) -> Void
        /// 16 h insulin history for the grant.
        var doseHistory: (_ start: Date, _ completion: @escaping ([DoseEntry]) -> Void) -> Void
        /// Active carb entries for the grant (#49) — seeded so the watch predicts with COB.
        var carbHistory: (_ start: Date, _ completion: @escaping ([LoanCarbRecord]) -> Void) -> Void = { _, done in done([]) }
        /// ~3 h of recent glucose for the grant — seeded so the watch's momentum + retrospective
        /// correction warm from the first post-takeover cycle instead of a cold empty store.
        var glucoseHistory: (_ start: Date, _ completion: @escaping ([LoanGlucoseRecord]) -> Void) -> Void = { _, done in done([]) }
        /// Loud surfacing (banner + Event History line at integration).
        var issueNotice: (_ title: String, _ body: String) -> Void
        /// PODLOAN instant-tile port (crude f3784d49/674e1b13): fired when pod
        /// OWNERSHIP flips (owner <-> not-owner) so the phone HUD re-renders the
        /// pump tile immediately instead of aging into signal-loss.
        var ownershipDidChange: () -> Void = {}
        /// True when the loaned pump's connection is truly back after a reclaim (post-hand-back).
        /// Default true so a pump lacking the capability never gets stuck in the settling tile.
        var isConnectionReady: () -> Bool = { true }
        var now: () -> Date = { Date() }
    }

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanPhoneController")
    private let queue = DispatchQueue(label: "com.loopkit.Loop.PodLoanPhoneController", qos: .utility)
    private var deps: Dependencies

    // MARK: - Loan → pump-event conversion (#69/#52)

    /// Wrap reconciled loan DoseEntries as NewPumpEvents for DoseStore.addPumpEvents.
    /// The identity must live in `raw` — NewPumpEvent.init overwrites dose.syncIdentifier
    /// with raw.hexadecimalString, so we encode the deterministic loan syncIdentifier
    /// (loanv2-<uuid> / loanv2-audit-<epoch>) there for idempotent, dedup-safe upserts.
    private func newPumpEvents(from doses: [DoseEntry]) -> [NewPumpEvent] {
        doses.compactMap { dose in
            guard let syncID = dose.syncIdentifier else { return nil }
            return NewPumpEvent(date: dose.startDate,
                                dose: dose,
                                raw: Data(syncID.utf8),
                                title: Self.pumpEventTitle(for: dose.type))
        }
    }

    private static func pumpEventTitle(for type: DoseType) -> String {
        switch type {
        case .bolus:     return "Bolus"
        case .tempBasal: return "Temp Basal"
        case .basal:     return "Basal"
        case .suspend:   return "Suspend"
        case .resume:    return "Resume"
        }
    }

    private(set) var state: State {
        didSet {
            UserDefaults.standard.set(state.rawValue, forKey: Keys.state)
            // Instant-tile: EVERY state change re-renders (the tile distinguishes
            // "Pod on Watch" from "Reclaiming…", so intermediate transitions are
            // user-visible — crude parity: it pushed every phase, and the 5s frozen
            // tile during hand-back read as ambiguity).
            if oldValue != state {
                deps.ownershipDidChange()
                // A reclaim just landed us in .owner, but reclaimConnection() only re-armed
                // the BLE bid — the pod isn't actually back for ~2 min. Open the settle window
                // so "Reclaiming…" (and the bolus gate) persist until the pod is truly reachable.
                if oldValue != .owner, state == .owner {
                    beginReclaimSettleWindow()
                }
            }
        }
    }

    // MARK: Reclaim settle window (post-hand-back "Reclaiming…" until the pod is truly back)

    /// Set when state enters .owner (a reclaim re-armed the BLE bid, but the pod isn't back
    /// yet). Drives `isReclaimSettling` so the tile persists until the pod is truly connected
    /// (deps.isConnectionReady) or the ceiling elapses. nil = not settling.
    private var reclaimStartedAt: Date?
    private var reclaimSettleWork: DispatchWorkItem?
    private static let reclaimSettleTimeout: TimeInterval = .minutes(5)

    /// reclaimConnection() only re-arms the BLE bid; the actual reconnect lands
    /// seconds-to-minutes later. Open a bounded window so the tile keeps showing "Reclaiming…"
    /// until the pod is genuinely reachable, without ever sticking (the ceiling clears it).
    /// Runs on `queue` (state is queue-confined, as the sync accessors below assume).
    private func beginReclaimSettleWindow() {
        let started = deps.now()
        reclaimStartedAt = started
        reclaimSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.reclaimStartedAt == started else { return }
            self.reclaimStartedAt = nil            // ceiling reached — stop settling
            self.deps.ownershipDidChange()         // final re-render that clears the tile
        }
        reclaimSettleWork = work
        queue.asyncAfter(deadline: .now() + Self.reclaimSettleTimeout, execute: work)
    }

    /// True whenever this phone does NOT own the pod's connection (any non-owner
    /// state — the link is released or in flux). Delivery attempts made here while
    /// true would die in a BLE timeout; callers should refuse loudly instead.
    var isPodLoanedOut: Bool {
        return queue.sync { state != .owner }
    }

    /// True while the pod is actively coming home (hand-back reconcile / reclaim in
    /// flight) — the pump tile shows "Reclaiming…" instead of "Pod on Watch".
    var isReclaimInProgress: Bool {
        return queue.sync { state == .reconciling || state == .reclaimPending }
    }

    /// True after state flips to .owner until the pod is truly back on the link
    /// (deps.isConnectionReady) or the settle ceiling elapses — bridging the ~2 min BLE
    /// re-establishment window after reclaimConnection() (which only re-arms the bid). Keeps
    /// "Reclaiming…" up until the pod is actually reachable, without sticking (ceiling) or
    /// misfiring on a later ordinary signal-loss (gated on a recent reclaimStartedAt).
    var isReclaimSettling: Bool {
        return queue.sync {
            guard state == .owner, let started = reclaimStartedAt else { return false }
            if deps.now().timeIntervalSince(started) >= Self.reclaimSettleTimeout { return false }
            return !deps.isConnectionReady()
        }
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
        case .grant, .handbackAck, .revoke, .statusQuery, .denied, .diag:
            break  // watch-bound kinds (diag is phone→watch only)
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

        // Fix 1 (#69, field-confirmed boundaryDup=YES): DO NOT emit a boundaryRecord.
        // The running temp is (near-always) already in `doseHistory` — getNormalizedDoseEntries
        // returns the open mutable temp, fetched below AFTER releaseConnection (which only
        // truncates the in-memory pod state via cancel(at:), never the dose store). A separate
        // same-start, same-rate boundaryRecord is therefore a duplicate of that temp, and seeding
        // both double-counts the [start→handover] slice (the ~0.3 U IOB bump at takeover). The
        // watch's stock reconciled() truncates the seeded open temp when it enacts its first
        // command. (Narrow caveat: if a just-set temp has not yet reached the dose store, the seed
        // could miss it for a few seconds — acceptably rarer than the double-seed it replaces.)
        // The .boundaryTruncation Kind + LoanReconciler's handling of it are LEFT in place as
        // defensive/back-compat tolerance ONLY: the watch hand-back journal never mints that kind,
        // so those arms are now vestigial in production (an older phone may still send one).
        let handedOverAt = deps.now()

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
        // #42 diagnosis: if the phone doesn't actually drop the pod BLE here, the watch's
        // takeover reads "pod unreachable" (a pod is a single-central peripheral). Relay the
        // release state to the watch's iCloud log — before, and a +3s confirm (release is async).
        let releaseEpoch = epoch + 1
        handbackDiag(releaseEpoch, "GRANT — releasing pod BLE (wasReleased=\(lendable.isConnectionReleased))")
        lendable.releaseConnection()
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak lendable] in
            guard let self = self, let lendable = lendable else { return }
            self.handbackDiag(releaseEpoch, "GRANT +3s — pod BLE released=\(lendable.isConnectionReleased)")
        }

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
        let historyStart = handedOverAt.addingTimeInterval(-.hours(16))
        // Fetch insulin AND carb history before building the grant (#49). Nested so both
        // are in hand at construction; the same 16h window that seeds IOB now seeds COB.
        // 3 h of glucose (the Integral RC look-back) seeds momentum + RC; the 16 h window seeds
        // IOB and COB. Nested so all three are in hand at construction.
        let glucoseStart = handedOverAt.addingTimeInterval(-.hours(3))
        deps.doseHistory(historyStart) { [weak self] history in
            guard let self = self else { return }
            self.deps.carbHistory(historyStart) { [weak self] carbs in
                guard let self = self else { return }
                self.deps.glucoseHistory(glucoseStart) { [weak self] glucose in
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
                            boundaryRecord: nil,   // Fix 1: running temp already lives in doseHistory (see above)
                            supportsInterimHandback: true,   // WS1 capability gate (REAL-3)
                            // Same source LoopDataManager:458 reads. Without this the watch runs
                            // Standard RC while this phone may be running Integral — different
                            // predictions from identical inputs, silently (audit 2026-07-22).
                            integralRetrospectiveCorrectionEnabled: UserDefaults.standard.integralRetrospectiveCorrectionEnabled,
                            carbHistory: carbs,
                            glucoseHistory: glucose)
                        self.sendMessage(.grant(grant))
                        self.armT1(for: grantEpoch)
                    }
                }
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

    /// #35: relay a phone-side hand-back breadcrumb to the watch (which mirrors to iCloud)
    /// AND os_log it, so the phone's offer→write→ack path is visible when the phone
    /// silently fails to ack. Purely diagnostic.
    private func handbackDiag(_ epoch: Int, _ text: String) {
        os_log("HANDBACK-DIAG e%d: %{public}@", log: log, type: .default, epoch, text)
        sendMessage(.diag(LoanDiag(epoch: epoch, text: text)))
    }

    private func handleHandbackOffer(_ offer: HandbackOffer) {
        // Stale epoch (rows 13/14): the records still drain — they are historical
        // truth, idempotent by ID — but loan STATE is untouched and the ack says
        // stale so the sender stops retrying. Dead loans cannot speak.
        let isStale = offer.epoch < epoch
        guard offer.epoch == epoch || isStale else { return }
        handbackDiag(offer.epoch, "offer RX ev=\(offer.events.count) released=\(offer.released.map { $0 ? "final" : "interim" } ?? "nil") stale=\(isStale) state=\(state.rawValue)")

        // WS1 (two-phase hand-back): an INTERIM offer (released == false) means the
        // watch is still dosing and still owns the pod — commit + ack ONLY; no state
        // change, no reclaim, tile stays "Pod on Watch". Legacy senders (released
        // nil) only offered after stopping, so nil = final.
        //
        // NO early re-ack shortcut (verify finding REAL-4): the staging path below is
        // idempotent by construction (committedIDs/cursor filters), and a blind re-ack
        // permanently stranded any event minted after the final-offer snapshot — the
        // watch could never drain it and held the pod forever. Every non-stale offer
        // now stages + commits unseen events; only the STATE transitions are gated.
        let isFinal = offer.released ?? true
        let canTransition = state == .loaned || state == .reclaimPending || state == .grantOffered
        if !isStale, isFinal, canTransition {
            state = .reconciling
        }
        // Round-2 fix: the odometer audit runs ONLY on the transition-owning final
        // offer. A duplicate final (routine: 15s resends vs ack latency) arrives
        // after finishLoanAfterCommit cleared `staged` — its re-staged tail is a
        // SUBSET of the loan, and auditing the whole-loan odometer against it mints
        // phantom remainders (the R1 bug, reintroduced via this path). Interim
        // offers carry freshened=false anyway; this makes the skip explicit.
        let auditThisOffer = !isStale && isFinal && state == .reconciling

        stage(events: offer.events, tombstones: offer.tombstones)
        // Round-4 fix: dedup by EVENT ID only. The seq>cursor condition assumed a
        // gapless cursor; WS1 withholding creates gaps (an in-flight command's seq
        // can arrive AFTER later events were acked), and it would silently discard
        // the late-classified event. committedIDs is persisted — the ID filter is
        // the true exactly-once invariant.
        let events = staged.values
            .filter { !stagedTombstones.contains($0.id) && !committedIDs.contains($0.id) }
            .sorted { $0.seq < $1.seq }
        // WS1: the odometer audit must see the WHOLE loan's journal, not the tail —
        // interim-committed temps/suspends are real recorded insulin, not schedule.
        let allStagedEvents = staged.values
            .filter { !stagedTombstones.contains($0.id) }
            .sorted { $0.seq < $1.seq }

        let loanStart = loanStartedAt ?? offer.handedBackAt.addingTimeInterval(-.hours(2))
        let input = LoanReconciler.Input(
            events: events,
            odometer: auditThisOffer ? offer.odometer : nil,
            auditEvents: allStagedEvents,
            schedule: deps.settings().basalRateSchedule,
            loanStart: loanStart,
            loanEnd: offer.handedBackAt,
            // Interim WS1 drain (watch still dosing): don't clamp a still-open temp to
            // this drain instant — that would orphan its post-drain delivery (#69).
            isFinalHandback: isFinal)
        let outcome = LoanReconciler.reconcile(input)

        // §5.3.3 audit inputs: the expected total over the WHOLE loan (all staged
        // events, not just this drain) and whether the watch's own audit ran.
        if auditThisOffer {
            let expected = LoanReconciler.expectedInsulin(events: allStagedEvents, schedule: deps.settings().basalRateSchedule,
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

        logReconciledDoses(doses, context: "drain-e\(offer.epoch)")

        // WS1: the still-open temp (outcome.openEventID) is skipped by the reconciler and
        // kept out of committedIDs, so it re-drains and is written (clamped, immutable) on
        // the final drain. But we STILL ack its seq (newCursor below uses `events`, not
        // `committable`) so the watch's finalize gate (unackedEvents empty) can clear —
        // decoupling the ack cursor from committedIDs is what avoids the finalize deadlock.
        let committable = events.filter { $0.id != outcome.openEventID }

        // Write-events-first; ack ONLY after commit (a897d22c). Failure: no ack, stay
        // reconciling, 1 h reminder repeats (row 11) — never dose on incomplete records.
        // Loan insulin goes through addPumpEvents (PumpEvent table + stock reconciled() +
        // HealthKit); lastReconciliation = handedBackAt (the finalized-through watermark).
        let writeStart = deps.now()
        handbackDiag(offer.epoch, "write START \(doses.count) dose(s) (final=\(isFinal))")
        deps.addPumpEvents(newPumpEvents(from: doses), offer.handedBackAt) { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    self.handbackDiag(offer.epoch, "write FAILED: \(String(describing: error))")
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
                    self.committedIDs.formUnion(committable.map(\.id))
                    self.persistCommittedIDs()
                    self.sendMessage(.handbackAck(HandbackAck(epoch: self.epoch, committedCursor: self.committedCursor)))
                    self.handbackDiag(self.epoch, String(format: "write DONE %.0fms → ACK cursor %d", self.deps.now().timeIntervalSince(writeStart) * 1000, self.committedCursor))
                    if isFinal, self.state == .reconciling {
                        // Only the transition-owning offer finishes; a duplicate final
                        // offer post-.owner just committed any unseen tail + re-acked.
                        self.finishLoanAfterCommit()
                    } else if !isFinal {
                        os_log("Interim drain committed to cursor %d — watch still dosing", log: self.log, type: .default, self.committedCursor)
                    }
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
                    let bolus = DoseEntry(type: .bolus, startDate: self.deps.now(), endDate: self.deps.now(),
                                          value: remainder, unit: .units,
                                          syncIdentifier: "loanv2-reaudit-\(self.epoch)")
                    self.deps.addPumpEvents(self.newPumpEvents(from: [bolus]), self.deps.now()) { _ in }
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
    /// Instrumentation (#69, 2026-07-25): itemize reconciled hand-back/reclaim doses so the
    /// loaded-IOB inflation is auditable without a forensic issue-report sum. Logs each dose's
    /// window (start→end→minutes), rate/value, IMPLIED delivery (rate×minutes for temps), an
    /// OVERLAP-NEXT flag when a temp's full window overruns the next dose's start (the
    /// over-count signal — LoanReconciler enters oversized records in full with no truncation,
    /// :107-109), plus the batch total. Compare this Σ against the watch's "stream implied Σ"
    /// and the post-reclaim IOB to localize where the ~5 U comes from.
    private func logReconciledDoses(_ doses: [DoseEntry], context: String) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let sorted = doses.sorted { $0.startDate < $1.startDate }
        var total = 0.0
        for (i, d) in sorted.enumerated() {
            let mins = d.endDate.timeIntervalSince(d.startDate) / 60
            let implied = d.programmedUnits   // public: rate×duration for temps, units for bolus
            total += implied
            let overlap = i + 1 < sorted.count && sorted[i + 1].startDate < d.endDate
            let magnitude = d.unit == .unitsPerHour ? d.unitsPerHour : d.programmedUnits
            let line = String(format: "HANDBACK[%@] %d/%d %@ %@→%@ %.0fm %.2f%@ ≈%.3fU%@",
                              context, i + 1, sorted.count, String(describing: d.type),
                              iso.string(from: d.startDate), iso.string(from: d.endDate),
                              mins, magnitude, d.unit == .unitsPerHour ? "U/hr" : "U", implied,
                              overlap ? " OVERLAP-NEXT" : "")
            os_log("%{public}@", log: log, type: .default, line)
        }
        os_log("%{public}@", log: log, type: .default,
               String(format: "HANDBACK[%@] SUMMARY: %d dose(s), implied Σ=%.2fU", context, sorted.count, total))
    }

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
            let outcome = LoanReconciler.reconcile(input)  // isFinalHandback defaults true → all finalized
            logReconciledDoses(outcome.doses, context: "reclaim")
            deps.addPumpEvents(newPumpEvents(from: outcome.doses), deps.now()) { _ in }
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
