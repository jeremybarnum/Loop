//
//  LowGlucoseWarning.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore

/// The predicted-low warning's decision, shared by the phone and the watch: whichever device is
/// looping gathers its three warning predictions and its settings, asks this, and posts the result
/// its own way. One decision, tested once (WatchAppTests: LowGlucoseWarningTests,
/// ObservedAbsorptionWarningTests).
///
/// INFORMATION ONLY. Nothing here influences dosing: it reads predictions built for the warning
/// alone, and its only output is a notification.
///
/// The three predictions: P1 is Loop's own forecast with insulin suspended; P2 is the observed-
/// absorption forecast (Loop's forecast with the remaining carbs scaled by the absorption ratio);
/// P3 is P2 with insulin suspended. P2 crossing the warning level is what makes a warning possible;
/// which kind depends on P1 and P3.
enum LowGlucoseWarning {

    // MARK: - Types

    /// One prediction, reduced to the handful of numbers the decision and the message need.
    struct PredictionMetrics: Equatable {
        let minimumGlucoseValue: PredictedGlucoseValue?
        let glucoseValueAtAbsorptionTime: PredictedGlucoseValue?
        let timeToMinimumGlucose: TimeInterval?
        let timeToCrossThreshold: TimeInterval?
        let velocityAtThresholdCrossing: Double?

        var didCrossThreshold: Bool { timeToCrossThreshold != nil }

        func minimumGlucoseDouble(for unit: HKUnit) -> Double? {
            minimumGlucoseValue?.quantity.doubleValue(for: unit)
        }
    }

    /// Everything the message builder needs, computed once.
    struct Context {
        let standardWithSuspend: PredictionMetrics                  // P1
        let observedAbsorption: PredictionMetrics                   // P2
        let observedAbsorptionWithSuspend: PredictionMetrics        // P3
        let rescueCarbMessageStr: String?
        let absorptionRatio: Double
        let displayUnit: HKUnit
    }

    /// There was once a fifth case, `considerEditingCarbsUpToAvoidUnnecessarySuspend` — an
    /// advisory for the inverse situation, where Loop predicts a low from declared carbs but
    /// observation says they are arriving faster than declared, so the low is not real. It was
    /// unreachable and was removed (2026-08-15): it required P2 NOT to cross, and the
    /// P2-crossing guard returns before the table is ever consulted. Resurrecting it would have
    /// needed its own timing anchor (P1's crossing, since there is no P2 crossing) and its own
    /// snooze, or it would eat a real low warning. Ruled not worth it — it is the only class that
    /// is not about a low.
    enum Outcome: Equatable {
        case none
        case carbsDefinitelyNeeded
        case rescueCarbsLikelyNeeded
        case mayAvoidRescueCarbsWithEditing
    }

    /// The three predictions plus the state the decision reads. Passed in rather than reached for,
    /// so the whole evaluation is a pure function of its inputs and can be table-tested.
    struct Inputs {
        let predictionWithZeroTemp: [PredictedGlucoseValue]                      // P1
        let predictionWithObservedAbsorption: [PredictedGlucoseValue]            // P2
        let predictionWithObservedAbsorptionAndZeroTemp: [PredictedGlucoseValue] // P3
        let absorptionRatio: Double
        let suspendThreshold: HKQuantity?
        let displayUnit: HKUnit
        let insulinSensitivity: Double?
        let carbRatio: Double?
        let correctionTarget: Double?
        let mostRecentCarbEntryDate: Date?
        let lastNotificationTime: Date?
        let now: Date
        let settings: LoanLowBGWarningSettings
    }

    // MARK: - Decision

