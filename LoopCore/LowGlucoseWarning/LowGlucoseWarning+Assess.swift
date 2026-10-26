//
//  LowGlucoseWarning+Assess.swift
//  LoopCore
//
//  From a LoopAlgorithm run to a decision: the warning's absorption ratio, its zero-temp effect,
//  its three forecasts and its verdict, built here once for both devices from the run that ends
//  every cycle (the display run, which counts doses still in flight). Each device passes its own
//  run, its own pump-data date and the scheduled basal ahead; nothing else is read.
//

import Foundation
import LoopAlgorithm

extension LowGlucoseWarning {

    public struct Assessment {
        /// nil when the warning did not evaluate at all this time (compression low, stale data):
        /// a warning already showing stays as it is.
        public let decision: Decision?
        /// Carbs actually arriving ÷ carbs the entries, as entered, said would arrive (1.0 when there is nothing to judge).
        public let absorptionRatio: Double
        /// What the ratio adds to the carb effect: the remaining carbs scaled, same timing.
        public let observedAbsorptionEffect: [GlucoseEffect]
        /// P1, P2, P3 — empty when the data is too old to forecast from.
        public let predictionWithZeroTemp: [PredictedGlucoseValue]
        public let predictionWithObservedAbsorption: [PredictedGlucoseValue]
        public let predictionWithObservedAbsorptionAndZeroTemp: [PredictedGlucoseValue]

        public init(decision: Decision?, absorptionRatio: Double, observedAbsorptionEffect: [GlucoseEffect],
                    predictionWithZeroTemp: [PredictedGlucoseValue], predictionWithObservedAbsorption: [PredictedGlucoseValue],
                    predictionWithObservedAbsorptionAndZeroTemp: [PredictedGlucoseValue]) {
            self.decision = decision
            self.absorptionRatio = absorptionRatio
            self.observedAbsorptionEffect = observedAbsorptionEffect
            self.predictionWithZeroTemp = predictionWithZeroTemp
            self.predictionWithObservedAbsorption = predictionWithObservedAbsorption
            self.predictionWithObservedAbsorptionAndZeroTemp = predictionWithObservedAbsorptionAndZeroTemp
        }
    }

