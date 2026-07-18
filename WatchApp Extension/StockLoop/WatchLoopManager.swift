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

            // Mirrors loopInternal(): enact only when automatic dosing is enabled — the
            // watch analogue is the phone-pushed `dosingEnabled` plus the per-session
            // closed-loop opt-in (crown ceremony), which arrives with M5 integration.
            if error == nil, self.settings.dosingEnabled {
                error = self.enactRecommendedAutomaticDose()
            } else if error == nil {
                self.log.default("Not adjusting dosing during open loop.")
            }

            self.lastLoopError = error
            if let error {
                self.log.error("Loop ended with error: %{public}@", String(describing: error))
            } else {
                self.lastLoopCompleted = self.now()
                self.log.default("Loop ended (duration %.1fs)", self.now().timeIntervalSince(startDate))
            }
        }
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

    func enact(recommendation: AutomaticDoseRecommendation, with pumpManager: PumpManager, completion: @escaping (PumpManagerError?) -> Void) {
        dosingQueue.async {
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
                completion(tempBasalError)
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
            completion(bolusError)
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
        }
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
