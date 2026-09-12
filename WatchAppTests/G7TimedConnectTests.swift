//
//  G7TimedConnectTests.swift
//  WatchAppTests
//
//  Pins the grid arithmetic behind the timed, bounded connect (G7TimedConnect). The anchor is a
//  READING's own sensor timestamp; the request goes up `fireOffset` seconds after each
//  `period`-spaced grid point, which is ~1 s before the sensor starts advertising.
//

import XCTest
import G7SensorKit

final class G7TimedConnectTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_000_000)

    func testFiresJustAfterTheNextGridPoint() {
        let fire = G7TimedConnect.nextFire(anchor: anchor, now: anchor.addingTimeInterval(100))
        XCTAssertEqual(fire.timeIntervalSince(anchor), G7TimedConnect.period + G7TimedConnect.fireOffset, accuracy: 0.001)
    }

    func testSkipsAGridPointThatIsInsideTheMargin() {
        // 0.5 s before the fire time, with a 1-s margin: too close, take the next one.
        let now = anchor.addingTimeInterval(G7TimedConnect.period + G7TimedConnect.fireOffset - 0.5)
        let fire = G7TimedConnect.nextFire(anchor: anchor, now: now)
        XCTAssertEqual(fire.timeIntervalSince(anchor), 2 * G7TimedConnect.period + G7TimedConnect.fireOffset, accuracy: 0.001)
    }

    func testStaysGridAlignedManyCyclesLater() {
        // A stale anchor is no longer fatal: it is the sensor's own clock, so an anchor hours old
        // still names the grid (crystal drift ≈ 4 s/day against a 5-s bound).
        let now = anchor.addingTimeInterval(47 * G7TimedConnect.period + 12)
        let fire = G7TimedConnect.nextFire(anchor: anchor, now: now)
        XCTAssertEqual(fire.timeIntervalSince(anchor), 48 * G7TimedConnect.period + G7TimedConnect.fireOffset, accuracy: 0.001)
    }

    func testTheRequestWindowStraddlesTheBurstStart() {
        // The sensor starts advertising ≈ 2 s after the reading timestamp (n=20, 2026-09-12
        // overnight: connects at +2.0…+3.1 s). The request must be up BEFORE that and still be
        // up for seconds after it.
        let burstStart = 2.0
        XCTAssertLessThan(G7TimedConnect.fireOffset, burstStart)                      // up before the burst
        XCTAssertGreaterThan(G7TimedConnect.fireOffset + G7TimedConnect.bound,
                             burstStart + 2)                                          // still up 2 s into it
    }

    func testBoundSitsUnderTheDaemonsFastScan() {
        // The -70 is written by a failure more than 6 s after the connect REQUEST. The bound
        // must withdraw the request before that, with margin for timer slop.
        XCTAssertLessThan(G7TimedConnect.bound, 6)
        XCTAssertGreaterThan(G7TimedConnect.fireOffset, 0)
    }
}
