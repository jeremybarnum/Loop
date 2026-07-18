//
//  WatchAutoLoop.swift
//  WatchApp Extension
//
//  The standalone loop's policy layer. OPEN loop (today): it consumes the
//  store's already-computed recommendation and records the trail of what it
//  WOULD enact — visible, nothing dosed — exactly like open loop on the phone.
//  CLOSED loop (B2): `isClosed` becomes true and the same recommendation is
//  enacted. It does NOT compute the prediction — WatchPredictionStore is the
//  single source (the watch's LoopDataManager analog).
//
//  This mirrors Loop's separation: LoopDataManager owns the prediction and the
//  recommendedAutomaticDose; the loop()/enact path reads them. We do the same —
//  the store recomputes on every input change (glucose/carb/journal/settings),
//  posts one didUpdate, and this layer reacts to that single signal rather than
//  re-observing raw sources or running a second engine.
//
//  Design: docs/WATCH_STANDALONE_UI_AUTOLOOP.md. Rails relied on elsewhere:
//  the pod's ≤30-min temp auto-expiry (fail-safe for lenient staleness),
//  pod-layer proof limits, therapy-settings max basal in the shared math.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import Combine
import HealthKit
import LoopKit
import LoopCore
import WatchKit
import os.log

@MainActor
final class WatchAutoLoop: ObservableObject {

    /// P1#9 — a user-facing loop notice (e.g. the closed loop paused because BG
    /// went stale). Presented + haptically announced by whichever HUD page is up,
    /// the same way a failed pod command is. Distinct from the pod-command failure
    /// channel so the two don't clobber each other.
    struct Notice: Equatable {
        let title: String
        let message: String
    }
    @Published var notice: Notice?
    func clearNotice() { notice = nil }

    private func raiseNotice(title: String, message: String) {
        WKInterfaceDevice.current().play(.failure)
        notice = Notice(title: title, message: message)
        fileLog("LOOP NOTICE: \(title) — \(message)")
    }

    enum Decision {
        case setTemp(unitsPerHour: Double, minutes: Int)  // set/refresh a temp
        case suspend(minutes: Int)                        // bounded 0-rate temp
        case cancelTemp                                   // revert to schedule
        case scheduleFits                                 // no change needed
        case staleBG(minutes: Int)
        case noBG

        /// Open loop shows "would…" (advisory); closed loop shows the action
        /// (it was enacted). The ring/header also conveys open vs closed.
        func detailText(closed: Bool) -> String {
            switch self {
            case .setTemp(let rate, let minutes):
                return closed
                    ? String(format: NSLocalizedString("temp %.2f U/hr · %dm", comment: "Loop decision (closed): temp set"), rate, minutes)
                    : String(format: NSLocalizedString("would set %.2f U/hr · %dm", comment: "Loop decision (open): temp it would set"), rate, minutes)
            case .suspend(let minutes):
                return closed
                    ? String(format: NSLocalizedString("suspend · %dm", comment: "Loop decision (closed): suspended"), minutes)
                    : String(format: NSLocalizedString("would suspend · %dm", comment: "Loop decision (open): would suspend"), minutes)
            case .cancelTemp:
                return closed
                    ? NSLocalizedString("→ schedule", comment: "Loop decision (closed): reverted to schedule")
                    : NSLocalizedString("would revert to schedule", comment: "Loop decision (open): would revert")
            case .scheduleFits:
                return NSLocalizedString("schedule fits", comment: "Loop decision: no temp needed")
            case .staleBG(let minutes):
                return String(format: NSLocalizedString("paused — BG %dm old", comment: "Loop decision: glucose too stale to dose"), minutes)
            case .noBG:
                return NSLocalizedString("paused — no BG", comment: "Loop decision: no glucose available")
            }
        }

