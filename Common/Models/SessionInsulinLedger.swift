//
//  SessionInsulinLedger.swift
//  Loop / WatchApp Extension (compiled into BOTH targets — one source file, tested from LoopTests)
//
//  #73/#74 (2026-07-29, Jeremy's zoom-out ruling: "in the end, we have to store some insulin
//  doses and then move them back and forth — shouldn't be that hard"): the loan session's
//  insulin books as a PLAIN, SINGLE-OWNER timeline, replacing the Core Data DoseStore for the
//  watch's dosing path. SHADOW MODE first: runs alongside the untouched store and emits
//  [ledger-diff] every cycle; cutover is a later, explicit flag flip. Reverting = delete this
//  file + three one-line hooks.
//
//  WHY (the seven-incident pattern, all field-diagnosed): the stock DoseStore stack is
//  multi-year, HealthKit-syncing Core Data machinery whose invariants assume ONE writer (the
//  pump manager) and treat MUTABLE doses as ephemeral — every report raw-blind purges mutable
//  pump rows AND soft-deletes every mutable delivery entry not re-asserted in that exact batch,
//  with unverified saves and no rollback. The loan fed it THREE writers (grant seed, pod
//  re-reports, wipes); every incident — identity laundering (hex-of-hex), store-trump swallows,
//  wipe leaks, pending-object zombies, the 2026-07-29 IOB cliffs — was a coherence failure
//  between them. A session holds ≤ ~200 doses and the math (LoopKit InsulinMath) is pure
//  functions over [DoseEntry]. This ledger is that array with ONE owner:
//   - no wipes: a new ledger per epoch is a new array;
//   - no identity machinery: single writer, nothing to dedup;
//   - no mutability lifecycle: a still-running temp is just a full-span entry — InsulinMath's
//     eval-time bound (delivery integrated only to eval-time + model delay) counts
//     delivered-so-far natively, the same semantics as the phone's own mutable row;
//   - the #72 inherited-temp problem dissolves: seed it full-span, done. No re-arm, no C5.
//
//  PARITY GOAL (honest scope, per the 2026-07-29 adversarial review): the ledger folds the
//  MAIN inputs the hand-back journal carries (enacts, predecessors truncated at supersede),
//  aiming for hand-back parity by derivation. KNOWN GAPS, all deliberate for shadow mode and
//  all cutover-blockers until closed: (1) the uncertain-command cluster — an enact that errors
//  uncertainly but is later chase-CONFIRMED (or stands as .assumed under R22) is journaled but
//  NOT ledgered, so a persistent ledger<store Δ after an uncertain enact is the LEDGER's gap;
//  (2) dose timestamps are stamped at pod-ACCEPT with programmed values (the journal mints at
//  will-enact; the pod's actual start precedes accept by the BLE round-trip — supersede
//  boundaries shift late by seconds); (3) pod-actual reconciliation (pulse quantization,
//  partial boluses) is not folded back. `testLedgerMatchesDoseStoreIOB` pins ledger output to
//  DoseStore output on identical doses — the stock-math guarantee for what IS folded.
//

import Foundation
import HealthKit
import LoopKit

/// Single-owner insulin timeline for one loan session.
///
/// NOT thread-safe by design: the owner (WatchLoopManager) confines every access to its
/// serial `dataAccessQueue`. There is deliberately no locking to get wrong.
public struct SessionInsulinLedger {
    /// The frozen grant basal schedule — temps net against this for the whole loan
    /// (delivery-time netting, same rule as the seeded store path).
    public let basalSchedule: BasalRateSchedule
    public let insulinModelProvider: InsulinModelProvider
    public let longestEffectDuration: TimeInterval

    /// Chronological. Basal-affecting doses are non-overlapping BY CONSTRUCTION —
    /// `recordEnact` truncates the open predecessor, the single coherence rule this design
    /// needs (versus reconciled() + resolveMutable + replacePendingEvents + raw constraints).
    public private(set) var doses: [DoseEntry] = []

    public init(basalSchedule: BasalRateSchedule,
                insulinModelProvider: InsulinModelProvider,
                longestEffectDuration: TimeInterval) {
        self.basalSchedule = basalSchedule
        self.insulinModelProvider = insulinModelProvider
        self.longestEffectDuration = longestEffectDuration
    }

    // MARK: - Writes (single owner)

