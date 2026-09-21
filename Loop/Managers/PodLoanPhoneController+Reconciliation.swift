//
//  PodLoanPhoneController+Reconciliation.swift
//  Loop
//
//  Part of PodLoanPhoneController (see PodLoanPhoneController.swift). Split by concern; stored properties live in the core class.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore
import UserNotifications
import os.log

extension PodLoanPhoneController {

    // MARK: - Loan → pump-event conversion

    /// Wrap reconciled loan DoseEntries as NewPumpEvents for DoseStore.addPumpEvents.
    /// The identity must live in `raw` — NewPumpEvent.init overwrites dose.syncIdentifier
    /// with raw.hexadecimalString, so we encode the deterministic loan syncIdentifier
    /// (loanv2-<uuid>) there for idempotent, dedup-safe upserts. (The loanv2-audit-<epoch>
    /// odometer-IOB sync ID is gone as of 2026-07-27 — no odometer insulin is injected.)
    func newPumpEvents(from doses: [DoseEntry]) -> [NewPumpEvent] {
        doses.compactMap { dose in
            guard let syncID = dose.syncIdentifier else { return nil }
            // The wire identity is the pod-native raw as hex (the watch's pump manager minted it);
            // decoding it lands the row under the SAME bytes this phone's own pump manager uses
            // for the same dose, so a re-report after reclaim is the same row, not a twin.
            return NewPumpEvent(date: dose.startDate,
                                dose: dose,
                                raw: LoanSeedIdentity.raw(forSyncIdentifier: syncID),
                                title: Self.pumpEventTitle(for: dose.type))
        }
    }

    /// e44: the overlap truncation the STORE does on the way into the delivery store, done here
    /// because the backfill upsert deliberately bypasses that path.
    ///
    /// NOT optional. The watch journals a temp with its PROGRAMMED end (PodLoanWatchController
    /// `loanWillEnactTempBasal`: `endDate = now + duration`), so a 5-minutely dose cycle leaves
    /// half a dozen 30-minute temps overlapping — the watch's own log calls that untruncated sum
    /// "NOT a meaningful commanded total" (:2222). LoanReconciler leaves them that way on purpose
    /// (LoanReconciler.swift:182-188) because `DoseStore.addPumpEvents` runs stock
    /// `InsulinMath.reconciled()` before the delivery-store insert (DoseStore.swift:1174). An
    /// upsert that carried the untruncated spans would REPLACE the store's own truncated rows
    /// with them and inflate IOB on every hand-back, healthy ones included.
    ///
    /// `reconciled()` is internal to LoopKit, so this is its rate-record arm restated against the
    /// only two dose types that can appear here: a rate record ends where the next one starts, a
    /// fully superseded one is dropped, boluses pass through. The suspend/resume arms are
    /// unreachable — LoanReconciler mints suspends as rate-0 `.tempBasal` (:200-211) and never
    /// emits `.suspend`/`.resume` DoseEntries.
    func truncatingOverlaps(_ doses: [DoseEntry]) -> [DoseEntry] {
        var out: [DoseEntry] = []
        var lastRate: DoseEntry?
        for dose in doses.sorted(by: { $0.startDate < $1.startDate }) {
            guard dose.type != .bolus else {
                out.append(dose)
                continue
            }
            if let last = lastRate {
                let end = Swift.min(last.endDate, dose.startDate)
                if end > last.startDate {
                    if let trimmed = last.trimmed(from: nil, to: end, syncIdentifier: last.syncIdentifier) {
                        out.append(trimmed)
                    }
                }
            }
            lastRate = dose
        }
        // Stock's tail guard verbatim (InsulinMath.swift:514): a zero-duration final record is
        // dropped there, so appending it here would upsert a stray row the clean path never wrote.
        if let last = lastRate, last.endDate > last.startDate { out.append(last) }
        return out
    }

    /// The other half of what the store's path does that the upsert bypasses:
    /// `reconciled()` ends with `resolvingDelivery` (InsulinMath.swift:345-365, fileprivate),
    /// which stamps `deliveredUnits` on every immutable dose — pulse-quantized for temps.
    /// Without this, an upserted row REPLACES a clean row that had `deliveredUnits` set with
    /// one that has nil, and downstream math falls back to un-quantized programmed figures —
    /// sub-pulse drift, but rows the backfill corrects must be indistinguishable from rows
    /// the clean path wrote.
    private static func resolvedDeliveredUnits(for dose: DoseEntry) -> Double? {
        guard !dose.isMutable else { return nil }
        switch dose.type {
        case .bolus:     return dose.programmedUnits
        case .tempBasal: return dose.unitsInDeliverableIncrements
        default:         return nil
        }
    }

