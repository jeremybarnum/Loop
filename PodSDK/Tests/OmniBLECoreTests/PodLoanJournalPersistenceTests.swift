//
//  PodLoanJournalPersistenceTests.swift
//  OmniBLECoreTests
//
//  §4c-3: the loan journal must survive watch-app crashes/updates. Pins the
//  UserDefaults-backed store and the decode counterpart of encoded().
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import OmniBLECore

class PodLoanJournalPersistenceTests: XCTestCase {

    private var suite: UserDefaults!
    private let suiteName = "PodLoanJournalPersistenceTests"

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        PodLoanJournalStore.defaults = suite
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        PodLoanJournalStore.defaults = .standard
        super.tearDown()
    }

    private func makeJournal() -> PodLoanJournal {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        var journal = PodLoanJournal(startedAt: t0, deliveredAtStart: 12.3)
        journal.record(.bolus(units: 0.85), at: t0.addingTimeInterval(60))
        journal.record(.suspend, at: t0.addingTimeInterval(120))
        return journal
    }

    func testPersistAndRecoverRoundTrip() {
        let journal = makeJournal()
        PodLoanJournalStore.persist(journal)

        let data = PodLoanJournalStore.persistedData()
        XCTAssertNotNil(data, "journal should persist")
        let recovered = PodLoanJournal.decoded(from: data!)
        XCTAssertEqual(recovered, journal, "recovered journal must equal the original (the 0.85 must survive)")
    }

    func testClearRemovesPersistedJournal() {
        PodLoanJournalStore.persist(makeJournal())
        PodLoanJournalStore.clear()
        XCTAssertNil(PodLoanJournalStore.persistedData())
    }

    func testPersistIsUpdatedOnEachMutation() {
        var journal = makeJournal()
        PodLoanJournalStore.persist(journal)
        journal.record(.resume, at: Date(timeIntervalSince1970: 1_780_000_300))
        PodLoanJournalStore.persist(journal)

        let recovered = PodLoanJournal.decoded(from: PodLoanJournalStore.persistedData()!)
        XCTAssertEqual(recovered?.events.count, journal.events.count, "latest persist wins")
    }

    func testDecodedRejectsGarbage() {
        XCTAssertNil(PodLoanJournal.decoded(from: Data([0x00, 0x01])))
    }
}
