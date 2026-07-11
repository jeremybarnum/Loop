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

/// The phone's scheduled basal, Foundation-only (this package deliberately does
/// not link LoopKit). The watch builds one from LoopKit's BasalRateSchedule.
/// Semantics match LoopKit: rates repeat daily; an item applies from its offset
/// (seconds after local midnight in the schedule's time zone) until the next.
public struct PodLoanBasalSchedule: Equatable {
    public struct Item: Equatable {
        public let startOffset: TimeInterval   // seconds after midnight
        public let rate: Double                // U/hr
        public init(startOffset: TimeInterval, rate: Double) {
            self.startOffset = startOffset
            self.rate = rate
        }
    }

    public let items: [Item]                   // sorted by startOffset
    public let timeZoneSecondsFromGMT: Int

    public init(items: [Item], timeZoneSecondsFromGMT: Int) {
        self.items = items.sorted { $0.startOffset < $1.startOffset }
        self.timeZoneSecondsFromGMT = timeZoneSecondsFromGMT
    }

    /// The scheduled rate (U/hr) at a moment in time.
    public func rate(at date: Date) -> Double {
        guard !items.isEmpty else { return 0 }
        let local = date.timeIntervalSince1970 + Double(timeZoneSecondsFromGMT)
        let secondsOfDay = local.truncatingRemainder(dividingBy: 86400)
        // Last item whose offset ≤ now-of-day; before the first item (shouldn't
        // happen — schedules start at 0) fall back to the last item (wraps midnight).
        var current = items.last!
        for item in items {
            if item.startOffset <= secondsOfDay {
                current = item
            } else {
                break
            }
        }
        return current.rate
    }
}

extension PodLoanJournal {
    /// The spans during the loan when the watch commanded delivery AWAY from
    /// the schedule: a temp basal (actualRate = its rate, until superseded,
    /// suspended, or expired) or a suspend (actualRate = 0, until resumed).
    /// Time following the schedule is omitted — it nets to zero by definition.
    public func offScheduleSegments(until end: Date) -> [(start: Date, end: Date, actualRate: Double)] {
        enum DeliveryState {
            case following
            case temp(rate: Double, since: Date, expiry: Date)
            case suspended(since: Date)
        }

        var segments: [(start: Date, end: Date, actualRate: Double)] = []
        var state = DeliveryState.following

        func close(at date: Date) {
            switch state {
            case .following:
                break
            case .temp(let rate, let since, let expiry):
                let segmentEnd = min(date, expiry)   // expiry reverts to schedule (net 0)
                if segmentEnd > since {
                    segments.append((start: since, end: segmentEnd, actualRate: rate))
                }
            case .suspended(let since):
                if date > since {
                    segments.append((start: since, end: date, actualRate: 0))
                }
            }
        }

        for event in events.sorted(by: { $0.date < $1.date }) where event.date < end {
            switch event.kind {
            case .tempBasal(let rate, let duration):
                close(at: event.date)
                state = .temp(rate: rate, since: event.date, expiry: event.date.addingTimeInterval(duration))
            case .suspend:
                close(at: event.date)
                state = .suspended(since: event.date)
            case .resume, .cancelTempBasal, .handedBack:
                close(at: event.date)
                state = .following
            case .bolus, .tookOver:
                break
            }
        }
        close(at: end)
        return segments
    }

