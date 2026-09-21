//
//  LoanReconciler.swift
//  Loop
//
//  Loan protocol v2 reconciliation (docs/DESIGN_LOAN_PROTOCOL_V2.md §5): the pure
//  logic that turns a drained watch record into phone-store writes, the one-way
//  odometer valve, and the fingerprints-only negative-remainder allocation.
//
//  Deliberately a value type with a static pure core so the property tests
//  (never reduce confirmed, never below zero, exact-match preference, ambiguity
//  touches nothing) run against it without stores or timers.
//

import Foundation
import LoopCore
import LoopAlgorithm
import HealthKit
import LoopKit

enum LoanReconciler {
    struct Input {
        let events: [LoanEvent]

        let schedule: BasalRateSchedule?

        let loanStart: Date
        let loanEnd: Date

        var isFinalHandback: Bool = true
    }

    struct DeletedCarb: Equatable {
        let syncIdentifier: String?
        let startDate: Date
        let grams: Double
    }

    struct IdentifiedCarb: Equatable {
        let eventID: UUID
        let entry: NewCarbEntry
    }

    struct Outcome: Equatable {
        var doses: [DoseEntry] = []

        var openEventID: UUID? = nil

        var carbs: [IdentifiedCarb] = []

        var deletedCarbs: [DeletedCarb] = []

        var overrideChange: OverrideChange?
    }

    enum OverrideChange: Equatable {
        case set(TemporaryScheduleOverride)
        case cleared
    }

    static func reconcile(_ input: Input) -> Outcome {
        var outcome = Outcome()
        var events = input.events

        let openEventID: UUID? = input.isFinalHandback ? nil : events
            .filter { e in
                switch e.record.kind {
                case .tempBasal, .suspend:
                    return (e.record.endDate ?? e.record.startDate) > input.loanEnd
                default:
                    return false
                }
            }
            .max(by: { $0.record.startDate < $1.record.startDate })?.id
        outcome.openEventID = openEventID

        for event in events {
            switch event.record.kind {
            case .bolus:
                if let units = event.record.amount {
                    outcome.doses.append(DoseEntry(
                        type: .bolus,
                        startDate: event.record.startDate,
                        endDate: event.record.endDate ?? event.record.startDate,
                        value: units, unit: .units,
                        decisionId: nil,
                        syncIdentifier: syncIdentifier(for: event)))
                }
            case .tempBasal, .suspend:

                if event.id == openEventID { continue }
                if let rate = event.record.unitsPerHour, let end = event.record.endDate {
                    let clampedEnd = input.isFinalHandback ? Swift.min(end, input.loanEnd) : end
                    outcome.doses.append(DoseEntry(
                        type: .tempBasal,
                        startDate: event.record.startDate,
                        endDate: clampedEnd,
                        value: rate, unit: .unitsPerHour,
                        decisionId: nil,
                        syncIdentifier: syncIdentifier(for: event)))
                }
            case .carb:
                if let grams = event.record.amount {
                    outcome.carbs.append(IdentifiedCarb(
                        eventID: event.id,
                        entry: NewCarbEntry(
                            quantity: LoopQuantity(unit: .gram, doubleValue: grams),
                            startDate: event.record.startDate,
                            foodType: nil,
                            absorptionTime: event.record.absorptionTime)))
                }
            case .carbDeleted:

                if let grams = event.record.amount {
                    let start = event.record.startDate
                    let before = outcome.carbs.count
                    outcome.carbs.removeAll { $0.entry.startDate == start && $0.entry.quantity.doubleValue(for: .gram) == grams }
                    guard outcome.carbs.count == before else { break }
                    outcome.deletedCarbs.append(DeletedCarb(
                        syncIdentifier: event.record.syncIdentifier,
                        startDate: start,
                        grams: grams))
                }
            case .overrideChange:

                if event.record.overrideChangeIsClear {
                    outcome.overrideChange = .cleared
                } else if let override = event.record.overrideChangePayload {
                    outcome.overrideChange = .set(override)
                }

                break
            }
        }

        return outcome
    }

    static func syncIdentifier(for event: LoanEvent) -> String {
        return event.record.syncIdentifier ?? "loanv2-\(event.id.uuidString)"
    }

    static func expectedInsulin(events: [LoanEvent], schedule: BasalRateSchedule?, from start: Date, to end: Date,
                                includingBolusesAtEnd: Bool = true) -> Double {
        guard end > start else { return 0 }

        var total: Double = 0

        for event in events where event.record.kind == .bolus {
            guard event.record.startDate >= start else { continue }
            guard includingBolusesAtEnd ? event.record.startDate <= end
                                        : event.record.startDate < end else { continue }
            total += event.record.amount ?? 0
        }

        struct Segment { let start: Date; let end: Date; let rate: Double }
        var segments: [Segment] = []
        for event in events {
            switch event.record.kind {
            case .tempBasal, .suspend:
                guard let rate = event.record.unitsPerHour,
                      let segEnd = event.record.endDate else { continue }
                let s = max(event.record.startDate, start)
                let e = min(segEnd, end)

                if e >= s { segments.append(Segment(start: s, end: e, rate: rate)) }
            default:
                break
            }
        }

        segments.sort { $0.start < $1.start }
        var resolved: [Segment] = []
        for seg in segments {
            while let last = resolved.last, last.end > seg.start {
                let trimmed = Segment(start: last.start, end: seg.start, rate: last.rate)
                resolved.removeLast()
                if trimmed.end > trimmed.start { resolved.append(trimmed) }
            }
            resolved.append(seg)
        }

        for seg in resolved {
            total += pulsedInsulin(rate: seg.rate, seconds: seg.end.timeIntervalSince(seg.start))
        }

        if let schedule = schedule {
            var cursor = start
            for seg in resolved {
                if seg.start > cursor {
                    total += scheduleInsulin(schedule, from: cursor, to: seg.start)
                }
                cursor = max(cursor, seg.end)
            }
            if end > cursor {
                total += scheduleInsulin(schedule, from: cursor, to: end)
            }
        }

        return total
    }

    private static func pulsedInsulin(rate: Double, seconds: TimeInterval) -> Double {
        guard rate > 0, seconds > 0 else { return 0 }
        let pulseInterval = 3600.0 * podPulseSize / rate
        let pulses = (seconds / pulseInterval).rounded(.down)
        return pulses * podPulseSize
    }

    private static let podPulseSize: Double = 0.05

    private static func scheduleInsulin(_ schedule: BasalRateSchedule, from: Date, to: Date) -> Double {
        return schedule.between(start: from, end: to).reduce(0) { partial, item in
            let s = max(item.startDate, from)
            let e = min(item.endDate, to)
            guard e > s else { return partial }
            return partial + pulsedInsulin(rate: item.value, seconds: e.timeIntervalSince(s))
        }
    }
}
