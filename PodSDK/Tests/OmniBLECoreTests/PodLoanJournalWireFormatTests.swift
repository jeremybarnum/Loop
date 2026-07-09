//
//  PodLoanJournalWireFormatTests.swift
//  OmniBLECoreTests
//
//  Pins the loan journal's JSON wire format. The PHONE decodes this JSON with a
//  hand-written mirror type (WatchLoanJournal, private in Loop's
//  WatchDataManager.swift) because the phone deliberately does not link
//  OmniBLECore. Synthesized Codable derives its JSON keys from case names and
//  associated-value labels — so ANY rename/reorder in PodLoanJournal or
//  PodLoanEvent.Kind silently breaks the phone's dose reconciliation (it falls
//  back to display-only). These tests fail loudly instead.
//
//  If a test here fails because the journal changed INTENTIONALLY, update the
//  phone mirror in Loop/Loop/Managers/WatchDataManager.swift in the same change.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import OmniBLECore

class PodLoanJournalWireFormatTests: XCTestCase {

    private func makeJournal() -> PodLoanJournal {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)   // fixed for determinism
        var journal = PodLoanJournal(startedAt: t0, deliveredAtStart: 10.55)
        journal.record(.bolus(units: 0.5), at: t0.addingTimeInterval(60))
        journal.record(.tempBasal(rate: 0.75, duration: 3 * 60 * 60), at: t0.addingTimeInterval(120))
        journal.record(.suspend, at: t0.addingTimeInterval(180))
        journal.record(.resume, at: t0.addingTimeInterval(240))
        journal.noteDelivered(11.75)
        return journal
    }

    /// The exact key spellings the phone mirror relies on.
    func testWireFormatKeysMatchPhoneMirrorContract() throws {
        let journal = makeJournal()
        let data = try XCTUnwrap(journal.encoded())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Top-level fields the mirror decodes.
        XCTAssertNotNil(root["startedAt"], "startedAt key missing/renamed — phone mirror will fail to decode")
        XCTAssertEqual(root["deliveredAtStart"] as? Double, 10.55)
        XCTAssertEqual(root["deliveredLatest"] as? Double, 11.75)
        let events = try XCTUnwrap(root["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 5)   // tookOver + 4 recorded

        // Every event carries id/date/kind.
        for event in events {
            XCTAssertNotNil(event["id"])
            XCTAssertNotNil(event["date"])
            XCTAssertNotNil(event["kind"])
        }

        // Kind encodings: case name is the key; associated values keyed by label.
        let kinds = events.compactMap { $0["kind"] as? [String: Any] }
        XCTAssertEqual(kinds.count, 5)

        XCTAssertNotNil(kinds[0]["tookOver"])

        let bolus = try XCTUnwrap(kinds[1]["bolus"] as? [String: Any])
        XCTAssertEqual(bolus["units"] as? Double, 0.5)

        let tempBasal = try XCTUnwrap(kinds[2]["tempBasal"] as? [String: Any])
        XCTAssertEqual(tempBasal["rate"] as? Double, 0.75)
        XCTAssertEqual(tempBasal["duration"] as? Double, 3 * 60 * 60)

        XCTAssertNotNil(kinds[3]["suspend"])
        XCTAssertNotNil(kinds[4]["resume"])
    }

    /// Dates must be ISO-8601 strings (the phone decodes with .iso8601).
    func testDatesEncodeAsISO8601() throws {
        let journal = makeJournal()
        let data = try XCTUnwrap(journal.encoded())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let startedAt = try XCTUnwrap(root["startedAt"] as? String)

        let iso = ISO8601DateFormatter()
        XCTAssertNotNil(iso.date(from: startedAt), "startedAt is not ISO-8601 ('\(startedAt)') — phone mirror uses .iso8601 date decoding")
    }

    /// Encoding must be byte-stable for identical journals: the phone's duplicate
    /// hand-back guard hashes the raw bytes, and the watch may re-encode on old
    /// builds — different bytes for the same content would defeat the guard.
    func testEncodingIsDeterministic() throws {
        let journal = makeJournal()
        let first = try XCTUnwrap(journal.encoded())
        for _ in 0..<10 {
            XCTAssertEqual(journal.encoded(), first, "encoded() is not byte-stable — breaks the phone's duplicate-hand-back hash guard")
        }
    }

    /// Round-trip through the journal's own decoder (watch-side restore path).
    func testRoundTrip() throws {
        let journal = makeJournal()
        let data = try XCTUnwrap(journal.encoded())
        let decoded = try XCTUnwrap(PodLoanJournal(data: data))
        XCTAssertEqual(decoded, journal)
    }
}
