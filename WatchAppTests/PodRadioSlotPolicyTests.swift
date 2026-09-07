//
//  PodRadioSlotPolicyTests.swift
//  WatchAppTests
//
//  Build 179 (mute record §7a–7c, 2026-09-07): ONE pod hold, and only in the sensor's extended
//  phase — the first two windows without the phone's relay after windows that had it, where
//  every counted failure and the one −70 write of the day came from. Phone present and steady
//  phone-absent are unrestricted: 17 pod-on-minute-call collisions at both judgment states
//  counted nothing.
//

import XCTest
@testable import WatchApp_Extension

final class PodRadioSlotPolicyTests: XCTestCase {

    private typealias S = StockLoopSession.PodRadioSlotPolicy
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)   // a direct read = a burst

    // The extended phase: no relay THIS window, and one within 12.5 min (two windows, three when
    // the departure cut a window short). Today: 11:06 and 11:11 long tails, 11:16 short.
    func testTheExtendedPhaseIsTheFirstTwoWindowsAfterTheRelayStops() {
        let now = anchor
        XCTAssertTrue(S.isExtendedPhase(lastRelay: now.addingTimeInterval(-5 * 60), now: now, relayThisWindow: false), "first window without a relay")
        XCTAssertTrue(S.isExtendedPhase(lastRelay: now.addingTimeInterval(-10 * 60), now: now, relayThisWindow: false), "second window without a relay")
        XCTAssertFalse(S.isExtendedPhase(lastRelay: now.addingTimeInterval(-15 * 60), now: now, relayThisWindow: false), "third burst is already short — minute calls, no tail")
        XCTAssertFalse(S.isExtendedPhase(lastRelay: now.addingTimeInterval(-40 * 60), now: now, relayThisWindow: false), "steady phone-absent")
    }

    func testAWindowWithTheRelayIsNeverExtended() {
        XCTAssertFalse(S.isExtendedPhase(lastRelay: anchor.addingTimeInterval(-3), now: anchor, relayThisWindow: true), "phone present: 7-s tail, nothing to fail into")
    }

    func testNoRelayEverMeansSteadyPhoneAbsentNotExtended() {
        XCTAssertFalse(S.isExtendedPhase(lastRelay: nil, now: anchor, relayThisWindow: false), "a loan that began with the phone away, or a relaunch: the sensor is on minute calls")
    }

    // Inside the extended phase: hold through the burst and the tail, close+25 s capped at +40,
    // read-relative 40 until the close is seen — build 177/178's proven numbers.
    func testTheExtendedPhaseHoldsThroughTheTail() {
        XCTAssertEqual(S.firstPhaseEnd(extended: true, closeOffset: 9), 34, accuracy: 0.001)
        XCTAssertEqual(S.firstPhaseEnd(extended: true, closeOffset: 0.4), 25.4, accuracy: 0.001)
        XCTAssertEqual(S.firstPhaseEnd(extended: true, closeOffset: 16), 40, accuracy: 0.001, "a late close is capped by what run 3 proved")
        XCTAssertEqual(S.firstPhaseEnd(extended: true, closeOffset: nil), 40, "no close seen: the read-relative fallback")
        let phases = S.closedPhases(extended: true, closeOffset: 9)
        for phase: TimeInterval in [0, 5, 24, 33] {
            XCTAssertNotNil(S.closedRemaining(phase: phase, phases: phases), "phase +\(Int(phase)) s must be closed")
        }
        XCTAssertEqual(S.closedRemaining(phase: 0, phases: phases)!, 34, accuracy: 0.001)
    }

    // The minute calls are open even in the extended phase (T1: 13 collisions at state 0, T1c: 4 at
    // state 1, none counted); only the 20-s lead before the next burst is closed.
    func testTheMinuteCallsAreOpenAndTheLeadIsClosedInTheExtendedPhase() {
        let phases = S.closedPhases(extended: true, closeOffset: 9)
        for phase: TimeInterval in [34, 45, 60, 115, 120, 180, 240, 279] {
            XCTAssertNil(S.closedRemaining(phase: phase, phases: phases), "phase +\(Int(phase)) s must be open")
        }
        XCTAssertNotNil(S.closedRemaining(phase: 280, phases: phases), "the next window's lead (+280→+300) is closed")
        XCTAssertNotNil(S.closedRemaining(phase: 299, phases: phases))
    }

    // Outside the extended phase: nothing, anywhere in the window — Jeremy, 2026-09-07: "outside
    // of that mode, pod is unrestricted".
    func testOutsideTheExtendedPhaseNothingIsHeld() {
        XCTAssertEqual(S.firstPhaseEnd(extended: false, closeOffset: 9), 0)
        XCTAssertTrue(S.closedPhases(extended: false, closeOffset: 9).isEmpty)
        var p: TimeInterval = 0
        while p < 300 {
            XCTAssertNil(S.closedRemaining(anchor: anchor, now: anchor.addingTimeInterval(p), extended: false, closeOffset: 9), "phase +\(Int(p)) s")
            p += 0.5
        }
    }

    func testTheLongestHoldIsFortySeconds() {
        var worst: TimeInterval = 0
        var p: TimeInterval = 0
        let phases = S.closedPhases(extended: true, closeOffset: nil)
        while p < 300 { if let r = S.closedRemaining(phase: p, phases: phases) { worst = max(worst, r) }; p += 0.5 }
        XCTAssertEqual(worst, 40, accuracy: 0.001, "a dose never waits longer than 40 s")
    }

    func testNeverWithoutAnAnchor() {
        XCTAssertNil(S.closedRemaining(anchor: nil, now: anchor, extended: true, closeOffset: nil), "no direct read yet means no phase — never hold a dose on a guess")
    }

    func testThePhaseIsTheSensorsAndCarriesThroughMisses() {
        XCTAssertEqual(S.phase(anchor: anchor, now: anchor.addingTimeInterval(30)), 30, accuracy: 0.001)
        XCTAssertEqual(S.phase(anchor: anchor, now: anchor.addingTimeInterval(299)), 299, accuracy: 0.001)
        XCTAssertEqual(S.phase(anchor: anchor, now: anchor.addingTimeInterval(300 + 45)), 45, accuracy: 0.001,
                       "a missed window does not move the phase — skip whole periods on the sensor's grid")
        XCTAssertEqual(S.phase(anchor: anchor, now: anchor.addingTimeInterval(4 * 300 + 200)), 200, accuracy: 0.001)
    }

    // The bench switch is the only control left, and nothing on the wrist sets it.
    func testTheHoldIsOnByDefault() {
        UserDefaults.standard.removeObject(forKey: StockLoopSession.PodRadioHold.key)
        XCTAssertFalse(StockLoopSession.PodRadioHold.disabled)
        XCTAssertTrue(StockLoopSession.quietWindowEnabled)
    }
}