    /// e44: the same reconciled doses, restated under the identity the STORE gave them.
    ///
    /// `NewPumpEvent.init` DISCARDS `dose.syncIdentifier` and derives the stored one as
    /// `raw.hexadecimalString` (NewPumpEvent.swift:33), so a dose upserted by syncIdentifier has
    /// to carry hex(utf8("loanv2-<uuid>")) or it inserts a SECOND row instead of correcting the
    /// one the pump-event path already wrote. Rebuilt rather than mutated: `syncIdentifier` is
    /// `internal(set)` outside LoopKit, and `value` is not readable at all — recovered through
    /// the unit-appropriate public accessor.
    func storeIdentifiedDoses(from doses: [DoseEntry]) -> [DoseEntry] {
        doses.compactMap { dose in
            guard let syncID = dose.syncIdentifier else { return nil }
            return DoseEntry(type: dose.type,
                             startDate: dose.startDate,
                             endDate: dose.endDate,
                             value: dose.unit == .unitsPerHour ? dose.unitsPerHour : dose.programmedUnits,
                             unit: dose.unit,
                             decisionId: dose.decisionId,
                             deliveredUnits: dose.deliveredUnits ?? Self.resolvedDeliveredUnits(for: dose),
                             description: dose.description,
                             syncIdentifier: LoanSeedIdentity.raw(forSyncIdentifier: syncID).hexadecimalString,
                             scheduledBasalRate: dose.scheduledBasalRate,
                             insulinType: dose.insulinType,
                             automatic: dose.automatic,
                             manuallyEntered: dose.manuallyEntered,
                             isMutable: dose.isMutable,
                             wasProgrammedByPumpUI: dose.wasProgrammedByPumpUI)
        }
    }

    static func pumpEventTitle(for type: DoseType) -> String {
        switch type {
        case .bolus:     return "Bolus"
        case .tempBasal: return "Temp Basal"
        case .basal:     return "Basal"
        case .suspend:   return "Suspend"
        case .resume:    return "Resume"
        }
    }


    /// The reclaim's phase, its real deadline, and — for the settle alone — a fraction to draw.
    /// nil when nothing is in flight.
    ///
    /// Two windows, one accessor, and only the settle draws. The tapped handover still publishes
    /// its phase and the ladder's own force deadline, because the tile's label comes from that phase
    /// ("Reaching Watch…" the moment a dead branch is decided, not after the wait — and
    /// "Can't Reach Watch" from the resend deadline, so the verdict lands before the force).
    /// What it no longer publishes is a fraction: at 736 ms tapped and sub-second on a
    /// hand-back, a bar over the handover is a flash, and a dead-watch handover is better
    /// served by the sweep plus a label that names the problem than by a bar racing a 20 s force.
    ///
    /// The settle arm is deliberately NOT gated on a ladder. A watch-initiated hand-back arms no
    /// ladder and still lands in the same settle, so gating on one is what left a regularly ended
    /// session with an indeterminate sweep for the whole of its wait. Every route into `.owner`
    /// opens the settle window, so every route — tapped, watch-initiated, forced — draws a
    /// settle bar. A settle that follows a FORCE runs one stage against its own promise; the
    /// others run the two-stage fast/slow split.
    ///
    /// nil during a watch-initiated hand-back's own store commit, which no tap promised anything
    /// about, and nil again the moment the settle's round-trip verifies.
    var reclaimProgress: ReclaimProgress? {
        return Self.reclaimProgress(from: queue.sync { uiSnapshot() }, now: deps.now())
    }


    // MARK: - What a reconciliation difference actually DOES

