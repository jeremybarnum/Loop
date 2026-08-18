//
//  WatchLoopManager.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  M4 of the watch-from-stock rebuild (docs/DESIGN_FROM_STOCK_REBUILD.md §1.5/§4 M4).
//
//  A MINIATURE OF THE PHONE'S STOCK LoopDataManager POLICY PATHS. Every dosing-relevant
//  decision here is either (a) the identical LoopKit/DoseMath entry point the phone calls,
//  or (b) a structural mirror of a named LoopDataManager method, cited inline. Nothing
//  reimplements policy beside a stock call — the adversarial review's central lesson
//  (defect density tracks distance from upstream).
//
//  Mirrored phone patterns (Loop/Managers/LoopDataManager.swift unless noted):
//    loop()/loopInternal()                 -> WatchLoopManager.loop()
//    update(for: .loop) effect refresh     -> updateCachedEffects()
//    updateRetrospectiveGlucoseEffect()    -> same name (guard-throw instead of force-unwrap)
//    predictGlucose(using:)                -> same name (no potential-bolus/-carb arms yet)
//    updatePredictedGlucoseAndRecommendedDose(with:) -> same name
//    recommendBolusValidatingDataRecency / recommendManualBolus -> same names
//    enactRecommendedAutomaticDose()       -> same name (enact seam, M4: unconnected)
//    DoseEnactor.enact(recommendation:with:) (Loop/Managers/DoseEnactor.swift) -> WatchDoseEnactor
//    DeviceDataManager.cgmManager(_:hasNew:) + processCGMReadingResult
//        (Loop/Managers/DeviceDataManager.swift:580/:1001) -> CGMManagerDelegate extension
//
//  M4 SCOPE: construction + compile proof. The enact seam is typed against the stock
//  PumpManager protocol (the M2 OmniPumpManager conforms) but `pumpManager` stays nil —
//  no dosing, no behavior claims. See StockLoopStack.assemble() for the (uninvoked)
//  wiring entry point.
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import G7SensorKit
import WatchConnectivity
import os.log

// MARK: - Errors (miniature of Loop/Models/LoopError.swift, which is phone-target-only)

/// Watch-side mirror of the phone's `LoopError` cases exercised by the loop policy paths.
/// (The phone file also carries `StoredDosingDecision` issue plumbing that has no watch
/// counterpart yet, so the type is mirrored rather than shared.)
enum WatchLoopError: Error {
    /// A settings element is missing. MISSING SETTINGS DENY DOSING — no fabricated
    /// defaults, ever (design doc §1.5).
    case configurationError(String)
    /// A data input is missing.
    case missingDataError(String)
    /// The dose was computed but the PUMP REFUSED OR COULD NOT BE
    /// REACHED. Never wrap this as `.missingDataError`, which is wrong twice over: it is
    /// not a data problem, and the cycle-verdict logger deliberately suppresses
    /// missingDataError (it is logged separately as "NOT DOSING — prediction missing X"), so
    /// every failed enact would produce NO cycle verdict at all — a loop that looks silent
    /// rather than broken.
    case enactFailed(String)
    /// Glucose data is too old to dose from (`LoopError.glucoseTooOld`).
    case glucoseTooOld(date: Date)
    /// Glucose data is in the future (`LoopError.invalidFutureGlucose`).
    case invalidFutureGlucose(date: Date)
    /// Pump data is too old to dose from (`LoopError.pumpDataTooOld`).
    case pumpDataTooOld(date: Date)
    /// The recommendation aged out before enactment (`LoopError.recommendationExpired`).
    case recommendationExpired(date: Date)
    /// Delivery is suspended (`LoopError.pumpSuspended`).
    case pumpSuspended
    /// M4 only: the enact seam has no pump manager connected (M5 wires the loaned pod).
    case pumpManagerUnconnected
}

// Intelligible refusals — 'WatchLoopError error 7' told the user nothing (verify
// finding: they can't distinguish "dial a smaller bolus" from "no pump connected").
extension WatchLoopError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .configurationError(let field):
            return String(format: NSLocalizedString("Missing setting: %@", comment: "Watch loop error (1: setting name)"), field)
        case .missingDataError(let what):
            return String(format: NSLocalizedString("Missing data: %@", comment: "Watch loop error (1: data name)"), what)
        case .enactFailed(let why):
            // Say what is actually wrong: the loop decided, the POD did not take it. The old
            // wrapping as missingDataError told the user "Missing data: podNotConnected".
            return String(format: NSLocalizedString("The pod did not accept the dose: %@", comment: "Watch loop error (1: pump error)"), why)
        case .glucoseTooOld:
            return NSLocalizedString("Glucose is too old to dose from.", comment: "Watch loop error")
        case .invalidFutureGlucose:
            return NSLocalizedString("Glucose timestamp is in the future.", comment: "Watch loop error")
        case .pumpDataTooOld:
            return NSLocalizedString("Pump data is too old to dose from.", comment: "Watch loop error")
        case .recommendationExpired:
            return NSLocalizedString("The recommendation expired before enacting.", comment: "Watch loop error")
        case .pumpSuspended:
            return NSLocalizedString("Insulin delivery is suspended.", comment: "Watch loop error")
        case .pumpManagerUnconnected:
            return NSLocalizedString("No pod connected to the watch.", comment: "Watch loop error")
        }
    }
}

// MARK: - WatchLoopManager

final class WatchLoopManager {

    // MARK: Stores (LoopKit, real persistence — M1)

    let doseStore: DoseStore
    let glucoseStore: GlucoseStore
    let carbStore: CarbStore

    // MARK: Settings

    /// Phone-pushed therapy settings (`LoopSettingsUserInfo` -> persisted `LoopSettings`),
    /// the same LoopCore type the stock watch LoopDataManager holds. Defaults to an empty
    /// `LoopSettings` whose nil schedules/limits DENY dosing via the configuration gates in
    /// `updatePredictedGlucoseAndRecommendedDose` — the no-fallback rule. Settings plumbing
    /// from the stock watch session arrives with M5 integration.
    ///
    /// ROOT CAUSE of a "NOT DOSING — prediction missing carbEffect" loop: the stores
    /// were built schedule-less (StockLoopStack.makeStores)
    /// and NOTHING propagated the grant's schedules to them — so CarbStore.getGlucoseEffects
    /// and DoseStore.getGlucoseEffects failed .notConfigured EVERY cycle, carbEffect/
    /// insulinEffect stayed nil, and the automatic loop never once recommended a dose
    /// The granted therapy settings, in the form the rest of the settings machinery expects.
    /// Refreshed whenever a grant lands; the single source every schedule is resolved from.
    let settingsProvider: WatchSettingsProvider

    /// The override history the loan's schedules resolve against. Deliberately held directly
    /// rather than through the phone's `TemporaryPresetsManager`: that type is `@MainActor`,
    /// and this loop resolves schedules synchronously on its own queue while deciding a dose.
    /// The history itself carries no isolation, so owning it here keeps schedule resolution
    /// where the dosing decision happens instead of hopping actors mid-decision.
    let overrideHistory: TemporaryScheduleOverrideHistory

    /// The therapy maximumBolus the GRANT delivered, in a form the main thread may read.
    ///
    /// The manual-bolus dial used to take its ceiling from the HUD `LoopDataManager`'s
    /// settings — a different object, whose only writer is a `LoopSettingsUserInfo` the PHONE
    /// pushes, falling back to a hardcoded 10 U on a watch that has never been in range. So in
    /// Sport Mode the dial was capped by the wrong number in both directions: below the
    /// prescribed max (can't dial it) or above it (dial accepts, then `enactManualBolus`
    /// refuses at :1921 after the screen has already dismissed).
    ///
    /// `settings` is a mutable value type owned by `dataAccessQueue`, so it must not be read
    /// across queues; this is a scalar snapshot republished on every assignment.
    private let grantedMaximumBolusLock = NSLock()
    private var _grantedMaximumBolus: Double?

    /// Therapy maximumBolus from the loan grant, or nil if no grant has landed. Main-safe.
    var grantedMaximumBolus: Double? {
        grantedMaximumBolusLock.lock()
        defer { grantedMaximumBolusLock.unlock() }
        return _grantedMaximumBolus
    }

    var settings: LoopSettings {
        didSet {
            grantedMaximumBolusLock.lock()
            _grantedMaximumBolus = settings.maximumBolus
            grantedMaximumBolusLock.unlock()

            // The stores no longer hold therapy settings — schedules are handed to the
            // algorithm per run instead of being pushed into the stores ahead of time. So a
            // new grant is published to the settings provider, and everything that resolves
            // a schedule reads through `temporaryPresetsManager`, which combines the granted
            // schedules with the active override.
            settingsProvider.update(with: settings)

        }
    }

    private var _scheduleOverride: TemporaryScheduleOverride?

    /// The override in force for this loan.
    ///
    /// An override only takes effect through the override HISTORY, not through a settings
    /// object — without the history the wrist resolves every schedule UNSCALED (basal, ISF,
    /// carb ratio) and nets historical temps against the wrong baseline, which reads exactly
    /// like an IOB bug. `TemporaryPresetsManager` owns that history and records into it on
    /// assignment, so routing through it here is what makes the override real.
    var scheduleOverride: TemporaryScheduleOverride? {
        get { _scheduleOverride }
        set {
            let oldValue = _scheduleOverride
            guard newValue != oldValue else { return }
            _scheduleOverride = newValue
            overrideHistory.recordOverride(newValue)

            if let o = newValue {
                let target = o.settings.targetRange.map {
                    String(format: "%.0f-%.0f", $0.lowerBound.doubleValue(for: .milligramsPerDeciliter),
                           $0.upperBound.doubleValue(for: .milligramsPerDeciliter))
                } ?? "unchanged"
                SportLog.event("override", String(format: "APPLIED %@ · insulin needs %.0f%% (basal x%.2f, ISF x%.2f, CR x%.2f) · target %@ · ends %@",
                                                  o.context.presetNameForLog,
                                                  o.settings.effectiveInsulinNeedsScaleFactor * 100,
                                                  o.settings.basalRateMultiplier ?? 1.0,
                                                  o.settings.insulinSensitivityMultiplier ?? 1.0,
                                                  o.settings.carbRatioMultiplier ?? 1.0,
                                                  target,
                                                  o.duration.isInfinite ? "indefinite" : ISO8601DateFormatter().string(from: o.scheduledInterval.end)))
            } else if oldValue != nil {
                SportLog.event("override", "CLEARED — schedules resolve unscaled again")
            }

        }
    }

    /// The insulin model to use for a dose.
    ///
    /// The stores used to own a model provider; the loop owns this decision now. Pod doses
    /// carry their own `insulinType`, so the typeless default is only ever reached by doses
    /// that never named one.
    func insulinModel(for type: InsulinType?) -> InsulinModel {
        switch type {
        case .fiasp: return ExponentialInsulinModelPreset.fiasp
        case .lyumjev: return ExponentialInsulinModelPreset.lyumjev
        case .afrezza: return ExponentialInsulinModelPreset.afrezza
        default: return settings.defaultRapidActingModel ?? ExponentialInsulinModelPreset.rapidActingAdult
        }
    }

    // MARK: The enact seam (M4: UNCONNECTED)

    /// Typed against the stock `PumpManager` protocol — the same protocol methods the phone's
    /// DoseEnactor calls (`enactTempBasal`/`enactBolus`) and the M2 `OmniPumpManager`
    /// implements. nil in M4: assembly is proven, dosing is not.
    /// Wiring a live pump manager happens via the loan protocol v2 controller
    /// (DESIGN_LOAN_PROTOCOL_V2.md §10): the grant's PodState snapshot constructs the
    /// OmniPumpManager and hands it here. The ruling dependencies are discharged
    /// (therapy-settings-only limits; max-temp = therapy max-basal) — the remaining gate
    /// is the protocol itself, never a direct assignment from app code.
    var pumpManager: PumpManager?
    /// True when the POD itself will beep for a manual bolus, making the watch's success
    /// haptic redundant (both fire the instant the pod accepts). False when the pod is
    /// silenced — then the haptic is the ONLY confirmation and must stay.
    ///
    /// A closure, not a cast: this file works against the `PumpManager` protocol and does not
    /// import OmnipodKit. Wired in StockLoopSession alongside reclaimPodForDose.
    var podBeepsOnManualBolusProbe: (() -> Bool)?
    var podBeepsOnManualBolus: Bool { podBeepsOnManualBolusProbe?() ?? false }

    /// The loan controller's dose-recording hooks (spec §1.2); set alongside
    /// `pumpManager` by PodLoanWatchController, cleared with it.
    weak var loanDoseRecorder: WatchLoanDoseRecording? {
        get { doseEnactor.loanRecorder }
        set { doseEnactor.loanRecorder = newValue }
    }


    /// Reclaim the orphaned pod before a dose, release after.
    /// Forwarded to the enactor (automatic path); enactManualBolus uses them directly.
    /// Wired by StockLoopSession to the loan controller (which owns the OmniPumpManager);
    /// no-op / immediate-connected when the pod link is held continuously instead.
    /// Device-log storm dedupe (see logEventForDeviceIdentifier). Any thread may log.
    private let deviceLogThrottle = DeviceLogThrottle()

    private let manualBolusLock = NSLock()
    private var _manualBolusInFlight = false
    /// True from the moment a manual bolus begins its pod reclaim until it resolves.
    ///
    /// A manual bolus can take ~29s wall-clock — up to 24s of it waiting for the G7 to
    /// release the radio, then ~4s reclaiming the pod, then ~1.3s delivering. The bolus flow
    /// auto-dismisses after 1s and shows NOTHING for the rest, so the wrist looks idle while the
    /// dose is very much in progress. A user who reads that silence as a hang taps End, and End
    /// cancels the in-flight reclaim — impatience silently destroys the dose. The glance reads
    /// this so the wait is legible.
    var manualBolusInFlight: Bool {
        manualBolusLock.lock(); defer { manualBolusLock.unlock() }; return _manualBolusInFlight
    }
    /// When the in-flight bolus started, so the glance can escalate "delivering…" to an
    /// explanation once the wait stops looking normal. Nil when nothing is in flight.
    var manualBolusStartedAt: Date? {
        manualBolusLock.lock(); defer { manualBolusLock.unlock() }
        return _manualBolusInFlight ? _manualBolusStartedAt : nil
    }
    private var _manualBolusStartedAt: Date?
    /// The amount being attempted, so the glance can NAME it during the pre-acceptance
    /// wait ("starting 0.90 U…") instead of describing our plumbing ("reaching pod…").
    private var _manualBolusPendingUnits: Double?
    var manualBolusPendingUnits: Double? {
        manualBolusLock.lock(); defer { manualBolusLock.unlock() }
        return _manualBolusInFlight ? _manualBolusPendingUnits : nil
    }
    fileprivate func setManualBolusInFlight(_ inFlight: Bool, units: Double? = nil) {
        manualBolusLock.lock()
        _manualBolusInFlight = inFlight
        _manualBolusStartedAt = inFlight ? self.now() : nil
        _manualBolusPendingUnits = inFlight ? units : nil
        manualBolusLock.unlock()
    }

    /// DELIVERY WINDOW — the half of a manual bolus that is otherwise invisible.
    ///
    /// `manualBolusInFlight` ends at ACCEPTANCE (the pod acking the command), ~1.2s in.
    /// The pod then spends ~1.5 U/min actually pushing the dose — 36s for 0.90 U —
    /// with nothing on the wrist, which is exactly where stock's PHONE starts narrating
    /// ("Bolused X of Y U" + ring, StatusTableViewController). docs/BOLUS_ANNOUNCEMENT.md.
    ///
    /// Same contract as stock's PodDoseProgressEstimator: an ESTIMATE from the dose's own dates
    /// (`elapsed / duration`), the pod is never queried, no radio is spent. The rate we book
    /// (1.5 U/min, `:deliverBolus`) IS `Pod.bolusDeliveryRate` — 0.05 U per 2s — so the same
    /// arithmetic stock uses on the phone applies here unchanged.
    private var _manualBolusDelivery: (units: Double, startedAt: Date, endsAt: Date)?
    /// nil once the estimated window has elapsed, so the glance clears itself with no timer.
    var manualBolusDelivery: (units: Double, startedAt: Date, endsAt: Date)? {
        manualBolusLock.lock(); defer { manualBolusLock.unlock() }
        guard let d = _manualBolusDelivery, d.endsAt > self.now() else { return nil }
        return d
    }
    fileprivate func setManualBolusDelivering(units: Double, from startedAt: Date, to endsAt: Date) {
        manualBolusLock.lock()
        _manualBolusDelivery = (units: units, startedAt: startedAt, endsAt: endsAt)
        manualBolusLock.unlock()
    }

    var reclaimPodForDose: ((@escaping (Bool) -> Void) -> Void)? {
        get { doseEnactor.reclaimPodForDose }
        set { doseEnactor.reclaimPodForDose = newValue }
    }
    var releasePodAfterDose: (() -> Void)? {
        get { doseEnactor.releasePodAfterDose }
        set { doseEnactor.releasePodAfterDose = newValue }
    }

    /// Per-session watch-local closed-loop opt-in. Each loan
    /// starts OPEN (advisory — the loop computes and drives the glance display but does
    /// NOT enact); the user deliberately closes the loop from the glance screen.
    /// RULED: the watch is SOVEREIGN once a loan is
    /// granted — the phone's own loop mode does NOT gate the wrist's per-session close.
    /// Therapy settings (frozen in the grant) are the only dosing limits; never AND this
    /// with the phone's dosingEnabled — that produced an untappable dead control when
    /// the phone happened to run open loop. Read/written on the dataAccessQueue.
    private var _closedLoopEnabled = false
    var closedLoopEnabled: Bool {
        dataAccessQueue.sync { _closedLoopEnabled }
    }
    /// Lock-guarded mirror of `_closedLoopEnabled` for callers that MUST NOT block on
    /// `dataAccessQueue`. The loan controller's queue is one: a `sync` from there onto
    /// dataAccessQueue is the deadlock direction (apparent success at the crown, crash
    /// 0-40s later, no insulin delivered), and the hand-back offer is built on that queue.
    private let closedLoopMirrorLock = NSLock()
    private var _closedLoopMirror = false
    var closedLoopEnabledNonBlocking: Bool {
        closedLoopMirrorLock.lock()
        defer { closedLoopMirrorLock.unlock() }
        return _closedLoopMirror
    }

    /// Silent per-session reset, called at loan end. Loop mode is a PER-SESSION concept — the
    /// next grant re-asserts it from the phone's inheritance — so a "closed" left over from the
    /// previous session must not survive into the next one: with it stale, a grant inheriting
    /// OPEN reads as a closed→open transition and fires the temp cancel below during grant
    /// intake, aimed at a pod mid-takeover. (Today that shot goes wide — the pump is not wired
    /// yet at the inheritance call — but a race that merely misses is still a race.) No cancel
    /// here by construction: the session is over, there is no pod on the wrist to command.
    func resetClosedLoopForSessionEnd() {
        closedLoopMirrorLock.lock()
        _closedLoopMirror = false
        closedLoopMirrorLock.unlock()
        dataAccessQueue.async {
            self._closedLoopEnabled = false
        }
    }