        /// Records a new history entry only when this changes.
        var changeKey: String {
            switch self {
            case .setTemp(let rate, _): return String(format: "temp:%.2f", rate)
            case .suspend: return "suspend"
            case .cancelTemp: return "cancel"
            case .scheduleFits: return "fits"
            case .staleBG: return "stale"
            case .noBG: return "nobg"
            }
        }
    }

    struct Cycle: Identifiable {
        let id = UUID()
        let date: Date
        let trigger: String
        let bg: HKQuantity?
        let eventual: HKQuantity?
        let math: WatchPredictionOutput.CorrectionMath?
        let decision: Decision
        let wasClosed: Bool
    }

    /// Whether the loop is CLOSED (auto-enacting). Open loop always shows the
    /// recommendation trail below; closing the loop (B2) enacts it. Per-session,
    /// default open — a standalone session never inherits yesterday's decision.
    @Published private(set) var isClosed = false {
        didSet {
            // H19: the dead-man's switch is armed only while the loop is CLOSED
            // (an open/CGM-viewer session has no loop to stall). Arm on close,
            // disarm on open; loopCycle pushes it forward on every live cycle.
            if isClosed { LoopStallWatchdog.refresh() } else { LoopStallWatchdog.disarm() }
        }
    }
    @Published private(set) var lastCycle: Cycle?
    /// Rolling shadow-decision history, most-recent-first, for on-wrist
    /// validation (the log trail, made visible). Session-scoped.
    @Published private(set) var recentCycles: [Cycle] = []
    private static let historyLength = 12

    /// Loop's own recency rule — the same constant that gates glucose freshness
    /// on the phone loop and the HUD (via the store), not a bespoke number.
    static let bgStalenessLimit: TimeInterval = LoopCoreConstants.inputDataRecencyInterval

    private let log = OSLog(category: "WatchAutoLoop")
    private let store: WatchPredictionStore
    private let coordinator: WatchPodLoanCoordinator

    private var updateObserver: NSObjectProtocol?
    private var loopTickObserver: NSObjectProtocol?
    /// The prediction we last enacted, so we act once per new prediction
    /// (ifNecessary already handles continuation between them).
    private var lastEnactedAnchorDate: Date?

    // MARK: - P1#7 CGM-sovereignty activation gate

    /// How long after Sport Mode activates the watch has to produce its OWN direct
    /// sensor read before we warn. One worst-case EGV interval + handshake — see
    /// the CGM-direct timing analysis. Until this proves out, the loop may be
    /// silently running on a phone-pushed value (the trap the ruling targets).
    static let cgmSovereigntyTimeout: TimeInterval = 6 * 60
    private var phaseCancellable: AnyCancellable?
    private var cgmSovereigntyWork: DispatchWorkItem?

