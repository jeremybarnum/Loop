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
import HealthKit
import LoopKit

enum LoanReconciler {

    /// One pod pulse — the exact-match tolerance.
    static let pulseTolerance: Double = 0.05

    struct Input {
        /// Events not yet committed (seq > cursor), in seq order, tombstones applied.
        let events: [LoanEvent]
        /// The odometer audit pair; nil or !freshenSucceeded → audit is advisory-only.
        let odometer: LoanOdometerSnapshot?
        /// The FULL loan's event set for the odometer audit. With interim drains,
        /// `events` is only the uncommitted tail — auditing expected-insulin against
        /// the tail treats committed temps/suspends as schedule and mints phantom
        /// remainders. nil = use `events` (single-offer drains and tests unchanged).
        /// Annulment candidates stay TAIL-only: committed records can't be unwritten.
        var auditEvents: [LoanEvent]? = nil
        /// Grant-frozen basal schedule in its captured timezone
        /// (docs/DESIGN_LOAN_PROTOCOL_V2.md §8).
        let schedule: BasalRateSchedule?
        /// Loan window: grant/handover stamp → handedBackAt.
        let loanStart: Date
        let loanEnd: Date
        /// False for an interim drain (`released == false`: watch still dosing). On a
        /// final hand-back / forced reclaim (true) delivery has stopped, so every dose is
        /// finalized: immutable and clamped to `loanEnd`. On an interim drain the pod keeps
        /// running, so the still-open temp (`outcome.openEventID`) is SKIPPED here — it
        /// re-drains and is written on the final drain. Finalizing it early would orphan
        /// its post-drain delivery and UNDER-count IOB, the dangerous direction.
        /// See docs/DESIGN_LOAN_ADDPUMPEVENTS.md.
        var isFinalHandback: Bool = true
    }

    /// One wrist-side carb deletion, carried to the phone's store.
    struct DeletedCarb: Equatable {
        let syncIdentifier: String?
        let startDate: Date
        let grams: Double
    }

    /// Which stored carb a wrist deletion names — identity first, natural key second.
    ///
    /// TWO PASSES, not one predicate. The obvious one-predicate form asks each entry in turn
    /// "same syncIdentifier, or failing that same (startDate, grams)?", and that quietly means
    /// something different: an entry carrying a DIFFERENT syncIdentifier answers "no" outright
    /// and never gets its natural key considered. So the moment the wrist's identity matches
    /// nothing in the store, every identified entry is excluded and the fallback the design
    /// promises can only ever inspect entries whose syncIdentifier happens to be nil. A carb
    /// whose identity moved out from under the wrist — re-minted by an edit, resynced from
    /// HealthKit under a new identity — is then a hard MISS despite matching on time and grams
    /// exactly, and a missed delete is not inert: `ingestGrantCarbs` mirrors the phone at every
    /// takeover, so the carb the user deleted comes back on the wrist and keeps driving dosing.
    ///
    /// Splitting the passes is what makes "falling back" true. Identity is checked across the
    /// whole candidate set first, so it still wins wherever it exists; only when it names
    /// nothing does the natural key get a look, and then at every entry rather than a subset.
    ///
    /// A natural-key tie takes the first candidate deliberately. The key IS (startDate within a
    /// second, grams within a hundredth) — entries that tie on it are the same carb as far as
    /// anything downstream can tell, so there is no wrong one to pick.
    static func matchDeletedCarb(_ gone: DeletedCarb, among entries: [StoredCarbEntry]) -> StoredCarbEntry? {
        if let id = gone.syncIdentifier,
           let byIdentity = entries.first(where: { $0.syncIdentifier == id }) {
            return byIdentity
        }
        return entries.first { entry in
            abs(entry.startDate.timeIntervalSince(gone.startDate)) < 1
                && abs(entry.quantity.doubleValue(for: .gram()) - gone.grams) < 0.01
        }
    }

    /// A carb plus the wire identity it travels under.
    struct IdentifiedCarb: Equatable {
        let eventID: UUID
        let entry: NewCarbEntry
    }