    /// `reason` exists so the log distinguishes a wrist tap from the grant-inherited mode —
    /// otherwise every field log claims the user did it.
    func setClosedLoopEnabled(_ enabled: Bool, reason: String = "by user") {
        // Mirror synchronously so a hand-back offer built immediately after a wrist tap
        // carries the value the user just chose, not the one before it.
        closedLoopMirrorLock.lock()
        let wasEnabled = _closedLoopMirror
        _closedLoopMirror = enabled
        closedLoopMirrorLock.unlock()

        dataAccessQueue.async {
            self._closedLoopEnabled = enabled
            SportLog.event("loop", enabled ? "CLOSED \(reason) — the watch will adjust basal" : "OPENED \(reason) — advisory only, no dosing")

            // PUSH THE MODE TO THE STOCK SCREENS NOW, not at the end of the next loop cycle.
            //
            // The glance and the stock pages read the same underlying flag, but on different
            // clocks: the glance re-reads `glanceData()` every couple of seconds, while the stock
            // pages read `activeContext.isClosedLoop`, which only changes when publishHUDContext
            // runs — at cycle end, up to five minutes later. So a wrist tap moved the glance
            // immediately and left the stock pages showing the OLD mode, which reads as the two
            // screens disagreeing about whether the loop is closed.
            self.publishHUDContext()

            // Opening the loop CANCELS the running temp, exactly as the phone does — stock
            // subscribes to its automatic-dosing flag and cancels on every transition to off
            // (LoopDataManager, alongside clearing the pre-meal override). Without this the
            // wrist stopped issuing new temps but left the last one delivering for up to its
            // full 30 minutes, so "open loop" on the watch and on the phone meant different
            // amounts of insulin.
            //
            // Guarded on a REAL transition, which is what makes it safe at grant intake: a
            // loan that inherits an open loop calls this with the flag already false, and a
            // cancel there would fire at a pod the watch has only just taken over.
            //
            // Failure is logged, not escalated: the enactor answers `.pumpManagerUnconnected`
            // when there is no loan, and a cancel can only ever move toward LESS insulin, so a
            // failed one leaves the pod running the rate it already had until the temp expires
            // on its own.
            guard wasEnabled, !enabled else { return }
            let recommendation = AutomaticDoseRecommendation(basalAdjustment: .cancel, direction: .decrease)
            self.recommendedAutomaticDose = (recommendation: recommendation, date: self.now())
            if let error = self.enactRecommendedAutomaticDose() {
                SportLog.event("loop", "OPEN: temp cancel FAILED — \(String(describing: error)); the pod keeps its current rate until the temp expires")
            } else {
                SportLog.event("loop", "OPEN: running temp cancelled — pod reverts to the user's schedule")
            }
        }
    }

    // MARK: - Wrist-enacted overrides

    /// Apply an override the USER just selected on the wrist to this loan's DOSING settings.
    ///
    /// This is the whole watch-side mechanism: assigning `scheduleOverride` runs the
    /// didSet above, which records into the shared `overrideHistory` — and THAT is what
    /// rescales basal / ISF / carb ratio and invalidates the cached effects, so the very next
    /// cycle doses under the override. Nothing else is needed, and nothing here is conditional
    /// on the phone: the point of Sport Mode is that the phone is usually absent.
    ///
    /// QUEUE: called from the wrist UI (main). `settings` has exactly one other writer — grant
    /// intake on the loan controller's queue — and grants are refused unless the phase is
    /// idle/requested (PodLoanWatchController.handleGrant), i.e. never while a loan is active
    /// and the preset button is live. So the two writers cannot overlap. (The store setters the
    /// didSet drives are `Locked<>` and any-queue safe regardless.)
    ///
    /// TELEMETRY: `SET-ON-WRIST` is the user's intent; the didSet's `APPLIED` / `CLEARED` line
    /// that follows is the dosing manager confirming it took, with the resolved multipliers.
    /// Seeing intent without confirmation is the signature of a settings object that refused it.
    func applyWristOverride(_ override: TemporaryScheduleOverride?) {
        if let o = override {
            let target = o.settings.targetRange.map {
                String(format: "%.0f-%.0f", $0.lowerBound.doubleValue(for: .milligramsPerDeciliter),
                       $0.upperBound.doubleValue(for: .milligramsPerDeciliter))
            } ?? "unchanged"
            SportLog.event("override", String(format: "SET-ON-WRIST %@ · insulin needs %.0f%% · target %@ · ends %@ · sync %@",
                                              o.context.presetNameForLog,
                                              o.settings.effectiveInsulinNeedsScaleFactor * 100,
                                              target,
                                              o.duration.isInfinite ? "indefinite" : ISO8601DateFormatter().string(from: o.scheduledInterval.end),
                                              o.syncIdentifier.uuidString))
        } else {
            SportLog.event("override", "SET-ON-WRIST · CLEARED by user — the loan's schedules resolve unscaled from here")
        }
        scheduleOverride = override
    }

    // MARK: - Glance surface (display only — no dosing paths read this)

    /// The prediction components for the diagnostic screen — insulin, carbs, momentum,
    /// retrospection — as one line with an arithmetic reconciliation to the eventual BG.
    /// DISPLAY + LOGGING ONLY — nothing here is read by any dosing path.
    ///
    /// An EXACT decomposition of `eventual − start`, produced by mirroring
    /// `LoopMath.predictGlucose`'s OWN accounting (LoopKit/LoopMath.swift:118-175) rather than
    /// by differencing the stored effect arrays. Two things make the naive difference fail to
    /// add up, and both are handled here:
    ///   1. ANCHOR. `[predict]`'s `net()` (:824) anchors at the last effect entry with
    ///      `startDate <= now()`; `LoopMath` anchors every timeline at the STARTING GLUCOSE's
    ///      date and only applies deltas at dates strictly greater than it (LoopMath.swift:163).
    ///      We anchor where the prediction anchors.
    ///   2. MOMENTUM BLEND. `LoopMath` does not ADD momentum to the summed effects — inside the
    ///      blend window it REPLACES them: `slot = (1 − split)·slot + split·Δmomentum`
    ///      (LoopMath.swift:132-160). Differencing the arrays double-counts the suppressed
    ///      slice. We apply the same (1 − split) scaling PER SOURCE, so the four terms are
    ///      shares of exactly the arithmetic the prediction ran.
    ///
    /// `residualMgdl` is therefore ~0 BY CONSTRUCTION. It is still carried and still rendered:
    /// a non-zero residual means this mirror has drifted from `LoopMath`, or `predictedGlucose`
    /// was built from a different glucose sample than the one we anchored on — which is exactly
    /// the kind of thing worth showing rather than silently forcing the row to close.
    struct PredictionBreakdown {
        /// The prediction's own anchor: `glucoseStore.latestGlucose`, mg/dL.
        let startMgdl: Double
        /// `predictedGlucose.last` — the same number the `eventual` row shows, mg/dL.
        let eventualMgdl: Double
        let insulinMgdl: Double
        let carbMgdl: Double
        let momentumMgdl: Double
        let retrospectiveMgdl: Double
        /// eventual − (start + the four terms). ~0 unless this mirror has drifted.
        let residualMgdl: Double
        /// The insulin tail BEFORE the momentum blend: `last − value(at-or-before now)` of
        /// `insulinEffect`, the same quantity `[predict]` prints. This — not `insulinMgdl` — is
        /// what the −ISF × IOB invariant applies to.
        ///
        /// `insulinMgdl` above is BLENDED. `LoopMath.predictGlucose` (LoopKit LoopMath.swift:148-159,
        /// byte-identical to upstream/dev) scales the SUMMED effect delta at each early slot by
        /// `(1 − split)` while fading momentum in, so it attenuates insulin, carbs and RC together
        /// for the first few bins after the last reading. That is momentum doing its job — the
        /// observed trend outranks the model in the near term — and it makes `insulinMgdl`
        /// legitimately smaller in magnitude than −ISF × IOB whenever momentum exists.
        let insulinRawTailMgdl: Double?
        /// −ISF × IOB. Compare against `insulinRawTailMgdl`, NEVER against `insulinMgdl`.
        ///
        /// Comparing it against the BLENDED term instead manufactures a false "GAP".
        /// Note also that this quantity is NOT expected to match exactly when a temp is running:
        /// `insulinOnBoard` counts the temp's full remaining programmed delivery while
        /// `glucoseEffects` trims at `basalDosingEnd = now()`. Stock does the same — measured on
        /// the phone's own issue report: IOB 2.5954 U against an insulinEffect tail
        /// of −124.02 mg/dL at ISF 70, a 0.82 U difference, which was exactly the 15 minutes
        /// still to run on a 4.5 U/hr temp. So a residual here is expected; a term that does not
        /// TRACK IOB at all is the real alarm.
        let insulinExpectedMgdl: Double?
        let isfMgdlPerU: Double?
        let iobUnits: Double?
        let momentumPointCount: Int
        let computedAt: Date

        /// Shared rounding for the reconciliation row: the wrist and `[predict-recon]` render
        /// the SAME integers, so the logged line is literally the line on the watch. Collapses
        /// `-0.0` (which "%+.0f" would print as "-0") and never lets a non-finite term through.
        static func round0(_ v: Double) -> Double {
            guard v.isFinite else { return 0 }
            let x = v.rounded()
            return x == 0 ? 0 : x
        }
    }

    struct GlanceData {
        let glucose: LoopQuantity?
        let glucoseDate: Date?
        /// OPTION C (Jeremy 2026-08-05): when each SOURCE last delivered a reading — the
        /// direct G7 link's own health, independent of which copy won the store.
        ///
        /// `dropAlreadyStored` is first-writer-wins, and the phone's relay lands ~7s ahead of
        /// the direct read, so with the phone nearby the STORED row is the phone's and the
        /// direct read is discarded as a duplicate. Labelling the stored row would therefore
        /// read "phone" almost always and tell Jeremy nothing about the thing he actually wants
        /// to know: is the watch standing on its own right now? So stamp direct-G7 on ARRIVAL,
        /// whether or not its copy was kept.
        let directG7At: Date?
        let phoneRelayAt: Date?
        let trend: GlucoseTrend?
        let eventual: LoopQuantity?
        let iob: Double?
        /// nil = no temp running (pod on schedule).
        let tempRate: Double?
        let lastLoopCompleted: Date?
        let suspendThreshold: LoopQuantity?
        let closedLoopEnabled: Bool
        /// The phone-frozen dosing permission: when false the watch CANNOT close the
        /// loop (the phone had Closed Loop off at grant).
        let dosingAllowedByPhone: Bool
        /// Dosing observability (display-only): the temp DoseMath recommends THIS
        /// cycle (nil = none), vs `tempRate` (what the pod is actually running) — the
        /// gap between them is the "is it enacting?" tell. `lastLoopErrorText` is the
        /// last cycle's error (nil = clean), so a stalled/erroring loop is visible.
        let recommendedTempRate: Double?
        let lastLoopErrorText: String?
        /// Display-only: last cycle's exact prediction decomposition (nil until the first
        /// successful prediction of the session). Cached at cycle end — NEVER computed here.
        let predictionBreakdown: PredictionBreakdown?
        /// Which retrospective-correction model is actually running,
        /// and how much data it has. The watch adopts the PHONE's Integral toggle from the grant
        /// (PodLoanWatchController:431), so this is the readout that proves the two devices are
        /// predicting with the same algorithm. It was only
        /// ever visible in the log line `[rc] type=… · discrepancies=…`; on the wrist there was
        /// no way to tell Integral from Standard while looking at a suspicious eventual.
        let retrospectiveCorrectionIsIntegral: Bool
        let retrospectiveDiscrepancyCount: Int
        /// Active override, as "<symbol> <name>". The glance shows
        /// this in the top row: an override silently rescales ISF AND the basal baseline, so a
        /// number on this screen means something different depending on it. nil = none active.
        let overrideLabel: String?
    }


    /// The temp basal the pod is running, as best the watch can know it — the live
    /// `basalDeliveryState` while the pod is connected, otherwise the temp we last enacted
    /// until its programmed end. The link is released between doses, so `basalDeliveryState`
    /// goes nil within seconds even though the pod keeps delivering. Read on `dataAccessQueue`.
    /// Hand-back half: is a LOOP temp still executing on the pod right now? The loan
    /// controller needs this at hand-back and cannot ask `basalDeliveryState`, because the
    /// link is orphaned by then and that state reads nil — which is exactly why the
    /// DESIGN-5 cancel in finalizeHandback had been silently dead (no pod
    /// command at all between "drain complete" and the release, at both hand-backs).
    /// Thread-safe by hopping the data queue; nil when nothing is running.
    func runningTempBasalForHandback() -> DoseEntry? {
        return dataAccessQueue.sync { self.runningTempBasal() }
    }

    func runningTempBasal() -> DoseEntry? {
        if case .some(.tempBasal(let dose)) = pumpManager?.status.basalDeliveryState {
            return dose
        }
        if let cached = cachedEnactedTempBasal, cached.endDate > now() {
            return cached
        }
        return nil
    }

    // MARK: - Glance mirror (main must never wait on dataAccessQueue)

    /// The glance must NEVER read `dataAccessQueue` from main. That queue is held for the whole
    /// of a dose cycle, and `enactRecommendedAutomaticDose` polls the radio arbiter for up to 15 s
    /// (:2527) before giving up — so a `dataAccessQueue.sync` on a 2 s UI timer freezes the entire
    /// interface for as long as any cycle waits out the G7 handshake, ~16 s in the worst measured
    /// case. Almost all of that is the radio wait, not compute.
    ///
    /// Same remedy PodLoanWatchController applies to the loan/pump queue
    /// (`refreshDebugSnapshot`/`mirroredDebugSnapshot`): publish a mirror FROM the queue, read the
    /// mirror ON main, never block.
    private let glanceMirrorLock = NSLock()
    private var _glanceMirror: GlanceData?
    private var _glanceRefreshPending = false

    /// Main-safe: never touches `dataAccessQueue`. Nil only before the first refresh completes.
    var mirroredGlanceData: GlanceData? {
        glanceMirrorLock.lock()
        defer { glanceMirrorLock.unlock() }
        return _glanceMirror
    }

    /// Ask for a fresh mirror. Returns immediately; the work lands on `dataAccessQueue` behind
    /// whatever cycle is in flight, which is exactly the wait we refuse to make main sit through.
    func refreshGlanceData() {
        // Coalesce. The glance asks every 2s; if the queue is held for 16s that would pile up
        // eight identical rebuilds to run back-to-back the instant it frees. Only the last one
        // would survive anyway — the mirror is latest-wins — so never queue a second.
        glanceMirrorLock.lock()
        if _glanceRefreshPending { glanceMirrorLock.unlock(); return }
        _glanceRefreshPending = true
        glanceMirrorLock.unlock()

        dataAccessQueue.async { [weak self] in
            guard let self = self else { return }
            let data = self.buildGlanceData()
            self.glanceMirrorLock.lock()
            self._glanceMirror = data
            self._glanceRefreshPending = false
            self.glanceMirrorLock.unlock()
            // TELL THE GLANCE IT LANDED (field 2026-08-07: "raising the wrist shows stale BG for
            // half a second before refreshing"). The caller reads `mirroredGlanceData` on the line
            // AFTER kicking this off, so without a signal it always renders the PREVIOUS mirror —
            // one tick stale by construction, and on a wrist-raise as stale as whatever was
            // published before the screen slept (14 minutes, observed 2026-08-06).
            //
            // This is the async price of the freeze fix: reading the mirror instead of blocking on
            // dataAccessQueue stopped a 16s frozen watch, but turned the read into read-then-refresh.
            // Posting on arrival makes it refresh-then-read without giving the block back.
            NotificationCenter.default.post(name: Self.glanceMirrorDidUpdate, object: nil)
        }
    }

    /// Fires on the main queue's notification centre whenever a fresh glance mirror is published.
    static let glanceMirrorDidUpdate = Notification.Name("com.loopkit.Loop.glanceMirrorDidUpdate")

    /// Synchronous snapshot. Kept for the DEBUG page, which is not an always-on surface and can
    /// afford to wait. The glance must use the mirror above.
    func glanceData() -> GlanceData {
        return dataAccessQueue.sync { self.buildGlanceData() }
    }

    /// MUST be called on `dataAccessQueue` — reads queue-confined state.
    private func buildGlanceData() -> GlanceData {
            let latest = glucoseStore.latestGlucose
            var tempRate: Double?
            if let dose = runningTempBasal() {
                // Show NET (temp − scheduled), matching stock's net-basal convention and
                // publishHUDContext (:324). The glance renders this with a forced sign
                // ("%+.2f"), so net makes it meaningful: + above schedule, − a reduction,
                // 0 at schedule. (Was the ABSOLUTE rate, so a low-temp rendered as a
                // meaningless "+0.00" that read as "no action".)
                //
                // Net against the OVERRIDE-APPLIED schedule, not the raw one.
                // Netting against raw 0.70 under a 60% override rendered "+0.00" while the pod ran
                // 1.67x the override's intended basal, which reads as "not low-temping". Under the
                // override a suspend is −0.42 and raw-schedule is +0.28,
                // and the wrist must say so. Same fix, same accessor as the DoseMath guards.
                let scheduled = (basalRateScheduleApplyingOverrideHistory ?? settings.basalRateSchedule)?.value(at: now()) ?? 0
                tempRate = dose.unitsPerHour - scheduled
            }
            let sources = self.lastGlucoseSourceStamps
            // IOB evaluated at `now()` instead of read from the loop's cache. `insulinOnBoard`
            // is written only by updateCachedEffects, which runs only inside a loop cycle — and
            // loop() is CGM-triggered (:2523), so a sensor dropout stops IOB recomputation
            // outright. In the field the rail held a flat 1.13 U for 28 minutes across a
            // G7 outage and then fell 0.53 in one step when readings resumed, which reads as an
            // insulin EVENT rather than as the arithmetic catching up.
            //
            // Unlike the prediction — which is deliberately MARKED stale rather than blanked,
            // because it genuinely cannot be recomputed without glucose — IOB is a pure function
            // of the dose timeline and the clock. So the honest fix is to evaluate it, not to
            // gate it: stock's HUD blanks stale insulin (ChartHUDController:165) because its
            // value arrives in a context it cannot recompute; the watch owns the timeline and
            // can. Same on-demand shape as glanceCarbsOnBoard — which is exactly why COB kept
            // decaying through that same outage while IOB sat still. Pre-cutover, or before the
            // ledger is seeded, the cached value remains the only source.
            let liveIOB: Double? = basalRateScheduleApplyingOverrideHistory.flatMap { sched in
                sessionLedger?.insulinOnBoard(at: now(), basalSchedule: sched)
            } ?? activeInsulin
            return GlanceData(
                glucose: latest?.quantity,
                glucoseDate: latest?.startDate,
                directG7At: sources.direct,
                phoneRelayAt: sources.phone,
                trend: (latest as? StoredGlucoseSample)?.trend,
                // Keep the eventual VISIBLE; the glance grades its
                // freshness (fresh/aging/stale on the loop dot — stock's HUDInterfaceController
                // convention) rather than BLANKING it. A binary gate that hid the number when
                // cycles failed reads as "no prediction," which is its own lie.
                // `lastLoopCompleted` is already in GlanceData, so activeState MARKS a stale
                // prediction instead of dropping it — a stale eventual stays shown while the
                // dot goes amber→red, so it never looks authoritative once old.
                // The pending-inclusive curve, matching the phone's "Eventually" — which reads
                // the same one. The dosing curve stamped just below credits nothing for a temp
                // the instant it is enacted, so the wrist and the phone disagreed by ISF times
                // the net remaining span: measured in the field at 493 on the phone against
                // ~490 on the wrist within a minute of a net -3.3 U/hr enact. Dosing is
                // unaffected — DoseMath consumes the no-pending curve, deliberately.
                // `predictedGlucose` — the curve the algorithm actually produced, and the same
                // one the phone displays as "Eventually" (StatusTableViewController assigns
                // `state.output?.predictedGlucose` with no adjustment).
                //
                // This previously read a pending-inclusive variant that, on THIS architecture, is
                // never assigned by anything: that curve was a concept of the older Loop the fork
                // was built on, and next-dev's LoopAlgorithm produces no such thing — only some
                // error cases still carry the name. So the glance's eventual was nil on every
                // cycle since the port, which is why the wrist showed no forecast while the log
                // printed one every five minutes.
                eventual: predictedGlucose?.last?.quantity,
                iob: liveIOB,
                tempRate: tempRate,
                lastLoopCompleted: lastLoopCompleted,
                suspendThreshold: settings.suspendThreshold?.quantity,
                closedLoopEnabled: _closedLoopEnabled,
                dosingAllowedByPhone: settings.dosingEnabled,
                // Read the SNAPSHOT, not the live property: a successful enact nils
                // `recommendedAutomaticDose` (:889/:1081), so in closed loop the panel's
                // recommend row was blank essentially always — it showed "no recommendation"
                // when the truth was "erased before you could see it". Same defect 148 fixed
                // for the log line; the panel was still reading the live value (field
                // 2026-07-22: eventual ~200 with a blank recommend).
                recommendedTempRate: lastRecommendation?.basalAdjustment.unitsPerHour,
                lastLoopErrorText: lastLoopError.map { String(describing: $0) },
                // READ the cached value. Computing it here would run a full per-source
                // replay of LoopMath on the MAIN thread every 2 s (this whole closure is
                // `dataAccessQueue.sync` from the debug page's timer) — cache at cycle end,
                // read at render.
                predictionBreakdown: lastPredictionBreakdown,
                // Same queue as the rest of this closure, so these are consistent with the
                // prediction being rendered rather than a torn read from another cycle.
                retrospectiveCorrectionIsIntegral: retrospectiveCorrection is IntegralRetrospectiveCorrection,
                retrospectiveDiscrepancyCount: lastAlgorithmEffects?.retrospectiveGlucoseDiscrepancies.count ?? 0,
                overrideLabel: {
                    guard let o = scheduleOverride, o.isActive() else { return nil }
                    return o.context.presetNameForLog
                }())
    }

