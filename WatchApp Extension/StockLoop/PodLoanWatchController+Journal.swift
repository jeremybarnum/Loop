//
//  PodLoanWatchController+Journal.swift
//  WatchApp Extension
//
//  Part of PodLoanWatchController (see PodLoanWatchController.swift). The journal's writers: the pump manager's report (doses), the wrist UI (carbs, overrides).
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import OmnipodKit
import WatchKit
import os.log

// MARK: - The journal's writers: the pump manager's report (doses), the wrist UI (carbs, overrides)

extension PodLoanWatchController {

    /// THE JOURNAL IS FED BY THE PUMP MANAGER'S REPORT — the same report that writes the book.
    /// One identity per dose: the pod-native raw the pump manager minted, carried on the wire as
    /// hex so the phone's row lands under the SAME bytes its own pump manager would use for the
    /// same dose (`LoanSeedIdentity` decodes it). A dose is journaled once, at its first report;
    /// the running temp's re-reports (same raw, mutable) are recognized and not re-minted, and the
    /// phone finalizes it from the returned pod state on reclaim, exactly as it does its own.
    /// Uncertainty is the pump manager's: a command the pod never acknowledged is not reported
    /// until OmnipodKit resolves it from the next status, or books it "in the direction of
    /// positive net delivery" when it gives up — so nothing here is ever assumed.
    func journalPumpEvents(_ events: [NewPumpEvent]) {
        guard phase == .active else { return }
        var minted = 0
        for event in events {
            guard let dose = event.dose, let record = Self.loanRecord(for: dose, raw: event.raw),
                  let identity = record.syncIdentifier, !journal.contains(syncIdentifier: identity) else { continue }
            guard let journaled = try? journal.mintEvent(record: record, provenance: .confirmed) else {
                SportLog.event("loan", "** JOURNAL MINT FAILED for \(record.kind) — the dose is in the book but will NOT follow the pod home **")
                continue
            }
            minted += 1
            let amount = record.kind == .bolus ? String(format: "%.2f U", record.amount ?? 0)
                                               : String(format: "%.2f U/hr", record.unitsPerHour ?? 0)
            SportLog.event("loan", "\(record.kind) JOURNALED from the pump manager's report — \(amount)\(dose.isMutable ? " (running)" : ""), seq \(journaled.seq)")
        }
        if minted > 0 { streamRecords() }
    }

    /// A pump-manager dose as a wire record. Temps and boluses are what the wrist doses with; a
    /// suspend or resume never originates on the wrist, so anything else is logged and skipped.
    private static func loanRecord(for dose: DoseEntry, raw: Data) -> LoanDoseRecord? {
        let identity = raw.map { String(format: "%02x", $0) }.joined()   // LoopKit's hex helper is module-internal
        switch dose.type {
        case .bolus:
            return LoanDoseRecord(kind: .bolus, startDate: dose.startDate, endDate: dose.endDate,
                                  amount: dose.programmedUnits, syncIdentifier: identity,
                                  insulinType: dose.insulinType, deliveredUnits: dose.deliveredUnits)
        case .tempBasal:
            return LoanDoseRecord(kind: .tempBasal, startDate: dose.startDate, endDate: dose.endDate,
                                  unitsPerHour: dose.unitsPerHour, syncIdentifier: identity,
                                  insulinType: dose.insulinType, deliveredUnits: dose.deliveredUnits)
        default:
            SportLog.event("loan", "pump report carried a \(dose.type) dose — not a wrist command; not journaled")
            return nil
        }
    }