    /// A positive residual — the pod delivered MORE than our books say — beyond this opens the
    /// loop.
    /// **0.20 U, set FROM DATA**, replacing the deliberately
    /// loose +0.5 U that had to be chosen when every residual available had been measured against
    /// the watch's stale endpoint — i.e. against the wrong interval.
    ///
    /// The bank that justifies it: n=13 authoritative samples, mean −0.031, worst |0.200|,
    /// min −0.200, max +0.000. Note WHERE THE MASS SITS — every sample is at or below zero, so the
    /// open-loop direction has never once been observed. Tightening 2.5× therefore costs nothing
    /// in false trips against the measured distribution, while catching a real over-delivery six
    /// pulses sooner. Four pulses (0.20 U) is still well clear of quantization, which
    /// tops out around half a pulse per temp replacement.
    private static let openLoopPositiveResidual: Double = 0.20

    /// A negative residual — the pod delivered LESS than our books say — beyond this warns, and
    /// only warns (see the sign asymmetry on `applyReconciliationVerdict`). Also 0.20 U.
    ///
    /// Unlike the positive bound, this one DOES sit on the measured distribution: the worst banked
    /// sample is exactly −0.200, so a loan marginally worse than anything yet seen will now warn.
    /// That is the intended trade rather than an oversight — this direction never opens the loop,
    /// so the cost of a trip is a notice, not a therapy gap, and the under-delivery direction is
    /// precisely where we WANT early visibility while the residual's true distribution fills in.
    private static let warnNegativeResidual: Double = 0.20

    /// Sign-aware. The two directions are not the same failure and do not deserve the
    /// same response:
    ///
    /// POSITIVE (pod delivered more than recorded) — there is insulin in the body that the
    /// algorithm cannot see. Closed loop will dose on top of it. That is stacking, and the remedy
    /// is to stop the machine: go open, tell the user loudly, let them look and dose by hand.
    ///
    /// NEGATIVE (pod delivered less than recorded) — the books carry phantom IOB. The algorithm
    /// believes there is more insulin working than there is, so it doses LESS: the error is
    /// self-limiting, it decays out within DIA, and annulment already retires the
    /// identifiable cases. Opening the loop here would make the actual failure (under-treatment)
    /// worse, not better — the one direction where opening the loop is the wrong medicine. So: warn,
    /// keep looping.
    ///
    /// Warned once per event, never once per retry (alarm fatigue).
    func applyReconciliationVerdict(residual: Double, epoch: Int) {
        if residual > Self.openLoopPositiveResidual {
            handbackDiag(epoch, String(format:
                "** R32 OPEN LOOP — residual %+.3f U exceeds +%.2f: the pod delivered insulin our records do not contain. Automatic dosing STOPPED. **",
                residual, Self.openLoopPositiveResidual))
            deps.openLoopForUncertainReconciliation()
            armOpenLoopReminder()
            // URGENT on either flavor: an alert that stops automatic dosing must never be a
            // quiet list entry. The one alert left on the plain channel is the negative warn
            // below, which keeps looping — caution, not action (alarm fatigue).
            deps.issueUrgentNotice("Loop Open — Unexplained Insulin",
                             String(format: "The pod delivered %.2f U more than the watch session's records account for. Automatic dosing is off until you turn it back on. Check your insulin on board before dosing.", residual))
        } else if residual < -Self.warnNegativeResidual {
            handbackDiag(epoch, String(format:
                "** R32 WARN — residual %+.3f U beyond -%.2f: records claim more delivery than the pod made (phantom IOB). Still looping — this direction under-doses and decays out. **",
                residual, Self.warnNegativeResidual))
            // "Overstated", not "High": the pod delivered LESS than the records claim, so the
            // defect is in the books, not in the body. "High" reads as a therapy state — is my
            // IOB high, is that bad? — and sends the user looking at the wrong thing.
            //
            // URGENT channel, by ruling (2026-08-24): SYMMETRIC URGENCY, ASYMMETRIC ACTION.
            // Urgency answers "does the user need to know" — and any audit breach means the
            // books and the pod disagree, both directions alike. Action answers "what is
            // safe" — and stays asymmetric: this direction keeps looping (phantom IOB
            // under-doses and decays out; opening would worsen it). The previous plain-channel
            // choice meant a Focus mode could eat the only witness to a recording failure.
            deps.issueUrgentNotice("Insulin On Board May Be Overstated",
                             String(format: "The watch session's records account for %.2f U more than the pod delivered. Automatic dosing continues; expect it to run cautious until this clears.", -residual))
        }
    }

