//
//  LowGlucoseWarning.swift
//  LoopCore
//
//  The predicted-low warning's decision, shared by the phone and the watch: whichever device is
//  looping builds its ingredients from its own algorithm run, asks this, and issues the result.
//  Ported from the production line's `LowGlucoseWarning` (2026-10-21); the decision and the
//  wording are unchanged. All glucose values are mg/dL.
//
//  INFORMATION ONLY. Nothing here influences dosing: it reads forecasts built for the warning
//  alone, and its only output is an alert.
//
//  The three forecasts: P1 is Loop's own forecast with insulin suspended; P2 is the observed-
//  absorption forecast (Loop's forecast with the remaining carbs scaled by the absorption ratio);
//  P3 is P2 with insulin suspended. P2 crossing the warning level is what makes a warning possible;
//  which kind depends on P1 and P3.
//

import Foundation
import LoopAlgorithm

public enum LowGlucoseWarning {

    // MARK: - Types

    /// One forecast, reduced to the handful of numbers the decision and the message need.
    public struct PredictionMetrics: Equatable {
        public let minimumGlucose: Double?
        public let glucoseAtAbsorptionTime: Double?
        public let timeToMinimumGlucose: TimeInterval?
        public let timeToCrossThreshold: TimeInterval?
        public let velocityAtThresholdCrossing: Double?

        public var didCrossThreshold: Bool { timeToCrossThreshold != nil }

        public init(minimumGlucose: Double?, glucoseAtAbsorptionTime: Double?, timeToMinimumGlucose: TimeInterval?,
                    timeToCrossThreshold: TimeInterval?, velocityAtThresholdCrossing: Double?) {
            self.minimumGlucose = minimumGlucose
            self.glucoseAtAbsorptionTime = glucoseAtAbsorptionTime
            self.timeToMinimumGlucose = timeToMinimumGlucose
            self.timeToCrossThreshold = timeToCrossThreshold
            self.velocityAtThresholdCrossing = velocityAtThresholdCrossing
        }
    }

    /// Everything the message builder needs, computed once.
    public struct Context: Equatable {
        public let standardWithSuspend: PredictionMetrics                  // P1
        public let observedAbsorption: PredictionMetrics                   // P2
        public let observedAbsorptionWithSuspend: PredictionMetrics        // P3
        public let rescueCarbMessageStr: String?
        public let absorptionRatio: Double

        public init(standardWithSuspend: PredictionMetrics, observedAbsorption: PredictionMetrics,
                    observedAbsorptionWithSuspend: PredictionMetrics, rescueCarbMessageStr: String?, absorptionRatio: Double) {
            self.standardWithSuspend = standardWithSuspend
            self.observedAbsorption = observedAbsorption
            self.observedAbsorptionWithSuspend = observedAbsorptionWithSuspend
            self.rescueCarbMessageStr = rescueCarbMessageStr
            self.absorptionRatio = absorptionRatio
        }
    }

    public enum Outcome: Equatable {
        case none
        case carbsDefinitelyNeeded
        case rescueCarbsLikelyNeeded
        case mayAvoidRescueCarbsWithEditing
    }

    /// The three forecasts plus the state the decision reads. Passed in rather than reached for, so
    /// the whole evaluation is a pure function of its inputs and can be table-tested.
    public struct Inputs {
        public let predictionWithZeroTemp: [PredictedGlucoseValue]                      // P1
        public let predictionWithObservedAbsorption: [PredictedGlucoseValue]            // P2
        public let predictionWithObservedAbsorptionAndZeroTemp: [PredictedGlucoseValue] // P3
        public let absorptionRatio: Double
        public let suspendThreshold: Double?
        public let insulinSensitivity: Double?
        public let carbRatio: Double?
        public let correctionTarget: Double?
        public let mostRecentCarbEntryDate: Date?
        public let now: Date
        public let settings: LowBGWarningSettings