// Build 179 — the glance's wedge hint (mute record §7c): two or more consecutive missed bursts
// with the phone not relaying, on a stale number. Not an alert; it names the WATCH's Bluetooth.
final class WedgeHintTests: XCTestCase {
    func testTwoMissesWithThePhoneAwayNameTheWatchBluetooth() {
        let hint = GlanceViewModel.wedgeHint(staleAge: 12 * 60, consecutiveMisses: 2, relayRecent: false)
        XCTAssertEqual(hint, "G7 silent 12 min · try toggling watch Bluetooth")
    }
    func testOneMissIsNotAWedge() {
        XCTAssertNil(GlanceViewModel.wedgeHint(staleAge: 12 * 60, consecutiveMisses: 1, relayRecent: false))
    }
    func testAPhoneThatIsRelayingIsNotAWedge() {
        XCTAssertNil(GlanceViewModel.wedgeHint(staleAge: 12 * 60, consecutiveMisses: 3, relayRecent: true), "the number is stale for another reason — the relay is landing")
    }
    func testAFreshNumberNeverCarriesTheHint() {
        XCTAssertNil(GlanceViewModel.wedgeHint(staleAge: 4 * 60, consecutiveMisses: 2, relayRecent: false))
        XCTAssertNil(GlanceViewModel.wedgeHint(staleAge: nil, consecutiveMisses: 2, relayRecent: false))
    }
}


// Build 174 — the per-window tail-exposure verdict (mute record §5): our pod link or scan in the
// 40 s after a sensor close, and whether it touched the late zone (+6→+29 s) where every −70
// write on record came from.
final class TailExposureTests: XCTestCase {
    typealias E = TailExposure.Event

    func testNothingOfOursIsClean() {
        XCTAssertTrue(TailExposure.summary(events: [], podUpAtClose: false).hasPrefix("CLEAN"))
    }

    func testTheDoseCyclePodLinkTouchesTheLateZone() {
        // 09-06 00:26: pod link +1 s after the read … released +18 s; the close came at +9 s.
        let s = TailExposure.summary(events: [E(kind: "pod↑", offset: 1.2), E(kind: "pod↓", offset: 18.4)], podUpAtClose: false)
        XCTAssertTrue(s.contains("pod link +1.2→+18.4 s"), s)
        XCTAssertTrue(s.hasSuffix("TOUCHED"), s)
    }

    func testAPodLinkThatEndsBeforeTheFastScanExpiresIsClear() {
        let s = TailExposure.summary(events: [E(kind: "pod↑", offset: 0.5), E(kind: "pod↓", offset: 4.0)], podUpAtClose: false)
        XCTAssertTrue(s.hasSuffix("clear"), s)
    }

    func testAScanInTheTailTouches() {
        // 16:06:53: stock forget-and-scan two seconds after the close.
        let s = TailExposure.summary(events: [E(kind: "scan", offset: 2.0)], podUpAtClose: false)
        XCTAssertTrue(s.contains("scan +2.0 s") && s.hasSuffix("TOUCHED"), s)
    }

    func testAPodLinkAlreadyUpAtTheCloseCountsFromZero() {
        let s = TailExposure.summary(events: [E(kind: "pod↓", offset: 9.0)], podUpAtClose: true)
        XCTAssertTrue(s.contains("pod link +0.0→+9.0 s") && s.hasSuffix("TOUCHED"), s)
    }

    func testALinkStillUpAtTheWindowEndIsReported() {
        let s = TailExposure.summary(events: [E(kind: "pod↑", offset: 30.0)], podUpAtClose: false)
        XCTAssertTrue(s.contains("still up at +40 s"), s)
        XCTAssertTrue(s.hasSuffix("clear"), "a link that starts after the tail ended is not in the late zone: \(s)")
    }
}
