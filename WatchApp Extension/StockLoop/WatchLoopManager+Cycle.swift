//
//  WatchLoopManager+Cycle.swift
//  WatchApp Extension
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import G7SensorKit
import WatchConnectivity
import os.log

extension WatchLoopManager {

    func checkPumpDataAndLoop() {
        guard let pumpManager = pumpManager else {
            awaitedPumpLock.lock()
            if awaitingPumpManager { readingArrivedWithoutPump = true }
            awaitedPumpLock.unlock()

            if !loggedIdleNoPump {
                loggedIdleNoPump = true
                SportLog.event("loop", "idle — no pod on the watch; cycles paused until the next grant (glucose still ingesting)")
            }
            return
        }
        loggedIdleNoPump = false

        pumpManager.ensureCurrentPumpData { _ in self.loop() }
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

            if case .missingDataError(let what)? = error {
                SportLog.event("loop", "NOT DOSING — prediction missing \(what)")
            }

            let decided = self.recommendedAutomaticDose?.recommendation
            self.lastRecommendation = decided
            if error == nil, self._closedLoopEnabled {
                error = self.enactRecommendedAutomaticDose()
            } else if error == nil {
                self.log.default("Advisory (open loop) — computed but not enacting.")
            }

            self.lastLoopError = error

            let enactVerdict: String
            if !self._closedLoopEnabled { enactVerdict = "none(open-loop)" }
            else if decided?.basalAdjustment == nil && decided != nil { enactVerdict = "none(no-change)" }
            else if decided == nil { enactVerdict = "none(nothing-decided)" }
            else if case .enactFailed(let why)? = error { enactVerdict = "FAILED \(why)" }
            else if error != nil { enactVerdict = "not-attempted(\(error!))" }
            else { enactVerdict = "ok" }

            let watchdogRefreshed = (error == nil && self.pumpManager != nil)
            if watchdogRefreshed { LoopStallWatchdog.refresh(); self.onCycleLanded?() }
            let sinceCompleted = self.lastLoopCompleted.map { Int(self.now().timeIntervalSince($0)) }

            let computeSucceeded: Bool = {
                switch error {
                case .none: return true
                case .enactFailed, .pumpManagerUnconnected: return true
                default: return false
                }
            }()

            SportLog.event("loop", String(format: "CYCLE VERDICT computed=%@ enact=%@ watchdog=%@ lastCompletedAge=%@",
                                          computeSucceeded ? "ok" : "FAILED",
                                          enactVerdict,
                                          watchdogRefreshed ? "refreshed" : "HELD",
                                          sinceCompleted.map { "\($0)s" } ?? "never") + " · " + batteryTag())

            if let error {
                self.log.error("Loop ended with error: %{public}@", String(describing: error))

                if case .missingDataError = error {} else {
                    SportLog.event("loop", "cycle ended with error: \(error)")
                }
            } else {
                self.lastLoopCompleted = self.now()
                self.log.default("Loop ended (duration %.1fs)", self.now().timeIntervalSince(startDate))
                let bg = self.glucoseStore.latestGlucose.map { String(format: "%.0f", $0.quantity.doubleValue(for: .milligramsPerDeciliter)) } ?? "—"

                let rec = decided.map { String(format: "%.2f U/h", $0.basalAdjustment.unitsPerHour) } ?? "none"
                SportLog.event("loop", "cycle OK — BG \(bg), IOB \(self.activeInsulin.map { String(format: "%.2f", $0) } ?? "—"), temp \(rec)")
                self.logPredictionBreakdown(decided: decided)
            }

            self.publishHUDContext()
        }
    }

    func refreshPredictionForGlance() {
        dataAccessQueue.async {
            var error: WatchLoopError? = nil
            if error == nil {
                error = self.updatePredictedGlucoseAndRecommendedDose()
            }
            if case .missingDataError(let what)? = error {
                SportLog.event("loop", "takeover prediction refresh — not yet (missing \(what))")
            } else if error == nil {
                self.lastRecommendation = self.recommendedAutomaticDose?.recommendation
                SportLog.event("loop", "takeover prediction refresh — IOB \(self.activeInsulin.map { String(format: "%.2f U", $0) } ?? "—"), eventual + carbs refreshed (no enact)")
                self.logPredictionBreakdown(decided: self.recommendedAutomaticDose?.recommendation)
            }
            self.publishHUDContext()
        }
    }

    func runBlocking<T>(_ work: @escaping () async throws -> T) throws -> T {
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

    func roundedBasalRate(_ unitsPerHour: Double) -> Double {
        guard let supported = pumpManager?.supportedBasalRates, !supported.isEmpty else { return unitsPerHour }
        return supported.enumerated().min(by: {
            abs($0.element - unitsPerHour) < abs($1.element - unitsPerHour)
        })?.element ?? unitsPerHour
    }

    func fetchAlgorithmInput(at baseTime: Date, recommendationType: DoseRecommendationType) async throws -> StoredDataAlgorithmInput {
        let dosesInputHistory = CarbMath.maximumAbsorptionTimeInterval + InsulinMath.defaultInsulinActivityDuration
        var dosesStart = baseTime.addingTimeInterval(-dosesInputHistory)

        let pumpDataAge = baseTime.timeIntervalSince(doseStore.lastAddedPumpData)
        guard pumpDataAge <= LoopAlgorithm.inputDataRecencyInterval else {
            throw WatchLoopError.missingDataError(String(format: "pumpDataTooOld (%.0f s since the last pump report)", pumpDataAge))
        }

        let doses: [DoseEntry] = try await doseStore.getNormalizedDoseEntries(start: dosesStart, end: baseTime)
            .compactMap { $0.trimmed(to: baseTime) }
        dosesStart = min(dosesStart, doses.map { $0.startDate }.min() ?? dosesStart)
        let dosesEnd = max(baseTime, doses.map { $0.endDate }.max() ?? baseTime)

        let rawBasal = try await settingsProvider.getBasalHistory(startDate: dosesStart, endDate: dosesEnd)
        guard !rawBasal.isEmpty else { throw WatchLoopError.configurationError("basalRateSchedule") }

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

    func updatePredictedGlucoseAndRecommendedDose() -> WatchLoopError? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        let startDate = now()

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
                recommendedAutomaticDose = nil
                SportLog.event("dosemath", String(format: "no command needed — pod already at %.2f U/hr", basal.unitsPerHour))
                return nil
            }
            automatic.basalAdjustment = adjusted

            recommendedAutomaticDose = (recommendation: automatic, date: startDate)
            let derivation = algorithmSummary(input: input, output: output, enacting: adjusted)
            SportLog.event("dosemath", derivation)
            return nil
        }
    }

    func updateDisplayState() {
        dataAccessQueue.async {
            self.publishHUDContext()
            self.refreshGlanceData()
        }
    }
}