    /// The force-reclaim verdict. Same bounds and sign asymmetry as the verdict above — a dead
    /// watch is the limiting case of incomplete books, not a different protocol — but the RESPONSE
    /// escalates, because the counterparty that would normally explain a residual is dead, and
    /// because dosing has been held since the reclaim waiting on exactly this answer.
    func applyForceReclaimVerdict(residual: Double, epoch: Int) {
        deps.setAutomaticDosingPaused(false)   // the latch's job is done; dosingEnabled carries any verdict
        if residual > Self.openLoopPositiveResidual {
            handbackDiag(epoch, String(format:
                "** R37 OPEN LOOP — force-reclaim residual %+.3f U exceeds +%.2f: the pod delivered insulin the records cannot explain (watch died mid-session?). Automatic dosing STOPPED. **",
                residual, Self.openLoopPositiveResidual))
            deps.openLoopForUncertainReconciliation()
            armOpenLoopReminder()
            // Written to survive a BANNER, which is where this is actually read. The previous
            // wording ran past four lines and truncated mid-sentence on the field screenshot
            // (2026-08-14), cutting off at "its real records w" — so the reader lost the one
            // clause that says the situation resolves itself. Order is deliberate: the number
            // and the dosing state first, because those are what a truncated banner must still
            // carry, then the reassurance. The ~2 min figure is the measured lag from the watch
            // reconnecting to its records landing and the estimate retiring.
            var body = String(format:
                "%.2f U on the pod isn't in the watch's records, so automatic dosing is OFF.", residual)
            if Self.bookUnattributedInsulinOnForceReclaim {
                bookGapDose(units: residual, epoch: epoch)
                body += " It's booked as a bolus to keep IOB conservative; the watch's real records replace it about 2 min after the phone sees the watch again."
            } else {
                body += " Check your insulin on board before dosing."
            }
            deps.issueUrgentNotice("Loop Open — Unverified Insulin", body)
        } else if residual < -Self.warnNegativeResidual {
            // Same asymmetry as the verdict above: phantom IOB under-doses and decays out, so opening
            // the loop would worsen the actual failure. Warn — but urgently, since a dead-watch
            // session earns attention either way.
            handbackDiag(epoch, String(format:
                "** R37 WARN — force-reclaim residual %+.3f U beyond -%.2f: records claim more than the pod delivered (phantom IOB). Looping resumes — this direction under-doses and decays out. **",
                residual, Self.warnNegativeResidual))
            // URGENT channel, by ruling (2026-08-24) — same symmetric-urgency/asymmetric-action
            // rule as the R32 twin, and a dead-watch session is the stronger case for it: the
            // counterparty that would normally explain the residual is dead, so this notice may
            // be the ONLY witness that recording failed. Looping still continues (the action
            // asymmetry is unchanged).
            deps.issueUrgentNotice("Insulin On Board May Be Overstated",
                             String(format: "After the watch session ended abruptly, records account for %.2f U more than the pod delivered. Automatic dosing resumes; expect it to run cautious until this clears.", -residual))
        } else {
            handbackDiag(epoch, String(format:
                "R37 audit CLEAN — residual %+.3f U within ±%.2f; automatic dosing resumes", residual, Self.openLoopPositiveResidual))
        }
    }

    /// The placeholder for insulin the odometer proved but no record explains. Timestamped
    /// NOW (the reclaim) — zero decay, maximum IOB, the conservative direction — and manually
    /// entered with a deterministic syncIdentifier so the watch's return can retire it.
    func bookGapDose(units: Double, epoch: Int) {
        let now = deps.now()
        let sync = Self.gapSyncIdentifier(epoch: epoch)
        let entry = DoseEntry(type: .bolus, startDate: now, endDate: now,
                              value: units, unit: .units, decisionId: nil, deliveredUnits: units,
                              syncIdentifier: sync, manuallyEntered: true)
        deps.bookGapDose(entry) { [weak self] ok in
            guard let self = self else { return }
            self.queue.async {
                if ok {
                    UserDefaults.standard.set(["epoch": epoch, "units": units,
                                               "bookedAt": now.timeIntervalSince1970],
                                              forKey: Keys.gapBooking)
                    // The booking is now the standing condition, so this is where the standing
                    // reminder belongs — not at the four "dosing is paused" sites the old one
                    // used, none of which imply a placeholder exists.
                    self.armPlaceholderReminders(units: units, bookedAt: now)
                    self.handbackDiag(epoch, String(format: "R37 gap BOOKED — %.2f U bolus @ reclaim (sync %@); retired if the watch returns", units, sync))
                } else {
                    self.handbackDiag(epoch, String(format: "** R37 gap booking FAILED to save — %.2f U is NOT in the books. Loop is open; dose by hand with that in mind. **", units))
                }
            }
        }
    }

