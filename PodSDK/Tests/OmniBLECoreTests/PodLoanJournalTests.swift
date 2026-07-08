//
//  PodLoanJournalTests.swift
//  OmniBLECoreTests
//
//  Tests for the loan journal (Phase-1 capture + display, and the Codable
//  transport used to hand it back to the phone).
//

import XCTest
@testable import OmniBLECore

final class PodLoanJournalTests: XCTestCase {

    private func fixedDate(_ minutesFromBase: Double) -> Date {
        // A deterministic base date so tests don't depend on the wall clock.
        Date(timeIntervalSinceReferenceDate: 800_000_000).addingTimeInterval(minutesFromBase * 60)
    }

    func testBolusTallyAndSummary() {
        var j = PodLoanJournal(startedAt: fixedDate(0), deliveredAtStart: 10.0)
        j.record(.bolus(units: 0.5), at: fixedDate(1))
        j.record(.bolus(units: 0.5), at: fixedDate(2))
        j.record(.bolus(units: 0.5), at: fixedDate(3))
        j.noteDelivered(11.6)   // pod says +1.6 U over the loan (basal + boluses)

        XCTAssertEqual(j.bolusCount, 3)
        XCTAssertEqual(j.totalBolusUnits, 1.5, accuracy: 1e-9)
        XCTAssertEqual(j.podDeliveredDelta ?? -1, 1.6, accuracy: 1e-9)
        XCTAssertFalse(j.isSuspended)

        let text = j.summaryText
        XCTAssertTrue(text.contains("1.50 U"))
        XCTAssertTrue(text.contains("3 bolus"))
    }

    func testSuspendWindowAndOngoingSuspend() {
        var j = PodLoanJournal(startedAt: fixedDate(0))
        j.record(.suspend, at: fixedDate(5))
        j.record(.resume, at: fixedDate(35))     // 30-min closed window
        j.record(.suspend, at: fixedDate(50))    // still suspended at end

        XCTAssertTrue(j.isSuspended)
        let windows = j.suspendWindows
        XCTAssertEqual(windows.count, 2)
        XCTAssertNotNil(windows[0].end)
        XCTAssertNil(windows[1].end)

        let lines = j.summaryLines(now: fixedDate(60))
        XCTAssertTrue(lines.contains { $0.contains("still suspended") })
        XCTAssertTrue(lines.contains { $0.contains("⚠️") })
    }

    func testBasalOnlySummary() {
        let j = PodLoanJournal(startedAt: fixedDate(0))
        let lines = j.summaryLines(now: fixedDate(10))
        XCTAssertTrue(lines.contains { $0.contains("basal only") })
    }

    func testCodableRoundTripPreservesEventsAndTotals() {
        var j = PodLoanJournal(startedAt: fixedDate(0), deliveredAtStart: 5.0)
        j.record(.bolus(units: 0.5), at: fixedDate(1))
        j.record(.suspend, at: fixedDate(2))
        j.record(.resume, at: fixedDate(10))
        j.record(.handedBack, at: fixedDate(11))
        j.noteDelivered(6.7)

        guard let data = j.encoded() else { return XCTFail("encode failed") }
        guard let round = PodLoanJournal(data: data) else { return XCTFail("decode failed") }

        XCTAssertEqual(round, j)
        XCTAssertEqual(round.totalBolusUnits, 0.5, accuracy: 1e-9)
        XCTAssertEqual(round.podDeliveredDelta ?? -1, 1.7, accuracy: 1e-9)
        XCTAssertEqual(round.events.count, j.events.count)
    }
}
