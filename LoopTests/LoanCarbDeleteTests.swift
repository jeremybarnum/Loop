//
//  LoanCarbDeleteTests.swift
//  LoopTests
//
//  The wrist-deletes-a-carb round trip, which until now had no test at any layer.
//
//  That gap is the reason this keeps coming back. The feature has shipped twice and failed in
//  the field twice — first on the authorship guard, then on a live run where a carb deleted on
//  the wrist stayed on the phone — and both times the failure was in the last hop, where the
//  phone has to decide WHICH stored entry a wrist deletion names. That decision was written
//  inline in a WatchDataManager closure, so nothing could reach it; the tests that existed
//  covered the journal and the wire and stopped one hop short.
//
//  A missed delete is not inert. `ingestGrantCarbs` mirrors the phone onto the wrist at every
//  takeover, so a deletion the phone never applied is resurrected at the next grant: the user
//  deletes the carb, watches it vanish, and it returns still driving dosing. The safe direction
//  here is genuinely both ways — deleting the WRONG carb overstates nothing but removes real
//  carbs from the prediction, and failing to delete leaves phantom carbs in it — so the matcher
//  is asserted in both directions below.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

final class LoanCarbDeleteTests: XCTestCase {

    private let now = Date()

    private func stored(_ grams: Double, at date: Date, sync: String?) -> StoredCarbEntry {
        StoredCarbEntry(startDate: date,
                        quantity: HKQuantity(unit: .gram(), doubleValue: grams),
                        syncIdentifier: sync)
    }

    private func gone(_ grams: Double, at date: Date, sync: String?) -> LoanReconciler.DeletedCarb {
        LoanReconciler.DeletedCarb(syncIdentifier: sync, startDate: date, grams: grams)
    }

    // MARK: - Identity

    /// A phone-originated carb reaches the wrist through the grant carrying the phone's own
    /// syncIdentifier, so the deletion can name it directly — and must, even when a second entry
    /// would satisfy the natural key. This is the ordinary case and the one that has to stay
    /// exact: with two 30 g entries a minute apart, the natural key alone could take either.
    func testIdentityNamesTheEntryEvenWhenATwinWouldSatisfyTheNaturalKey() {
        let twin = stored(30, at: now.addingTimeInterval(-.minutes(90)), sync: "phone-A")
        let target = stored(30, at: now.addingTimeInterval(-.minutes(91)), sync: "phone-B")

        let match = LoanReconciler.matchDeletedCarb(
            gone(30, at: now.addingTimeInterval(-.minutes(91)), sync: "phone-B"),
            among: [twin, target])

        XCTAssertEqual(match?.syncIdentifier, "phone-B")
    }

    /// A carb entered ON the wrist has no shared identity at all — `.carb` records carry none and
    /// each CarbStore mints its own — so the deletion travels with a nil syncIdentifier and the
    /// natural key is the only key there is.
    func testAWatchEnteredCarbIsMatchedOnTimeAndGrams() {
        let start = now.addingTimeInterval(-.minutes(20))
        let entry = stored(18, at: start, sync: "phone-minted-later")

        let match = LoanReconciler.matchDeletedCarb(gone(18, at: start, sync: nil), among: [entry])

        XCTAssertEqual(match?.syncIdentifier, "phone-minted-later")
    }

    /// THE REGRESSION THIS FILE WAS WRITTEN FOR.
    ///
    /// The wrist names an identity the phone's store no longer holds — an entry re-minted by an
    /// edit, or resynced from HealthKit under a new one. Time and grams still match exactly, so
    /// the design's stated rule ("syncIdentifier first, falling back to startDate and grams")
    /// resolves it.
    ///
    /// The single-predicate form did not do that. Asking each entry "same syncIdentifier, or
    /// failing that same time and grams?" lets an entry with a DIFFERENT identity answer no
    /// outright, so the fallback could only ever see entries whose syncIdentifier was nil — and
    /// here there are none. The delete missed, and the carb came back at the next grant.
    func testAnIdentityThatNamesNothingFallsBackToTimeAndGrams() {
        let start = now.addingTimeInterval(-.hours(2))
        let entry = stored(45, at: start, sync: "phone-remint-9f2c")

        let match = LoanReconciler.matchDeletedCarb(
            gone(45, at: start, sync: "phone-stale-1a0b"),
            among: [entry])

        XCTAssertEqual(match?.syncIdentifier, "phone-remint-9f2c",
                       "an identity that names nothing must fall back to the natural key, not miss")
    }

