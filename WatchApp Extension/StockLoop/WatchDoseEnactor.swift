//
//  WatchDoseEnactor.swift
//  WatchApp Extension
//
//  A COPY of Loop/Managers/DoseEnactor.swift (stock, 17 lines), differing only in its logger:
//  stock's DiagnosticLog pulls the phone's SharedLogging into the target, so this uses os.log.
//  Same API, same order — temp first, then bolus. Keep it in step with the original.
//

import Foundation
import LoopKit
import LoopAlgorithm
import os.log

class WatchDoseEnactor {
    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "DoseEnactor")

    func enact(decisionId: UUID?, bolus: Double?, tempBasal: TempBasalRecommendation?, with pumpManager: PumpManager) async throws {
        if let tempBasal {
            self.log.default("Enacting recommended basal change")
            try await pumpManager.enactTempBasal(decisionId: decisionId, unitsPerHour: tempBasal.unitsPerHour, for: tempBasal.duration)
        }
        if let bolus, bolus > 0 {
            self.log.default("Enacting recommended bolus dose")
            try await pumpManager.enactBolus(decisionId: decisionId, units: bolus, activationType: .automatic)
        }
    }
}
