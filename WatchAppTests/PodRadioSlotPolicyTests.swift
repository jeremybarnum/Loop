//
//  PodRadioSlotPolicyTests.swift
//  WatchAppTests
//
//  The pod-radio slot schedule (2026-09-05 night). Sniffer histograms: the sensor is on the air
//  0→~25 s after a reading and, phone absent, at +60/+120/+180/+240 (±5 s); silent otherwise.
//  bluetoothd gated the sensor at −70 dBm after two links collapsed inside our pod exchange at
//  +20/+25 s. The schedule keeps the pod off the air everywhere the sensor has been seen active.
//

import XCTest
@testable import WatchApp_Extension

final class PodRadioSlotPolicyTests: XCTestCase {

    private typealias S = StockLoopSession.PodRadioSlotPolicy
    private typealias P = StockLoopSession.PodRadioPolicy
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)   // a direct read = a burst

    // Build 177: the hold covers the burst and the measured tail (~+29 s) with margin — 40 s.
    // The +60 s minute call is no longer inside it: unanswered CONNECT_INDs there never booked
    // a failure under ride-only (mute record §5), and the pod's scan + link at +40…+60 s end
    // before it.
    func testThePodIsHeldThroughTheBurstAndTheTail() {
        for phase: TimeInterval in [0, 5, 24, 25, 30, 35, 39] {
            XCTAssertNotNil(S.closedRemaining(phase: phase), "phase +\(Int(phase)) s must be closed")
        }
        XCTAssertEqual(S.closedRemaining(phase: 0)!, 40, accuracy: 0.001)
        XCTAssertEqual(S.closedRemaining(phase: 25)!, 15, accuracy: 0.001)
    }

    func testTheFourSlotsAreOpen() {
        for phase: TimeInterval in [40, 45, 60, 70, 90, 109, 130, 150, 169, 190, 210, 229, 250, 265, 279] {
            XCTAssertNil(S.closedRemaining(phase: phase), "phase +\(Int(phase)) s must be open")
        }
    }

    func testEveryMinuteCallIsBlackedOutWithTenSecondsOfMargin() {
        for call: TimeInterval in [120, 180, 240] {
            XCTAssertNil(S.closedRemaining(phase: call - 11))
            XCTAssertNotNil(S.closedRemaining(phase: call - 10))
            XCTAssertNotNil(S.closedRemaining(phase: call))
            XCTAssertNotNil(S.closedRemaining(phase: call + 9))
            XCTAssertNil(S.closedRemaining(phase: call + 10))
        }
        XCTAssertNotNil(S.closedRemaining(phase: 280), "the next window's lead (+280→+300) is closed")
        XCTAssertNotNil(S.closedRemaining(phase: 299))
    }

    func testThePhaseIsTheSensorsAndCarriesThroughMisses() {
        XCTAssertEqual(S.phase(anchor: anchor, now: anchor.addingTimeInterval(30)), 30, accuracy: 0.001)
        XCTAssertEqual(S.phase(anchor: anchor, now: anchor.addingTimeInterval(299)), 299, accuracy: 0.001)
        XCTAssertEqual(S.phase(anchor: anchor, now: anchor.addingTimeInterval(300 + 45)), 45, accuracy: 0.001,
                       "a missed window does not move the phase — skip whole periods on the sensor's grid")
        XCTAssertEqual(S.phase(anchor: anchor, now: anchor.addingTimeInterval(4 * 300 + 200)), 200, accuracy: 0.001)
    }

    func testOnlyTheSlotsPolicyHoldsAndNeverWithoutAnAnchor() {
        let now = anchor.addingTimeInterval(20)
        XCTAssertNotNil(S.closedRemaining(anchor: anchor, now: now, policy: .slots))
        XCTAssertNil(S.closedRemaining(anchor: anchor, now: now, policy: .quietGate), "quietGate keeps the old bracket + gate, not the schedule")
        XCTAssertNil(S.closedRemaining(anchor: anchor, now: now, policy: .off))
        XCTAssertNil(S.closedRemaining(anchor: nil, now: now, policy: .slots), "no direct read yet means no phase — never hold a dose on a guess")
    }

    // Build 176: `slots` is the shipping policy — the pod never touches the sensor's tail.
    func testTheDefaultIsSlots() {
        UserDefaults.standard.removeObject(forKey: P.key)
        XCTAssertEqual(P.current, .slots)
        XCTAssertTrue(StockLoopSession.quietWindowEnabled, "the pre-burst bracket stays on under the default")
    }

    // Build 177: 40 s covers the measured tail (+29 s) and the latest close (+16 s) with margin.
    func testTheLongestHoldIsFortySeconds() {
        var worst: TimeInterval = 0
        var p: TimeInterval = 0
        while p < 300 { if let r = S.closedRemaining(phase: p) { worst = max(worst, r) }; p += 0.5 }
        XCTAssertEqual(worst, 40, accuracy: 0.001, "a dose never waits longer than 40 s for the schedule")
    }

    // Build 177: outside a transition the hold is 20 s — past the latest observed close.
    func testTheSteadyStateHoldIsTwentySeconds() {
        var worst: TimeInterval = 0
        var p: TimeInterval = 0
        while p < 300 { if let r = S.closedRemaining(phase: p, transition: false) { worst = max(worst, r) }; p += 0.5 }
        XCTAssertEqual(worst, 20, accuracy: 0.001)
        XCTAssertNil(S.closedRemaining(phase: 25, transition: false), "steady: open at +25 s")
        XCTAssertNotNil(S.closedRemaining(phase: 25, transition: true), "transition: still closed at +25 s")
        XCTAssertNotNil(S.closedRemaining(phase: 115, transition: false), "the minute-call blackouts stay in both tables")
    }

    func testATransitionLastsFifteenMinutesFromItsTrigger() {
        typealias T = StockLoopSession.TailTransition
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let until = t0.addingTimeInterval(T.length)
        XCTAssertTrue(T.isActive(until: until, now: t0.addingTimeInterval(14 * 60)))
        XCTAssertFalse(T.isActive(until: until, now: t0.addingTimeInterval(16 * 60)))
        XCTAssertFalse(T.isActive(until: nil, now: t0), "no trigger yet: not in transition")
        UserDefaults.standard.removeObject(forKey: T.adaptiveKey)
        XCTAssertFalse(T.adaptiveEnabled, "adaptive hold is off by default until one more departure run")
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
