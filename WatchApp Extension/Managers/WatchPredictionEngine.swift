//
//  WatchPredictionEngine.swift
//  WatchApp Extension
//
//  Runs the real Loop algorithm (LoopAlgorithm.generatePrediction + DoseMath)
//  on the watch against the stored glucose series: eventual BG, the correction
//  range it was judged against, and a temp-basal recommendation.
//
//  Effects config: FULL stock pipeline (.all — insulin, carbs, momentum,
//  retrospective correction). The direct G7 stream provides the dense 5-min
//  series momentum/RC require; the algorithm anchors on the genuine newest
//  stored sample (no synthetic anchor — a fabricated sample carries foreign
//  provenance and a re-stamped clock, corrupting momentum and ICE pairing).
//  Manual entries persist FIRST and enter the history like any other sample —
//  exactly how stock Loop treats wasUserEntered readings.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore
import OmniBLECore
import WatchConnectivity
import os.log

enum WatchPredictionError: LocalizedError {
    case missingSetting(String)
    case noJournal

    var errorDescription: String? {
        switch self {
        case .missingSetting(let name):
            return String(format: NSLocalizedString("%@ hasn't synced from the iPhone yet.", comment: "Prediction error: a therapy setting is missing"), name)
        case .noJournal:
            return NSLocalizedString("No Sport Mode session is active.", comment: "Prediction error: no loan journal")
        }
    }
}

struct WatchPredictionOutput {
    let date: Date
    /// startDate of the newest glucose sample this prediction is anchored on — the READING's
    /// identity. The closed loop dedups on this so it enacts AT MOST ONCE per genuinely-new
    /// reading, no matter how many refresh triggers fire for the same reading (observer +
    /// backfills/purges + phase activation + any stray phone push). `date` above is wall-clock
    /// at predict-time and is NOT a stable per-reading key.
    let anchorDate: Date
    let unit: HKUnit
    let currentBG: HKQuantity
    let eventualBG: HKQuantity
    let predictedGlucose: [PredictedGlucoseValue]
    let correctionRange: ClosedRange<HKQuantity>
    /// nil means the scheduled basal already fits the prediction.
    let recommendedTempBasal: TempBasalRecommendation?
    let scheduledBasalRate: Double
    /// ISF at the prediction date (glucose-per-U) — for the correction math.
    let sensitivity: HKQuantity
    /// Therapy-settings max basal (U/hr) — the temp cap.
    let maxBasalRate: Double
    /// Active insulin (U) at the prediction date — same doses the prediction
    /// used, LoopKit insulinOnBoard. Cross-checkable against the phone's HUD.
    let activeInsulin: Double
    /// Active carbs (g) at the prediction date — dynamic (ICE-informed) COB
    /// from the same carb statuses the prediction used.
    let activeCarbs: Double
    /// false: the grant carried no pre-loan history — prediction sees
    /// loan-session insulin only and understates IOB from earlier boluses.
    let usedPreLoanHistory: Bool
    let inputDoseCount: Int
    let inputCarbCount: Int
    /// The stock manual-bolus recommendation (U) for the current prediction — used by
    /// the Sport Mode carb+bolus flow to recommend a meal bolus locally (phone-free),
    /// same as the phone. Includes any `pendingCarb` passed to `predict`.
    let recommendedBolus: Double?
}

extension WatchPredictionOutput {
    /// The correction math, step by step (eventual → target → Δ → ÷ISF →
    /// 30-min temp), for the EVENTUAL glucose — which is exactly DoseMath's
    /// arithmetic there (target = correction-range midpoint; temp = scheduled +
    /// correctionUnits / durationHours, floored at 0, capped at max). It does
    /// NOT reflect the interim-low handling (min across the whole curve, the
    /// time-ramped target, the suspend threshold) — that lives in Loop's
    /// `recommendedTempBasal`. When this derivation and the recommendation
    /// diverge, a predicted low is constraining the real dose.
    struct CorrectionMath {
        let unit: HKUnit
        let eventual: Double
        let targetLow: Double
        let targetHigh: Double
        let sensitivity: Double      // glucose per U
        let scheduledBasal: Double
        let maxBasalRate: Double
        let duration: TimeInterval

