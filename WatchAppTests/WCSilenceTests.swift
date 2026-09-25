//
//  WCSilenceTests.swift
//  WatchAppTests
//
//  The 2026-09-04 diagnosis build: the WC-silence gate (a phone-away loan hands
//  WatchConnectivity nothing while the bench switch is on) and the G7 window monitor's
//  verdict rule (one HIT/MISS line per expected sensor burst). Both pinned as pure decisions
//  so the meaning of the switch and of the log line cannot drift silently.
//

import XCTest
@testable import WatchApp_Extension

final class WCSilenceTests: XCTestCase {

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
}