    /// COB for the glance rail (async — the store computes it).
    ///
    /// Passes `effectVelocities` exactly as the phone does (LoopDataManager:1110). The port
    /// omitted them, so COB was computed with STATIC absorption while `carbEffect` — the
    /// thing actually feeding the prediction — uses dynamic/ICE-informed absorption. Flagged
    /// in the 2026-07-22 stock-call audit as a minor display divergence; it is not minor.
    /// Field: 15 g entered on the wrist moved `eventual` correctly while COB read a hard 0,
    /// which reads as "the loop lost my carbs" next to a prediction that plainly did not.
    func glanceCarbsOnBoard(_ completion: @escaping (Double?) -> Void) {
        // The velocities read was `dataAccessQueue.sync` ON THE CALLER — i.e. on MAIN, every 2s,
        // behind whatever cycle held the queue. That is the second half of the freeze the mirror
        // above fixes, and it is the one that actually proved it: `latestCOB` is written from this
        // callback on every tick, and its value did not change for 17.0s / ~8 ticks after the carbs
        // were in the store (build 237, 23:41:47.583 -> 23:42:04.58). An already-completion-based
        // API has no reason to block its caller at all.
        dataAccessQueue.async { [weak self] in
            // Straight off the last algorithm run rather than a fresh store query: the run
            // already computed absorption from the same doses and readings the forecast used,
            // so this cannot drift from what the wrist is dosing against.
            completion(self?.activeCarbs)
        }
    }

    /// Feed the STOCK watch screens (ChartHUDController rows: IOB, COB, net temp
    /// basal; loop-age via loopLastRunDate) during a loan. The phone stops sending
    /// fresh WatchContext while the pod is on the wrist — it cannot know what the
    /// watch has dosed — so those rows sat blank all sport session. The watch loop
    /// is the ground truth here: synthesize a context from local state after each
    /// cycle and push it through the same updateContext path a phone context uses.
    /// No glucoseSyncIdentifier is set, so WatchContext.newGlucoseSample stays nil
    /// and updateContext writes nothing to the HUD's glucose store (the sport
    /// store's single-writer invariant is untouched; glucose fields here are
    /// display-only). shouldReplace is glucoseDate recency — after hand-back the
    /// phone's fresher contexts win the screens back naturally.
    private func publishHUDContext() {   // dataAccessQueue
        guard pumpManager != nil else { return }   // loan active only — otherwise the phone owns the HUD
        let ctx = WatchContext()
        ctx.isWatchAuthored = true   // Outranks the phone's relay of the same reading
        // The stock chart's prediction line reads context.predictedGlucose and was never
        // populated here, so it sat empty for the whole loan.
        ctx.predictedGlucose = predictedGlucose.flatMap { WatchPredictedGlucose(values: $0) }
        let latest = glucoseStore.latestGlucose
        ctx.glucose = latest?.quantity
        ctx.glucoseDate = latest?.startDate
        ctx.glucoseTrend = (latest as? StoredGlucoseSample)?.trend
        ctx.iob = activeInsulin
        ctx.loopLastRunDate = lastLoopCompleted
        ctx.isClosedLoop = _closedLoopEnabled
        if let dose = runningTempBasal() {
            // Override-applied schedule, matching the glance fix above.
            let scheduled = (basalRateScheduleApplyingOverrideHistory ?? settings.basalRateSchedule)?.value(at: now()) ?? 0
            ctx.lastNetTempBasalDose = dose.unitsPerHour - scheduled
            ctx.lastNetTempBasalDate = dose.startDate
        } else {
            ctx.lastNetTempBasalDose = 0
            ctx.lastNetTempBasalDate = now()
        }
        // Same dynamic-absorption argument as the phone (:1110) — already on dataAccessQueue
        // here, so read the velocities directly.
        // Active carbs come off the same algorithm run the dose was decided from, so the HUD
        // cannot disagree with the forecast it is displayed beside.
        do {
            if let cob = activeCarbs {
                ctx.cob = cob
                // Per-cycle COB trace, so seeded/loan COB is verifiable through the loan.
                if cob > 0.05 { SportLog.event("loop", String(format: "COB %.1f g on board", cob)) }
            }
            DispatchQueue.main.async {
                guard let loopDataManager = ExtensionDelegate.sharedIfAvailable()?.loopManager else { return }
                ctx.displayGlucoseUnit = loopDataManager.activeContext?.displayGlucoseUnit ?? ctx.displayGlucoseUnit
                loopDataManager.updateContext(ctx)
                NotificationCenter.default.post(name: LoopDataManager.didUpdateContextNotification, object: loopDataManager)
            }
            // The stock carb/bolus flow reads context.recommendedBolusDose, which only the
            // phone ever set — hence a blank recommendation for the whole loan. Fill it from the
            // watch's own DoseMath.
            //
            // Deliberately AFTER the install, not before: a recommendation can legitimately fail
            // (missing momentum/carb/insulin effect early in a session) and blocking the context
            // on it would take the entire HUD down with it. ctx is a class, so mutating it
            // updates what the UI already holds; re-post so the flow picks it up.
            self.recommendManualBolus { result in
                switch result {
                case .success(let recommendation):
                    // The stock flow renders this as "REC: N U" under the dial (BolusInput :67).
                    SportLog.event("loan", String(format: "REC bolus %.2f U — published to the stock bolus flow", recommendation.amount))
                    DispatchQueue.main.async {
                        ctx.recommendedBolusDose = recommendation.amount
                        guard let loopDataManager = ExtensionDelegate.sharedIfAvailable()?.loopManager else { return }
                        NotificationCenter.default.post(name: LoopDataManager.didUpdateContextNotification, object: loopDataManager)
                    }
                case .failure(let error):
                    // Was `guard case .success ... else { return }` — silent. Field 2026-08-05:
                    // Jeremy saw no recommendation and there was no way to tell whether it had
                    // failed, or was legitimately zero, or never ran. A diagnostic that cannot
                    // distinguish those is the same gap the G7 observer had.
                    SportLog.event("loan", "REC bolus UNAVAILABLE — \(error) (the flow will show 'REC: – U')")
                }
            }
        }
    }

    // MARK: The CGM input (stock G7CGMManager over the proven transport — M3)

    /// Held so the stack has an owner; delegate wiring happens in StockLoopStack.assemble().

    // MARK: Queues (mirrors the phone's DeviceDataManager.queue / LoopDataManager.dataAccessQueue split)

    /// Device-facing events (CGM delegate callbacks). The G7CGMManager's `delegateQueue`.
    let deviceQueue = DispatchQueue(label: "com.loopkit.Loop.WatchLoopManager.deviceQueue", qos: .utility)

    /// Loop state. All cached effects and recommendation state are confined to this queue.
    private let dataAccessQueue = DispatchQueue(label: "com.loopkit.Loop.WatchLoopManager.dataAccessQueue", qos: .utility)

    private let log = OSLog(category: "WatchLoopManager")

    /// Test seam, same shape as the phone's `now()`.
    ///
    /// Item 2 (2026-08-11): propagates to the dose enactor, which keeps its own clock
    /// (separate type, can't reach this one). Without the didSet, a test that set this
    /// would still get wall-clock timestamps on every dose the enactor records into the
    /// ledger — the exact values such a test is usually asserting on.
    var now: () -> Date = { Date() } {
        didSet { doseEnactor.now = now }
    }

    /// Item 2 companion seam: bench flags and persisted CGM state read/write through this,
    /// so a test can hand in a scratch suite instead of the host app's real defaults.
    var defaults: UserDefaults = .standard

    init(doseStore: DoseStore, glucoseStore: GlucoseStore, carbStore: CarbStore,
         overrideHistory: TemporaryScheduleOverrideHistory = TemporaryScheduleOverrideHistory(),
         settings: LoopSettings = LoopSettings()) {
        self.doseStore = doseStore
        self.glucoseStore = glucoseStore
        self.carbStore = carbStore
        self.settingsProvider = WatchSettingsProvider(settings: settings)
        self.overrideHistory = overrideHistory
        self.settings = settings
        // Cache each accepted temp so runningTempBasal() can report what the pod is
        // running while the link is orphaned (basalDeliveryState is nil then). Built here so the
        // DoseEntry uses this manager's testable clock; the cache is dataAccessQueue-isolated.
        // Shadow ledger: enactor-accepted doses flow into the session timeline.
        doseEnactor.ledgerRecord = { [weak self] dose in self?.ledgerRecordEnact(dose) }
        doseEnactor.onTempBasalEnacted = { [weak self] unitsPerHour, duration in
            guard let self = self else { return }
            let start = self.now()
            let enacted = DoseEntry(type: .tempBasal, startDate: start, endDate: start.addingTimeInterval(duration), value: unitsPerHour, unit: .unitsPerHour, decisionId: nil)
            self.dataAccessQueue.async { self.cachedEnactedTempBasal = enacted }
        }
        #if !targetEnvironment(simulator)
        // Phone-BG fallback. Every phone context update, during a loan, mirror the phone's
        // relayed CGM into the DOSING store (device only; the simulator drives it via the
        // simStartGlucoseFeed timer instead, to avoid a synthetic-vs-real syncId double-ingest).
        NotificationCenter.default.addObserver(forName: LoopDataManager.didUpdateContextNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.ingestPhoneGlucoseFromContext()
        }
        #endif
    }

    /// Last-seen adapter delivery count, for producer attribution on the INGEST line. Touched only
    /// on the CGM delegate queue (processCGMReadingResult), so no lock of its own.

    private let bgSourceLock = NSLock()
    private var _lastDirectG7At: Date?
    private var _lastPhoneRelayAt: Date?
    /// Last sensorID written by cgmManagerDidUpdateState (extension can't hold
    /// storage) — the persist itself runs every state change; this only rate-limits the log line.
    var lastPersistedSensorID: String?
    private func noteGlucoseSource(directG7: Bool) {
        bgSourceLock.lock()
        if directG7 { _lastDirectG7At = self.now() } else { _lastPhoneRelayAt = self.now() }
        bgSourceLock.unlock()
    }

    /// The grant seed counts as the PHONE. (Jeremy, 2026-08-05: "treat the seed as the same as
    /// phone source — in the end, that's what's actually true.") Those samples were carried in the
    /// grant out of the phone's own glucose store, so "via iPhone" IS their provenance; a separate
    /// third label would have named the transport rather than the source.
    ///
    /// Without this the provenance line went BLANK for the first minutes of every loan. The seed
    /// stamped nothing, the G7 had stood down to give the pod the radio for the takeover, and the
    /// relay was off because the watch now owns the pod — so `bgSource` fell to `.none` while a
    /// real number sat on screen. The `.none` arm's own comment ("first cycle after launch") shows
    /// the takeover case was never considered. Field 2026-08-05: on-wrist immediately after a
    /// takeover, BG 116 displayed with no source at all.
    ///
    /// Safe from any queue: `noteGlucoseSource` is guarded by `bgSourceLock`, not by
    /// `dataAccessQueue`, so the loan controller can call this from its own serial queue.
    func notePhoneGlucoseDelivered() {
        noteGlucoseSource(directG7: false)
    }
    private var lastGlucoseSourceStamps: (direct: Date?, phone: Date?) {
        bgSourceLock.lock(); defer { bgSourceLock.unlock() }
        return (_lastDirectG7At, _lastPhoneRelayAt)
    }
    /// The last cycle's binding-constraint summary, for the diagnostic screen. Our screen
    /// only — never annotated onto a stock surface (the stock-parity ruling).
    private(set) var lastDosingDerivation: String?

    // MARK: - Override-applied schedules (stock parity)
    //
    // Copied verbatim from LoopDataManager :561-573, including WHICH STORE each one reads.
    // The split looks arbitrary and isn't ours to redesign: DoseStoreProtocol exposes only
    // the basal accessor, CarbStoreProtocol exposes ISF and carb ratio. Both stores are handed
    // the SAME TemporaryScheduleOverrideHistory instance (StockLoopStack :122 -> :131, :148 —
    // verified shared, a public final class), so either store resolves to the same answer;
    // matching the phone's choice keeps a future reader from having to re-derive that.
    //
    // WHY THESE EXIST AT ALL. The watch had no manager-level accessor and instead inlined
    // `doseStore.<accessor> ?? settings.<raw>` at seven call sites — our own dialect, with a
    // fallback the phone does not have anywhere. That dialect is how a real defect got in: the
    // manual-bolus path simply read `settings.insulinSensitivitySchedule` and nobody noticed it
    // was the odd one out, because there was no single place where "the schedule dosing uses"
    // was defined. One accessor per schedule, used everywhere, makes the next omission visible.

    /// The basal rate schedule, applying recent overrides relative to the current moment in time.
    var basalRateScheduleApplyingOverrideHistory: BasalRateSchedule? {
        settings.basalRateSchedule.map { overrideHistory.resolvingRecentBasalSchedule($0) }
    }

    /// The carb ratio schedule, applying recent overrides relative to the current moment in time.
    var carbRatioScheduleApplyingOverrideHistory: CarbRatioSchedule? {
        settings.carbRatioSchedule.map { overrideHistory.resolvingRecentCarbRatioSchedule($0) }
    }

    /// The insulin sensitivity schedule, applying recent overrides relative to the current moment in time.
    var insulinSensitivityScheduleApplyingOverrideHistory: InsulinSensitivitySchedule? {
        settings.insulinSensitivitySchedule.map { overrideHistory.resolvingRecentInsulinSensitivitySchedule($0) }
    }

    /// Refuse loudly, once per distinct reason — not once per glance tick, and never by
    /// silently switching the dosing source; that silent switch is banned outright.
    private func logLedgerRefusal(_ what: String) {
        let reason = "\(what): ledger=\(sessionLedger != nil ? "ok" : "NIL") isf=\(insulinSensitivityScheduleApplyingOverrideHistory != nil ? "ok" : "NIL") basal=\(basalRateScheduleApplyingOverrideHistory != nil ? "ok" : "NIL")"
        guard reason != lastLedgerRefusalLogged else { return }
        lastLedgerRefusalLogged = reason
        SportLog.event("ledger", "REFUSED \(reason) — R35: no store fallback; the cycle fails loudly")
    }

    /// The pump-data recency clock, owned directly. It must never be `doseStore.lastAddedPumpData`,
    /// which advanced as a side effect of writing dose rows into a store that never persists
    /// them. Same lock idiom as the glucose source stamps.
    private let pumpDataLock = NSLock()
    private var _lastPumpDataDate: Date?
    var lastPumpDataDate: Date? {
        pumpDataLock.lock(); defer { pumpDataLock.unlock() }
        return _lastPumpDataDate
    }
    func notePumpDataReceived(at date: Date) {
        pumpDataLock.lock(); defer { pumpDataLock.unlock() }
        if (_lastPumpDataDate ?? .distantPast) < date { _lastPumpDataDate = date }
    }

    /// The temp basal we last successfully enacted, cached so the watch knows what the
    /// pod is running without querying it. The pod link is orphaned after each dose, so
    /// `pumpManager.status.basalDeliveryState` reverts to nil within seconds even though the
    /// pod keeps delivering the accepted temp for its full programmed duration. dataAccessQueue.
    private var cachedEnactedTempBasal: DoseEntry?
    private var retrospectiveGlucoseEffect: [GlucoseEffect] = []

    /// Mirrors LoopDataManager's buffer multiplier for combining retrospective discrepancies.

    /// Selected from the loan grant so the watch runs the SAME implementation the phone
    /// would (`LoopDataManager.retrospectiveCorrection:457`). Frozen for the loan like the
    /// therapy settings — the phone's re-selection-on-toggle-change has no analog here
    /// because the flag cannot change mid-loan. Defaults to Standard, which is both the
    /// pre-existing behavior and what a grant from a phone that doesn't send the flag
    /// implies. Both implementations compile here (LoopKit watchOS target, M4).
    private var retrospectiveCorrection: RetrospectiveCorrection = StandardRetrospectiveCorrection(effectDuration: LoopMath.retrospectiveCorrectionEffectDuration)

    /// Apply the granted RC mode. Hops to dataAccessQueue because
    /// `retrospectiveCorrection` is read there (updateRetrospectiveGlucoseEffect,
    /// predictGlucose) — the grant lands on the loan controller's queue.
    ///
    /// Ordering guarantee (UX: the first loan prediction must NOT use Standard and then jump
    /// to Integral once IRC lands): this async runs on the SAME serial dataAccessQueue as
    /// every prediction, and it is enqueued at grant intake (PodLoanWatchController:389) —
    /// before the takeover-complete refreshPredictionForGlance (:499) and before any loop
    /// cycle. Nothing runs a loan prediction in between (the takeover read-loop only reads pod
    /// status). FIFO on the serial queue therefore guarantees the RC type is set before the
    /// first prediction reads it. See docs/PREDICTION_FIDELITY.md.
    func setIntegralRetrospectiveCorrection(_ enabled: Bool) {
        dataAccessQueue.async {
            self.integralRetrospectiveCorrectionEnabled = enabled
            SportLog.event("loan", "retrospective correction: \(enabled ? "INTEGRAL" : "standard") (from grant)")
        }
    }