        var targetMid: Double { (targetLow + targetHigh) / 2 }
        var difference: Double { eventual - targetMid }              // + above target
        var insulin: Double { sensitivity > 0 ? difference / sensitivity : 0 }  // ± U
        /// Positive insulin = excess above scheduled; negative = shortage below,
        /// floored at 0 delivery; capped at max.
        var rawTempRate: Double { scheduledBasal + insulin / (duration / 3600) }
        var tempRate: Double { Swift.min(maxBasalRate, Swift.max(0, rawTempRate)) }
        var isCapped: Bool { rawTempRate > maxBasalRate }
        var isSuspend: Bool { rawTempRate <= 0 }
    }

    func correctionMath(duration: TimeInterval = .minutes(30)) -> CorrectionMath {
        CorrectionMath(
            unit: unit,
            eventual: eventualBG.doubleValue(for: unit),
            targetLow: correctionRange.lowerBound.doubleValue(for: unit),
            targetHigh: correctionRange.upperBound.doubleValue(for: unit),
            sensitivity: sensitivity.doubleValue(for: unit),
            scheduledBasal: scheduledBasalRate,
            maxBasalRate: maxBasalRate,
            duration: duration)
    }
}

final class WatchPredictionEngine {
    private let loopManager: LoopDataManager
    private let coordinator: WatchPodLoanCoordinator
    private let log = OSLog(category: "WatchPredictionEngine")

    /// Whether run() persists the anchor BG as a user-entered sample. True for
    /// the entry dial (the rider is REPORTING a reading); false for background
    /// HUD refreshes, which anchor on an already-stored sample.
    private var storeEntry = true
    /// A carb the user is CONSIDERING (not yet stored) — injected into this run's carb
    /// history so the manual-bolus recommendation accounts for it (the Sport Mode
    /// carb+bolus flow). Cleared after each run.
    private var pendingCarb: NewCarbEntry?

    /// Dedup key for the "predict:" reconciliation register so it emits ONE line per
    /// genuinely new cycle, not per redundant recompute. Keyed on the anchor sample's
    /// identity + dose/carb counts + the temp recommendation — deliberately excluding
    /// age/eventual/IOB/COB, which drift every run (date = Date()) and would defeat the
    /// dedup. A new CGM reading (new anchor startDate), a new/changed dose, a new carb,
    /// or a none↔temp flip all change the key and still log.
    private var lastLoggedPredictSignature: String?
    /// Guards lastLoggedPredictSignature: the dedup check runs inside run()'s
    /// group.notify(queue: .global) block, so overlapping predicts would otherwise race
    /// on the String property (undefined behavior, not just a stray log line).
    private let predictSignatureLock = NSLock()

    init(loopManager: LoopDataManager, coordinator: WatchPodLoanCoordinator) {
        self.loopManager = loopManager
        self.coordinator = coordinator
    }

    private func settingsState(_ s: LoopSettings) -> String {
        "basal=\(s.basalRateSchedule != nil ? "Y" : "N") isf=\(s.insulinSensitivitySchedule != nil ? "Y" : "N") cr=\(s.carbRatioSchedule != nil ? "Y" : "N") target=\(s.glucoseTargetRangeSchedule != nil ? "Y" : "N") maxBasal=\(s.maximumBasalRatePerHour != nil ? "Y" : "N")"
    }

    private func settingsIncomplete(_ s: LoopSettings) -> Bool {
        s.basalRateSchedule == nil || s.insulinSensitivitySchedule == nil
            || s.carbRatioSchedule == nil || s.glucoseTargetRangeSchedule == nil
            || s.maximumBasalRatePerHour == nil
    }

    /// The newest glucose sample the watch knows (backfilled CGM or a prior
    /// manual entry) — seeds the entry dial so the rider starts from the last
    /// known value instead of an arbitrary default.
    @MainActor
    func latestGlucose(completion: @escaping (StoredGlucoseSample?) -> Void) {
        loopManager.glucoseStore.getGlucoseSamples(start: Date(timeIntervalSinceNow: -.hours(10)), end: Date()) { result in
            var sample: StoredGlucoseSample?
            if case .success(let samples) = result {
                sample = samples.max(by: { $0.startDate < $1.startDate })
            }
            DispatchQueue.main.async { completion(sample) }
        }
    }

