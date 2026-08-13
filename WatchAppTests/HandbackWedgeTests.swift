//
//  HandbackWedgeTests.swift
//  WatchAppTests
//
//  The #113 discriminator's full truth table. This shipped in build 275 with no tests, and it
//  decides which of two OPPOSITE instructions the user gets when a hand-back hangs: force-quit
//  the watch app, or wait a minute. Getting it backwards sends them to the wrong device.
//
//  Testable because the decision is now a pure function. Before that it was two separate
//  if/else-if chains inside handbackTimedOut() — evaluated twice, so the log line and the alert
//  could disagree — behind a path that needs a live pump manager.
//

import XCTest
@testable import WatchApp_Extension

final class HandbackWedgeTests: XCTestCase {

    // MARK: - The two variants

    /// Variant A: offers went out, the phone was reachable throughout, no acks, and the sends
    /// themselves reported success. Only a watch-app restart has ever recovered this.
    func testReachableThroughoutWithSilentSendsIsTheOneWayWedge() {
        XCTAssertEqual(
            HandbackWedge.classify(resendCount: 3, sawUnreachable: false, reachableNow: true, sendsErrored: false),
            .oneWay)
    }

    /// Variant B: same picture, except the sends ERRORED. That is a session tearing down and
    /// re-establishing, and the queued fallback delivers when it returns — so the advice is
    /// "wait", not "force-quit".
    func testErroringSendsAreTheReestablishingSessionNotTheWedge() {
        XCTAssertEqual(
            HandbackWedge.classify(resendCount: 3, sawUnreachable: false, reachableNow: true, sendsErrored: true),
            .sessionReestablishing)
    }

    // MARK: - Everything that must NOT be called a wedge
    //
    // These matter more than the positives. A false wedge tells the user to force-quit the
    // watch app during a hand-back — the most disruptive advice the app can give — for what is
    // usually an ordinary phone-out-of-range hang that would have healed on its own.

    /// Under three offers there is not enough evidence yet, whatever else is true.
    func testTooFewOffersIsNeverAWedge() {
        for count in 0...2 {
            XCTAssertEqual(
                HandbackWedge.classify(resendCount: count, sawUnreachable: false, reachableNow: true, sendsErrored: false),
                .none, "\(count) offers is not enough evidence")
            XCTAssertEqual(
                HandbackWedge.classify(resendCount: count, sawUnreachable: false, reachableNow: true, sendsErrored: true),
                .none, "\(count) offers is not enough evidence, erroring sends included")
        }
    }

    /// A phone that went away even ONCE explains the hang innocently. This is the sticky flag:
    /// it must veto the wedge even though the phone is reachable again right now, which is the
    /// common case by the time the timeout fires.
    func testAPhoneThatWasEverUnreachableVetoesTheWedge() {
        XCTAssertEqual(
            HandbackWedge.classify(resendCount: 9, sawUnreachable: true, reachableNow: true, sendsErrored: false),
            .none, "one unreachable moment explains the hang without a wedge")
        XCTAssertEqual(
            HandbackWedge.classify(resendCount: 9, sawUnreachable: true, reachableNow: true, sendsErrored: true),
            .none)
    }

    /// A phone that is out of range AT the timeout is the ordinary case, not a wedge.
    func testAnUnreachablePhoneAtTimeoutIsNotAWedge() {
        XCTAssertEqual(
            HandbackWedge.classify(resendCount: 9, sawUnreachable: false, reachableNow: false, sendsErrored: false),
            .none)
    }

    // MARK: - Boundary

    /// Three is the threshold, and it is inclusive. Two is not enough; three is.
    func testThreeOffersIsTheInclusiveThreshold() {
        XCTAssertEqual(
            HandbackWedge.classify(resendCount: 2, sawUnreachable: false, reachableNow: true, sendsErrored: false),
            .none)
        XCTAssertEqual(
            HandbackWedge.classify(resendCount: 3, sawUnreachable: false, reachableNow: true, sendsErrored: false),
            .oneWay)
    }

    /// Exhaustive over the whole input space that matters, so no combination is unspecified.
    /// A wedge requires ALL THREE of: enough offers, never unreachable, reachable now — and
    /// only then does `sendsErrored` choose between the variants.
    func testFullTruthTable() {
        for count in [0, 2, 3, 10] {
            for sawUnreachable in [false, true] {
                for reachableNow in [false, true] {
                    for sendsErrored in [false, true] {
                        let actual = HandbackWedge.classify(resendCount: count,
                                                            sawUnreachable: sawUnreachable,
                                                            reachableNow: reachableNow,
                                                            sendsErrored: sendsErrored)
                        let expected: HandbackWedge
                        if count >= 3 && !sawUnreachable && reachableNow {
                            expected = sendsErrored ? .sessionReestablishing : .oneWay
                        } else {
                            expected = .none
                        }
                        XCTAssertEqual(actual, expected,
                                       "count=\(count) sawUnreachable=\(sawUnreachable) reachableNow=\(reachableNow) sendsErrored=\(sendsErrored)")
                    }
                }
            }
        }
    }
}