        public init(predictionWithZeroTemp: [PredictedGlucoseValue], predictionWithObservedAbsorption: [PredictedGlucoseValue],
                    predictionWithObservedAbsorptionAndZeroTemp: [PredictedGlucoseValue], absorptionRatio: Double,
                    suspendThreshold: Double?, insulinSensitivity: Double?, carbRatio: Double?, correctionTarget: Double?,
                    mostRecentCarbEntryDate: Date?, now: Date, settings: LowBGWarningSettings) {
            self.predictionWithZeroTemp = predictionWithZeroTemp
            self.predictionWithObservedAbsorption = predictionWithObservedAbsorption
            self.predictionWithObservedAbsorptionAndZeroTemp = predictionWithObservedAbsorptionAndZeroTemp
            self.absorptionRatio = absorptionRatio
            self.suspendThreshold = suspendThreshold
            self.insulinSensitivity = insulinSensitivity
            self.carbRatio = carbRatio
            self.correctionTarget = correctionTarget
            self.mostRecentCarbEntryDate = mostRecentCarbEntryDate
            self.now = now
            self.settings = settings
        }
    }

    /// The decision, and whether a low is still predicted: P2 crosses the warning level before
    /// "don't warn if farther than". A warning already showing is withdrawn only when that is false;
    /// the gates that merely delay a warning (the snooze, the delay after carbs) do not withdraw one.
    public struct Decision: Equatable {
        public let outcome: Outcome
        public let context: Context?
        public let lowStillPredicted: Bool
    }

    // MARK: - Decision

