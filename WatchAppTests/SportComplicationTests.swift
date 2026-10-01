//
//  SportComplicationTests.swift
//  WatchAppTests
//
//  The SportComplications widgets' text (shared snapshot) and the watch app's reload throttle.
//

import XCTest
@testable import WatchApp_Extension

final class SportComplicationTests: XCTestCase {

    private let now = Date()

    private func snapshot(loopAge: TimeInterval = 60, glucoseAge: TimeInterval = 60, mmol: Bool = false) -> SportComplicationSnapshot {
        SportComplicationSnapshot(glucose: mmol ? 6.7 : 120, glucoseDate: now.addingTimeInterval(-glucoseAge),
                                  iob: 1.24, cob: 23.6, eventual: mmol ? 7.1 : 128,
                                  loopDate: now.addingTimeInterval(-loopAge), mmol: mmol)
    }

    func testShortFormsFitACorner() {
        let s = snapshot()
        XCTAssertEqual(s.short(.iob, at: now), "1.2U")
        XCTAssertEqual(s.short(.cob, at: now), "24g")
        XCTAssertEqual(s.short(.eventual, at: now), "→128")
        XCTAssertEqual(s.short(.glucoseToEventual, at: now), "120→128")
    }

    func testInlineLinesSayWhatEachNumberIs() {
        let s = snapshot()
        XCTAssertEqual(s.line(.iob, at: now), "IOB 1.2 U")
        XCTAssertEqual(s.line(.cob, at: now), "COB 24 g")
        XCTAssertEqual(s.line(.eventual, at: now), "Eventually 128")
        XCTAssertEqual(s.line(.glucoseToEventual, at: now), "BG 120 → 128")
    }

    /// A stale loop must not leave old insulin on the wrist as if it were current.
    func testAStaleLoopShowsDashes() {
        let s = snapshot(loopAge: 20 * 60)
        XCTAssertEqual(s.short(.iob, at: now), "—")
        XCTAssertEqual(s.short(.cob, at: now), "—")
        XCTAssertEqual(s.short(.eventual, at: now), "→—")
        XCTAssertEqual(s.short(.glucoseToEventual, at: now), "120→—", "the reading itself is still fresh")
    }

    func testAStaleReadingDashesOnlyTheCurrentValue() {
        XCTAssertEqual(snapshot(glucoseAge: 20 * 60).short(.glucoseToEventual, at: now), "—→128")
    }

    func testMmolShowsOneDecimal() {
        XCTAssertEqual(snapshot(mmol: true).short(.glucoseToEventual, at: now), "6.7→7.1")
    }

    func testTheTimelineMarksWhenEachValueGoesStale() {
        let s = snapshot(loopAge: 5 * 60, glucoseAge: 2 * 60)
        let moments = s.staleMoments(after: now)
        XCTAssertEqual(moments.count, 2)
        XCTAssertEqual(moments.first!.timeIntervalSince(now), SportComplicationSnapshot.recency + 1 - 5 * 60, accuracy: 0.5)
    }

    func testTheSnapshotRoundTripsThroughSharedDefaults() {
        let defaults = UserDefaults(suiteName: "SportComplicationTests")!
        defaults.removePersistentDomain(forName: "SportComplicationTests")
        snapshot().save(to: defaults)
        XCTAssertEqual(SportComplicationSnapshot.load(from: defaults), snapshot())
    }

    /// WidgetKit budgets reloads: at most one per 5 min, and a change inside that window is not
    /// lost — the owed reload is paid on the next publish after the window.
    func testReloadsAreThrottledButNeverLost() {
        SportComplicationPublisher.resetForTesting()
        defer { SportComplicationPublisher.resetForTesting() }
        var reloads = 0, saves = 0
        func publish(_ s: SportComplicationSnapshot, at t: TimeInterval) {
            SportComplicationPublisher.store(s, now: now.addingTimeInterval(t), save: { _ in saves += 1 }, reload: { reloads += 1 })
        }
        let a = snapshot(), b = SportComplicationSnapshot(glucose: 130, glucoseDate: now, iob: 1.5, cob: 20, eventual: 140, loopDate: now)

        publish(a, at: 0)
        XCTAssertEqual(reloads, 1, "the first value reloads at once")
        publish(a, at: 60)
        XCTAssertEqual(saves, 1, "an unchanged value is not rewritten")
        publish(b, at: 120)
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(reloads, 1, "inside the 5-minute window: saved, reload owed")
        publish(b, at: 301)
        XCTAssertEqual(reloads, 2, "the owed reload is paid once the window passes, even with no new value")
        publish(b, at: 700)
        XCTAssertEqual(reloads, 2, "nothing owed, nothing reloaded")
    }
}
