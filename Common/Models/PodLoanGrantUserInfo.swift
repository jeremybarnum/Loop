//
//  PodLoanGrantUserInfo.swift
//  Loop
//
//  Phone → watch, sent as the reply to a PodLoanRequestUserInfo. Either GRANTS
//  the loan (carrying the pod identity the watch needs to take the pod over —
//  the same fields OmniBLECore's takeover path consumes: LTK, controllerId,
//  podId, podAddress, messageNumber) or DENIES it with a reason (e.g. no active
//  pod, pod already suspended for another reason).
//
//  Fixed-width identifiers cross the WatchConnectivity boundary as Int (they
//  fit in UInt32 and Int↔NSNumber bridging is reliable), then are rebuilt as
//  UInt32. The 16-byte LTK crosses as Data.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

struct PodLoanGrantUserInfo {
    let version = 1
    let granted: Bool

    // Present iff granted.
    let ltk: Data?
    let controllerId: UInt32?
    let podId: UInt32?
    let podAddress: UInt32?
    let messageNumber: Int?

    // Present iff !granted.
    let denialReason: String?

    static func grant(ltk: Data, controllerId: UInt32, podId: UInt32, podAddress: UInt32, messageNumber: Int) -> PodLoanGrantUserInfo {
        PodLoanGrantUserInfo(granted: true,
                             ltk: ltk,
                             controllerId: controllerId,
                             podId: podId,
                             podAddress: podAddress,
                             messageNumber: messageNumber,
                             denialReason: nil)
    }

    static func denied(reason: String) -> PodLoanGrantUserInfo {
        PodLoanGrantUserInfo(granted: false,
                             ltk: nil,
                             controllerId: nil,
                             podId: nil,
                             podAddress: nil,
                             messageNumber: nil,
                             denialReason: reason)
    }
}

extension PodLoanGrantUserInfo: RawRepresentable {
    typealias RawValue = [String: Any]

    static let name = "PodLoanGrantUserInfo"

    init?(rawValue: RawValue) {
        guard
            rawValue["v"] as? Int == version,
            rawValue["name"] as? String == PodLoanGrantUserInfo.name,
            let granted = rawValue["g"] as? Bool
            else {
                return nil
        }

        self.granted = granted

        if granted {
            guard
                let ltk = rawValue["ltk"] as? Data,
                let controllerId = rawValue["cid"] as? Int,
                let podId = rawValue["pid"] as? Int,
                let podAddress = rawValue["addr"] as? Int,
                let messageNumber = rawValue["mn"] as? Int
                else {
                    return nil
            }

            self.ltk = ltk
            self.controllerId = UInt32(truncatingIfNeeded: controllerId)
            self.podId = UInt32(truncatingIfNeeded: podId)
            self.podAddress = UInt32(truncatingIfNeeded: podAddress)
            self.messageNumber = messageNumber
            self.denialReason = nil
        } else {
            self.ltk = nil
            self.controllerId = nil
            self.podId = nil
            self.podAddress = nil
            self.messageNumber = nil
            self.denialReason = rawValue["dr"] as? String
        }
    }

    var rawValue: RawValue {
        var raw: RawValue = [
            "v": version,
            "name": PodLoanGrantUserInfo.name,
            "g": granted
        ]

        if granted {
            raw["ltk"] = ltk
            raw["cid"] = controllerId.map { Int($0) }
            raw["pid"] = podId.map { Int($0) }
            raw["addr"] = podAddress.map { Int($0) }
            raw["mn"] = messageNumber
        } else {
            raw["dr"] = denialReason
        }

        return raw
    }
}
