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

    // MARK: - Orphan slot (DESIGN-6)

    func testOrphanPreservesDisplacedJournalAcrossNewSessionPersists() {
        let oldJournal = makeJournal()
        PodLoanJournalStore.persist(oldJournal)

        // New takeover: displace, then persist a new session's journal.
        PodLoanJournalStore.orphanActiveJournal()
        var newJournal = PodLoanJournal(startedAt: Date(timeIntervalSince1970: 1_780_100_000))
        newJournal.record(.bolus(units: 0.5), at: Date(timeIntervalSince1970: 1_780_100_060))
        PodLoanJournalStore.persist(newJournal)

        // The undelivered old journal must still be the recoverable one.
        let recoverable = PodLoanJournal.decoded(from: PodLoanJournalStore.recoverableData()!)
        XCTAssertEqual(recoverable, oldJournal, "orphan (undelivered) journal must win over the live session's persists")
    }

    func testClearRecoverableClearsOrphanFirstThenActive() {
        PodLoanJournalStore.persist(makeJournal())
        PodLoanJournalStore.orphanActiveJournal()
        let newJournal = PodLoanJournal(startedAt: Date(timeIntervalSince1970: 1_780_100_000))
        PodLoanJournalStore.persist(newJournal)

        PodLoanJournalStore.clearRecoverable()   // clears the orphan
        let next = PodLoanJournal.decoded(from: PodLoanJournalStore.recoverableData()!)
        XCTAssertEqual(next, newJournal, "after orphan ack, the active slot becomes recoverable")

        PodLoanJournalStore.clearRecoverable()   // clears the active slot
        XCTAssertNil(PodLoanJournalStore.recoverableData())
    }

    func testOrphanOfEmptyActiveSlotIsNoOp() {
        PodLoanJournalStore.orphanActiveJournal()
        XCTAssertNil(PodLoanJournalStore.recoverableData())
    }

    // MARK: - C10 pending-command slot (intent-before-transmission)

    func testOrphanedPendingBolusFoldsIntoActiveJournal() {
        PodLoanJournalStore.persist(makeJournal())
        let t = Date(timeIntervalSince1970: 1_780_000_500)
        PodLoanJournalStore.persistPending(PodLoanPendingCommand(date: t, kind: .bolus(units: 1.0)))

        let recovered = PodLoanJournalStore.recoverableData().flatMap(PodLoanJournal.decoded(from:))
        // 0.85 from makeJournal + the folded 1.0 orphan
        XCTAssertEqual(recovered?.totalBolusUnits, 1.85)
        XCTAssertEqual(recovered?.events.last?.date, t)
        XCTAssertNil(PodLoanJournalStore.pending(), "fold must consume the pending slot")
    }

    func testOrphanedPendingZeroTempIsNotFolded() {
        PodLoanJournalStore.persist(makeJournal())
        PodLoanJournalStore.persistPending(PodLoanPendingCommand(kind: .tempBasal(rate: 0, duration: 1800)))

        let recovered = PodLoanJournalStore.recoverableData().flatMap(PodLoanJournal.decoded(from:))
        // Max-exposure: an unconfirmed zero-temp must NOT reduce modeled insulin.
        XCTAssertEqual(recovered?.tempBasalCount, 0)
        XCTAssertNil(PodLoanJournalStore.pending(), "slot is consumed even when nothing is recorded")
    }

    func testOrphanedPendingPositiveTempIsFolded() {
        PodLoanJournalStore.persist(makeJournal())
        PodLoanJournalStore.persistPending(PodLoanPendingCommand(kind: .tempBasal(rate: 2.5, duration: 10800)))

        let recovered = PodLoanJournalStore.recoverableData().flatMap(PodLoanJournal.decoded(from:))
        XCTAssertEqual(recovered?.tempBasalCount, 1)
        XCTAssertEqual(recovered?.lastTempBasalRate, 2.5)
    }

    func testOrphanedPendingCancelFoldedOnlyOverZeroTemp() {
        // Over a zero-temp: cancelling resumes schedule -> more insulin -> fold.
        var journal = makeJournal()
        journal.record(.tempBasal(rate: 0, duration: 1800), at: Date(timeIntervalSince1970: 1_780_000_300))
        PodLoanJournalStore.persist(journal)
        PodLoanJournalStore.persistPending(PodLoanPendingCommand(kind: .cancelTempBasal))
        var recovered = PodLoanJournalStore.recoverableData().flatMap(PodLoanJournal.decoded(from:))
        XCTAssertNil(recovered?.lastTempBasalRate, "cancel over zero-temp is folded (temp no longer modeled)")
        PodLoanJournalStore.clear()

        // Over a positive temp: NOT folded (journal keeps modeling the higher temp).
        var journal2 = makeJournal()
        journal2.record(.tempBasal(rate: 3.0, duration: 1800), at: Date(timeIntervalSince1970: 1_780_000_300))
        PodLoanJournalStore.persist(journal2)
        PodLoanJournalStore.persistPending(PodLoanPendingCommand(kind: .cancelTempBasal))
        recovered = PodLoanJournalStore.recoverableData().flatMap(PodLoanJournal.decoded(from:))
        XCTAssertEqual(recovered?.lastTempBasalRate, 3.0, "cancel over above-zero temp must NOT be folded")
    }

    func testTakeoverDisplacementFoldsPendingBeforeOrphaning() {
        PodLoanJournalStore.persist(makeJournal())
        PodLoanJournalStore.persistPending(PodLoanPendingCommand(kind: .resume))
        PodLoanJournalStore.orphanActiveJournal()

        let orphan = PodLoanJournalStore.recoverableData().flatMap(PodLoanJournal.decoded(from:))
        XCTAssertEqual(orphan?.events.filter { $0.kind == .resume }.count, 1,
                       "pending resume must ride the journal into the orphan slot")
        XCTAssertNil(PodLoanJournalStore.pending())
    }

    // MARK: - Layer 1 (uncertainty resolution) annulment

    func testRemoveEventsAnnulsOnlyTheGivenIDs() {
        var journal = makeJournal()
        let phantomID = journal.record(.bolus(units: 2.0), at: Date(timeIntervalSince1970: 1_780_000_400))
        XCTAssertEqual(journal.totalBolusUnits, 2.85)

        journal.removeEvents(withIDs: [phantomID])
        XCTAssertEqual(journal.totalBolusUnits, 0.85, "only the refuted phantom is annulled")
        XCTAssertEqual(journal.bolusCount, 1)

        // Round-trips: the annulment survives encode/persist/decode.
        PodLoanJournalStore.persist(journal)
        let recovered = PodLoanJournalStore.recoverableData().flatMap(PodLoanJournal.decoded(from:))
        XCTAssertEqual(recovered?.totalBolusUnits, 0.85)
    }
}
