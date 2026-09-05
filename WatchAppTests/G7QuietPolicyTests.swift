//
//  G7QuietPolicyTests.swift
//  WatchAppTests
//
//  The quiet window (2026-09-05): a bracket around the sensor's expected burst inside which
//  nothing of ours touches the radio. The bracket is computed from the last direct read on
//  the sensor's own 300 s grid and carried forward through misses. Pinned as a pure policy.
//

import XCTest
@testable import WatchApp_Extension

final class G7QuietPolicyTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)   // a direct read
    private typealias P = StockLoopSession.G7QuietPolicy

    func testTheNextBurstIsOnePeriodAfterTheAnchor() {
        let b = P.nextBurst(anchor: anchor, now: anchor.addingTimeInterval(10))
        XCTAssertEqual(b.timeIntervalSince(anchor), P.period, accuracy: 0.001)
    }

    func testTheBracketOpensBeforeAndClosesAfterTheBurst() {
        let br = P.bracket(anchor: anchor, now: anchor.addingTimeInterval(10))
        XCTAssertEqual(br.burst.timeIntervalSince(br.open), P.lead, accuracy: 0.001)
        XCTAssertEqual(br.close.timeIntervalSince(br.burst), P.lag, accuracy: 0.001)
    }

    func testAMissedBurstCarriesTheBracketForwardOnTheSensorsPhase() {
        // 8 minutes after the anchor the first burst's bracket has closed; the next one is due.
        let now = anchor.addingTimeInterval(8 * 60)
        let b = P.nextBurst(anchor: anchor, now: now)
        XCTAssertEqual(b.timeIntervalSince(anchor), 2 * P.period, accuracy: 0.001,
                       "the phase is the sensor's, not ours — skip whole periods, never re-anchor on our clock")
        // Just before the previous bracket closes it is still the one to protect.
        let late = anchor.addingTimeInterval(P.period + P.lag - 1)
        XCTAssertEqual(P.nextBurst(anchor: anchor, now: late).timeIntervalSince(anchor), P.period, accuracy: 0.001)
    }

    func testTheAirIsClosedInsideTheBracketAndOpenOutsideIt() {
        let burst = anchor.addingTimeInterval(P.period)
        XCTAssertFalse(P.isClosed(anchor: anchor, readLandedFor: nil, now: burst.addingTimeInterval(-P.lead - 1), enabled: true))
        XCTAssertTrue(P.isClosed(anchor: anchor, readLandedFor: nil, now: burst.addingTimeInterval(-P.lead + 1), enabled: true))
        XCTAssertTrue(P.isClosed(anchor: anchor, readLandedFor: nil, now: burst, enabled: true))
        XCTAssertTrue(P.isClosed(anchor: anchor, readLandedFor: nil, now: burst.addingTimeInterval(P.lag - 1), enabled: true))
        XCTAssertFalse(P.isClosed(anchor: anchor, readLandedFor: nil, now: burst.addingTimeInterval(P.lag + 1), enabled: true))
    }

    func testThisWindowsReadReopensTheAirEarly() {
        let burst = anchor.addingTimeInterval(P.period)
        XCTAssertFalse(P.isClosed(anchor: anchor, readLandedFor: burst, now: burst.addingTimeInterval(5), enabled: true),
                       "once the read has landed the pod may go — that is the read-driven cycle, which never collided")
    }

    func testTheSwitchAndAMissingAnchorOpenTheAir() {
        let burst = anchor.addingTimeInterval(P.period)
        XCTAssertFalse(P.isClosed(anchor: anchor, readLandedFor: nil, now: burst, enabled: false))
        XCTAssertFalse(P.isClosed(anchor: nil, readLandedFor: nil, now: burst, enabled: true),
                       "no direct read yet means no phase to protect — never hold a dose on a guess")
    }

    func testTheBracketIsGenerousAgainstTheMeasuredGrid() {
        // Mac scanner 2026-09-02→05: spacing 300.00 s ± 1.2 s, phase drifting +4 s/day, so a
        // 70-minute mute moves the predicted burst by well under a second.
        XCTAssertGreaterThanOrEqual(P.lead, 15)
        XCTAssertGreaterThanOrEqual(P.lag, 30)
        XCTAssertLessThanOrEqual(P.lead + P.lag, 90, "a dose must never wait longer than a minute and a half")
    }
}