    init(store: WatchPredictionStore, coordinator: WatchPodLoanCoordinator) {
        self.store = store
        self.coordinator = coordinator

        // DISPLAY trail: record the recommendation on every store recompute
        // (open loop shows what it would do). No enactment here.
        updateObserver = NotificationCenter.default.addObserver(forName: WatchPredictionStore.didUpdateNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.recordTrail(trigger: "update") }
        }
        // LOOP CYCLE: enact only on a loop-worthy tick (new glucose or the
        // periodic tick), never on a dose/carb/settings recompute — mirrors
        // Loop's loop() triggers and avoids re-looping off our own enactment.
        loopTickObserver = NotificationCenter.default.addObserver(forName: WatchPredictionStore.didLoopTickNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.loopCycle(trigger: "tick") }
        }
        // P1#7 — arm the CGM-sovereignty check on each activation.
        phaseCancellable = coordinator.$phase.removeDuplicates().sink { [weak self] phase in
            Task { @MainActor in self?.handlePhaseForSovereignty(phase) }
        }
    }

    deinit {
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        if let loopTickObserver { NotificationCenter.default.removeObserver(loopTickObserver) }
    }

    /// P1#7 — on each Sport Mode activation, arm a timeout to verify CGM sovereignty:
    /// the watch must land a read through its OWN radio (G7Client.lastReadDate moves
    /// past the activation instant), not just show a fresh store value the phone may
    /// have pushed. If the window lapses with no direct read, warn loudly — this is
    /// the affirmative proof that prevents "left the phone behind, lost glucose".
    private func handlePhaseForSovereignty(_ phase: WatchPodLoanCoordinator.Phase) {
        cgmSovereigntyWork?.cancel()
        cgmSovereigntyWork = nil
        guard case .active = phase else {
            LoopStallWatchdog.disarm()   // H19: Sport Mode ended — the loop is intentionally stopping
            return
        }
        let activatedAt = Date()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, case .active = self.coordinator.phase else { return }
                let lastDirect = ExtensionDelegate.shared().g7.client.lastReadDate
                let provedDirect = lastDirect.map { $0 >= activatedAt } ?? false
                if provedDirect {
                    fileLog("P1#7: CGM sovereignty confirmed — direct read after activation")
                } else {
                    self.raiseNotice(
                        title: NSLocalizedString("No Direct Sensor Yet", comment: "Alert title: the watch hasn't read the sensor directly since Sport Mode started"),
                        message: NSLocalizedString("Sport Mode is on, but the watch hasn't read the sensor directly yet. Watch will continue trying to connect to sensor but once you move away from phone you will not have fresh BG until the watch connects.", comment: "Alert body: CGM sovereignty not yet proven"))
                }
            }
        }
        cgmSovereigntyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cgmSovereigntyTimeout, execute: work)
    }

    /// B2 will call this (behind the crown-confirm) to CLOSE the loop and begin
    /// enacting. Today the recommendation trail is always shown; nothing enacts.
    func setClosed(_ closed: Bool) {
        guard closed != isClosed, case .active = coordinator.phase else { return }
        isClosed = closed
        log.default("standalone loop %{public}@", closed ? "CLOSED" : "opened")
        if closed { loopCycle(trigger: "closed") }   // act on the current recommendation now
    }

    /// Record the current recommendation for display if it changed — the
    /// open/closed trail. No enactment here; that's loopCycle(), on a
    /// loop-worthy tick only.
    private func recordTrail(trigger: String) {
        guard case .active = coordinator.phase else {
            // No live session — nothing to recommend; clear the trail.
            if lastCycle != nil || isClosed {
                isClosed = false
                lastCycle = nil
                recentCycles = []
            }
            return
        }

        let anchor = store.anchorSample

        let decision: Decision
        let bg = anchor?.quantity
        var eventual: HKQuantity?
        var math: WatchPredictionOutput.CorrectionMath?

        if anchor == nil {
            decision = .noBG
        } else if store.isAnchorStale {
            // Lenient staleness (design ruling): stop issuing NEW temps; an
            // active one runs out on the pod's own ≤30-min clock.
            let age = anchor.map { -$0.startDate.timeIntervalSinceNow } ?? 0
            decision = .staleBG(minutes: Int(age / 60))
        } else if let output = store.latestOutput {
            eventual = output.eventualBG
            math = output.correctionMath()
            if let temp = output.recommendedTempBasal {
                if temp.duration == 0 {
                    decision = .cancelTemp
                } else if temp.unitsPerHour == 0 {
                    decision = .suspend(minutes: Int(temp.duration.minutes))
                } else {
                    decision = .setTemp(unitsPerHour: temp.unitsPerHour, minutes: Int(temp.duration.minutes))
                }
            } else {
                decision = .scheduleFits
            }
        } else {
            // Fresh anchor but no successful prediction yet (settings not synced,
            // or the recompute is in flight). Wait for the next store update
            // rather than record a spurious decision.
            return
        }

        // Record only meaningful changes (see Decision.changeKey).
        guard decision.changeKey != lastCycle?.decision.changeKey else { return }

        let cycle = Cycle(date: Date(), trigger: trigger, bg: bg, eventual: eventual, math: math, decision: decision, wasClosed: isClosed)
        lastCycle = cycle
        recentCycles.insert(cycle, at: 0)
        if recentCycles.count > Self.historyLength { recentCycles.removeLast() }
        log.default("loop decision (%{public}@): %{public}@", trigger, decision.detailText(closed: isClosed))
        fileLog("loop decision (\(trigger)): \(decision.detailText(closed: isClosed)) · bg=\(bg.map { String(format: "%.0f", $0.doubleValue(for: .milligramsPerDeciliter)) } ?? "—")")

        // P1#9 — a CLOSED loop that just transitioned into a state where it can no
        // longer dose (BG stale/absent) taps the wrist and surfaces once. recordTrail
        // runs only on a decision CHANGE, so this is inherently once-per-episode; the
        // recovery back to an actionable decision is silent (nothing to warn about).
        if isClosed {
            switch decision {
            case .staleBG(let minutes):
                raiseNotice(title: NSLocalizedString("Loop Paused", comment: "Alert title: the closed loop stopped dosing"),
                            message: String(format: NSLocalizedString("Glucose is %d min old — the loop stopped adjusting basal. The last temp expires on the pod's own timer. Check your sensor.", comment: "Alert body: closed loop paused on stale glucose"), minutes))
            case .noBG:
                raiseNotice(title: NSLocalizedString("Loop Paused", comment: "Alert title: the closed loop stopped dosing"),
                            message: NSLocalizedString("No recent glucose — the loop can't adjust basal. Check your sensor.", comment: "Alert body: closed loop paused with no glucose"))
            default:
                break
            }
        }
    }

    /// The loop() analog: on a loop-worthy tick (new glucose / periodic / on
    /// close), enact the store's current recommendation if the loop is closed
    /// and the BG is fresh. DoseEnactor-style: one duration-parameterized
    /// enactTempBasal straight from recommendedTempBasal. Acts once per new
    /// prediction; ifNecessary continuation means it only carries a temp when a
    /// change/refresh is actually needed. Failures surface loudly via the
    /// coordinator; we stay closed and retry next tick. Stale/no BG → no enact
    /// (lenient — the active temp expires on the pod's clock).
    private func loopCycle(trigger: String) {
        guard isClosed, case .active = coordinator.phase else { return }
        guard let output = store.latestOutput, !store.isAnchorStale else { return }
        // H19: a closed loop cycle with a FRESH reading proves the loop is alive —
        // push the dead-man's switch forward. If the loop stops completing cycles
        // (keepalive death, prolonged reading gap), this stops firing and the
        // pre-scheduled alert lands from outside the (suspended) app.
        LoopStallWatchdog.refresh()
        // Enact at most once per genuinely-new reading. Keyed on the anchor sample's identity, NOT
        // output.date (which is wall-clock-at-predict and always fresh, so it never deduped) — this
        // collapses every redundant loop-worthy trigger for the same reading into a single enact
        // (root fix for the pod-command storm). A distinct new reading → distinct anchor → enacts.
        guard lastEnactedAnchorDate != output.anchorDate else { return }
        // Recency guard (mirrors enactRecommendedAutomaticDose's 5-min check).
        guard abs(output.date.timeIntervalSinceNow) < .minutes(5) else { return }

        // P0#2 — never enact over a manual suspend. The user affirmatively held
        // delivery; the closed loop must not silently resume it. Mirrors the phone,
        // where a manual suspend blocks looping until the user resumes. (Checked
        // BEFORE marking the prediction enacted, so resuming re-loops immediately.)
        if coordinator.sessionSuspended {
            fileLog("closed loop SKIP (\(trigger)): delivery is manually suspended — not enacting")
            return
        }

        // H2: the anchor latch (line 299 — the storm guard: one action per reading)
        // is now claimed AFTER the pod actually accepts the command, not before it.
        // enactTempBasal/cancelBasal go through runPodCommand, which DROPS silently
        // if the pod is busy (another command in flight); previously the latch was
        // set first, so a dropped enact stranded this reading's decision until the
        // NEXT reading (~5 min) — over-delivery direction when a reduction is
        // dropped. Setting on-accept leaves a busy-dropped enact unlatched, so the
        // next tick (≤60 s heartbeat) retries — approximating stock, which never
        // latches: it re-derives against the running temp via DoseMath.ifNecessary
        // every cycle. (Proper fix — a pod-grid rateRounder into generateRecommendation
        // so ifNecessary works, then delete this latch — is from-stock; see M12.)
        guard let temp = output.recommendedTempBasal else {
            lastEnactedAnchorDate = output.anchorDate   // no action needed — this reading is handled
            return
        }

        // The recommendation is already bounded by therapy max basal inside
        // generateRecommendation. Two additional dosing-safety guards, mirroring
        // the phone, applied here so both the log and the pod see the same number:
        var rate = temp.unitsPerHour

        // P0#3 / cap — clamp to the operating ceiling (the wearer's therapy max-basal,
        // which the coordinator also programs as the pod's proof limit) so the ENACT
        // log and the pod agree. A no-op for the closed loop (generateRecommendation
        // already bounds by max-basal); it bites only on a bug.
        let cap = coordinator.maxTempBasalRate
        if rate > cap {
            fileLog(String(format: "closed loop CLAMP (%@): %.2f → %.2f U/hr (max-basal cap)", trigger, rate, cap))
            rate = cap
        }

        // P0#1 — IOB clamp, EXACT parity with the phone's tempBasalOnly path. The phone
        // passes `additionalActiveInsulinClamp: iobHeadroom` into DoseMath.recommendedTempBasal
        // (LoopDataManager.swift:2003); the watch's generateRecommendation `.tempBasal`
        // case does NOT, so we apply the identical clamp here (DoseMath.swift:426):
        //   iobHeadroom = maxBolus×2 − IOB
        //   maxRate     = iobHeadroom×2 + scheduledBasalRate   (30-min rate keeping IOB < limit)
        // Applying min(rate, maxRate) to the already-max-basal-bounded recommendation is
        // identical to the phone's min(maxBasalRate, maxRate) → asTempBasal. Flooring at 0
        // turns an over-limit state (negative headroom) into a zero temp (auto de-stack).
        if let maxBolus = ExtensionDelegate.shared().loopManager.settings.maximumBolus {
            let iobHeadroom = maxBolus * 2.0 - output.activeInsulin
            let maxRateForIOB = max(0, iobHeadroom * 2.0 + output.scheduledBasalRate)
            if rate > maxRateForIOB {
                fileLog(String(format: "closed loop IOB-CLAMP (%@): IOB %.2f headroom %.2f → cap %.2f U/hr (was %.2f)",
                               trigger, output.activeInsulin, iobHeadroom, maxRateForIOB, rate))
                rate = maxRateForIOB
            }
        }

        log.default("closed loop enact (%{public}@): %.2f U/hr for %.0f min", trigger, rate, temp.duration.minutes)
        fileLog(String(format: "closed loop ENACT (%@): %.2f U/hr for %.0f min", trigger, rate, temp.duration.minutes))
        // H2: latch only if the pod accepted the command; a busy-drop stays
        // unlatched so the next tick retries this reading.
        //
        // A2 (Empty Value fix): enactTempBasal returns true the moment the command is
        // DISPATCHED, not when the pod acknowledges. So a command that dispatches and
        // then fails ASYNCHRONOUSLY (e.g. "Empty Value" — the pod never received it under
        // radio contention) would otherwise stay latched and never retry until the next
        // NEW reading (~5 min) — the over-delivery direction when the dropped command was
        // a reduction/suspend. Fix: latch optimistically on dispatch (so the ≤60 s
        // heartbeat doesn't re-fire mid-command), then UN-latch on a CERTAIN failure so
        // the next tick re-enacts on fresh BG. An UNCERTAIN outcome stays latched — the
        // pod may have applied it; retrying could double-dose (matches the C4 rule).
        let enactedAnchor = output.anchorDate
        if coordinator.enactTempBasal(unitsPerHour: rate, for: temp.duration, onCertainFailure: { [weak self] in
            guard let self, self.lastEnactedAnchorDate == enactedAnchor else { return }
            self.lastEnactedAnchorDate = nil
            fileLog("closed loop enact FAILED (certain) — anchor un-latched; retry next tick")
        }) {
            lastEnactedAnchorDate = enactedAnchor
        } else {
            fileLog("closed loop enact DROPPED (busy) — anchor left unlatched; retry next tick")
        }
    }
}