    /// - Parameters:
    ///   - input, output: the device's display run (`updateDisplayState`), as it ends a cycle.
    ///   - lastPumpDataDate: when this device last received pump data.
    ///   - scheduledBasal: the basal schedule from now to the end of insulin action (the zero temp
    ///     withholds it), as the settings provider gives it.
    public static func assess<Input: AlgorithmInput>(
        input: Input,
        output: AlgorithmOutput<Input.CarbType>,
        lastPumpDataDate: Date?,
        scheduledBasal: [AbsoluteScheduleValue<Double>],
        now: Date,
        settings: LowBGWarningSettings,
        log: (String) -> Void = { _ in }
    ) -> Assessment {
        func skipped(_ reason: String) -> Assessment {
            log("skip — \(reason)")
            return Assessment(decision: nil, absorptionRatio: 1.0, observedAbsorptionEffect: [],
                              predictionWithZeroTemp: [], predictionWithObservedAbsorption: [],
                              predictionWithObservedAbsorptionAndZeroTemp: [])
        }

        guard settings.enabled else {
            return Assessment(decision: Decision(outcome: .none, context: nil, lowStillPredicted: false), absorptionRatio: 1.0,
                              observedAbsorptionEffect: [], predictionWithZeroTemp: [], predictionWithObservedAbsorption: [],
                              predictionWithObservedAbsorptionAndZeroTemp: [])
        }
        guard let glucose = input.glucoseHistory.last else { return skipped("no glucose") }
        if isCompressionLow(input.glucoseHistory) { return skipped("compression low (≥10 mg/dL one-reading drop)") }

        // Loop's own recency rules for forecasting: never warn from old or future glucose, or from
        // pump data too old to know what insulin is aboard.
        let glucoseAge = now.timeIntervalSince(glucose.startDate)
        guard glucoseAge <= LoopAlgorithm.inputDataRecencyInterval else {
            return skipped(String(format: "glucose is %.0f min old", glucoseAge / 60))
        }
        guard -glucoseAge <= LoopCoreConstants.futureGlucoseDataInterval else { return skipped("glucose is in the future") }
        guard let pumpDate = lastPumpDataDate, now.timeIntervalSince(pumpDate) <= LoopAlgorithm.inputDataRecencyInterval else {
            return skipped("pump data is too old")
        }

        let effects = output.effects
        let mgdl = LoopUnit.milligramsPerDeciliter

        // The ratio and the effect it adds, from the entries on their entered absorption times.
        var ratio = 1.0
        var observedAbsorptionEffect: [GlucoseEffect] = []
        let cutoff = now.addingTimeInterval(-ObservedAbsorption.recentAndFutureCarbExclusionWindow)
        let judged = input.carbEntries.filter { $0.startDate <= cutoff }
        if !judged.isEmpty, !effects.carbs.isEmpty {
            /// The carb effect of `entries`, computed from `readings` exactly as the algorithm computes its
            /// own, except that each entry is expected on its entered absorption time.
            ///
            /// NOT A SETTING. The 1.0 is not a value to tune: it is the multiplier that leaves the entered
            /// time as entered, so the algorithm's code is reused rather than copied (ruled 2026-10-21).
            func enteredTimeEffect(_ readings: [GlucoseEffectVelocity]) -> [GlucoseEffect] {
                judged.map(to: readings, carbRatio: input.carbRatio, insulinSensitivity: input.sensitivity,
                           initialAbsorptionTimeOverrun: 1.0)
                    .dynamicGlucoseEffects(from: now.addingTimeInterval(-CarbMath.maximumAbsorptionTimeInterval),
                                           carbRatios: input.carbRatio, insulinSensitivities: input.sensitivity,
                                           absorptionModel: input.carbAbsorptionModel.model)
            }
            if let measurement = ObservedAbsorption.measureRatio(insulinCounteractionEffects: effects.insulinCounteraction,
                                                                 carbEffect: enteredTimeEffect) {
                ratio = measurement.ratio
                log(String(format: "absorption ratio %.3f: observed %.1f vs expected %.1f mg/dL over %.1f of %.0f min",
                           measurement.ratio, measurement.observedEffect, measurement.expectedEffect,
                           measurement.covered / 60, measurement.window.duration / 60))
            }
            observedAbsorptionEffect = ObservedAbsorption.effect(absorptionRatio: ratio,
                                                                 carbEffects: enteredTimeEffect(effects.insulinCounteraction))
        }

        // The zero temp: the scheduled basal withheld from now to the end of insulin action.
        let insulinModel = input.recommendationInsulinModel
        let suspendEnd = now.addingTimeInterval(insulinModel.effectDuration)
        let suspendDoses: [BasalRelativeDose] = scheduledBasal.compactMap { item in
            let start = max(item.startDate, now), end = min(item.endDate, suspendEnd)
            guard end > start else { return nil }
            return BasalRelativeDose(type: .basal(scheduledRate: item.value), startDate: start, endDate: end,
                                     volume: -item.value * end.timeIntervalSince(start) / 3600, insulinModel: insulinModel)
        }
        let suspendEffect = suspendDoses.glucoseEffects(insulinSensitivityHistory: input.sensitivity, from: now, to: suspendEnd)

        // The three forecasts: Loop's own forecast (carb, insulin, retrospective correction, momentum)
        // plus the extra effects, run to the end of insulin action.
        func predict(_ extra: [[GlucoseEffect]]) -> [PredictedGlucoseValue] {
            var prediction = LoopMath.predictGlucose(startingAt: glucose, momentum: effects.momentum,
                                                     effects: [effects.carbs, effects.insulin, effects.retrospectiveCorrection] + extra)
            let finalDate = glucose.startDate.addingTimeInterval(insulinModel.effectDuration)
            if let last = prediction.last, last.startDate < finalDate {
                prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
            }
            return prediction
        }
        let p1 = predict([suspendEffect])
        let p2 = predict([observedAbsorptionEffect])
        let p3 = predict([observedAbsorptionEffect, suspendEffect])

        let decision = evaluate(Inputs(
            predictionWithZeroTemp: p1,
            predictionWithObservedAbsorption: p2,
            predictionWithObservedAbsorptionAndZeroTemp: p3,
            absorptionRatio: ratio,
            suspendThreshold: input.suspendThreshold?.doubleValue(for: mgdl),
            insulinSensitivity: input.sensitivity.closestPrior(to: now)?.value.doubleValue(for: mgdl),
            carbRatio: input.carbRatio.closestPrior(to: now)?.value,
            correctionTarget: input.target.closestPrior(to: now.addingTimeInterval(30 * 60))?.value.lowerBound.doubleValue(for: mgdl),
            mostRecentCarbEntryDate: input.carbEntries.map(\.startDate).max(),
            now: now,
            settings: settings), log: log)

        return Assessment(decision: decision, absorptionRatio: ratio, observedAbsorptionEffect: observedAbsorptionEffect,
                          predictionWithZeroTemp: p1, predictionWithObservedAbsorption: p2,
                          predictionWithObservedAbsorptionAndZeroTemp: p3)
    }
}
