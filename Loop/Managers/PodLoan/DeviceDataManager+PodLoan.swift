//
//  DeviceDataManager+PodLoan.swift
//  Loop
//
//  The pod loan's read/act surface on DeviceDataManager: everything the UI asks about a loan,
//  and the one action it can take. Kept out of DeviceDataManager.swift so the stock file holds
//  only the `watchManager` back-reference these reads travel through.
//

import Foundation
import LoopKit

// MARK: - Pod loan (client API)

extension DeviceDataManager {
    /// Revoke the watch's loan and bring the pod home. Dosing stays paused until the records
    /// the watch is holding have been reconciled.
    func reclaimPodLoanFromWatch() {
        watchManager?.podLoanController.reclaimNow()
    }

    /// Any non-owner state. Never blocks on the loan queue: the tile draws from main.
    var isPodLoanedToWatch: Bool {
        watchManager?.podLoanController.isPodLoanedOutForUI ?? false
    }

    /// Grant sent, takeover not yet confirmed: the outbound half of the handover.
    var isPodTakeoverInProgress: Bool {
        watchManager?.podLoanController.isPodTakeoverInProgressForUI ?? false
    }

    /// Includes the settle window, while the pod's link is still coming back.
    var isPodLoanReclaiming: Bool {
        watchManager?.podLoanController.isReclaimActivityForUI ?? false
    }

    var podReclaimProgress: PodLoanPhoneController.ReclaimProgress? {
        watchManager?.podLoanController.reclaimProgressForUI
    }
}