    /// Which retrospective correction the GRANTING phone runs, frozen at grant. The algorithm
    /// selects the implementation itself; the wrist only carries the phone's choice across.
    private var integralRetrospectiveCorrectionEnabled = false

    private var predictedGlucose: [PredictedGlucoseValue]?

    /// Straight off the last algorithm run. Held rather than recomputed so that what the glance
    /// shows is, by construction, what the dose was decided from.
    private var activeInsulin: Double?
    private var activeCarbs: Double?
    private var lastAlgorithmEffects: LoopAlgorithmEffects<StoredCarbEntry>?

    /// INSTRUMENTATION ONLY: last cycle's exact prediction decomposition, computed once at
    /// the end of `logPredictionBreakdown` and read (never computed) by `glanceData()`.
    private var lastPredictionBreakdown: PredictionBreakdown?

    private var recommendedAutomaticDose: (recommendation: AutomaticDoseRecommendation, date: Date)?

    /// INSTRUMENTATION ONLY: the phone's prediction decomposition carried in the grant,
    /// stashed at takeover so `[predict-diff]` can subtract the watch's first post-takeover prediction
    /// against it, term by term. Self-expires after 20 min (checked at the diff) so a stale grant
    /// snapshot never keeps diffing against a moved-on watch.
    private var phonePredictionSnapshotAtGrant: LoanPredictionSnapshot?
    func stashPhonePredictionSnapshot(_ snapshot: LoanPredictionSnapshot?) {
        dataAccessQueue.async { self.phonePredictionSnapshotAtGrant = snapshot }
    }

    /// INSTRUMENTATION ONLY: the three IOB values that should agree at takeover — phone-at-grant,
    /// watch SEED-IN anchor, watch first-cycle computed — captured so `[iob-diff]` can localize the
    /// ~0.3U leak. Set at SEED-IN, consumed (and cleared) at the first post-takeover cycle.
    private var takeoverIOBAnchors: (phone: Double?, phoneDate: Date?, seed: Double, at: Date)?
    func recordTakeoverIOBAnchors(phone: Double?, phoneDate: Date?, seed: Double, at: Date) {
        dataAccessQueue.async { self.takeoverIOBAnchors = (phone, phoneDate, seed, at) }
    }

    /// What the LAST cycle decided, retained after `recommendedAutomaticDose` is cleared by
    /// a successful enact — so display surfaces can show the decision instead of a blank.
    private var lastRecommendation: AutomaticDoseRecommendation?

    private(set) var lastLoopCompleted: Date?
    private(set) var lastLoopError: Error?

    /// Mirrors DeviceDataManager.lastCGMLoopTrigger (deviceQueue only).
    private var lastCGMLoopTrigger: Date = .distantPast
    /// Storm latch: last phone-fallback syncId attempted (serial deviceQueue only).
    var lastPhoneFallbackSyncId: String?

    // MARK: - SessionInsulinLedger

    /// The single-owner session dose timeline (see SessionInsulinLedger.swift for the full
    /// rationale). dataAccessQueue-confined, and the ONLY insulin book: the watch's DoseStore
    /// is never written, so both dosing and display read from here.
    ///
    /// The header used to end "dosing and display still read the DoseStore", a leftover from
    /// shadow mode that contradicted its own preceding sentence. It was accurate about the
    /// algorithm and that was the bug — `fetchAlgorithmInput` really did read the store, and
    /// the store really was empty. Fixed 2026-08-18; the sentence goes with it.
    private var sessionLedger: SessionInsulinLedger?

    /// Takeover: build a fresh ledger from the grant split. Uses the SAME config the store
    /// path nets/decays with (frozen grant basalProfile, same model provider) so the shadow
    /// diff isolates STORAGE behavior, not math.
    func ledgerSeed(finished: [DoseEntry], live: [DoseEntry]) {
        dataAccessQueue.async {
            // The ledger does not freeze a schedule at seed — both schedules are
            // resolved override-applied at READ time, so a "no basal profile yet →
            // seed SKIPPED" failure (which would silently leave the STORE driving dosing)
            // cannot arise. A missing schedule surfaces at read as a loud refusal instead.
            var ledger = SessionInsulinLedger(
                insulinModel: { [weak self] type in
                    self?.insulinModel(for: type) ?? ExponentialInsulinModelPreset.rapidActingAdult
                },
                longestEffectDuration: self.doseStore.longestEffectDuration)
            ledger.seed(finished: finished, live: live)
            self.sessionLedger = ledger
            SportLog.event("ledger", "seeded — \(ledger.summary) (\(finished.count) finished + \(live.count) live)")
        }
    }

    // g7.ledgerCutover DELETED. The flag was the one-line revert to the
    // store dosing path — and that path was never trustworthy on the watch
    // (isReadOnly store: saves silently no-op, purges can't clear). There is no fallback at
    // all: a missing ledger input refuses the cycle loudly, and the rollback is the previous
    // TestFlight build, not a hidden second book.

    /// One refusal log per distinct reason, not one per 2s glance tick.
    private var lastLedgerRefusalLogged: String?

    /// The ledger's counterpart to the phone's `clearCachedInsulinEffects()`
    /// (LoopDataManager.swift:472). Stock reaches it through a DoseStore notification observer
    /// (LoopDataManager.swift:206-219) that fires on EVERY dosing change; under the ledger
    /// cutover our doses never touch DoseStore, so that observer never fires and the cached
    /// insulin effects went stale for the whole epoch — the prediction kept the array built at
    /// takeover and every subsequent temp basal was invisible to it (measured: the
    /// predicted-minimum horizon pinned to one absolute wall-clock time for 11 consecutive
    /// cycles, and the insulin term reading −4 mg/dL against IOB 1.33 U at ISF 70, where the
    /// invariant demands −ISF × IOB ≈ −93). The loop then stacked insulin onto a prediction that
    /// contained none, and the counteraction pass — fed the same frozen array — booked real
    /// insulin action as positive discrepancy, inflating RC.
    ///
    /// MUST be called on `dataAccessQueue`, INLINE with the mutation that dirties the ledger:
    /// hopping through `invalidateInsulinEffect()` would enqueue a second block on this serial
    /// queue that could land after the next cycle has already read the stale array.
    private func clearCachedInsulinEffects() {   // dataAccessQueue
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        // Nothing to clear: the algorithm holds no effects between cycles, so the next run
        // reads the rebuilt books directly. Kept as a call site so the ledger mutations that
        // used to depend on it still read as deliberate.
        // NOT predictedGlucose — the watch deliberately diverges from the phone here, and the
        // first cut of this method broke it. Stock's clearCachedInsulinEffects() also nils
        // predictedGlucose; on the watch that value is DISPLAY-ONLY (the glance/diagnostic
        // "eventually N" row — DoseMath uses the locally-computed prediction), and the glance keeps
        // the last eventual visible with a freshness grade rather than blanking on a failed
        // cycle. See the identical note at the carbEffect didSet (~:552). Because this method now
        // runs on EVERY ledger write, nil-ing it here blanked the eventual after every enact —
        // observed on the wrist, with the reconciliation row still rendering 106
        // because it is cached separately at predict time. The stale array was the bug;
        // predictedGlucose was never part of it and is recomputed each cycle regardless.
    }

    /// A pod-ACCEPTED watch enact enters the timeline (truncating the open predecessor).
    func ledgerRecordEnact(_ dose: DoseEntry) {
        dataAccessQueue.async {
            self.sessionLedger?.recordEnact(dose)
            self.clearCachedInsulinEffects()   // The dose must reach the next prediction
            // ...and the DISPLAY curve must reach the wrist now, not next cycle. This is the
            // half of stock's dosing-change observer that had no analogue here: stock clears
            // the same two caches and then posts `notify(forChange: .insulin)`, and the status
            // screen's recompute off that notification is why the phone's "Eventually" credits
            // a temp within seconds of enacting it. The watch stamps its curves once per cycle,
            // BEFORE the enactor runs, so without this the wrist showed a figure computed
            // before the dose it had just delivered — the disagreement Jeremy measured at ~100
            // mg/dL against the phone, side by side.
            //
            // Effects first, curve second, and in that order: predictGlucose READS the caches
            // that were just nil-ed and does not rebuild them, so predicting here without the
            // refresh would produce a curve with no insulin in it at all.
            //
            // Only the pending-inclusive array is re-stamped. Nothing dosing reads it — DoseMath
            // consumes the locally-computed curve — so this cannot reach delivery, and no
            // recommendation is produced off-cycle.
            // No explicit glance poke: the glance's own tick rebuilds its mirror, and leaving a
            // failed predict on the previous value is the same choice made for the eventual
            // everywhere else on the wrist — a stale figure carrying a freshness grade beats a
            // blank one, which is why clearCachedInsulinEffects deliberately does not nil the
            // display curve the way stock's does.
        }
    }

    /// A chase verdict REFUTED a previously booked assumed dose — reverse it.
    func ledgerRemoveDose(type: DoseType, startingAt: Date) {
        dataAccessQueue.async {
            if self.sessionLedger?.removeDose(type: type, startingAt: startingAt) == true {
                self.clearCachedInsulinEffects()   // A reversal changes the curve too
                SportLog.event("ledger", "assumed dose REMOVED (chase refuted) — \(type) @ \(startingAt)")
            }
        }
    }

    /// Session over — the ledger simply ends (no wipe machinery to fight).
    func ledgerClear() {
        dataAccessQueue.async {
            self.sessionLedger = nil
        }
    }

    private let doseEnactor = WatchDoseEnactor()

    // MARK: - Loop cycle (mirrors loop()/loopInternal())

    /// One loop cycle: refresh effects, gate, predict, recommend, enact (via the seam).
    /// Triggered by new CGM data exactly as the phone's DeviceDataManager does; safe to call
    /// from any queue.
    /// Mirrors the phone's `DeviceDataManager.checkPumpDataAndLoop()` (:563): assert
    /// current pump data BEFORE looping, so the cycle's `pumpDataTooOld` gate (:655;
    /// phone LoopDataManager:1257) sees fresh state. **The port dropped this call
    /// entirely** — the watch never called `ensureCurrentPumpData`, so nothing kept
    /// `doseStore.lastAddedPumpData` current. On the phone that call is exactly what
    /// does: the DRIVER decides staleness (`OmniPumpManager.ensureCurrentPumpData`
    /// :2468 checks `state.isPumpDataStale`) and fetches pod status only when needed,
    /// so we inherit stock's threshold rather than inventing one.
    ///
    /// Without it every closed-loop cycle dies on `pumpDataTooOld` dated at the last pod
    /// contact: the pod link is orphaned between doses, so status only refreshes when we
    /// dose, and the loop won't dose without fresh status — a permanent deadlock after
    /// 15 minutes.
    ///
    /// The one necessary deviation: a status fetch needs the BLE link
    /// back, so reclaim → assert → loop → release. Skipped while our own view of the
    /// data is still fresh, because a reclaim costs pod contact that stock
    /// never pays. When the link is held continuously the reclaim closure returns
    /// immediately and this collapses to the stock call.
    /// OBS-8: latched so the no-pod state logs once per transition, not once per reading.
    private var loggedIdleNoPump = false

    func checkPumpDataAndLoop() {
        guard let pumpManager = pumpManager else {
            // OBS-8 (2026-08-13): AFTER a hand-back there is no pod and never will be until the
            // next grant, so running the full cycle is pure waste — the G7 keeps delivering, and
            // every reading drove updateCachedEffects + the whole prediction to conclude "no pod",
            // forever, once per reading. Log it ONCE per transition instead of once per cycle.
            //
            // This deliberately diverges from stock (LoopDataManager :571 loops without a pump).
            // On the phone that is right: no pump is an ERROR STATE the user should see surfaced
            // every cycle. On the wrist during Sport Mode it is the NORMAL resting state between
            // loans — the phone owns the pod and is looping — so treating it as a per-reading
            // failure produces alarming FAILED verdicts for a device that is working correctly.
            //
            // Glucose ingestion and the glance are untouched: they read the stores directly and
            // do not depend on this cycle.
            if !loggedIdleNoPump {
                loggedIdleNoPump = true
                SportLog.event("loop", "idle — no pod on the watch; cycles paused until the next grant (glucose still ingesting)")
            }
            return
        }
        loggedIdleNoPump = false

        let assertThenLoop: (@escaping () -> Void) -> Void = { done in
            pumpManager.ensureCurrentPumpData { _ in
                self.loop()
                done()
            }
        }

        let age = now().timeIntervalSince(lastPumpDataDate ?? .distantPast)   // Owned stamp
        // WARM CADENCE (157, E5 parity). E5's overnight proof — 84/84 reclaims, 2-4 reads
        // each — touched the pod EVERY cycle (an enact every reading). This threshold was
        // inputDataRecencyInterval/2 (7.5 min), so any quiet cycle (NO CHANGE verdict, data
        // ~5 min old) skipped pod contact entirely and the next reclaim faced a 10-min-cold
        // pod — the regime where the bare re-connect goes coin-flip (field 2026-07-22:
        // every reclaim failure followed a contact gap ≥ ~8 min; every ≤5-min-cadence run
        // was clean). Refresh whenever data is older than ~4 min = one status read per
        // cycle = exactly the cadence E5 proved all night. Recovery from a genuinely
        // missed cycle is the scan escalation's job; this keeps the miss from happening.
        guard age > .minutes(4),
              let reclaim = reclaimPodForDose else {
            assertThenLoop({})
            return
        }

        SportLog.event("loan", String(format: "pump data %.0f min old — reclaiming pod to refresh status before the cycle", age / 60))
        // This reclaim fires ~100ms after reading arrival — while un-adopted
        // that is the exact moment the D2W ride appears, and the pod scan kills the G7
        // connect. Hold the pod radio until the ride resolves.
        // Steady state (fresh direct G7) passes straight through.
        deferPodRadioWhileG7AcquisitionResolves {
            self.reclaimForRefresh(reclaim, assertThenLoop: assertThenLoop)
        }
    }

    private func reclaimForRefresh(_ reclaim: (@escaping (Bool) -> Void) -> Void, assertThenLoop: @escaping (@escaping () -> Void) -> Void) {
        reclaim { ok in
            if !ok {
                SportLog.event("loan", "pump-data refresh: pod didn't reconnect — cycle will still gate on stale pump data")
            }
            assertThenLoop {
                // Radio back to the G7. The +12s settle comfortably outlasts a
                // same-cycle enact, whose own reclaim is a no-op because the link
                // is already up.
                self.releasePodAfterDose?()
            }
        }
    }

