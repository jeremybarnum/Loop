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
    var settings: LoopSettings

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

    /// Synchronous snapshot of the cached loop state for the glance screen.
    func glanceData() -> GlanceData {
        return dataAccessQueue.sync {
            let latest = glucoseStore.latestGlucose
            var tempRate: Double?
            if case .some(.tempBasal(let dose)) = pumpManager?.status.basalDeliveryState {
                tempRate = dose.unitsPerHour
            }
            return GlanceData(
                glucose: latest?.quantity,
                glucoseDate: latest?.startDate,
                trend: (latest as? StoredGlucoseSample)?.trend,
                eventual: predictedGlucose?.last?.quantity,
                iob: insulinOnBoard?.value,
                tempRate: tempRate,
                lastLoopCompleted: lastLoopCompleted,
                suspendThreshold: settings.suspendThreshold?.quantity,
                closedLoopEnabled: _closedLoopEnabled,
                dosingAllowedByPhone: settings.dosingEnabled,
                recommendedTempRate: recommendedAutomaticDose?.recommendation.basalAdjustment?.unitsPerHour,
                lastLoopErrorText: lastLoopError.map { String(describing: $0) })
        }
    }

    /// COB for the glance rail (async — the store computes it).
    func glanceCarbsOnBoard(_ completion: @escaping (Double?) -> Void) {
        carbStore.carbsOnBoard(at: now()) { result in
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
        if case .some(.tempBasal(let dose)) = pumpManager?.status.basalDeliveryState {
            let scheduled = settings.basalRateSchedule?.value(at: now()) ?? 0
            ctx.lastNetTempBasalDose = dose.unitsPerHour - scheduled
            ctx.lastNetTempBasalDate = dose.startDate
        } else {
            ctx.lastNetTempBasalDose = 0
            ctx.lastNetTempBasalDate = now()
        }
        carbStore.carbsOnBoard(at: now()) { result in
            if case .success(let value) = result {
                ctx.cob = value.quantity.doubleValue(for: .gram())
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
    private var carbEffect: [GlucoseEffect]?
    private var insulinOnBoard: InsulinValue?
    private var retrospectiveGlucoseEffect: [GlucoseEffect] = []

    /// Mirrors LoopDataManager's buffer multiplier for combining retrospective discrepancies.
    private let retrospectiveCorrectionGroupingIntervalMultiplier = 1.01

    private var retrospectiveGlucoseDiscrepancies: [GlucoseEffect]? {
        didSet {
            retrospectiveGlucoseDiscrepanciesSummed = retrospectiveGlucoseDiscrepancies?.combinedSums(of: LoopMath.retrospectiveCorrectionGroupingInterval * retrospectiveCorrectionGroupingIntervalMultiplier)
        }
    }
    private var retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?

    /// The phone switches Standard/Integral RC on a phone-local UserDefaults toggle
    /// (`LoopDataManager.retrospectiveCorrection:457`); that toggle is not pushed to the
    /// watch, so the watch mirrors the default. Both implementations compile here (LoopKit
    /// watchOS target, M4).
    private let retrospectiveCorrection: RetrospectiveCorrection = StandardRetrospectiveCorrection(effectDuration: LoopMath.retrospectiveCorrectionEffectDuration)

    private var predictedGlucose: [PredictedGlucoseValue]?
    private var predictedGlucoseIncludingPendingInsulin: [PredictedGlucoseValue]?

    private var recommendedAutomaticDose: (recommendation: AutomaticDoseRecommendation, date: Date)?

    private(set) var lastLoopCompleted: Date?
    private(set) var lastLoopError: Error?

    /// Mirrors DeviceDataManager.lastCGMLoopTrigger (deviceQueue only).
    private var lastCGMLoopTrigger: Date = .distantPast

    private let doseEnactor = WatchDoseEnactor()

    // MARK: - Loop cycle (mirrors loop()/loopInternal())

    /// One loop cycle: refresh effects, gate, predict, recommend, enact (via the seam).
    /// Triggered by new CGM data exactly as the phone's DeviceDataManager does; safe to call
    /// from any queue.
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
                let rec = self.recommendedAutomaticDose.map { String(describing: $0.recommendation.basalAdjustment?.unitsPerHour ?? 0) } ?? "none"
                SportLog.event("loop", "cycle OK — BG \(bg), IOB \(self.insulinOnBoard.map { String(format: "%.2f", $0.value) } ?? "—"), temp \(rec)")
                self.logPredictionBreakdown()
                self.publishHUDContext()
            }
        }
    }

    /// 134 dosing-audit instrumentation (Jeremy 2026-07-20: "make sure prediction is
    /// well instrumented in the logs so we can iterate to the answer as efficiently
    /// as possible"). One line per cycle decomposing WHAT the dose math saw: each
    /// cached effect's net mg/dL contribution over its horizon, the eventual BG, and
    /// the recommendation. A missing input reads "—" — absence is a finding, not a
    /// blank (the 20:31 carb-invalidation bug would have been one glance: COB present
    /// on screen, "carbs —" here).
    private func logPredictionBreakdown() {   // dataAccessQueue
        func net(_ effects: [GlucoseEffect]?) -> String {
            guard let effects, let first = effects.first, let last = effects.last else { return "—" }
            let delta = last.quantity.doubleValue(for: .milligramsPerDeciliter) - first.quantity.doubleValue(for: .milligramsPerDeciliter)
            return String(format: "%+.0f", delta)
        }
        let eventual = predictedGlucose?.last.map { String(format: "%.0f", $0.quantity.doubleValue(for: .milligramsPerDeciliter)) } ?? "—"
        let rc = retrospectiveGlucoseEffect.isEmpty ? "—" : net(retrospectiveGlucoseEffect)
        let rec: String
        if let r = recommendedAutomaticDose {
            let basal = r.recommendation.basalAdjustment.map { String(format: "%.2f U/h", $0.unitsPerHour) } ?? "no basal change"
            let bolus = r.recommendation.bolusUnits.map { String(format: " + auto-bolus %.2f U", $0) } ?? ""
            rec = basal + bolus
        } else {
            rec = "none"
        }
        SportLog.event("predict", "eventual \(eventual) · net effects: carbs \(net(carbEffect)), insulin \(net(insulinEffect)), momentum \(net(glucoseMomentumEffect)), RC \(rc) · rec \(rec)")
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
            glucoseStore.getRecentMomentumEffect(for: now()) { result in
                switch result {
                case .failure(let error):
                    self.log.error("Failure getting recent momentum effect: %{public}@", String(describing: error))
                    self.glucoseMomentumEffect = nil
                case .success(let effects):
                    self.glucoseMomentumEffect = effects
                }
                updateGroup.leave()
            }
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

        guard now().timeIntervalSince(pumpStatusDate) <= LoopCoreConstants.inputDataRecencyInterval else {
            throw WatchLoopError.pumpDataTooOld(date: pumpStatusDate)
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

            let lastTempBasal: DoseEntry?
            if case .some(.tempBasal(let dose)) = pumpManager?.status.basalDeliveryState {
                lastTempBasal = dose
            } else {
                lastTempBasal = nil
            }

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

    func enact(recommendation: AutomaticDoseRecommendation, with pumpManager: PumpManager, completion: @escaping (PumpManagerError?) -> Void) {
        dosingQueue.async {
            if self.isRadioBusy?() == true {
                self.log.default("Enact DEFERRED — G7 handshake owns the radio (BG wins); the next reading retries")
                SportLog.event("radio", "enact DEFERRED — G7 handshake owns the radio (BG wins); retry next reading")
                completion(.communication(nil))
                return
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
                doseDispatchGroup.enter()
                let eventID = self.loanRecorder?.loanWillEnactTempBasal(unitsPerHour: basalAdjustment.unitsPerHour, duration: basalAdjustment.duration)
                pumpManager.enactTempBasal(unitsPerHour: basalAdjustment.unitsPerHour, for: basalAdjustment.duration) { error in
                    self.loanRecorder?.loanDidEnact(eventID: eventID, error: error)
                    if let error = error {
                        tempBasalError = error
                    }
                    doseDispatchGroup.leave()
                }
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
                self.loop()
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
            glucoseStore.addGlucoseSamples(values) { result in
                if case .failure(let error) = result {
                    self.log.error("Failure adding glucose samples: %{public}@", String(describing: error))
                }
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
