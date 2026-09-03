//
//  ScanArmPolicyTests.swift
//  WatchAppTests
//
//  The arm decision behind the 20-40 minute outage fix (ported by content from next-dev
//  8c45b1a, 2026-09-02). Pre-fix the scan was armed only with nothing adopted; an adopted
//  sensor's disconnect left a bare pending connect and no scan — the lottery that produced
//  30 minutes of silence on 2026-09-02. Pinned as a pure predicate so the policy is testable
//  without CoreBluetooth, and so the legacy arm stays available for the bench A/B.
//

import XCTest
import CoreBluetooth
import G7SensorKit

final class ScanArmPolicyTests: XCTestCase {

    func testNothingAdoptedAlwaysArms() {
        XCTAssertTrue(G7ScanArmPolicy.shouldArmScan(peripheralState: nil, scanWhilePending: true))
        XCTAssertTrue(G7ScanArmPolicy.shouldArmScan(peripheralState: nil, scanWhilePending: false))
    }

    func testAdoptedButDisconnectedArmsOnlyWithTheFix() {
        XCTAssertTrue(G7ScanArmPolicy.shouldArmScan(peripheralState: .disconnected, scanWhilePending: true),
                      "the 2026-09-02 mute: adopted sensor, disconnected, pending connect — the fix arms the scan here")
        XCTAssertFalse(G7ScanArmPolicy.shouldArmScan(peripheralState: .disconnected, scanWhilePending: false),
                       "legacy policy: adopted → never re-arm (the pre-fix behavior, kept for the bench A/B)")
    }

    func testPendingConnectStillArmsWithTheFix() {
        XCTAssertTrue(G7ScanArmPolicy.shouldArmScan(peripheralState: .connecting, scanWhilePending: true),
                      "scan-while-PENDING is the whole point: the pending connect and the armed scan coexist")
    }

    func testConnectedNeverArms() {
        XCTAssertFalse(G7ScanArmPolicy.shouldArmScan(peripheralState: .connected, scanWhilePending: true))
        XCTAssertFalse(G7ScanArmPolicy.shouldArmScan(peripheralState: .connected, scanWhilePending: false))
    }
}