import UserNotifications

/// H19 — DEAD-MAN'S SWITCH for the watch closed loop.
///
/// watchOS suspends the app when the wrist drops; the HKWorkoutSession keepalive
/// is what keeps the loop running in the background. If that keepalive dies (or
/// readings stop for a long stretch), the process is SUSPENDED and cannot raise
/// an alarm itself — so the alarm must be PRE-SCHEDULED: a local notification
/// armed to fire in the future and pushed forward on every successful closed-loop
/// cycle. As long as the loop keeps completing cycles the alert is perpetually
/// re-deferred and never fires; if the loop stalls, nothing defers it and watchOS
/// delivers it FROM OUTSIDE the (dead) app. Mirrors the phone's loop-not-running
/// watchdog, relocated to the watch and keyed to the watch's own loop.
enum LoopStallWatchdog {

    // ─── TUNABLES — safe to change for your own build ────────────────────────

    /// How long the closed loop may go without completing a cycle before the
    /// alert fires. Refreshed on every live cycle, so it only fires on a genuine
    /// stall. 15 min = three G7 reading intervals: tolerates a normal RF gap or
    /// two, catches a real stall promptly. (The phone's AT-REST loop-not-running
    /// ladder starts at 20 min — a workout warrants a tighter window.)
    static let interval: TimeInterval = 15 * 60

