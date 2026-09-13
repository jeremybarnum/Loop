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

    func testTheRequestSitsInsideTheBurst() {
        // The sensor starts advertising +2.0…+3.2 s after the reading timestamp (61 cycles,
        // 2026-09-12) and keeps going ≥ 7 s. Being late is free (a mid-burst request completes
        // in ~0.03 s); being early wastes window. So the request goes up at the burst start and
        // the whole bound sits inside the shortest burst.
        let burstStart = 2.0, burstEnd = 9.0
        XCTAssertGreaterThanOrEqual(G7TimedConnect.fireOffset, burstStart)
        XCTAssertLessThanOrEqual(G7TimedConnect.fireOffset + G7TimedConnect.bound, burstEnd)
    }

    func testEveryAskIsWithdrawnInsideTheDaemonsFastScan() {
        // The -70 is written by a failure more than 6 s after the connect REQUEST. Every request
        // of ours — grid ask, second ask, retry — must be withdrawn before that, so a refusal can
        // add to the daemon's COUNT but can never park the floor.
        XCTAssertLessThan(G7TimedConnect.bound, 6)
        XCTAssertGreaterThan(G7TimedConnect.secondAskDelay, 0)
        XCTAssertLessThan(G7TimedConnect.secondAskDelay, 2)   // the burst must still be on the air
    }
}
