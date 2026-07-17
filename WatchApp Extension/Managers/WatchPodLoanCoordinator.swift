//
//  WatchPodLoanCoordinator.swift
//  WatchApp Extension
//
//  The watch side of the pod loan. Asks the phone (Loop) to loan the pod over
//  WatchConnectivity, takes the pod over directly via OmniBLECore using the keys
//  the phone returns, drives suspend/resume/bolus/status while the phone is away,
//  and hands the pod back with a summary of what it did.
//
//  Pairs with WatchDataManager on the phone (PodLoanRequestUserInfo ->
//  PodLoanGrantUserInfo reply; PodHandbackUserInfo on hand back).
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import WatchConnectivity
import WatchKit
import HealthKit
import LoopKit
import OmniBLECore

@MainActor
final class WatchPodLoanCoordinator: ObservableObject {

    enum Phase: Equatable {
        case idle             // no loan
        case requesting       // asked the phone, awaiting grant + takeover
        case denied(String)   // phone declined the loan
        case armed            // hold the keys, pod not yet taken over (phone still owns it)
        case active           // holding the pod
        case handingBack      // sending the journal to the phone
        case done             // handed back
    }

    /// Posted when a dose lands in the loan journal (bolus/temp/suspend/cancel),
    /// so the prediction store and the auto-loop recompute — a dose changes IOB
    /// and the prediction, but is neither a glucose sample nor a 5-min tick.
    static let journalDidChangeNotification = Notification.Name("WatchPodLoanCoordinator.journalDidChange")