    /// Returns `.none` with a nil context whenever anything is missing or a precondition fails —
    /// never throws, never traps. `log` receives one line per decision, for the device's own log.
    static func evaluate(_ input: Inputs, log: (String) -> Void = { _ in }) -> (outcome: Outcome, context: Context?) {
        let s = input.settings

        guard s.enabled else { return (.none, nil) }

        // Night gate, on minutes of the day carried in the settings, so both devices agree.
        let isNight = s.isNightTime(at: input.now)
        guard !isNight || s.nightWarningsEnabled else { return (.none, nil) }

        guard let suspendThresholdQuantity = input.suspendThreshold,
              let isf = input.insulinSensitivity,
              let cr = input.carbRatio
        else {
            log("skip — missing suspend threshold / ISF / CR")
            return (.none, nil)
        }

        let csf = isf / cr
        guard csf > 0 else {
            log("skip — CSF is zero or negative")
            return (.none, nil)
        }

        guard !input.predictionWithZeroTemp.isEmpty,
              !input.predictionWithObservedAbsorption.isEmpty,
              !input.predictionWithObservedAbsorptionAndZeroTemp.isEmpty
        else {
            log("skip — a warning prediction is empty")
            return (.none, nil)
        }

        let unit = input.displayUnit
        let offset = isNight ? s.nightWarningOffset : s.dayWarningOffset
        let warningLevelValue = suspendThresholdQuantity.doubleValue(for: unit) - offset
        let warningLevel = HKQuantity(unit: unit, doubleValue: warningLevelValue)

        let p1 = analyze(input.predictionWithZeroTemp, threshold: warningLevel, now: input.now)
        let p2 = analyze(input.predictionWithObservedAbsorption, threshold: warningLevel, now: input.now)
        let p3 = analyze(input.predictionWithObservedAbsorptionAndZeroTemp, threshold: warningLevel, now: input.now)

        let rescue = rescueCarbs(from: p3,
                                 suspendThreshold: suspendThresholdQuantity,
                                 displayUnit: unit,
                                 csf: csf,
                                 correctionTarget: input.correctionTarget ?? 100.0)

        let rescueValues = [rescue.neutralizeVelocity, rescue.treatNadir, rescue.treatAtAbsorptionTime].compactMap { $0 }
        let minRescue = max(rescueValues.min() ?? 0, 0)
        let maxRescue = max(rescueValues.max() ?? 0, 0)
        let rescueStr: String = minRescue.rounded() == maxRescue.rounded()
            ? String(format: "%.0f", minRescue)
            : String(format: "%.0f and %.0f", minRescue, maxRescue)

        // P2 is the filter: if the observed-absorption prediction never crosses, there is nothing
        // to warn about regardless of what the other two do.
        guard let timeToObservedLow = p2.timeToCrossThreshold else {
            log("no warning — P2 never crosses the warning level")
            return (.none, nil)
        }

        let intervalExceeded: Bool = {
            guard let last = input.lastNotificationTime else { return true }
            return input.now.timeIntervalSince(last) > s.warningSnooze
        }()
        let farEnough = timeToObservedLow > s.dontWarnIfSooner
        let notTooFar = timeToObservedLow < s.dontWarnIfLater
        let enoughTimeElapsed: Bool = {
            guard let carbDate = input.mostRecentCarbEntryDate else { return true }
            return input.now.timeIntervalSince(carbDate) > s.delayAfterCarbEntry
        }()

        log(String(format: "level=%.0f · toLow=%.0fm · P1=%d P2=%d P3=%d · snooze=%d far=%d near=%d carbAge=%d · ratio=%.0f%%",
                                       warningLevelValue, timeToObservedLow / 60,
                                       p1.didCrossThreshold ? 1 : 0, p2.didCrossThreshold ? 1 : 0, p3.didCrossThreshold ? 1 : 0,
                                       intervalExceeded ? 1 : 0, farEnough ? 1 : 0, notTooFar ? 1 : 0, enoughTimeElapsed ? 1 : 0,
                                       input.absorptionRatio * 100))

        guard intervalExceeded, farEnough, notTooFar else { return (.none, nil) }

        let context = Context(standardWithSuspend: p1,
                              observedAbsorption: p2,
                              observedAbsorptionWithSuspend: p3,
                              rescueCarbMessageStr: rescueStr,
                              absorptionRatio: input.absorptionRatio,
                              displayUnit: unit)

        // The 8-cell truth table.
        switch (p1.didCrossThreshold, p2.didCrossThreshold, p3.didCrossThreshold) {
        case (true, true, true), (true, true, false):
            // Enough extra insulin aboard that the low lands regardless. This one fires even when
            // carbs are too recent.
            return (.carbsDefinitelyNeeded, context)

        default:
            guard enoughTimeElapsed else {
                log("no warning — carbs too recent")
                return (.none, nil)
            }

            switch (p1.didCrossThreshold, p2.didCrossThreshold, p3.didCrossThreshold) {
            case (false, true, true):
                return (.rescueCarbsLikelyNeeded, context)
            case (false, true, false):
                return (.mayAvoidRescueCarbsWithEditing, context)
            default:
                // Everything left requires P2 not to cross, and the guard above already returned
                // for that. Unreachable in practice; silence is the honest answer if it is ever
                // reached, since every remaining message is about a low that P2 does not predict.
                return (.none, nil)
            }
        }
    }

    // MARK: - Analysis