    /// Age is not a term in the match. The wrist lists carbs back to the start of the day, so the
    /// entry a user deletes can easily predate the loan by hours — which is exactly the entry
    /// that failed in the field. Nothing in the matcher may scope to the loan window.
    func testAnAncientCarbMatchesLikeAnyOther() {
        let start = now.addingTimeInterval(-.hours(9))     // hours before any loan began
        let entry = stored(62, at: start, sync: "phone-breakfast")

        XCTAssertEqual(LoanReconciler.matchDeletedCarb(gone(62, at: start, sync: "phone-breakfast"),
                                                       among: [entry])?.syncIdentifier,
                       "phone-breakfast")
        XCTAssertEqual(LoanReconciler.matchDeletedCarb(gone(62, at: start, sync: nil),
                                                       among: [entry])?.syncIdentifier,
                       "phone-breakfast",
                       "and by natural key too — the wrist may hold no identity for an old entry")
    }

    // MARK: - Refusing to guess

    /// Nothing plausibly matches → delete nothing. The caller logs the miss loudly with the
    /// candidate lineup; deleting an unrelated carb because a key was ambiguous is the worse
    /// outcome, since the user never asked for that one to go.
    func testNothingComparableMatchesNothing() {
        let entries = [stored(30, at: now.addingTimeInterval(-.minutes(10)), sync: "a"),
                       stored(12, at: now.addingTimeInterval(-.hours(3)), sync: "b")]

        XCTAssertNil(LoanReconciler.matchDeletedCarb(
            gone(75, at: now.addingTimeInterval(-.minutes(44)), sync: "not-here"), among: entries))
        XCTAssertNil(LoanReconciler.matchDeletedCarb(gone(75, at: now, sync: nil), among: []))
    }

    /// The natural key is (within a second, within a hundredth of a gram). A carb at the same
    /// instant but a different size is a DIFFERENT carb — the 30 g the user deleted is not the
    /// 45 g sitting beside it, and matching loosely on time alone would take the wrong one.
    func testSameInstantDifferentGramsIsNotAMatch() {
        let start = now.addingTimeInterval(-.minutes(30))
        XCTAssertNil(LoanReconciler.matchDeletedCarb(gone(30, at: start, sync: nil),
                                                     among: [stored(45, at: start, sync: nil)]))
    }

    /// And the time half of the key: same grams, minutes apart, is a different eating occasion.
    func testSameGramsMinutesApartIsNotAMatch() {
        let start = now.addingTimeInterval(-.minutes(30))
        XCTAssertNil(LoanReconciler.matchDeletedCarb(
            gone(30, at: start, sync: nil),
            among: [stored(30, at: start.addingTimeInterval(-.minutes(7)), sync: nil)]))
    }

    // MARK: - What the drain hands the phone

    /// The reconciler side: a deletion of a grant-carried carb must arrive at the phone carrying
    /// the identity the wrist saw, so the matcher above has something exact to work with.
    func testADrainedDeletionCarriesTheIdentityTheWristSaw() {
        let start = now.addingTimeInterval(-.hours(6))
        let record = LoanDoseRecord(kind: .carbDeleted, startDate: start, amount: 62,
                                    syncIdentifier: "phone-breakfast")
        let outcome = LoanReconciler.reconcile(LoanReconciler.Input(
            events: [LoanEvent(id: UUID(), seq: 1, provenance: .confirmed, record: record, loggedAt: now)],
            odometer: nil, schedule: nil,
            loanStart: now.addingTimeInterval(-.hours(1)), loanEnd: now))

        XCTAssertEqual(outcome.deletedCarbs,
                       [LoanReconciler.DeletedCarb(syncIdentifier: "phone-breakfast",
                                                   startDate: start, grams: 62)])
        XCTAssertTrue(outcome.carbs.isEmpty)
        XCTAssertTrue(outcome.doses.isEmpty, "a carb deletion is not dose accounting")
    }

    /// A deletion whose carb starts hours before the loan still drains. The loan window governs
    /// the insulin audit, never the carb records — and the field failure was precisely an entry
    /// older than the loan.
    func testADeletionOlderThanTheLoanStillDrains() {
        let start = now.addingTimeInterval(-.hours(11))    // loan began one hour ago
        let record = LoanDoseRecord(kind: .carbDeleted, startDate: start, amount: 40,
                                    syncIdentifier: "phone-lastnight")
        let outcome = LoanReconciler.reconcile(LoanReconciler.Input(
            events: [LoanEvent(id: UUID(), seq: 1, provenance: .confirmed, record: record, loggedAt: now)],
            odometer: nil, schedule: nil,
            loanStart: now.addingTimeInterval(-.hours(1)), loanEnd: now))

        XCTAssertEqual(outcome.deletedCarbs.count, 1)
        XCTAssertEqual(outcome.deletedCarbs.first?.grams, 40)
    }

