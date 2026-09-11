//
//  G7TimedConnectTests.swift
//  WatchAppTests
//
//  Pins the grid arithmetic behind the timed, bounded connect experiment (G7TimedConnect):
//  fire `lead` seconds before each `period`-spaced grid point, never inside the margin.
//

import XCTest
import G7SensorKit

final class G7TimedConnectTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_000_000)

    func testFiresLeadSecondsBeforeTheNextGridPoint() {
        let fire = G7TimedConnect.nextFire(anchor: anchor, now: anchor.addingTimeInterval(100))
        XCTAssertEqual(fire.timeIntervalSince(anchor), G7TimedConnect.period - G7TimedConnect.lead, accuracy: 0.001)
    }

    func testSkipsAGridPointThatIsInsideTheMargin() {
        // 0.5 s before the fire time, with a 1-s margin: too close, take the next one.
        let now = anchor.addingTimeInterval(G7TimedConnect.period - G7TimedConnect.lead - 0.5)
        let fire = G7TimedConnect.nextFire(anchor: anchor, now: now)
        XCTAssertEqual(fire.timeIntervalSince(anchor), 2 * G7TimedConnect.period - G7TimedConnect.lead, accuracy: 0.001)
    }

    func testStaysGridAlignedManyCyclesLater() {
        let now = anchor.addingTimeInterval(47 * G7TimedConnect.period + 12)
        let fire = G7TimedConnect.nextFire(anchor: anchor, now: now)
        XCTAssertEqual(fire.timeIntervalSince(anchor), 48 * G7TimedConnect.period - G7TimedConnect.lead, accuracy: 0.001)
    }

    func testBoundSitsUnderTheDaemonsFastScan() {
        // The -70 is written by a failure more than 6 s after the connect REQUEST. The bound
        // must withdraw the request before that, with margin for timer slop.
        XCTAssertLessThan(G7TimedConnect.bound, 6)
        XCTAssertGreaterThan(G7TimedConnect.lead, 0)
    }
}
