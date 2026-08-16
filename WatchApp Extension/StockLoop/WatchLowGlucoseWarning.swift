//
//  WatchLowGlucoseWarning.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore
import UserNotifications

/// The wrist half of the predicted-low warning. While the watch holds the pod the phone's books
/// are missing every dose the watch has enacted since the grant, so a phone-side warning computed
/// during a loan is wrong in BOTH directions — it over-warns when the watch has been low-temping
/// (the phone still believes scheduled basal was delivered) and under-warns after a wrist bolus.
/// The device driving the pod is the only one that can answer the question, so it owns the warning
/// for the duration of the loan and the phone stands down.
///
/// INFORMATION ONLY. Nothing in this file may influence dosing, and nothing here is reachable from
/// the dosing path: it consumes predictions that are built for it alone, and its single output is
/// a notification. The warning-only predictions are assembled by a method that exists solely for
/// this purpose; the loop's own `predictGlucose()` is untouched.
///
/// Ported from the phone's `determinePotentialWarningType()` (LoopDataManager) branch for branch,
/// including the message text, so a warning reads identically whichever device sends it. Two
/// deliberate divergences, both noted at their site: no `fatalError`, and the day/night offsets
/// arrive pre-resolved from the phone rather than being read from `UserDefaults` that do not
/// exist on this device.
enum WatchLowGlucoseWarning {

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

    /// The phone carried a fifth case, `considerEditingCarbsUpToAvoidUnnecessarySuspend` — an
    /// advisory for the inverse situation, where Loop predicts a low from declared carbs but
    /// observation says they are arriving faster than declared, so the low is not real. It was
    /// unreachable there and is deliberately absent here: it required P2 NOT to cross, and the
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

    /// The phone's `determinePotentialWarningType()`. Returns `.none` with a nil context whenever
    /// anything is missing or a precondition fails — never throws, never traps.
    static func evaluate(_ input: Inputs) -> (outcome: Outcome, context: Context?) {
        let s = input.settings

        guard s.enabled else { return (.none, nil) }

        // Night gate. The phone resolves the window against its own locale; the watch is handed
        // the resolved start/end minutes-of-day so both devices agree even across a time zone.
        let isNight = s.isNightTime(at: input.now)
        guard !isNight || s.nightWarningsEnabled else { return (.none, nil) }

        guard let suspendThresholdQuantity = input.suspendThreshold,
              let isf = input.insulinSensitivity,
              let cr = input.carbRatio
        else {
            SportLog.event("lowbg", "skip — missing suspend threshold / ISF / CR")
            return (.none, nil)
        }

        let csf = isf / cr
        guard csf > 0 else {
            SportLog.event("lowbg", "skip — CSF is zero or negative")
            return (.none, nil)
        }

        guard !input.predictionWithZeroTemp.isEmpty,
              !input.predictionWithObservedAbsorption.isEmpty,
              !input.predictionWithObservedAbsorptionAndZeroTemp.isEmpty
        else {
            SportLog.event("lowbg", "skip — a warning prediction is empty")
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
            SportLog.event("lowbg", "no warning — P2 never crosses the warning level")
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

        SportLog.event("lowbg", String(format: "level=%.0f · toLow=%.0fm · P1=%d P2=%d P3=%d · snooze=%d far=%d near=%d carbAge=%d · ratio=%.0f%%",
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

        // The 8-cell truth table, exactly as the phone reads it.
        switch (p1.didCrossThreshold, p2.didCrossThreshold, p3.didCrossThreshold) {
        case (true, true, true), (true, true, false):
            // Enough extra insulin aboard that the low lands regardless. This one fires even when
            // carbs are too recent — the phone privileges it the same way.
            return (.carbsDefinitelyNeeded, context)

        default:
            guard enoughTimeElapsed else {
                SportLog.event("lowbg", "no warning — carbs too recent")
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

    /// The phone's `createWarningMessages`, with its `fatalError` on `.none` replaced by nil.
    /// A trap here would take the watch down mid-loan while it is the only thing driving the pod,
    /// which is a far worse outcome than a missed warning.
    static func messages(for outcome: Outcome, context: Context) -> (title: String, body: String)? {
        let timeToLow = Int(round((context.observedAbsorption.timeToCrossThreshold ?? 0) / 60))
        let ratio = Int(round(context.absorptionRatio * 100))
        let rescue = context.rescueCarbMessageStr ?? "rescue carbs"

        switch outcome {
        case .none:
            return nil
        case .carbsDefinitelyNeeded:
            return (title: "Very likely low in \(timeToLow) mins",
                    body: "Take between \(rescue) carbs. Low will happen even if any old carbs fully absorb.")
        case .rescueCarbsLikelyNeeded:
            return (title: "Likely low in \(timeToLow) mins",
                    body: "Carbs absorbing at \(ratio)%. Consider taking between \(rescue) carbs, and editing.")
        case .mayAvoidRescueCarbsWithEditing:
            return (title: "Probable low in \(timeToLow) mins",
                    body: "Check and consider editing. Low temping may avoid need for rescue carbs. Carbs absorbing at \(ratio)% of expectation")
        }
    }

    // MARK: - Delivery

    static let notificationIdentifier = "com.loopkit.Loop.watch.lowBGWarning"

    /// Posts immediately. Replacing the pending request under the same identifier means a fresh
    /// warning supersedes a stale one rather than stacking on the wrist.
    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        content.threadIdentifier = notificationIdentifier
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: nil))
    }


    /// Hand-back, revoke, or any other end of the loan: the phone takes the warning back, so
    /// anything still on the wrist should go with it.
    static func clearDelivered() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
    }
}