    struct Outcome: Equatable {
        /// Insulin records to write (per-event deterministic syncIdentifiers).
        var doses: [DoseEntry] = []
        /// The interim-drain still-open temp's event ID: ACKed (so the watch's finalize
        /// gate clears) but NOT written or committed here — it re-drains and is written on
        /// the final drain (nil on a final hand-back). See below / the design doc.
        var openEventID: UUID? = nil
        /// Carb records to write, each carrying the WATCH JOURNAL EVENT UUID that names it on
        /// the wire. The store inserts-if-absent on this identity, which is what makes a
        /// redelivered offer physically unable to duplicate a carb — the identity is minted once
        /// at authoring on the wrist and survives to the phone's store row.
        var carbs: [IdentifiedCarb] = []
        /// Carbs the WRIST deleted during the loan, as (startDate, grams) natural
        /// keys plus the phone syncIdentifier when the watch knew one.
        ///
        /// Two origins need two keys. A PHONE-originated carb reached the watch through the
        /// grant carrying the phone's own syncIdentifier, so it can be named directly. A
        /// WATCH-entered carb has no shared identity at all — `.carb` records carry none, and
        /// CarbStore mints a fresh syncIdentifier on each side — so it is matched on
        /// (startDate, grams), which is unique enough inside one loan.
        ///
        /// Add-then-delete inside a single drain is CANCELLED here rather than round-tripped:
        /// see the `.carbDeleted` case below. Only deletes that survive that cancellation reach
        /// the phone's store, and they are the phone-originated ones by construction.
        var deletedCarbs: [DeletedCarb] = []
        /// Event IDs annulled by the exact-size fingerprint.
        var annulledEventIDs: [UUID] = []
        /// A positive odometer remainder no record explains — extra delivery the pod made
        /// beyond the books. Computed and captured here; the consumer deliberately does NOT
        /// inject it as IOB (that valve is disabled — see its call site in
        /// PodLoanPhoneController). The asymmetry with the shortfall below still holds:
        /// extra delivery may only ever ADD to the books, a shortfall may only annul a
        /// whole ASSUMED record, and neither direction ever reduces a confirmed record or
        /// reduces anything partially.
        var positiveRemainderUnits: Double?
        /// A negative remainder no fingerprint explains (case 3 in `reconcile`) — computed
        /// and captured, never subtracted from any record. Deliberate: guessed or partial
        /// reductions are prohibited, because a wrong reduction understates IOB, and
        /// leaving IOB overstated is the safe direction. The user-facing warning for a
        /// shortfall comes from the phone's authoritative odometer audit, not this field.
        var residualShortfallUnits: Double?
        /// The override state this drain hands back, or nil when the drain
        /// carried no `.overrideChange` record at all (→ the phone's own override is left
        /// completely alone). LAST record wins: within one drain the watch may have set,
        /// re-set and cleared, and only the final wrist state is therapy-relevant.
        /// This is NOT dose accounting — it never touches `doses`.
        var overrideChange: OverrideChange?
    }

    /// The two things a drained override record can say. Modelled as an enum rather than a
    /// `TemporaryScheduleOverride??` so "clear it" and "there was nothing to say" cannot be
    /// confused at a call site — confusing them would silently cancel a phone override.
    enum OverrideChange: Equatable {
        case set(TemporaryScheduleOverride)
        case cleared
    }

    // MARK: - The pure core

