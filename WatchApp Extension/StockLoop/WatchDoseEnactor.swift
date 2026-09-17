//
//  WatchDoseEnactor.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  Split out of WatchLoopManager.swift unchanged. Stock keeps this in its own file
//  (Loop/Managers/DoseEnactor.swift) and the section had always been marked as mirroring it;
//  the two were only sharing a file. Nothing here differs from the version that lived there.
//

import Foundation
import LoopKit
import LoopAlgorithm
import os.log

// MARK: - Dose enactor (mirrors Loop/Managers/DoseEnactor.swift)

/// Same sequencing as the phone's DoseEnactor: temp-basal adjustment first, wait, then any
/// automatic bolus — all through stock `PumpManager` protocol methods, so pulse-grid
/// snapping, cancel-before-program, busy handling, and uncertain-delivery classification are
/// the stock driver's (OmniPumpManager), not ours.
final class WatchDoseEnactor {

    /// This class records dose timestamps into the ledger, so it
    /// needs its own clock seam — it is a separate type from WatchLoopManager and cannot
    /// reach that one. WatchLoopManager keeps the two in sync when it builds the enactor.
    var now: () -> Date = Date.init

    private let dosingQueue = DispatchQueue(label: "com.loopkit.Loop.WatchDoseEnactor", qos: .utility)

    private let log = OSLog(category: "WatchDoseEnactor")

    /// The loan controller's intent-minting hooks. nil outside a loan;
    /// the enact calls themselves are unchanged stock PumpManager methods either way.
    weak var loanRecorder: WatchLoanDoseRecording?

    func enact(recommendation: AutomaticDoseRecommendation, with pumpManager: PumpManager, completion: @escaping (PumpManagerError?) -> Void) {
        dosingQueue.async {
            let doseDispatchGroup = DispatchGroup()

            var tempBasalError: PumpManagerError? = nil
            var bolusError: PumpManagerError? = nil

            // A recommendation always carries a basal now. "Leave the running basal alone" is
            // no longer expressed by an absent adjustment — the loop simply declines to produce
            // a recommendation at all, and this method is never called. So reaching here means
            // a basal command really is intended.
            do {
                let basalAdjustment = recommendation.basalAdjustment
                self.log.default("Enacting recommended basal change")
                // What the pod is ACTUALLY being told, and whether it took it. Without
                // this line the field log shows a reclaim and a released pod with no way
                // to tell whether a command went out at all.
                SportLog.event("dose", String(format: "enacting temp %.2f U/hr × %.0f min", basalAdjustment.unitsPerHour, basalAdjustment.duration / 60))
                doseDispatchGroup.enter()
                let eventID = self.loanRecorder?.loanWillEnactTempBasal(unitsPerHour: basalAdjustment.unitsPerHour, duration: basalAdjustment.duration)
                pumpManager.enactTempBasal(decisionId: nil, unitsPerHour: basalAdjustment.unitsPerHour, for: basalAdjustment.duration) { error in
                    self.loanRecorder?.loanDidEnact(eventID: eventID, error: error)
                    if let error = error {
                        tempBasalError = error
                        SportLog.event("dose", "temp enact FAILED — \(String(describing: error))")
                    } else {
                        SportLog.event("dose", String(format: "temp %.2f U/hr ACCEPTED by pod", basalAdjustment.unitsPerHour))
                        // The pump manager books it: the session that carried this command ends
                        // with dosesForStorage → the watch's DoseStore, the one insulin book.
                    }
                    doseDispatchGroup.leave()
                }
            }

            doseDispatchGroup.wait()

            guard tempBasalError == nil else {
                completion(tempBasalError)
                return
            }

            if let bolusUnits = recommendation.bolusUnits, bolusUnits > 0 {
                self.log.default("Enacting recommended bolus dose")
                doseDispatchGroup.enter()
                let eventID = self.loanRecorder?.loanWillEnactBolus(units: bolusUnits)
                pumpManager.enactBolus(decisionId: nil, units: bolusUnits, activationType: .automatic) { error in
                    self.loanRecorder?.loanDidEnact(eventID: eventID, error: error)
                    if let error = error {
                        bolusError = error
                    }
                    doseDispatchGroup.leave()
                }
            }
            doseDispatchGroup.wait()
            completion(bolusError)
        }
    }
}
