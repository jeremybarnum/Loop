//
//  PodRadioHoldTests.swift
//  WatchAppTests
//
//  Pins the pure half of the G7 mute fix's pod side (PodRadioHold.swift): WHEN the sensor is
//  in its extended phase, HOW LONG the pod stays off the air there, that nothing is held
//  anywhere else, and the wedge hint's three gates. The numbers are her line's, earned on the
//  air and in six watch sysdiagnoses (mute record §5–§7); the tests exist so a later edit
//  cannot quietly move them.
//

import XCTest
@testable import WatchApp

final class PodRadioHoldTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Extended phase

    func testTheExtendedPhaseIsTheFirstTwoWindowsAfterTheRelayStops() {
        let relay = t0
        XCTAssertTrue(PodRadioHold.isExtendedPhase(lastRelay: relay, now: t0.addingTimeInterval(5 * 60), relayThisWindow: false))
        XCTAssertTrue(PodRadioHold.isExtendedPhase(lastRelay: relay, now: t0.addingTimeInterval(12 * 60), relayThisWindow: false))
        XCTAssertFalse(PodRadioHold.isExtendedPhase(lastRelay: relay, now: t0.addingTimeInterval(13 * 60), relayThisWindow: false),
                       "the third burst after a departure is already a short tail — steady phone-absent")
    }

    func testAWindowWithTheRelayIsNeverExtended() {
        XCTAssertFalse(PodRadioHold.isExtendedPhase(lastRelay: t0, now: t0.addingTimeInterval(5), relayThisWindow: true),
                       "phone present: 7-s two-central tail, never a late failure on record")
    }

    func testNoRelayEverMeansSteadyPhoneAbsentNotExtended() {
        XCTAssertFalse(PodRadioHold.isExtendedPhase(lastRelay: nil, now: t0, relayThisWindow: false),
                       "minute calls, no tails, nothing to hold for")
    }

    // MARK: The relay's freshness gate

    func testAFreshRelayCountsAsThePhoneCollecting() {
        XCTAssertTrue(PodRadioHold.relayCounts(readingDate: t0, now: t0.addingTimeInterval(5)),
                      "the phone reads on the grid and relays within seconds")
        XCTAssertTrue(PodRadioHold.relayCounts(readingDate: t0, now: t0.addingTimeInterval(5 * 60)),
                      "a whole window of transport lag still counts")
    }

    /// Field 2026-09-07 23:02: the phone's radio had been off for ten minutes, but it relayed
    /// its last reading once. Stamped on arrival alone that read as "the phone is collecting"
    /// and suppressed the hold for a window in the sensor's extended phase.
    func testAStaleRelayFromAPhoneThatStoppedCollectingDoesNotCount() {
        XCTAssertFalse(PodRadioHold.relayCounts(readingDate: t0, now: t0.addingTimeInterval(10 * 60)),
                       "a ten-minute-old reading says nothing about whether the phone is collecting now")
        XCTAssertFalse(PodRadioHold.relayCounts(readingDate: t0, now: t0.addingTimeInterval(6 * 60 + 1)),
                       "just past the gate")
    }

    func testAReadingFromTheFutureDoesNotCount() {
        XCTAssertFalse(PodRadioHold.relayCounts(readingDate: t0.addingTimeInterval(60), now: t0),
                       "clock skew must not manufacture evidence")
    }

    /// The gate is safe here only because the loan start has its own entry point — her line
    /// relies on the stale grant sample for exactly this and warns against gating it.
    func testTheLoanStartIsNeverFreshnessGated() {
        PodRadioHold.noteLoanStarted(t0)
        XCTAssertTrue(PodRadioHold.isExtendedPhase(lastRelay: t0, now: t0.addingTimeInterval(5 * 60), relayThisWindow: false),
                      "a loan that begins as the phone leaves must still hold its first tails")
    }

    // MARK: The hold

    func testTheExtendedPhaseHoldsThroughTheTail() {
        // Close seen at +12 s → hold to close+25 = +37 s.
        XCTAssertEqual(PodRadioHold.holdRemaining(phase: 0, extended: true, closeOffset: 12)!, 37, accuracy: 0.001)
        XCTAssertEqual(PodRadioHold.holdRemaining(phase: 30, extended: true, closeOffset: 12)!, 7, accuracy: 0.001)
        XCTAssertNil(PodRadioHold.holdRemaining(phase: 37.5, extended: true, closeOffset: 12), "open once the tail is over")
    }

    func testTheLongestHoldIsFortySeconds() {
        // No close seen yet → read-relative 40; a late close (+20) is capped at 40, not 45.
        XCTAssertEqual(PodRadioHold.holdRemaining(phase: 0, extended: true, closeOffset: nil)!, 40, accuracy: 0.001)
        XCTAssertEqual(PodRadioHold.holdRemaining(phase: 0, extended: true, closeOffset: 20)!, 40, accuracy: 0.001)
        XCTAssertNil(PodRadioHold.holdRemaining(phase: 41, extended: true, closeOffset: 20))
    }

    func testTheMinuteCallsAreOpenAndTheLeadIsClosedInTheExtendedPhase() {
        for p: TimeInterval in [60, 120, 180, 240] {
            XCTAssertNil(PodRadioHold.holdRemaining(phase: p, extended: true, closeOffset: 10),
                         "minute calls count nothing — 17 pod collisions on record, zero booked")
        }
        XCTAssertEqual(PodRadioHold.holdRemaining(phase: 290, extended: true, closeOffset: 10)!, 10, accuracy: 0.001,
                       "the 20 s before the next burst are held")
    }

    func testOutsideTheExtendedPhaseNothingIsHeld() {
        for p: TimeInterval in [0, 5, 20, 39, 150, 290, 299] {
            XCTAssertNil(PodRadioHold.holdRemaining(phase: p, extended: false, closeOffset: 12),
                         "phone present or steady phone-absent: the pod is unrestricted (Jeremy 2026-09-07)")
        }
    }

    func testThePhaseIsTheSensorsAndCarriesThroughMisses() {
        XCTAssertEqual(PodRadioHold.phase(anchor: t0, now: t0.addingTimeInterval(37)), 37, accuracy: 0.001)
        XCTAssertEqual(PodRadioHold.phase(anchor: t0, now: t0.addingTimeInterval(600 + 37)), 37, accuracy: 0.001,
                       "two missed bursts later the phase is still the grid's")
    }

    // MARK: The wedge hint

    func testTwoMissesWithThePhoneAwayNameTheWatchBluetooth() {
        let hint = PodRadioHold.wedgeHint(directAge: 11 * 60, relayAge: nil)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("watch Bluetooth"), "ruled wording: it must name the WATCH")
        XCTAssertTrue(hint!.contains("11 min"))
    }

    func testOneMissIsNotAWedge() {
        XCTAssertNil(PodRadioHold.wedgeHint(directAge: 7 * 60, relayAge: nil))
    }

    func testAPhoneThatIsRelayingIsNotAWedge() {
        XCTAssertNil(PodRadioHold.wedgeHint(directAge: 15 * 60, relayAge: 3 * 60),
                     "the phone is collecting — a missed direct read with a relay is not the parked stack")
    }

    func testAFreshNumberNeverCarriesTheHint() {
        XCTAssertNil(PodRadioHold.wedgeHint(directAge: 60, relayAge: nil))
        XCTAssertNil(PodRadioHold.wedgeHint(directAge: nil, relayAge: nil))
    }

    // MARK: The [tail] line

    func testNothingOfOursIsClean() {
        XCTAssertEqual(TailExposure.summary(events: [], podUpAtClose: false), "CLEAN (nothing of ours on the radio for 40 s)")
    }

    func testTheDoseCyclePodLinkTouchesTheLateZone() {
        let s = TailExposure.summary(events: [.init(kind: "pod↑", offset: 1.0), .init(kind: "pod↓", offset: 19.0)], podUpAtClose: false)
        XCTAssertTrue(s.contains("pod link +1.0→+19.0 s"))
        XCTAssertTrue(s.hasSuffix("TOUCHED"))
    }

    func testAPodLinkThatEndsBeforeTheFastScanExpiresIsClear() {
        let s = TailExposure.summary(events: [.init(kind: "pod↑", offset: 0.5), .init(kind: "pod↓", offset: 5.0)], podUpAtClose: false)
        XCTAssertTrue(s.hasSuffix("clear"))
    }

    func testAScanInTheTailTouches() {
        XCTAssertTrue(TailExposure.summary(events: [.init(kind: "scan", offset: 2.0)], podUpAtClose: false).hasSuffix("TOUCHED"))
    }

    func testAPodLinkAlreadyUpAtTheCloseCountsFromZero() {
        let s = TailExposure.summary(events: [.init(kind: "pod↓", offset: 30.0)], podUpAtClose: true)
        XCTAssertTrue(s.contains("pod link +0.0→+30.0 s"))
        XCTAssertTrue(s.hasSuffix("TOUCHED"))
    }

    func testALinkStillUpAtTheWindowEndIsReported() {
        let s = TailExposure.summary(events: [.init(kind: "pod↑", offset: 35.0)], podUpAtClose: false)
        XCTAssertTrue(s.contains("still up at +40 s"))
        XCTAssertTrue(s.hasSuffix("clear"), "a link that came up after the tail ended did not touch the late zone")
    }
}