    /// NET basal insulin on board (U) at `date`: what the watch's basal
    /// commands delivered ABOVE (+) or BELOW (−) the schedule, decayed with the
    /// insulin curve. Scheduled basal nets to zero — the same semantics as
    /// LoopKit's netBasalUnits — so this is symmetric by construction: a high
    /// temp adds IOB, a suspend subtracts it.
    ///
    /// Continuous delivery is discretized into 5-minute slices, each decaying
    /// from its midpoint (LoopKit's InsulinMath uses the same 5-minute delta).
    public func netBasalIOB(at date: Date = Date(),
                            schedule: PodLoanBasalSchedule,
                            model: PodLoanInsulinModel = .rapidActingAdult) -> Double {
        let slice: TimeInterval = 5 * 60
        var net = 0.0
        for segment in offScheduleSegments(until: date) {
            var t = segment.start
            while t < segment.end {
                let sliceEnd = min(t.addingTimeInterval(slice), segment.end)
                let hours = sliceEnd.timeIntervalSince(t) / 3600
                let mid = t.addingTimeInterval(sliceEnd.timeIntervalSince(t) / 2)
                let deviation = (segment.actualRate - schedule.rate(at: mid)) * hours
                net += deviation * model.percentEffectRemaining(at: date.timeIntervalSince(mid))
                t = sliceEnd
            }
        }
        return net
    }

    /// RAW net basal insulin DELIVERED (U) above (+) or below (−) schedule over
    /// the session — the undecayed cumulative amount, for a "what I've done this
    /// session" display (as opposed to netBasalIOB, which decays for dosing/
    /// prediction). Same piecewise integration, no activity-curve factor: a temp
    /// above schedule is positive, a suspend/low temp is negative.
    public func netBasalDelivered(until date: Date = Date(),
                                  schedule: PodLoanBasalSchedule) -> Double {
        let slice: TimeInterval = 5 * 60
        var net = 0.0
        for segment in offScheduleSegments(until: date) {
            var t = segment.start
            while t < segment.end {
                let sliceEnd = min(t.addingTimeInterval(slice), segment.end)
                let hours = sliceEnd.timeIntervalSince(t) / 3600
                let mid = t.addingTimeInterval(sliceEnd.timeIntervalSince(t) / 2)
                net += (segment.actualRate - schedule.rate(at: mid)) * hours
                t = sliceEnd
            }
        }
        return net
    }

    /// TRUE net insulin on board: bolus decay + net basal vs schedule. This is
    /// the decayed figure used for prediction (predict()). Without a schedule it
    /// degrades to bolus-only. (The Show Mode status page shows the RAW session
    /// numbers — totalBolusUnits, netBasalDelivered, and their sum — not this.)
    public func iob(at date: Date = Date(),
                    schedule: PodLoanBasalSchedule?,
                    model: PodLoanInsulinModel = .rapidActingAdult) -> Double {
        let bolus = bolusIOB(at: date, model: model)
        guard let schedule = schedule else { return bolus }
        return bolus + netBasalIOB(at: date, schedule: schedule, model: model)
    }
}

/// A point-in-time projection from a single BG reading and the journal's IOB
/// (net when a schedule is supplied, bolus-only otherwise). Ships dark until
/// the watch has a live BG source (direct-G7).
public struct PodLoanPrediction: Equatable {
    public let iob: Double          // U
    public let eventualBG: Double   // same unit as the input BG
    public let asOf: Date

    public init(iob: Double, eventualBG: Double, asOf: Date) {
        self.iob = iob
        self.eventualBG = eventualBG
        self.asOf = asOf
    }
}

extension PodLoanJournal {
    /// v0 prediction: eventualBG = currentBG − IOB × ISF.
    ///
    /// With a schedule, IOB is the true net figure (bolus + basal deviation);
    /// without one it degrades to bolus-only. Deliberately excludes carbs (none
    /// logged on the watch) and momentum/retrospective correction (no CGM
    /// history on the watch): it is the "if nothing else happens, this insulin
    /// takes you here" number — classic correction arithmetic. Display-only;
    /// MUST NOT gate dosing.
    public func predict(currentBG: Double,
                        isfMgdlPerUnit: Double,
                        at date: Date = Date(),
                        model: PodLoanInsulinModel = .rapidActingAdult,
                        schedule: PodLoanBasalSchedule? = nil) -> PodLoanPrediction {
        let iob = self.iob(at: date, schedule: schedule, model: model)
        return PodLoanPrediction(iob: iob, eventualBG: currentBG - iob * isfMgdlPerUnit, asOf: date)
    }
}