    static func analyze(_ prediction: [PredictedGlucoseValue], threshold: HKQuantity, now: Date) -> PredictionMetrics {
        let firstLow = prediction.first { $0.quantity < threshold }
        let absorptionTime = ObservedAbsorptionSettings.assumedRescueCarbAbsorptionTimeMinutes
        let atAbsorption = prediction.first { $0.startDate >= now.addingTimeInterval(absorptionTime * 60) }

        var velocityAtCrossing: Double?
        if let idx = prediction.firstIndex(where: { $0.quantity < threshold }), idx + 1 < prediction.count {
            let before = prediction[idx]
            let after = prediction[idx + 1]
            let diff = after.quantity.doubleValue(for: .milligramsPerDeciliter) - before.quantity.doubleValue(for: .milligramsPerDeciliter)
            velocityAtCrossing = diff / 5.0
        }

        let minimum = prediction.min(by: { $0.quantity < $1.quantity })

        return PredictionMetrics(
            minimumGlucoseValue: minimum,
            glucoseValueAtAbsorptionTime: atAbsorption,
            timeToMinimumGlucose: minimum?.startDate.timeIntervalSince(now),
            timeToCrossThreshold: firstLow?.startDate.timeIntervalSince(now),
            velocityAtThresholdCrossing: velocityAtCrossing
        )
    }

    static func rescueCarbs(from p3: PredictionMetrics,
                            suspendThreshold: HKQuantity,
                            displayUnit: HKUnit,
                            csf: Double,
                            correctionTarget: Double) -> (neutralizeVelocity: Double?, treatNadir: Double?, treatAtAbsorptionTime: Double?) {
        let none: (Double?, Double?, Double?) = (nil, nil, nil)

        guard let minQty = p3.minimumGlucoseValue?.quantity,
              minQty < suspendThreshold,
              let timeToMin = p3.timeToMinimumGlucose,
              let velocityAtCrossing = p3.velocityAtThresholdCrossing
        else { return none }

        let minValue = minQty.doubleValue(for: displayUnit)
        let assumedAbsorption = ObservedAbsorptionSettings.assumedRescueCarbAbsorptionTimeMinutes
        let flooredTime = max(ObservedAbsorptionSettings.flooredTimeForRescueCarbs, timeToMin / 60.0)

        guard assumedAbsorption > 0 else { return none }
        let absorptionFraction = min(1.0, flooredTime / assumedAbsorption)
        guard absorptionFraction > 0 else { return none }

        let thresholdValue = suspendThreshold.doubleValue(for: displayUnit)
        let treatNadir = (thresholdValue - minValue) / csf / absorptionFraction
        let treatAtAbsorptionTime = (correctionTarget - (p3.glucoseValueAtAbsorptionTime?.quantity.doubleValue(for: displayUnit) ?? 0)) / csf

        let carbAbsorptionStartDelay = CarbMath.defaultEffectDelay / 60
        let postLowTimeToTarget = 20.0
        let postLowTargetRiseRate = (correctionTarget - thresholdValue) / postLowTimeToTarget
        let neutralizeVelocity = (-velocityAtCrossing + postLowTargetRiseRate) * (assumedAbsorption - carbAbsorptionStartDelay) / csf

        return (neutralizeVelocity: neutralizeVelocity, treatNadir: treatNadir, treatAtAbsorptionTime: treatAtAbsorptionTime)
    }

    // MARK: - Messages

    /// The notification's title and body, and the one-line note the phone posts to Nightscout.
    /// nil for `.none` rather than a trap: on the watch a trap would take down the device that is
    /// driving the pod, a far worse outcome than a missed warning.
    static func messages(for outcome: Outcome, context: Context) -> (title: String, body: String, nightscoutNote: String)? {
        let timeToLow = Int(round((context.observedAbsorption.timeToCrossThreshold ?? 0) / 60))
        let ratio = Int(round(context.absorptionRatio * 100))
        let rescue = context.rescueCarbMessageStr ?? "rescue carbs"
        let minBG = Int(round(context.observedAbsorptionWithSuspend.minimumGlucoseDouble(for: context.displayUnit) ?? 0))
        let timeToMinBG = Int(round((context.observedAbsorption.timeToMinimumGlucose ?? 0) / 60))
        func note(_ confidence: Int) -> String {
            "Conf \(confidence). Time to low: \(timeToLow). Min BG: \(minBG). Time to min: \(timeToMinBG). Ratio:(\(ratio)%. Rec \(rescue)g."
        }

        switch outcome {
        case .none:
            return nil
        case .carbsDefinitelyNeeded:
            return (title: "Very likely low in \(timeToLow) mins",
                    body: "Take between \(rescue) carbs. Low will happen even if any old carbs fully absorb.",
                    nightscoutNote: note(1))
        case .rescueCarbsLikelyNeeded:
            return (title: "Likely low in \(timeToLow) mins",
                    body: "Carbs absorbing at \(ratio)%. Consider taking between \(rescue) carbs, and editing.",
                    nightscoutNote: note(2))
        case .mayAvoidRescueCarbsWithEditing:
            return (title: "Probable low in \(timeToLow) mins",
                    body: "Check and consider editing. Low temping may avoid need for rescue carbs. Carbs absorbing at \(ratio)% of expectation",
                    nightscoutNote: note(3))
        }
    }
}
