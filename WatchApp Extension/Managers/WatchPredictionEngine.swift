//
//  WatchPredictionEngine.swift
//  WatchApp Extension
//
//  Runs the real Loop algorithm (LoopAlgorithm.generatePrediction + DoseMath)
//  on the watch against a manually entered BG: eventual BG, the correction
//  range it was judged against, and a temp-basal recommendation.
//
//  Effects config: insulin + carbs only. Momentum needs a dense recent BG
//  series and retrospective correction needs 30 min of fresh counteraction
//  data — neither exists when the anchor is a single typed-in value, so they
//  stay off rather than run on stale inputs.
//
//  DISPLAY/RECOMMEND ONLY in this stage: nothing here enacts a dose.
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
            return NSLocalizedString("No Show Mode session is active.", comment: "Prediction error: no loan journal")
        }
    }
}

struct WatchPredictionOutput {
    let date: Date
    let unit: HKUnit
    let currentBG: HKQuantity
    let eventualBG: HKQuantity
    let predictedGlucose: [PredictedGlucoseValue]
    let correctionRange: ClosedRange<HKQuantity>
    /// nil means the scheduled basal already fits the prediction.
    let recommendedTempBasal: TempBasalRecommendation?
    let scheduledBasalRate: Double
    /// false: the grant carried no pre-loan history — prediction sees
    /// loan-session insulin only and understates IOB from earlier boluses.
    let usedPreLoanHistory: Bool
    let inputDoseCount: Int
    let inputCarbCount: Int
}

final class WatchPredictionEngine {
    private let loopManager: LoopDataManager
    private let coordinator: WatchPodLoanCoordinator
    private let log = OSLog(category: "WatchPredictionEngine")

    /// Dose history pulled from the phone when the grant carried none (sim
    /// demo, or a real grant whose payload was absent). Cached per engine.
    private var pulledDoseHistoryData: Data?

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

    /// Predict from a manually entered BG and recommend a temp basal. If core
    /// settings are missing, first pull them from the phone over sendMessage
    /// (the push path loses them across a watch reinstall and is unreliable on
    /// simulators), then run. Every branch logs — silence is not an option here.
    @MainActor
    func predict(manualBG: HKQuantity, at date: Date = Date(), completion: @escaping (Swift.Result<WatchPredictionOutput, Error>) -> Void) {
        let settings = loopManager.settings
        log.default("predict: settings state %{public}@", settingsState(settings))

        // Freshen the watch-local carb/glucose stores opportunistically; replies
        // land async, so they enrich this run if fast and the next run if not.
        // (The carb-list screen normally triggers this, but Show Mode repurposes
        // its button — without this line, carbs never backfill mid-session.)
        loopManager.requestCarbBackfill()
        loopManager.requestGlucoseBackfillIfNecessary()

        guard settingsIncomplete(settings) else {
            pullDoseHistoryIfNeededThenRun(manualBG: manualBG, at: date, completion: completion)
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
                self.pullDoseHistoryIfNeededThenRun(manualBG: manualBG, at: date, completion: completion)
            }
        }, errorHandler: { [weak self] error in
            self?.log.error("predict: settings pull failed: %{public}@", String(describing: error))
            Task { @MainActor in
                self?.pullDoseHistoryIfNeededThenRun(manualBG: manualBG, at: date, completion: completion)
            }
        })
    }

    /// Pre-loan insulin history: grant payload first; otherwise pull once from
    /// the phone. Missing history skews IOB low, so it's worth a round-trip.
    @MainActor
    private func pullDoseHistoryIfNeededThenRun(manualBG: HKQuantity, at date: Date, completion: @escaping (Swift.Result<WatchPredictionOutput, Error>) -> Void) {
        guard coordinator.grantDoseHistoryData == nil, pulledDoseHistoryData == nil else {
            return run(manualBG: manualBG, at: date, completion: completion)
        }

        let session = WCSession.default
        guard session.activationState == .activated else {
            log.default("predict: no dose history and WC inactive — running without")
            return run(manualBG: manualBG, at: date, completion: completion)
        }

        log.default("predict: no grant dose history — pulling from phone")
        session.sendMessage(["name": PodLoanDoseHistoryRequest.name], replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                if let data = reply["dh"] as? Data {
                    self.log.default("predict: dose history pull succeeded (%d bytes)", data.count)
                    self.pulledDoseHistoryData = data
                } else {
                    self.log.error("predict: dose history pull returned no data")
                }
                self.run(manualBG: manualBG, at: date, completion: completion)
            }
        }, errorHandler: { [weak self] error in
            self?.log.error("predict: dose history pull failed: %{public}@", String(describing: error))
            Task { @MainActor in
                self?.run(manualBG: manualBG, at: date, completion: completion)
            }
        })
    }

    @MainActor
    private func run(manualBG: HKQuantity, at date: Date, completion: @escaping (Swift.Result<WatchPredictionOutput, Error>) -> Void) {
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
        let model: ExponentialInsulinModelPreset = settings.defaultRapidActingModel ?? .rapidActingAdult

        // Doses: pre-loan history from the grant + the loan journal, with the
        // active temp carried at full programmed extent (parity with the
        // phone's live path, which sees the mutable temp's future remainder).
        let journal = coordinator.journalForPrediction
        let grantHistory = (coordinator.grantDoseHistoryData ?? pulledDoseHistoryData)
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
            algorithmEffectsOptions: [.insulin, .carbs],
            maximumBasalRatePerHour: maxBasalRate,
            maximumBolus: settings.maximumBolus,
            suspendThreshold: settings.suspendThreshold)

        // Histories from the watch-local stores, then run.
        let group = DispatchGroup()
        var glucoseHistory: [StoredGlucoseSample] = []
        var carbEntries: [StoredCarbEntry] = []

        group.enter()
        loopManager.glucoseStore.getGlucoseSamples(start: date.addingTimeInterval(-.hours(10)), end: date) { result in
            if case .success(let samples) = result {
                glucoseHistory = samples
            }
            group.leave()
        }

        group.enter()
        loopManager.carbStore.getCarbEntries(start: date.addingTimeInterval(-.hours(10)), end: date) { result in
            if case .success(let entries) = result {
                carbEntries = entries
            }
            group.leave()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            // The manual entry is the anchor: strictly the newest sample.
            let manualSample = StoredGlucoseSample(startDate: date, quantity: manualBG, wasUserEntered: true)
            let history = glucoseHistory
                .filter { $0.startDate < date }
                .sorted { $0.startDate < $1.startDate } + [manualSample]

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

                let displayUnit = settings.glucoseUnit ?? .milligramsPerDeciliter
                let eventual = prediction.glucose.last?.quantity ?? manualBG
                let range = targetSchedule.quantityRange(at: date)

                completion(.success(WatchPredictionOutput(
                    date: date,
                    unit: displayUnit,
                    currentBG: manualBG,
                    eventualBG: eventual,
                    predictedGlucose: prediction.glucose,
                    correctionRange: range,
                    recommendedTempBasal: recommendation.basalAdjustment,
                    scheduledBasalRate: basalSchedule.value(at: date),
                    usedPreLoanHistory: !grantHistory.isEmpty,
                    inputDoseCount: doses.count,
                    inputCarbCount: carbEntries.count)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
