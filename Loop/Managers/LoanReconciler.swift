//
//  LoanReconciler.swift
//  Loop
//
//  Loan protocol v2 reconciliation (docs/DESIGN_LOAN_PROTOCOL_V2.md §5): the pure
//  logic that turns a drained watch record into phone-store writes, the R6 one-way
//  odometer valve, and the R22 fingerprints-only negative-remainder allocation.
//
//  Deliberately a value type with a static pure core so the R22 property tests
//  (never reduce confirmed, never below zero, exact-match preference, ambiguity
//  touches nothing) run against it without stores or timers.
//

import Foundation
import HealthKit
import LoopKit

enum LoanReconciler {

    /// One pod pulse — the R22 exact-match tolerance.
    static let pulseTolerance: Double = 0.05

    struct Input {
        /// Events not yet committed (seq > cursor), in seq order, tombstones applied.
        let events: [LoanEvent]
        /// The odometer audit pair; nil or !freshenSucceeded → audit is advisory-only.
        let odometer: LoanOdometerSnapshot?
        /// WS1: the FULL loan's event set for the odometer audit. With interim drains,
        /// `events` is only the uncommitted tail — auditing expected-insulin against
        /// the tail treats committed temps/suspends as schedule and mints phantom
        /// remainders (verify finding 2026-07-19, invariant-2 break). nil = use
        /// `events` (pre-WS1 behavior; single-offer drains and tests unchanged).
        /// Annulment candidates stay TAIL-only: committed records can't be unwritten.
        var auditEvents: [LoanEvent]? = nil
        /// Grant-frozen basal schedule in its captured timezone (R10/§8).
        let schedule: BasalRateSchedule?
        /// Loan window: grant/handover stamp → handedBackAt.
        let loanStart: Date
        let loanEnd: Date
    }

    struct Outcome: Equatable {
        /// Insulin records to write (per-event deterministic syncIdentifiers).
        var doses: [DoseEntry] = []
        /// Carb records to write (merge-not-replace happens at the store call).
        var carbs: [NewCarbEntry] = []
        /// Event IDs annulled by the R22 exact-size fingerprint.
        var annulledEventIDs: [UUID] = []
        /// A positive odometer remainder entered timed-late at hand-back (R6 valve).
        var positiveRemainderUnits: Double?
        /// A negative remainder no fingerprint explains — surfaced, never subtracted
        /// (the ruled layer-3 notice, R22).
        var residualShortfallUnits: Double?
    }

    // MARK: - The pure core

    static func reconcile(_ input: Input) -> Outcome {
        var outcome = Outcome()
        var events = input.events

        // The odometer audit (R6/R12): compare delivered against the journal +
        // schedule over the loan window. Only meaningful with a fresh odometer.
        if let odometer = input.odometer, odometer.freshenSucceeded {
            let delivered = odometer.deliveredLatest - odometer.deliveredAtStart
            // WS1: expected-insulin integrates the WHOLE loan's journal (committed
            // interim drains included), never just the uncommitted tail.
            let expected = expectedInsulin(events: input.auditEvents ?? events, schedule: input.schedule,
                                           from: input.loanStart, to: input.loanEnd)
            let remainder = delivered - expected

            if remainder > pulseTolerance {
                // Positive: the pod delivered more than recorded → enter IOB timed at
                // hand-back with zero decay elapsed (deliberately conservative).
                outcome.positiveRemainderUnits = remainder
            } else if remainder < -pulseTolerance {
                let shortfall = -remainder
                // R22 — fingerprints only:
                // 1. Exact-size annulment: one .assumed event whose units equal the
                //    shortfall within a pulse. Tie → the one closest to the failure
                //    (latest); identical arithmetic, only decay timing differs.
                if let match = events
                    .filter({ $0.isAssumed && abs(($0.record.insulinUnits(schedule: input.schedule) ?? -1) - shortfall) <= pulseTolerance })
                    .max(by: { $0.seq < $1.seq }) {
                    outcome.annulledEventIDs.append(match.id)
                    events.removeAll { $0.id == match.id }
                }
                // 2. Skipped-reduction window: an .assumed(.skippedReduction) marker
                //    whose window's scheduled insulin can absorb the shortfall — the
                //    C′ case: the reduction was real, record it retroactively by NOT
                //    writing the schedule-assumed insulin for that window. Modeled as
                //    annulling the marker's assumed-schedule contribution.
                else if let marker = events.first(where: { $0.provenance == .assumed(.skippedReduction) }),
                        let windowUnits = marker.record.scheduledInsulin(schedule: input.schedule),
                        shortfall <= windowUnits + pulseTolerance {
                    outcome.annulledEventIDs.append(marker.id)
                    events.removeAll { $0.id == marker.id }
                }
                // 3. Everything else touches NO record: the whole shortfall surfaces
                //    (IOB stays overstated — the safe direction).
                else {
                    outcome.residualShortfallUnits = shortfall
                }
            }
        }

        // Store writes for what remains: records are the truth (R12); confirmed and
        // surviving-assumed alike enter the record — an oversized record is entered in
        // FULL (max-exposure: understating IOB is the dangerous direction).
        for event in events {
            switch event.record.kind {
            case .bolus:
                if let units = event.record.amount {
                    outcome.doses.append(DoseEntry(
                        type: .bolus,
                        startDate: event.record.startDate,
                        endDate: event.record.endDate ?? event.record.startDate,
                        value: units, unit: .units,
                        syncIdentifier: syncIdentifier(for: event)))
                }
            case .tempBasal, .suspend, .boundaryTruncation:
                if let rate = event.record.unitsPerHour, let end = event.record.endDate {
                    outcome.doses.append(DoseEntry(
                        type: .tempBasal,
                        startDate: event.record.startDate,
                        endDate: end,
                        value: rate, unit: .unitsPerHour,
                        syncIdentifier: syncIdentifier(for: event)))
                }
            case .carb:
                if let grams = event.record.amount {
                    outcome.carbs.append(NewCarbEntry(
                        quantity: HKQuantity(unit: .gram(), doubleValue: grams),
                        startDate: event.record.startDate,
                        foodType: nil,
                        absorptionTime: event.record.absorptionTime))
                }
            case .resume, .plumbingCancel, .modeChange:
                break  // bookkeeping; the temp/suspend records carry the insulin truth
            }
        }

        return outcome
    }