    /// How disruptive the "loop stopped" alert is.
    ///   false (DEFAULT) → .timeSensitive: a wrist haptic + on-screen card that
    ///     can break through Focus, but does NOT force sound through the silent
    ///     switch / Do Not Disturb. Deliberately non-blaring so it can't disrupt
    ///     an equestrian competition round.
    ///   true → .critical: pierces silent mode / DND with sound — louder and more
    ///     insistent. Requires the app's Critical Alerts entitlement (and
    ///     FeatureFlags.criticalAlertsEnabled on a full build); without the
    ///     entitlement watchOS silently downgrades it to time-sensitive.
    /// Change this one flag to trade non-disruption against insistence.
    static let useCriticalAlert = false

    // ─────────────────────────────────────────────────────────────────────────

    private static let identifier = "com.loopkit.Loop.watch.loopStallWatchdog"

    /// Arm the watchdog or push its deadline forward. Adding a request with the
    /// same identifier REPLACES the pending one, so calling this on every live
    /// cycle simply re-defers the alert.
    static func refresh() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Sport Mode Loop Stopped", comment: "Title: the watch closed loop has stopped completing cycles")
        content.body = NSLocalizedString("The watch hasn't looped in a while — check your pod and glucose. Your pod reverts to its scheduled basal when its last temp expires.", comment: "Body: the watch closed loop has stopped completing cycles")
        content.interruptionLevel = useCriticalAlert ? .critical : .timeSensitive
        content.sound = useCriticalAlert ? .defaultCritical : .default
        content.threadIdentifier = identifier
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    /// Disarm — a clean end / hand-back / open loop. The loop is stopping on purpose.
    static func disarm() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