    /// The fragile phase is G7 CONNECT/AUTH ESTABLISHMENT, ~1.5 s straddling the grid point. An
    /// ESTABLISHED link coexists with pod traffic perfectly well — backfill and live reads land
    /// during pod handshakes — and the forensics say the same from the pod's side. So the
    /// gate keys on live acquisition state, not the clock:
    ///
    /// - Direct G7 fresh (< 6.5 min): the read that triggered this cycle already completed —
    ///   proceed immediately. Steady state pays nothing.
    /// - Otherwise hold the pod radio until: a direct read LANDS (ride succeeded), or the G7
    ///   falls idle (no pending connect + no ride signal for 3s — checked only after a 2.5s
    ///   minimum hold, because the ride can announce up to ~1s AFTER the relay reading that
    ///   triggered us: ad at :48.197 vs INGEST at :48.050), or 20s timeout.
    ///
    /// Worst case: the cycle's pod work starts 20s late and the dose enacts 20s late —
    /// clinically nil. A lost ride costs the session's entire direct-G7 coverage.
    private func deferPodRadioWhileG7AcquisitionResolves(_ proceed: @escaping () -> Void) {
        let directAge = lastGlucoseSourceStamps.direct.map { self.now().timeIntervalSince($0) }
        if let age = directAge, age < .minutes(6.5) {
            proceed()
            return
        }
        let start = self.now()
        SportLog.event("loan", "acquisition gate: direct G7 not fresh (\(directAge.map { "\(Int($0))s ago" } ?? "never")) — holding pod radio for the G7 ride")
        func poll() {
            let elapsed = self.now().timeIntervalSince(start)
            if let d = self.lastGlucoseSourceStamps.direct, d > start {
                SportLog.event("loan", String(format: "acquisition gate: released after %.1fs — direct read LANDED", elapsed))
                proceed(); return
            }
            let pendingSince = G7RadioCensus.connectPendingSince
            let rideAge = G7RadioCensus.lastRideSignalAt.map { self.now().timeIntervalSince($0) }
            if elapsed >= 2.5, pendingSince == nil, (rideAge ?? .infinity) > 3 {
                SportLog.event("loan", String(format: "acquisition gate: released after %.1fs — G7 idle, no ride in sight", elapsed))
                proceed(); return
            }
            if elapsed >= 20 {
                SportLog.event("loan", String(format: "acquisition gate: TIMEOUT after %.1fs — proceeding (connectPending=%@ · lastRideSignal %@)",
                                              elapsed, pendingSince == nil ? "no" : "yes",
                                              rideAge.map { String(format: "%.1fs ago", $0) } ?? "never"))
                proceed(); return
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { poll() }
        }
        DispatchQueue.global(qos: .userInitiated).async { poll() }
    }

    func loop() {
        dataAccessQueue.async {
            self.log.default("Loop running")
            self.lastLoopError = nil
            let startDate = self.now()

            var error: WatchLoopError? = nil
            if error == nil {
                error = self.updatePredictedGlucoseAndRecommendedDose()
            }

            // Observability: a PREDICTION-stage missingDataError is otherwise
            // swallowed — the cycle-end handler suppresses missingDataError to avoid
            // double-logging enact radio-defers (which reach the loop as a wrapped
            // missingDataError too). Logging HERE, before enact, surfaces which of the
            // five inputs is nil (glucose / momentumEffect / carbEffect / insulinEffect
            // / activeInsulin) without touching the radio-defer path. This is exactly
            // the failure that made a silently non-dosing loop invisible.
            if case .missingDataError(let what)? = error {
                SportLog.event("loop", "NOT DOSING — prediction missing \(what)")
            }

            // The dead-man refresh belongs AFTER the enact — see the
            // verdict block below. Firing it here, on a healthy PREDICTION alone, deviates
            // from stock: stock's finishLoop takes enactRecommendedAutomaticDose's
            // error AS the loop's error (LoopDataManager.swift:888-905), so a cycle that cannot
            // reach the pump is a FAILED loop and never advances lastLoopCompleted. Ours already
            // matched stock for lastLoopCompleted/the ring; only the watchdog was wrong, and it
            // is the one surface whose whole job is to notice — otherwise a run of
            // podNotConnected enacts keeps re-arming the dead-man because the prediction is fine.

            // Enact only when the user has closed the loop on the watch THIS session
            // (watch sovereign — the phone's own loop mode
            // does not gate the wrist). Open = advisory: prediction + recommendation
            // computed above (glance display live), nothing sent to the pod.
            // Snapshot the recommendation BEFORE enacting. enactRecommendedAutomaticDose
            // clears `recommendedAutomaticDose` on success, and the cycle logging below
            // runs after it — so in CLOSED loop the log always read "rec none" no matter
            // what was decided. The decision has to be captured
            // while it still exists.
            let decided = self.recommendedAutomaticDose?.recommendation
            self.lastRecommendation = decided   // survives the enact's clear, for the DOSING panel
            if error == nil, self._closedLoopEnabled {
                error = self.enactRecommendedAutomaticDose()
            } else if error == nil {
                self.log.default("Advisory (open loop) — computed but not enacting.")
            }

            self.lastLoopError = error

            // CYCLE VERDICT — exactly one line per cycle, always. The question "did this
            // cycle actually dose?" had no greppable answer: a failed enact logged nothing at
            // all (mis-typed as .missingDataError, which is suppressed below), so 25 minutes of
            // podNotConnected looked identical to a quiet healthy night.
            let enactVerdict: String
            if !self._closedLoopEnabled { enactVerdict = "none(open-loop)" }
            else if decided?.basalAdjustment == nil && decided != nil { enactVerdict = "none(no-change)" }
            else if decided == nil { enactVerdict = "none(nothing-decided)" }
            else if case .enactFailed(let why)? = error { enactVerdict = "FAILED \(why)" }
            else if error != nil { enactVerdict = "not-attempted(\(error!))" }
            else { enactVerdict = "ok" }
            // The dead-man refreshes ONLY on a cycle that both computed AND (if it owed the pod
            // a command) landed it — stock parity, see the note where this used to live.
            let watchdogRefreshed = (error == nil && self.pumpManager != nil)
            if watchdogRefreshed { LoopStallWatchdog.refresh() }
            let sinceCompleted = self.lastLoopCompleted.map { Int(self.now().timeIntervalSince($0)) }
            // OBS-8: an ENACT-stage failure must not read as a COMPUTE failure. pumpManagerUnconnected
            // is raised by enactRecommendedAutomaticDose but is not wrapped as .enactFailed, so it
            // used to print computed=FAILED for a cycle whose prediction was perfect — which is how
            // a healthy post-hand-back watch logged FAILED every five minutes.
            let computeSucceeded: Bool = {
                switch error {
                case .none: return true
                case .enactFailed, .pumpManagerUnconnected: return true   // computed fine; the ENACT is what refused
                default: return false
                }
            }()
            SportLog.event("loop", String(format: "CYCLE VERDICT computed=%@ enact=%@ watchdog=%@ lastCompletedAge=%@",
                                          computeSucceeded ? "ok" : "FAILED",
                                          enactVerdict,
                                          watchdogRefreshed ? "refreshed" : "HELD",
                                          sinceCompleted.map { "\($0)s" } ?? "never"))

            if let error {
                self.log.error("Loop ended with error: %{public}@", String(describing: error))
                // Radio defers are logged at the defer site; don't double-log those.
                // .enactFailed is NOT suppressed — that suppression is why a failed enact
                // was invisible. Only missingDataError stays quiet (it has its own line above).
                if case .missingDataError = error {} else {
                    SportLog.event("loop", "cycle ended with error: \(error)")
                }
            } else {
                self.lastLoopCompleted = self.now()
                self.log.default("Loop ended (duration %.1fs)", self.now().timeIntervalSince(startDate))
                let bg = self.glucoseStore.latestGlucose.map { String(format: "%.0f", $0.quantity.doubleValue(for: .milligramsPerDeciliter)) } ?? "—"
                // "no change" is a DECISION (DoseMath declined to alter the running
                // basal), distinct from "nothing was decided" — conflating them is what
                // made 08:48 unreadable.
                let rec = decided.map { String(format: "%.2f U/h", $0.basalAdjustment.unitsPerHour) } ?? "none"
                SportLog.event("loop", "cycle OK — BG \(bg), IOB \(self.activeInsulin.map { String(format: "%.2f", $0) } ?? "—"), temp \(rec)")
                self.logPredictionBreakdown(decided: decided)
                self.publishHUDContext()
            }
        }
    }

    /// Recompute the cached effects + the prediction WITHOUT enacting — called right after a
    /// takeover so the glance shows a fresh eventual (WITH the seeded carbs) and IOB immediately,
    /// instead of the stale pre-loan cached values until the next G7 reading drives a full cycle.
    /// In the field, carbs seeded at takeover weren't in the glance eventual (it stayed the last
    /// pre-loan insulin-only prediction because no cycle had run), and IOB read ~0 while the seed
    /// store held the real value — both because the glance reads CACHED IOB/eventual that only a
    /// completed cycle refreshes. This is DISPLAY-ONLY: it never enacts (enact-only-on-fresh-reading
    /// is enforced by loop()'s CGM-triggered callers), so dosing timing is unchanged.
    func refreshPredictionForGlance() {
        dataAccessQueue.async {
            var error: WatchLoopError? = nil
            if error == nil {
                error = self.updatePredictedGlucoseAndRecommendedDose()
            }
            if case .missingDataError(let what)? = error {
                SportLog.event("loop", "takeover prediction refresh — not yet (missing \(what))")
            } else if error == nil {
                // Cache the recommendation for the DOSING panel (as loop() does), but do NOT enact.
                self.lastRecommendation = self.recommendedAutomaticDose?.recommendation
                SportLog.event("loop", "takeover prediction refresh — IOB \(self.activeInsulin.map { String(format: "%.2f U", $0) } ?? "—"), eventual + carbs refreshed (no enact)")
                self.logPredictionBreakdown(decided: self.recommendedAutomaticDose?.recommendation)
            }
            self.publishHUDContext()
        }
    }

    /// One line per cycle decomposing what the dose decision actually saw: each effect's net
    /// contribution over its remaining horizon, the eventual BG, and the recommendation. A
    /// missing input reads "—", because absence is a finding rather than a blank.
    ///
    /// Every number here comes off the last algorithm run rather than being recomputed, so the
    /// log cannot disagree with the forecast the dose was taken from. The older leave-one-out
    /// decomposition is gone with the hand-rolled pipeline it took apart; the algorithm reports
    /// its own effects, which is the same evidence obtained more cheaply.
    private func logPredictionBreakdown(decided: AutomaticDoseRecommendation? = nil) {   // dataAccessQueue
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        // Forward-looking from now, not across the whole stored array: effect already realized
        // is baked into the CURRENT BG and cannot move `eventual` — only effect still to come
        // can. Anchoring at the array start reaches hours back and reports the whole night's
        // insulin, which explains nothing.
        func net(_ effects: [GlucoseEffect]?) -> String {
            guard let effects, !effects.isEmpty else { return "—" }
            let forward = effects.filter { $0.startDate >= now() }
            guard let first = forward.first, let last = forward.last else { return "—" }
            let mgdl = LoopUnit.milligramsPerDeciliter
            return String(format: "%+.0f", last.quantity.doubleValue(for: mgdl) - first.quantity.doubleValue(for: mgdl))
        }

        let mgdlU = LoopUnit.milligramsPerDeciliter
        let eventual = predictedGlucose?.last.map { String(format: "%.0f", $0.quantity.doubleValue(for: mgdlU)) } ?? "—"

        let rec: String
        // Prefer the caller's pre-enact snapshot; `recommendedAutomaticDose` is already cleared
        // by a successful enact in closed loop.
        if let r = decided ?? recommendedAutomaticDose?.recommendation {
            let basal = String(format: "%.2f U/h", r.basalAdjustment.unitsPerHour)
            let bolus = r.bolusUnits.map { String(format: " + auto-bolus %.2f U", $0) } ?? ""
            rec = basal + bolus
        } else {
            rec = "none"
        }

        // The dose keys on EVENTUAL, with the predicted MIN and the suspend threshold as the
        // safety brake. All three on the decision line so "eventual < target ⇒ reduce" — and
        // "why temp 0" — read without cross-referencing the curve.
        let minPredicted: String = {
            guard let fwd = predictedGlucose?.filter({ $0.startDate >= now() }), !fwd.isEmpty,
                  let m = fwd.min(by: { $0.quantity.doubleValue(for: mgdlU) < $1.quantity.doubleValue(for: mgdlU) })
            else { return "—" }
            return String(format: "%.0f@%dm", m.quantity.doubleValue(for: mgdlU), Int(m.startDate.timeIntervalSince(now()) / 60))
        }()
        let suspendThr = settings.suspendThreshold.map { String(format: "%.0f", $0.quantity.doubleValue(for: mgdlU)) } ?? "—"

        let e = lastAlgorithmEffects

        // STORE the decomposition the line below prints. `lastPredictionBreakdown` was declared
        // and read (into GlanceData, for the diagnostics reconciliation panel) but assigned
        // NOWHERE in the tree, so that panel has said "no prediction to reconcile" on every cycle
        // since the port — while this very function computed every term it needed.
        //
        // Same numbers as the log line by construction: both read `lastAlgorithmEffects` and
        // `predictedGlucose` on this queue, in this pass, so the panel and the log can never
        // disagree about a cycle.
        lastPredictionBreakdown = {
            func delta(_ effects: [GlucoseEffect]?) -> Double {
                guard let effects else { return 0 }
                let forward = effects.filter { $0.startDate >= now() }
                guard let first = forward.first, let last = forward.last else { return 0 }
                return last.quantity.doubleValue(for: mgdlU) - first.quantity.doubleValue(for: mgdlU)
            }
            guard let start = glucoseStore.latestGlucose?.quantity.doubleValue(for: mgdlU),
                  let eventualValue = predictedGlucose?.last?.quantity.doubleValue(for: mgdlU) else { return nil }
            let insulin = delta(e?.insulin)
            let carb = delta(e?.carbs)
            let momentum = delta(e?.momentum)
            let retro = delta(e?.retrospectiveCorrection)
            // The insulin tail BEFORE the momentum blend: last − value(at-or-before now), the
            // same quantity the log line reports. Non-optional array on this type, so no flatMap.
            let rawTail: Double? = {
                guard let tail = e?.insulin, let last = tail.last else { return nil }
                let base = tail.last(where: { $0.startDate <= now() }) ?? tail.first
                guard let base else { return nil }
                return last.quantity.doubleValue(for: mgdlU) - base.quantity.doubleValue(for: mgdlU)
            }()
            return PredictionBreakdown(
                startMgdl: start,
                eventualMgdl: eventualValue,
                insulinMgdl: insulin,
                carbMgdl: carb,
                momentumMgdl: momentum,
                retrospectiveMgdl: retro,
                residualMgdl: eventualValue - (start + insulin + carb + momentum + retro),
                insulinRawTailMgdl: rawTail,
                insulinExpectedMgdl: nil,
                isfMgdlPerU: nil,
                iobUnits: activeInsulin,
                momentumPointCount: e?.momentum.count ?? 0,
                computedAt: now())
        }()
        SportLog.event("predict", "eventual \(eventual) · min \(minPredicted) · suspendThr \(suspendThr) · net effects: carbs \(net(e?.carbs)), insulin \(net(e?.insulin)), momentum \(net(e?.momentum)), RC \(net(e?.retrospectiveCorrection)) · IOB \(activeInsulin.map { String(format: "%.2f", $0) } ?? "—") · COB \(activeCarbs.map { String(format: "%.0f", $0) } ?? "—") · momPts \(e?.momentum.count ?? 0) · rcDisc \(e?.retrospectiveGlucoseDiscrepancies.count ?? 0) · rec \(rec)")
        SportLog.event("curve", curveSummary(predictedGlucose))
    }

    private func emitIOBDiff(anchors: (phone: Double?, phoneDate: Date?, seed: Double, at: Date), cycle1: Double?) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        let leg1 = anchors.phone.map { String(format: "%+.2f", anchors.seed - $0) } ?? "—"
        let leg2 = cycle1.map { String(format: "%+.2f", $0 - anchors.seed) } ?? "—"
        let dt = now().timeIntervalSince(anchors.at)
        let phoneAge = anchors.phoneDate.map { String(format: "%.0f", now().timeIntervalSince($0)) } ?? "—"
        let lastPumpAge = lastPumpDataDate.map { String(format: "%.0fs", now().timeIntervalSince($0)) } ?? "nil"   // Owned stamp; lastReconAge dropped with the store book
        SportLog.event("iob-diff", String(format:
            "phoneIOB=%@ seedIOB=%.2f cycle1=%@ · Δ(seed−phone)=%@[wire] · Δ(cycle1−seed)=%@[reconcile] · dt(seed→cycle1)=%.0fs · phoneIOBAge=%@s · lastPumpAge=%@",
            anchors.phone.map { String(format: "%.2f", $0) } ?? "—", anchors.seed,
            cycle1.map { String(format: "%.2f", $0) } ?? "—",
            leg1, leg2, dt, phoneAge, lastPumpAge))
    }

    /// INSTRUMENTATION ONLY: per-dose IOB decomposition at a labeled instant (SEED-IN vs
    /// CYCLE1), so a re-timed / superseded / added dose between the seed and the first pod-status read
    /// is visible — the mechanism behind the ~0.3U SEED-IN→first-cycle drop. One-shot; never per-cycle.
    /// `netBasalUnits` already folds in `scheduledBasalRate`, so the SAME window showing a different
    /// net between labels is the scheduled-basal-netting signature (H2); a re-timed/added row is H1.
    func dumpIOBDecomp(_ label: String, at t: Date) {
        dataAccessQueue.async {
            // The decomp reads the LEDGER — the only book that holds doses now. Annotated
            // with the override-applied schedule, so the rows show the same netting dosing uses.
            guard let ledger = self.sessionLedger,
                  let basal = self.basalRateScheduleApplyingOverrideHistory else {
                SportLog.event("iob-decomp", "@\(label) — no ledger/schedule (R35: store holds no doses)")
                return
            }
            do {
                let window = (start: ledger.doses.map(\.startDate).min() ?? t,
                              end: (ledger.doses.map(\.endDate).max() ?? t).addingTimeInterval(InsulinMath.defaultInsulinActivityDuration))
                let basalTimeline = BasalRateSchedule.generateTimeline(
                    schedules: [(date: .distantPast, schedule: basal)],
                    startDate: window.start,
                    endDate: window.end)
                let doses = ledger.doses
                    .map { $0.simpleDose(with: self.insulinModel(for: $0.insulinType)) }
                    .annotated(with: basalTimeline)
                let uhr = LoopUnit.internationalUnit.unitDivided(by: .hour)
                let tf = DateFormatter()
                tf.dateFormat = "HH:mm:ss"
                var netSum = 0.0
                var rows: [String] = []
                for d in doses where abs(d.netBasalUnits) > 0.0001 || d.type == .bolus {
                    netSum += d.netBasalUnits
                    let sched = String(format: "%.2f", d.volume / max(d.duration / 3600, .ulpOfOne))
                    let id = "—"
                    // `vol=` is the volume attributed to this slice once it was netted
                    // against the basal timeline — the number that actually enters IOB.
                    let del = String(format: "%.3f", d.volume)
                    rows.append(String(format: "%@ %@..%@ net=%+.3f sched=%@ vol=%@ id=%@",
                                       "\(d.type)", tf.string(from: d.startDate), tf.string(from: d.endDate),
                                       d.netBasalUnits, sched, del, id))
                }
                SportLog.event("iob-decomp", "@\(label) Σnet=\(String(format: "%.3f", netSum))U n=\(rows.count) · " + rows.joined(separator: " | "))
            }
        }
    }

    /// A4 (Jeremy 2026-07-24): the piece that makes a field run replayable through
    /// DoseMath. `[predict]` logs only `eventual`, but the dose decision keys on the
    /// predicted MINIMUM (suspend guard + the high-basal-threshold cap) and on the curve
    /// SHAPE. Log the min (value @ minutes-from-now) and a 30-min-sampled trajectory of
    /// the first two hours — enough to reconstruct which branch DoseMath took and to
    /// re-derive the verdict offline, without dumping all ~72 points every cycle.
    private func curveSummary(_ predicted: [PredictedGlucoseValue]?) -> String {
        guard let predicted, !predicted.isEmpty else { return "—" }
        let mgdl = LoopUnit.milligramsPerDeciliter
        let t0 = now()
        let fwd = predicted.filter { $0.startDate >= t0 }
        guard let minPoint = (fwd.isEmpty ? predicted : fwd)
            .min(by: { $0.quantity.doubleValue(for: mgdl) < $1.quantity.doubleValue(for: mgdl) }) else { return "—" }
        let minV = Int(minPoint.quantity.doubleValue(for: mgdl).rounded())
        let minOff = Int((minPoint.startDate.timeIntervalSince(t0) / 60).rounded())
        let samples = [0, 30, 60, 90, 120].map { m -> String in
            let mark = t0.addingTimeInterval(.minutes(Double(m)))
            guard let p = predicted.last(where: { $0.startDate <= mark }) ?? predicted.first else { return "—" }
            return "\(Int(p.quantity.doubleValue(for: mgdl).rounded()))"
        }.joined(separator: "→")
        return "min \(minV)@\(minOff)m · t0–120: \(samples)"
    }

    // MARK: - The algorithm

