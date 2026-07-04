//
//  PodLoanIdentityTests.swift
//  LoopTests
//
//  Verifies that PodLoanIdentity extracts the pod keys out of an OmniBLE-shaped
//  pump rawState dictionary, and denies cleanly when there's no active pod.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest

@testable import Loop

class PodLoanIdentityTests: XCTestCase {
    // A rawState shaped like OmniBLEPumpManagerState.rawValue for an active pod.
    private func rawState(ltk: String = "000102030405060708090a0b0c0d0e0f",
                          controllerId: UInt32 = 0x17AE45F4,
                          podId: UInt32 = 0x17AE45F5,
                          address: UInt32 = 0x17AE45F5,
                          messageNumber: Int = 15) -> [String: Any] {
        return [
            "controllerId": controllerId,
            "podId": podId,
            "podState": [
                "address": address,
                "ltk": ltk,
                "messageTransportState": [
                    "messageNumber": messageNumber,
                    "eapSeq": 1,
                ],
            ],
        ]
    }

    func testExtractsIdentityFromActivePod() {
        let grant = PodLoanIdentity.grant(fromPumpManagerRawState: rawState())
        XCTAssertTrue(grant.granted)
        XCTAssertEqual(grant.ltk, Data([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]))
        XCTAssertEqual(grant.controllerId, 0x17AE45F4)
        XCTAssertEqual(grant.podId, 0x17AE45F5)
        XCTAssertEqual(grant.podAddress, 0x17AE45F5)
        XCTAssertEqual(grant.messageNumber, 15)
        XCTAssertNil(grant.denialReason)
    }

    func testGrantRoundTripsThroughWireFormat() {
        // The grant the phone builds must survive the WC [String: Any] round trip
        // the watch will decode it from.
        let grant = PodLoanIdentity.grant(fromPumpManagerRawState: rawState())
        let decoded = PodLoanGrantUserInfo(rawValue: grant.rawValue)
        XCTAssertEqual(decoded?.ltk, grant.ltk)
        XCTAssertEqual(decoded?.controllerId, grant.controllerId)
        XCTAssertEqual(decoded?.podAddress, grant.podAddress)
        XCTAssertEqual(decoded?.messageNumber, grant.messageNumber)
    }

    func testNilRawStateDenied() {
        let grant = PodLoanIdentity.grant(fromPumpManagerRawState: nil)
        XCTAssertFalse(grant.granted)
        XCTAssertEqual(grant.denialReason, "No pump configured")
    }

    func testNoActivePodDenied() {
        // A pump with no pod paired: rawState has no "podState".
        let grant = PodLoanIdentity.grant(fromPumpManagerRawState: ["controllerId": UInt32(1)])
        XCTAssertFalse(grant.granted)
        XCTAssertEqual(grant.denialReason, "No active pod")
    }

    func testIncompletePodStateDenied() {
        var raw = rawState()
        var podState = raw["podState"] as! [String: Any]
        podState["ltk"] = nil
        raw["podState"] = podState
        let grant = PodLoanIdentity.grant(fromPumpManagerRawState: raw)
        XCTAssertFalse(grant.granted)
        XCTAssertEqual(grant.denialReason, "Pod state incomplete")
    }

    func testOddLengthLtkHexDenied() {
        let grant = PodLoanIdentity.grant(fromPumpManagerRawState: rawState(ltk: "abc"))
        XCTAssertFalse(grant.granted)
        XCTAssertEqual(grant.denialReason, "Pod state incomplete")
    }
}