    private static func gapSyncIdentifier(epoch: Int) -> String { "PODLOAN-ODOGAP-e\(epoch)" }

    /// Retry a gap delete that failed on a previous launch. `retireGapBookingIfExplained`
    /// only runs from inside an offer's write completion, and the hand-back ack that stops the
    /// watch's 15 s resend loop goes out BEFORE that retire attempt — so a delete that fails on
    /// its one shot can outlive the offer that would have retried it, with no other trigger left
    /// to fire. This is that other trigger: called once from `init`, it retries against whatever
    /// is persisted, independent of any offer or epoch match, because by the time this runs the
    /// watch may never send another one.
    func retryPersistedGapDeleteIfAny() {
        guard let gap = UserDefaults.standard.dictionary(forKey: Keys.gapBooking),
              let gapEpoch = gap["epoch"] as? Int, let booked = gap["units"] as? Double else { return }
        // RULED 2026-08-15: the placeholder STAYS unless the watch's real records actually
        // arrived. Previously this guard asked only "is a booking persisted", which cannot tell
        // "the delete failed after real records committed" (retry it — the point of this
        // function) from "nothing ever explained this insulin" (the booking is still TRUE). The
        // key is written at booking and cleared only on a successful delete, so the second case
        // is the normal persisted state — and every launch was silently deleting a conservative
        // IOB booking that nothing had replaced, while the user had been told it was there to
        // keep IOB safe. Losing the watch for good is exactly when that margin matters most.
        //
        // The flag is set only in retireGapBookingIfExplained's failure branch, i.e. only after
        // real records committed. An un-flagged booking now stands until either the watch comes
        // back or the dose decays out of the DIA window on its own.
        guard gap["deleteFailedAfterRecords"] as? Bool == true else {
            handbackDiag(gapEpoch, String(format: "R37 gap placeholder STANDS — %.2f U still unexplained; the watch never returned, so the booking is left in place", booked))
            return
        }
        let sync = Self.gapSyncIdentifier(epoch: gapEpoch)
        handbackDiag(gapEpoch, String(format: "R37 gap DELETE retrying at launch — %.2f U placeholder (sync %@) was unretired last session", booked, sync))
        deps.deleteGapDose(sync) { [weak self] ok in
            guard let self = self else { return }
            self.queue.async {
                if ok {
                    UserDefaults.standard.removeObject(forKey: Keys.gapBooking)
                    // A2: a delete is an insulin-history rewrite like any other — the placeholder
                    // was booked AT the reclaim, which by the time this launch-retry runs is well
                    // behind the frontier. Without the prune the counteraction memo keeps the
                    // deleted units baked into its bins.
                    if let bookedAt = (gap["bookedAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)) {
                        self.deps.insulinHistoryRewritten(bookedAt)
                    }
                    self.cancelPlaceholderReminders()
                    self.handbackDiag(gapEpoch, String(format: "R37 gap RETIRED on launch retry — %.2f U placeholder cleared", booked))
                } else {
                    self.handbackDiag(gapEpoch, String(format: "** R37 gap DELETE FAILED AGAIN at launch — %.2f U placeholder still stands; will retry next launch or the next matching offer **", booked))
                }
            }
        }
    }

    /// The watch came back. Its offer just committed the REAL records behind the gap, so
    /// the placeholder retires — full replacement, not a partial offset: the store now carries
    /// the truth-bearing account (validated in aggregate by the odometer at reclaim), and any
    /// residue left is ordinary reconcile noise. Runs AFTER the real doses are written, so the
    /// transition never passes through a state with neither (a brief both is the safe
    /// direction; a gap of neither is not). Keyed on persisted state: duplicate redeliveries
    /// find nothing and no-op. A failed delete keeps the state (retried on the next offer and
    /// at launch) and says so, because a silent failure here is a double-counted IOB.
    func retireGapBookingIfExplained(offerEpoch: Int, dosesJustCommitted: [DoseEntry], carbsJustCommitted: Int) {
        guard let gap = UserDefaults.standard.dictionary(forKey: Keys.gapBooking),
              let gapEpoch = gap["epoch"] as? Int, gapEpoch == offerEpoch,
              let booked = gap["units"] as? Double else { return }
        guard !dosesJustCommitted.isEmpty else { return }   // an empty offer explains nothing
        // The array, not a pre-summed total: `booked` is a bolus-shaped, odometer-derived number,
        // so only bolus units are comparable to it. LoanReconciler mints every dose without
        // deliveredUnits (:193-198, :205-210), which made the old single total ALWAYS gross
        // programmed — rate × FULL clamped window, un-netted against the schedule and untruncated
        // against the next temp. That is the "implied Σ" over-count this file already deleted once
        // (see the note above forceReclaimToOwner), printed here against a real delivered figure.
        // `deliveredUnits ??` survives on the BOLUS sum only: inert today, right the day a record
        // carries one. Rate records get their own column, labelled gross on its face.
        let boluses = dosesJustCommitted.filter { $0.type == .bolus }
        let bolusUnits = boluses.reduce(0.0) { $0 + ($1.deliveredUnits ?? $1.programmedUnits) }
        let rateCount = dosesJustCommitted.count - boluses.count
        let rateGross = dosesJustCommitted.filter { $0.type != .bolus }.reduce(0.0) { $0 + $1.programmedUnits }
        let sync = Self.gapSyncIdentifier(epoch: gapEpoch)
        deps.deleteGapDose(sync) { [weak self] ok in
            guard let self = self else { return }
            self.queue.async {
                if ok {
                    UserDefaults.standard.removeObject(forKey: Keys.gapBooking)
                    // A2: the placeholder is gone from the books, so the counteraction bins that
                    // were computed with it in the insulin curve are wrong from `bookedAt` on.
                    // Same prune as the doses that just replaced it — the pair is one rewrite.
                    if let bookedAt = (gap["bookedAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)) {
                        self.deps.insulinHistoryRewritten(bookedAt)
                    }
                    self.handbackDiag(gapEpoch, String(format:
                        "R37 gap RETIRED — the watch returned with %d real dose(s): %.2f U bolus + %d rate record(s) (%.2f U gross programmed, pre-truncation) and %d carb(s); the %.2f U estimate is replaced by actual timing",
                        dosesJustCommitted.count, bolusUnits, rateCount, rateGross, carbsJustCommitted, booked))
                    // STAYS (ruled 2026-08-15, restoring the 2026-08-14 field request). The
                    // keeps re-review called this a congratulation banner announcing that a
                    // self-healing correction healed, and recommended killing it. That misses
                    // what it is actually for: IOB and COB CHANGE UNDER THE USER'S FEET at this
                    // instant. A numbers-changed notice is not reassurance, and the urgent
                    // channel is right for it.
                    //
                    // The review's real finding stands though — it omits the half the user can
                    // act on, because the loop the audit opened is STILL OPEN and nothing in
                    // this codebase closes it. That sentence is going into the standing
                    // placeholder/open-loop reminder rather than here, so this can stay a short
                    // statement of what just changed.
                    self.cancelPlaceholderReminders()   // the condition is gone
                    self.deps.issueUrgentNotice("Watch Records Recovered",
                                          String(format: "The watch is back. Its records (%d doses, %d carbs) replaced the estimated %.2f U bolus — your IOB and COB now reflect actual timing.",
                                                 dosesJustCommitted.count, carbsJustCommitted, booked))
                } else {
                    // Mark the booking as "real records DID arrive, the delete is what failed".
                    // Only that state earns a launch retry — see retryPersistedGapDeleteIfAny.
                    var marked = gap
                    marked["deleteFailedAfterRecords"] = true
                    UserDefaults.standard.set(marked, forKey: Keys.gapBooking)
                    self.handbackDiag(gapEpoch, String(format:
                        "** R37 gap DELETE FAILED — the %.2f U placeholder AND the real records are both booked; IOB is over-counted until this retries **", booked))
                }
            }
        }
    }

    /// The "don't forget to tighten this" mechanism, built so it cannot be forgotten: bank every
    /// authoritative residual and say in the log how many clean samples exist. A note in a doc
    /// relies on someone re-reading the doc; a line that appears at every hand-back does not.
    /// R32 CLOSED (2026-08-27): the verdict is window-scoped at ±0.20 U and this bank is
    /// DIAGNOSTICS ONLY. The whole-loan series continues for drift trend (it is what proved
    /// the −0.05 U/h truncation bias), and the worst-window series is what any FUTURE band
    /// review reads — it is the distribution the active band actually judges. No nag: the
    /// 2026-08-13 provisional bounds were reviewed and ratified against ~90 field windows
    /// (worst |0.10| noise vs +1.500 signal), and a log line demanding a review that already
    /// happened is the OBS-8 cry-wolf failure.
    func bankResidual(_ residual: Double, worstWindow: Double, epoch: Int) {
        var history = (UserDefaults.standard.array(forKey: Keys.residualHistory) as? [Double]) ?? []
        history.append(residual)
        if history.count > 40 { history.removeFirst(history.count - 40) }
        UserDefaults.standard.set(history, forKey: Keys.residualHistory)

        var windows = (UserDefaults.standard.array(forKey: Keys.windowWorstHistory) as? [Double]) ?? []
        windows.append(worstWindow)
        if windows.count > 40 { windows.removeFirst(windows.count - 40) }
        UserDefaults.standard.set(windows, forKey: Keys.windowWorstHistory)

        let mean = history.reduce(0, +) / Double(history.count)
        let worst = history.map(abs).max() ?? 0
        handbackDiag(epoch, String(format:
            "residual bank: n=%d mean=%+.3f worst=|%.3f| min=%+.3f max=%+.3f · window-worst this loan |%.3f| (series n=%d max |%.3f|) — diagnostics only, R32 closed 2026-08-27 (window verdict ±%.2f U)",
            history.count, mean, worst, history.min() ?? 0, history.max() ?? 0,
            worstWindow, windows.count, windows.map(abs).max() ?? 0,
            Self.openLoopPositiveResidual))
    }

    /// True whenever this phone does NOT own the pod's connection (any non-owner
    /// state — the link is released or in flux). Delivery attempts made here while
    /// true would die in a BLE timeout; callers should refuse loudly instead.
    var isPodLoanedOut: Bool {
        // PHONE MIRROR: the yielded posture shows as Pod on Watch — technically true.
        return queue.sync { state != .owner || yieldingToInferredLoan }
    }

    /// True after state flips to .owner until the pod is truly back on the link
    /// (deps.isConnectionReady) or the settle ceiling elapses — bridging the ~2 min BLE
    /// re-establishment window after reclaimConnection() (which only re-arms the bid). Keeps
    /// "Reclaiming…" up until the pod is actually reachable, without sticking (ceiling) or
    /// misfiring on a later ordinary signal-loss (gated on a recent reclaimStartedAt).
    var isReclaimSettling: Bool {
        return queue.sync {
            guard state == .owner, let started = reclaimStartedAt else { return false }
            if deps.now().timeIntervalSince(started) >= Self.reclaimSettleTimeout { return false }
            // Settling until a pod ROUND-TRIP has landed, not until the peripheral shows
            // .connected — the Bluetooth state flips true seconds after hand-back while the
            // actual return conversation hasn't happened. This is what kept "Reclaiming…"
            // honest AND sticky before; now it clears the moment the round-trip completes,
            // which the chase makes prompt.
            return reclaimVerifiedAt == nil
        }
    }


    // MARK: - The audit base (since-last-sync reconciliation, ruled 2026-08-26)

    /// The audit's anchor: the last pod odometer reading that was RECONCILED against a
    /// complete record set. Every audit — clean hand-back or forced reclaim — judges the
    /// window [base.asOf → end], so a mid-loan sync retires the windows behind it and a
    /// forced reclaim answers "what happened since we last agreed?", not "replay the whole
    /// loan". With no checkpoints the base never leaves the takeover reading, which is
    /// byte-for-byte the old whole-loan behavior — the contactless-loan force-reclaim,
    /// the one case with no choice, is unchanged by construction.
    struct AuditBase {
        let units: Double
        let asOf: Date
    }

    /// The same four-pulse band the verdicts use: a window that reconciles within it is
    /// retired; one that doesn't is CARRIED — the base does not advance past an
    /// unreconciled window, so the discrepancy stays in scope for the next checkpoint or
    /// the final audit rather than being quietly absorbed.
    static let checkpointBand: Double = 0.20

    /// Consider advancing the audit base to a synced odometer reading. Called with the
    /// staged record set already updated by the same message that carried the snapshot,
    /// so "records through this instant" and "odometer at this instant" are paired.
    func considerCheckpoint(_ snap: LoanOdometerSnapshot, context: String) {
        guard let asOf = snap.asOf else { return }          // older watch: whole-loan audit
        guard let base = auditBase else { return }          // no anchor yet: nothing to advance
        guard asOf > base.asOf else { return }              // stale or duplicate reading
        guard snap.deliveredLatest >= base.units else {
            PhoneLog.event("loan", String(format: "e%d [checkpoint] REJECTED (%@): odometer regressed %.3f → %.3f",
                                          epoch, context, base.units, snap.deliveredLatest))
            return
        }
        let events = staged.values
            .filter { !stagedTombstones.contains($0.id) }
            .sorted { $0.seq < $1.seq }
        let expected = LoanReconciler.expectedInsulin(events: events, schedule: deps.settings().basalRateSchedule,
                                                      from: base.asOf, to: asOf,
                                                      includingBolusesAtEnd: false)
        let delivered = snap.deliveredLatest - base.units
        // Milli-unit quantization, same reason as the verdict residual: a window sitting
        // exactly on the band must reconcile, not carry on float representation error.
        let residual = ((delivered - expected) * 1000).rounded() / 1000
        if abs(residual) <= Self.checkpointBand {
            // Count BEFORE the base assignment — the didSet persists the count alongside.
            checkpointsThisLoan += 1
            worstWindowThisLoan = max(worstWindowThisLoan, abs(residual))
            auditBase = AuditBase(units: snap.deliveredLatest, asOf: asOf)
            os_log("Checkpoint ACCEPTED (%{public}@): window %.1f min reconciled (delivered %.3f expected %.3f residual %+.3f) — base → %.3f U",
                   log: log, type: .default, context, asOf.timeIntervalSince(base.asOf) / 60,
                   delivered, expected, residual, snap.deliveredLatest)
            PhoneLog.event("loan", String(format: "e%d [checkpoint] #%d ACCEPTED (%@): %.1f min window, residual %+.3f — base %.3f U",
                                          epoch, checkpointsThisLoan, context,
                                          asOf.timeIntervalSince(base.asOf) / 60, residual, snap.deliveredLatest))
        } else {
            // CARRY, loudly. In-flight delivery, a still-chasing verdict, or a genuinely
            // missing record all look like this mid-window; the final audit (or a later
            // checkpoint over the widened window) renders the verdict with full records.
            os_log("Checkpoint CARRIED (%{public}@): window residual %+.3f exceeds ±%.2f (delivered %.3f expected %.3f) — base stays at %.3f U",
                   log: log, type: .error, context, residual, Self.checkpointBand,
                   delivered, expected, base.units)
            PhoneLog.event("loan", String(format: "e%d [checkpoint] CARRIED (%@): residual %+.3f beyond ±%.2f — window stays open",
                                          epoch, context, residual, Self.checkpointBand))
        }
    }

    /// Everything the odometer audit needs EXCEPT the end reading, held
    /// from the final drain until the phone's own reclaim round-trip lands (seconds later) and can
    /// supply that reading first-hand. See `finishPendingHandbackAudit`.
    struct PendingHandbackAudit {
        enum Flavor: String { case handback, forceReclaim }
        let epoch: Int
        let deliveredAtStart: Double  // the audit base's units — the verdict window's anchor
        let expected: Double          // expected insulin over [base.asOf → end]
        let loanMinutes: Double
        let cycles: Int
        let watchLatest: Double?      // the watch's own end reading, for the fresh-vs-stale delta
        let watchFreshened: Bool
        var flavor: Flavor = .handback
        /// Whole-loan companions (nil when no takeover anchor survived): the banked residual
        /// series and the slow-drift tripwire keep reading the FULL loan even when
        /// checkpoints narrowed the verdict window — a real systematic drip that stays
        /// inside every window band still shows here.
        var takeoverUnits: Double? = nil
        var wholeLoanExpected: Double? = nil
    }


}
