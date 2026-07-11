//
//  PodLoanDoseBridge.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import OmniBLECore

extension PodLoanJournal {
    /// The loan session's deliveries as LoopKit DoseEntries, for the watch
    /// prediction algorithm (LoopAlgorithm.generatePrediction input).
    ///
    /// Boluses map directly. Spans where delivery differed from the pod's
    /// schedule — a temp basal or a suspend — become tempBasal entries at the
    /// actual rate (a suspend is a 0 U/hr temp); the algorithm's basal
    /// annotation nets them against the schedule, the same semantics as
    /// netBasalIOB. Time following the schedule is omitted: it nets to zero,
    /// and the phone-supplied basal timeline covers it.
    ///
    /// An active temp basal at `end` is included through `end` only. Pass the
    /// journal's current temp separately as the recommendation's lastTempBasal
    /// so continuation logic sees its full extent.
    func doseEntries(until end: Date = Date(), insulinType: InsulinType? = nil) -> [DoseEntry] {
        var entries: [DoseEntry] = []

        for event in events where event.date < end {
            if case .bolus(let units) = event.kind {
                entries.append(DoseEntry(
                    type: .bolus,
                    startDate: event.date,
                    endDate: event.date,
                    value: units,
                    unit: .units,
                    insulinType: insulinType))
            }
        }

        for segment in offScheduleSegments(until: end) {
            entries.append(DoseEntry(
                type: .tempBasal,
                startDate: segment.start,
                endDate: segment.end,
                value: segment.actualRate,
                unit: .unitsPerHour,
                insulinType: insulinType))
        }

        return entries.sorted { $0.startDate < $1.startDate }
    }
}