    private func notifyJournalChanged() {
        NotificationCenter.default.post(name: Self.journalDidChangeNotification, object: self)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status: PodControlStatus?
    @Published private(set) var busy = false
    @Published var lastError: String?

    /// DESIGN-6: the phone ended this loan via its escape-hatch reclaim (a
    /// revoke message, not a watch-initiated hand-back). The done screen says
    /// so instead of showing the normal hand-back checkmark.
    @Published private(set) var wasRevokedByPhone = false

    /// 3a: whether the watch currently holds a live BLE link to the pod. Flips to
    /// `false` only after a SUSTAINED loss (a quick auto-reconnect won't flash the
    /// HUD "signal lost" glyph). Drives that glyph; starts optimistically `true`.
    @Published private(set) var podConnected = true

    /// Monotonic counter so a stale debounced "still disconnected" check can tell
    /// it's been superseded by a newer link event and bail.
    private var linkGeneration = 0

    /// P0#5 — BOUNDED manual suspend. A manual suspend is enacted as a fixed-duration
    /// zero temp (not an untimed suspendDelivery) so the pod auto-reverts to its
    /// scheduled basal if the watch dies mid-suspend, instead of withholding insulin
    /// indefinitely. This is the watch-alive view of that bound: the instant it lapses.
    /// Cleared by resume(), a positive manual basal, or expiry. Drives the "Suspended"
    /// display and blocks the closed loop.
    @Published private(set) var manualSuspendUntil: Date?
    /// True while a bounded manual suspend is in force (and hasn't expired).
    var manualSuspendActive: Bool { (manualSuspendUntil.map { $0 > Date() }) ?? false }

    // MARK: - P1#8 pod-takeover timeout

    /// How long a pod takeover may run before the UI stops showing an open-ended
    /// spinner and offers Keep Trying / Cancel. ~one advertising window + margin;
    /// the armed BLE connect keeps running underneath, so this bounds the UX, not
    /// the radio.
    static let takeoverTimeout: TimeInterval = 40
    /// Bumped on every takeover start / user retry / cancel, so a late completion
    /// from a superseded attempt is ignored.
    private var takeoverGeneration = 0
    private var takeoverTimeoutWork: DispatchWorkItem?
    /// True once the in-flight takeover has run past `takeoverTimeout` without
    /// resolving — the view shows a "pod not responding" prompt instead of an
    /// indefinite spinner. Cleared when the takeover resolves or the user acts.
    @Published private(set) var takeoverStalled = false

    /// When the current keys arrived (handleGrantReply) — lets a queued revoke
    /// from an OLDER loan be recognized as stale and ignored for this one.
    private var armedAt: Date?

    /// When the current loan request was sent — staleness anchor for a revoke
    /// arriving in .requesting (before any grant/journal exists).
    private var lastRequestAt: Date?

    /// When the last revoke was accepted — a grant reply for a request made
    /// BEFORE this must be dropped, or the revoked loan resurrects when the
    /// (delayed) reply lands after the revoke.
    private var lastRevokeAt: Date?

    /// A revoke that arrived while a pod command was in flight (busy). Processing
    /// it immediately would abandon the journal BEFORE the command's completion
    /// records what the pod may have already delivered — a bolus lost from all
    /// records. Instead it parks here and is processed the moment busy drops.
    private var pendingRevokeAt: Date?

    /// Run a parked revoke once the in-flight command has completed (and
    /// journaled). Call wherever busy transitions to false.
    private func processPendingRevoke() {
        guard let revokedAt = pendingRevokeAt else { return }
        pendingRevokeAt = nil
        handleLoanRevoked(revokedAt: revokedAt)
    }

    /// Live summary of what the watch has done during the loan (for display).
    var liveSummary: String? {
        #if targetEnvironment(simulator)
        if Self.isSimulatorDemo, phase == .done { return "Delivered 1.5 U · Suspended 12m" }
        #endif
        return controller.loanJournalSummary(schedule: loanBasalSchedule)
    }

    /// Whether the phone can currently be reached to hand the pod back. Hand-back needs
    /// this (WatchConnectivity to send the loan journal, and the phone's Bluetooth on to
    /// reclaim the pod over BLE). Since Sport Mode is entered with the phone's BT OFF, this
    /// is often false when the user tries to end — the UI checks it to warn rather than
    /// silently no-op. Always true in the sim demo so the demo end-flow still runs.
    var phoneReachable: Bool {
        if Self.isSimulatorDemo { return true }
        return WCSession.default.isReachable
    }

    // MARK: - Session basal state (for the status page)

    /// The basal rate the watch has set this session (U/hr), or nil when the pod is on
    /// its scheduled basal (nothing set, or a resume since). Journal-backed on hardware;
    /// demo-mirrored on the sim. Display-only.
    var sessionBasalRate: Double? {
        if Self.isSimulatorDemo { return demoBasalRate }
        guard let events = controller.loanJournal?.events else { return nil }
        for event in events.reversed() {
            switch event.kind {
            case .tempBasal(let rate, _): return rate
            case .resume, .suspend, .cancelTempBasal: return nil   // scheduled / suspended (see sessionSuspended)
            default: continue
            }
        }
        return nil
    }

    /// The scheduled basal rate (U/hr) in force right now, if the schedule has
    /// reached the watch — lets the UI say "Scheduled (0.60 U/hr)" honestly.
    var currentScheduledRate: Double? {
        loanBasalSchedule?.rate(at: Date())
    }

    /// Whether the watch's last delivery change this session was a suspend. Unlike the
    /// journal's own isSuspended, a later temp basal counts as un-suspending (the pod
    /// resumes delivery at the programmed rate).
    var sessionSuspended: Bool {
        if Self.isSimulatorDemo { return status?.deliveryStatus == "Suspended" }
        // A manual suspend is now a bounded zero temp (P0#5), so the journal no longer
        // carries a `.suspend` kind for it — the manualSuspendUntil bound is the truth.
        // (A loop-issued zero temp is NOT a manual suspend and must not read as one.)
        return manualSuspendActive
    }

    /// Total insulin bolused by the watch this session (U) — the journal's discrete
    /// bolus records, the same accounting the hand-back summary reports. 0 if none.
    var sessionBolusUnits: Double {
        if Self.isSimulatorDemo { return demoBolusTotal }
        return controller.loanJournal?.totalBolusUnits ?? 0
    }

    /// The phone's basal schedule, if it has arrived via LoopSettingsUserInfo
    /// (older phones don't send it — see LoopSettings.rawValue). Bridged to the
    /// Foundation-only type the insulin math in OmniBLECore consumes. In the
    /// simulator demo, a flat placeholder schedule so the session-basal math is
    /// exercisable without a paired phone.
    private var loanBasalSchedule: PodLoanBasalSchedule? {
        if let schedule = ExtensionDelegate.shared().loopManager.settings.basalRateSchedule {
            return PodLoanBasalSchedule(
                items: schedule.items.map { .init(startOffset: $0.startTime, rate: $0.value) },
                timeZoneSecondsFromGMT: schedule.timeZone.secondsFromGMT()
            )
        }
        if Self.isSimulatorDemo {
            return PodLoanBasalSchedule(items: [.init(startOffset: 0, rate: 0.5)], timeZoneSecondsFromGMT: 0)
        }
        return nil
    }

    /// RAW net basal insulin DELIVERED this session (U), above (+) or below (−)
    /// the scheduled basal — the undecayed cumulative amount ("Session Basal").
    /// nil when the schedule hasn't reached the watch (can't be computed).
    var sessionBasalDelivered: Double? {
        guard let schedule = loanBasalSchedule else { return nil }
        let journal = Self.isSimulatorDemo ? demoJournal : controller.loanJournal
        return journal?.netBasalDelivered(until: Date(), schedule: schedule)
    }

    /// Total net insulin this session (U) = session boluses + session basal
    /// deviation ("Session Insulin"). nil when session basal is uncomputable.
    var sessionInsulinTotal: Double? {
        guard let basal = sessionBasalDelivered else { return nil }
        return sessionBolusUnits + basal
    }

    /// Decayed net IOB (bolus decay + basal deviation vs schedule) — for the
    /// dark predict() path only; NOT shown (the status page shows the raw
    /// session numbers above). The demo journal makes it behave identically on
    /// the simulator.
    var sessionIOB: Double {
        let journal = Self.isSimulatorDemo ? demoJournal : controller.loanJournal
        return journal?.iob(at: Date(), schedule: loanBasalSchedule, model: loanInsulinModel) ?? 0
    }

    /// Insulin activity curve for this loan, chosen from the grant's insulin type
    /// (rapid-acting-adult fallback — the slower curve, so the fallback errs
    /// toward showing MORE remaining insulin).
    private(set) var loanInsulinModel: PodLoanInsulinModel = .rapidActingAdult

    // MARK: - Prediction engine inputs

    /// The loan-session journal (live, or the sim-demo mirror), for the
    /// prediction engine's dose bridge.
    var journalForPrediction: PodLoanJournal? {
        Self.isSimulatorDemo ? demoJournal : controller.loanJournal
    }

    /// Pre-loan dose history shipped in the grant (nil: older phone, failed
    /// fetch, or no live loan) — PodLoanDoseHistory-encoded.
    var grantDoseHistoryData: Data? { heldGrant?.doseHistoryData }

    /// Dose history the prediction engine pulled from the phone when the grant
    /// carried none (sim demo; absent grant payload). Session-lifetime — kept
    /// while the loan lives so re-opening the prediction screen with the phone
    /// away doesn't lose it; cleared when a new loan starts.
    var pulledDoseHistoryData: Data?

    /// The grant's insulin type as LoopKit's InsulinType.rawValue, for tagging
    /// bridged doses with the right activity curve.
    var grantInsulinTypeRaw: Int? { heldGrant?.insulinTypeRaw }

    /// A pod command that failed DURING Sport Mode, for loud surfacing (haptic +
    /// alert on the HUD). Distinct from lastError (quiet, shown on the pod screen):
    /// a mid-session failure — especially a bolus — must never be silent (BUG-5).
    struct CommandFailure: Equatable {
        let title: String
        let message: String
    }
    @Published private(set) var commandFailure: CommandFailure?

    func clearCommandFailure() {
        commandFailure = nil
    }

    /// P1#10 — surfaced once when the app relaunches to find an orphaned loan
    /// journal (Sport Mode ended WITHOUT a normal hand-back: the app was killed
    /// mid-session). Presented by the HUD like a command failure so the silent
    /// transition to open-loop isn't spooky.
    @Published private(set) var sessionEndedNotice: CommandFailure?
    func clearSessionEndedNotice() { sessionEndedNotice = nil }
    /// Announce the uncommanded end at most once per app launch.
    private var announcedRecoveredSession = false

    /// Sim-demo mirrors of session state (the demo has no controller journal;
    /// demoJournal lets demo IOB decay exactly like hardware IOB).
    private var demoBasalRate: Double?
    private var demoBolusTotal: Double = 0
    private var demoJournal: PodLoanJournal?

    /// Ceiling on any single bolus from the watch = the wearer's THERAPY max-bolus
    /// setting (settings.maximumBolus) — the exact bound Loop-on-the-phone uses. Mirrors
    /// `maxTempBasalRate`: the manual dial, the Sport Mode meal-bolus reco, AND the pod
    /// command clamp all respect the real therapy limit (no bench 1.0, no revert chore,
    /// and the display never disagrees with what the pod will accept — the pod-facade
    /// proof limit is set to this too, see `applyControllerPrefs`). Falls back to a
    /// conservative value only until settings sync.
    nonisolated static var maxBolusUnits: Double {
        ExtensionDelegate.shared().loopManager.settings.maximumBolus ?? fallbackMaxBolusUnits
    }
    /// Conservative ceiling used only until the therapy max-bolus setting has synced.
    static let fallbackMaxBolusUnits: Double = 1.0
    /// The amount the bolus dial starts at.
    static let defaultBolusUnits: Double = 0.5

    /// The watch temp-basal ceiling (U/hr) = the wearer's THERAPY max-basal setting —
    /// the exact bound the Loop algorithm itself uses. Deriving it here (rather than a
    /// magic 3.0 TEMP-TEST-CAP) means the manual dial and the closed-loop clamp respect
    /// the real limit, there's no revert-to-1.0 chore, and the display never disagrees
    /// with what the pod will accept (the proof limit is set to this too — see
    /// `applyTempCapToController`). Falls back only until settings sync (the closed loop
    /// can't run before then anyway; the manual dial gets a conservative default).
    nonisolated var maxTempBasalRate: Double {
        ExtensionDelegate.shared().loopManager.settings.maximumBasalRatePerHour ?? Self.fallbackMaxTempBasalRate
    }
    /// Conservative ceiling used only until the therapy max-basal setting has synced.
    static let fallbackMaxTempBasalRate: Double = 3.0

    /// The phone's beep preference, carried in the loan grant (see PodLoanIdentity):
    /// whether the pod should beep for MANUAL commands (user bolus/basal/suspend on
    /// the watch) and AUTOMATIC commands (the closed loop's temps). Default SILENT
    /// until a grant lands (or for an older phone that doesn't send it).
    private var loanBeepsManual = false
    private var loanBeepsAutomatic = false

    /// Program the pod-layer prefs that depend on the session/grant before a command:
    /// the temp-rate proof cap (therapy max) and whether THIS command beeps — manual
    /// vs the closed loop's automatic, per the phone's setting. Follows the phone so
    /// the watch has no independent code-only beep switch.
    private func applyControllerPrefs(automatic: Bool) {
        controller.tempBasalRateProofLimit = maxTempBasalRate
        controller.bolusProofLimit = Self.maxBolusUnits
        controller.commandBeepsEnabled = automatic ? loanBeepsAutomatic : loanBeepsManual
        // C1: the max-exposure rules for UNCERTAIN outcomes compare command rates
        // against the wearer's schedule; nil (not yet synced) falls back to
        // journal-local heuristics.
        controller.currentScheduledBasalRate = loanBasalSchedule?.rate(at: Date())
    }
    /// The rate the basal dial starts at.
    static let defaultBasalRate: Double = 0.5
    /// Fixed duration for every watch temp basal. From the user's view it's just
    /// "set the basal" (no duration UI); it's long enough to cover a competition,
    /// and the pod auto-reverts to the scheduled basal when it expires — a safety
    /// backstop if the watch dies. The phone reasserts its own basal on hand-back.
    static let tempBasalDuration: TimeInterval = 3 * 60 * 60   // 3 hours

    /// True only in the watchOS simulator (which has no Bluetooth, so it can never
    /// reach a pod). When true, the methods below route to the simulator demo path
    /// (see the extension at the bottom) instead of WatchConnectivity/BLE, so the
    /// whole Sport Mode flow is walkable on the sim. Compile-time FALSE on a real
    /// watch — the demo path can never execute on hardware.
    #if targetEnvironment(simulator)
    static let isSimulatorDemo = true
    #else
    static let isSimulatorDemo = false
    #endif

    private let controller = PodController()

    /// Keys the phone granted, retained in memory so the pod can be claimed after
    /// the phone goes away (which frees the pod's BLE connection). Cleared on
    /// hand-back. In-memory only — survives suspension, lost on app termination.
    private var heldGrant: PodLoanGrantUserInfo?

    init() {
        // 3a: reflect the pod's BLE link into `podConnected` so the HUD can show a
        // "signal lost" glyph while the watch still holds the loan. The callback is
        // delivered on the main queue by PodController.
        controller.onConnectionChanged = { [weak self] connected in
            Task { @MainActor in self?.handleLinkChange(connected) }
        }
    }

    /// Debounce BLE link changes into `podConnected`. A reconnect is reflected
    /// immediately; a disconnect only "sticks" if it persists ~3s, so the brief
    /// drop-and-reconnect that CoreBluetooth does routinely won't flash the glyph.
    private func handleLinkChange(_ connected: Bool) {
        linkGeneration &+= 1
        let generation = linkGeneration
        if connected {
            podConnected = true
        } else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // Bail if a newer link event superseded this one in the meantime.
                guard self.linkGeneration == generation else { return }
                self.podConnected = false
            }
        }
    }

    // MARK: - Loan lifecycle

    /// Ask the phone to loan us the pod, then take it over with the returned keys.
    func requestLoan() {
        pulledDoseHistoryData = nil   // stale pre-loan history must not leak into a new loan
        if Self.isSimulatorDemo { demoStart(); return }
        guard !busy else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            lastError = "iPhone not reachable — bring it close to start Sport Mode."
            return
        }
        // An undelivered journal from a previous session (crash or revoke) gets
        // a delivery attempt while the phone is provably reachable — BEFORE the
        // new takeover displaces it into the orphan slot.
        attemptRecoveredJournalHandback()

        busy = true
        phase = .requesting
        lastError = nil
        wasRevokedByPhone = false
        lastRequestAt = Date()
        // Start optimistic; bump the generation so any debounce still pending from a
        // previous session's teardown can't fire and flash the glyph on this loan.
        podConnected = true
        linkGeneration &+= 1

        let request = PodLoanRequestUserInfo(requestedAt: Date())
        session.sendMessage(request.rawValue, replyHandler: { [weak self] reply in
            Task { @MainActor in self?.handleGrantReply(reply) }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.busy = false
                self?.phase = .idle
                self?.lastError = "Couldn't start Sport Mode: \(error.localizedDescription)"
            }
        })
    }

    private func handleGrantReply(_ reply: [String: Any]) {
        // DESIGN-6 resurrection guards: a grant reply is only meaningful while
        // we are still asking. If a revoke was accepted after this request went
        // out (phase left .requesting), or anything else moved the phase, the
        // grant is void — dropping it keeps the phone the single writer.
        guard phase == .requesting else { return }
        if let revokedAt = lastRevokeAt, let requestedAt = lastRequestAt, revokedAt >= requestedAt {
            busy = false
            phase = .done
            return
        }
        guard let grant = PodLoanGrantUserInfo(rawValue: reply) else {
            busy = false
            phase = .idle
            lastError = "Unexpected reply from iPhone."
            return
        }
        guard grant.granted,
              grant.ltk != nil,
              grant.controllerId != nil,
              grant.podId != nil,
              grant.podAddress != nil,
              grant.messageNumber != nil
        else {
            busy = false
            phase = .denied(grant.denialReason ?? "iPhone couldn't start Sport Mode.")
            return
        }

        // Formal handoff: the phone RELEASED the pod's BLE connection before
        // replying to this grant, so the slot is already free — take over
        // immediately, no user step between keys-arrived and takeover. `.armed`
        // survives only as the retry surface: a failed takeover drops back to
        // it (keys retained) with an Enable button.
        heldGrant = grant
        loanInsulinModel = PodLoanInsulinModel.forInsulinTypeRaw(grant.insulinTypeRaw)
        // Adopt the phone's beep preference for this loan (default silent if absent).
        loanBeepsManual = grant.beepsForManual ?? false
        loanBeepsAutomatic = grant.beepsForAutomatic ?? false
        armedAt = Date()
        busy = false
        phase = .armed
        lastError = nil
        takeOver(using: grant)
    }

    /// DESIGN-6: the phone reclaimed the pod via its escape hatch and queued a
    /// revoke. The pod is NOT ours anymore — single-writer says let go NOW, no
    /// pod commands (no leftover-temp cancel, no status freshen; those are the
    /// phone's problem after a reclaim). The journal is kept persisted and
    /// handed back through the recovered-journal path, which the phone
    /// reconciles idempotently. Ignorable and idempotent by design: revokes
    /// for finished loans and stale revokes for older loans do nothing.
    func handleLoanRevoked(revokedAt: Date) {
        guard !Self.isSimulatorDemo else { return }
        switch phase {
        case .idle, .done, .denied:
            return   // no live loan — nothing to revoke
        case .requesting:
            // No grant or journal yet — the staleness anchor is the request
            // itself. A request made AFTER the revoke is a new loan this revoke
            // doesn't apply to. (Clocks are same-account NTP-synced; loans are
            // minutes apart, skew is seconds — same reasoning throughout.)
            if let requestedAt = lastRequestAt, requestedAt > revokedAt { return }
            lastRevokeAt = revokedAt   // the in-flight grant reply must be dropped
            // Kill any controller machinery a racing grant may have spun up —
            // a zombie auto-connect bid would fight the phone for the pod.
            controller.abandonLoanAsRevoked()
            heldGrant = nil
            armedAt = nil
            pendingHandbackPayload = nil
            busy = false
            wasRevokedByPhone = true
            phase = .done
        case .armed:
            if let armedAt, armedAt > revokedAt { return }
            lastRevokeAt = revokedAt
            // The auto-takeover may be mid-flight: podComms is scanning with a
            // standing connect bid and pendingTakeover armed. Abandon NOW so
            // the watch stops contending with the reclaiming phone; the takeover
            // completion (if it fires) hits the wasRevokedByPhone guard and
            // re-abandons idempotently.
            controller.abandonLoanAsRevoked()
            heldGrant = nil
            armedAt = nil
            pendingHandbackPayload = nil
            busy = false
            wasRevokedByPhone = true
            phase = .done
        case .active, .handingBack:
            // Anchor staleness on the GRANT time when we have it: a genuine
            // revoke issued in the grant→takeover window would look "stale"
            // against journal.startedAt (stamped at takeover completion) and be
            // wrongly ignored. journal.startedAt is the fallback anchor only.
            let loanAnchor = armedAt ?? controller.loanJournal?.startedAt
            if let loanAnchor, loanAnchor > revokedAt { return }
            // In-flight pod command (or hand-back chain): park the revoke until
            // the command completes AND journals — abandoning now would lose a
            // dose the pod may have already delivered.
            guard !busy else {
                pendingRevokeAt = revokedAt
                return
            }
            lastRevokeAt = revokedAt
            wasRevokedByPhone = true
            // Uniform for .handingBack too: abandoning records NO new journal
            // event, so the persisted bytes equal any hand-back snapshot already
            // in flight — whichever delivery lands first wins and the other is
            // dropped by the phone's byte-hash duplicate guard.
            controller.abandonLoanAsRevoked()
            heldGrant = nil
            armedAt = nil
            pendingHandbackPayload = nil
            lastError = nil
            phase = .done
            // Best-effort immediate send; if the phone isn't reachable right
            // now, the persisted journal is retried on reachability changes and
            // future activations.
            attemptRecoveredJournalHandback()
        }
    }

    /// Take the pod over using keys the phone already granted — no phone contact
    /// required. Use after the iPhone is powered off (or its Bluetooth turned off),
    /// which frees the pod's BLE connection for the watch.
    func claim() {
        if Self.isSimulatorDemo { demoClaim(); return }
        guard !busy, phase == .armed, let grant = heldGrant else { return }
        lastError = nil
        takeOver(using: grant)
    }

    /// Drop the retained keys and return to idle (user abandoned an armed loan).
    func cancelArmed() {
        guard phase == .armed, !busy else { return }
        heldGrant = nil
        phase = .idle
        lastError = nil
    }

    /// Return to idle after a completed hand-back so a new loan can be started
    /// without force-quitting the app. (BUG-1)
    func reset() {
        guard !busy else { return }
        heldGrant = nil
        status = nil
        lastError = nil
        wasRevokedByPhone = false
        armedAt = nil
        pendingRevokeAt = nil
        phase = .idle
    }

    /// Take the pod over from a granted key set. Succeeds when the pod's BLE slot
    /// is free (phone off / not currently connected). If the phone still holds the
    /// pod, this fails and we drop to `.armed` — keeping the keys — so the user can
    /// power the phone off and Claim.
    private func takeOver(using grant: PodLoanGrantUserInfo) {
        guard let ltk = grant.ltk,
              let controllerId = grant.controllerId,
              let podId = grant.podId,
              let podAddress = grant.podAddress,
              let messageNumber = grant.messageNumber
        else {
            busy = false
            phase = .idle
            lastError = "Pod keys were incomplete."
            return
        }

        busy = true
        takeoverStalled = false
        takeoverGeneration &+= 1
        let gen = takeoverGeneration
        scheduleTakeoverTimeout(generation: gen)
        controller.takeOverExternalPod(ltk: ltk,
                                       controllerId: controllerId,
                                       podId: podId,
                                       podAddress: podAddress,
                                       messageNumber: messageNumber) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                // P1#8 — ignore a completion from an attempt the user already
                // superseded (Keep Trying / Cancel bumps the generation).
                guard gen == self.takeoverGeneration else { return }
                self.cancelTakeoverTimeout()
                self.takeoverStalled = false
                self.busy = false
                // DESIGN-6 resurrection guard: a revoke landed while this
                // takeover was in flight. The pod is the phone's again — let go
                // of whatever the takeover established and stay on the revoked
                // done screen (the trivial journal is preserved for recovery).
                if self.wasRevokedByPhone {
                    self.controller.abandonLoanAsRevoked()
                    return
                }
                switch result {
                case .success(let status):
                    self.status = status
                    self.phase = .active
                    self.lastError = nil
                case .failure:
                    // We still hold the keys — the pod is just unreachable, almost
                    // always because the phone still owns the connection. Stay armed
                    // so the user can power the phone off and Claim again.
                    self.phase = .armed
                    self.lastError = "Couldn't reach the pod. Make sure your iPhone's Bluetooth is off, then try again."
                }
            }
        }
    }

    // MARK: - P1#8 takeover-timeout plumbing

    private func scheduleTakeoverTimeout(generation gen: Int) {
        cancelTakeoverTimeout()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, gen == self.takeoverGeneration, self.busy else { return }
                fileLog("P1#8: pod takeover stalled past \(Int(Self.takeoverTimeout))s — prompting user")
                self.takeoverStalled = true
            }
        }
        takeoverTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.takeoverTimeout, execute: work)
    }

    private func cancelTakeoverTimeout() {
        takeoverTimeoutWork?.cancel()
        takeoverTimeoutWork = nil
    }

    /// P1#8 — user chose "Keep Trying" on the stall prompt. Supersede the stalled
    /// attempt, tear down its BLE machinery, and start a fresh takeover with the
    /// retained keys (releasePod first so the retry doesn't contend with a zombie
    /// connect bid from the old attempt).
    func retryStalledTakeover() {
        guard phase == .armed, let grant = heldGrant else { return }
        fileLog("P1#8: user chose Keep Trying — restarting takeover")
        takeoverGeneration &+= 1        // orphan the stalled attempt's completion
        cancelTakeoverTimeout()
        controller.releasePod()         // tear down the current connect machinery
        takeoverStalled = false
        busy = false
        lastError = nil
        takeOver(using: grant)
    }

    /// P1#8 — user chose "Cancel" on the stall prompt. Stop trying but keep the
    /// keys so they can retry after checking the phone's Bluetooth.
    func cancelStalledTakeover() {
        fileLog("P1#8: user canceled a stalled takeover")
        takeoverGeneration &+= 1
        cancelTakeoverTimeout()
        controller.releasePod()
        takeoverStalled = false
        busy = false
        phase = .armed
        lastError = "Pod takeover canceled. Make sure your iPhone's Bluetooth is off, then try again."
    }

    // MARK: - Pod control (only while the loan is active)

    func suspend() {
        // P0#5 — BOUNDED manual suspend: a fixed-duration zero temp, NOT an untimed
        // suspendDelivery. If the watch dies mid-suspend the pod auto-reverts to its
        // scheduled basal at expiry rather than withholding insulin indefinitely (an
        // untimed suspend has no pod-side revert net). Same mechanism the closed loop
        // uses for a predicted-low zero temp; blocks the loop via manualSuspendActive.
        // C4: the suspended note follows the command outcome — applied only if
        // the command was accepted (optimistic while in flight, like the dose
        // screens), rolled back on a definitive refusal. A busy-drop changes
        // nothing and alerts "try again".
        let until = Date().addingTimeInterval(Self.tempBasalDuration)
        if Self.isSimulatorDemo { manualSuspendUntil = until; demoSuspend(); return }
        applyControllerPrefs(automatic: false)
        let prior = manualSuspendUntil
        let accepted = runPodCommand(label: NSLocalizedString("Suspend", comment: "Command name: suspend"),
                                     onCertainFailure: { [weak self] in self?.manualSuspendUntil = prior }) {
            self.controller.setTempBasal(rate: 0, duration: Self.tempBasalDuration, completion: $0)
        }
        if accepted { manualSuspendUntil = until }
    }
    func resume() {
        if Self.isSimulatorDemo { manualSuspendUntil = nil; demoResume(); return }
        applyControllerPrefs(automatic: false)
        let prior = manualSuspendUntil

        if status?.suspended == true, !manualSuspendActive {
            // TRUE pod suspend (a pre-loan edge — Sport Mode itself never issues
            // one): resuming RE-PROGRAMS the pod's stored basal table, which
            // outlives the loan, so it requires the wearer's REAL schedule. No
            // schedule, no command — never a fabricated table (C9).
            guard let schedule = realBasalSchedule else {
                WKInterfaceDevice.current().play(.failure)
                lastError = NSLocalizedString("Basal schedule hasn't synced from iPhone.", comment: "Status line: resume refused, no synced basal schedule")
                commandFailure = CommandFailure(
                    title: NSLocalizedString("Can't Resume", comment: "Alert title: resume refused without a synced basal schedule"),
                    message: NSLocalizedString("The watch doesn't have your basal schedule yet, and resuming would program the pod with made-up rates. Resume from the iPhone, or bring it in range and try again.", comment: "Alert body: resume refused without a synced basal schedule"))
                return
            }
            // Program in the schedule's own timezone (captured at grant), not
            // the watch's current zone.
            let tz = loanBasalSchedule.flatMap { TimeZone(secondsFromGMT: $0.timeZoneSecondsFromGMT) } ?? .current
            let accepted = runPodCommand(label: NSLocalizedString("Resume", comment: "Command name: resume"),
                                         onCertainFailure: { [weak self] in self?.manualSuspendUntil = prior }) { self.controller.resume(schedule: schedule, timeZone: tz, completion: $0) }
            if accepted { manualSuspendUntil = nil }
            return
        }

        // Bounded zero-temp suspend (the only suspend Sport Mode creates):
        // cancel the temp — the pod reverts to its own STORED true schedule.
        // No reprogramming, no schedule needed, works with zero settings sync (C9).
        let accepted = runPodCommand(label: NSLocalizedString("Resume", comment: "Command name: resume"),
                                     onCertainFailure: { [weak self] in self?.manualSuspendUntil = prior }) { self.controller.cancelTempBasal(completion: $0) }
        if accepted { manualSuspendUntil = nil }   // resuming clears the bounded manual suspend
    }

    /// The phone's basal schedule as the pod-programmable OmniBLECore type,
    /// if it has reached the watch via settings sync.
    private var realBasalSchedule: BasalSchedule? {
        guard let schedule = ExtensionDelegate.shared().loopManager.settings.basalRateSchedule,
              !schedule.items.isEmpty else {
            return nil
        }
        return BasalSchedule(entries: schedule.items.map {
            BasalScheduleEntry(rate: $0.value, startTime: $0.startTime)
        })
    }
    func bolus(units: Double) {
        let capped = min(max(units, 0), Self.maxBolusUnits)
        guard capped > 0 else { return }
        if Self.isSimulatorDemo { demoBolus(units: capped); return }
        applyControllerPrefs(automatic: false)
        runPodCommand(label: String(format: NSLocalizedString("Bolus %.2f U", comment: "Command name: bolus with units"), capped)) { self.controller.bolus(units: capped, completion: $0) }
    }
    /// Set the pod's basal to an absolute rate (U/hr). 0 = suspend. Capped at
    /// maxTempBasalRate; snapped to the pod's 0.05 U/hr resolution. Implemented as a
    /// fixed-duration temp basal (see tempBasalDuration) that auto-reverts.
    func setBasalRate(_ rate: Double) {
        let snapped = (min(max(rate, 0), maxTempBasalRate) / 0.05).rounded() * 0.05
        if snapped <= 0 { suspend(); return }   // 0 U/hr = suspend
        if Self.isSimulatorDemo { manualSuspendUntil = nil; demoSetTempBasal(rate: snapped); return }
        applyControllerPrefs(automatic: false)
        let prior = manualSuspendUntil
        let accepted = runPodCommand(label: NSLocalizedString("Set Basal", comment: "Command name: set basal"),
                                     onCertainFailure: { [weak self] in self?.manualSuspendUntil = prior }) { self.controller.setTempBasal(rate: snapped, duration: Self.tempBasalDuration, completion: $0) }
        if accepted { manualSuspendUntil = nil }   // a positive manual basal clears any bounded suspend
    }
    /// Log a carb the user ate during Sport Mode. NOT a pod command (no BLE): it
    /// stores the entry in the watch's LOCAL carb store — so the watch prediction and
    /// closed loop dose for the resulting COB via temp basal — and records it in the
    /// loan journal's `carbs` list so the phone reconciles it into its own carb store /
    /// Nightscout on hand-back (otherwise a watch-logged meal would be silently lost).
    func logCarb(_ entry: NewCarbEntry) {
        let grams = entry.quantity.doubleValue(for: .gram())
        guard grams > 0 else { return }
        ExtensionDelegate.shared().loopManager.carbStore.addCarbEntry(entry) { [weak self] _ in
            // Recompute AFTER the store write lands, so the fetched carb history includes it.
            Task { @MainActor in self?.notifyJournalChanged() }
        }
        controller.recordLoanCarb(grams: grams, absorptionTime: entry.absorptionTime ?? .hours(3), at: entry.startDate)
        fileLog(String(format: "Sport Mode carb logged: %.0f g", grams))
    }

    /// Cancel the running temp basal; the pod reverts to its scheduled basal.
    /// `loudDrop: false` when the closed loop is the caller (it retries itself).
    func cancelBasal(loudDrop: Bool = true) {
        if Self.isSimulatorDemo { demoCancelTempBasal(); return }
        applyControllerPrefs(automatic: false)
        runPodCommand(label: NSLocalizedString("Cancel Temp", comment: "Command name: cancel temp basal"), loudDrop: loudDrop) { self.controller.cancelTempBasal(completion: $0) }
    }

    /// Loop-faithful temp-basal enactment for the closed loop, mirroring
    /// PumpManager.enactTempBasal(unitsPerHour:for:) — the DURATION is a
    /// parameter (the recommendation's own, ~30 min), not the manual path's
    /// fixed 3h hold. Following DoseEnactor + the pump interface: duration 0
    /// cancels the running temp (revert to schedule); rate 0 with a duration is
    /// a bounded zero temp that auto-reverts (Loop's "suspend"). Goes through
    /// runPodCommand, so it gets the same journal recording, proof caps, and
    /// loud-failure surfacing as manual control. The manual setBasalRate (3h,
    /// 0→indefinite suspend) is deliberately left as-is for rider hold.
    func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval) {
        guard duration > 0 else {
            cancelBasal(loudDrop: false)   // .cancel → revert to schedule
            return
        }
        let snapped = (min(max(unitsPerHour, 0), maxTempBasalRate) / 0.05).rounded() * 0.05
        if Self.isSimulatorDemo { demoSetTempBasal(rate: snapped, duration: duration); return }
        applyControllerPrefs(automatic: true)   // closed-loop enact → beeps follow the phone's AUTOMATIC pref
        runPodCommand(label: String(format: NSLocalizedString("Loop %.2f U/hr", comment: "Command name: loop-set temp basal"), snapped), loudDrop: false) {
            self.controller.setTempBasal(rate: snapped, duration: duration, completion: $0)
        }
    }
    func refreshStatus() {
        if Self.isSimulatorDemo { return }
        runPodCommand(label: NSLocalizedString("Status", comment: "Command name: status refresh"), loudDrop: false) { self.controller.getStatus(completion: $0) }
    }

    /// Returns whether the command was accepted (false = dropped by the
    /// busy/phase guard, nothing sent). C4: manual callers use this to make
    /// state transactional — apply optimistic state only when accepted, and
    /// pass `onCertainFailure` to roll it back when the pod definitively
    /// refuses (UNCERTAIN outcomes keep the optimistic state; the
    /// may-have-applied alert fires). `loudDrop` surfaces a busy-drop with
    /// haptic + alert — true for manual commands, false for the loop's own
    /// enacts and status refreshes, which retry on their own cadence.
    @discardableResult
    private func runPodCommand(label: String, loudDrop: Bool = true, onCertainFailure: (() -> Void)? = nil, _ operation: (@escaping (Result<PodControlStatus, Error>) -> Void) -> Void) -> Bool {
        guard !busy, phase == .active else {
            fileLog("pod cmd '\(label)' DROPPED (busy=\(busy) phase=\(phase))")   // surfaced: the silent skip
            if loudDrop, phase == .active {
                WKInterfaceDevice.current().play(.retry)
                lastError = NSLocalizedString("Pod is busy — not sent.", comment: "Status line when a Sport Mode pod command is dropped because another is in progress")
                commandFailure = CommandFailure(
                    title: String(format: NSLocalizedString("%@ Not Sent", comment: "Alert title for a Sport Mode pod command dropped while the pod is busy (parameter: command name)"), label),
                    message: NSLocalizedString("The pod is busy with another command. Nothing was sent — try again in a moment.", comment: "Alert body for a Sport Mode pod command dropped while the pod is busy"))
            }
            return false
        }
        fileLog("pod cmd '\(label)' →")
        busy = true
        lastError = nil
        // Any new command makes a previously-snapshot hand-back payload stale (its
        // journal wouldn't include this action) — drop it so the next hand-back
        // re-snapshots.
        pendingHandbackPayload = nil
        operation { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                defer { self.processPendingRevoke() }   // a revoke parked during this command
                switch result {
                case .success(let status):
                    fileLog("pod cmd '\(label)' ✓")
                    self.status = status
                    self.notifyJournalChanged()
                case .failure(let error):
                    // P0#4 — an UNCERTAIN (unacknowledged) delivery is NOT a certain
                    // failure: the pod may have applied the command. Never tell the
                    // user "no change was made" in that case — say to verify the pod.
                    var uncertain = false
                    if case PodControlError.uncertainDelivery = error { uncertain = true }
                    fileLog("*** pod cmd '\(label)' \(uncertain ? "UNCERTAIN" : "FAILED"): \(error.localizedDescription) ***")
                    // C4: a DEFINITIVE refusal rolls back the caller's optimistic
                    // state (uncertain keeps it — the pod may have applied it).
                    if !uncertain { onCertainFailure?() }
                    self.lastError = error.localizedDescription
                    // LOUD surfacing (BUG-5): dose screens dismiss optimistically on
                    // confirm, so a late failure/uncertainty must announce itself —
                    // haptic + alert.
                    if self.phase == .active {
                        WKInterfaceDevice.current().play(.failure)
                        let title = uncertain
                            ? String(format: NSLocalizedString("%@ Uncertain", comment: "Alert title for an unacknowledged (uncertain) Sport Mode pod command"), label)
                            : String(format: NSLocalizedString("%@ Failed", comment: "Alert title for a failed Sport Mode pod command (parameter: command name)"), label)
                        let suffix = uncertain
                            ? NSLocalizedString("\nThe pod did not confirm. It MAY have applied this — check the pod before retrying.", comment: "Alert body suffix for an uncertain Sport Mode pod command")
                            : NSLocalizedString("\nNo change was made to the pod.", comment: "Alert body suffix for a failed Sport Mode pod command")
                        self.commandFailure = CommandFailure(title: title, message: error.localizedDescription + suffix)
                    }
                }
            }
        }
        return true
    }

    // MARK: - Hand back to the phone

    /// Send the loan journal to the phone and, once the phone acknowledges,
    /// release the pod so the phone can reclaim it. The pod is NOT released until
    /// the phone confirms receipt — so a failed hand-back leaves us still holding
    /// it rather than orphaning the pod.
    ///
    /// The journal payload is SNAPSHOT once per hand-back intent and retries resend
    /// the identical bytes: the phone's duplicate guard hashes the raw journal data,
    /// so a retry after a lost ack must be byte-identical or it would double-enter
    /// doses. The snapshot is invalidated whenever a new pod command runs.
    func handBack() {
        if Self.isSimulatorDemo { demoHandBack(); return }
        guard !busy, phase == .active else { return }
        let session = WCSession.default
        guard session.isReachable else {
            lastError = "iPhone not reachable — bring it close to end Sport Mode."
            return
        }
        busy = true
        phase = .handingBack
        lastError = nil

        if pendingHandbackPayload != nil {
            // Retry of a failed hand-back: resend the exact same journal bytes.
            sendHandback()
        } else {
            // DESIGN-5: hand the pod back running its SCHEDULE. A temp the watch
            // leaves running is invisible to the phone — the pod's status response
            // carries no rate or duration, and stock deliberately declines to
            // adopt unknown temps (PodState.updateDeliveryStatus, adoption
            // commented out). Closed loop replaces it within a cycle, but open
            // loop would let it run to expiry with the phone's IOB none the
            // wiser. Canceling makes the phone's "scheduled basal" belief TRUE
            // at the moment control transfers, and closes the journal's last
            // temp segment so the loan accounting is self-contained. A pod the
            // user deliberately suspended (a rate-0 temp) stays suspended —
            // cancelLeftoverTempIfNeeded skips rate-0 temps. Best-effort like the freshen below: a
            // hand-back must never be blocked by an unreachable or faulted pod.
            cancelLeftoverTempIfNeeded { [weak self] cancelWarning in
                guard let self else { return }
                // A revoke may have landed while the cancel ran — the journal is
                // abandoned and the revoke path owns delivery. Sending here would
                // snapshot an EMPTY journal whose ack could displace the real one.
                guard !self.wasRevokedByPhone, self.controller.loanJournal != nil else { return }
                // Freshen the pod's delivered-odometer right before snapshotting the
                // journal, so the phone's reconciliation audit sees delivery up to
                // hand-back rather than up to the last command. Best-effort: hand back
                // proceeds even if the read fails (journal keeps the last-known value).
                self.controller.getStatus { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        guard !self.wasRevokedByPhone, self.controller.loanJournal != nil else { return }
                        var summary = self.controller.loanJournalSummary(schedule: self.loanBasalSchedule) ?? "No loan activity recorded."
                        if let cancelWarning {
                            summary += "\n" + cancelWarning
                        }
                        if case .failure(let error) = result {
                            // The audit's deliveredLatest stays at the last successful
                            // read — say so where the phone will log and show it (OQ-5
                            // instrumentation: distinguishes freshen failure from a
                            // genuinely idle odometer).
                            summary += "\n⚠️ Final pod status read FAILED (\(error.localizedDescription)) — delivered total may be stale."
                        }
                        let journalData = self.controller.loanJournal?.encoded() ?? Data()
                        self.pendingHandbackPayload = (summary: summary, journalData: journalData)
                        self.sendHandback()
                    }
                }
            }
        }
    }

    /// DESIGN-5 helper: cancel a temp basal the watch believes is running, so
    /// control transfers with the pod on its stored schedule. Journal-gated —
    /// the watch is the single writer during a loan, so journal state matches
    /// pod state except for a temp that expired on its own, where the cancel is
    /// stock's sanctioned cancel-of-nothing no-op. On success the facade
    /// journals .cancelTempBasal, closing the temp's segment at hand-back time.
    /// On failure, returns a warning line for the hand-back summary; the
    /// hand-back itself proceeds regardless.
    private func cancelLeftoverTempIfNeeded(completion: @escaping (String?) -> Void) {
        // A rate-0 temp is a deliberate WITHHOLD — a manual bounded suspend, or a
        // closed-loop predicted-low zero temp. Leave it running so the pod hands back in
        // the suspended state and the phone re-evaluates from there (the bounded temp
        // auto-reverts at expiry). Only a POSITIVE leftover temp is cancelled back to
        // scheduled. NOTE: `sessionBasalRate` is 0 — NOT nil — after a suspend, because a
        // suspend is a rate-0 temp basal (P0#5), not a `.suspend` event; the old
        // `!= nil` guard therefore cancelled suspends and silently resumed basal.
        guard let rate = sessionBasalRate, rate != 0 else {
            completion(nil)
            return
        }
        controller.cancelTempBasal { result in
            Task { @MainActor in
                switch result {
                case .success:
                    completion(nil)
                case .failure(let error):
                    completion("⚠️ Leftover temp basal NOT canceled (\(error.localizedDescription)) — the pod continues it until it expires.")
                }
            }
        }
    }

    /// §4c-3: a journal persisted by a PREVIOUS run (crash or app update killed the
    /// watch app mid-loan) is handed back best-effort whenever the app becomes
    /// active — DATA FIRST; the dead session is never resumed. The phone's normal
    /// hand-back handler reconciles it (idempotent via the journal-hash guard) and
    /// reclaims the pod, so this also un-orphans a pod stranded by a crash.
    func attemptRecoveredJournalHandback() {
        // .done is safe too (loan over, journal persisted) — the DESIGN-6 revoke
        // path lands there and uses this same delivery.
        guard !Self.isSimulatorDemo, phase == .idle || phase == .done,
              let data = controller.recoveredLoanJournalData else { return }
        let decoded = PodLoanJournal.decoded(from: data)

        // The real loan-end time is the journal's LAST EVENT, not this (possibly hours-later)
        // relaunch. Use it for BOTH the summary's net-basal integration + suspend-duration
        // text (else an open suspend integrates from suspend-time all the way to relaunch →
        // a grossly inflated "Basal delivered vs schedule") AND the phone hand-back stamp
        // (a send-time stamp would inflate the phone's audit window for hours the watch
        // never held the pod).
        let handedBackAt = decoded?.events.last?.date ?? Date()

        // P1#10 — an orphaned journal in .idle means Sport Mode ended WITHOUT a normal
        // hand-back (the app was killed/relaunched mid-session). Announce it once so
        // the silent drop to open-loop isn't spooky. (.done is a deliberate phone
        // revoke — the done screen already explains that; don't double-alert.)
        if !announcedRecoveredSession, phase == .idle {
            announcedRecoveredSession = true
            let did = decoded?.summaryLines(now: handedBackAt, schedule: loanBasalSchedule).joined(separator: "\n")
            sessionEndedNotice = CommandFailure(
                title: NSLocalizedString("Sport Mode Ended", comment: "Alert title: Sport Mode ended unexpectedly on relaunch"),
                message: NSLocalizedString("Sport Mode ended unexpectedly (the app restarted). The loop is open and the pod is back on its schedule. Your insulin records are being sent to your phone.", comment: "Alert body: uncommanded Sport Mode end")
                    + (did.map { "\n\n\($0)" } ?? ""))
            fileLog("P1#10: announced uncommanded Sport Mode end (orphaned journal recovered)")
        }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            return   // keep it persisted; retry on next activation
        }
        var summary = decoded?.summaryLines(now: handedBackAt, schedule: loanBasalSchedule).joined(separator: "\n") ?? "Recovered watch loan journal."
        summary += "\n⚠️ Sent after Sport Mode ended without a normal hand-back."
        let handback = PodHandbackUserInfo(handedBackAt: handedBackAt, summary: summary, journalData: data)
        session.sendMessage(handback.rawValue, replyHandler: { [weak self] _ in
            Task { @MainActor in
                self?.controller.clearRecoveredLoanJournal()
            }
        }, errorHandler: { _ in
            // Keep it persisted; retried on the next activation.
        })
    }

    /// The journal payload for the in-flight hand-back, retained across retries so
    /// resends are byte-identical (see handBack). Cleared on success or when any
    /// new pod command invalidates it.
    private var pendingHandbackPayload: (summary: String, journalData: Data)?

    private func sendHandback() {
        guard let payload = pendingHandbackPayload else {
            busy = false
            phase = .active
            lastError = "Couldn't prepare hand-back."
            return
        }
        let session = WCSession.default
        let handback = PodHandbackUserInfo(handedBackAt: Date(), summary: payload.summary, journalData: payload.journalData)

        session.sendMessage(handback.rawValue, replyHandler: { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                _ = self.controller.endLoan()   // finalize the journal
                self.controller.releasePod()    // phone acked — safe to let go
                // NOTE: when a revoke landed mid-hand-back, the abandoned journal
                // stays persisted even though the phone just acked these same
                // bytes. Deliberate: the byte-hash duplicate guard makes a later
                // recovery resend harmless, whereas clearing here could wipe an
                // undelivered journal in ack-reordering corners. Cheap resend
                // beats possible loss.
                self.heldGrant = nil            // phone owns the pod again; keys are now stale
                self.pendingHandbackPayload = nil
                self.busy = false
                self.phase = .done
                self.processPendingRevoke()
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                // DESIGN-6: if a revoke landed while this hand-back was in
                // flight, the pod is NOT ours anymore — "still in control" would
                // be false and .active would offer pod commands we must not
                // send. Stay on the revoked done screen; the persisted journal
                // is delivered by the recovery path instead.
                if self.wasRevokedByPhone {
                    self.phase = .done
                    return
                }
                // Phone didn't confirm — keep holding the pod; the user can retry.
                // pendingHandbackPayload is retained so the retry resends the SAME
                // journal bytes (the phone's duplicate guard hashes them).
                self.phase = .active
                self.lastError = "Couldn't reach iPhone to end Sport Mode: \(error.localizedDescription). Still in control on your watch."
                self.processPendingRevoke()
            }
        })
    }
}