    /// `.none` with a nil context whenever anything is missing or a precondition fails — never
    /// throws, never traps. `log` receives one line per decision, for the device's own log.
    public static func evaluate(_ input: Inputs, log: (String) -> Void = { _ in }) -> Decision {
        let s = input.settings
        let nothing = Decision(outcome: .none, context: nil, lowStillPredicted: false)

        guard s.enabled else { return nothing }

        // Night gate, on minutes of the day carried in the settings, so both devices agree.
        let isNight = s.isNightTime(at: input.now)
        guard !isNight || s.nightWarningsEnabled else { return nothing }

        guard let suspendThreshold = input.suspendThreshold,
              let isf = input.insulinSensitivity,
              let cr = input.carbRatio
        else {
            log("skip — missing suspend threshold / ISF / CR")
            return nothing
        }

        let csf = isf / cr
        guard csf > 0 else {
            log("skip — CSF is zero or negative")
            return nothing
        }

        guard !input.predictionWithZeroTemp.isEmpty,
              !input.predictionWithObservedAbsorption.isEmpty,
              !input.predictionWithObservedAbsorptionAndZeroTemp.isEmpty
        else {
            log("skip — a warning prediction is empty")
            return nothing
        }

        let offset = isNight ? s.nightWarningOffset : s.dayWarningOffset
        let warningLevel = suspendThreshold - offset

        let p1 = analyze(input.predictionWithZeroTemp, threshold: warningLevel, now: input.now)
        let p2 = analyze(input.predictionWithObservedAbsorption, threshold: warningLevel, now: input.now)
        let p3 = analyze(input.predictionWithObservedAbsorptionAndZeroTemp, threshold: warningLevel, now: input.now)

        let rescue = rescueCarbs(from: p3, suspendThreshold: suspendThreshold, csf: csf,
                                 correctionTarget: input.correctionTarget ?? 100.0)

        let rescueValues = [rescue.neutralizeVelocity, rescue.treatNadir, rescue.treatAtAbsorptionTime].compactMap { $0 }
        let minRescue = max(rescueValues.min() ?? 0, 0)
        let maxRescue = max(rescueValues.max() ?? 0, 0)
        let rescueStr: String = minRescue.rounded() == maxRescue.rounded()
            ? String(format: "%.0f", minRescue)
            : String(format: "%.0f and %.0f", minRescue, maxRescue)

        // P2 is the filter: if the observed-absorption forecast never crosses, there is nothing to
        // warn about regardless of what the other two do.
        guard let timeToObservedLow = p2.timeToCrossThreshold else {
            log("no warning — P2 never crosses the warning level")
            return nothing
        }

        let intervalExceeded: Bool = {
            guard let last = s.lastNotificationTime else { return true }
            return input.now.timeIntervalSince(last) > s.warningSnooze
        }()
        let farEnough = timeToObservedLow > s.dontWarnIfSooner
        let notTooFar = timeToObservedLow < s.dontWarnIfLater
        let enoughTimeElapsed: Bool = {
            guard let carbDate = input.mostRecentCarbEntryDate else { return true }
            return input.now.timeIntervalSince(carbDate) > s.delayAfterCarbEntry
        }()

        log(String(format: "level=%.0f · toLow=%.0fm · P1=%d P2=%d P3=%d · snooze=%d far=%d near=%d carbAge=%d · ratio=%.0f%%",
                   warningLevel, timeToObservedLow / 60,
                   p1.didCrossThreshold ? 1 : 0, p2.didCrossThreshold ? 1 : 0, p3.didCrossThreshold ? 1 : 0,
                   intervalExceeded ? 1 : 0, farEnough ? 1 : 0, notTooFar ? 1 : 0, enoughTimeElapsed ? 1 : 0,
                   input.absorptionRatio * 100))

        let stillPredicted = notTooFar
        let held = Decision(outcome: .none, context: nil, lowStillPredicted: stillPredicted)
        guard intervalExceeded, farEnough, notTooFar else { return held }

        let context = Context(standardWithSuspend: p1,
                              observedAbsorption: p2,
                              observedAbsorptionWithSuspend: p3,
                              rescueCarbMessageStr: rescueStr,
                              absorptionRatio: input.absorptionRatio)

        // The 8-cell truth table.
        switch (p1.didCrossThreshold, p2.didCrossThreshold, p3.didCrossThreshold) {
        case (true, true, true), (true, true, false):
            // Enough extra insulin aboard that the low lands regardless. This one fires even when
            // carbs are too recent.
            return Decision(outcome: .carbsDefinitelyNeeded, context: context, lowStillPredicted: true)

        default:
            guard enoughTimeElapsed else {
                log("no warning — carbs too recent")
                return held
            }

            switch (p1.didCrossThreshold, p2.didCrossThreshold, p3.didCrossThreshold) {
            case (false, true, true):
                return Decision(outcome: .rescueCarbsLikelyNeeded, context: context, lowStillPredicted: true)
            case (false, true, false):
                return Decision(outcome: .mayAvoidRescueCarbsWithEditing, context: context, lowStillPredicted: true)
            default:
                // Everything left requires P2 not to cross, and the guard above already returned for
                // that. Unreachable in practice; silence is the honest answer if it is ever reached.
                return held
            }
        }
    }

    // MARK: - Compression-low guard

    /// A sensor artifact drops glucose fast enough to trip every threshold at once, and warning on it
    /// trains the user to ignore the warning: skip when the newest reading fell 10 mg/dL or more from
    /// the previous one, if the two are consecutive (6 minutes or less apart). A feature, kept as is
    /// (ruled 2026-10-21); a real fast fall is caught by the actual-low alarms.
    public static func isCompressionLow(_ glucose: [GlucoseValue]) -> Bool {
        guard glucose.count >= 2 else { return false }
        let last = glucose[glucose.count - 1], previous = glucose[glucose.count - 2]
        guard last.startDate.timeIntervalSince(previous.startDate) <= 6 * 60 else { return false }
        let drop = previous.quantity.doubleValue(for: .milligramsPerDeciliter) - last.quantity.doubleValue(for: .milligramsPerDeciliter)
        return drop >= 10
    }

    // MARK: - Analysis

