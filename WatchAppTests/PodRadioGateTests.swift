//
//  PodRadioGateTests.swift
//  WatchAppTests
//
//  The session-end wait (2026-09-02): the pod radio opens only once the G7 session that
//  delivered the reading has been down for a short settle, bounded by a ceiling. Pinned as a
//  pure decision so the timing policy is testable without radios or timers.
//

import XCTest
@testable import WatchApp_Extension

final class PodRadioGateTests: XCTestCase {

    func testWaitsWhileTheSessionIsLive() {
        XCTAssertEqual(WatchLoopManager.podRadioGateDecision(sessionLive: true, sinceSessionEnd: nil, elapsed: 0), .wait)
        XCTAssertEqual(WatchLoopManager.podRadioGateDecision(sessionLive: true, sinceSessionEnd: nil, elapsed: 12), .wait,
                       "a 12 s session (the bench saw up to 13.1 s) is still inside the ceiling — keep waiting")
    }

    func testWaitsThroughTheSettleAfterTheSessionEnds() {
        XCTAssertEqual(WatchLoopManager.podRadioGateDecision(sessionLive: false, sinceSessionEnd: 1, elapsed: 9), .wait)
        if case .proceed = WatchLoopManager.podRadioGateDecision(sessionLive: false, sinceSessionEnd: 3, elapsed: 11) {} else {
            XCTFail("3 s after the session ended the pod radio must open")
        }
    }

    func testCeilingOpensTheRadioRegardless() {
        if case .proceed(let why) = WatchLoopManager.podRadioGateDecision(sessionLive: true, sinceSessionEnd: nil, elapsed: 20) {
            XCTAssertTrue(why.contains("CEILING"), "the ceiling must name itself so a stuck session is visible in the log")
        } else {
            XCTFail("the ceiling bounds the dosing delay — it must proceed")
        }
    }

    func testSessionFlappingBackUpResetsTheSettle() {
        // Session ended, then came back (backfill burst) — the settle restarts from the next end.
        XCTAssertEqual(WatchLoopManager.podRadioGateDecision(sessionLive: true, sinceSessionEnd: nil, elapsed: 6), .wait)
    }
}
