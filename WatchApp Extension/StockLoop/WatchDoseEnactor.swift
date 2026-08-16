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

    /// BG wins the single watch radio. When the
    /// G7 is mid-handshake (the heavy ~8-10s burst), a LOOP enact yields instead of
    /// colliding ("Empty Value") — the stock-shaped loop retries naturally on the next
    /// reading, which is exactly the fresh BG landing. Only the automatic path runs
    /// through this enactor today; a future manual path must NOT defer (user present —
    /// the crude loudDrop==true analog).

    /// While pod/G7 time-separation is active the pod BLE is
    /// orphaned for G7's sake. reclaim it just before dosing; release it just after.
    /// reclaim's completion(true) = pod connected & ready; (false) = couldn't
    /// reconnect in the bounded window → SKIP this automatic dose (pod keeps running
    /// its baseline, loop retries next cycle). Both nil / no-op when that separation is off.
    var reclaimPodForDose: ((@escaping (Bool) -> Void) -> Void)?
    var releasePodAfterDose: (() -> Void)?

    /// Fired with the (rate, duration) the pod just accepted for a temp basal, so the
    /// owner can cache what is running without querying the pod — the link is released seconds later.
    var onTempBasalEnacted: ((_ unitsPerHour: Double, _ duration: TimeInterval) -> Void)?
    /// Shadow ledger: pod-ACCEPTED doses flow to the owner's session timeline.
    var ledgerRecord: ((DoseEntry) -> Void)?

    func enact(recommendation: AutomaticDoseRecommendation, with pumpManager: PumpManager, completion: @escaping (PumpManagerError?) -> Void) {
        dosingQueue.async {
            // BG still wins the radio — but WAIT for the handshake instead of throwing the
            // dose cycle away on a millisecond-scale collision.
            //
            // Reclaim the orphaned pod before dosing (bounded). Safe-fallback on
            // failure: skip the dose — never block, never dose against a pod that
            // isn't confirmed connected. Runs on dosingQueue (not the loop's
            // dataAccessQueue), so the bounded wait can't stall the loop cycle.
            if let reclaim = self.reclaimPodForDose {
                let group = DispatchGroup()
                group.enter()
                var connected = false
                reclaim { ok in connected = ok; group.leave() }
                if group.wait(timeout: .now() + 25) == .timedOut || !connected {
                    SportLog.event("radio", "E4: pod not reconnected — automatic dose SKIPPED (pod runs baseline; loop retries next cycle)")
                    self.releasePodAfterDose?()
                    completion(.communication(nil))   // benign: the loop re-enacts next reading
                    return
                }
            }
            // Always re-release the pod on the way out, whatever the dose result.
            let finish: (PumpManagerError?) -> Void = { err in
                self.releasePodAfterDose?()
                completion(err)
            }

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
                        // Hand the accepted temp to the owner so it can cache what the pod
                        // is running once the link is released (basalDeliveryState goes nil
                        // seconds after release).
                        self.onTempBasalEnacted?(basalAdjustment.unitsPerHour, basalAdjustment.duration)
                        // Shadow ledger: the accepted temp enters the single-owner
                        // timeline (truncating its open predecessor — the journal's rule).
                        let acceptedAt = self.now()
                        self.ledgerRecord?(DoseEntry(
                            type: .tempBasal, startDate: acceptedAt,
                            endDate: acceptedAt.addingTimeInterval(basalAdjustment.duration),
                            value: basalAdjustment.unitsPerHour, unit: .unitsPerHour,
                            decisionId: nil,
                            insulinType: pumpManager.status.insulinType))
                    }
                    doseDispatchGroup.leave()
                }
            }

            doseDispatchGroup.wait()

            guard tempBasalError == nil else {
                finish(tempBasalError)
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
                    } else {
                        // Shadow ledger: point-ish event; DASH delivers ~1.5 U/min.
                        let acceptedAt = self.now()
                        self.ledgerRecord?(DoseEntry(
                            type: .bolus, startDate: acceptedAt,
                            endDate: acceptedAt.addingTimeInterval(bolusUnits / 1.5 * 60),
                            value: bolusUnits, unit: .units,
                            decisionId: nil,
                            insulinType: pumpManager.status.insulinType))
                    }
                    doseDispatchGroup.leave()
                }
            }
            doseDispatchGroup.wait()
            finish(bolusError)
        }
    }
}
