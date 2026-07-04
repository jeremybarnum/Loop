//
//  PodLoanRequestUserInfo.swift
//  Loop
//
//  Watch → phone. Sent as a WCSession message (with reply handler) when the
//  watch wants to borrow the pod for a workout while the phone is away. The
//  phone replies with a PodLoanGrantUserInfo carrying the pod identity (or a
//  denial). See docs/LOOP_WATCHAPP_INTEGRATION.md in the WatchPodSandbox.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

struct PodLoanRequestUserInfo {
    let version = 1
    let requestedAt: Date
}

extension PodLoanRequestUserInfo: RawRepresentable {
    typealias RawValue = [String: Any]

    static let name = "PodLoanRequestUserInfo"

    init?(rawValue: RawValue) {
        guard
            rawValue["v"] as? Int == version,
            rawValue["name"] as? String == PodLoanRequestUserInfo.name,
            let requestedAt = rawValue["ra"] as? Date
            else {
                return nil
        }

        self.requestedAt = requestedAt
    }

    var rawValue: RawValue {
        return [
            "v": version,
            "name": PodLoanRequestUserInfo.name,
            "ra": requestedAt
        ]
    }
}
