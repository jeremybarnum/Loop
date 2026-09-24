//
//  WCSilenceAndWindowTests.swift
//  WatchAppTests
//
//  The 2026-09-04 diagnosis build: the WC-silence gate (a phone-away loan hands
//  WatchConnectivity nothing while the bench switch is on) and the G7 window monitor's
//  verdict rule (one HIT/MISS line per expected sensor burst). Both pinned as pure decisions
//  so the meaning of the switch and of the log line cannot drift silently.
//

import XCTest
@testable import WatchApp_Extension

final class WCSilenceAndWindowTests: XCTestCase {

    // MARK: WC silence

    func testTheGateSuppressesExactlyWhenTheSwitchIsOn() {
        XCTAssertTrue(StockLoopSession.WCSilence.shouldSuppress(enabled: true))
        XCTAssertFalse(StockLoopSession.WCSilence.shouldSuppress(enabled: false),
                       "with the switch off every send must go through — the A arms of the A/B/A depend on it")
    }

    func testTheSwitchIsOffUnlessSomebodySetIt() {
        UserDefaults.standard.removeObject(forKey: StockLoopSession.WCSilence.key)
        XCTAssertFalse(StockLoopSession.WCSilence.enabled, "a diagnosis switch must never be on by default")
    }

    // MARK: G7 window verdict

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAReadingJustAfterTheBurstIsAHit() {
        XCTAssertEqual(StockLoopSession.G7WindowPolicy.verdict(lastDirect: t0.addingTimeInterval(5), expectedBurst: t0), "HIT")
    }

    func testABetweenBurstConnectUpToAMinuteLateStillBelongsToItsWindow() {
        // 2026-09-03 23:37:36: connected 62 s after the 23:36:34 burst, reading age 65 s.
        XCTAssertEqual(StockLoopSession.G7WindowPolicy.verdict(lastDirect: t0.addingTimeInterval(62), expectedBurst: t0), "HIT")
    }

    func testNoReadingOrAStaleOneIsAMiss() {
        XCTAssertEqual(StockLoopSession.G7WindowPolicy.verdict(lastDirect: nil, expectedBurst: t0), "MISS")
        XCTAssertEqual(StockLoopSession.G7WindowPolicy.verdict(lastDirect: t0.addingTimeInterval(-300), expectedBurst: t0), "MISS",
                       "the previous window's reading must not count for this one")
        XCTAssertEqual(StockLoopSession.G7WindowPolicy.verdict(lastDirect: t0.addingTimeInterval(200), expectedBurst: t0), "MISS",
                       "a reading 200 s late belongs to the next window, not this one")
    }

    func testTheVerdictIsDueOnePeriodPlusTheLateAllowanceAfterTheAnchor() {
        let due = StockLoopSession.G7WindowPolicy.nextVerdict(after: t0)
        XCTAssertEqual(due.timeIntervalSince(t0),
                       StockLoopSession.G7WindowPolicy.period + StockLoopSession.G7WindowPolicy.late, accuracy: 0.001)
        XCTAssertGreaterThan(StockLoopSession.G7WindowPolicy.late, StockLoopSession.G7WindowPolicy.early,
                             "the late allowance covers the between-burst connects; the early one only the burst's own jitter")
    }

    /// Field 2026-09-24 15:22: a bracket whose close timer was cancelled stayed "open" at
    /// "0.5s to close" for 30 minutes and held a Start request the whole time. Past its close
    /// a bracket holds nothing.
    func testABracketPastItsCloseHoldsNothing() {
        defer { StockLoopSession.setBracketForTesting(open: false, closeAt: nil) }
        StockLoopSession.setBracketForTesting(open: true, closeAt: Date().addingTimeInterval(20))
        XCTAssertNotNil(StockLoopSession.bracketRemainingNow(), "inside the bracket: held")
        StockLoopSession.setBracketForTesting(open: true, closeAt: Date().addingTimeInterval(-1))
        XCTAssertNil(StockLoopSession.bracketRemainingNow(), "past the close: nothing is held, timer or no timer")
    }

    /// The messages the quiet window must never hold: someone is waiting on each.
    func testStartRequestsAndHandBackOffersAreNeverHeld() throws {
        let request = try LoanMessage.request(LoanRequest(watchBuild: "t")).transportDictionary()
        let offer = try LoanMessage.handbackOffer(HandbackOffer(
            epoch: 1, handedBackAt: Date(), finalStatus: nil, odometer: nil,
            events: [], tombstones: [], recovered: false, released: false)).transportDictionary()
        XCTAssertTrue(LoanMessage.isInteractiveHandshake(transport: request))
        XCTAssertTrue(LoanMessage.isInteractiveHandshake(transport: offer))
    }
}