    /// Run an async piece of work from this manager's serial queue and wait for it.
    ///
    /// The loop cycle is a synchronous state machine on `dataAccessQueue`, while the stores it
    /// reads are async. Blocking here is safe precisely because this is NOT the main queue and
    /// the stores complete on their own queues; the alternative — making the whole cycle async —
    /// would restructure the loan's ordering guarantees for no behavioural gain.
    private func runBlocking<T>(_ work: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task {
            do { result = .success(try await work()) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    /// Round to something the pod can actually deliver, so the recorded rate is the delivered one.
    private func roundedBasalRate(_ unitsPerHour: Double) -> Double {
        guard let supported = pumpManager?.supportedBasalRates, !supported.isEmpty else { return unitsPerHour }
        return supported.enumerated().min(by: {
            abs($0.element - unitsPerHour) < abs($1.element - unitsPerHour)
        })?.element ?? unitsPerHour
    }


    /// Gather everything one forecast and dosing decision needs, in the shape the algorithm
    /// takes. Mirrors `LoopDataManager.fetchData` — same queries, same order, same refusals —
    /// with two differences that belong to a loan rather than to a phone:
    ///
    ///   * settings come from the grant, through `settingsProvider`, instead of a settings
    ///     store that the wrist never writes to;
    ///   * the override history is this manager's own, because the wrist resolves schedules
    ///     while deciding a dose on its own queue.
    ///
    /// Every missing configuration element DENIES dosing rather than defaulting. A wrist that
    /// invents a basal rate is worse than a wrist that refuses to dose.
    private func fetchAlgorithmInput(at baseTime: Date, recommendationType: DoseRecommendationType) async throws -> StoredDataAlgorithmInput {
        let dosesInputHistory = CarbMath.maximumAbsorptionTimeInterval + InsulinMath.defaultInsulinActivityDuration
        var dosesStart = baseTime.addingTimeInterval(-dosesInputHistory)

        // THE INSULIN BOOK IS THE LEDGER, NOT THE STORE.
        //
        // This read used to be `doseStore.getNormalizedDoseEntries(...)`, which is what the
        // phone does — and on the phone it is right, because the phone's DoseStore is written
        // by the pump-event delegate. The watch's is not: `pumpManager(_:hasNewPumpEvents:)`
        // discards every row on purpose ("Dose rows are NOT stored — the ledger is the only
        // book"), and there is no other writer anywhere in the extension. So the algorithm was
        // being handed an EMPTY dose history on every cycle.
        //
        // What that looked like in the field (2026-08-18, 09:24-09:30): three manual boluses
        // totalling 3.40 U inside six minutes, `IOB 0.00` and `insulin +0` in every prediction
        // across the whole session, and `REC bolus 1.66 U` republished unchanged after each one.
        // A recommendation that cannot see the insulin already given cannot decrement, so the
        // wrist kept asking for the same dose again — the overbolus path, reached by arithmetic
        // rather than by a radio fault.
        //
        // Unannotated on purpose: LoopAlgorithm does `doses.annotated(with: basal)` itself
        // (LoopAlgorithm :203) using the override-applied basal built below, so netting here
        // would apply it twice.
        //
        // Refuses rather than substituting an empty book. R35 bans a store fallback outright,
        // and the reason is this bug: dosing off an empty history looks exactly like dosing
        // with no insulin on board, which is the most dangerous number the watch can believe.
        guard let ledger = sessionLedger else {
            logLedgerRefusal("algorithm input")
            throw WatchLoopError.configurationError("no insulin ledger — refusing to dose off an empty book")
        }
        // Safe without a hop: both callers reach this through `runBlocking` from
        // `dataAccessQueue`, which blocks that queue for the duration, and every ledger
        // mutation is a `dataAccessQueue.async`. The ledger is a struct, so this is a copy.
        let doses = ledger.doses
            .filter { $0.startDate <= baseTime && $0.endDate >= dosesStart }
            .compactMap { dose -> DoseEntry? in
                // TEMPS ARE TRIMMED TO NOW; BOLUSES ARE NOT. The two need opposite treatment and
                // a blanket rule breaks one of them.
                //
                // Temps: WatchDoseEnactor books an accepted temp FULL-SPAN
                // (endDate = acceptedAt + 30 min, WatchDoseEnactor.swift:118-120), so inside a
                // running temp the untrimmed dose ends in the FUTURE. Two things go wrong at once.
                // LoopAlgorithm hard-refuses it on the automated path — `guard
                // !input.recommendationType.automated || basalEnd <= input.predictionStart else
                // { throw AlgorithmError.futureBasalNotAllowed }` (LoopAlgorithm.swift:700-703),
                // and `.tempBasal.automated` is true — so EVERY automatic cycle would throw for
                // as long as a temp was running. And it would be wrong even if it were allowed:
                // forward credit for insulin the pod has not yet delivered is banned outright in
                // this codebase. Trimming preserves the RATE and shrinks only the window, because
                // a temp carries `.unitsPerHour` and DoseEntry.trimmed only pro-rates `.units`.
                //
                // Boluses: the same enactor books a bolus with a real delivery window
                // (endDate = acceptedAt + units / 1.5 * 60, :149). Trimming THAT to now would
                // pro-rate a just-accepted bolus to approximately zero units — which is exactly
                // the defect this whole path was rewritten to fix, arrived at from the other
                // direction. A commanded bolus is committed insulin; counting it whole is also
                // the conservative direction, where under-counting invites a second dose.
                //
                // The phone trims everything (LoopDataManager.swift:719) and is right to: its
                // DoseStore rows come from pod history with real delivered amounts, not from a
                // forward-looking booking made at the moment of acceptance.
                guard dose.type != .bolus else { return dose }
                return dose.trimmed(to: baseTime)
            }
        // A live ledger with nothing in the dosing window is the exact shape of the bug above,
        // and it said nothing for a whole session. Once per distinct reason, so a genuinely
        // empty book (fresh pod, no history) reports once rather than every cycle.
        if doses.isEmpty {
            logLedgerRefusal("empty dosing window (ledger holds \(ledger.doses.count) dose(s))")
        }
        dosesStart = min(dosesStart, doses.map { $0.startDate }.min() ?? dosesStart)
        let dosesEnd = max(baseTime, doses.map { $0.endDate }.max() ?? baseTime)

        let rawBasal = try await settingsProvider.getBasalHistory(startDate: dosesStart, endDate: dosesEnd)
        guard !rawBasal.isEmpty else { throw WatchLoopError.configurationError("basalRateSchedule") }

        // Collapse contiguous same-rate entries, as the phone does: the projection splits at
        // every local midnight even when the rate does not change, and the continuous-delivery
        // integrator does not rejoin the pieces perfectly across that boundary.
        let basal: [AbsoluteScheduleValue<Double>] = rawBasal.reduce(into: []) { acc, entry in
            if let last = acc.last, last.value == entry.value, last.endDate == entry.startDate {
                acc[acc.count - 1] = AbsoluteScheduleValue(startDate: last.startDate, endDate: entry.endDate, value: last.value)
            } else {
                acc.append(entry)
            }
        }

        let forecastEndTime = baseTime.addingTimeInterval(InsulinMath.defaultInsulinActivityDuration).dateCeiledToTimeInterval(GlucoseMath.defaultDelta)
        let carbsStart = baseTime.addingTimeInterval(CarbMath.maximumAbsorptionTimeInterval * -1)

        let carbEntries = try await carbStore.getCarbEntries(start: carbsStart, end: forecastEndTime)
            .filter { $0.userCreatedDate ?? $0.startDate < baseTime }

        let carbRatio = try await settingsProvider.getCarbRatioHistory(startDate: carbsStart, endDate: forecastEndTime)
        guard !carbRatio.isEmpty else { throw WatchLoopError.configurationError("carbRatioSchedule") }

        let glucose = try await glucoseStore.getGlucoseSamples(start: carbsStart, end: baseTime)

        let dosesWithModel = doses.map { $0.simpleDose(with: insulinModel(for: $0.insulinType)) }
        let recommendationInsulinModel = insulinModel(for: pumpManager?.status.insulinType)

        let neededSensitivityTimeline = LoopAlgorithm.timelineIntervalForSensitivity(
            doses: dosesWithModel,
            glucoseHistoryStart: glucose.first?.startDate ?? baseTime,
            recommendationEffectInterval: DateInterval(start: baseTime, duration: recommendationInsulinModel.effectDuration)
        )
        let sensitivity = try await settingsProvider.getInsulinSensitivityHistory(
            startDate: neededSensitivityTimeline.start,
            endDate: neededSensitivityTimeline.end
        )
        guard !sensitivity.isEmpty else { throw WatchLoopError.configurationError("insulinSensitivitySchedule") }

        let dosingLimits = try await settingsProvider.getDosingLimits(at: baseTime)
        guard let maxBolus = dosingLimits.maxBolus else { throw WatchLoopError.configurationError("maximumBolus") }
        guard let maxBasalRate = dosingLimits.maxBasalRate else { throw WatchLoopError.configurationError("maximumBasalRatePerHour") }
        guard let suspendThreshold = dosingLimits.suspendThreshold else { throw WatchLoopError.configurationError("suspendThreshold") }

        // Overrides scale the timelines themselves, which is what makes an override real: the
        // target moves AND the basal / ISF / carb-ratio scales move with it. Moving the target
        // alone would make every "neutral" temp a high temp in override terms.
        let overrides = overrideHistory.getOverrideHistory(startDate: neededSensitivityTimeline.start, endDate: forecastEndTime)

        var target: [AbsoluteScheduleValue<ClosedRange<LoopQuantity>>]
        if let activeOverride = scheduleOverride, activeOverride.isActive(at: baseTime) {
            guard let schedule = settings.glucoseTargetRangeSchedule else {
                throw WatchLoopError.configurationError("glucoseTargetRangeSchedule")
            }
            let overridden = activeOverride.effectiveCorrectionRangeDuring(scheduledRange: schedule.quantityRange(at: baseTime))
            target = [AbsoluteScheduleValue(startDate: baseTime, endDate: forecastEndTime, value: overridden)]
        } else {
            target = try await settingsProvider.getTargetRangeHistory(startDate: baseTime, endDate: forecastEndTime)
        }
        guard !target.isEmpty else { throw WatchLoopError.configurationError("glucoseTargetRangeSchedule") }

        return StoredDataAlgorithmInput(
            glucoseHistory: glucose,
            doses: dosesWithModel,
            carbEntries: carbEntries,
            predictionStart: baseTime,
            basal: overrides.applyBasal(over: basal),
            sensitivity: overrides.applySensitivity(over: sensitivity),
            carbRatio: overrides.applyCarbRatio(over: carbRatio),
            target: target,
            suspendThreshold: suspendThreshold,
            maxBolus: maxBolus,
            maxBasalRate: maxBasalRate,
            useIntegralRetrospectiveCorrection: integralRetrospectiveCorrectionEnabled,
            includePositiveVelocityAndRC: true,
            carbAbsorptionModel: .piecewiseLinear,
            recommendationInsulinModel: recommendationInsulinModel,
            recommendationType: recommendationType
        )
    }

    // MARK: - Recommendation

    /// Run the algorithm and turn its output into the dose this cycle will enact.
    ///
    /// This used to be several hundred lines: momentum, insulin and carb effects, counteraction,
    /// retrospective correction, a prediction, and then DoseMath — each cached, each invalidated
    /// by hand. All of it now happens inside `LoopAlgorithm.run`, which takes every input at once
    /// and holds no state between cycles. That is not merely shorter: the cached-effect
    /// invalidation was the source of a whole family of stale-forecast bugs on this watch, and a
    /// function that cannot remember cannot go stale.
    ///
    /// The IOB clamp the fork used to pass into DoseMath by hand is now the algorithm's own
    /// `maxActiveInsulinMultiplier`, applied inside the dosing decision where it belongs.
    private func updatePredictedGlucoseAndRecommendedDose() -> WatchLoopError? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        let startDate = now()

        // The watch doses by temp basal only; every bolus is human-confirmed. A phone-pushed
        // automaticBolus setting is refused out loud rather than quietly reinterpreted.
        guard settings.automaticDosingStrategy == .tempBasalOnly else {
            return .configurationError("automaticDosingStrategy: automaticBolus is not supported on the watch (temps only)")
        }

        let input: StoredDataAlgorithmInput
        do {
            input = try runBlocking { try await self.fetchAlgorithmInput(at: startDate, recommendationType: .tempBasal) }
        } catch let error as WatchLoopError {
            return error
        } catch {
            return .missingDataError(String(describing: error))
        }

        let output = LoopAlgorithm.run(input: input)

        // Everything the glance and the telemetry read comes off the same output, so what is
        // displayed is by construction what was dosed from.
        predictedGlucose = output.predictedGlucose
        activeInsulin = output.activeInsulin
        activeCarbs = output.activeCarbs
        lastAlgorithmEffects = output.effects

        switch output.recommendationResult {
        case .failure(let error):
            recommendedAutomaticDose = nil
            SportLog.event("dosemath", "algorithm declined: \(String(describing: error))")
            return .missingDataError(String(describing: error))

        case .success(let recommendation):
            guard var automatic = recommendation.automatic else {
                recommendedAutomaticDose = nil
                self.log.default("No dose recommended.")
                return nil
            }

            // Whether a command actually needs to go out. The algorithm says what rate is
            // right; this says whether the pod is already running it. Skipping the redundant
            // command matters more on a wrist than on a phone — every pod command costs radio
            // time the G7 is competing for.
            var basal = automatic.basalAdjustment
            basal.unitsPerHour = roundedBasalRate(basal.unitsPerHour)
            let scheduledBasalRate = input.basal.closestPrior(to: startDate)?.value ?? 0
            let adjusted = basal.adjustForCurrentDelivery(
                at: startDate,
                neutralBasalRate: scheduledBasalRate,
                currentTempBasal: runningTempBasal(),
                continuationInterval: .minutes(11),
                neutralBasalRateMatchesPump: scheduleOverride == nil
            )

            guard let adjusted else {
                // The pod is already delivering what the algorithm asked for.
                recommendedAutomaticDose = nil
                SportLog.event("dosemath", String(format: "no command needed — pod already at %.2f U/hr", basal.unitsPerHour))
                return nil
            }
            automatic.basalAdjustment = adjusted

            recommendedAutomaticDose = (recommendation: automatic, date: startDate)
            lastDosingDerivation = algorithmSummary(input: input, output: output, enacting: adjusted)
            SportLog.event("dosemath", lastDosingDerivation ?? "")
            return nil
        }
    }

    /// The decision, with the evidence behind it. A verdict without its inputs is unexplainable
    /// hours later in a field log, which is exactly when it needs explaining.
    private func algorithmSummary(input: StoredDataAlgorithmInput,
                                  output: AlgorithmOutput<StoredCarbEntry>,
                                  enacting: TempBasalRecommendation) -> String {
        let mgdl = LoopUnit.milligramsPerDeciliter
        let target = input.target.closestPrior(to: input.predictionStart)?.value
        return String(
            format: "eventual %@ vs target %@ · running %@ · scheduled %.2f · maxBasal %.2f · IOB %.2f · COB %.0f · suspendThr %@ => temp %.2f U/hr x %.0f min",
            output.predictedGlucose.last.map { String(format: "%.0f", $0.quantity.doubleValue(for: mgdl)) } ?? "—",
            target.map { String(format: "%.0f-%.0f", $0.lowerBound.doubleValue(for: mgdl), $0.upperBound.doubleValue(for: mgdl)) } ?? "—",
            runningTempBasal().map { String(format: "%.2f U/hr", $0.unitsPerHour) } ?? "none(scheduled)",
            input.basal.closestPrior(to: input.predictionStart)?.value ?? 0,
            input.maxBasalRate,
            output.activeInsulin ?? 0,
            output.activeCarbs ?? 0,
            input.suspendThreshold?.doubleValue(for: mgdl).description ?? "none",
            enacting.unitsPerHour,
            enacting.duration / 60)
    }

    // MARK: - Manual bolus (mirrors recommendBolusValidatingDataRecency — :1500 — and recommendManualBolus — :1537)

    /// The stock recency-validated manual-bolus path: glucose/pump staleness gates and no
    /// fabricated glucose placeholder (the crude version's 100 mg/dL stand-in is a review
    /// finding and does not return).
    /// RULED: a recency denial surfaces as an explicit "No recent
    /// glucose — no recommendation" notice in the recommendation slot; the dial stays
    /// usable for a manual bolus under therapy maxBolus and carbs still log. The notice
    /// rendering lands with the bolus-flow UI integration; this method supplies policy
    /// only (the thrown recency error is the notice's trigger).
    /// - Parameter potentialCarbEntry: when non-nil the recommendation is a MEAL bolus for
    ///   an entry the user has not saved yet. Two things change, both of them stock's doing:
    ///   the entry joins the prediction, and the target range switches to the pre-meal range
    ///   (`presumingMealEntry:`), which is exactly why passing it matters rather than just
    ///   adding a carb effect.
    func recommendManualBolus(potentialCarbEntry: NewCarbEntry? = nil,
                              completion: @escaping (Swift.Result<ManualBolusRecommendation, Error>) -> Void) {
        dataAccessQueue.async {
            do {
                // Same algorithm, different question: `.manualBolus` asks what a person should
                // take now, where `.tempBasal` asks what the pump should run. Everything that
                // used to be assembled by hand here — the pending-insulin-inclusive prediction,
                // the override-applied sensitivity, the pre-meal target — is now part of the
                // input, which is what stops the recommendation and the forecast behind it from
                // being computed two different ways.
                var input = try self.runBlocking {
                    try await self.fetchAlgorithmInput(at: self.now(), recommendationType: .manualBolus)
                }

                // An entry the user has typed but not saved joins the forecast, exactly as it
                // does on the phone's bolus screen.
                if let potentialCarbEntry {
                    input.carbEntries += [StoredCarbEntry(
                        startDate: potentialCarbEntry.startDate,
                        quantity: potentialCarbEntry.quantity,
                        foodType: potentialCarbEntry.foodType,
                        absorptionTime: potentialCarbEntry.absorptionTime)]
                }

                let output = LoopAlgorithm.run(input: input)

                self.predictedGlucose = output.predictedGlucose
                self.activeInsulin = output.activeInsulin
                self.activeCarbs = output.activeCarbs
                self.lastAlgorithmEffects = output.effects

                switch output.recommendationResult {
                case .failure(let error):
                    throw error
                case .success(let recommendation):
                    guard var manual = recommendation.manual else {
                        throw WatchLoopError.missingDataError("no manual bolus recommendation")
                    }
                    // Round to what the pod can actually deliver, exactly where the phone does it
                    // (LoopDataManager.recommendManualBolus) — before the number reaches ANY
                    // consumer, so the flow, the log line and the glance all quote one figure.
                    //
                    // Not cosmetic-only, though the symptom is cosmetic. The stock dial renders
                    // insulin with QuantityFormatter(for: .internationalUnit), whose
                    // maxFractionDigits is 3, so an unrounded recommendation reads "REC: 2.191 U"
                    // — a number no pod can give you, printed to a precision that implies it can.
                    // The delivery path already rounds at enactBolus, so the pre-fix wrist was
                    // quoting one figure and delivering another.
                    if let pump = self.pumpManager {
                        manual.amount = pump.roundToSupportedBolusVolume(units: manual.amount)
                    }
                    completion(.success(manual))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Manual bolus: the user is PRESENT — never defers to the radio arbiter
    /// (unlike the automatic path), capped by the granted therapy maximumBolus
    /// (therapy settings are the only limits), journaled through the same
    /// loan hooks as automatic doses. Completion on main.
    func enactManualBolus(units: Double, activationType: BolusActivationType, completion: @escaping (Error?) -> Void) {
        dataAccessQueue.async {
            guard let pumpManager = self.pumpManager else {
                DispatchQueue.main.async { completion(WatchLoopError.pumpManagerUnconnected) }
                return
            }
            guard let maxBolus = self.settings.maximumBolus else {
                DispatchQueue.main.async { completion(WatchLoopError.configurationError("maximumBolus")) }
                return
            }
            guard units <= maxBolus + .ulpOfOne else {
                DispatchQueue.main.async { completion(WatchLoopError.configurationError("bolus exceeds therapy maximum")) }
                return
            }
            let rounded = pumpManager.roundToSupportedBolusVolume(units: units)
            // The delivery itself, factored so it can run after a pod reclaim.
            let deliverBolus = {
                SportLog.event("loan", String(format: "MANUAL BOLUS %.2f U — enacting on the watch pump", rounded))
                let eventID = self.doseEnactor.loanRecorder?.loanWillEnactBolus(units: rounded)
                pumpManager.enactBolus(decisionId: nil, units: rounded, activationType: activationType) { error in
                    self.doseEnactor.loanRecorder?.loanDidEnact(eventID: eventID, error: error)
                    self.releasePodAfterDose?()   // Re-release the pod after the bolus
                    if let error = error {
                        SportLog.event("loan", "MANUAL BOLUS FAILED — \(String(describing: error))")
                    } else {
                        // Shadow ledger: point-ish event; DASH delivers ~1.5 U/min.
                        let acceptedAt = self.now()
                        let deliveryEndsAt = acceptedAt.addingTimeInterval(rounded / 1.5 * 60)
                        SportLog.event("loan", String(format: "MANUAL BOLUS delivering %.2f U — estimated done in %.0fs",
                                                      rounded, deliveryEndsAt.timeIntervalSince(acceptedAt)))
                        // Hand the glance the window so it can narrate the delivery the way
                        // stock's phone does. Estimate only — same contract as
                        // PodDoseProgressEstimator, no pod query, no radio.
                        self.setManualBolusDelivering(units: rounded, from: acceptedAt, to: deliveryEndsAt)
                        self.ledgerRecordEnact(DoseEntry(
                            type: .bolus, startDate: acceptedAt,
                            endDate: deliveryEndsAt,
                            value: rounded, unit: .units,
                            decisionId: nil,
                            insulinType: pumpManager.status.insulinType))
                        // Fold the bolus into IOB / prediction / HUD now rather than at the next
                        // reading. Nothing to invalidate any more — the cycle recomputes from the
                        // stores, so running one is both necessary and sufficient.
                        self.loop()
                    }
                    self.setManualBolusInFlight(false)
                    DispatchQueue.main.async { completion(error) }
                }
            }
            self.setManualBolusInFlight(true, units: rounded)
            // The pod link is orphaned so the G7 can use the radio — reclaim it before the
            // bolus. User is PRESENT, so a few seconds' reconnect is fine; on failure FAIL
            // LOUDLY (never a silent no-bolus). No-op immediate when the link is already held.
            if let reclaim = self.reclaimPodForDose {
                reclaim { ok in
                    if ok {
                        // ROOT CAUSE of a crown-tap deadlock: this completion runs ON the loan
                        // controller's serial queue (reclaimPodForDose wraps every path in
                        // queue.async, including the still-connected short-circuit), and
                        // deliverBolus → loanWillEnactBolus → mintIntent does queue.sync
                        // onto that SAME queue — a guaranteed libdispatch trap, before
                        // enactBolus is ever issued (apparent success at the crown, crash
                        // 0-40s later, NO insulin delivered). The automatic enactor never
                        // hits this because it re-enters from its own dosingQueue — mirror
                        // that discipline: hop off the loan queue before delivering.
                        // (.async is load-bearing: when the pod link is held rather than
                        // orphaned, the reclaim closure completes SYNCHRONOUSLY on
                        // dataAccessQueue — a .sync hop would deadlock on itself.)
                        let hopStart = self.now()
                        self.dataAccessQueue.async {
                            // Visibility: a manual bolus queued behind a full automatic
                            // enact (updateGroup.wait holds this queue ~15-45s) is loud
                            // in the log, not a silent delay (adversarial review).
                            let waited = self.now().timeIntervalSince(hopStart)
                            if waited > 2.0 {
                                SportLog.event("loan", String(format: "MANUAL BOLUS queued %.0fs behind the dosing queue (automatic cycle in flight)", waited))
                            }
                            deliverBolus()
                        }
                    } else {
                        self.releasePodAfterDose?()
                        SportLog.event("loan", "MANUAL BOLUS FAILED — the pod did not reconnect in time. If Sport Mode was just ended, the hand-back cancelled it (see the E4 reclaim ABORTED line above) — that is NOT a pod fault.")
                        self.setManualBolusInFlight(false)
                        DispatchQueue.main.async { completion(WatchLoopError.pumpManagerUnconnected) }
                    }
                }
            } else {
                deliverBolus()
            }
        }
    }

    /// Loan-time carb entry: lands in the WATCH's carb store so THIS loop's COB and
    /// dosing see it immediately (stores are isolated, HealthKit off; the phone still
    /// receives the stock relay as the durable record).
    /// Force the next cycle to recompute carbEffect. Used after seeding the phone's carbs
    /// at grant: carbEffect is cached and updateCachedEffects only recomputes it when
    /// nil, so without this the seeded COB would be ignored until the next CGM-triggered
    /// invalidation. Deliberately does NOT force a loop() — takeover has no glucose yet; the
    /// first reading-triggered cycle (within ~5 min) recomputes and doses.
    func invalidateCarbEffect() {
        // No-op by construction now — carb effects are computed inside each run from the
        // entries then in the store, so a seeded entry is picked up by the next cycle without
        // anything being dropped first.
    }

    /// IOB dedup (2026-07-22): after the grant wipe-then-seed rebuilds the insulin books,
    /// drop the cached insulin effects so the next cycle recomputes from the clean store
    /// instead of riding the pre-wipe curve (IOB itself refetches every cycle already).
    func invalidateInsulinEffect() {
        // No-op by construction now — see invalidateCarbEffect.
    }

    /// After the grant seeds ~3 h of glucose, drop the glucose-derived caches so the next cycle
    /// recomputes momentum AND retrospective correction from the seeded history. Setting
    /// insulinCounteractionEffects = [] cascades through its didSet (carbEffect = nil) and — via
    /// the Fix-C carbEffect.didSet — nils retrospectiveGlucoseDiscrepancies too; we also clear
    /// momentum and discrepancies directly so nothing rides a stale cold-start value. No forced
    /// loop(): the first live glucose reading drives the first cycle (mirrors invalidateCarbEffect).
    func invalidateGlucoseDerivedEffects() {
        // No-op by construction now. This one is worth a note: the cold-start freeze it was
        // written to break — momentum computed once against an empty store, retrospective
        // correction stuck at an empty value for a whole loan — cannot happen to a function
        // that keeps nothing between calls.
    }

    /// Prime the cached IOB AT takeover, from the seed's own IOB read, so the glance shows the
    /// correct value immediately instead of stale/blank until the first loop cycle (~1 min later)
    /// refreshes it. The seed populates the dose store but not this cache. `insulinOnBoard` feeds
    /// the glance (glanceData), the stock HUD (publishHUDContext), and dosing — priming it fixes
    /// all three consistently and single-sourced; the glance COB already reads its store live, so
    /// this brings IOB to parity for glance consistency. The next cycle overwrites it with the
    /// fully-reconciled value (e.g. after the first pod-status read trims the seeded open temp).
    func primeInsulinOnBoard(_ value: InsulinValue?) {
        // Show the seed's own IOB immediately rather than leaving the glance blank until the
        // first cycle lands; the next run overwrites it with the reconciled value.
        dataAccessQueue.async { self.activeInsulin = value?.value }
    }

    /// The takeover SEED-IN anchor comes from the LEDGER (the store no longer holds
    /// doses). Completion reports the primed value for the [iob-diff] anchors + SEED-IN log.
    func primeIOBFromLedger(at date: Date, _ completion: @escaping (Double?) -> Void) {
        dataAccessQueue.async {
            guard let ledger = self.sessionLedger,
                  let basal = self.basalRateScheduleApplyingOverrideHistory else {
                completion(nil); return
            }
            let iob = ledger.insulinOnBoard(at: date, basalSchedule: basal)
            self.activeInsulin = iob
            completion(iob)
        }
    }

    func addLoanCarbEntry(_ entry: NewCarbEntry) {
        carbStore.addCarbEntry(entry) { result in
            switch result {
            case .success(let stored):
                SportLog.event("loan", String(format: "carbs logged locally: %.0f g", stored.quantity.doubleValue(for: .gram)))
                // 134 (field 2026-07-20 20:31): carbEffect is invalidated ONLY by new
                // CGM data (insulinCounteractionEffects.didSet) — the stock phone loop
                // observes carb-store changes for this, and the port dropped that
                // observer. A carb entry therefore sat OUTSIDE the prediction until
                // the next reading-triggered cycle (eventual BG lower than current
                // with 20 g COB on board). Invalidate + re-run the loop NOW: the
                // prediction, recommendation, and HUD update within seconds of the
                // entry, independent of CGM timing — stock parity restored.
                self.loop()
            case .failure(let error):
                SportLog.event("loan", "carb store add FAILED — \(String(describing: error))")
            }
        }
    }

    /// The mirror image of `addLoanCarbEntry` — remove a carb the wrist deleted and
    /// re-predict immediately.
    ///
    /// The invalidate-and-loop is not optional for the same reason it is not optional on the add
    /// path: `carbEffect` is invalidated only by new CGM data, because the port dropped the
    /// stock phone loop's carb-store observer. Without this the deleted carb keeps driving the
    /// prediction until the next reading — the user would watch the row vanish and the eventual
    /// BG not move, which is precisely the "did that do anything?" failure the delete is meant to
    /// resolve.
    ///
    /// Journaling is the CALLER's job (LoanCarbListController), so this stays a pure store+loop
    /// operation and the journal side-effect is visible at the UI layer where the ruling lives.
    func deleteLoanCarbEntry(_ entry: StoredCarbEntry, completion: @escaping (Bool) -> Void) {
        let grams = entry.quantity.doubleValue(for: .gram)
        // IDENTITY DUMP before the attempt (field lesson, two releases deep: 258 died on the
        // method's authorship guard, 260 died on the LOOKUP's — each time the log named the
        // error but not the entry's identity, so the next gate was invisible). One line that
        // says exactly what this entry carries answers "which lookup stage can even match it".
        SportLog.event("loan", String(format: "carb delete attempt %.0f g @ %@ · uuid=%@ sync=%@ ver=%@ prov=%@ mine=%@",
                                      grams, ISO8601DateFormatter().string(from: entry.startDate),
                                      entry.uuid == nil ? "nil" : "set",
                                      entry.syncIdentifier.map { String($0.prefix(8)) } ?? "nil",
                                      entry.syncVersion.map(String.init) ?? "nil",
                                      String(entry.provenanceIdentifier.prefix(12)),
                                      entry.createdByCurrentApp ? "y" : "n"))
        // Skipping the authorship check is the FIX, not a shortcut: grant-seeded entries are
        // createdByCurrentApp:false / uuid:nil by design, and BOTH stock gates (the method
        // guard AND the lookup) refuse them. The fork method does its own authorship-free
        // lookup and reports which stage matched. The phone applies the same deletion through
        // its own guarded door when the journal drains.
        carbStore.deleteCarbEntrySkippingAuthorshipCheck(entry) { result, lookupDiag in
            switch result {
            case .success:
                SportLog.event("loan", String(format: "carb DELETED locally: %.0f g · lookup: %@", grams, lookupDiag))
                self.loop()
                // POST-DELETE VERIFICATION: read the store back and say what remains, so
                // "deleted but still showing" can never again be ambiguous between a failed
                // delete and a stale view.
                let start = min(Calendar.current.startOfDay(for: self.now()),
                                Date(timeIntervalSinceNow: -CarbMath.maximumAbsorptionTimeInterval))
                self.carbStore.getCarbEntries(start: start) { readback in
                    if case .success(let remaining) = readback {
                        let total = remaining.reduce(0.0) { $0 + $1.quantity.doubleValue(for: .gram) }
                        SportLog.event("loan", String(format: "post-delete store: %d entr%@ remain, %.0f g total",
                                                      remaining.count, remaining.count == 1 ? "y" : "ies", total))
                    }
                }
                completion(true)
            case .failure(let error):
                SportLog.event("loan", "carb store delete FAILED — \(String(describing: error)) · lookup: \(lookupDiag)")
                completion(false)
            }
        }
    }

    // MARK: - Enactment (mirrors enactRecommendedAutomaticDose() — :1894 — via the seam)

    /// Freshness and suspension gates are the phone's; delivery goes through the stock
    /// PumpManager protocol. In M4 `pumpManager` is nil, so this path always ends at
    /// `.pumpManagerUnconnected` — by design.
    private func enactRecommendedAutomaticDose() -> WatchLoopError? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let recommendedDose = self.recommendedAutomaticDose else {
            return nil
        }

        guard abs(recommendedDose.date.timeIntervalSince(now())) < TimeInterval(minutes: 5) else {
            return .recommendationExpired(date: recommendedDose.date)
        }

        guard let pumpManager = pumpManager else {
            // M4: the seam is deliberately unconnected. An explicit error, never a silent
            // success — the loop must not appear to have dosed.
            return .pumpManagerUnconnected
        }

        if case .suspended = pumpManager.status.basalDeliveryState {
            return .pumpSuspended
        }

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var enactError: WatchLoopError?

        // RADIO STRESS REMOVED — it established that there is no radio contention when
        // dosing happens. The tool forced a pulse-step temp on
        // cycles DoseMath would have left alone, so every 5-min cycle exercised reading +
        // enact — the heaviest realistic contention load we could apply. It did its job and
        // the answer came back negative, repeatedly.
        //
        // What survived it, and must NOT be mistaken for this: contention is real during
        // CONNECT ESTABLISHMENT, which is why `deferPodRadioWhileG7AcquisitionResolves`
        // exists. An ESTABLISHED G7 link coexists with pod traffic (the 263 census); an
        // in-flight acquisition does not. Removing the stress tool does not weaken that gate.
        //
        // In git: the tool, its jitter alternator, and its debug toggle are at 37d7219d.
        doseEnactor.enact(recommendation: recommendedDose.recommendation, with: pumpManager) { error in
            if let error = error {
                // .enactFailed, NOT .missingDataError — see the case's own note.
                enactError = .enactFailed(String(describing: error))
            }
            updateGroup.leave()
        }
        updateGroup.wait()

        if enactError == nil {
            self.recommendedAutomaticDose = nil
        }

        return enactError
    }

    // MARK: - E5 bench concurrency driver

    /// A random temp-basal generator: drives the full reclaim→enact→re-release
    /// choreography with a genuine pod command on EVERY reading — pure BT-contention
    /// testing, zero dependence on the prediction pipeline (debugged separately in
    /// the sim, Track B). Gates: bench flag; loan pump present; loop OPEN — the
    /// generator REPLACES the enactor path, never runs beside it. Rate: scheduled
    /// basal + 0.05–0.50 U/hr random (a fresh value each cycle so the pod always
    /// gets a real program command — identical-temp suppression lives in DoseMath,
    /// which this bypasses), clamped to the granted max, 30-min duration so a
    /// stalled session decays back to schedule. Doses journal through the same
    /// loanRecorder hooks as real ones — they ARE real pod deliveries.
    func e5FireRandomTempIfEnabled() {
        guard defaults.bool(forKey: "g7.e5RandomTemp") else { return }
        // +8s: field 2026-07-21 23:32 (144, first firing) — E5 fired 25ms after the
        // VALUE, while the G7 link was still up (disconnect lands ~60ms post-value),
        // so the radio arbiter deferred it EVERY cycle and E5 never dosed. The real
        // loop's prediction pipeline adds enough latency to miss this race; E5 has
        // no pipeline, so it must wait out the teardown explicitly. +8s also matches
        // real-dose geometry (a temp lands seconds after the reading, not ms).
        dataAccessQueue.asyncAfter(deadline: .now() + 8) {
            guard !self._closedLoopEnabled else {
                SportLog.event("e5", "E5 skipped — loop is CLOSED (generator never runs beside the real enactor)")
                return
            }
            guard let pumpManager = self.pumpManager else { return }
            guard let scheduled = self.settings.basalRateSchedule?.value(at: self.now()) else {
                SportLog.event("e5", "E5 skipped — no basal schedule in granted settings (no-fabricated-defaults)")
                return
            }
            var rate = scheduled + Double.random(in: 0.05...0.50)
            if let cap = self.settings.maximumBasalRatePerHour { rate = min(rate, cap) }
            rate = pumpManager.roundToSupportedBasalRate(unitsPerHour: rate)
            let clock = DateFormatter(); clock.dateFormat = "HH:mm"
            self.defaults.set(String(format: "%+.2f @ %@", rate, clock.string(from: self.now())), forKey: "g7.e5LastCmd")
            SportLog.event("e5", String(format: "E5 random temp %.2f U/hr × 30 min (sched %.2f) — enacting", rate, scheduled))
            let recommendation = AutomaticDoseRecommendation(basalAdjustment: TempBasalRecommendation(unitsPerHour: rate, duration: .minutes(30)), direction: .neutral)
            self.doseEnactor.enact(recommendation: recommendation, with: pumpManager) { error in
                if let error = error {
                    SportLog.event("e5", "E5 enact FAILED — \(String(describing: error))")
                } else {
                    SportLog.event("e5", "E5 temp enacted OK — pod exchange complete")
                }
            }
        }
    }
}

// MARK: - Override telemetry helper

extension TemporaryScheduleOverride.Context {
    /// Greppable preset identity for the [override] lines — the name is what Jeremy will
    /// match against the phone when reconciling a session.
    var presetNameForLog: String {
        switch self {
        case .preMeal: return "pre-meal"
        case .preset(let preset): return "\(preset.symbol) \(preset.name)"
        case .activity(let preset): return "\(preset.activityType.symbol) \(preset.activityType.name)"
        case .custom: return "custom"
        }
    }
}

// MARK: - CGM input (mirrors DeviceDataManager.cgmManager(_:hasNew:) — :1001 — and processCGMReadingResult — :580)

/// The M3 stack's output becomes the loop's input here:
/// G7CGMManager -> CGMManagerDelegate -> GlucoseStore -> loop().
extension WatchLoopManager: CGMManagerDelegate {

    func startDateToFilterNewData(for manager: CGMManager) -> Date? {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        return glucoseStore.latestGlucose?.startDate
    }

    func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        log.default("CGMManager:%{public}@ did update with %{public}@", String(describing: type(of: manager)), String(describing: readingResult))
        processCGMReadingResult(manager, readingResult: readingResult) {
            let now = self.now()
            // Same 4.2-minute trigger gate as the phone (:1006) — under the G7's 5-minute
            // cadence this loops once per reading without double-firing on backfill.
            if case .newData = readingResult, now.timeIntervalSince(self.lastCGMLoopTrigger) > .minutes(4.2) {
                self.log.default("Triggering loop from new CGM data at %{public}@", String(describing: now))
                self.lastCGMLoopTrigger = now
                // Stock parity: the phone's CGM path also asserts pump data before
                // looping (DeviceDataManager.checkPumpDataAndLoop) — the port called
                // loop() bare, which is what stranded the cycle on pumpDataTooOld.
                self.checkPumpDataAndLoop()
                // E5: same post-catch trigger geometry as a real dose —
                // the command lands in the gap after this reading and contends with
                // the NEXT window, exactly like production timing. No-op unless the
                // bench flag is on.
                self.e5FireRandomTempIfEnabled()
            }
            // Every direct reading re-defers the sensor-blackout dead-man —
            // but only DURING a loan (pumpManager is loan-scoped): a reading that
            // lands after loan-end must not resurrect a disarmed repeating alert.
            if case .newData = readingResult, self.pumpManager != nil {
                SensorBlackoutAlert.refresh()
            }
            // Autonomous-iteration pipeline (Jeremy 2026-07-20): every reading
            // queues the log to the phone (throttled; queued transfers survive
            // unreachability), where a Shortcuts automation syncs it to iCloud.
            if case .newData = readingResult {
                Self.queueLogTransferThrottled()
            }
        }
    }

    /// Sovereignty signal: age of the newest stored glucose (direct-only during
    /// a loan — the watch's stores are isolated from the phone's), nil before any reading.
    var latestGlucoseAge: TimeInterval? {
        return glucoseStore.latestGlucose.map { self.now().timeIntervalSince($0.startDate) }
    }

    /// Queue the on-device log to the phone, at most once per 5 minutes — the
    /// autonomous-iteration pipeline's first hop (phone → iCloud via Shortcuts).
    private static var lastLogTransfer = Date.distantPast
    static func queueLogTransferThrottled() {
        // 4.5 min, NOT 5.0: readings arrive every ~4.98-5.0 min, so a 5.0-min gate
        // races the cadence and skips alternate transfers on boundary timing
        // (field 2026-07-20: the 17:47:33 reading, 299s after the 17:42 transfer,
        // shipped nothing — halving my Mac-side visibility).
        guard Date().timeIntervalSince(lastLogTransfer) > 4.5 * 60 else { return }
        guard WCSession.default.activationState == .activated, let url = LogFile.url else { return }
        lastLogTransfer = Date()
        WCSession.default.transferFile(url, metadata: ["kind": "g7watch.log"])
    }

    /// Mirrors processCGMReadingResult (:580): samples go to the LoopKit GlucoseStore —
    /// stock provenance, dedup, and persistence — before any loop consideration.
    private func processCGMReadingResult(_ manager: CGMManager, readingResult: CGMReadingResult, completion: @escaping () -> Void) {
        switch readingResult {
        case .newData(let rawValues):
            // BENCH-ONLY: substitute scripted values AFTER a successful real read.
            // Deliberately here and not upstream — the G7 connect/handshake already happened,
            // so radio contention and pod-link timing stay genuine and a MISSED window stays
            // missed. Everything downstream (store, momentum, prediction, DoseMath, the pod
            // command) is real. No-op unless the bench flag is on.
            let values: [NewGlucoseSample]
            if FakeGlucose.isEnabled {
                values = FakeGlucose.substitute(rawValues)
            } else {
                values = rawValues
            }
            // The phone relay may already have filed this exact reading under its own name
            // tag. Same sensor stamp = same reading; first writer wins.
            dropAlreadyStored(values) { kept in
            // 2026-08-03: this choke point — the ONLY place direct-G7 samples enter the store —
            // logged NOTHING on success, so a night could show zero `*** VALUE` lines (which the
            // BLE layer emits only for LIVE notification values) while the store filled normally
            // from BACKFILL batches. `.newData` carries an array precisely because the G7 hands
            // back history plus the current value together. Scoring CGM reliability by grepping
            // `*** VALUE` therefore undercounted real coverage, which is how the 2026-08-03
            // overnight got read as "0 reads in 2.8 h" when glucose was in fact arriving on a
            // clean 5-minute grid. Log every ingestion with its SOURCE so the three paths
            // (direct-G7 here, phone relay in ingestPhoneGlucoseFromContext, grant seed in
            // PodLoanWatchController) are countable and distinguishable from the log alone.
            let deliveredCount = values.count
            let latest = kept.max(by: { $0.date < $1.date }) ?? values.max(by: { $0.date < $1.date })
            let latestDesc: String = {
                guard let s = latest else { return "none" }
                let mgdl = Int(s.quantity.doubleValue(for: .milligramsPerDeciliter).rounded())
                return "\(mgdl) mg/dL age \(Int(self.now().timeIntervalSince(s.date)))s"
            }()
            let batchTag = deliveredCount > 1 ? " BATCH(backfill+live)" : ""
            // Stamp on ARRIVAL even when kept.isEmpty — a direct read the phone's copy beat to
            // the store still proves the direct link is alive, which is the whole point of C.
            if deliveredCount > 0 { self.noteGlucoseSource(directG7: true) }
            // `src=direct-G7` is PROVENANCE: off the sensor rather than via the phone relay. That
            // distinction still matters and is still worth logging — a run where the relay quietly
            // covers for a dead direct link would otherwise look healthy. (It once also had to name
            // WHICH of two BLE stacks produced the sample; there is only one now.)
            SportLog.event("glucose",
                "INGEST src=direct-G7 stored=\(kept.count)/\(deliveredCount) · latest \(latestDesc)\(batchTag)")
            guard !kept.isEmpty else { completion(); return }
            Task {
                do {
                    _ = try await self.glucoseStore.addGlucoseSamples(kept)
                } catch {
                    self.log.error("Failure adding glucose samples: %{public}@", String(describing: error))
                }
                // Nothing to invalidate: momentum is derived inside the algorithm from the
                // glucose it is handed, so the next cycle picks these readings up by reading
                // the store afresh. The old cached-momentum bug — computed once against an
                // empty store and then frozen for the loan — is not expressible any more.
                completion()
            }
            }
        case .unreliableData:
            // Stock G7CGMManager already withholds unreliable readings upstream of this.
            log.default("CGM reported unreliable data")
            completion()
        case .noData:
            completion()
        case .error(let error):
            log.error("CGM reading error: %{public}@", String(describing: error))
            completion()
        }
    }

    func cgmManager(_ manager: CGMManager, hasNew events: [PersistedCgmEvent]) {
        // The phone routes these to CgmEventStore (sensor start/expiry bookkeeping); no
        // watch-side CgmEventStore yet. Log-only in M4.
        log.default("CGM event(s): %{public}d", events.count)
    }

    /// Phone-BG fallback. During a loan, mirror the phone's relayed CGM into
    /// the DOSING glucose store so the closed loop survives a direct-G7 dropout. The relayed
    /// sample carries the phone's REAL G7 syncIdentifier (WatchContext.newGlucoseSample), so when
    /// direct G7 also has this grid point the store auto-dedups by syncId — this only fills GAPS.
    /// Fired on every phone context update (didUpdateContextNotification); gated to an active loan
    /// (pumpManager set). The date pre-check IS the failover for free: we ingest only when the
    /// phone reading is NEWER than anything already stored, so a fresh direct G7 always wins and
    /// phone BG fills in only once direct goes stale. (Mixed provenance zeroes momentum briefly at
    /// the boundary — accepted, per design.)
    @MainActor
    func ingestPhoneGlucoseFromContext() {
        guard pumpManager != nil else { return }   // active loan only — the watch is the dosing controller
        // Read the PHONE's relay explicitly. activeContext is watch-authored during a loan
        // now, so reading it here would hand this method the watch's own reading back and the
        // fallback would never ingest anything.
        guard let ctx = ExtensionDelegate.sharedIfAvailable()?.loopManager.phoneRelayContext,
              let sample = ctx.newGlucoseSample else { return }
        deviceQueue.async {
            // Same-sample repeat latch (the same sample can be ingested 3× in
            // 12 ms — one didUpdateContextNotification per context-adjacent update, and the
            // latestGlucose freshness guard below reads BEFORE the async add commits, so storms
            // slip past it; the store's syncId constraint absorbed the duplicate rows but the
            // completion re-logged and re-fired the loop trigger each time). Set synchronously
            // on the serial deviceQueue so repeats bail before the add.
            if sample.syncIdentifier == self.lastPhoneFallbackSyncId { return }
            self.lastPhoneFallbackSyncId = sample.syncIdentifier
            // Fill a gap only: skip if the store already has a reading at/after this one (a fresher
            // direct-G7 read wins). syncId dedup in the store is the belt for the exact-overlap case.
            if let latest = self.glucoseStore.latestGlucose?.startDate, latest >= sample.date { return }
            self.dropAlreadyStored([sample]) { kept in
            guard !kept.isEmpty else { return }   // Direct G7 already filed this reading
            Task {
                do {
                    _ = try await self.glucoseStore.addGlucoseSamples(kept)
                } catch {
                    self.log.error("phone-BG fallback add failed: %{public}@", String(describing: error))
                    return
                }
                let mgdl = Int(sample.quantity.doubleValue(for: .milligramsPerDeciliter))
                self.noteGlucoseSource(directG7: false)
                SportLog.event("glucose",
                    "INGEST src=phone-relay stored=1/1 · latest \(mgdl) mg/dL age \(Int(self.now().timeIntervalSince(sample.date)))s (direct-G7 gap)")
                SportLog.event("loan", "phone-BG fallback: ingested \(mgdl) mg/dL syncId=\(sample.syncIdentifier ?? "?") (direct-G7 gap) — triggering loop")
                let now = self.now()
                if now.timeIntervalSince(self.lastCGMLoopTrigger) > .minutes(4.2) {
                    self.lastCGMLoopTrigger = now
                    self.checkPumpDataAndLoop()
                }
            }
            }
        }
    }

    // MARK: - One physical reading, one row

    /// The part of a G7 syncIdentifier that BOTH devices agree on.
    ///
    /// G7CGMManager builds it as `"\(activatedAt…hours) \(sensorID) \(timestamp)"`
    /// (G7SensorKit/G7CGMManager.swift:421). Fields 2 and 3 come off the sensor itself and are
    /// therefore device-independent. Field 1 is each device's own ESTIMATE of when the sensor was
    /// started — `Date() − messageTimestamp`, latched the first time that device saw the sensor
    /// (G7CGMManager.swift:301-310, latched independently on each device). The phone and
    /// the watch latch at different instants,
    /// so their estimates differ by a fraction of a second and the full string never matches.
    ///
    /// So the store's syncIdentifier uniqueness constraint never fires across devices: the same
    /// physical reading arrives under two different names and is filed twice, once from the direct
    /// G7 read and once from the phone relay.
    ///
    /// Duplicate points carry the same value, so a regression through them barely moves — EXCEPT
    /// at `GlucoseMath.swift:103`, whose `count > 2` floor counts ROWS. A two-reading window that
    /// stock refuses to regress becomes four rows, clears the floor, and manufactures a trend.
    /// That is the reason this exists.
    ///
    /// The truncated form is verified device-independent in the field: the stamp parsed from the
    /// watch's own raw BLE frames equalled the phone's relayed stamp on 13 of 14 cycles, and the
    /// exception was the phone relaying a ~110-minute-stale reading, which is genuinely a
    /// different reading and correctly does NOT dedup.
    private static func sensorIdentity(_ syncIdentifier: String?) -> String? {
        guard let s = syncIdentifier, let sp = s.firstIndex(of: " ") else { return nil }
        let tail = s[s.index(after: sp)...]
        return tail.isEmpty ? nil : String(tail)
    }

    /// Drop candidates the store has already filed under a different device's name for the SAME
    /// physical reading. First writer wins, which gives the phone's copy while the phone is there
    /// (its relay lands ~7 s ahead of the direct read) and the direct copy once it is not —
    /// Jeremy's stated preference, with no arbitration logic.
    ///
    /// FAILS OPEN: if the store read errors we keep every candidate. A duplicate row is a mild
    /// distortion; a dropped reading is a missed loop cycle.
    private func dropAlreadyStored(_ samples: [NewGlucoseSample],
                                   completion: @escaping ([NewGlucoseSample]) -> Void) {
        let wanted = samples.compactMap { Self.sensorIdentity($0.syncIdentifier) }
        guard !wanted.isEmpty else { completion(samples); return }
        // The stamp is unique per reading, so a short window is plenty; this only has to cover the
        // seconds between the relay and the direct read for the same grid point.
        let since = self.now().addingTimeInterval(-.minutes(30))
        Task {
            guard let stored = try? await glucoseStore.getGlucoseSamples(start: since, end: nil) else {
                completion(samples)   // fail open
                return
            }
            let seen = Set(stored.compactMap { Self.sensorIdentity($0.syncIdentifier) })
            guard !seen.isEmpty else { completion(samples); return }
            var dropped: [String] = []
            let kept = samples.filter { s in
                guard let id = Self.sensorIdentity(s.syncIdentifier), seen.contains(id) else { return true }
                dropped.append(id)
                return false
            }
            if !dropped.isEmpty {
                SportLog.event("glucose", "#83 dedup: dropped \(dropped.count) already-filed reading(s) [\(dropped.joined(separator: ", "))] — same sensor stamp, different device name tag")
            }
            completion(kept)
        }
    }

    #if targetEnvironment(simulator)
    /// SIMULATOR-ONLY: inject the phone's stock CGM-simulator BG (relayed
    /// in WatchContext) into the REAL glucose store + trigger the REAL loop, so
    /// prediction/DoseMath run for real without a G7. Compiled OUT of device builds. The watch
    /// accumulates its own history from these, so the prediction sharpens over a few readings —
    /// exactly as it does from a real G7. Mirrors processCGMReadingResult(.newData) + the loop
    /// trigger, minus the CGMManager plumbing. In OPEN loop the recommendation is computed but
    /// not enacted (advisory); a nil pump means checkPumpDataAndLoop just loops — no pod touched.
    @MainActor
    func simIngestPhoneGlucose() {
        let ctx = ExtensionDelegate.sharedIfAvailable()?.loopManager.activeContext
        guard let quantity = ctx?.glucose, let date = ctx?.glucoseDate else { return }
        deviceQueue.async {
            if let latest = self.glucoseStore.latestGlucose?.startDate, latest >= date { return }   // dedup on date
            let sample = NewGlucoseSample(
                date: date,
                quantity: quantity,
                condition: nil,
                trend: ctx?.glucoseTrend,
                trendRate: ctx?.glucoseTrendRate,
                isDisplayOnly: false,
                wasUserEntered: false,
                syncIdentifier: "sim-\(Int(date.timeIntervalSince1970))")
            Task {
                do {
                    _ = try await self.glucoseStore.addGlucoseSamples([sample])
                } catch {
                    self.log.error("SIM glucose add failed: %{public}@", String(describing: error))
                }
                // Nothing to invalidate — the algorithm derives momentum from the glucose it is
                // handed on each run, so the next cycle picks this reading up by itself.
                let now = self.now()
                if now.timeIntervalSince(self.lastCGMLoopTrigger) > .minutes(4.2) {
                    self.lastCGMLoopTrigger = now
                    SportLog.event("sim", "SIM CGM \(Int(quantity.doubleValue(for: .milligramsPerDeciliter))) mg/dL (phone sim) — triggering real loop")
                    self.checkPumpDataAndLoop()
                }
            }
        }
    }
    #endif

    func cgmManagerWantsDeletion(_ manager: CGMManager) {
        log.default("CGM manager requested deletion (ignored on watch)")
    }

    /// Where the persisted G7 state lives. StockLoopStack.assemble reads it
    /// back at construction (`G7CGMManager(rawState:)` — the stock phone pattern).
    static let cgmStateDefaultsKey = "g7.cgmManagerRawState"

    func cgmManagerDidUpdateState(_ manager: CGMManager) {
        // Persist exactly as the stock phone does on this callback. The old
        // no-op here ("part of M5 integration") is why every launch constructed a blank
        // G7CGMManager and reran the acquisition lottery — the watch had the adoption and
        // threw it away on exit.
        guard manager is G7CGMManager else { return }
        let raw = manager.rawState
        let sensorID = raw["sensorID"] as? String

        // A nil sensorID means "unknown", NOT "forget".
        //
        // Stock treats a disconnect while auth is still pending as end-of-session
        // (G7Sensor.swift:227) and calls scanForNewSensor(), nilling the identity. On the WATCH
        // that fires as a matter of course after every loan: keepalive is released, the app
        // backgrounds, it can no longer hold a connection long enough to authenticate, and the
        // sensor drops it — roughly two minutes after every loan closes, mid-sensor-life.
        //
        // Persisting that nil is not merely a slow re-acquisition: a watch that has forgotten the
        // identity can fail authentication indefinitely and take ZERO direct reads. So keep the
        // last known-good identity rather than overwrite it with nothing. A genuine new sensor
        // still lands, because it arrives with its OWN non-nil sensorID and takes this branch
        // normally, and the escape for a sensor that really is finished is its age — past the
        // 10-day life plus a margin, a nil is honoured and the identity clears. (The bench
        // "Forget Sensor" button remains the manual escape for a mid-life sensor change.)
        if sensorID == nil,
           let stored = defaults.dictionary(forKey: Self.cgmStateDefaultsKey),
           let storedID = stored["sensorID"] as? String {
            let activated = stored["activatedAt"] as? Date
            let expired = activated.map { now().timeIntervalSince($0) > .hours(10 * 24 + 12) } ?? false
            if !expired {
                if lastPersistedSensorID != nil {
                    SportLog.event("cgm", "G7 state: manager forgot sensor \(storedID) — KEEPING the persisted identity (#104: nil means unknown, not forget)")
                    lastPersistedSensorID = nil   // log once per forget, not per state change
                }
                return
            }
            SportLog.event("cgm", "G7 state: sensor \(storedID) is past its 10-day life — honouring the clear")
        }

        defaults.set(raw, forKey: Self.cgmStateDefaultsKey)
        if sensorID != lastPersistedSensorID {
            lastPersistedSensorID = sensorID
            SportLog.event("cgm", "G7 state persisted — sensor \(sensorID ?? "none") (survives relaunch/update)")
        }
    }

    func credentialStoragePrefix(for manager: CGMManager) -> String {
        return "com.loopkit.Loop.WatchLoopManager"
    }

    func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {
        log.default("CGM status did update")
    }

    // MARK: DeviceManagerDelegate (device log + alerts)

    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        log.default("Device %{public}@: %{public}@", deviceIdentifier ?? "unknown", message)
        // Route to the FILE sink too. This is the only channel through which G7SensorKit reports
        // itself, and it was going to os_log alone — invisible in g7watch.log, which is the entire
        // reason it took a day to discover that G7SensorKit is what actually delivers glucose.
        //
        // 2026-08-06: 103 readings arrived while the since-retired J-PAKE reader logged ZERO of its
        // unconditional markers ("-> glucose [4E]", "*** GLUCOSE<-", "*** VALUE ="), including
        // 30 readings overnight with the phone's Bluetooth OFF. G7SensorKit runs its own
        // CBCentralManager, constructed eagerly at launch, and emitted exactly one line into our
        // log per reading — the INGEST, which credited the wrong component. It calls this delegate
        // for connect / disconnect / comms, so this one line makes its whole lifecycle visible.
        // ATTRIBUTE FROM THE MANAGER, not from the device name. DeviceManagerDelegate is shared:
        // the CGM manager AND the pump manager both call this, so the old flat "g7kit" label put
        // POD BLE traffic under a CGM heading. That cost real time on 2026-08-06 — pod
        // "max connections" errors read as sensor errors. The `manager` argument is the ground
        // truth, so use it rather than pattern-matching "DXCM" against a peripheral name, which
        // would be another label asserting something it cannot actually verify.
        let source = manager is G7CGMManager ? "cgm" : "pod-ble"
        // DEDUPE THE STORM. A Code=11 connect-retry loop pushed ~2,000
        // IDENTICAL lines/second through here (1051 in 0.52s) — each one a
        // synchronous NSLog plus a file-append — jamming syslogd and the log queue hard enough
        // to starve MAIN (the reproducible glance freeze) and rotate all real evidence out of
        // the log inside a second. The BLE-layer backoff makes the storm cold; this makes even
        // a future storm cheap AND readable: an identical repeat within 2s is counted, not
        // written, and the count is flushed on the next DIFFERENT line. Distinct lines pass
        // through untouched.
        let line = "\(type) \(deviceIdentifier ?? "—"): \(message)"
        switch deviceLogThrottle.admit(line, at: now()) {
        case .suppress:
            completion?(nil)
            return
        case .write(let flushing):
            if flushing > 0 {
                SportLog.event(source, "(previous line repeated ×\(flushing) — suppressed)")
            }
        }
        SportLog.event(source, line)
        completion?(nil)
    }

    // The watch alert path (surfacing PumpManagerAlerts — pod fault/occlusion — and CGM
    // alerts through watch notifications) is M5 work per design doc §1.3; these minimal
    // conformances log so nothing is silently swallowed in the meantime.

    func issueAlert(_ alert: LoopKit.Alert) {
        log.default("Alert issued: %{public}@", alert.identifier.value)
    }

    func retractAlert(identifier: LoopKit.Alert.Identifier) {
        log.default("Alert retracted: %{public}@", identifier.value)
    }

    // The wrist does not persist alerts. It issues them live for the duration of a loan and
    // forgets them when the loan ends, so every lookup answers "nothing stored" rather than
    // pretending to a history it never keeps.
    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier) async throws -> Bool {
        false
    }

    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] {
        []
    }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] {
        []
    }

    func recordRetractedAlert(_ alert: LoopKit.Alert, at date: Date) {
        log.default("Retracted alert recorded: %{public}@", alert.identifier.value)
    }
}

// MARK: - (mirrors the private TemporaryScheduleOverride extension in LoopDataManager.swift:2362)

private extension TemporaryScheduleOverride {
    func isBasalRateScheduleOverriden(at date: Date) -> Bool {
        guard isActive(at: date), let basalRateMultiplier = settings.basalRateMultiplier else {
            return false
        }
        return abs(basalRateMultiplier - 1.0) >= .ulpOfOne
    }
}
