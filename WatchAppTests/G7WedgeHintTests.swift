//
//  G7WedgeHintTests.swift
//  WatchAppTests
//
//  The glance's wedge hint has three gates (two missed bursts, the phone not relaying, and the
//  ruled wording that names the WATCH's Bluetooth); the tests exist so a later edit cannot
//  quietly move them.
//

import XCTest
@testable import WatchApp

final class G7WedgeHintTests: XCTestCase {
    func testTwoMissesWithThePhoneAwayNameTheWatchBluetooth() {
        let hint = G7WedgeHint.text(directAge: 11 * 60, relayAge: nil)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("watch Bluetooth"), "ruled wording: it must name the WATCH")
        XCTAssertTrue(hint!.contains("11 min"))
    }

    func testOneMissIsNotAWedge() {
        XCTAssertNil(G7WedgeHint.text(directAge: 7 * 60, relayAge: nil))
    }

    func testAPhoneThatIsRelayingIsNotAWedge() {
        XCTAssertNil(G7WedgeHint.text(directAge: 15 * 60, relayAge: 3 * 60),
                     "the phone is collecting — a missed direct read with a relay is not the parked stack")
    }

    func testAFreshNumberNeverCarriesTheHint() {
        XCTAssertNil(G7WedgeHint.text(directAge: 60, relayAge: nil))
        XCTAssertNil(G7WedgeHint.text(directAge: nil, relayAge: nil))
    }
}