    /// Takeover seed. `finished` = the grant's completed history; `live` = doses still
    /// delivering at takeover (the running temp / a mid-flight bolus), entered FULL-SPAN —
    /// the eval-time bound counts only what has dripped in by any given evaluation instant,
    /// so IOB tracks their delivery in real time (the 0.50 → 0.57 behavior) and a later
    /// watch enact truncates them like any predecessor.
    public mutating func seed(finished: [DoseEntry], live: [DoseEntry]) {
        // Older-phone back-compat: a grant may carry the running temp BOTH as a truncated
        // boundaryRecord (finished) and full-span (live). The store path collapses that via
        // reconciled(); here, drop the finished same-start twin — the live full-span copy is
        // the single truth (adversarial review: without this the delivered span counts twice).
        let deduped = finished.filter { fin in
            !(fin.type != .bolus && live.contains { liv in
                liv.type != .bolus && abs(liv.startDate.timeIntervalSince(fin.startDate)) < 1.0
            })
        }
        doses = (deduped + live).sorted { $0.startDate < $1.startDate }
    }

    /// A watch enact the pod ACCEPTED. Basal-affecting doses (temp/suspend — the enactor
    /// models suspends as 0 U/hr temps) truncate any open predecessor at their start:
    /// the same supersede rule the hand-back journal fold applies on the phone.
    public mutating func recordEnact(_ dose: DoseEntry) {
        if dose.type != .bolus {
            // An accepted basal command supersedes EVERY open basal dose: earlier-starting
            // ones are truncated at its start; equal- or later-starting overlaps (same-second
            // enacts, clock skew vs a phone-stamped live seed) are removed outright — the pod
            // runs one basal program, so the ledger holds one (adversarial-review edges).
            doses.removeAll { $0.type != .bolus && $0.startDate >= dose.startDate && $0.endDate > dose.startDate }
            for index in doses.indices
            where doses[index].type != .bolus
                && doses[index].startDate < dose.startDate
                && doses[index].endDate > dose.startDate {
                doses[index] = doses[index].trimmed(to: dose.startDate)
            }
        }
        doses.append(dose)
        doses.sort { $0.startDate < $1.startDate }
    }

    // MARK: - Reads (stock math, no stores)

    /// IOB at `date` via the SAME public InsulinMath pipeline the DoseStore path uses:
    /// annotate against the frozen schedule (delivery-time netting, incl. schedule-boundary
    /// splits), then the stock insulin-on-board timeline — and the SAME sampling rule as
    /// `DoseStore.insulinOnBoard(at:)`: of the two 5-min-grid values adjacent to `date`,
    /// take the larger (stock's bolus-scheduled-between-samples convention). Byte-for-byte
    /// parity with the store on identical doses is pinned by testLedgerMatchesDoseStoreIOB.
    public func insulinOnBoard(at date: Date) -> Double {
        guard !doses.isEmpty else { return 0 }
        let timeline = doses
            .annotated(with: basalSchedule)
            .insulinOnBoard(
                insulinModelProvider: insulinModelProvider,
                longestEffectDuration: longestEffectDuration,
                from: date.addingTimeInterval(-.minutes(5)),
                to: date.addingTimeInterval(.minutes(5)))
        let before = timeline.last(where: { $0.startDate <= date })?.value
        let after = timeline.first(where: { $0.startDate >= date })?.value
        return max(before ?? 0, after ?? 0)
    }

    /// Glucose effects for the prediction pipeline (cutover phase; unused in shadow mode).
    /// Mirrors DoseStore.getGlucoseEffects' basalDosingEnd contract: non-bolus doses are
    /// trimmed to `basalDosingEnd` (stock trims continuing temps at now so DoseMath can assume
    /// cancellability); pass nil for the includingPendingInsulin series (cutover API parity —
    /// adversarial review).
    public func glucoseEffects(insulinSensitivity: InsulinSensitivitySchedule,
                               basalDosingEnd: Date? = nil,
                               from start: Date? = nil,
                               to end: Date? = nil) -> [GlucoseEffect] {
        guard !doses.isEmpty else { return [] }
        let trimmed = doses.map { dose -> DoseEntry in
            guard dose.type != .bolus, let basalDosingEnd else { return dose }
            return dose.trimmed(to: basalDosingEnd)
        }
        return trimmed
            .annotated(with: basalSchedule)
            .glucoseEffects(insulinModelProvider: insulinModelProvider,
                            longestEffectDuration: longestEffectDuration,
                            insulinSensitivity: insulinSensitivity,
                            from: start,
                            to: end)
    }

    /// Greppable one-liner for [ledger-diff] context.
    public var summary: String {
        let temps = doses.filter { $0.type != .bolus }.count
        let boluses = doses.count - temps
        return "\(doses.count) doses (\(temps) basal-affecting, \(boluses) bolus)"
    }
}