    static func reconcile(_ input: Input) -> Outcome {
        var outcome = Outcome()
        var events = input.events

        // The odometer audit: compare delivered against the journal +
        // schedule over the loan window. Only meaningful with a fresh odometer.
        if let odometer = input.odometer, odometer.freshenSucceeded {
            let delivered = odometer.deliveredLatest - odometer.deliveredAtStart
            // Expected-insulin integrates the WHOLE loan's journal (committed
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
                // Fingerprints only: a shortfall may annul an ASSUMED record that
                // exactly explains it — never a confirmed one, never below zero — and
                // an ambiguous remainder touches nothing. Partial or newest-first
                // reduction is prohibited: a wrong reduction understates IOB in
                // exactly the least-understood scenarios.
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

        // The still-open temp at an INTERIM drain: the latest-starting temp/suspend whose
        // programmed window extends past the loan end (i.e. still running at the drain
        // instant). It is NOT written here — it re-drains and is written correctly
        // (clamped, immutable) on the FINAL drain. The phone is paused during the loan, so
        // its store need only be right at hand-back; writing the open temp now would either
        // defer it (the save filter) or freeze it at the interim state. The controller
        // still ACKS it (so the watch's finalize gate clears) but keeps it out of
        // committedIDs (so it re-drains). On a FINAL hand-back nothing is open.
        let openEventID: UUID? = input.isFinalHandback ? nil : events
            .filter { e in
                switch e.record.kind {
                case .tempBasal, .suspend, .boundaryTruncation:
                    return (e.record.endDate ?? e.record.startDate) > input.loanEnd
                default:
                    return false
                }
            }
            .max(by: { $0.record.startDate < $1.record.startDate })?.id
        outcome.openEventID = openEventID

        // Store writes for what remains: records are the truth; confirmed and
        // surviving-assumed alike enter the record. Overlap truncation is NOT done here —
        // routing through DoseStore.addPumpEvents runs stock InsulinMath.reconciled() at
        // the store, which collapses overlaps and trims the last loan temp against the
        // phone's resumed dose. We only (a) clamp to loanEnd on a final hand-back so a
        // full-window trailing temp isn't deferred by the save filter, and (b) skip the
        // interim open temp (written on the final drain). See docs/DESIGN_LOAN_ADDPUMPEVENTS.md.
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
                // Skip the interim open temp — it re-drains and is written on the final drain.
                if event.id == openEventID { continue }
                if let rate = event.record.unitsPerHour, let end = event.record.endDate {
                    let clampedEnd = input.isFinalHandback ? Swift.min(end, input.loanEnd) : end
                    outcome.doses.append(DoseEntry(
                        type: .tempBasal,
                        startDate: event.record.startDate,
                        endDate: clampedEnd,
                        value: rate, unit: .unitsPerHour,
                        syncIdentifier: syncIdentifier(for: event)))
                }
            case .carb:
                if let grams = event.record.amount {
                    outcome.carbs.append(IdentifiedCarb(
                        eventID: event.id,
                        entry: NewCarbEntry(
                            quantity: HKQuantity(unit: .gram(), doubleValue: grams),
                            startDate: event.record.startDate,
                            foodType: nil,
                            absorptionTime: event.record.absorptionTime)))
                }
            case .carbDeleted:
                // The wrist owned the carb store for the length of the loan, so the
                // drain replays that ownership onto the phone — the same contract as
                // `.overrideChange`, and for the same reason: without it, `ingestGrantCarbs`
                // resurrects the deletion at the next takeover.
                //
                // ADD-THEN-DELETE CANCELS. A carb entered on the wrist and deleted again before
                // hand-back must reach the phone as NOTHING, not as an add followed by a delete
                // the phone cannot resolve (it never minted an identity for that carb, so a
                // syncIdentifier delete would miss and the carb would survive). Seq order makes
                // this safe: the `.carb` is always earlier in `events` than its `.carbDeleted`.
                if let grams = event.record.amount {
                    let start = event.record.startDate
                    let before = outcome.carbs.count
                    outcome.carbs.removeAll { $0.entry.startDate == start && $0.entry.quantity.doubleValue(for: .gram()) == grams }
                    guard outcome.carbs.count == before else { break }   // cancelled the pair
                    outcome.deletedCarbs.append(DeletedCarb(
                        syncIdentifier: event.record.syncIdentifier,
                        startDate: start,
                        grams: grams))
                }
            case .overrideChange:
                // The wrist owned overrides for the length of the loan, so the
                // drain replays that ownership onto the phone. Fold in seq order and let the
                // LAST record win — a set→clear pair inside one drain must land as "cleared",
                // never as "set" (that is the resurrection this ordering rules out). Writes
                // nothing to `doses`: an override changes the SCHEDULE insulin is netted
                // against, and the phone's own override history does that job.
                if event.record.overrideChangeIsClear {
                    outcome.overrideChange = .cleared
                } else if let override = event.record.overrideChangePayload {
                    outcome.overrideChange = .set(override)
                }
                // An undecodable payload falls through deliberately: leave the phone's
                // override exactly as it is rather than guess (see overrideChangeIsClear).
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
    /// (docs/DESIGN_LOAN_PROTOCOL_V2.md §8) — nil schedule means the basal
    /// expectation is unknowable, so only journaled insulin counts (the audit then
    /// skews conservative: a too-low expectation makes remainders MORE positive,
    /// which only ever adds IOB).
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
            total += pulsedInsulin(rate: seg.rate, seconds: seg.end.timeIntervalSince(seg.start))
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

    /// What the POD actually delivers for a basal segment — not `rate × time`.
    ///
    /// The pod delivers discrete 0.05 U pulses spaced `3600 × 0.05 / rate` apart, and every
    /// SetInsulinScheduleCommand RESTARTS that clock (`RateEntry.makeEntries` sets
    /// `delayUntilFirstPulse` to a full interval). The loop replaces the temp about every
    /// 5 minutes, so each segment is truncated mid-interval and loses its partial pulse — a
    /// LOSS every time, never a gain, averaging half a pulse per replacement.
    ///
    /// A continuous `rate × time` figure is therefore a biased estimate that OVERSTATES
    /// expected insulin, and the bias grows with the NUMBER OF TEMP CHANGES — ~0.6 U/hour of
    /// pure artifact on a long loan. Overstated expected drives the audit residual NEGATIVE,
    /// which warns the user of phantom IOB on a perfectly healthy loan and can annul assumed
    /// records that were in fact delivered. (A negative residual never opens the loop — only
    /// unexplained EXTRA delivery does — so the artifact's cost is false alarms and wrongly
    /// retired records, not a therapy stop.)
    ///
    /// Boluses are unaffected and stay exact: they are commanded directly as a pulse count.
    ///
    /// Rate 0 delivers nothing. Rates are already multiples of 0.05 by the time they reach the pod
    /// (`roundToSupportedBasalRate`), so no rounding is applied here beyond the pulse count itself.
    private static func pulsedInsulin(rate: Double, seconds: TimeInterval) -> Double {
        guard rate > 0, seconds > 0 else { return 0 }
        let pulseInterval = 3600.0 * podPulseSize / rate       // seconds between pulses
        let pulses = (seconds / pulseInterval).rounded(.down)  // the partial pulse is never delivered
        return pulses * podPulseSize
    }

    /// The pod's delivery quantum. Mirrors OmnipodKit's `Pod.pulseSize`, restated here because
    /// this file must not import the pump driver.
    private static let podPulseSize: Double = 0.05

    private static func scheduleInsulin(_ schedule: BasalRateSchedule, from: Date, to: Date) -> Double {
        // Same pulse model per schedule segment. A schedule-covered gap is the pod running its
        // stored basal program, which is pulsed identically — but note the pod does NOT restart
        // its pulse clock at our segment boundaries here (it is one continuous program), so this
        // slightly over-penalises a gap split across schedule items. Immaterial for a flat
        // schedule, and conservative in the direction that matters: it can only make `expected`
        // smaller, i.e. make delivery look MORE complete rather than less.
        return schedule.between(start: from, end: to).reduce(0) { partial, item in
            let s = max(item.startDate, from)
            let e = min(item.endDate, to)
            guard e > s else { return partial }
            return partial + pulsedInsulin(rate: item.value, seconds: e.timeIntervalSince(s))
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
    /// The insulin this record claims, for exact-size matching (fingerprint 1 in
    /// `reconcile`).
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

    /// The schedule insulin over this record's window (fingerprint 2 in `reconcile` — how much a
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
