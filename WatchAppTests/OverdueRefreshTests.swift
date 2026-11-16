//
//  OverdueRefreshTests.swift
//  WatchAppTests
//
//  Testing only: when the address-hold workaround asks for its background refresh (OverdueRefresh in
//  AddressHold.swift).
//

import XCTest
@testable import WatchApp

final class OverdueRefreshTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testASensorConnectionAsksHalfAMinuteAfterTheNextReadingIsDue() {
        var refresh = OverdueRefresh()
        XCTAssertEqual(refresh.sensorConnected(now: t0), at(330))
        XCTAssertEqual(refresh.readingDue, at(300))
    }

    /// A reading 4 s old at the connection: the request moves from the connection's time to the reading's.
    func testTheReadingsOwnTimeRefinesTheRequest() {
        var refresh = OverdueRefresh()
        _ = refresh.sensorConnected(now: at(4))
        XCTAssertEqual(refresh.readingArrived(taken: t0, now: at(5)), at(330))
        XCTAssertEqual(refresh.readingDue, at(300))
    }

    /// Loan 115, 18:36: a blocked reading arrived 243 s old. The next is due 57 s later, not 5 min later.
    func testAReadingDeliveredLateStillTimesTheNextFromWhenItWasTaken() {
        var refresh = OverdueRefresh()
        _ = refresh.sensorConnected(now: at(243))
        XCTAssertEqual(refresh.readingArrived(taken: t0, now: at(244)), at(330))
    }

    func testBackfillAndFutureReadingsDoNotMoveTheRequest() {
        var refresh = OverdueRefresh()
        _ = refresh.sensorConnected(now: at(600))
        XCTAssertNil(refresh.readingArrived(taken: t0, now: at(601)))
        XCTAssertNil(refresh.readingArrived(taken: at(700), now: at(601)))
        XCTAssertEqual(refresh.readingDue, at(900))
    }

    /// The sensor stays away: 5, 10, then 15 min apart, so no more than four run in an hour.
    func testWhileTheSensorStaysAwayTheRequestsSpreadOut() {
        var refresh = OverdueRefresh()
        _ = refresh.sensorConnected(now: t0)
        XCTAssertEqual(refresh.refreshRan(now: at(340)), at(340 + 300))
        XCTAssertEqual(refresh.refreshRan(now: at(650)), at(650 + 600))
        XCTAssertEqual(refresh.refreshRan(now: at(1260)), at(1260 + 900))
        XCTAssertEqual(refresh.refreshRan(now: at(2170)), at(2170 + 900))
    }

    func testASensorConnectionEndsTheSpreadingOut() {
        var refresh = OverdueRefresh()
        _ = refresh.sensorConnected(now: t0)
        _ = refresh.refreshRan(now: at(340))
        _ = refresh.refreshRan(now: at(650))
        _ = refresh.sensorConnected(now: at(700))
        XCTAssertEqual(refresh.refreshRan(now: at(1040)), at(1040 + 300))
    }
}