    /// Watch-entered carbs follow the pod home.
    ///
    /// Rides the ordinary journal, exactly like the override path, so it inherits the per-loan
    /// seq, the commit cursor, resend-until-ack and the hand-back drain for free. On the phone,
    /// LoanReconciler turns a .carb record into a NewCarbEntry (LoanReconciler.swift:183-189)
    /// and both commit sites run behind
    /// `.filter { !stagedTombstones.contains($0.id) && !committedIDs.contains($0.id) }`, so a
    /// redelivered record is dropped before it reaches addCarb.
    ///
    /// That protocol-level gate is load-bearing, not belt-and-braces: NewCarbEntry carries no
    /// identity of its own (CarbStore mints a fresh syncIdentifier on every addCarbEntry), so
    /// the store can never dedupe and the cursor is the only guard against double-counting.
    ///
    /// No skew gate needed, unlike .overrideChange: .carb is an original kind that every phone
    /// build in the field can decode.
    func loanDidRecordCarbs(_ entry: NewCarbEntry) {
        let grams = entry.quantity.doubleValue(for: .gram)
        queue.async {
            guard self.phase == .active else {
                SportLog.event("loan", String(format: "carb entry ignored (%.0f g) — no active loan to journal it against", grams))
                return
            }
            let record = LoanDoseRecord(kind: .carb,
                                        startDate: entry.startDate,
                                        amount: grams,
                                        absorptionTime: entry.absorptionTime)
            guard let event = try? self.journal.mintEvent(record: record, provenance: .confirmed) else {
                SportLog.event("loan", String(format: "** CARB JOURNAL MINT FAILED (%.0f g) — the carb is LIVE on the watch but will NOT follow the pod home **", grams))
                return
            }
            SportLog.event("loan", String(format: "carb JOURNALED %.0f g (absorption %.1f h) — seq %d, event %@",
                                          grams, (entry.absorptionTime ?? 0) / 3600, event.seq,
                                          String(event.id.uuidString.prefix(8))))
            self.streamRecords()
        }
    }

    /// Journal a carb the WRIST deleted, so the deletion follows the pod home.
    ///
    /// This CANNOT be a local-only delete. `ingestGrantCarbs` makes the watch an authoritative
    /// mirror of the phone at every takeover, so a deletion the phone never heard about is
    /// resurrected at the next grant — the user deletes it, watches it vanish, and it comes back
    /// still driving dosing. Riding the journal buys the per-loan seq, the commit cursor,
    /// resend-until-ack and the hand-back drain, which is exactly what makes the deletion survive
    /// a phone that is out of range for the whole session.
    ///
    /// `syncIdentifier` is the phone's own, when the carb came from the grant; nil for a carb
    /// entered on this wrist, whose add/delete pair the reconciler cancels instead of
    /// round-tripping (LoanReconciler `.carbDeleted`).
    func loanDidDeleteCarb(syncIdentifier: String?, startDate: Date, grams: Double) {
        queue.async {
            guard self.phase == .active else {
                SportLog.event("loan", String(format: "carb delete ignored (%.0f g) — no active loan to journal it against", grams))
                return
            }
            let record = LoanDoseRecord(kind: .carbDeleted,
                                        startDate: startDate,
                                        amount: grams,
                                        syncIdentifier: syncIdentifier)
            guard let event = try? self.journal.mintEvent(record: record, provenance: .confirmed) else {
                // Say it loudly: the carb is gone from the WATCH but the phone still holds it, so
                // the next takeover will bring it back. Same failure class as a lost carb add.
                SportLog.event("loan", String(format: "** CARB DELETE JOURNAL MINT FAILED (%.0f g) — gone on the watch but the phone still has it; the next grant will RESURRECT it **", grams))
                return
            }
            SportLog.event("loan", String(format: "carb DELETE journaled %.0f g @ %@ — sync %@, seq %d, event %@",
                                          grams, ISO8601DateFormatter().string(from: startDate),
                                          syncIdentifier ?? "none(watch-entered)", event.seq,
                                          String(event.id.uuidString.prefix(8))))
            self.streamRecords()
        }
    }