    /// Predict from a manually entered BG and recommend a temp basal. If core
    /// settings are missing, first pull them from the phone over sendMessage
    /// (the push path loses them across a watch reinstall and is unreliable on
    /// simulators), then run. Every branch logs — silence is not an option here.
    @MainActor
    func predict(manualBG: HKQuantity, at date: Date = Date(), storeEntry: Bool = true, pendingCarb: NewCarbEntry? = nil, completion: @escaping (Swift.Result<WatchPredictionOutput, Error>) -> Void) {
        let tapped = Date()
        self.storeEntry = storeEntry
        self.pendingCarb = pendingCarb
        let settings = loopManager.settings
        log.default("predict: settings state %{public}@", settingsState(settings))

        // Freshen the watch-local carb/glucose stores opportunistically; replies
        // land async, so they enrich this run if fast and the next run if not.
        // (The carb-list screen normally triggers this, but Sport Mode repurposes
        // its button — without this line, carbs never backfill mid-session.)
        loopManager.requestCarbBackfill()
        loopManager.requestGlucoseBackfillIfNecessary()

        guard settingsIncomplete(settings) else {
            pullDoseHistoryIfNeededThenRun(manualBG: manualBG, at: date, tapped: tapped, completion: completion)
            return
        }

        let session = WCSession.default
        log.default("predict: settings incomplete; WC activation=%d reachable=%d — pulling from phone",
                    session.activationState.rawValue, session.isReachable ? 1 : 0)

        guard session.activationState == .activated else {
            session.activate()
            return completion(.failure(WatchPredictionError.missingSetting("Settings (watch session inactive) — Basal schedule")))
        }

        session.sendMessage(["name": LoopSettingsUserInfo.name], replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                if let fresh = LoopSettingsUserInfo(rawValue: reply)?.settings {
                    self.log.default("predict: settings pull succeeded: %{public}@", self.settingsState(fresh))
                    self.loopManager.settings = fresh
                } else {
                    self.log.error("predict: settings pull reply failed to decode: %{public}@", String(describing: reply))
                }
                self.pullDoseHistoryIfNeededThenRun(manualBG: manualBG, at: date, tapped: tapped, completion: completion)
            }
        }, errorHandler: { [weak self] error in
            self?.log.error("predict: settings pull failed: %{public}@", String(describing: error))
            Task { @MainActor in
                self?.pullDoseHistoryIfNeededThenRun(manualBG: manualBG, at: date, tapped: tapped, completion: completion)
            }
        })
    }

    /// Pre-loan insulin history: grant payload first; otherwise pull once from
    /// the phone. Missing history skews IOB low, so it's worth a round-trip.
    @MainActor
    private func pullDoseHistoryIfNeededThenRun(manualBG: HKQuantity, at date: Date, tapped: Date, completion: @escaping (Swift.Result<WatchPredictionOutput, Error>) -> Void) {
        guard coordinator.grantDoseHistoryData == nil, coordinator.pulledDoseHistoryData == nil else {
            return run(manualBG: manualBG, at: date, tapped: tapped, completion: completion)
        }

        let session = WCSession.default
        guard session.activationState == .activated else {
            log.default("predict: no dose history and WC inactive — running without")
            return run(manualBG: manualBG, at: date, tapped: tapped, completion: completion)
        }

        log.default("predict: no grant dose history — pulling from phone")
        session.sendMessage(["name": PodLoanDoseHistoryRequest.name], replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                if let data = reply["dh"] as? Data {
                    self.log.default("predict: dose history pull succeeded (%d bytes)", data.count)
                    self.coordinator.pulledDoseHistoryData = data
                } else {
                    self.log.error("predict: dose history pull returned no data")
                }
                self.run(manualBG: manualBG, at: date, tapped: tapped, completion: completion)
            }
        }, errorHandler: { [weak self] error in
            self?.log.error("predict: dose history pull failed: %{public}@", String(describing: error))
            Task { @MainActor in
                self?.run(manualBG: manualBG, at: date, tapped: tapped, completion: completion)
            }
        })
    }

    @MainActor
    private func run(manualBG: HKQuantity, at date: Date, tapped: Date, completion: @escaping (Swift.Result<WatchPredictionOutput, Error>) -> Void) {
        let pullsDone = Date()
        let settings = loopManager.settings

        // Every input the algorithm can't default must have synced.
        guard let basalSchedule = settings.basalRateSchedule else {
            return completion(.failure(WatchPredictionError.missingSetting("Basal schedule")))
        }
        guard let sensitivitySchedule = settings.insulinSensitivitySchedule else {
            return completion(.failure(WatchPredictionError.missingSetting("Insulin sensitivity")))
        }
        guard let carbRatioSchedule = settings.carbRatioSchedule else {
            return completion(.failure(WatchPredictionError.missingSetting("Carb ratio")))
        }
        guard let targetSchedule = settings.glucoseTargetRangeSchedule else {
            return completion(.failure(WatchPredictionError.missingSetting("Correction range")))
        }
        guard let maxBasalRate = settings.maximumBasalRatePerHour else {
            return completion(.failure(WatchPredictionError.missingSetting("Max basal rate")))
        }

        let insulinType = coordinator.grantInsulinTypeRaw.flatMap { InsulinType(rawValue: $0) }
        // Correction/bolus math uses the curve for the PUMP's insulin type, exactly
        // as the phone does via PresetInsulinModelProvider.model(for:) — fixed-curve
        // types get their own preset; rapid-acting types use the settings default.
        let model: ExponentialInsulinModelPreset
        switch insulinType {
        case .fiasp:   model = .fiasp
        case .lyumjev: model = .lyumjev
        case .afrezza: model = .afrezza
        default:       model = settings.defaultRapidActingModel ?? .rapidActingAdult
        }

        // Doses: pre-loan history from the grant + the loan journal, with the
        // active temp carried at full programmed extent (parity with the
        // phone's live path, which sees the mutable temp's future remainder).
        let journal = coordinator.journalForPrediction
        let grantHistory = (coordinator.grantDoseHistoryData ?? coordinator.pulledDoseHistoryData)
            .flatMap { PodLoanDoseHistory.decode(from: $0) }?
            .doseEntries(insulinType: insulinType) ?? []
        let activeTemp = journal?.activeTempBasal(at: date, insulinType: insulinType)
        let journalDoses = journal?.doseEntries(until: activeTemp?.endDate ?? date, insulinType: insulinType) ?? []
        let doses = (grantHistory + journalDoses).sorted { $0.startDate < $1.startDate }

        // Timelines: cover every dose (validated by the algorithm) plus the
        // prediction span.
        let historyStart = min(doses.first?.startDate ?? date, date.addingTimeInterval(-.hours(16)))
            .addingTimeInterval(-.hours(1))
        let horizon = date.addingTimeInterval(.hours(7))

        let basalTimeline = basalSchedule.between(start: historyStart, end: horizon)
        let sensitivityUnit = sensitivitySchedule.unit
        let sensitivityTimeline = sensitivitySchedule.between(start: historyStart, end: horizon).map {
            AbsoluteScheduleValue(startDate: $0.startDate, endDate: $0.endDate, value: HKQuantity(unit: sensitivityUnit, doubleValue: $0.value))
        }
        let carbRatioTimeline = carbRatioSchedule.between(start: historyStart, end: horizon)
        let targetUnit = targetSchedule.unit
        let targetTimeline = targetSchedule.between(start: date.addingTimeInterval(-.hours(1)), end: horizon).map {
            AbsoluteScheduleValue(
                startDate: $0.startDate,
                endDate: $0.endDate,
                value: ClosedRange(uncheckedBounds: (
                    lower: HKQuantity(unit: targetUnit, doubleValue: $0.value.minValue),
                    upper: HKQuantity(unit: targetUnit, doubleValue: $0.value.maxValue))))
        }

        let algorithmSettings = LoopAlgorithmSettings(
            basal: basalTimeline,
            sensitivity: sensitivityTimeline,
            carbRatio: carbRatioTimeline,
            target: targetTimeline,
            // algorithmEffectsOptions defaults to .all — full stock pipeline.
            maximumBasalRatePerHour: maxBasalRate,
            maximumBolus: settings.maximumBolus,
            suspendThreshold: settings.suspendThreshold)

        // Histories from the watch-local stores, then run. STOCK-LOOP PARITY: the stored
        // series IS the input. A manual entry persists FIRST so the fetch returns it as the
        // genuine newest sample; the G7 stream needs no help at all.
        let group = DispatchGroup()
        var glucoseHistory: [StoredGlucoseSample] = []
        var carbEntries: [StoredCarbEntry] = []

        group.enter()
        let beginGlucoseFetch = {
            self.loopManager.glucoseStore.getGlucoseSamples(start: date.addingTimeInterval(-.hours(10)), end: date) { result in
                if case .success(let samples) = result {
                    glucoseHistory = samples
                }
                group.leave()
            }
        }
        if storeEntry {
            loopManager.glucoseStore.addGlucoseSamples([NewGlucoseSample(
                date: date,
                quantity: manualBG,
                condition: nil,
                trend: nil,
                trendRate: nil,
                isDisplayOnly: false,
                wasUserEntered: true,
                syncIdentifier: UUID().uuidString)]) { result in
                if case .failure(let error) = result {
                    fileLog("*** predict: manual-entry store FAILED (\(error)) — anchoring on prior sample ***")
                }
                beginGlucoseFetch()
            }
        } else {
            beginGlucoseFetch()
        }

        group.enter()
        loopManager.carbStore.getCarbEntries(start: date.addingTimeInterval(-.hours(10)), end: date) { result in
            if case .success(let entries) = result {
                carbEntries = entries
            }
            group.leave()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            let fetchesDone = Date()
            // The stored series verbatim — the algorithm anchors on its genuine newest sample.
            let history = glucoseHistory
                .filter { $0.startDate <= date }
                .sorted { $0.startDate < $1.startDate }

            // Inject the carb under consideration (not yet stored) so the manual-bolus
            // recommendation below accounts for it. Additive; nil for the normal loop path.
            if let pending = self.pendingCarb {
                carbEntries.append(StoredCarbEntry(startDate: pending.startDate, quantity: pending.quantity,
                                                   foodType: pending.foodType, absorptionTime: pending.absorptionTime))
            }

            let input = LoopAlgorithmInput(
                predictionInput: LoopPredictionInput(
                    glucoseHistory: history,
                    doses: doses,
                    carbEntries: carbEntries,
                    settings: algorithmSettings),
                predictionDate: date,
                doseRecommendationType: .tempBasal)

            do {
                let (prediction, recommendation) = try LoopAlgorithm.generateRecommendation(
                    input: input,
                    correctionRange: targetSchedule,
                    sensitivity: sensitivitySchedule,
                    basalRates: basalSchedule,
                    model: model,
                    lastTempBasal: activeTemp)

                // Stock manual-bolus recommendation for this curve (the meal bolus for the
                // Sport Mode carb+bolus flow — includes any pendingCarb injected above).
                // pendingInsulin 0: the watch has no in-flight manual bolus. maxBolus-capped
                // exactly like the phone.
                let recommendedBolus: Double? = settings.maximumBolus.map { maxBolus in
                    prediction.glucose.recommendedManualBolus(
                        to: targetSchedule, at: date,
                        suspendThreshold: settings.suspendThreshold?.quantity,
                        sensitivity: sensitivitySchedule, model: model,
                        pendingInsulin: 0, maxBolus: maxBolus).amount
                }

                // IOB/COB for display: computed from the same inputs (and the
                // prediction's own ICE) so the numbers are the algorithm's view.
                // Annotate against the basal timeline first: netBasalUnits only
                // nets temp segments against schedule when the annotation exists
                // (the wire format drops it), and net-of-schedule is what the
                // phone's Active Insulin shows. generatePrediction annotates
                // internally the same way.
                let activeInsulin = doses.annotated(with: algorithmSettings.basal).insulinOnBoard(from: date, to: date).last?.value ?? 0
                let activeCarbs = carbEntries.map(
                    to: prediction.effects.insulinCounteraction,
                    carbRatio: algorithmSettings.carbRatio,
                    insulinSensitivity: algorithmSettings.sensitivity
                ).dynamicCarbsOnBoard(from: date, to: date).last?.value ?? 0

                let algorithmDone = Date()
                self.log.default("predict timing: pulls %dms, fetches %dms, algorithm %dms, total %dms",
                                 Int(pullsDone.timeIntervalSince(tapped) * 1000),
                                 Int(fetchesDone.timeIntervalSince(pullsDone) * 1000),
                                 Int(algorithmDone.timeIntervalSince(fetchesDone) * 1000),
                                 Int(algorithmDone.timeIntervalSince(tapped) * 1000))

                let displayUnit = settings.glucoseUnit ?? .milligramsPerDeciliter
                let eventual = prediction.glucose.last?.quantity ?? manualBG
                let range = targetSchedule.quantityRange(at: date)

                // Reconciliation register: one compact line per cycle, joined offline against
                // the phone's Nightscout devicestatus.loop.predicted. Per-effect nets localize
                // any divergence to the responsible term (input skew vs algorithm skew).
                let mgdl = HKUnit.milligramsPerDeciliter
                func net(_ e: [GlucoseEffect]) -> String {
                    guard let f = e.first, let l = e.last else { return "0" }
                    return String(format: "%+.0f", l.quantity.doubleValue(for: mgdl) - f.quantity.doubleValue(for: mgdl))
                }
                let anchorBG = history.last.map { Int($0.quantity.doubleValue(for: mgdl)) } ?? -1
                let anchorAge = history.last.map { Int(date.timeIntervalSince($0.startDate)) } ?? -1
                let tempStr = recommendation.basalAdjustment.map { String(format: "%.2f U/hr·%.0fm", $0.unitsPerHour, $0.duration.minutes) } ?? "none"
                // Emit one line per GENUINE cycle (see lastLoggedPredictSignature): dedup on the
                // anchor identity + counts + temp, not the age/eventual/IOB/COB that drift each run.
                let predictSignature = "\(history.last.map { String(Int($0.startDate.timeIntervalSince1970)) } ?? "-1")|nBG=\(history.count)|nDose=\(doses.count)|nCarb=\(carbEntries.count)|temp=\(tempStr)"
                self.predictSignatureLock.lock()
                let shouldLogPredict = predictSignature != self.lastLoggedPredictSignature
                if shouldLogPredict { self.lastLoggedPredictSignature = predictSignature }
                self.predictSignatureLock.unlock()
                if shouldLogPredict {
                    fileLog("predict: anchor=\(anchorBG)mg/dL age=\(anchorAge)s nBG=\(history.count) nDose=\(doses.count) nCarb=\(carbEntries.count) eventual=\(Int(eventual.doubleValue(for: mgdl))) fx[ins=\(net(prediction.effects.insulin)) carb=\(net(prediction.effects.carbs)) mom=\(net(prediction.effects.momentum)) rc=\(net(prediction.effects.retrospectiveCorrection))] temp=\(tempStr) IOB=\(String(format: "%.2f", activeInsulin)) COB=\(String(format: "%.0f", activeCarbs))")
                }

                completion(.success(WatchPredictionOutput(
                    date: date,
                    anchorDate: history.last?.startDate ?? date,   // the reading this prediction is anchored on
                    unit: displayUnit,
                    currentBG: manualBG,
                    eventualBG: eventual,
                    predictedGlucose: prediction.glucose,
                    correctionRange: range,
                    recommendedTempBasal: recommendation.basalAdjustment,
                    scheduledBasalRate: basalSchedule.value(at: date),
                    sensitivity: sensitivitySchedule.quantity(at: date),
                    maxBasalRate: maxBasalRate,
                    activeInsulin: activeInsulin,
                    activeCarbs: activeCarbs,
                    usedPreLoanHistory: !grantHistory.isEmpty,
                    inputDoseCount: doses.count,
                    inputCarbCount: carbEntries.count,
                    recommendedBolus: recommendedBolus)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