    static func syncIdentifier(for event: LoanEvent) -> String {
        return "loanv2-\(event.id.uuidString)"
    }

    /// Journal-aware expected insulin over the loan window: journaled temps/suspends
    /// override the schedule for their spans; the schedule fills the gaps; boluses add.
    /// The grant-frozen schedule in its captured timezone is the only schedule source
    /// (R10/§8) — nil schedule means the basal expectation is unknowable, so only
    /// journaled insulin counts (the audit then skews conservative: a too-low
    /// expectation makes remainders MORE positive, which only ever adds IOB).
    static func expectedInsulin(events: [LoanEvent], schedule: BasalRateSchedule?, from start: Date, to end: Date) -> Double {
        guard end > start else { return 0 }

        var total: Double = 0

        // Boluses.
        for event in events where event.record.kind == .bolus {
            total += event.record.amount ?? 0
        }

        // Rate segments: journaled temp/suspend windows clipped to the loan window.
        struct Segment { let start: Date; let end: Date; let rate: Double }
        var segments: [Segment] = []
        for event in events {
            switch event.record.kind {
            case .tempBasal, .suspend, .boundaryTruncation:
                guard let rate = event.record.unitsPerHour,
                      let segEnd = event.record.endDate else { continue }
                let s = max(event.record.startDate, start)
                let e = min(segEnd, end)
                if e > s { segments.append(Segment(start: s, end: e, rate: rate)) }
            default:
                break
            }
        }
        // Later journal entries supersede earlier ones for overlapping spans (the pod
        // runs one program at a time); walk in start order, truncating predecessors.
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
            total += seg.rate * seg.end.timeIntervalSince(seg.start) / 3600.0
        }

        // Schedule fills the uncovered gaps.
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

    private static func scheduleInsulin(_ schedule: BasalRateSchedule, from: Date, to: Date) -> Double {
        return schedule.between(start: from, end: to).reduce(0) { partial, item in
            let s = max(item.startDate, from)
            let e = min(item.endDate, to)
            guard e > s else { return partial }
            return partial + item.value * e.timeIntervalSince(s) / 3600.0
        }
    }
}

// MARK: - Event helpers

private extension LoanEvent {
    var isAssumed: Bool {
        if case .assumed = provenance { return true }
        return false
    }
}

private extension LoanDoseRecord {
    /// The insulin this record claims, for exact-size matching (R22 fingerprint 1).
    func insulinUnits(schedule: BasalRateSchedule?) -> Double? {
        switch kind {
        case .bolus:
            return amount
        case .tempBasal, .suspend:
            guard let rate = unitsPerHour, let end = endDate else { return nil }
            return rate * end.timeIntervalSince(startDate) / 3600.0
        default:
            return nil
        }
    }

    /// The schedule insulin over this record's window (R22 fingerprint 2 — how much a
    /// real-but-unrecorded reduction could explain).
    func scheduledInsulin(schedule: BasalRateSchedule?) -> Double? {
        guard let schedule = schedule, let end = endDate else { return nil }
        return schedule.between(start: startDate, end: end).reduce(0) { partial, item in
            let s = max(item.startDate, startDate)
            let e = min(item.endDate, end)
            guard e > s else { return partial }
            return partial + item.value * e.timeIntervalSince(s) / 3600.0
        }
    }
}