// MARK: - Simulator demo mode
//
// The watchOS simulator has no Bluetooth, so it can never reach a pod. When
// `isSimulatorDemo` is true (simulator only — compile-time false on a real watch), the
// methods above route here instead of WatchConnectivity/BLE, walking the real phases
// with faked data + small delays. This makes the whole Sport Mode flow reviewable on the
// sim — no pod, no TestFlight. It can never execute on hardware.
private extension WatchPodLoanCoordinator {
    func demoStatus(_ delivery: String, delivered: Double) -> PodControlStatus {
        PodControlStatus(deliveryStatus: delivery, podProgress: "Running", reservoirLevel: 128,
                       insulinDelivered: delivered, bolusNotDelivered: 0,
                       lastProgrammingMessageSeqNum: 5, timeActive: 3600, alerts: "None")
    }

    func demoStart() {
        lastError = nil
        phase = .requesting
        busy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.phase = .armed
            self.busy = false
            // Mirror the real flow: takeover follows the grant automatically.
            self.demoClaim()
        }
    }

    func demoClaim() {
        busy = true
        demoBasalRate = nil
        demoBolusTotal = 0
        demoJournal = PodLoanJournal(startedAt: Date(), deliveredAtStart: 0)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.status = self.demoStatus("Scheduled Basal", delivered: 0)
            self.phase = .active
            self.lastError = nil
            self.busy = false
        }
    }

    func demoSuspend() {
        let delivered = status?.insulinDelivered ?? 0
        busy = true
        demoBasalRate = nil
        demoJournal?.record(.suspend)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.status = self.demoStatus("Suspended", delivered: delivered)
            self.busy = false
            self.notifyJournalChanged()
        }
    }

    func demoResume() {
        let delivered = status?.insulinDelivered ?? 0
        busy = true
        demoBasalRate = nil
        demoJournal?.record(.resume)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.status = self.demoStatus("Scheduled Basal", delivered: delivered)
            self.busy = false
            self.notifyJournalChanged()
        }
    }

    func demoBolus(units: Double) {
        let delivered = (status?.insulinDelivered ?? 0) + units
        busy = true
        demoBolusTotal += units
        demoJournal?.record(.bolus(units: units))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.status = self.demoStatus("Bolusing", delivered: delivered)
            self.busy = false
            self.notifyJournalChanged()
        }
    }

    func demoSetTempBasal(rate: Double, duration: TimeInterval = WatchPodLoanCoordinator.tempBasalDuration) {
        let delivered = status?.insulinDelivered ?? 0
        busy = true
        demoBasalRate = rate
        demoJournal?.record(.tempBasal(rate: rate, duration: duration))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.status = self.demoStatus(String(format: "Temp basal %.2f U/hr", rate), delivered: delivered)
            self.busy = false
            self.notifyJournalChanged()
        }
    }

    func demoCancelTempBasal() {
        let delivered = status?.insulinDelivered ?? 0
        busy = true
        demoBasalRate = nil
        demoJournal?.record(.cancelTempBasal)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.status = self.demoStatus("Scheduled Basal", delivered: delivered)
            self.busy = false
            self.notifyJournalChanged()
        }
    }

    func demoHandBack() {
        lastError = nil
        phase = .handingBack
        busy = true
        // Mirror DESIGN-5: a leftover temp is canceled as part of hand-back.
        if demoBasalRate != nil {
            demoJournal?.record(.cancelTempBasal)
            demoBasalRate = nil
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.phase = .done
            self.busy = false
        }
    }
}
