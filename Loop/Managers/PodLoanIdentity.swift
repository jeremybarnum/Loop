//
//  PodLoanIdentity.swift
//  Loop
//
//  Builds a PodLoanGrantUserInfo by reading the active Omnipod DASH pod's
//  identity out of the pump manager's rawState — the public
//  PumpManager.rawState dictionary Loop already uses to persist/restore the
//  pump. This is how the phone hands the watch the keys it needs to take the
//  pod over, WITHOUT importing OmniBLE (which is a runtime plugin, not linked
//  into the Loop app) and without any changes to the OmniBLE driver.
//
//  The five fields the watch's takeover consumes live here in rawState:
//    rawState["controllerId"]                                    -> UInt32
//    rawState["podId"]                                           -> UInt32
//    rawState["podState"]["address"]                             -> UInt32
//    rawState["podState"]["ltk"]                                 -> hex String
//    rawState["podState"]["messageTransportState"]["messageNumber"] -> Int
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

enum PodLoanIdentity {
    /// Build a loan grant from an OmniBLE pump manager's rawState, or a denial
    /// if there is no active pod / the state is missing a required field.
    static func grant(fromPumpManagerRawState rawState: [String: Any]?) -> PodLoanGrantUserInfo {
        guard let rawState = rawState else {
            return .denied(reason: "No pump configured")
        }
        guard let podState = rawState["podState"] as? [String: Any] else {
            return .denied(reason: "No active pod")
        }
        guard
            let ltkHex = podState["ltk"] as? String,
            let ltk = Data(podLoanHexString: ltkHex),
            let podAddress = podState["address"] as? UInt32,
            let messageTransportState = podState["messageTransportState"] as? [String: Any],
            let messageNumber = messageTransportState["messageNumber"] as? Int
        else {
            return .denied(reason: "Pod state incomplete")
        }

        // controllerId is stored at the top level of the pump state; podId falls
        // back to the pod address (they are equal for a DASH pod).
        let controllerId = rawState["controllerId"] as? UInt32 ?? 0
        let podId = rawState["podId"] as? UInt32 ?? podAddress

        return .grant(ltk: ltk,
                      controllerId: controllerId,
                      podId: podId,
                      podAddress: podAddress,
                      messageNumber: messageNumber)
    }
}

private extension Data {
    /// Decodes a hex string (as OmniBLE serializes the LTK via
    /// Data.hexadecimalString). Returns nil on odd length or non-hex chars.
    init?(podLoanHexString hex: String) {
        let characters = Array(hex)
        guard characters.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard
                let high = characters[index].hexDigitValue,
                let low = characters[index + 1].hexDigitValue
            else {
                return nil
            }
            bytes.append(UInt8(high << 4 | low))
            index += 2
        }
        self = Data(bytes)
    }
}