    /// Journal a WRIST-enacted override change so it follows the pod home.
    ///
    /// Rides the ordinary journal, exactly like the (currently suppressed) carb path: it
    /// inherits the per-loan seq, the commit cursor, resend-until-ack, and the hand-back drain —
    /// which is precisely what makes a phone-ABSENT override still reach the phone. A bespoke
    /// WC message would be dropped on the floor the moment the phone is out of range, and Sport
    /// Mode's whole premise is that it is.
    ///
    /// Minted `.confirmed` directly: this is not a pod command, so there is no report to wait for.
    ///
    /// Called from the wrist UI on main; `queue.async` (never `sync`) keeps the queue-order
    /// invariant intact.
    ///
    /// EDGE CASES (verified, not assumed — no machinery added for any of them):
    ///
    ///  • OVERRIDE EXPIRES MID-LOAN. Stock handles it, via the override's OWN end date, in both
    ///    places that matter. Schedules: `TemporaryScheduleOverrideHistory.resolvingRecent*`
    ///    scopes each multiplier to `[startDate, actualEndDate]` (overridesReflectingEnabled-
    ///    Duration → applyingOverride(relativeTo:)), so cycles after the end resolve unscaled
    ///    while the temps that ran DURING it still net against the scaled baseline. Target:
    ///    `GlucoseRangeSchedule.value(at:)` gates on `Date() < override.end`, so the target
    ///    snaps back on expiry. Nothing here polls or sweeps — an expired override simply
    ///    stops mattering. The journal record is a point event ("at 14:02 the wrist set this
    ///    override, which ends at 15:02"), so its meaning is unchanged by expiry: the phone
    ///    applies the same override, already expired or expiring, and treats it identically.
    ///
    ///  • HAND-BACK WITH AN OVERRIDE ACTIVE. It PERSISTS on the phone — that is the ruling, and
    ///    it is what falls out of the design: the drain applies it to the phone's LoopSettings
    ///    and nothing revokes it at loan end. The user set an override; ending Sport Mode is
    ///    not a request to cancel it.
    ///
    ///  • LOAN ENDS BY REVOCATION OR CRASH. The record either drained or it did not, and both
    ///    are safe. Mint persists to disk BEFORE returning (LoanEventJournal.mintEvent), so:
    ///    a revoke routes through `handleRevoke` → `sendHandbackOffer(recovered: true)`, which
    ///    carries every unacked event including this one; a crash/relaunch finds the undrained
    ///    journal, enters `.recoveredDrain`, and `drainRecoveredIfNeeded()` offers the same set.
    ///    If the phone is simply never reachable the record stays unacked and re-offers on a
    ///    later hand-back, exactly like an unacked dose. The only true loss window is a
    ///    process death between the wrist apply and this mint — sub-millisecond, and in that
    ///    window the override was never durable ANYWHERE, so nothing is left inconsistent.
    ///
    ///  • WATCH APP RELAUNCHES MID-LOAN. The applied override does NOT survive INTO A LOAN,
    ///    because the loan itself does not: `init` routes any live phase to `.recoveredDrain`
    ///    (never resurrect a session). So there is no state where dosing continues under an
    ///    override the sport manager has forgotten. What DOES survive is the wrist UI's copy
    ///    (stock `LoopDataManager.settings` is `@PersistedProperty`), which is display-only
    ///    once the loan is dead; the sport `WatchLoopManager.settings` is grant-scoped by
    ///    construction and is rebuilt by the NEXT grant — which carries the phone's override
    ///    (part A), i.e. this one, once the recovered drain lands. Deliberately no new
    ///    persistence: the correct source of truth after a relaunch is the phone, not a
    ///    cached wrist value.
    func loanDidRecordOverride(_ override: TemporaryScheduleOverride?) {
        let name = override.map { $0.context.presetNameForLog } ?? "cleared"
        queue.async {
            guard self.phase == .active else {
                // Outside a loan the phone owns overrides and the stock WC settings path
                // already carries them — journaling here would be a record with no loan to
                // ride home on. (ActionHUDController only calls this during a loan; this is
                // the guard for a hand-back landing between the tap and this hop.)
                SportLog.event("override", "NOT JOURNALED (\(name)) — no active loan (phase \(self.phase.rawValue)); the stock phone path owns it")
                return
            }
            guard self.phoneSupportsOverrideRecords else {
                // Skew gate: an older phone cannot decode this kind, and an
                // undecodable offer strands the loan. The override is LIVE on the wrist —
                // dosing is correct here — it simply will not follow the pod home.
                SportLog.event("override", "NOT JOURNALED (\(name)) — this phone build predates override records; the override is LIVE on the watch but will NOT follow the pod home. Update the phone app to sync overrides.")
                return
            }
            let record = LoanDoseRecord.overrideChange(override, at: self.now(), note: name)
            guard let event = try? self.journal.mintEvent(record: record, provenance: .confirmed) else {
                SportLog.event("override", "** JOURNAL MINT FAILED for \(name) — the override is LIVE on the watch but will NOT follow the pod home **")
                return
            }
            SportLog.event("override", "JOURNALED \(name) — seq \(event.seq), event \(event.id.uuidString.prefix(8)), sync \(record.syncIdentifier ?? "—") (rides the drain to the phone)")
            self.streamRecords()
        }
    }

}

/// Which WCSession channel a message arrived on. `sendMessage` wakes the counterpart
/// immediately; `transferUserInfo` is queued but guaranteed and relaunch-surviving. They fail
/// independently, which is the whole reason this is recorded.
