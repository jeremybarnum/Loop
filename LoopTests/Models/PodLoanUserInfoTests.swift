//
//  PodLoanUserInfoTests.swift
//  LoopTests
//
//  Tests for the three WatchConnectivity message types that carry the pod
//  loan/handback across the phone↔watch boundary.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest

@testable import Loop

class PodLoanRequestUserInfoTests: XCTestCase {
    private lazy var requestedAt = Date(timeIntervalSinceReferenceDate: 0)
    private lazy var rawValue: PodLoanRequestUserInfo.RawValue = [
        "v": 1,
        "name": "PodLoanRequestUserInfo",
        "ra": requestedAt,
    ]

    func testDefaultInitializer() {
        let info = PodLoanRequestUserInfo(requestedAt: requestedAt)
        XCTAssertEqual(info.version, 1)
        XCTAssertEqual(info.requestedAt, requestedAt)
    }

    func testRawValueRoundTrip() {
        let info = PodLoanRequestUserInfo(rawValue: PodLoanRequestUserInfo(requestedAt: requestedAt).rawValue)
        XCTAssertEqual(info?.requestedAt, requestedAt)
    }

    func testRawValueInitializerInvalidVersion() {
        var rawValue = self.rawValue
        rawValue["v"] = 2
        XCTAssertNil(PodLoanRequestUserInfo(rawValue: rawValue))
    }

    func testRawValueInitializerInvalidName() {
        var rawValue = self.rawValue
        rawValue["name"] = "Invalid"
        XCTAssertNil(PodLoanRequestUserInfo(rawValue: rawValue))
    }

    func testRawValueInitializerMissingRequestedAt() {
        var rawValue = self.rawValue
        rawValue["ra"] = nil
        XCTAssertNil(PodLoanRequestUserInfo(rawValue: rawValue))
    }
}

class PodLoanGrantUserInfoTests: XCTestCase {
    private let ltk = Data((0..<16).map { UInt8($0) })
    private let controllerId: UInt32 = 0x17AE45F4
    private let podId: UInt32 = 0x17AE45F5
    private let podAddress: UInt32 = 0x17AE45F5
    private let messageNumber = 15

    func testGrantRoundTripPreservesIdentity() {
        let grant = PodLoanGrantUserInfo.grant(ltk: ltk,
                                               controllerId: controllerId,
                                               podId: podId,
                                               podAddress: podAddress,
                                               messageNumber: messageNumber)
        guard let decoded = PodLoanGrantUserInfo(rawValue: grant.rawValue) else {
            return XCTFail("grant failed to round-trip")
        }
        XCTAssertTrue(decoded.granted)
        XCTAssertEqual(decoded.ltk, ltk)
        XCTAssertEqual(decoded.controllerId, controllerId)
        XCTAssertEqual(decoded.podId, podId)
        XCTAssertEqual(decoded.podAddress, podAddress)
        XCTAssertEqual(decoded.messageNumber, messageNumber)
        XCTAssertNil(decoded.denialReason)
    }

    func testHighBitIdentifierSurvivesIntBridging() {
        // controllerId with the high bit set must not be mangled crossing as Int.
        let big: UInt32 = 0xFFFF_FFFE
        let grant = PodLoanGrantUserInfo.grant(ltk: ltk, controllerId: big, podId: big, podAddress: big, messageNumber: 0)
        let decoded = PodLoanGrantUserInfo(rawValue: grant.rawValue)
        XCTAssertEqual(decoded?.controllerId, big)
        XCTAssertEqual(decoded?.podAddress, big)
    }

    func testDenialRoundTrip() {
        let denied = PodLoanGrantUserInfo.denied(reason: "No active pod")
        guard let decoded = PodLoanGrantUserInfo(rawValue: denied.rawValue) else {
            return XCTFail("denial failed to round-trip")
        }
        XCTAssertFalse(decoded.granted)
        XCTAssertEqual(decoded.denialReason, "No active pod")
        XCTAssertNil(decoded.ltk)
        XCTAssertNil(decoded.controllerId)
    }

    func testGrantMissingIdentityFieldIsRejected() {
        var raw = PodLoanGrantUserInfo.grant(ltk: ltk, controllerId: controllerId, podId: podId, podAddress: podAddress, messageNumber: messageNumber).rawValue
        raw["ltk"] = nil
        XCTAssertNil(PodLoanGrantUserInfo(rawValue: raw))
    }

    func testInvalidVersionRejected() {
        var raw = PodLoanGrantUserInfo.denied(reason: "x").rawValue
        raw["v"] = 2
        XCTAssertNil(PodLoanGrantUserInfo(rawValue: raw))
    }

    func testInvalidNameRejected() {
        var raw = PodLoanGrantUserInfo.denied(reason: "x").rawValue
        raw["name"] = "Invalid"
        XCTAssertNil(PodLoanGrantUserInfo(rawValue: raw))
    }
}

class PodHandbackUserInfoTests: XCTestCase {
    private lazy var handedBackAt = Date(timeIntervalSinceReferenceDate: 0)
    private let summary = "Delivered 1.5 U in 3 boluses"
    private let journalData = Data("{\"any\":\"json\"}".utf8)
    private lazy var rawValue: PodHandbackUserInfo.RawValue = [
        "v": 1,
        "name": "PodHandbackUserInfo",
        "hb": handedBackAt,
        "sm": summary,
        "jd": journalData,
    ]

    func testRoundTripPreservesSummaryAndJournalData() {
        let info = PodHandbackUserInfo(handedBackAt: handedBackAt, summary: summary, journalData: journalData)
        let decoded = PodHandbackUserInfo(rawValue: info.rawValue)
        XCTAssertEqual(decoded?.handedBackAt, handedBackAt)
        XCTAssertEqual(decoded?.summary, summary)
        XCTAssertEqual(decoded?.journalData, journalData)
    }

    func testMissingSummaryRejected() {
        var rawValue = self.rawValue
        rawValue["sm"] = nil
        XCTAssertNil(PodHandbackUserInfo(rawValue: rawValue))
    }

    func testInvalidVersionRejected() {
        var rawValue = self.rawValue
        rawValue["v"] = 2
        XCTAssertNil(PodHandbackUserInfo(rawValue: rawValue))
    }

    func testInvalidNameRejected() {
        var rawValue = self.rawValue
        rawValue["name"] = "Invalid"
        XCTAssertNil(PodHandbackUserInfo(rawValue: rawValue))
    }

    func testMissingJournalDataRejected() {
        var rawValue = self.rawValue
        rawValue["jd"] = nil
        XCTAssertNil(PodHandbackUserInfo(rawValue: rawValue))
    }
}
