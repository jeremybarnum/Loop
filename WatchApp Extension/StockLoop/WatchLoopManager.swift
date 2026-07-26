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
    var settings: LoopSettings {
        didSet {
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

    /// The loan controller's dose-recording hooks (spec §1.2); set alongside
    /// `pumpManager` by PodLoanWatchController, cleared with it.
    weak var loanDoseRecorder: WatchLoanDoseRecording? {
        get { doseEnactor.loanRecorder }
        set { doseEnactor.loanRecorder = newValue }
    }

    /// Fix B: the radio-arbiter probe, forwarded to the enactor (StockLoopSession wires
    /// it to G7Client.isHandshakeActive).
    var isRadioBusy: (() -> Bool)? {
        get { doseEnactor.isRadioBusy }
        set { doseEnactor.isRadioBusy = newValue }
    }

    /// E4 Stage 2 (task #40): reclaim the orphaned pod before a dose, release after.
    /// Forwarded to the enactor (automatic path); enactManualBolus uses them directly.
    /// Wired by StockLoopSession to the loan controller (which owns the OmniPumpManager);
    /// no-op / immediate-connected when E4 is off.
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
    func setClosedLoopEnabled(_ enabled: Bool) {
        dataAccessQueue.async {
            self._closedLoopEnabled = enabled
            SportLog.event("loop", enabled ? "CLOSED by user — the watch will adjust basal" : "OPENED by user — advisory only, no dosing")
        }
    }

    // MARK: - Glance surface (R23; display only — no dosing paths read this)

    struct GlanceData {
        let glucose: HKQuantity?
        let glucoseDate: Date?
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
    }


    /// #50: the temp basal the pod is running, as best the watch can know it — the live
    /// `basalDeliveryState` while the pod is connected, otherwise the temp we last enacted
    /// until its programmed end. E4 orphans the pod, so `basalDeliveryState` goes nil within
    /// seconds even though the pod keeps delivering. Read on `dataAccessQueue`.
    private func runningTempBasal() -> DoseEntry? {
        if case .some(.tempBasal(let dose)) = pumpManager?.status.basalDeliveryState {
            return dose
        }
        if let cached = cachedEnactedTempBasal, cached.endDate > now() {
            return cached
        }
        return nil
    }

    /// Synchronous snapshot of the cached loop state for the glance screen.
    func glanceData() -> GlanceData {
        return dataAccessQueue.sync {
            let latest = glucoseStore.latestGlucose
            var tempRate: Double?
            if let dose = runningTempBasal() {
                // Show NET (temp − scheduled), matching stock's net-basal convention and
                // publishHUDContext (:324). The glance renders this with a forced sign
                // ("%+.2f"), so net makes it meaningful: + above schedule, − a reduction,
                // 0 at schedule. (Was the ABSOLUTE rate, so a low-temp rendered as a
                // meaningless "+0.00" that read as "no action" — 2026-07-25.)
                let scheduled = settings.basalRateSchedule?.value(at: now()) ?? 0
                tempRate = dose.unitsPerHour - scheduled
            }
            return GlanceData(
                glucose: latest?.quantity,
                glucoseDate: latest?.startDate,
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
                iob: insulinOnBoard?.value,
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
                lastLoopErrorText: lastLoopError.map { String(describing: $0) })
        }
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
        let velocities = dataAccessQueue.sync { insulinCounteractionEffects }
        carbStore.carbsOnBoard(at: now(), effectVelocities: velocities) { result in
            if case .success(let value) = result {
                completion(value.quantity.doubleValue(for: .gram()))
            } else {
                completion(nil)
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
        let latest = glucoseStore.latestGlucose
        ctx.glucose = latest?.quantity
        ctx.glucoseDate = latest?.startDate
        ctx.glucoseTrend = (latest as? StoredGlucoseSample)?.trend
        ctx.iob = insulinOnBoard?.value
        ctx.loopLastRunDate = lastLoopCompleted
        ctx.isClosedLoop = _closedLoopEnabled
        if let dose = runningTempBasal() {
            let scheduled = settings.basalRateSchedule?.value(at: now()) ?? 0
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
        }
    }

    // MARK: The CGM input (stock G7CGMManager over the proven transport — M3)

    /// Held so the stack has an owner; delegate wiring happens in StockLoopStack.assemble().
    private(set) var cgmStack: G7ClientTransportAdapter?

    // MARK: Queues (mirrors the phone's DeviceDataManager.queue / LoopDataManager.dataAccessQueue split)

    /// Device-facing events (CGM delegate callbacks). The G7CGMManager's `delegateQueue`.
    let deviceQueue = DispatchQueue(label: "com.loopkit.Loop.WatchLoopManager.deviceQueue", qos: .utility)

    /// Loop state. All cached effects and recommendation state are confined to this queue.
    private let dataAccessQueue = DispatchQueue(label: "com.loopkit.Loop.WatchLoopManager.dataAccessQueue", qos: .utility)

    private let log = OSLog(category: "WatchLoopManager")

    /// Test seam, same shape as the phone's `now()`.
    var now: () -> Date = { Date() }

    init(doseStore: DoseStore, glucoseStore: GlucoseStore, carbStore: CarbStore, settings: LoopSettings = LoopSettings()) {
        self.doseStore = doseStore
        self.glucoseStore = glucoseStore
        self.carbStore = carbStore
        self.settings = settings
        // #50: cache each accepted temp so runningTempBasal() can report what the pod is
        // running while E4 has it orphaned (basalDeliveryState is nil then). Built here so the
        // DoseEntry uses this manager's testable clock; the cache is dataAccessQueue-isolated.
        doseEnactor.onTempBasalEnacted = { [weak self] unitsPerHour, duration in
            guard let self = self else { return }
            let start = self.now()
            let enacted = DoseEntry(type: .tempBasal, startDate: start, endDate: start.addingTimeInterval(duration), value: unitsPerHour, unit: .unitsPerHour)
            self.dataAccessQueue.async { self.cachedEnactedTempBasal = enacted }
        }
    }

    func attach(cgmStack: G7ClientTransportAdapter) {
        self.cgmStack = cgmStack
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
    /// #50: the temp basal we last successfully enacted, cached so the watch knows what the
    /// pod is running without querying it. E4 orphans the pod after each dose, so
    /// `pumpManager.status.basalDeliveryState` reverts to nil within seconds even though the
    /// pod keeps delivering the accepted temp for its full programmed duration. dataAccessQueue.
    private var cachedEnactedTempBasal: DoseEntry?
    private var retrospectiveGlucoseEffect: [GlucoseEffect] = []

    /// Mirrors LoopDataManager's buffer multiplier for combining retrospective discrepancies.
    private let retrospectiveCorrectionGroupingIntervalMultiplier = 1.01

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

            // H19 port: the loop proved ALIVE (fresh data -> effects -> prediction).
            // Push the dead-man forward BEFORE enact: a deliberate suspend denies the
            // enact but is not a stall. Recency failures deliberately do NOT refresh —
            // a prolonged reading gap is exactly what the watchdog exists to catch.
            if error == nil, self.pumpManager != nil {
                LoopStallWatchdog.refresh()
            }

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
            if let error {
                self.log.error("Loop ended with error: %{public}@", String(describing: error))
                // Radio defers are logged at the defer site; don't double-log those.
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
                    rows.append(String(format: "%@ %@..%@ net=%+.3f sched=%@ mut=%@ id=%@",
                                       "\(d.type)", tf.string(from: d.startDate), tf.string(from: d.endDate),
                                       d.netBasalUnits, sched, d.isMutable ? "Y" : "n", id))
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

        if insulinEffectIncludingPendingInsulin == nil {
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
                case .success(let (_, effects)):
                    self.carbEffect = effects
                }
                updateGroup.leave()
            }
        }

        updateGroup.enter()
        doseStore.insulinOnBoard(at: now()) { result in
            switch result {
            case .failure(let error):
                self.log.error("Failure getting insulin on board: %{public}@", String(describing: error))
                self.insulinOnBoard = nil
            case .success(let insulinValue):
                self.insulinOnBoard = insulinValue
            }
            updateGroup.leave()
        }

        _ = updateGroup.wait(timeout: .distantFuture)

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
        // #46/#3 RC input (2026-07-25): surfaces the active RC TYPE (the watch defaults to
        // Standard and, per #46, may not track the phone's Integral toggle — a real
        // prediction divergence) plus how much RC is contributing.
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
    private func predictGlucose(includingPendingInsulin: Bool = false) throws -> [PredictedGlucoseValue] {
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

        if let carbEffect = self.carbEffect {
            effects.append(carbEffect)
        }

        if let insulinEffect = includingPendingInsulin ? self.insulinEffectIncludingPendingInsulin : self.insulinEffect {
            effects.append(insulinEffect)
        }

        if let momentumEffect = self.glucoseMomentumEffect {
            momentum = momentumEffect
        }

        effects.append(retrospectiveGlucoseEffect)

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
        guard let basalRateSchedule = settings.basalRateSchedule else {
            return .configurationError("basalRateSchedule")
        }
        guard let insulinSensitivity = settings.insulinSensitivitySchedule else {
            return .configurationError("insulinSensitivitySchedule")
        }
        guard settings.carbRatioSchedule != nil else {
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
    func recommendManualBolus(completion: @escaping (Swift.Result<ManualBolusRecommendation, Error>) -> Void) {
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

                let prediction = try self.predictGlucose(includingPendingInsulin: true)

                // Same configuration guards as recommendManualBolus (:1539-1547).
                guard let glucoseTargetRange = self.settings.effectiveGlucoseTargetRangeSchedule() else {
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
                        SportLog.event("loan", "MANUAL BOLUS delivering")
                        // 134: fold the bolus into IOB/prediction/HUD NOW, not at the next
                        // reading (field: 0.75 U showed no immediate IOB update anywhere).
                        self.dataAccessQueue.async {
                            self.insulinEffect = nil
                            self.insulinEffectIncludingPendingInsulin = nil
                        }
                        self.loop()
                    }
                    DispatchQueue.main.async { completion(error) }
                }
            }
            // E4 Stage 2: the pod is orphaned for G7 — reclaim it before the bolus.
            // User is PRESENT, so a few seconds' reconnect is fine; on failure FAIL
            // LOUDLY (never a silent no-bolus). No-op immediate when E4 is off.
            if let reclaim = self.e4ReclaimPodForDose {
                reclaim { ok in
                    if ok {
                        deliverBolus()
                    } else {
                        self.e4ReleasePodAfterDose?()
                        SportLog.event("loan", "MANUAL BOLUS FAILED — E4 pod reconnect timed out (pod unreachable)")
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

        doseEnactor.enact(recommendation: recommendedDose.recommendation, with: pumpManager) { error in
            if let error = error {
                enactError = .missingDataError(String(describing: error))
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
        guard UserDefaults.standard.bool(forKey: "g7.e5RandomTemp") else { return }
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
            UserDefaults.standard.set(String(format: "%+.2f @ %@", rate, clock.string(from: self.now())), forKey: "g7.e5LastCmd")
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

// MARK: - Dose enactor (mirrors Loop/Managers/DoseEnactor.swift)

/// Same sequencing as the phone's DoseEnactor: temp-basal adjustment first, wait, then any
/// automatic bolus — all through stock `PumpManager` protocol methods, so pulse-grid
/// snapping, cancel-before-program, busy handling, and uncertain-delivery classification are
/// the stock driver's (OmniPumpManager, M2), not ours.
final class WatchDoseEnactor {

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
    var isRadioBusy: (() -> Bool)?

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

    func enact(recommendation: AutomaticDoseRecommendation, with pumpManager: PumpManager, completion: @escaping (PumpManagerError?) -> Void) {
        dosingQueue.async {
            // BG still wins the radio — but WAIT for the handshake instead of throwing the
            // dose cycle away on a millisecond-scale collision.
            //
            // Field 2026-07-22 15:42: the enact check landed 53ms after the VALUE, while
            // the G7 link was still up, and the whole cycle was abandoned. The two cycles
            // that DID dose (15:32, 15:37) differed only in that G7 logged
            // "!! disconnected (clean)" ~30ms BEFORE the enact ran. Pure race, and losing
            // it silently costs a full 5-minute dose cycle. E5 hit the identical race and
            // was fixed with a delay; the production dose path never got that treatment.
            //
            // The handshake completes in seconds and the next G7 window is ~5 minutes out,
            // so waiting is free. Poll rather than block so the dosing queue stays
            // responsive; give up only if the radio is genuinely stuck.
            var radioWaited: TimeInterval = 0
            while self.isRadioBusy?() == true, radioWaited < 15 {
                Thread.sleep(forTimeInterval: 0.5)
                radioWaited += 0.5
            }
            if self.isRadioBusy?() == true {
                self.log.default("Enact DEFERRED — G7 handshake owns the radio (BG wins); the next reading retries")
                SportLog.event("radio", "enact DEFERRED — G7 still owns the radio after 15s; retry next reading")
                completion(.communication(nil))
                return
            }
            if radioWaited > 0 {
                SportLog.event("radio", String(format: "enact waited %.1fs for the G7 handshake, then proceeded", radioWaited))
            }

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
            let now = Date()
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
        return glucoseStore.latestGlucose.map { Date().timeIntervalSince($0.startDate) }
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
        case .newData(let values):
            // BENCH-ONLY (#33/R29): substitute scripted values AFTER a successful real read.
            // Deliberately here and not upstream — the G7 connect/handshake already happened,
            // so radio contention and E4 timing stay genuine and a MISSED window stays
            // missed. Everything downstream (store, momentum, prediction, DoseMath, the pod
            // command) is real. No-op unless the bench flag is on.
            let values = FakeGlucose.isEnabled ? FakeGlucose.substitute(values) : values
            glucoseStore.addGlucoseSamples(values) { result in
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
                let now = Date()
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

    func cgmManagerDidUpdateState(_ manager: CGMManager) {
        // Stock managers persist via rawValue on this callback. Wiring the persisted CGM
        // state into the watch app's storage is part of M5 integration (the manager
        // reconstructs from its transport today).
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
