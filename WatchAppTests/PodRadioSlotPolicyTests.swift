//
//  PodRadioSlotPolicyTests.swift
//  WatchAppTests
//
//  The pod-radio slot schedule (2026-09-05 night). Sniffer histograms: the sensor is on the air
//  0→~25 s after a reading and, phone absent, at +60/+120/+180/+240 (±5 s); silent otherwise.
//  bluetoothd gated the sensor at −70 dBm after two links collapsed inside our pod exchange at
//  +20/+25 s. The schedule keeps the pod off the air everywhere the sensor has been seen active.
//

import XCTest
@testable import WatchApp_Extension

final class PodRadioSlotPolicyTests: XCTestCase {

    private typealias S = StockLoopSession.PodRadioSlotPolicy
    private typealias P = StockLoopSession.PodRadioPolicy
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)   // a direct read = a burst

    func testThePodIsHeldThroughTheBurstTheTailAndTheFirstCall() {
        for phase: TimeInterval in [0, 5, 24, 25, 40, 59, 60, 65, 69] {
            XCTAssertNotNil(S.closedRemaining(phase: phase), "phase +\(Int(phase)) s must be closed")
        }
        XCTAssertEqual(S.closedRemaining(phase: 0)!, 70, accuracy: 0.001)
        XCTAssertEqual(S.closedRemaining(phase: 25)!, 45, accuracy: 0.001)
    }

    func testTheFourSlotsAreOpen() {
        for phase: TimeInterval in [70, 90, 109, 130, 150, 169, 190, 210, 229, 250, 265, 279] {
            XCTAssertNil(S.closedRemaining(phase: phase), "phase +\(Int(phase)) s must be open")
        }
    }

    func testEveryMinuteCallIsBlackedOutWithTenSecondsOfMargin() {
        for call: TimeInterval in [120, 180, 240] {
            XCTAssertNil(S.closedRemaining(phase: call - 11))
            XCTAssertNotNil(S.closedRemaining(phase: call - 10))
            XCTAssertNotNil(S.closedRemaining(phase: call))
            XCTAssertNotNil(S.closedRemaining(phase: call + 9))
            XCTAssertNil(S.closedRemaining(phase: call + 10))
        }
        XCTAssertNotNil(S.closedRemaining(phase: 280), "the next window's lead (+280→+300) is closed")
        XCTAssertNotNil(S.closedRemaining(phase: 299))
    }

    func testThePhaseIsTheSensorsAndCarriesThroughMisses() {
        XCTAssertEqual(S.phase(anchor: anchor, now: anchor.addingTimeInterval(30)), 30, accuracy: 0.001)
        XCTAssertEqual(S.phase(anchor: anchor, now: anchor.addingTimeInterval(299)), 299, accuracy: 0.001)
        XCTAssertEqual(S.phase(anchor: anchor, now: anchor.addingTimeInterval(300 + 45)), 45, accuracy: 0.001,
                       "a missed window does not move the phase — skip whole periods on the sensor's grid")
        XCTAssertEqual(S.phase(anchor: anchor, now: anchor.addingTimeInterval(4 * 300 + 200)), 200, accuracy: 0.001)
    }

    func testOnlyTheSlotsPolicyHoldsAndNeverWithoutAnAnchor() {
        let now = anchor.addingTimeInterval(20)
        XCTAssertNotNil(S.closedRemaining(anchor: anchor, now: now, policy: .slots))
        XCTAssertNil(S.closedRemaining(anchor: anchor, now: now, policy: .quietGate), "quietGate keeps the old bracket + gate, not the schedule")
        XCTAssertNil(S.closedRemaining(anchor: anchor, now: now, policy: .off))
        XCTAssertNil(S.closedRemaining(anchor: nil, now: now, policy: .slots), "no direct read yet means no phase — never hold a dose on a guess")
    }

    func testTheDefaultIsThePreviousBehaviour() {
        UserDefaults.standard.removeObject(forKey: P.key)
        XCTAssertEqual(P.current, .quietGate)
        XCTAssertTrue(StockLoopSession.quietWindowEnabled, "the pre-burst bracket stays on under the default")
    }

    func testTheLongestHoldIsSeventySeconds() {
        var worst: TimeInterval = 0
        var p: TimeInterval = 0
        while p < 300 { if let r = S.closedRemaining(phase: p) { worst = max(worst, r) }; p += 0.5 }
        XCTAssertEqual(worst, 70, accuracy: 0.001, "a dose never waits longer than 70 s for the schedule")
    }
}
