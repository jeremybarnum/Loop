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

extension PodLoanWatchController {
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

    private static func loanRecord(for dose: DoseEntry, raw: Data) -> LoanDoseRecord? {
        let identity = raw.map { String(format: "%02x", $0) }.joined()
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

    func loanDidRecordOverride(_ override: TemporaryScheduleOverride?) {
        let name = override.map { $0.context.presetNameForLog } ?? "cleared"
        queue.async {
            guard self.phase == .active else {
                SportLog.event("override", "NOT JOURNALED (\(name)) — no active loan (phase \(self.phase.rawValue)); the stock phone path owns it")
                return
            }
            guard self.phoneSupportsOverrideRecords else {
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
