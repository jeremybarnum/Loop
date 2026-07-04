//
//  PodHandbackUserInfo.swift
//  Loop
//
//  Watch → phone. Sent when the watch hands the pod back (end of workout). It
//  carries the loan journal — what the watch actually did while it held the pod
//  (boluses, suspend/resume windows, pod-delivered cross-check) — as its
//  encoded JSON (PodLoanJournal.encoded()). The phone re-establishes its own
//  pod session and shows the user this summary (Phase 1); later it can reconcile
//  the delivery into IOB (Phase 2, see docs/IOB_RECONCILIATION.md).
//
//  The journal crosses as opaque Data so this type needs no OmniBLECore
//  dependency; whichever side has OmniBLECore linked decodes it.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

struct PodHandbackUserInfo {
    let version = 1
    let handedBackAt: Date
    /// PodLoanJournal.encoded() — JSON. Decoded with PodLoanJournal(data:) on
    /// the phone, which links OmniBLECore.
    let journalData: Data
}

extension PodHandbackUserInfo: RawRepresentable {
    typealias RawValue = [String: Any]

    static let name = "PodHandbackUserInfo"

    init?(rawValue: RawValue) {
        guard
            rawValue["v"] as? Int == version,
            rawValue["name"] as? String == PodHandbackUserInfo.name,
            let handedBackAt = rawValue["hb"] as? Date,
            let journalData = rawValue["jd"] as? Data
            else {
                return nil
        }

        self.handedBackAt = handedBackAt
        self.journalData = journalData
    }

    var rawValue: RawValue {
        return [
            "v": version,
            "name": PodHandbackUserInfo.name,
            "hb": handedBackAt,
            "jd": journalData
        ]
    }
}
