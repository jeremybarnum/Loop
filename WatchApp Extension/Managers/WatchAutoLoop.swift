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
    @Published private(set) var isClosed = false
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
    private var lastEnactedPredictionDate: Date?

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
    }

    deinit {
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        if let loopTickObserver { NotificationCenter.default.removeObserver(loopTickObserver) }
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
        guard lastEnactedPredictionDate != output.date else { return }
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
        lastEnactedPredictionDate = output.date

        guard let temp = output.recommendedTempBasal else { return }  // schedule fits — no action

        // The recommendation is already bounded by therapy max basal inside
        // generateRecommendation. Two additional dosing-safety guards, mirroring
        // the phone, applied here so both the log and the pod see the same number:
        var rate = temp.unitsPerHour

        // P0#3 — clamp to the pod layer's hard proof cap so the ENACT log and the
        // pod agree. Without this the pod silently re-caps (proof limit) and the
        // trail overstates what was delivered. Fires only if therapy max > cap.
        let proofCap = WatchPodLoanCoordinator.maxTempBasalRate
        if rate > proofCap {
            fileLog(String(format: "closed loop CLAMP (%@): %.2f → %.2f U/hr (proof cap)", trigger, rate, proofCap))
            rate = proofCap
        }

        // P0#1 — IOB clamp. Once active insulin is at/over the automatic-dosing
        // ceiling (maxBolus×2, the phone's automaticDosingIOBLimit), refuse to ADD
        // insulin above the scheduled basal; hold at schedule instead. Reductions
        // and zero-temps (a predicted low pulling delivery down) always pass.
        if let maxBolus = ExtensionDelegate.shared().loopManager.settings.maximumBolus {
            let iobLimit = maxBolus * 2.0
            if output.activeInsulin >= iobLimit && rate > output.scheduledBasalRate {
                fileLog(String(format: "closed loop IOB-CLAMP (%@): IOB %.2f ≥ limit %.2f — holding at schedule %.2f (was %.2f)",
                               trigger, output.activeInsulin, iobLimit, output.scheduledBasalRate, rate))
                rate = output.scheduledBasalRate
            }
        }

        log.default("closed loop enact (%{public}@): %.2f U/hr for %.0f min", trigger, rate, temp.duration.minutes)
        fileLog(String(format: "closed loop ENACT (%@): %.2f U/hr for %.0f min", trigger, rate, temp.duration.minutes))
        coordinator.enactTempBasal(unitsPerHour: rate, for: temp.duration)
    }
}
