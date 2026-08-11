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
    /// #97/#98 (2026-08-08): the dose was computed but the PUMP REFUSED OR COULD NOT BE
    /// REACHED. Previously wrapped as `.missingDataError`, which is wrong twice over: it is
    /// not a data problem, and the cycle-verdict logger deliberately suppresses
    /// missingDataError (it is logged separately as "NOT DOSING — prediction missing X"), so
    /// every failed enact produced NO cycle verdict at all. Field 2026-08-08 00:36/00:41/
    /// 00:46/00:56: four consecutive cycles whose temp enact failed podNotConnected logged
    /// neither "cycle OK" nor "cycle ended with error" — the loop looked silent, not broken.
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
    /// #41 ROOT CAUSE (found via build 142's "NOT DOSING — prediction missing carbEffect",
    /// 2026-07-21 22:17): the stores were built schedule-less (StockLoopStack.makeStores)
    /// and NOTHING propagated the grant's schedules to them — so CarbStore.getGlucoseEffects
    /// and DoseStore.getGlucoseEffects failed .notConfigured EVERY cycle, carbEffect/
    /// insulinEffect stayed nil, and the automatic loop never once recommended a dose
    /// (the phone's LoopDataManager does this same store sync in its settings didSet).
    /// Propagate here so EVERY settings application — grant, future mid-session pushes —
    /// keeps the stores consistent. All four store setters are Locked<> (any-queue safe).
    /// #68 overrides: the SAME history instance both stores were constructed with, so
    /// recording here re-resolves basal / ISF / carb ratio through
    /// basalProfileApplyingOverrideHistory et al. Mirrors the phone's
    /// LoopDataManager.overrideHistory (:346) and its record site (:270).
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

            // #68: mirror LoopDataManager :269-270 — an override only takes effect through
            // the HISTORY, not the settings object. Without this the watch resolves every
            // schedule UNSCALED during a loan (basal, ISF, carb ratio) and nets historical
            // temps against the wrong baseline, which reads exactly like an IOB bug.
            if settings.scheduleOverride != oldValue.scheduleOverride {
                overrideHistory.recordOverride(settings.scheduleOverride)
                if let o = settings.scheduleOverride {
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
                } else if oldValue.scheduleOverride != nil {
                    SportLog.event("override", "CLEARED — schedules resolve unscaled again")
                }
            }
            // Mirrors the phone LoopDataManager.settings didSet (:294-339) — same four
            // store syncs, same FeatureFlags-gated model provider, same cache
            // invalidation. Deviations: no mealDetectionManager/analytics (absent on
            // the watch), and syncs run unconditionally instead of diffed against
            // oldValue — a grant applies once per loan, so the extra invalidation is
            // free and a mid-session re-push behaves identically to stock.
            carbStore.carbRatioSchedule = settings.carbRatioSchedule
            carbStore.insulinSensitivitySchedule = settings.insulinSensitivitySchedule
            doseStore.insulinSensitivitySchedule = settings.insulinSensitivitySchedule
            doseStore.basalProfile = settings.basalRateSchedule
            // :317-321 verbatim, including the flag (compiled OFF in this build →
            // nil default model, exactly what the phone's doseStore runs with; pod
            // doses carry their own insulinType so the default is typeless-only).
            if FeatureFlags.adultChildInsulinModelSelectionEnabled {
                doseStore.insulinModelProvider = PresetInsulinModelProvider(defaultRapidActingModel: settings.defaultRapidActingModel)
            } else {
                doseStore.insulinModelProvider = PresetInsulinModelProvider(defaultRapidActingModel: nil)
            }
            // :330-336: schedule changes invalidate cached effects so the next cycle
            // recomputes under the new schedules instead of serving stale ones.
            dataAccessQueue.async {
                self.carbEffect = nil
                self.insulinEffect = nil
                self.insulinEffectIncludingPendingInsulin = nil
            }
        }
    }

    // MARK: The enact seam (M4: UNCONNECTED)

    /// Typed against the stock `PumpManager` protocol — the same protocol methods the phone's
    /// DoseEnactor calls (`enactTempBasal`/`enactBolus`) and the M2 `OmniPumpManager`
    /// implements. nil in M4: assembly is proven, dosing is not.
    /// Wiring a live pump manager happens via the loan protocol v2 controller
    /// (DESIGN_LOAN_PROTOCOL_V2.md §10): the grant's PodState snapshot constructs the
    /// OmniPumpManager and hands it here. The ruling dependencies are discharged (R16:
    /// therapy-settings-only limits; max-temp = therapy max-basal) — the remaining gate
    /// is the protocol itself, never a direct assignment from app code.
    var pumpManager: PumpManager?
    /// True when the POD itself will beep for a manual bolus, making the watch's success
    /// haptic redundant (both fire the instant the pod accepts). False when the pod is
    /// silenced — then the haptic is the ONLY confirmation and must stay.
    ///
    /// A closure, not a cast: this file works against the `PumpManager` protocol and does not
    /// import OmnipodKit. Wired in StockLoopSession alongside e4ReclaimPodForDose.
    var podBeepsOnManualBolusProbe: (() -> Bool)?
    var podBeepsOnManualBolus: Bool { podBeepsOnManualBolusProbe?() ?? false }

    /// The loan controller's dose-recording hooks (spec §1.2); set alongside
    /// `pumpManager` by PodLoanWatchController, cleared with it.
    weak var loanDoseRecorder: WatchLoanDoseRecording? {
        get { doseEnactor.loanRecorder }
        set { doseEnactor.loanRecorder = newValue }
    }


    /// E4 Stage 2 (task #40): reclaim the orphaned pod before a dose, release after.
    /// Forwarded to the enactor (automatic path); enactManualBolus uses them directly.
    /// Wired by StockLoopSession to the loan controller (which owns the OmniPumpManager);
    /// no-op / immediate-connected when E4 is off.
    /// #94: device-log storm dedupe (see logEventForDeviceIdentifier). Any thread may log.
    private let deviceLogDedupeLock = NSLock()
    private var lastDeviceLogLine = ""
    private var lastDeviceLogAt = Date.distantPast
    private var suppressedDeviceLogCount = 0

    private let manualBolusLock = NSLock()
    private var _manualBolusInFlight = false
    /// True from the moment a manual bolus begins its E4 pod reclaim until it resolves.
    ///
    /// Field 2026-08-05: a manual bolus took ~29s wall-clock — 24s of it waiting for the G7 to
    /// release the radio, then 4s reclaiming the pod, then 1.3s delivering. The bolus flow
    /// auto-dismisses after 1s and shows NOTHING for the rest, so the wrist looks idle while the
    /// dose is very much in progress. Jeremy read that silence as a hang and tapped End three
    /// separate times, and End cancels the in-flight reclaim — the user's impatience silently
    /// destroyed their own dose. The glance reads this so the wait is legible.
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
    /// #91: the amount being attempted, so the glance can NAME it during the pre-acceptance
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

    /// #91 DELIVERY WINDOW — the half of a manual bolus that used to be invisible.
    ///
    /// `manualBolusInFlight` ends at ACCEPTANCE (the pod acking the command), measured at 1.2s
    /// on 2026-08-08. The pod then spends ~1.5 U/min actually pushing the dose — 36s for 0.90 U —
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

    var e4ReclaimPodForDose: ((@escaping (Bool) -> Void) -> Void)? {
        get { doseEnactor.e4ReclaimPodForDose }
        set { doseEnactor.e4ReclaimPodForDose = newValue }
    }
    var e4ReleasePodAfterDose: (() -> Void)? {
        get { doseEnactor.e4ReleasePodAfterDose }
        set { doseEnactor.e4ReleasePodAfterDose = newValue }
    }

    /// Per-session watch-local closed-loop opt-in (R23 confidence model). Each loan
    /// starts OPEN (advisory — the loop computes and drives the glance display but does
    /// NOT enact); the user deliberately closes the loop from the glance screen.
    /// RULED 2026-07-18 (Jeremy, amending R23): the watch is SOVEREIGN once a loan is
    /// granted — the phone's own loop mode does NOT gate the wrist's per-session close.
    /// Therapy settings (frozen in the grant) are the only dosing limits (R1/R16); the
    /// old AND with the phone's dosingEnabled produced an untappable dead control when
    /// the phone happened to run open loop. Read/written on the dataAccessQueue.
    private var _closedLoopEnabled = false
    var closedLoopEnabled: Bool {
        dataAccessQueue.sync { _closedLoopEnabled }
    }
    /// Lock-guarded mirror of `_closedLoopEnabled` for callers that MUST NOT block on
    /// `dataAccessQueue`. The loan controller's queue is one: a `sync` from there onto
    /// dataAccessQueue is the #64 deadlock direction (apparent success at the crown, crash
    /// 0-40s later, no insulin delivered), and the hand-back offer is built on that queue.
    private let closedLoopMirrorLock = NSLock()
    private var _closedLoopMirror = false
    var closedLoopEnabledNonBlocking: Bool {
        closedLoopMirrorLock.lock()
        defer { closedLoopMirrorLock.unlock() }
        return _closedLoopMirror
    }

    /// `reason` exists so the log distinguishes a wrist tap from the grant-inherited mode
    /// (R23 overturned 2026-08-04) — otherwise every field log claims the user did it.
    func setClosedLoopEnabled(_ enabled: Bool, reason: String = "by user") {
        // Mirror synchronously so a hand-back offer built immediately after a wrist tap
        // carries the value the user just chose, not the one before it.
        closedLoopMirrorLock.lock()
        _closedLoopMirror = enabled
        closedLoopMirrorLock.unlock()

        dataAccessQueue.async {
            self._closedLoopEnabled = enabled
            SportLog.event("loop", enabled ? "CLOSED \(reason) — the watch will adjust basal" : "OPENED \(reason) — advisory only, no dosing")
        }
    }

    // MARK: - #68 part B: wrist-enacted overrides

    /// Apply an override the USER just selected on the wrist to this loan's DOSING settings.
    ///
    /// This is the whole watch-side mechanism: assigning `settings.scheduleOverride` runs the
    /// part-A didSet above, which records into the shared `overrideHistory` — and THAT is what
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
        settings.scheduleOverride = override
    }

    // MARK: - Glance surface (R23; display only — no dosing paths read this)

    /// #86 (Jeremy 2026-07-31: "add the prediction components to the diagnostic screen —
    /// INSULIN, carbs, momentum, retrospection … one line with an arithmetic reconciliation
    /// to the eventual BG"). DISPLAY + LOGGING ONLY — nothing here is read by any dosing path.
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
        /// 2026-08-01: an earlier version of this row compared it against the blended term and
        /// called the difference a "GAP", which manufactured a discrepancy that cost a morning.
        /// Note also that this quantity is NOT expected to match exactly when a temp is running:
        /// `insulinOnBoard` counts the temp's full remaining programmed delivery while
        /// `glucoseEffects` trims at `basalDosingEnd = now()`. Stock does the same — measured on
        /// the phone's own issue report the same day: IOB 2.5954 U against an insulinEffect tail
        /// of −124.02 mg/dL at ISF 70, a 0.82 U difference, which was exactly the 15 minutes
        /// still to run on a 4.5 U/hr temp. So a residual here is expected; a term that does not
        /// TRACK IOB at all is the real alarm (that was #84).
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
        let glucose: HKQuantity?
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
        let eventual: HKQuantity?
        let iob: Double?
        /// nil = no temp running (pod on schedule).
        let tempRate: Double?
        let lastLoopCompleted: Date?
        let suspendThreshold: HKQuantity?
        let closedLoopEnabled: Bool
        /// The phone-frozen dosing permission: when false the watch CANNOT close the
        /// loop (the phone had Closed Loop off at grant).
        let dosingAllowedByPhone: Bool
        /// #29 dosing observability (display-only): the temp DoseMath recommends THIS
        /// cycle (nil = none), vs `tempRate` (what the pod is actually running) — the
        /// gap between them is the "is it enacting?" tell. `lastLoopErrorText` is the
        /// last cycle's error (nil = clean), so a stalled/erroring loop is visible.
        let recommendedTempRate: Double?
        let lastLoopErrorText: String?
        /// #86 display-only: last cycle's exact prediction decomposition (nil until the first
        /// successful prediction of the session). Cached at cycle end — NEVER computed here.
        let predictionBreakdown: PredictionBreakdown?
        /// #46 (Jeremy 2026-08-04): which retrospective-correction model is actually running,
        /// and how much data it has. The watch adopts the PHONE's Integral toggle from the grant
        /// (PodLoanWatchController:431), so this is the readout that proves the two devices are
        /// predicting with the same algorithm — the divergence #46 was opened for. It was only
        /// ever visible in the log line `[rc] type=… · discrepancies=…`; on the wrist there was
        /// no way to tell Integral from Standard while looking at a suspicious eventual.
        let retrospectiveCorrectionIsIntegral: Bool
        let retrospectiveDiscrepancyCount: Int
    }


    /// #50: the temp basal the pod is running, as best the watch can know it — the live
    /// `basalDeliveryState` while the pod is connected, otherwise the temp we last enacted
    /// until its programmed end. E4 orphans the pod, so `basalDeliveryState` goes nil within
    /// seconds even though the pod keeps delivering. Read on `dataAccessQueue`.
    /// R33 hand-back half: is a LOOP temp still executing on the pod right now? The loan
    /// controller needs this at hand-back and cannot ask `basalDeliveryState`, because E4
    /// has orphaned the link by then and that state reads nil — which is exactly why the
    /// DESIGN-5 cancel in finalizeHandback had been silently dead (field 2026-08-11: no pod
    /// command at all between "drain complete" and the release, at both hand-backs).
    /// Thread-safe by hopping the data queue; nil when nothing is running.
    func runningTempBasalForHandback() -> DoseEntry? {
        return dataAccessQueue.sync { self.runningTempBasal() }
    }

    private func runningTempBasal() -> DoseEntry? {
        if case .some(.tempBasal(let dose)) = pumpManager?.status.basalDeliveryState {
            return dose
        }
        if let cached = cachedEnactedTempBasal, cached.endDate > now() {
            return cached
        }
        return nil
    }

    // MARK: - Glance mirror (main must never wait on dataAccessQueue)

    /// The glance used to read `glanceData()` — a `dataAccessQueue.sync` — from MAIN, on a 2s
    /// timer. That queue is held for the whole of a dose cycle, and `enactRecommendedAutomaticDose`
    /// polls the radio arbiter for up to 15s (:2527) before giving up. So any cycle that had to
    /// wait out the G7 handshake froze the entire UI for as long as it waited.
    ///
    /// Measured, build 237: carbs saved 23:41:47.583, compute done 63ms later, then
    /// `enact DEFERRED — G7 still owns the radio after 15s` at 23:42:04.261 and the glance's next
    /// render 0.3s after that — main parked ~16.6s. The identical stall is in the build 236 log
    /// (18:44:05 → 18:44:20, 15.0s), so this is not a regression from the #47 work: that ran 9.4s
    /// BEFORE the tap and cost 63ms. 99.6% of the freeze is the radio wait.
    ///
    /// Same remedy PodLoanWatchController already applies to the loan/pump queue (ba92c3cb,
    /// `refreshDebugSnapshot`/`mirroredDebugSnapshot`): publish a mirror from the queue, read the
    /// mirror from main, never block. That fix left `dataAccessQueue` untouched — this is the
    /// surviving edge of the same defect, and the fourth field report of the class.
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
                // meaningless "+0.00" that read as "no action" — 2026-07-25.)
                //
                // #68 (2026-08-01): net against the OVERRIDE-APPLIED schedule, not the raw one.
                // Netting against raw 0.70 under a 60% override rendered "+0.00" while the pod ran
                // 1.67x the override's intended basal — Jeremy read exactly that "0" as "not
                // low-temping". Under the override a suspend is −0.42 and raw-schedule is +0.28,
                // and the wrist must say so. Same fix, same accessor as the DoseMath guards.
                let scheduled = (doseStore.basalProfileApplyingOverrideHistory ?? settings.basalRateSchedule)?.value(at: now()) ?? 0
                tempRate = dose.unitsPerHour - scheduled
            }
            let sources = self.lastGlucoseSourceStamps
            // IOB evaluated at `now()` instead of read from the loop's cache. `insulinOnBoard`
            // is written only by updateCachedEffects, which runs only inside a loop cycle — and
            // loop() is CGM-triggered (:2523), so a sensor dropout stops IOB recomputation
            // outright. Field 2026-08-05: the rail held a flat 1.13 U for 28 minutes across a
            // G7 outage and then fell 0.53 in one step when readings resumed, which reads as an
            // insulin EVENT rather than as the arithmetic catching up.
            //
            // Unlike the prediction — which #48 deliberately MARKS stale rather than blanking,
            // because it genuinely cannot be recomputed without glucose — IOB is a pure function
            // of the dose timeline and the clock. So the honest fix is to evaluate it, not to
            // gate it: stock's HUD blanks stale insulin (ChartHUDController:165) because its
            // value arrives in a context it cannot recompute; the watch owns the timeline and
            // can. Same on-demand shape as glanceCarbsOnBoard — which is exactly why COB kept
            // decaying through that same outage while IOB sat still. Pre-cutover, or before the
            // ledger is seeded, the cached value remains the only source.
            let liveIOB: Double? = (ledgerCutoverActive ? sessionLedger?.insulinOnBoard(at: now()) : nil)
                ?? insulinOnBoard?.value
            return GlanceData(
                glucose: latest?.quantity,
                glucoseDate: latest?.startDate,
                directG7At: sources.direct,
                phoneRelayAt: sources.phone,
                trend: (latest as? StoredGlucoseSample)?.trend,
                // #48 (Jeremy 2026-07-24): keep the eventual VISIBLE; the glance grades its
                // freshness (fresh/aging/stale on the loop dot — stock's HUDInterfaceController
                // convention) rather than BLANKING it. The old binary gate hid the number when
                // cycles failed, but a blank reads as "no prediction," which is its own lie.
                // `lastLoopCompleted` is already in GlanceData, so activeState MARKS a stale
                // prediction instead of dropping it (field 2026-07-22: eventual sat at 120 for
                // 25 min across failed cycles — it now stays shown while the dot goes
                // amber→red, so it never looks authoritative once old).
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
                recommendedTempRate: lastRecommendation?.basalAdjustment?.unitsPerHour,
                lastLoopErrorText: lastLoopError.map { String(describing: $0) },
                // #86: READ the cached value. Computing it here would run a full per-source
                // replay of LoopMath on the MAIN thread every 2 s (this whole closure is
                // `dataAccessQueue.sync` from the debug page's timer) — cache at cycle end,
                // read at render.
                predictionBreakdown: lastPredictionBreakdown,
                // Same queue as the rest of this closure, so these are consistent with the
                // prediction being rendered rather than a torn read from another cycle.
                retrospectiveCorrectionIsIntegral: retrospectiveCorrection is IntegralRetrospectiveCorrection,
                retrospectiveDiscrepancyCount: retrospectiveGlucoseDiscrepancies?.count ?? 0)
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
            guard let self = self else { return completion(nil) }
            let velocities = self.insulinCounteractionEffects
            self.carbStore.carbsOnBoard(at: self.now(), effectVelocities: velocities) { result in
                if case .success(let value) = result {
                    completion(value.quantity.doubleValue(for: .gram()))
                } else {
                    completion(nil)
                }
            }
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
        ctx.isWatchAuthored = true   // #47: outranks the phone's relay of the same reading
        // #47: the stock chart's prediction line reads context.predictedGlucose and was never
        // populated here, so it sat empty for the whole loan (field 2026-08-05).
        ctx.predictedGlucose = predictedGlucose.flatMap { WatchPredictedGlucose(values: $0) }
        let latest = glucoseStore.latestGlucose
        ctx.glucose = latest?.quantity
        ctx.glucoseDate = latest?.startDate
        ctx.glucoseTrend = (latest as? StoredGlucoseSample)?.trend
        ctx.iob = insulinOnBoard?.value
        ctx.loopLastRunDate = lastLoopCompleted
        ctx.isClosedLoop = _closedLoopEnabled
        if let dose = runningTempBasal() {
            // #68 (2026-08-01): override-applied schedule, matching the glance fix above.
            let scheduled = (doseStore.basalProfileApplyingOverrideHistory ?? settings.basalRateSchedule)?.value(at: now()) ?? 0
            ctx.lastNetTempBasalDose = dose.unitsPerHour - scheduled
            ctx.lastNetTempBasalDate = dose.startDate
        } else {
            ctx.lastNetTempBasalDose = 0
            ctx.lastNetTempBasalDate = now()
        }
        // Same dynamic-absorption argument as the phone (:1110) — already on dataAccessQueue
        // here, so read the velocities directly.
        carbStore.carbsOnBoard(at: now(), effectVelocities: insulinCounteractionEffects) { result in
            if case .success(let value) = result {
                let cob = value.quantity.doubleValue(for: .gram())
                ctx.cob = cob
                // Per-cycle COB trace (grams on board) — complements the [predict] carbEffect line
                // so seeded/loan COB is verifiable through the loan. Non-trivial values only.
                if cob > 0.05 { SportLog.event("loop", String(format: "COB %.1f g on board", cob)) }
            }
            DispatchQueue.main.async {
                let loopDataManager = ExtensionDelegate.shared().loopManager
                ctx.displayGlucoseUnit = loopDataManager.activeContext?.displayGlucoseUnit ?? ctx.displayGlucoseUnit
                loopDataManager.updateContext(ctx)
                NotificationCenter.default.post(name: LoopDataManager.didUpdateContextNotification, object: loopDataManager)
            }
            // #47: the stock carb/bolus flow reads context.recommendedBolusDose, which only the
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
                        let loopDataManager = ExtensionDelegate.shared().loopManager
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
        self.overrideHistory = overrideHistory
        self.settings = settings
        // #50: cache each accepted temp so runningTempBasal() can report what the pod is
        // running while E4 has it orphaned (basalDeliveryState is nil then). Built here so the
        // DoseEntry uses this manager's testable clock; the cache is dataAccessQueue-isolated.
        // #73/#74 shadow ledger: enactor-accepted doses flow into the session timeline.
        doseEnactor.ledgerRecord = { [weak self] dose in self?.ledgerRecordEnact(dose) }
        doseEnactor.onTempBasalEnacted = { [weak self] unitsPerHour, duration in
            guard let self = self else { return }
            let start = self.now()
            let enacted = DoseEntry(type: .tempBasal, startDate: start, endDate: start.addingTimeInterval(duration), value: unitsPerHour, unit: .unitsPerHour)
            self.dataAccessQueue.async { self.cachedEnactedTempBasal = enacted }
        }
        #if !targetEnvironment(simulator)
        // #39: phone-BG fallback. Every phone context update, during a loan, mirror the phone's
        // relayed CGM into the DOSING store (device only; the simulator drives it via the
        // #61 timer — simStartGlucoseFeed — to avoid a synthetic-vs-real syncId double-ingest).
        NotificationCenter.default.addObserver(forName: LoopDataManager.didUpdateContextNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.ingestPhoneGlucoseFromContext()
        }
        #endif
    }

    // MARK: Cached effects (mirrors LoopDataManager's cached-effect properties; dataAccessQueue only)

    private var glucoseMomentumEffect: [GlucoseEffect]?
    private var insulinEffect: [GlucoseEffect]?
    private var insulinEffectIncludingPendingInsulin: [GlucoseEffect]?
    private var insulinCounteractionEffects: [GlucoseEffectVelocity] = [] {
        didSet {
            carbEffect = nil
        }
    }
    private var carbEffect: [GlucoseEffect]? {
        didSet {
            // RC-freeze fix (#69/#46): re-calculate retrospective correction when carb effects
            // change (carb data may be back-dated). The port DROPPED the phone's
            // LoopDataManager.carbEffect.didSet (:352-358); without it,
            // retrospectiveGlucoseDiscrepancies — set to [] at cold-start takeover (empty glucose
            // store) — was never nil'd again, and updateRetrospectiveGlucoseEffect() only runs
            // when it's nil (:780), so RC froze at the empty value for the WHOLE loan ("RC —" on
            // every [predict] line). Nil-ing it here restores per-cycle RC recomputation.
            //
            // We deliberately do NOT also nil predictedGlucose (the phone does). On the watch
            // predictedGlucose is read only for DISPLAY (glance eventual), never for dosing
            // (DoseMath uses the locally-computed prediction), and #48 (2026-07-24) intentionally
            // KEEPS the last eventual visible + grades its freshness rather than blanking it on a
            // failed cycle. Nil-ing it here would re-blank the glance on failed post-reading cycles.
            retrospectiveGlucoseDiscrepancies = nil
        }
    }
    private var insulinOnBoard: InsulinValue?
    /// Last-seen adapter delivery count, for producer attribution on the INGEST line. Touched only
    /// on the CGM delegate queue (processCGMReadingResult), so no lock of its own.

    private let bgSourceLock = NSLock()
    private var _lastDirectG7At: Date?
    private var _lastPhoneRelayAt: Date?
    /// #101 phase 2: last sensorID written by cgmManagerDidUpdateState (extension can't hold
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
    /// *** RADIO STRESS (BENCH) *** #83 — alternator so forced commands always differ.
    private var radioStressJitterStep = 0
    /// #74 cutover: the store's IOB kept as the SHADOW series while the ledger drives.
    private var storeIOBShadow: Double?
    /// #50: the temp basal we last successfully enacted, cached so the watch knows what the
    /// pod is running without querying it. E4 orphans the pod after each dose, so
    /// `pumpManager.status.basalDeliveryState` reverts to nil within seconds even though the
    /// pod keeps delivering the accepted temp for its full programmed duration. dataAccessQueue.
    private var cachedEnactedTempBasal: DoseEntry?
    private var retrospectiveGlucoseEffect: [GlucoseEffect] = []

    /// Mirrors LoopDataManager's buffer multiplier for combining retrospective discrepancies.
    private let retrospectiveCorrectionGroupingIntervalMultiplier = 1.01

    /// Carb entries behind the current `carbEffect`, kept for the #47 potential-entry branch.
    /// Read/written on `dataAccessQueue` like every other cached effect.
    private var recentCarbEntries: [StoredCarbEntry]?

    private var retrospectiveGlucoseDiscrepancies: [GlucoseEffect]? {
        didSet {
            retrospectiveGlucoseDiscrepanciesSummed = retrospectiveGlucoseDiscrepancies?.combinedSums(of: LoopMath.retrospectiveCorrectionGroupingInterval * retrospectiveCorrectionGroupingIntervalMultiplier)
        }
    }
    private var retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?

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
            self.retrospectiveCorrection = enabled
                ? IntegralRetrospectiveCorrection(effectDuration: LoopMath.retrospectiveCorrectionEffectDuration)
                : StandardRetrospectiveCorrection(effectDuration: LoopMath.retrospectiveCorrectionEffectDuration)
            SportLog.event("loan", "retrospective correction: \(enabled ? "INTEGRAL" : "standard") (from grant)")
        }
    }

    private var predictedGlucose: [PredictedGlucoseValue]?
    private var predictedGlucoseIncludingPendingInsulin: [PredictedGlucoseValue]?

    /// #86 INSTRUMENTATION ONLY: last cycle's exact prediction decomposition, computed once at
    /// the end of `logPredictionBreakdown` and read (never computed) by `glanceData()`.
    private var lastPredictionBreakdown: PredictionBreakdown?

    private var recommendedAutomaticDose: (recommendation: AutomaticDoseRecommendation, date: Date)?

    /// INSTRUMENTATION ONLY (#45): the phone's prediction decomposition carried in the grant,
    /// stashed at takeover so `[predict-diff]` can subtract the watch's first post-takeover prediction
    /// against it, term by term. Self-expires after 20 min (checked at the diff) so a stale grant
    /// snapshot never keeps diffing against a moved-on watch.
    private var phonePredictionSnapshotAtGrant: LoanPredictionSnapshot?
    func stashPhonePredictionSnapshot(_ snapshot: LoanPredictionSnapshot?) {
        dataAccessQueue.async { self.phonePredictionSnapshotAtGrant = snapshot }
    }

    /// INSTRUMENTATION ONLY (#69): the three IOB values that should agree at takeover — phone-at-grant,
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
    /// #39 storm latch: last phone-fallback syncId attempted (serial deviceQueue only).
    var lastPhoneFallbackSyncId: String?

    // MARK: - #73/#74 SessionInsulinLedger (SHADOW MODE)

    /// The single-owner session dose timeline (see SessionInsulinLedger.swift for the full
    /// rationale). dataAccessQueue-confined; in shadow mode it only feeds [ledger-diff] —
    /// dosing and display still read the DoseStore. Reverting = delete these hooks.
    private var sessionLedger: SessionInsulinLedger?

    /// Takeover: build a fresh ledger from the grant split. Uses the SAME config the store
    /// path nets/decays with (frozen grant basalProfile, same model provider) so the shadow
    /// diff isolates STORAGE behavior, not math.
    func ledgerSeed(finished: [DoseEntry], live: [DoseEntry]) {
        dataAccessQueue.async {
            guard let schedule = self.doseStore.basalProfile else {
                SportLog.event("ledger", "seed SKIPPED — no basal profile yet")
                return
            }
            var ledger = SessionInsulinLedger(
                basalSchedule: schedule,
                insulinModelProvider: self.doseStore.insulinModelProvider,
                longestEffectDuration: self.doseStore.longestEffectDuration)
            ledger.seed(finished: finished, live: live)
            self.sessionLedger = ledger
            SportLog.event("ledger", "seeded — \(ledger.summary) (\(finished.count) finished + \(live.count) live)")
        }
    }

    /// #74 CUTOVER FLAG: when true (g7.ledgerCutover, default false) AND a session ledger
    /// exists (loan active), the ledger drives IOB display and insulin effects; the store
    /// keeps running untouched and the [ledger-diff] line flips to shadowing the STORE.
    /// Revert = flip the flag back — no data migration in either direction.
    private var ledgerCutoverActive: Bool {
        // DEFAULT ON since build 189 (Jeremy 2026-07-29: "yes, flip the default" — the
        // side-by-sides proved the ledger against the phone at every seam). The key now
        // exists only as the one-line REVERT switch back to the store path.
        defaults.object(forKey: "g7.ledgerCutover") as? Bool ?? true
    }

    /// #84: the ledger's counterpart to the phone's `clearCachedInsulinEffects()`
    /// (LoopDataManager.swift:472). Stock reaches it through a DoseStore notification observer
    /// (LoopDataManager.swift:206-219) that fires on EVERY dosing change; under the ledger
    /// cutover our doses never touch DoseStore, so that observer never fires and the cached
    /// insulin effects went stale for the whole epoch — the prediction kept the array built at
    /// takeover and every subsequent temp basal was invisible to it (measured 2026-07-31: the
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
        insulinEffect = nil
        insulinEffectIncludingPendingInsulin = nil
        // NOT predictedGlucose — the watch deliberately diverges from the phone here, and the
        // first cut of this method broke it. Stock's clearCachedInsulinEffects() also nils
        // predictedGlucose; on the watch that value is DISPLAY-ONLY (the glance/diagnostic
        // "eventually N" row — DoseMath uses the locally-computed prediction), and #48 rules that
        // the last eventual stays visible with a freshness grade rather than blanking on a failed
        // cycle. See the identical note at the carbEffect didSet (~:552). Because this method now
        // runs on EVERY ledger write, nil-ing it here blanked the eventual after every enact —
        // observed on the wrist 2026-07-31, with the reconciliation row still rendering 106
        // because it is cached separately at predict time. The stale array was the #84 bug;
        // predictedGlucose was never part of it and is recomputed each cycle regardless.
    }

    /// A pod-ACCEPTED watch enact enters the timeline (truncating the open predecessor).
    func ledgerRecordEnact(_ dose: DoseEntry) {
        dataAccessQueue.async {
            self.sessionLedger?.recordEnact(dose)
            self.clearCachedInsulinEffects()   // #84 — the dose must reach the next prediction
        }
    }

    /// #74: a chase verdict REFUTED a previously booked assumed dose — reverse it.
    func ledgerRemoveDose(type: DoseType, startingAt: Date) {
        dataAccessQueue.async {
            if self.sessionLedger?.removeDose(type: type, startingAt: startingAt) == true {
                self.clearCachedInsulinEffects()   // #84 — a reversal changes the curve too
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
    /// Field 2026-07-22 07:16-07:42: every closed-loop cycle died on
    /// `pumpDataTooOld(06:57:51)` — the last E5 dose, i.e. the last pod contact. Under
    /// E4 the pod is orphaned, so status only refreshed when we dosed, and the loop
    /// wouldn't dose without fresh status: a permanent deadlock after 15 minutes.
    ///
    /// E4 deviation (necessary, and the only one): a status fetch needs the BLE link
    /// back, so reclaim → assert → loop → release. Skipped while our own view of the
    /// data is still fresh, because under E4 a reclaim costs pod contact that stock
    /// never pays. With E4 off the reclaim closure returns immediately and this
    /// collapses to the stock call.
    func checkPumpDataAndLoop() {
        guard let pumpManager = pumpManager else {
            loop()   // stock (:571): loop even without a pump so the cycle still runs
            return
        }

        let assertThenLoop: (@escaping () -> Void) -> Void = { done in
            pumpManager.ensureCurrentPumpData { _ in
                self.loop()
                done()
            }
        }

        let age = now().timeIntervalSince(doseStore.lastAddedPumpData)
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
              let reclaim = e4ReclaimPodForDose else {
            assertThenLoop({})
            return
        }

        SportLog.event("loan", String(format: "pump data %.0f min old — reclaiming pod to refresh status before the cycle", age / 60))
        // #101 phase 2: this reclaim fires ~100ms after reading arrival — while un-adopted
        // that is the exact moment the D2W ride appears, and the pod scan kills the G7
        // connect (2026-08-10 23:31:48). Hold the pod radio until the ride resolves.
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
                self.e4ReleasePodAfterDose?()
            }
        }
    }

    /// #101 phase 2 acquisition gate (census build 263, 2026-08-10). The fragile phase is
    /// the G7 CONNECT/AUTH ESTABLISHMENT, ~1.5s straddling the grid point — an established
    /// link coexists with pod traffic (23:36/23:41/23:46: backfill and a live read landed
    /// DURING pod handshake), and #81's forensics say the same from the pod's side. So the
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

            var error = self.updateCachedEffects()
            if error == nil {
                error = self.updatePredictedGlucoseAndRecommendedDose()
            }

            // #41 observability: a PREDICTION-stage missingDataError is otherwise
            // swallowed — the cycle-end handler suppresses missingDataError to avoid
            // double-logging enact radio-defers (which reach the loop as a wrapped
            // missingDataError too). Logging HERE, before enact, surfaces which of the
            // five inputs is nil (glucose / momentumEffect / carbEffect / insulinEffect
            // / activeInsulin) without touching the radio-defer path. This is exactly
            // the failure that made a silently non-dosing loop invisible on 2026-07-21.
            if case .missingDataError(let what)? = error {
                SportLog.event("loop", "NOT DOSING — prediction missing \(what)")
            }

            // #98 (2026-08-08): the dead-man refresh MOVED to after the enact — see the
            // verdict block below. It used to fire here, on a healthy PREDICTION alone, which
            // is a deviation from stock: stock's finishLoop takes enactRecommendedAutomaticDose's
            // error AS the loop's error (LoopDataManager.swift:888-905), so a cycle that cannot
            // reach the pump is a FAILED loop and never advances lastLoopCompleted. Ours already
            // matched stock for lastLoopCompleted/the ring; only the watchdog was wrong, and it
            // is the one surface whose whole job is to notice. Field 2026-08-08: 25 minutes of
            // podNotConnected enacts kept re-arming the dead-man because the prediction was fine.

            // Enact only when the user has closed the loop on the watch THIS session
            // (R23 as amended 2026-07-18: watch sovereign — the phone's own loop mode
            // no longer gates the wrist). Open = advisory: prediction + recommendation
            // computed above (glance display live), nothing sent to the pod.
            // Snapshot the recommendation BEFORE enacting. enactRecommendedAutomaticDose
            // clears `recommendedAutomaticDose` on success, and the cycle logging below
            // runs after it — so in CLOSED loop the log always read "rec none" no matter
            // what was decided (field 2026-07-22 08:48). The decision has to be captured
            // while it still exists.
            let decided = self.recommendedAutomaticDose?.recommendation
            self.lastRecommendation = decided   // survives the enact's clear, for the DOSING panel
            if error == nil, self._closedLoopEnabled {
                error = self.enactRecommendedAutomaticDose()
            } else if error == nil {
                self.log.default("Advisory (open loop) — computed but not enacting.")
            }

            self.lastLoopError = error

            // #98 CYCLE VERDICT — exactly one line per cycle, always. The question "did this
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
            SportLog.event("loop", String(format: "CYCLE VERDICT computed=%@ enact=%@ watchdog=%@ lastCompletedAge=%@",
                                          error == nil || (error.map { if case .enactFailed = $0 { return true } else { return false } } ?? false) ? "ok" : "FAILED",
                                          enactVerdict,
                                          watchdogRefreshed ? "refreshed" : "HELD",
                                          sinceCompleted.map { "\($0)s" } ?? "never"))

            if let error {
                self.log.error("Loop ended with error: %{public}@", String(describing: error))
                // Radio defers are logged at the defer site; don't double-log those.
                // #98: .enactFailed is NOT suppressed — that suppression is why a failed enact
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
                let rec = decided.map { $0.basalAdjustment.map { String(format: "%.2f U/h", $0.unitsPerHour) } ?? "no change" } ?? "none"
                SportLog.event("loop", "cycle OK — BG \(bg), IOB \(self.insulinOnBoard.map { String(format: "%.2f", $0.value) } ?? "—"), temp \(rec)")
                self.logPredictionBreakdown(decided: decided)
                self.publishHUDContext()
            }
        }
    }

    /// Recompute the cached effects + the prediction WITHOUT enacting — called right after a
    /// takeover so the glance shows a fresh eventual (WITH the seeded carbs) and IOB immediately,
    /// instead of the stale pre-loan cached values until the next G7 reading drives a full cycle.
    /// #69 field: carbs seeded at takeover weren't in the glance eventual (it stayed the last
    /// pre-loan insulin-only prediction because no cycle had run), and IOB read ~0 while the seed
    /// store held the real value — both because the glance reads CACHED IOB/eventual that only a
    /// completed cycle refreshes. This is DISPLAY-ONLY: it never enacts (enact-only-on-fresh-reading
    /// is enforced by loop()'s CGM-triggered callers), so dosing timing is unchanged.
    func refreshPredictionForGlance() {
        dataAccessQueue.async {
            var error = self.updateCachedEffects()
            if error == nil {
                error = self.updatePredictedGlucoseAndRecommendedDose()
            }
            if case .missingDataError(let what)? = error {
                SportLog.event("loop", "takeover prediction refresh — not yet (missing \(what))")
            } else if error == nil {
                // Cache the recommendation for the DOSING panel (as loop() does), but do NOT enact.
                self.lastRecommendation = self.recommendedAutomaticDose?.recommendation
                SportLog.event("loop", "takeover prediction refresh — IOB \(self.insulinOnBoard.map { String(format: "%.2f U", $0.value) } ?? "—"), eventual + carbs refreshed (no enact)")
                self.logPredictionBreakdown(decided: self.recommendedAutomaticDose?.recommendation)
            }
            self.publishHUDContext()
        }
    }

    /// 134 dosing-audit instrumentation (Jeremy 2026-07-20: "make sure prediction is
    /// well instrumented in the logs so we can iterate to the answer as efficiently
    /// as possible"). One line per cycle decomposing WHAT the dose math saw: each
    /// cached effect's net mg/dL contribution over its horizon, the eventual BG, and
    /// the recommendation. A missing input reads "—" — absence is a finding, not a
    /// blank (the 20:31 carb-invalidation bug would have been one glance: COB present
    /// on screen, "carbs —" here).
    private func logPredictionBreakdown(decided: AutomaticDoseRecommendation? = nil) {   // dataAccessQueue
        // FORWARD-LOOKING from `now`, not across the whole stored array (Jeremy
        // 2026-07-22): effect already realized is baked into the CURRENT BG and cannot
        // move `eventual` — only effect still to come can. Anchoring at the array start
        // reached hours back and reported the whole night's insulin (-783 mg/dL against
        // 1.32 U IOB), which explained nothing and matched nothing. Anchored at now,
        // the four contributions decompose `eventual − current`, so a line that doesn't
        // add up is itself the bug signal.
        func net(_ effects: [GlucoseEffect]?) -> String {
            guard let effects, let last = effects.last else { return "—" }
            let t = now()
            guard let anchor = effects.last(where: { $0.startDate <= t }) ?? effects.first else { return "—" }
            let delta = last.quantity.doubleValue(for: .milligramsPerDeciliter) - anchor.quantity.doubleValue(for: .milligramsPerDeciliter)
            return String(format: "%+.0f", delta)
        }
        let eventual = predictedGlucose?.last.map { String(format: "%.0f", $0.quantity.doubleValue(for: .milligramsPerDeciliter)) } ?? "—"
        let rc = retrospectiveGlucoseEffect.isEmpty ? "—" : net(retrospectiveGlucoseEffect)
        let rec: String
        // Prefer the caller's pre-enact snapshot; `recommendedAutomaticDose` is already
        // cleared by a successful enact in closed loop.
        if let r = decided ?? recommendedAutomaticDose?.recommendation {
            let basal = r.basalAdjustment.map { String(format: "%.2f U/h", $0.unitsPerHour) } ?? "no basal change"
            let bolus = r.bolusUnits.map { String(format: " + auto-bolus %.2f U", $0) } ?? ""
            rec = basal + bolus
        } else {
            rec = "none"
        }
        // #3 (2026-07-25): the dose keys on EVENTUAL, with the predicted MIN + suspend
        // threshold as the safety brake. Put all three on the decision line so "eventual <
        // target ⇒ reduce" (and "why temp 0") reads without cross-referencing [curve].
        let mgdlU = HKUnit.milligramsPerDeciliter
        let minPredicted: String = {
            guard let fwd = predictedGlucose?.filter({ $0.startDate >= now() }), !fwd.isEmpty,
                  let m = fwd.min(by: { $0.quantity.doubleValue(for: mgdlU) < $1.quantity.doubleValue(for: mgdlU) })
            else { return "—" }
            return String(format: "%.0f@%dm", m.quantity.doubleValue(for: mgdlU), Int(m.startDate.timeIntervalSince(now()) / 60))
        }()
        let suspendThr = settings.suspendThreshold.map { String(format: "%.0f", $0.quantity.doubleValue(for: mgdlU)) } ?? "—"
        SportLog.event("predict", "eventual \(eventual) · min \(minPredicted) · suspendThr \(suspendThr) · net effects: carbs \(net(carbEffect)), insulin \(net(insulinEffect)), momentum \(net(glucoseMomentumEffect)), RC \(rc) · rec \(rec)")
        SportLog.event("curve", curveSummary(predictedGlucose))
        emitPredictionSnapshotAndDiff()
        // #86: the third decomposition — the one that ADDS UP — plus the cache the DOSING
        // panel renders. Last, so `[predict]` / `[predict-snapshot]` / `[predict-recon]` read
        // raw → marginal → exact in that order for any one cycle.
        emitPredictionReconciliation()
    }

    /// INSTRUMENTATION ONLY (#45): three lines appended each cycle after `[predict]`/`[curve]` —
    /// `[predict-snapshot]` (leave-one-out per-effect impact on the eventual), `[predict-diff]` (that
    /// same decomposition minus the phone's grant snapshot, term by term — the ~58 mg/dL takeover gap
    /// localized with zero manual arithmetic), and `[freshness]` (a diagnostic verdict that gates
    /// NOTHING). Impacts are MARGINAL (momentum blends non-linearly), so they need not sum to
    /// `eventual − start`; the residual is expected and itself informative.
    private func emitPredictionSnapshotAndDiff() {   // dataAccessQueue
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        let mgdl = HKUnit.milligramsPerDeciliter
        func signed(_ v: Double?) -> String { v.map { String(format: "%+.0f", $0) } ?? "—" }
        func plain(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
        func ageS(_ d: Date?) -> String { d.map { String(format: "%.0f", now().timeIntervalSince($0)) } ?? "—" }

        let base = counterfactualEventualMgdl(.none)
        func impact(_ drop: CFDrop) -> Double? {
            guard let base, let dropped = counterfactualEventualMgdl(drop) else { return nil }
            return base - dropped
        }
        let impMom = impact(.momentum), impIns = impact(.insulin)
        let impCarb = impact(.carb), impRC = impact(.rc)
        let iob = insulinOnBoard?.value
        let momPts = glucoseMomentumEffect?.count ?? 0
        let rcDisc = retrospectiveGlucoseDiscrepancies?.count ?? 0
        let startV = glucoseStore.latestGlucose?.quantity.doubleValue(for: mgdl)
        let glucoseDate = glucoseStore.latestGlucose?.startDate
        let glucoseAge = glucoseDate.map { now().timeIntervalSince($0) }
        let pumpAge = now().timeIntervalSince(doseStore.lastAddedPumpData)

        SportLog.event("predict-snapshot", String(format:
            "start=%@@%@s eventual=%@ | impact[loo]: mom %@ ins %@ carb %@ RC %@ | IOB=%@ | momPts=%d rcDisc=%d | pumpAge=%.0fs",
            plain(startV), ageS(glucoseDate), plain(base),
            signed(impMom), signed(impIns), signed(impCarb), signed(impRC),
            iob.map { String(format: "%.2f", $0) } ?? "—", momPts, rcDisc, pumpAge))

        // [predict-diff] — only while a fresh (<20 min) phone snapshot is stashed; else self-expire.
        if let p = phonePredictionSnapshotAtGrant {
            let snapAge = now().timeIntervalSince(p.snapshotAt)
            if snapAge > 20 * 60 {
                phonePredictionSnapshotAtGrant = nil
            } else {
                func diff(_ w: Double?, _ pv: Double) -> String { w.map { String(format: "%+.0f", $0 - pv) } ?? "—" }
                SportLog.event("predict-diff", String(format:
                    "vs phone@grant (snapAge %.0fm): dStart=%@ dEventual=%@ | dImpact: mom %@ ins %@ carb %@ RC %@ | dIOB=%@ | momPts w%d/p%d rcDisc w%d/p%d",
                    snapAge / 60,
                    diff(startV, p.startGlucoseMgdl), diff(base, p.eventualMgdl),
                    diff(impMom, p.impactMomentumMgdl), diff(impIns, p.impactInsulinMgdl),
                    diff(impCarb, p.impactCarbMgdl), diff(impRC, p.impactRCMgdl),
                    iob.map { String(format: "%+.2f", $0 - p.iobUnits) } ?? "—",
                    momPts, p.momentumPointCount, rcDisc, p.rcDiscrepancyCount))
            }
        }

        // [freshness] — DIAGNOSTIC ONLY; gates neither display nor dosing.
        let recency = LoopCoreConstants.inputDataRecencyInterval
        let verdict: String
        if let age = glucoseAge, age <= recency {
            verdict = (momPts > 0 && rcDisc > 0) ? "fresh" : "warming"
        } else {
            verdict = "stale"
        }
        SportLog.event("freshness", String(format:
            "%@ · momentum %d pts · latest glucose age %@s (recency %.0fm) · RC discrepancies %d",
            verdict, momPts, ageS(glucoseDate), recency / 60, rcDisc))
    }

    /// Sport Mode's momentum look-back window. Wider than stock's 15 min (`GlucoseMath`) so the
    /// seeded post-takeover history plus live reads clear the ≥3-sample floor; paired with
    /// `requireContinuous: false` at the call site so a single missed G7 read (radio shared with the
    /// pod) doesn't zero momentum for ~10 min — worst exactly during exercise. The 4 mg/dL/min
    /// velocity cap + provenance + calibration guards still bound it.
    static let sportMomentumWindow: TimeInterval = .minutes(25)

    /// INSTRUMENTATION ONLY (#45/#51): probe which of stock `linearMomentumEffect`'s gates the
    /// watch's glucose window passes right now — so "momentum over 0 pts" is explained, not guessed.
    /// Uses the SAME window + relaxed-continuity rule the live call uses (`sportMomentumWindow`,
    /// `requireContinuous: false`), so `avail`/`stockPts` match the real momentum. `cont(info)` is
    /// reported for INSIGHT only — Sport Mode no longer requires continuity. `isContinuous`/
    /// `hasSingleProvenance` are internal in LoopKit so they're recomputed locally (read-only);
    /// `containsCalibrations()`/`linearMomentumEffect()` are public and reused as the cross-check.
    private func emitMomentumGateDiagnostic(asOf date: Date, completion: @escaping () -> Void) {
        let start = date.addingTimeInterval(-Self.sportMomentumWindow)
        glucoseStore.getGlucoseSamples(start: start, end: nil) { result in
            defer { completion() }
            guard case .success(let samples) = result else {
                SportLog.event("momentum-gate", "avail=NO (sample fetch failed)")
                return
            }
            let n = samples.count
            let countPass = n > 2
            let span: TimeInterval = (samples.first != nil && samples.last != nil)
                ? abs(samples.first!.startDate.timeIntervalSince(samples.last!.startDate)) : 0
            let contThr = TimeInterval(minutes: 5) * Double(n)   // mirrors GlucoseMath.isContinuous(within: 5min)
            let contPass = n > 0 && span < contThr
            var maxGap: TimeInterval = 0
            if samples.count > 1 {
                for i in 1..<samples.count {
                    maxGap = Swift.max(maxGap, samples[i].startDate.timeIntervalSince(samples[i-1].startDate))
                }
            }
            let provs = Set(samples.map { $0.provenanceIdentifier })
            let provPass = provs.count <= 1
            let calibPass = !samples.containsCalibrations()
            let stockPts = samples.linearMomentumEffect(requireContinuous: false).count   // matches the live Sport Mode call
            let avail = stockPts > 0
            let latestAge = samples.last.map { date.timeIntervalSince($0.startDate) }
            let ids = provs.map { String($0.prefix(8)) }.joined(separator: ",")
            SportLog.event("momentum-gate", String(format:
                "avail=%@ (stockPts=%d) · count=%d %@ · cont(info)=%@ (span=%.1fmin thr=%.1fmin maxGap=%.1fmin) · provenance=%@ (%d distinct: [%@]) · calib=%@ · latest age %@s",
                avail ? "YES" : "NO", stockPts,
                n, countPass ? "PASS" : "FAIL",
                contPass ? "PASS" : "FAIL", span / 60, contThr / 60, maxGap / 60,
                provPass ? "PASS" : "FAIL", provs.count, ids,
                calibPass ? "PASS" : "FAIL",
                latestAge.map { String(format: "%.0f", $0) } ?? "—"))
        }
    }

    /// INSTRUMENTATION ONLY (#69): the three-way IOB reconciliation at the first post-takeover cycle.
    /// Leg 1 (seed − phone) isolates wire/seed fidelity (only measurable now that the grant carries
    /// phone IOB); Leg 2 (cycle1 − seed) isolates the post-status-read reconciliation. `dt` and
    /// `phoneIOBAge` contextualize the aging so a stale phone stamp can be decay-corrected offline.
    private func emitIOBDiff(anchors: (phone: Double?, phoneDate: Date?, seed: Double, at: Date), cycle1: Double?) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        let leg1 = anchors.phone.map { String(format: "%+.2f", anchors.seed - $0) } ?? "—"
        let leg2 = cycle1.map { String(format: "%+.2f", $0 - anchors.seed) } ?? "—"
        let dt = now().timeIntervalSince(anchors.at)
        let phoneAge = anchors.phoneDate.map { String(format: "%.0f", now().timeIntervalSince($0)) } ?? "—"
        let lastReconAge = doseStore.lastPumpEventsReconciliation.map { String(format: "%.0fs", now().timeIntervalSince($0)) } ?? "nil"
        let lastPumpAge = String(format: "%.0fs", now().timeIntervalSince(doseStore.lastAddedPumpData))
        SportLog.event("iob-diff", String(format:
            "phoneIOB=%@ seedIOB=%.2f cycle1=%@ · Δ(seed−phone)=%@[wire] · Δ(cycle1−seed)=%@[reconcile] · dt(seed→cycle1)=%.0fs · phoneIOBAge=%@s · lastReconAge=%@ lastPumpAge=%@",
            anchors.phone.map { String(format: "%.2f", $0) } ?? "—", anchors.seed,
            cycle1.map { String(format: "%.2f", $0) } ?? "—",
            leg1, leg2, dt, phoneAge, lastReconAge, lastPumpAge))
    }

    /// INSTRUMENTATION ONLY (#69): per-dose IOB decomposition at a labeled instant (SEED-IN vs
    /// CYCLE1), so a re-timed / superseded / added dose between the seed and the first pod-status read
    /// is visible — the mechanism behind the ~0.3U SEED-IN→first-cycle drop. One-shot; never per-cycle.
    /// `netBasalUnits` already folds in `scheduledBasalRate`, so the SAME window showing a different
    /// net between labels is the scheduled-basal-netting signature (H2); a re-timed/added row is H1.
    func dumpIOBDecomp(_ label: String, at t: Date) {
        dataAccessQueue.async {
            let start = t.addingTimeInterval(-Swift.min(self.doseStore.longestEffectDuration, .hours(8)))
            self.doseStore.getNormalizedDoseEntries(start: start, end: t) { result in
                guard case .success(let doses) = result else {
                    SportLog.event("iob-decomp", "@\(label) — dose fetch failed")
                    return
                }
                let uhr = HKUnit.internationalUnit().unitDivided(by: .hour())
                let tf = DateFormatter()
                tf.dateFormat = "HH:mm:ss"
                var netSum = 0.0
                var rows: [String] = []
                for d in doses where abs(d.netBasalUnits) > 0.0001 || d.type == .bolus {
                    netSum += d.netBasalUnits
                    let sched = d.scheduledBasalRate.map { String(format: "%.2f", $0.doubleValue(for: uhr)) } ?? "nil"
                    let id = d.syncIdentifier.map { String($0.suffix(6)) } ?? "—"
                    // #80: `del=` shows whether the pod's ACTUAL delivery rode the wire.
                    // del=nil means LoopKit falls back to round(programmedUnits) — the
                    // rounding path that over-states IOB ~0.025 U per temp slice. Post-fix,
                    // pod-native seeded temps must show a number here, not "nil".
                    let del = d.deliveredUnits.map { String(format: "%.3f", $0) } ?? "nil"
                    rows.append(String(format: "%@ %@..%@ net=%+.3f sched=%@ mut=%@ del=%@ id=%@",
                                       "\(d.type)", tf.string(from: d.startDate), tf.string(from: d.endDate),
                                       d.netBasalUnits, sched, d.isMutable ? "Y" : "n", del, id))
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
        let mgdl = HKUnit.milligramsPerDeciliter
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

    // MARK: - Effect refresh (mirrors update(for:) — LoopDataManager.swift:963)

    /// Same store entry points, same DispatchGroup shape as the phone's `update(for:)`:
    /// momentum from GlucoseStore, insulin effects (with and without pending) from DoseStore,
    /// counteraction from GlucoseStore, carb effects (dynamic absorption) from CarbStore,
    /// IOB from DoseStore, then retrospective correction.
    private func updateCachedEffects() -> WatchLoopError? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        let updateGroup = DispatchGroup()

        guard let latestGlucose = glucoseStore.latestGlucose else {
            return .missingDataError("glucose")
        }
        let lastGlucoseDate = latestGlucose.startDate

        let retrospectiveStart = lastGlucoseDate.addingTimeInterval(-type(of: retrospectiveCorrection).retrospectionInterval)
        let earliestEffectDate = Date(timeInterval: .hours(-24), since: now())
        let nextCounteractionEffectDate = insulinCounteractionEffects.last?.endDate ?? earliestEffectDate
        let insulinEffectStartDate = nextCounteractionEffectDate.addingTimeInterval(.minutes(-5))

        if glucoseMomentumEffect == nil {
            updateGroup.enter()
            // SPORT MODE momentum deviation (Jeremy 2026-07-26). This inlines stock
            // `getRecentMomentumEffect` (fetch the look-back window → `linearMomentumEffect`) so both
            // deviations are visible right here: a 25-min window (vs stock 15) and
            // `requireContinuous: false`. Together they stop a single missed G7 read (radio shared
            // with the pod) from zeroing momentum for ~10 min — worst exactly during exercise. Stock's
            // other guards hold: ≥3 samples, single provenance, no calibrations, 4 mg/dL/min velocity
            // cap. The phone/stock path is untouched (`getRecentMomentumEffect` and its defaults).
            glucoseStore.getGlucoseSamples(start: now().addingTimeInterval(-Self.sportMomentumWindow), end: nil) { result in
                switch result {
                case .failure(let error):
                    self.log.error("Failure getting recent momentum effect: %{public}@", String(describing: error))
                    self.glucoseMomentumEffect = nil
                case .success(let samples):
                    let effects = samples.linearMomentumEffect(requireContinuous: false)
                    self.glucoseMomentumEffect = effects
                    // #3 momentum input (2026-07-25): the net is in [predict]; this exposes
                    // whether it's built from FRESH, sufficient glucose. Sparse/stale input
                    // (gappy G7, #15) makes momentum lag or overshoot — invisible in the net.
                    let mgdlM = HKUnit.milligramsPerDeciliter
                    let mDelta = (effects.first != nil && effects.last != nil)
                        ? String(format: "%+.0f", effects.last!.quantity.doubleValue(for: mgdlM) - effects.first!.quantity.doubleValue(for: mgdlM))
                        : "—"
                    let mAge = self.glucoseStore.latestGlucose.map { String(format: "%.0fs", self.now().timeIntervalSince($0.startDate)) } ?? "—"
                    SportLog.event("momentum", "effect Δ=\(mDelta) over \(effects.count) pts · latest glucose age \(mAge)")
                }
                updateGroup.leave()
            }
            // INSTRUMENTATION ONLY (#45/#51): whenever momentum is (re)computed — every takeover and
            // every glucose invalidation — probe EXACTLY which stock gate the window passes/fails, so
            // "over 0 pts" stops being a mystery. FIRE-AND-FORGET: a pure diagnostic must NOT sit inside
            // the dosing cycle's DispatchGroup wait (it reads nothing from the cycle), so it can never
            // add latency to, or share the unbounded blocking wait of, the dosing critical path. Its
            // [momentum-gate] line may therefore land just after [predict] — cosmetic ordering only.
            emitMomentumGateDiagnostic(asOf: now()) { }
        }

        if insulinEffect == nil || insulinEffect?.first?.startDate ?? .distantFuture > insulinEffectStartDate {
            // #74 CUTOVER: behind g7.ledgerCutover, the session ledger drives the insulin
            // effects — same public InsulinMath, same basalDosingEnd trim-at-now contract
            // (canon: no forward credit for temps in the prediction). Fail-safe: any
            // missing ledger precondition falls back to the store path, never to nil.
            if ledgerCutoverActive, let ledger = sessionLedger,
               let isf = doseStore.insulinSensitivityScheduleApplyingOverrideHistory {
                // filterDateRange mirrors the store path exactly; keep it.
                //
                // #84 CORRECTION (2026-07-31): the comment that stood here claimed this call
                // "re-arms the recompute gate above every cycle". It does not, and the freeze it
                // warned about is exactly what shipped. The gate only fires when the cached array
                // starts LATER than the needed start, i.e. when EARLIER data is wanted; it cannot
                // re-arm as the clock advances, because insulinEffectStartDate moves FORWARD with
                // each cycle while first.startDate stays put. Worse, after a takeover
                // invalidateGlucoseDerivedEffects() empties insulinCounteractionEffects, so
                // insulinEffectStartDate falls back to ~24 h in the past and the comparison can
                // never be true again. What actually keeps this array fresh is
                // clearCachedInsulinEffects() on every ledger mutation (see ledgerRecordEnact) —
                // the ledger's stand-in for the DoseStore notification stock relies on. Do not
                // re-derive freshness from this gate.
                self.insulinEffect = ledger.glucoseEffects(insulinSensitivity: isf, basalDosingEnd: now(), from: insulinEffectStartDate, to: nil).filterDateRange(insulinEffectStartDate, nil)
            } else {
                updateGroup.enter()
                doseStore.getGlucoseEffects(start: insulinEffectStartDate, end: nil, basalDosingEnd: now()) { result in
                    switch result {
                    case .failure(let error):
                        self.log.error("Could not fetch insulin effects: %{public}@", String(describing: error))
                        self.insulinEffect = nil
                    case .success(let effects):
                        self.insulinEffect = effects
                    }
                    updateGroup.leave()
                }
            }
        }

        if insulinEffectIncludingPendingInsulin == nil {
            if ledgerCutoverActive, let ledger = sessionLedger,
               let isf = doseStore.insulinSensitivityScheduleApplyingOverrideHistory {
                self.insulinEffectIncludingPendingInsulin = ledger.glucoseEffects(insulinSensitivity: isf, basalDosingEnd: nil, from: insulinEffectStartDate, to: nil).filterDateRange(insulinEffectStartDate, nil)
            } else {
                updateGroup.enter()
                doseStore.getGlucoseEffects(start: insulinEffectStartDate, end: nil, basalDosingEnd: nil) { result in
                    switch result {
                    case .failure(let error):
                        self.log.error("Could not fetch insulin effects including pending: %{public}@", String(describing: error))
                        self.insulinEffectIncludingPendingInsulin = nil
                    case .success(let effects):
                        self.insulinEffectIncludingPendingInsulin = effects
                    }
                    updateGroup.leave()
                }
            }
        }

        _ = updateGroup.wait(timeout: .distantFuture)

        if nextCounteractionEffectDate < lastGlucoseDate, let insulinEffect = insulinEffect {
            updateGroup.enter()
            glucoseStore.getCounteractionEffects(start: nextCounteractionEffectDate, end: nil, to: insulinEffect) { result in
                switch result {
                case .failure(let error):
                    self.log.error("Failure getting counteraction effects: %{public}@", String(describing: error))
                case .success(let velocities):
                    self.insulinCounteractionEffects.append(contentsOf: velocities)
                }
                self.insulinCounteractionEffects = self.insulinCounteractionEffects.filterDateRange(earliestEffectDate, nil)
                updateGroup.leave()
            }
            _ = updateGroup.wait(timeout: .distantFuture)
        }

        if carbEffect == nil {
            updateGroup.enter()
            carbStore.getGlucoseEffects(start: retrospectiveStart, end: nil, effectVelocities: insulinCounteractionEffects) { result in
                switch result {
                case .failure(let error):
                    self.log.error("Failure getting carb effects: %{public}@", String(describing: error))
                    self.carbEffect = nil
                    self.recentCarbEntries = nil
                case .success(let (entries, effects)):
                    // #47: the port discarded these entries. The potential-carb-entry prediction
                    // needs them to pick a branch: a new entry whose effect is INDEPENDENT of what
                    // is already on board can simply be summed onto `carbEffect`, but a back-dated
                    // entry overlaps observed glucose, so dynamic absorption and retrospective
                    // correction have to be recomputed across the whole set. Same discriminator
                    // the phone uses (LoopDataManager:1270).
                    self.recentCarbEntries = entries
                    self.carbEffect = effects
                }
                updateGroup.leave()
            }
        }

        // The store IOB is fetched EITHER WAY: as the live number (shadow mode) or as the
        // shadow series for [ledger-diff] (cutover mode — the comparison must not collapse
        // to ledger-vs-ledger).
        let cutover = ledgerCutoverActive && sessionLedger != nil
        updateGroup.enter()
        doseStore.insulinOnBoard(at: now()) { result in
            switch result {
            case .failure(let error):
                self.log.error("Failure getting insulin on board: %{public}@", String(describing: error))
                if cutover { self.storeIOBShadow = nil } else { self.insulinOnBoard = nil }
            case .success(let insulinValue):
                if cutover { self.storeIOBShadow = insulinValue.value } else { self.insulinOnBoard = insulinValue }
            }
            updateGroup.leave()
        }
        if cutover, let ledger = sessionLedger {
            // #74 CUTOVER: displayed + dosing IOB from the single-owner timeline.
            self.insulinOnBoard = InsulinValue(startDate: now(), value: ledger.insulinOnBoard(at: now()))
        }

        _ = updateGroup.wait(timeout: .distantFuture)

        // #73/#74 SHADOW: the ledger's IOB next to the store's, every cycle. Δ attribution is
        // TWO-SIDED (adversarial review): a step-drop in STORE is the cliff class (store losing
        // doses); a persistent ledger<store after an UNCERTAIN enact is the LEDGER's known gap
        // (uncertain-command cluster unledgered); a one-cycle ledger>store spike at a MANUAL
        // bolus is expected FIFO timing (ledger records at accept, store at the pod report).
        // Cutover only after field diffs prove out with these signatures accounted.
        if let ledger = sessionLedger {
            let ledgerIOB = ledger.insulinOnBoard(at: now())
            let storeIOB = ledgerCutoverActive ? storeIOBShadow : insulinOnBoard?.value
            SportLog.event("ledger-diff", String(format: "store=%@ ledger=%.2f Δ=%@ · %@%@",
                                                 storeIOB.map { String(format: "%.2f", $0) } ?? "—",
                                                 ledgerIOB,
                                                 storeIOB.map { String(format: "%+.2f", $0 - ledgerIOB) } ?? "—",
                                                 ledger.summary,
                                                 ledgerCutoverActive ? " · CUTOVER (ledger drives; store is shadow)" : ""))
        }

        // INSTRUMENTATION ONLY (#69): the FIRST post-takeover cycle — now that this cycle's IOB is
        // computed, reconcile phone-IOB (grant snapshot) vs SEED-IN anchor vs cycle-1 computed, and
        // dump the per-dose decomposition once. One-shot: consuming the anchors clears them.
        if let anchors = takeoverIOBAnchors {
            takeoverIOBAnchors = nil
            emitIOBDiff(anchors: anchors, cycle1: insulinOnBoard?.value)
            dumpIOBDecomp("CYCLE1", at: now())
        }

        if retrospectiveGlucoseDiscrepancies == nil {
            do {
                try updateRetrospectiveGlucoseEffect()
            } catch {
                self.log.error("Failure computing retrospective correction: %{public}@", String(describing: error))
            }
        }

        return nil
    }

    // MARK: - Retrospective correction (mirrors updateRetrospectiveGlucoseEffect() — :1578)

    /// Identical math; the one shape difference is guard-throw where the phone force-unwraps
    /// settings (on the watch a nil schedule is a normal pre-push state and must deny, not
    /// crash).
    private func updateRetrospectiveGlucoseEffect() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let carbEffects = self.carbEffect else {
            retrospectiveGlucoseDiscrepancies = nil
            retrospectiveGlucoseEffect = []
            throw WatchLoopError.missingDataError("carbEffect")
        }

        guard let glucose = glucoseStore.latestGlucose else {
            retrospectiveGlucoseEffect = []
            throw WatchLoopError.missingDataError("glucose")
        }

        guard let insulinSensitivitySchedule = settings.insulinSensitivitySchedule,
              let basalRateSchedule = settings.basalRateSchedule,
              let glucoseTargetRangeSchedule = settings.glucoseTargetRangeSchedule else {
            retrospectiveGlucoseEffect = []
            throw WatchLoopError.configurationError("retrospective correction schedules")
        }

        retrospectiveGlucoseDiscrepancies = insulinCounteractionEffects.subtracting(carbEffects, withUniformInterval: carbStore.delta)

        let insulinSensitivity = insulinSensitivitySchedule.quantity(at: glucose.startDate)
        let basalRate = basalRateSchedule.value(at: glucose.startDate)
        let correctionRange = glucoseTargetRangeSchedule.quantityRange(at: glucose.startDate)

        retrospectiveGlucoseEffect = retrospectiveCorrection.computeEffect(
            startingAt: glucose,
            retrospectiveGlucoseDiscrepanciesSummed: retrospectiveGlucoseDiscrepanciesSummed,
            recencyInterval: LoopCoreConstants.inputDataRecencyInterval,
            insulinSensitivity: insulinSensitivity,
            basalRate: basalRate,
            correctionRange: correctionRange,
            retrospectiveCorrectionGroupingInterval: LoopMath.retrospectiveCorrectionGroupingInterval
        )
        // #46/#3 RC input (2026-07-25): surfaces the active RC TYPE plus how much RC is
        // contributing. (#46 CLOSED 2026-07-28: the watch DOES track the phone's Integral
        // toggle — set at takeover from the grant; the setter shares this serial queue and is
        // enqueued before the first prediction, so no first-cycle Standard→Integral jump.
        // See setIntegralRetrospectiveCorrection + docs/PREDICTION_FIDELITY.md.)
        let rcType = retrospectiveCorrection is IntegralRetrospectiveCorrection ? "Integral" : "Standard"
        let mgdlRC = HKUnit.milligramsPerDeciliter
        let rcNet = (retrospectiveGlucoseEffect.first != nil && retrospectiveGlucoseEffect.last != nil)
            ? String(format: "%+.0f", retrospectiveGlucoseEffect.last!.quantity.doubleValue(for: mgdlRC) - retrospectiveGlucoseEffect.first!.quantity.doubleValue(for: mgdlRC))
            : "0"
        SportLog.event("rc", "type=\(rcType) · discrepancies=\(retrospectiveGlucoseDiscrepancies?.count ?? 0) · effect net \(rcNet)")
    }

    // MARK: - Prediction (mirrors predictGlucose(using:) — :1228)

    /// Same `LoopMath.predictGlucose(startingAt:momentum:effects:)` combination over the same
    /// four effect inputs the phone enables by default (`PredictionInputEffect.all` with
    /// `LoopConstants.retrospectiveCorrectionEnabled == true`). The phone's potential-bolus/
    /// potential-carb-entry arms are meal-entry UI concerns and arrive with that flow.
    /// Retrospective correction recomputed against a hypothetical carb effect, WITHOUT touching
    /// `self.retrospectiveGlucoseEffect` — the cached one belongs to the loop, and a what-if the
    /// user may still cancel must not disturb it. Mirrors LoopDataManager:1613-1630, with the
    /// phone's force-unwrapped schedules replaced by guards: the watch reaches this from a UI
    /// flow rather than from an already-validated dosing cycle, so a missing schedule must fail
    /// loudly rather than trap.
    ///
    /// Carries one inherited wart, deliberately un-fixed: `IntegralRetrospectiveCorrection` holds
    /// accumulator state across calls, so evaluating a what-if perturbs it. Stock has exactly this
    /// behaviour at the same call site, and diverging here would put the watch's RC on a different
    /// trajectory from the phone's — a worse bug than the one it would fix. Flagged, not patched.
    private func computeRetrospectiveGlucoseEffect(startingAt glucose: GlucoseValue, carbEffects: [GlucoseEffect]) -> [GlucoseEffect] {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let insulinSensitivitySchedule = settings.insulinSensitivitySchedule,
              let basalRateSchedule = settings.basalRateSchedule,
              let glucoseTargetRangeSchedule = settings.glucoseTargetRangeSchedule else {
            SportLog.event("predict", "#47 RC recompute SKIPPED — missing schedules; the potential carb effect stands without retrospective correction")
            return []
        }

        let discrepancies = insulinCounteractionEffects.subtracting(carbEffects, withUniformInterval: carbStore.delta)
        let summed = discrepancies.combinedSums(of: LoopMath.retrospectiveCorrectionGroupingInterval * retrospectiveCorrectionGroupingIntervalMultiplier)

        return retrospectiveCorrection.computeEffect(
            startingAt: glucose,
            retrospectiveGlucoseDiscrepanciesSummed: summed,
            recencyInterval: LoopCoreConstants.inputDataRecencyInterval,
            insulinSensitivity: insulinSensitivitySchedule.quantity(at: glucose.startDate),
            basalRate: basalRateSchedule.value(at: glucose.startDate),
            correctionRange: glucoseTargetRangeSchedule.quantityRange(at: glucose.startDate),
            retrospectiveCorrectionGroupingInterval: LoopMath.retrospectiveCorrectionGroupingInterval
        )
    }

    /// - Parameter potentialCarbEntry: #47 — a carb entry the user is CONSIDERING but has not
    ///   saved. Folding it into the prediction here is what lets the watch recommend a meal bolus
    ///   on its own; without it the carb flow had to ask the phone, whose answer is computed from
    ///   the phone's own books and is therefore blind to everything the watch has done since the
    ///   grant (and simply absent when the phone is out of range).
    private func predictGlucose(includingPendingInsulin: Bool = false,
                                potentialCarbEntry: NewCarbEntry? = nil) throws -> [PredictedGlucoseValue] {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let glucose = glucoseStore.latestGlucose else {
            throw WatchLoopError.missingDataError("glucose")
        }

        let pumpStatusDate = doseStore.lastAddedPumpData
        let lastGlucoseDate = glucose.startDate

        // Recency gating, same constants as the phone (LoopCoreConstants).
        guard now().timeIntervalSince(lastGlucoseDate) <= LoopCoreConstants.inputDataRecencyInterval else {
            throw WatchLoopError.glucoseTooOld(date: glucose.startDate)
        }

        guard lastGlucoseDate.timeIntervalSince(now()) <= LoopCoreConstants.futureGlucoseDataInterval else {
            throw WatchLoopError.invalidFutureGlucose(date: lastGlucoseDate)
        }

        // LOAN AUTHORITY (157, Jeremy 2026-07-22, explicit go). Stock's stale-pump-data
        // gate exists for pumps that can act unilaterally (user button presses, unknown
        // boluses) — stale data there means IOB may be wrong, so don't compute a dose from
        // it. A loaned pod has exactly ONE commander: this watch. It runs the last program
        // we gave it and nothing else, so the books remain authoritative through a comms
        // blackout and a fresh CGM should always yield a prediction and a recommendation.
        // The one loan case where the books genuinely can diverge is a command sent but
        // unacked — stock's own deliveryIsUncertain flag — so THAT still gates. The enact
        // itself still requires a live link (physics, not policy); this only stops a comms
        // hiccup from blacking out the math. Field: 22:58-23:08 cycles threw here with
        // fresh CGM, sane IOB, and a blank eventual on the wrist.
        if now().timeIntervalSince(pumpStatusDate) > LoopCoreConstants.inputDataRecencyInterval {
            guard pumpManager != nil, pumpManager?.status.deliveryIsUncertain == false else {
                throw WatchLoopError.pumpDataTooOld(date: pumpStatusDate)
            }
            SportLog.event("loop", String(format: "pump data %.0f min old — proceeding under loan authority (no uncertain command)", now().timeIntervalSince(pumpStatusDate) / 60))
        }

        var momentum: [GlucoseEffect] = []
        var effects: [[GlucoseEffect]] = []
        var retrospectiveEffect = self.retrospectiveGlucoseEffect

        // #47 potential carb entry. Ported branch-for-branch from LoopDataManager:1266-1307 —
        // the two cases are NOT interchangeable and the split is the whole point.
        if let potentialCarbEntry = potentialCarbEntry {
            let retrospectiveStart = lastGlucoseDate.addingTimeInterval(-type(of: retrospectiveCorrection).retrospectionInterval)

            if potentialCarbEntry.startDate > lastGlucoseDate || recentCarbEntries?.isEmpty != false {
                // The entry starts after the last reading (or nothing else is on board), so no
                // observed glucose can have been influenced by it yet: its effect is independent
                // of the cached one and the two simply sum.
                if let carbEffect = self.carbEffect {
                    effects.append(carbEffect)
                }
                effects.append(try carbStore.glucoseEffects(
                    of: [potentialCarbEntry],
                    startingAt: retrospectiveStart,
                    endingAt: nil,
                    effectVelocities: insulinCounteractionEffects))
            } else {
                // Back-dated into a window we have already observed. Summing here would
                // double-count: the counteraction effects over that window ALREADY contain the
                // meal's rise, and retrospective correction was computed against a carb effect
                // that did not know about it. So recompute dynamic absorption across the whole
                // set, then recompute RC against that.
                var entries = (recentCarbEntries ?? []).map {
                    NewCarbEntry(quantity: $0.quantity, startDate: $0.startDate, foodType: nil, absorptionTime: $0.absorptionTime)
                }
                entries.append(potentialCarbEntry)
                entries.sort(by: { $0.startDate > $1.startDate })

                let potentialCarbEffect = try carbStore.glucoseEffects(
                    of: entries,
                    startingAt: retrospectiveStart,
                    endingAt: nil,
                    effectVelocities: insulinCounteractionEffects)
                effects.append(potentialCarbEffect)
                retrospectiveEffect = computeRetrospectiveGlucoseEffect(startingAt: glucose, carbEffects: potentialCarbEffect)
            }
        } else if let carbEffect = self.carbEffect {
            effects.append(carbEffect)
        }

        if let insulinEffect = includingPendingInsulin ? self.insulinEffectIncludingPendingInsulin : self.insulinEffect {
            effects.append(insulinEffect)
        }

        if let momentumEffect = self.glucoseMomentumEffect {
            momentum = momentumEffect
        }

        effects.append(retrospectiveEffect)

        var prediction = LoopMath.predictGlucose(startingAt: glucose, momentum: momentum, effects: effects)

        // Dosing requires prediction entries at least as long as the insulin model duration.
        let finalDate = glucose.startDate.addingTimeInterval(doseStore.longestEffectDuration)
        if let last = prediction.last, last.startDate < finalDate {
            prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
        }

        return prediction
    }

    /// INSTRUMENTATION ONLY (#45). Which effect to leave out of a counterfactual eventual.
    private enum CFDrop { case none, momentum, insulin, carb, rc }

    /// INSTRUMENTATION ONLY (#45): a literal read-only mirror of `predictGlucose(:896)` that omits
    /// exactly ONE effect input, so per-effect impact on the eventual is measurable as a leave-one-out
    /// counterfactual — impact(X) = eventual(.none) − eventual(dropX). It deliberately skips the
    /// recency guards and the pump-authority log (those belong to the real dosing path) and is NEVER
    /// fed to DoseMath. `counterfactualEventualMgdl(.none)` reproduces `predictedGlucose?.last`
    /// (same inputs, same order, non-pending). Momentum blends non-linearly inside
    /// `LoopMath.predictGlucose`, so these impacts are MARGINAL and need NOT sum to `eventual − start`.
    private func counterfactualEventualMgdl(_ drop: CFDrop) -> Double? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        guard let glucose = glucoseStore.latestGlucose else { return nil }
        let momentum: [GlucoseEffect] = (drop == .momentum) ? [] : (glucoseMomentumEffect ?? [])
        var effects: [[GlucoseEffect]] = []
        if drop != .carb,    let c = carbEffect    { effects.append(c) }
        if drop != .insulin, let i = insulinEffect { effects.append(i) }   // non-pending, matches dosing path
        if drop != .rc { effects.append(retrospectiveGlucoseEffect) }
        var prediction = LoopMath.predictGlucose(startingAt: glucose, momentum: momentum, effects: effects)
        let finalDate = glucose.startDate.addingTimeInterval(doseStore.longestEffectDuration)
        if let last = prediction.last, last.startDate < finalDate {
            prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
        }
        return prediction.last?.quantity.doubleValue(for: .milligramsPerDeciliter)
    }

    /// #86 INSTRUMENTATION ONLY (display + logging; no dosing path reads this). Build the EXACT
    /// per-source decomposition of `eventual − start` described on `PredictionBreakdown`.
    ///
    /// This is a per-contributor restatement of `LoopMath.predictGlucose` (LoopMath.swift:118-175)
    /// over the SAME inputs, in the SAME order, as `predictGlucose()` (:1349-1361 — carb, insulin
    /// non-pending, RC, with momentum blended). Instead of accumulating one Double per date, it
    /// accumulates one Double PER SOURCE per date and runs the identical blend, so the four terms
    /// necessarily sum to what the prediction moved.
    ///
    /// Runs once per cycle on `dataAccessQueue` (cheap: no `LoopMath.predictGlucose` calls at all,
    /// unlike the leave-one-out counterfactuals at :1384 which run five predictions).
    private func computePredictionBreakdown() -> PredictionBreakdown? {   // dataAccessQueue
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        let unit = HKUnit.milligramsPerDeciliter

        guard let glucose = glucoseStore.latestGlucose,
              let eventual = predictedGlucose?.last?.quantity.doubleValue(for: unit) else { return nil }

        let startDate = glucose.startDate
        let start = glucose.quantity.doubleValue(for: unit)

        // Slot layout, fixed: [carb, insulin, RC, momentum].
        let carbIdx = 0, insIdx = 1, rcIdx = 2, momIdx = 3
        let emptySlot = [0.0, 0.0, 0.0, 0.0]
        var byDate: [Date: [Double]] = [:]

        // First-difference each timeline exactly as LoopMath.swift:122-130 does (the first entry
        // contributes 0 — `previousEffectValue` is seeded from it).
        func accumulate(_ timeline: [GlucoseEffect], _ idx: Int) {
            var previous = timeline.first?.quantity.doubleValue(for: unit) ?? 0
            for effect in timeline {
                let value = effect.quantity.doubleValue(for: unit)
                var slot = byDate[effect.startDate] ?? emptySlot
                slot[idx] += value - previous
                byDate[effect.startDate] = slot
                previous = value
            }
        }

        if let carbEffect = carbEffect { accumulate(carbEffect, carbIdx) }
        if let insulinEffect = insulinEffect { accumulate(insulinEffect, insIdx) }   // non-pending, matches dosing
        accumulate(retrospectiveGlucoseEffect, rcIdx)

        // Momentum blend — LoopMath.swift:132-160, sliced by contributor. LoopMath writes
        // `slot = (1 − split)·slot + split·Δ`; scaling EVERY source (momentum included, so a
        // repeated date behaves identically) by (1 − split) and then adding the momentum share
        // is the same number, attributed.
        let momentum = glucoseMomentumEffect ?? []
        if momentum.count > 1 {
            var previous = momentum[0].quantity.doubleValue(for: unit)
            let blendCount = momentum.count - 2
            let timeDelta = momentum[1].startDate.timeIntervalSince(momentum[0].startDate)
            let momentumOffset = startDate.timeIntervalSince(momentum[0].startDate)
            let blendSlope = 1.0 / Double(blendCount)
            let blendOffset = momentumOffset / timeDelta * blendSlope

            for (index, effect) in momentum.enumerated() {
                let value = effect.quantity.doubleValue(for: unit)
                let change = value - previous
                let split = min(1.0, max(0.0, Double(momentum.count - index) / Double(blendCount) - blendSlope + blendOffset))
                var slot = byDate[effect.startDate] ?? emptySlot
                for s in slot.indices { slot[s] *= (1.0 - split) }
                slot[momIdx] += split * change
                byDate[effect.startDate] = slot
                previous = value
            }
        }

        // Only dates strictly after the anchor move the prediction (LoopMath.swift:163).
        var terms = emptySlot
        for (date, slot) in byDate where date > startDate {
            for s in terms.indices { terms[s] += slot[s] }
        }
        // Degenerate momentum arrays can make LoopMath's blend arithmetic non-finite
        // (blendCount == 0 ⇒ 1/0). Never render NaN: zero the term and let the residual carry it.
        for s in terms.indices where !terms[s].isFinite { terms[s] = 0 }

        let isfSchedule = doseStore.insulinSensitivityScheduleApplyingOverrideHistory ?? settings.insulinSensitivitySchedule
        let isf = isfSchedule?.quantity(at: startDate).doubleValue(for: unit)
        let iob = insulinOnBoard?.value
        let insulinExpected: Double? = (isf != nil && iob != nil) ? -(isf! * iob!) : nil

        // The UNBLENDED tail — the quantity the −ISF × IOB invariant actually governs. Same
        // anchor rule as `net()` (:824-830) and `[predict]`: last minus the last sample at or
        // before now, falling back to the first sample when the whole series is in the future.
        let rawTail: Double? = {
            guard let effects = insulinEffect, let last = effects.last else { return nil }
            let t = now()
            guard let anchor = effects.last(where: { $0.startDate <= t }) ?? effects.first else { return nil }
            return last.quantity.doubleValue(for: unit) - anchor.quantity.doubleValue(for: unit)
        }()

        let residual = eventual - (start + terms[carbIdx] + terms[insIdx] + terms[rcIdx] + terms[momIdx])

        return PredictionBreakdown(
            startMgdl: start,
            eventualMgdl: eventual,
            insulinMgdl: terms[insIdx],
            carbMgdl: terms[carbIdx],
            momentumMgdl: terms[momIdx],
            retrospectiveMgdl: terms[rcIdx],
            residualMgdl: residual,
            insulinRawTailMgdl: rawTail,
            insulinExpectedMgdl: insulinExpected,
            isfMgdlPerU: isf,
            iobUnits: iob,
            momentumPointCount: momentum.count,
            computedAt: now())
    }

    /// #86: cache the exact decomposition for the DOSING panel and emit it as a greppable
    /// `[predict-recon]` line. Unlike `[predict]` (raw array deltas, anchored at now) and
    /// `[predict-snapshot]` (MARGINAL leave-one-out impacts), this one ADDS UP — so a run of
    /// cycles can be grepped and summed without re-deriving the momentum blend by hand.
    private func emitPredictionReconciliation() {   // dataAccessQueue
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        guard let b = computePredictionBreakdown() else {
            lastPredictionBreakdown = nil
            SportLog.event("predict-recon", "— (no prediction to reconcile)")
            return
        }
        lastPredictionBreakdown = b

        // Render from the SAME rounded integers the wrist shows, and close the line with the
        // rounding remainder, so the logged row is literally the row on the watch.
        let s = PredictionBreakdown.round0(b.startMgdl), ev = PredictionBreakdown.round0(b.eventualMgdl)
        let ins = PredictionBreakdown.round0(b.insulinMgdl), carb = PredictionBreakdown.round0(b.carbMgdl)
        let mom = PredictionBreakdown.round0(b.momentumMgdl), rc = PredictionBreakdown.round0(b.retrospectiveMgdl)
        let shown = PredictionBreakdown.round0(ev - (s + ins + carb + mom + rc))

        // The invariant check, against the RAW tail — never against the blended term above.
        // Reads as its own sentence so nobody has to reconstruct this morning's argument to
        // interpret it: raw tail, what -ISF x IOB says it should be, and the residual in UNITS
        // (mg/dL is unreadable across different ISFs). A residual of roughly the running temp's
        // remaining delivery is EXPECTED and stock; a raw tail that ignores IOB is #84 again.
        let invariant: String
        if let raw = b.insulinRawTailMgdl, let e = b.insulinExpectedMgdl, let isf = b.isfMgdlPerU, let iob = b.iobUnits {
            invariant = String(format: " | raw ins tail %+.1f vs −ISF×IOB %+.1f (ISF %.0f × IOB %.2f) resid %+.3f U",
                               raw, e, isf, iob, (raw - e) / isf)
        } else if let e = b.insulinExpectedMgdl {
            invariant = String(format: " | raw ins tail — · −ISF×IOB %+.1f", e)
        } else {
            invariant = " | raw ins tail — · −ISF×IOB — (no ISF/IOB)"
        }

        SportLog.event("predict-recon", String(format:
            "%.0f ins %+.0f carb %+.0f mom %+.0f RC %+.0f r %+.0f = %.0f (Δ%+.0f) | blended: ins %+.1f carb %+.1f mom %+.1f RC %+.1f resid %+.2f%@ | momPts=%d",
            s, ins, carb, mom, rc, shown, ev, ev - s,
            b.insulinMgdl, b.carbMgdl, b.momentumMgdl, b.retrospectiveMgdl, b.residualMgdl,
            invariant, b.momentumPointCount))
    }

    // MARK: - Recommendation (mirrors updatePredictedGlucoseAndRecommendedDose(with:) — :1695)

    /// Configuration gates first (each missing element DENIES dosing — the design doc's
    /// no-fabricated-defaults rule), then prediction, then the SAME DoseMath entry points the
    /// phone calls, with the IOB clamp passed INSIDE the recommendation call
    /// (`additionalActiveInsulinClamp`) — never applied post-hoc beside it.
    private func updatePredictedGlucoseAndRecommendedDose() -> WatchLoopError? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        let startDate = now()

        // Same configuration checks, same denial semantics as the phone (:1726-1753).
        guard let glucoseTargetRange = settings.effectiveGlucoseTargetRangeSchedule() else {
            return .configurationError("glucoseTargetRangeSchedule")
        }
        // #68 FIX (2026-08-01): DoseMath must consume the OVERRIDE-APPLIED schedules, exactly as
        // the phone does (LoopDataManager.swift:1726ff guards on basalRateScheduleApplyingOverride-
        // History / insulinSensitivityScheduleApplyingOverrideHistory). This port passed the raw
        // settings schedules, so an active override moved the TARGET (effectiveGlucoseTargetRange-
        // Schedule below) but not the SCALES: field 2026-08-01, with a 60%-needs override the
        // [dosemath] line read `scheduled 0.70 · ISF 70` where 0.42 / ~117 were intended — every
        // "neutral" temp was a 1.67x high temp in override terms, and corrections were 1.67x
        // oversized. Systematic OVER-delivery under a reduced-needs override.
        //
        // The prediction path already used the applied ISF (:1211, :1607), so prediction and
        // dosing disagreed about the same override. The [dosemath] log line below prints these
        // same locals, so with this fix the wrist telemetry shows the applied values — scheduled
        // 0.42 / ISF 117 under the 60% preset — which is the field verification.
        //
        // Fallback to the raw settings schedule only when the override-history accessor itself is
        // nil (no overrideHistory wired — pre-#68 grants), mirroring the :1607 pattern; never nil
        // out dosing because override plumbing is absent.
        guard let basalRateSchedule = doseStore.basalProfileApplyingOverrideHistory ?? settings.basalRateSchedule else {
            return .configurationError("basalRateSchedule")
        }
        guard let insulinSensitivity = doseStore.insulinSensitivityScheduleApplyingOverrideHistory ?? settings.insulinSensitivitySchedule else {
            return .configurationError("insulinSensitivitySchedule")
        }
        guard (carbStore.carbRatioScheduleApplyingOverrideHistory ?? settings.carbRatioSchedule) != nil else {
            return .configurationError("carbRatioSchedule")
        }
        guard let maxBasal = settings.maximumBasalRatePerHour else {
            return .configurationError("maximumBasalRatePerHour")
        }
        guard let maxBolus = settings.maximumBolus else {
            return .configurationError("maximumBolus")
        }

        // Same missing-effect checks (:1755-1773).
        guard glucoseMomentumEffect != nil else { return .missingDataError("momentumEffect") }
        guard carbEffect != nil else { return .missingDataError("carbEffect") }
        guard insulinEffect != nil else { return .missingDataError("insulinEffect") }
        guard let insulinOnBoard = insulinOnBoard else { return .missingDataError("activeInsulin") }

        do {
            let predictedGlucose = try predictGlucose()
            self.predictedGlucose = predictedGlucose
            self.predictedGlucoseIncludingPendingInsulin = try predictGlucose(includingPendingInsulin: true)

            // Mirrors the phone's rateRounder: the pump manager's supported-rate rounding, or
            // pass-through when absent (:1800). With rounding in place `ifNecessary`
            // continuation works and the loop does not issue a cancel+set pair every reading.
            let rateRounder = { (rate: Double) in
                return self.pumpManager?.roundToSupportedBasalRate(unitsPerHour: rate) ?? rate
            }

            // #50: prefer the cached enacted temp when the pod is orphaned, so DoseMath's
            // continuation logic sees the running temp and does not re-issue an identical one
            // every cycle (and the [dosemath] `running` field reads true instead of "none").
            let lastTempBasal: DoseEntry? = runningTempBasal()

            let dosingRecommendation: AutomaticDoseRecommendation?

            // automaticDosingIOBLimit calculated from the user-entered maxBolus, exactly as
            // the phone (:1814-1816). The headroom is applied INSIDE recommendedTempBasal via
            // additionalActiveInsulinClamp — DoseMath owns the clamp, not this file.
            let automaticDosingIOBLimit = maxBolus * 2.0
            let iobHeadroom = automaticDosingIOBLimit - insulinOnBoard.value

            switch settings.automaticDosingStrategy {
            case .automaticBolus:
                // RULED (R16, 2026-07-17): the watch strategy is temp basals only — every
                // bolus is human-confirmed. The denial is explicit, not a silent fallback
                // to tempBasalOnly, so a phone-pushed automaticBolus setting is surfaced
                // rather than quietly reinterpreted.
                return .configurationError("automaticDosingStrategy: automaticBolus is not supported on the watch (R16: temps only)")

            case .tempBasalOnly:
                // The same DoseMath entry point, same argument surface as the phone (:1858).
                // RULED (R16, 2026-07-17): maxBasal is the raw therapy maximumBasalRatePerHour
                // — the only configured limit, exactly as on the phone. No watch-side
                // companion cap; stock DoseMath clamp + driver rounding + pod ceiling are
                // the layers.
                let temp = predictedGlucose.recommendedTempBasal(
                    to: glucoseTargetRange,
                    at: predictedGlucose[0].startDate,
                    suspendThreshold: settings.suspendThreshold?.quantity,
                    sensitivity: insulinSensitivity,
                    model: doseStore.insulinModelProvider.model(for: pumpManager?.status.insulinType),
                    basalRates: basalRateSchedule,
                    maxBasalRate: maxBasal,
                    additionalActiveInsulinClamp: iobHeadroom,
                    lastTempBasal: lastTempBasal,
                    rateRounder: rateRounder,
                    isBasalRateScheduleOverrideActive: settings.scheduleOverride?.isBasalRateScheduleOverriden(at: startDate) == true
                )
                dosingRecommendation = AutomaticDoseRecommendation(basalAdjustment: temp)

                // THE DECISION, with every input DoseMath actually saw. Until now the log
                // recorded the verdict but none of the evidence, so "no basal change" at a
                // high eventual was unexplainable from a log — the exact question left open
                // on 2026-07-22 (eventual ~200, nothing recommended). Any one of these can
                // legitimately produce nil: eventual already inside target, a running temp
                // that already matches, maxBasal reached, or the IOB clamp at zero headroom.
                // Naming which one turns a mystery into a fact.
                let tRange = glucoseTargetRange.quantityRange(at: startDate)
                let mgdl = HKUnit.milligramsPerDeciliter
                SportLog.event("dosemath", String(
                    format: "eventual %@ vs target %.0f-%.0f · running %@ · scheduled %.2f · maxBasal %.2f · ISF %.0f · IOB %.2f (clamp headroom %.2f) · suspendThr %@ => %@",
                    predictedGlucose.last.map { String(format: "%.0f", $0.quantity.doubleValue(for: mgdl)) } ?? "—",
                    tRange.lowerBound.doubleValue(for: mgdl),
                    tRange.upperBound.doubleValue(for: mgdl),
                    lastTempBasal.map { String(format: "%.2f U/hr", $0.unitsPerHour) } ?? "none(scheduled)",
                    basalRateSchedule.value(at: startDate),
                    maxBasal,
                    insulinSensitivity.quantity(at: startDate).doubleValue(for: mgdl),
                    insulinOnBoard.value,
                    iobHeadroom,
                    settings.suspendThreshold?.quantity.doubleValue(for: mgdl).description ?? "none",
                    temp.map { String(format: "temp %.2f U/hr x %.0f min", $0.unitsPerHour, $0.duration / 60) } ?? "NO CHANGE"))
            }

            if let dosingRecommendation = dosingRecommendation {
                self.log.default("Recommending dose: %{public}@ at %{public}@", String(describing: dosingRecommendation), String(describing: startDate))
                recommendedAutomaticDose = (recommendation: dosingRecommendation, date: startDate)
            } else {
                self.log.default("No dose recommended.")
                recommendedAutomaticDose = nil
            }
        } catch let error as WatchLoopError {
            return error
        } catch {
            return .missingDataError(String(describing: error))
        }

        return nil
    }

    // MARK: - Manual bolus (mirrors recommendBolusValidatingDataRecency — :1500 — and recommendManualBolus — :1537)

    /// The stock recency-validated manual-bolus path: glucose/pump staleness gates and no
    /// fabricated glucose placeholder (the crude version's 100 mg/dL stand-in is a review
    /// finding and does not return).
    /// RULED (R17, 2026-07-17): a recency denial surfaces as an explicit "No recent
    /// glucose — no recommendation" notice in the recommendation slot; the dial stays
    /// usable for a manual bolus under therapy maxBolus and carbs still log. The notice
    /// rendering lands with the bolus-flow UI integration; this method supplies policy
    /// only (the thrown recency error is the notice's trigger).
    /// - Parameter potentialCarbEntry: #47 — when non-nil the recommendation is a MEAL bolus for
    ///   an entry the user has not saved yet. Two things change, both of them stock's doing:
    ///   the entry joins the prediction, and the target range switches to the pre-meal range
    ///   (`presumingMealEntry:`), which is exactly why passing it matters rather than just
    ///   adding a carb effect.
    func recommendManualBolus(potentialCarbEntry: NewCarbEntry? = nil,
                              completion: @escaping (Swift.Result<ManualBolusRecommendation, Error>) -> Void) {
        dataAccessQueue.async {
            do {
                if let error = self.updateCachedEffects() {
                    throw error
                }

                // Same gating chain as recommendBolusValidatingDataRecency (:1502-1531);
                // the glucose/pump recency guards live in predictGlucose (identical
                // constants, identical order).
                guard self.glucoseMomentumEffect != nil else { throw WatchLoopError.missingDataError("momentumEffect") }
                guard self.carbEffect != nil else { throw WatchLoopError.missingDataError("carbEffect") }
                guard self.insulinEffect != nil else { throw WatchLoopError.missingDataError("insulinEffect") }

                let prediction = try self.predictGlucose(includingPendingInsulin: true,
                                                         potentialCarbEntry: potentialCarbEntry)

                // Same configuration guards as recommendManualBolus (:1539-1547).
                guard let glucoseTargetRange = self.settings.effectiveGlucoseTargetRangeSchedule(presumingMealEntry: potentialCarbEntry != nil) else {
                    throw WatchLoopError.configurationError("glucoseTargetRangeSchedule")
                }
                guard let insulinSensitivity = self.settings.insulinSensitivitySchedule else {
                    throw WatchLoopError.configurationError("insulinSensitivitySchedule")
                }
                guard let maxBolus = self.settings.maximumBolus else {
                    throw WatchLoopError.configurationError("maximumBolus")
                }

                let volumeRounder = { (units: Double) in
                    return self.pumpManager?.roundToSupportedBolusVolume(units: units) ?? units
                }

                let recommendation = prediction.recommendedManualBolus(
                    to: glucoseTargetRange,
                    at: self.now(),
                    suspendThreshold: self.settings.suspendThreshold?.quantity,
                    sensitivity: insulinSensitivity,
                    model: self.doseStore.insulinModelProvider.model(for: self.pumpManager?.status.insulinType),
                    pendingInsulin: 0,  // Pending insulin is already reflected in the prediction (:1569)
                    maxBolus: maxBolus,
                    volumeRounder: volumeRounder
                )
                completion(.success(recommendation))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// R5 manual bolus: the user is PRESENT — never defers to the radio arbiter
    /// (unlike the automatic path), capped by the granted therapy maximumBolus
    /// (R1/R16: therapy settings are the only limits), journaled through the same
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
            // The delivery itself, factored so it can run after an E4 pod reclaim.
            let deliverBolus = {
                SportLog.event("loan", String(format: "MANUAL BOLUS %.2f U — enacting on the watch pump", rounded))
                let eventID = self.doseEnactor.loanRecorder?.loanWillEnactBolus(units: rounded)
                pumpManager.enactBolus(units: rounded, activationType: activationType) { error in
                    self.doseEnactor.loanRecorder?.loanDidEnact(eventID: eventID, error: error)
                    self.e4ReleasePodAfterDose?()   // E4 Stage 2: re-release the pod after the bolus
                    if let error = error {
                        SportLog.event("loan", "MANUAL BOLUS FAILED — \(String(describing: error))")
                    } else {
                        // #73/#74 shadow ledger: point-ish event; DASH delivers ~1.5 U/min.
                        let acceptedAt = self.now()
                        let deliveryEndsAt = acceptedAt.addingTimeInterval(rounded / 1.5 * 60)
                        SportLog.event("loan", String(format: "MANUAL BOLUS delivering %.2f U — estimated done in %.0fs",
                                                      rounded, deliveryEndsAt.timeIntervalSince(acceptedAt)))
                        // #91: hand the glance the window so it can narrate the delivery the way
                        // stock's phone does. Estimate only — same contract as
                        // PodDoseProgressEstimator, no pod query, no radio.
                        self.setManualBolusDelivering(units: rounded, from: acceptedAt, to: deliveryEndsAt)
                        self.ledgerRecordEnact(DoseEntry(
                            type: .bolus, startDate: acceptedAt,
                            endDate: deliveryEndsAt,
                            value: rounded, unit: .units,
                            insulinType: pumpManager.status.insulinType))
                        // 134: fold the bolus into IOB/prediction/HUD NOW, not at the next
                        // reading (field: 0.75 U showed no immediate IOB update anywhere).
                        self.dataAccessQueue.async {
                            self.insulinEffect = nil
                            self.insulinEffectIncludingPendingInsulin = nil
                        }
                        self.loop()
                    }
                    self.setManualBolusInFlight(false)
                    DispatchQueue.main.async { completion(error) }
                }
            }
            self.setManualBolusInFlight(true, units: rounded)
            // E4 Stage 2: the pod is orphaned for G7 — reclaim it before the bolus.
            // User is PRESENT, so a few seconds' reconnect is fine; on failure FAIL
            // LOUDLY (never a silent no-bolus). No-op immediate when E4 is off.
            if let reclaim = self.e4ReclaimPodForDose {
                reclaim { ok in
                    if ok {
                        // #64 ROOT CAUSE (2026-07-29): this completion runs ON the loan
                        // controller's serial queue (reclaimPodForDose wraps every path in
                        // queue.async, including the still-connected short-circuit), and
                        // deliverBolus → loanWillEnactBolus → mintIntent does queue.sync
                        // onto that SAME queue — a guaranteed libdispatch trap, before
                        // enactBolus is ever issued (apparent success at the crown, crash
                        // 0-40s later, NO insulin delivered). The automatic enactor never
                        // hits this because it re-enters from its own dosingQueue — mirror
                        // that discipline: hop off the loan queue before delivering.
                        // (.async is load-bearing: with E4 off, the reclaim closure
                        // completes SYNCHRONOUSLY on dataAccessQueue — a .sync hop would
                        // deadlock on itself. Adversarial-review verified.)
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
                        self.e4ReleasePodAfterDose?()
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
    /// dosing see it immediately (stores are isolated — R19 HK-off; the phone still
    /// receives the stock relay as the durable record).
    /// Force the next cycle to recompute carbEffect. Used after seeding the phone's carbs
    /// at grant (#49): carbEffect is cached and updateCachedEffects only recomputes it when
    /// nil, so without this the seeded COB would be ignored until the next CGM-triggered
    /// invalidation. Deliberately does NOT force a loop() — takeover has no glucose yet; the
    /// first reading-triggered cycle (within ~5 min) recomputes and doses.
    func invalidateCarbEffect() {
        dataAccessQueue.async { self.carbEffect = nil }
    }

    /// IOB dedup (2026-07-22): after the grant wipe-then-seed rebuilds the insulin books,
    /// drop the cached insulin effects so the next cycle recomputes from the clean store
    /// instead of riding the pre-wipe curve (IOB itself refetches every cycle already).
    func invalidateInsulinEffect() {
        dataAccessQueue.async {
            self.insulinEffect = nil
            self.insulinEffectIncludingPendingInsulin = nil
        }
    }

    /// After the grant seeds ~3 h of glucose, drop the glucose-derived caches so the next cycle
    /// recomputes momentum AND retrospective correction from the seeded history. Setting
    /// insulinCounteractionEffects = [] cascades through its didSet (carbEffect = nil) and — via
    /// the Fix-C carbEffect.didSet — nils retrospectiveGlucoseDiscrepancies too; we also clear
    /// momentum and discrepancies directly so nothing rides a stale cold-start value. No forced
    /// loop(): the first live glucose reading drives the first cycle (mirrors invalidateCarbEffect).
    func invalidateGlucoseDerivedEffects() {
        dataAccessQueue.async {
            self.glucoseMomentumEffect = nil
            self.insulinCounteractionEffects = []
            self.retrospectiveGlucoseDiscrepancies = nil
        }
    }

    /// Prime the cached IOB AT takeover, from the seed's own IOB read, so the glance shows the
    /// correct value immediately instead of stale/blank until the first loop cycle (~1 min later)
    /// refreshes it. The seed populates the dose store but not this cache. `insulinOnBoard` feeds
    /// the glance (glanceData), the stock HUD (publishHUDContext), and dosing — priming it fixes
    /// all three consistently and single-sourced; the glance COB already reads its store live, so
    /// this brings IOB to parity (#69 glance consistency). The next cycle overwrites it with the
    /// fully-reconciled value (e.g. after the first pod-status read trims the seeded open temp).
    func primeInsulinOnBoard(_ value: InsulinValue?) {
        dataAccessQueue.async { self.insulinOnBoard = value }
    }

    func addLoanCarbEntry(_ entry: NewCarbEntry) {
        carbStore.addCarbEntry(entry) { result in
            switch result {
            case .success(let stored):
                SportLog.event("loan", String(format: "carbs logged locally: %.0f g", stored.quantity.doubleValue(for: .gram())))
                // 134 (field 2026-07-20 20:31): carbEffect is invalidated ONLY by new
                // CGM data (insulinCounteractionEffects.didSet) — the stock phone loop
                // observes carb-store changes for this, and the port dropped that
                // observer. A carb entry therefore sat OUTSIDE the prediction until
                // the next reading-triggered cycle (eventual BG lower than current
                // with 20 g COB on board). Invalidate + re-run the loop NOW: the
                // prediction, recommendation, and HUD update within seconds of the
                // entry, independent of CGM timing — stock parity restored.
                self.dataAccessQueue.async { self.carbEffect = nil }
                self.loop()
            case .failure(let error):
                SportLog.event("loan", "carb store add FAILED — \(String(describing: error))")
            }
        }
    }

    /// R30 (#89): the mirror image of `addLoanCarbEntry` — remove a carb the wrist deleted and
    /// re-predict immediately.
    ///
    /// The invalidate-and-loop is not optional for the same reason it is not optional on the add
    /// path (134): `carbEffect` is invalidated only by new CGM data, because the port dropped the
    /// stock phone loop's carb-store observer. Without this the deleted carb keeps driving the
    /// prediction until the next reading — the user would watch the row vanish and the eventual
    /// BG not move, which is precisely the "did that do anything?" failure the delete is meant to
    /// resolve.
    ///
    /// Journaling is the CALLER's job (LoanCarbListController), so this stays a pure store+loop
    /// operation and the journal side-effect is visible at the UI layer where the ruling lives.
    func deleteLoanCarbEntry(_ entry: StoredCarbEntry, completion: @escaping (Bool) -> Void) {
        let grams = entry.quantity.doubleValue(for: .gram())
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
                self.dataAccessQueue.async { self.carbEffect = nil }
                self.loop()
                // POST-DELETE VERIFICATION: read the store back and say what remains, so
                // "deleted but still showing" can never again be ambiguous between a failed
                // delete and a stale view.
                let start = min(Calendar.current.startOfDay(for: self.now()),
                                Date(timeIntervalSinceNow: -self.carbStore.maximumAbsorptionTimeInterval))
                self.carbStore.getCarbEntries(start: start) { readback in
                    if case .success(let remaining) = readback {
                        let total = remaining.reduce(0.0) { $0 + $1.quantity.doubleValue(for: .gram()) }
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

        // *** RADIO STRESS (BENCH) *** — REMOVE BEFORE PRODUCTION.
        // #83 (Jeremy 2026-07-30): the gold-standard radio test is "every 5-min cycle gets a
        // fresh sensor reading AND lands a distinct pod command". Today half the cycles go
        // quiet because DoseMath returns no change — we sit pinned at max or zero, where
        // consecutive cycles agree. Real-world dosing is seldom saturated, so a command per
        // cycle is the REALISTIC load, not an exaggerated one.
        //
        // E5 (the random-temp generator) is the wrong instrument for it: it fires 8s after
        // the reading, deliberately clear of the G7 teardown and observer-scan arming — the
        // exact window where contention lives. The real path reclaims ~0.2s after the value.
        // So substitute only the RECOMMENDATION and leave every timing seam untouched:
        // same trigger, same prediction pipeline, same reclaim geometry.
        //
        // Nudge one pulse step off the running rate, alternating so consecutive commands
        // always differ (a repeat would be suppressed downstream and cost the cycle).
        // Dosing impact is negligible — 0.05 U/hr for 5 min is 0.004 U — and the bench pod
        // is water. Clamped to [0, maxBasal] and pulse-rounded by the driver as usual.
        var recommendationToEnact = recommendedDose.recommendation
        if defaults.bool(forKey: "g7.radioStressAlwaysEnact"),
           recommendationToEnact.basalAdjustment == nil,
           let scheduled = settings.basalRateSchedule?.value(at: now()) {
            radioStressJitterStep = (radioStressJitterStep + 1) % 2
            let nudged = max(0, min(scheduled + (radioStressJitterStep == 0 ? 0.05 : 0.10),
                                    settings.maximumBasalRatePerHour ?? scheduled))
            recommendationToEnact = AutomaticDoseRecommendation(
                basalAdjustment: TempBasalRecommendation(unitsPerHour: nudged, duration: .minutes(30)))
            SportLog.event("radio-stress", String(format: "no-change cycle → forcing %.2f U/hr (sched %.2f) so the cycle exercises the pod radio", nudged, scheduled))
        }

        doseEnactor.enact(recommendation: recommendationToEnact, with: pumpManager) { error in
            if let error = error {
                // #98: .enactFailed, NOT .missingDataError — see the case's own note.
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

    // MARK: - E5 bench concurrency driver (task #43, 2026-07-21)

    /// A random temp-basal generator: drives the full E4 reclaim→enact→re-release
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
            let recommendation = AutomaticDoseRecommendation(basalAdjustment: TempBasalRecommendation(unitsPerHour: rate, duration: .minutes(30)))
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

// MARK: - #68 override telemetry helper

extension TemporaryScheduleOverride.Context {
    /// Greppable preset identity for the [override] lines — the name is what Jeremy will
    /// match against the phone when reconciling a session.
    var presetNameForLog: String {
        switch self {
        case .preMeal: return "pre-meal"
        case .legacyWorkout: return "workout(legacy)"
        case .preset(let preset): return "\(preset.symbol) \(preset.name)"
        case .custom: return "custom"
        }
    }
}

// MARK: - Dose enactor (mirrors Loop/Managers/DoseEnactor.swift)

/// Same sequencing as the phone's DoseEnactor: temp-basal adjustment first, wait, then any
/// automatic bolus — all through stock `PumpManager` protocol methods, so pulse-grid
/// snapping, cancel-before-program, busy handling, and uncertain-delivery classification are
/// the stock driver's (OmniPumpManager, M2), not ours.
final class WatchDoseEnactor {

    /// Test coverage plan item 2: this class records dose timestamps into the ledger, so it
    /// needs its own clock seam — it is a separate type from WatchLoopManager and cannot
    /// reach that one. WatchLoopManager keeps the two in sync when it builds the enactor.
    var now: () -> Date = Date.init

    private let dosingQueue = DispatchQueue(label: "com.loopkit.Loop.WatchDoseEnactor", qos: .utility)

    private let log = OSLog(category: "WatchDoseEnactor")

    /// M5: the loan controller's intent-minting hooks (spec §1.2). nil outside a loan;
    /// the enact calls themselves are unchanged stock PumpManager methods either way.
    weak var loanRecorder: WatchLoanDoseRecording?

    /// Fix B (radio arbiter, c6c9e18f port): BG wins the single watch radio. When the
    /// G7 is mid-handshake (the heavy ~8-10s burst), a LOOP enact yields instead of
    /// colliding ("Empty Value") — the stock-shaped loop retries naturally on the next
    /// reading, which is exactly the fresh BG landing. Only the automatic path runs
    /// through this enactor today; a future manual path must NOT defer (user present —
    /// the crude loudDrop==true analog).

    /// E4 Stage 2 (task #40): while E4 time-separation is active the pod BLE is
    /// orphaned for G7's sake. reclaim it just before dosing; release it just after.
    /// reclaim's completion(true) = pod connected & ready; (false) = couldn't
    /// reconnect in the bounded window → SKIP this automatic dose (pod keeps running
    /// its baseline, loop retries next cycle). Both nil / no-op when E4 is off.
    var e4ReclaimPodForDose: ((@escaping (Bool) -> Void) -> Void)?
    var e4ReleasePodAfterDose: (() -> Void)?

    /// #50: fired with the (rate, duration) the pod just accepted for a temp basal, so the
    /// owner can cache what is running without querying the pod — E4 orphans it seconds later.
    var onTempBasalEnacted: ((_ unitsPerHour: Double, _ duration: TimeInterval) -> Void)?
    /// #73/#74 shadow ledger: pod-ACCEPTED doses flow to the owner's session timeline.
    var ledgerRecord: ((DoseEntry) -> Void)?

    func enact(recommendation: AutomaticDoseRecommendation, with pumpManager: PumpManager, completion: @escaping (PumpManagerError?) -> Void) {
        dosingQueue.async {
            // BG still wins the radio — but WAIT for the handshake instead of throwing the
            // dose cycle away on a millisecond-scale collision.
            //
            // E4: reclaim the orphaned pod before dosing (bounded). Safe-fallback on
            // failure: skip the dose — never block, never dose against a pod that
            // isn't confirmed connected. Runs on dosingQueue (not the loop's
            // dataAccessQueue), so the bounded wait can't stall the loop cycle.
            if let reclaim = self.e4ReclaimPodForDose {
                let group = DispatchGroup()
                group.enter()
                var connected = false
                reclaim { ok in connected = ok; group.leave() }
                if group.wait(timeout: .now() + 25) == .timedOut || !connected {
                    SportLog.event("radio", "E4: pod not reconnected — automatic dose SKIPPED (pod runs baseline; loop retries next cycle)")
                    self.e4ReleasePodAfterDose?()
                    completion(.communication(nil))   // benign: the loop re-enacts next reading
                    return
                }
            }
            // Always re-release the pod on the way out, whatever the dose result.
            let finish: (PumpManagerError?) -> Void = { err in
                self.e4ReleasePodAfterDose?()
                completion(err)
            }

            let doseDispatchGroup = DispatchGroup()

            var tempBasalError: PumpManagerError? = nil
            var bolusError: PumpManagerError? = nil

            if let basalAdjustment = recommendation.basalAdjustment {
                self.log.default("Enacting recommended basal change")
                // What the pod is ACTUALLY being told, and whether it took it. Without
                // this the field log showed a reclaim and a released pod with no way to
                // tell whether a command went out at all (2026-07-22 08:48) — E5 had
                // this line, the real dosing path did not.
                SportLog.event("dose", String(format: "enacting temp %.2f U/hr × %.0f min", basalAdjustment.unitsPerHour, basalAdjustment.duration / 60))
                doseDispatchGroup.enter()
                let eventID = self.loanRecorder?.loanWillEnactTempBasal(unitsPerHour: basalAdjustment.unitsPerHour, duration: basalAdjustment.duration)
                pumpManager.enactTempBasal(unitsPerHour: basalAdjustment.unitsPerHour, for: basalAdjustment.duration) { error in
                    self.loanRecorder?.loanDidEnact(eventID: eventID, error: error)
                    if let error = error {
                        tempBasalError = error
                        SportLog.event("dose", "temp enact FAILED — \(String(describing: error))")
                    } else {
                        SportLog.event("dose", String(format: "temp %.2f U/hr ACCEPTED by pod", basalAdjustment.unitsPerHour))
                        // #50: hand the accepted temp to the owner so it can cache what the pod
                        // is running once E4 orphans it (basalDeliveryState goes nil seconds
                        // after release).
                        self.onTempBasalEnacted?(basalAdjustment.unitsPerHour, basalAdjustment.duration)
                        // #73/#74 shadow ledger: the accepted temp enters the single-owner
                        // timeline (truncating its open predecessor — the journal's rule).
                        let acceptedAt = self.now()
                        self.ledgerRecord?(DoseEntry(
                            type: .tempBasal, startDate: acceptedAt,
                            endDate: acceptedAt.addingTimeInterval(basalAdjustment.duration),
                            value: basalAdjustment.unitsPerHour, unit: .unitsPerHour,
                            insulinType: pumpManager.status.insulinType))
                    }
                    doseDispatchGroup.leave()
                }
            } else {
                // The silent case that made 08:48 unreadable: DoseMath ran and chose to
                // leave the running basal alone. That is a decision, and it gets a line.
                SportLog.event("dose", "no temp change recommended — leaving the running basal as-is")
            }

            doseDispatchGroup.wait()

            guard tempBasalError == nil else {
                finish(tempBasalError)
                return
            }

            if let bolusUnits = recommendation.bolusUnits, bolusUnits > 0 {
                self.log.default("Enacting recommended bolus dose")
                doseDispatchGroup.enter()
                let eventID = self.loanRecorder?.loanWillEnactBolus(units: bolusUnits)
                pumpManager.enactBolus(units: bolusUnits, activationType: .automatic) { error in
                    self.loanRecorder?.loanDidEnact(eventID: eventID, error: error)
                    if let error = error {
                        bolusError = error
                    } else {
                        // #73/#74 shadow ledger: point-ish event; DASH delivers ~1.5 U/min.
                        let acceptedAt = self.now()
                        self.ledgerRecord?(DoseEntry(
                            type: .bolus, startDate: acceptedAt,
                            endDate: acceptedAt.addingTimeInterval(bolusUnits / 1.5 * 60),
                            value: bolusUnits, unit: .units,
                            insulinType: pumpManager.status.insulinType))
                    }
                    doseDispatchGroup.leave()
                }
            }
            doseDispatchGroup.wait()
            finish(bolusError)
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
                // E5 (task #43): same post-catch trigger geometry as a real dose —
                // the command lands in the gap after this reading and contends with
                // the NEXT window, exactly like production timing. No-op unless the
                // bench flag is on.
                self.e5FireRandomTempIfEnabled()
            }
            // WS4b: every direct reading re-defers the sensor-blackout dead-man —
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

    /// WS4c sovereignty signal: age of the newest stored glucose (direct-only during
    /// a loan — R18/R19), nil before any reading.
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
            // BENCH-ONLY (#33/R29): substitute scripted values AFTER a successful real read.
            // Deliberately here and not upstream — the G7 connect/handshake already happened,
            // so radio contention and E4 timing stay genuine and a MISSED window stays
            // missed. Everything downstream (store, momentum, prediction, DoseMath, the pod
            // command) is real. No-op unless the bench flag is on.
            let values: [NewGlucoseSample]
            if FakeGlucose.isEnabled {
                values = FakeGlucose.substitute(rawValues)
            } else {
                values = rawValues
            }
            // #83: the phone relay may already have filed this exact reading under its own name
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
            self.glucoseStore.addGlucoseSamples(kept) { result in
                if case .failure(let error) = result {
                    self.log.error("Failure adding glucose samples: %{public}@", String(describing: error))
                }
                // #51: new glucose invalidates the momentum effect (it is glucose-derived).
                // Stock LoopDataManager nils momentum on every glucose update; this port only
                // reset it on a fetch-FAILURE (updateCachedEffects), so it was computed once at
                // init — when the store was still empty — and then frozen, because the
                // `if glucoseMomentumEffect == nil` guard never fired again. Every [predict]
                // read `momentum —` while BG swung ±20/cycle, leaving the prediction trend-blind.
                self.dataAccessQueue.async { self.glucoseMomentumEffect = nil }
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

    /// #39 (2026-07-28): phone-BG fallback. During a loan, mirror the phone's relayed CGM into
    /// the DOSING glucose store so the closed loop survives a direct-G7 dropout. The relayed
    /// sample carries the phone's REAL G7 syncIdentifier (WatchContext.newGlucoseSample), so when
    /// direct G7 also has this grid point the store auto-dedups by syncId — this only fills GAPS.
    /// Fired on every phone context update (didUpdateContextNotification); gated to an active loan
    /// (pumpManager set). The date pre-check IS the failover for free: we ingest only when the
    /// phone reading is NEWER than anything already stored, so a fresh direct G7 always wins and
    /// phone BG fills in only once direct goes stale. (Mixed provenance zeroes momentum briefly at
    /// the boundary — accepted, per design.)
    func ingestPhoneGlucoseFromContext() {
        guard pumpManager != nil else { return }   // active loan only — the watch is the dosing controller
        // #47: read the PHONE's relay explicitly. activeContext is watch-authored during a loan
        // now, so reading it here would hand this method the watch's own reading back and the
        // fallback would never ingest anything.
        guard let ctx = ExtensionDelegate.shared().loopManager.phoneRelayContext,
              let sample = ctx.newGlucoseSample else { return }
        deviceQueue.async {
            // Same-sample repeat latch (#39, field 2026-07-29: the same sample ingested 3× in
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
            guard !kept.isEmpty else { return }   // #83: direct G7 already filed this reading
            self.glucoseStore.addGlucoseSamples(kept) { result in
                if case .failure(let error) = result {
                    self.log.error("phone-BG fallback add failed: %{public}@", String(describing: error))
                    return
                }
                self.dataAccessQueue.async { self.glucoseMomentumEffect = nil }   // #51 parity
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

    // MARK: - #83: one physical reading, one row

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
    /// That is why the store's syncIdentifier uniqueness constraint never fired: the same physical
    /// reading arrived under two different names and was filed twice, once from the direct G7 read
    /// and once from the phone relay. Measured 2026-07-31: the sample count in the 25-minute
    /// momentum window tracked the relay exactly — 5 clean, climbing to 10 while the relay ran,
    /// decaying back to 5 within 25 minutes of it stopping, and one stray relay producing one
    /// +1 blip. Mostly benign (duplicate points carry the same value, so a regression through them
    /// barely moves) EXCEPT at `GlucoseMath.swift:103`, whose `count > 2` floor counts ROWS: a
    /// two-reading window that stock refuses to regress becomes four rows, clears the floor, and
    /// manufactures a trend.
    ///
    /// Verified device-independent against the field log — the stamp parsed out of the watch's own
    /// raw BLE frames equalled the phone's relayed stamp on 13 of 14 cycles (the exception was the
    /// phone relaying a ~110-minute-stale reading near a grant, which is genuinely a different
    /// reading and correctly does NOT dedup).
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
        glucoseStore.getGlucoseSamples(start: since, end: nil) { result in
            guard case .success(let stored) = result else {
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
    /// SIMULATOR-ONLY (task #61 stage 2): inject the phone's stock CGM-simulator BG (relayed
    /// in WatchContext) into the REAL glucose store + trigger the REAL loop, so
    /// prediction/DoseMath run for real without a G7. Compiled OUT of device builds. The watch
    /// accumulates its own history from these, so the prediction sharpens over a few readings —
    /// exactly as it does from a real G7. Mirrors processCGMReadingResult(.newData) + the loop
    /// trigger, minus the CGMManager plumbing. In OPEN loop the recommendation is computed but
    /// not enacted (advisory); a nil pump means checkPumpDataAndLoop just loops — no pod touched.
    func simIngestPhoneGlucose() {
        let ctx = ExtensionDelegate.shared().loopManager.activeContext
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
            self.glucoseStore.addGlucoseSamples([sample]) { result in
                if case .failure(let error) = result {
                    self.log.error("SIM glucose add failed: %{public}@", String(describing: error))
                }
                self.dataAccessQueue.async { self.glucoseMomentumEffect = nil }   // #51 parity
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

    /// #101 phase 2: where the persisted G7 state lives. StockLoopStack.assemble reads it
    /// back at construction (`G7CGMManager(rawState:)` — the stock phone pattern).
    static let cgmStateDefaultsKey = "g7.cgmManagerRawState"

    func cgmManagerDidUpdateState(_ manager: CGMManager) {
        // #101 phase 2: persist exactly as the stock phone does on this callback. The old
        // no-op here ("part of M5 integration") is why every launch constructed a blank
        // G7CGMManager and reran the acquisition lottery — the watch had the adoption and
        // threw it away on exit.
        guard manager is G7CGMManager else { return }
        let raw = manager.rawState
        defaults.set(raw, forKey: Self.cgmStateDefaultsKey)
        let sensorID = raw["sensorID"] as? String
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
        // #94 (2026-08-07): DEDUPE THE STORM. A Code=11 connect-retry loop pushed ~2,000
        // IDENTICAL lines/second through here (1051 in 0.52s, field 16:09:26) — each one a
        // synchronous NSLog plus a file-append — jamming syslogd and the log queue hard enough
        // to starve MAIN (the reproducible glance freeze) and rotate all real evidence out of
        // the log inside a second. The BLE-layer backoff makes the storm cold; this makes even
        // a future storm cheap AND readable: an identical repeat within 2s is counted, not
        // written, and the count is flushed on the next DIFFERENT line. Distinct lines pass
        // through untouched.
        deviceLogDedupeLock.lock()
        let line = "\(type) \(deviceIdentifier ?? "—"): \(message)"
        let now = self.now()
        if line == lastDeviceLogLine, now.timeIntervalSince(lastDeviceLogAt) < 2.0 {
            suppressedDeviceLogCount += 1
            lastDeviceLogAt = now
            deviceLogDedupeLock.unlock()
            completion?(nil)
            return
        }
        let suppressed = suppressedDeviceLogCount
        suppressedDeviceLogCount = 0
        lastDeviceLogLine = line
        lastDeviceLogAt = now
        deviceLogDedupeLock.unlock()
        if suppressed > 0 {
            SportLog.event(source, "(previous line repeated ×\(suppressed) — suppressed)")
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

    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier, completion: @escaping (Swift.Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }

    func lookupAllUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {
        completion(.success([]))
    }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {
        completion(.success([]))
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
