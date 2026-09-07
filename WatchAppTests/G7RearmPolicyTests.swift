//
//  G7RearmPolicyTests.swift
//  WatchAppTests
//
//  The re-arm delay after the sensor drops the link (2026-09-05). Stock re-issues the next
//  connect() 2 s after the drop; the bench knob can wait 30 s, or arm ~30 s before the next
//  expected burst so Dexcom's own request goes first. Pinned as a pure policy.
//

import XCTest
import G7SensorKit

final class G7RearmPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // a delivery

    func testStockIsTwoSecondsAndDelay30IsThirty() {
        XCTAssertEqual(G7RearmPolicy.delay(mode: .stock, lastDelivery: t0, now: t0.addingTimeInterval(10)), 2)
        XCTAssertEqual(G7RearmPolicy.delay(mode: .delay30, lastDelivery: t0, now: t0.addingTimeInterval(10)), 30)
    }

    func testLateArmWaitsUntilThirtySecondsBeforeTheNextBurst() {
        // Dropped 10 s after the delivery: the next burst is 290 s away, arm 30 s before it.
        let d = G7RearmPolicy.delay(mode: .lateArm, lastDelivery: t0, now: t0.addingTimeInterval(10))
        XCTAssertEqual(d, 300 - 30 - 10, accuracy: 0.001)
    }

    func testLateArmCarriesThroughMissesOnTheSensorsPhase() {
        // 8 minutes after the last delivery (one burst already missed): aim at the one after.
        let d = G7RearmPolicy.delay(mode: .lateArm, lastDelivery: t0, now: t0.addingTimeInterval(8 * 60))
        XCTAssertEqual(d, 2 * 300 - 30 - 8 * 60, accuracy: 0.001)
        XCTAssertGreaterThan(d, 2, "never re-arm immediately by accident while chasing the phase")
    }

    func testLateArmNeverWaitsLongerThanOnePeriodOrLessThanTwoSeconds() {
        // Just past the arm point: the target is the next period's arm point, under 300 s.
        let d = G7RearmPolicy.delay(mode: .lateArm, lastDelivery: t0, now: t0.addingTimeInterval(271))
        XCTAssertLessThanOrEqual(d, 300)
        XCTAssertGreaterThanOrEqual(d, 2)
    }

    func testLateArmWithoutADeliveryFallsBackToThirtySeconds() {
        XCTAssertEqual(G7RearmPolicy.delay(mode: .lateArm, lastDelivery: nil, now: t0), 30,
                       "no phase known yet — do not sit unarmed for a full period")
    }

    func testTheKnobDefaultsToStock() {
        UserDefaults.standard.removeObject(forKey: G7RearmPolicy.key)
        XCTAssertEqual(G7RearmPolicy.current, .stock)
    }
}
