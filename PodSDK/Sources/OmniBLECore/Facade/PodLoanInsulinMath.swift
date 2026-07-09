//
//  PodLoanInsulinMath.swift
//  OmniBLECore
//
//  NEW for the WatchPod project — bolus-only insulin-on-board for the loan
//  journal, so the watch can show a live "Bolus IOB" during Show Mode computed
//  from the doses the watch itself delivered.
//
//  The model is an EXACT port of LoopKit's ExponentialInsulinModel
//  (LoopKit/InsulinKit/ExponentialInsulinModel.swift, percentEffectRemaining) —
//  ported rather than imported because this package deliberately does not link
//  LoopKit (see Package.swift's OmniBLEShim note). The algebra is pinned by
//  test vectors in PodLoanInsulinMathTests computed independently from the
//  LoopKit formula; if LoopKit's model ever changes, re-pin.
//
//  BOLUS-ONLY by design: net-basal IOB requires the scheduled basal rate, which
//  the watch does not hold during a loan. Temp basals, suspends and resumes are
//  deliberately excluded — the UI must label this "Bolus IOB", never plain
//  "Active Insulin" (which reads as the phone's full net figure).
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// Exponential insulin activity model (LoopKit-equivalent), Foundation-only.
public struct PodLoanInsulinModel: Equatable {
    /// Duration of insulin activity, excluding the absorption delay.
    public let actionDuration: TimeInterval
    public let peakActivityTime: TimeInterval
    public let delay: TimeInterval

    private let tau: Double
    private let a: Double
    private let s: Double

    public init(actionDuration: TimeInterval, peakActivityTime: TimeInterval, delay: TimeInterval = 600) {
        self.actionDuration = actionDuration
        self.peakActivityTime = peakActivityTime
        self.delay = delay
        self.tau = peakActivityTime * (1 - peakActivityTime / actionDuration) / (1 - 2 * peakActivityTime / actionDuration)
        self.a = 2 * tau / actionDuration
        self.s = 1 / (1 - a + (1 + a) * exp(-actionDuration / tau))
    }

    /// Fraction of a dose still active `time` after delivery (1 → 0).
    public func percentEffectRemaining(at time: TimeInterval) -> Double {
        let t = time - delay
        guard t > 0 else { return 1 }
        guard t < actionDuration else { return 0 }
        return 1 - s * (1 - a) * ((pow(t, 2) / (tau * actionDuration * (1 - a)) - t / tau - 1) * exp(-t / tau) + 1)
    }

    // Presets matching LoopKit's ExponentialInsulinModelPreset. The watch picks
    // one from the loan grant's insulin-type raw value (see the wire contract in
    // PodLoanGrantUserInfo): 3=fiasp, 4=lyumjev, 5=afrezza, else rapidActingAdult.
    // The user's adult-vs-child rapid-acting preference is not available on the
    // watch; the adult curve decays slower, so the fallback errs toward showing
    // MORE remaining insulin (conservative for a "is my correction done?" glance).
    public static let rapidActingAdult = PodLoanInsulinModel(actionDuration: .minutes(360), peakActivityTime: .minutes(75))
    public static let rapidActingChild = PodLoanInsulinModel(actionDuration: .minutes(360), peakActivityTime: .minutes(65))
    public static let fiasp = PodLoanInsulinModel(actionDuration: .minutes(360), peakActivityTime: .minutes(55))
    public static let lyumjev = PodLoanInsulinModel(actionDuration: .minutes(360), peakActivityTime: .minutes(55))
    public static let afrezza = PodLoanInsulinModel(actionDuration: .minutes(300), peakActivityTime: .minutes(29))

    /// The model for a loan grant's insulin-type raw value (LoopKit
    /// InsulinType.rawValue: 0=novolog 1=humalog 2=apidra 3=fiasp 4=lyumjev
    /// 5=afrezza). Unknown/nil → rapidActingAdult, matching LoopKit's own
    /// PresetInsulinModelProvider fallback.
    public static func forInsulinTypeRaw(_ raw: Int?) -> PodLoanInsulinModel {
        switch raw {
        case 3: return .fiasp
        case 4: return .lyumjev
        case 5: return .afrezza
        default: return .rapidActingAdult
        }
    }
}

extension PodLoanJournal {
    /// BOLUS-ONLY insulin on board (U) at `date`, from this journal's bolus
    /// events at their recorded (command-success) times.
    public func bolusIOB(at date: Date = Date(), model: PodLoanInsulinModel = .rapidActingAdult) -> Double {
        events.reduce(0) { total, event in
            guard case .bolus(let units) = event.kind else { return total }
            return total + units * model.percentEffectRemaining(at: date.timeIntervalSince(event.date))
        }
    }
}

/// A point-in-time projection from a single BG reading and the journal's
/// bolus IOB. Ships dark until the watch has a live BG source (direct-G7).
public struct PodLoanPrediction: Equatable {
    public let bolusIOB: Double     // U
    public let eventualBG: Double   // same unit as the input BG
    public let asOf: Date

    public init(bolusIOB: Double, eventualBG: Double, asOf: Date) {
        self.bolusIOB = bolusIOB
        self.eventualBG = eventualBG
        self.asOf = asOf
    }
}

extension PodLoanJournal {
    /// v0 prediction: eventualBG = currentBG − bolusIOB × ISF.
    ///
    /// Deliberately excludes carbs (none logged on the watch), basal deltas (no
    /// schedule on the watch), and momentum/retrospective correction (no CGM
    /// history on the watch): it is the "if nothing else happens, the boluses
    /// take you here" number — classic correction arithmetic. Display-only;
    /// MUST NOT gate dosing.
    public func predict(currentBG: Double,
                        isfMgdlPerUnit: Double,
                        at date: Date = Date(),
                        model: PodLoanInsulinModel = .rapidActingAdult) -> PodLoanPrediction {
        let iob = bolusIOB(at: date, model: model)
        return PodLoanPrediction(bolusIOB: iob, eventualBG: currentBG - iob * isfMgdlPerUnit, asOf: date)
    }
}