    /// Assumed absorption time of rescue carbs, minutes.
    static let assumedRescueCarbAbsorptionTimeMinutes = 45.0
    /// The rescue estimate credits only what absorbs before the low; floored so it cannot explode.
    static let flooredTimeForRescueCarbs = 15.0

    static func analyze(_ prediction: [PredictedGlucoseValue], threshold: Double, now: Date) -> PredictionMetrics {
        func mgdl(_ value: PredictedGlucoseValue) -> Double { value.quantity.doubleValue(for: .milligramsPerDeciliter) }
        let firstLow = prediction.first { mgdl($0) < threshold }
        let atAbsorption = prediction.first { $0.startDate >= now.addingTimeInterval(assumedRescueCarbAbsorptionTimeMinutes * 60) }

        var velocityAtCrossing: Double?
        if let idx = prediction.firstIndex(where: { mgdl($0) < threshold }), idx + 1 < prediction.count {
            velocityAtCrossing = (mgdl(prediction[idx + 1]) - mgdl(prediction[idx])) / 5.0
        }

        let minimum = prediction.min(by: { mgdl($0) < mgdl($1) })

        return PredictionMetrics(
            minimumGlucose: minimum.map(mgdl),
            glucoseAtAbsorptionTime: atAbsorption.map(mgdl),
            timeToMinimumGlucose: minimum?.startDate.timeIntervalSince(now),
            timeToCrossThreshold: firstLow?.startDate.timeIntervalSince(now),
            velocityAtThresholdCrossing: velocityAtCrossing
        )
    }

    static func rescueCarbs(from p3: PredictionMetrics, suspendThreshold: Double, csf: Double,
                            correctionTarget: Double) -> (neutralizeVelocity: Double?, treatNadir: Double?, treatAtAbsorptionTime: Double?) {
        let none: (Double?, Double?, Double?) = (nil, nil, nil)

        guard let minValue = p3.minimumGlucose,
              minValue < suspendThreshold,
              let timeToMin = p3.timeToMinimumGlucose,
              let velocityAtCrossing = p3.velocityAtThresholdCrossing
        else { return none }

        let assumedAbsorption = assumedRescueCarbAbsorptionTimeMinutes
        let flooredTime = max(flooredTimeForRescueCarbs, timeToMin / 60.0)

        guard assumedAbsorption > 0 else { return none }
        let absorptionFraction = min(1.0, flooredTime / assumedAbsorption)
        guard absorptionFraction > 0 else { return none }

        let treatNadir = (suspendThreshold - minValue) / csf / absorptionFraction
        let treatAtAbsorptionTime = (correctionTarget - (p3.glucoseAtAbsorptionTime ?? 0)) / csf

        let carbAbsorptionStartDelay = CarbMath.defaultEffectDelay / 60
        let postLowTimeToTarget = 20.0
        let postLowTargetRiseRate = (correctionTarget - suspendThreshold) / postLowTimeToTarget
        let neutralizeVelocity = (-velocityAtCrossing + postLowTargetRiseRate) * (assumedAbsorption - carbAbsorptionStartDelay) / csf

        return (neutralizeVelocity: neutralizeVelocity, treatNadir: treatNadir, treatAtAbsorptionTime: treatAtAbsorptionTime)
    }

    // MARK: - Messages

    /// The alert's title and body (her wording), and the one-line note for Nightscout. nil for
    /// `.none` rather than a trap: on the watch a trap would take down the device driving the pod.
    public static func messages(for outcome: Outcome, context: Context) -> (title: String, body: String, nightscoutNote: String)? {
        let timeToLow = Int(round((context.observedAbsorption.timeToCrossThreshold ?? 0) / 60))
        let ratio = Int(round(context.absorptionRatio * 100))
        let rescue = context.rescueCarbMessageStr ?? "rescue carbs"
        let minBG = Int(round(context.observedAbsorptionWithSuspend.minimumGlucose ?? 0))
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