    /// Add-then-delete on the wrist inside one drain must reach the phone as NOTHING. The phone
    /// never minted an identity for a wrist-entered carb, so an add followed by a delete would
    /// leave the delete unresolvable and the carb standing — worse than never sending either.
    func testAddThenDeleteInOneDrainCancelsToNothing() {
        let start = now.addingTimeInterval(-.minutes(40))
        let added = LoanEvent(id: UUID(), seq: 1, provenance: .confirmed,
                              record: LoanDoseRecord(kind: .carb, startDate: start, amount: 25,
                                                     absorptionTime: .hours(3)),
                              loggedAt: start)
        let removed = LoanEvent(id: UUID(), seq: 2, provenance: .confirmed,
                                record: LoanDoseRecord(kind: .carbDeleted, startDate: start, amount: 25),
                                loggedAt: now)

        let outcome = LoanReconciler.reconcile(LoanReconciler.Input(
            events: [added, removed], odometer: nil, schedule: nil,
            loanStart: now.addingTimeInterval(-.hours(1)), loanEnd: now))

        XCTAssertTrue(outcome.carbs.isEmpty, "the add is cancelled")
        XCTAssertTrue(outcome.deletedCarbs.isEmpty, "and so is the delete — the phone must see nothing")
    }

    /// The pair only cancels when it IS a pair. A wrist-entered 25 g carb plus a deletion of a
    /// DIFFERENT 25 g carb from the morning must land as one add and one delete.
    func testAnUnrelatedDeletionDoesNotCancelAWristEntry() {
        let entered = now.addingTimeInterval(-.minutes(40))
        let morning = now.addingTimeInterval(-.hours(8))
        let added = LoanEvent(id: UUID(), seq: 1, provenance: .confirmed,
                              record: LoanDoseRecord(kind: .carb, startDate: entered, amount: 25),
                              loggedAt: entered)
        let removed = LoanEvent(id: UUID(), seq: 2, provenance: .confirmed,
                                record: LoanDoseRecord(kind: .carbDeleted, startDate: morning, amount: 25,
                                                       syncIdentifier: "phone-morning"),
                                loggedAt: now)

        let outcome = LoanReconciler.reconcile(LoanReconciler.Input(
            events: [added, removed], odometer: nil, schedule: nil,
            loanStart: now.addingTimeInterval(-.hours(1)), loanEnd: now))

        XCTAssertEqual(outcome.carbs.count, 1)
        XCTAssertEqual(outcome.deletedCarbs.count, 1)
        XCTAssertEqual(outcome.deletedCarbs.first?.syncIdentifier, "phone-morning")
    }

    // MARK: - End to end

    /// The whole hop, joined: what the wrist journals, through the reconciler, into the phone's
    /// pick from its own store. Each half is asserted above; this is the one that would have
    /// caught the field failure, because the failure lived in the join.
    func testTheDrainedDeletionResolvesAgainstThePhonesStore() {
        let start = now.addingTimeInterval(-.hours(7))
        let phoneStore = [stored(20, at: now.addingTimeInterval(-.minutes(15)), sync: "phone-snack"),
                          stored(62, at: start, sync: "phone-breakfast"),
                          stored(9, at: now.addingTimeInterval(-.hours(2)), sync: nil)]

        let record = LoanDoseRecord(kind: .carbDeleted, startDate: start, amount: 62,
                                    syncIdentifier: "phone-breakfast")
        let outcome = LoanReconciler.reconcile(LoanReconciler.Input(
            events: [LoanEvent(id: UUID(), seq: 1, provenance: .confirmed, record: record, loggedAt: now)],
            odometer: nil, schedule: nil,
            loanStart: now.addingTimeInterval(-.hours(1)), loanEnd: now))

        let victim = outcome.deletedCarbs.compactMap { LoanReconciler.matchDeletedCarb($0, among: phoneStore) }
        XCTAssertEqual(victim.count, 1)
        XCTAssertEqual(victim.first?.syncIdentifier, "phone-breakfast")
        XCTAssertEqual(victim.first?.quantity.doubleValue(for: .gram()), 62)
    }
}
