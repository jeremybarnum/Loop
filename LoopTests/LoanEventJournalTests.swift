//
//  LoanEventJournalTests.swift
//  LoopTests
//
//  The watch's dose ledger, under test for the first time (coverage plan item 5,
//  2026-08-11). `LoanEventJournal` is the exactly-once contract's watch half: it mints
//  the per-loan seq, decides what is still unacked (i.e. what gets streamed to the phone),
//  and applies the phone's ack cursor. A defect here silently loses or duplicates insulin
//  records, which is why it should have been the FIRST thing covered rather than the last.
//
//  It became testable at all because it imports only Foundation + os.log — no WatchKit, no
//  WCSession — so adding it to the LoopTests target costs nothing. Its siblings
//  (PodLoanWatchController, WatchLoopManager) are not so lucky; see TEST_COVERAGE_PLAN.md
//  "Corrections" for why the rest of the watch half is still out of reach.
//
//  Every test uses its own temp directory: the journal persists to a fixed FILENAME under
//  whatever directory it is given, so a shared directory would leak state between tests —
//  the flake class we are already chasing elsewhere.
//

import XCTest
@testable import Loop

final class LoanEventJournalTests: XCTestCase {

    private var dirs: [URL] = []

    override func tearDown() {
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        dirs = []
        super.tearDown()
    }

    private func makeJournal() -> LoanEventJournal {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        return LoanEventJournal(directory: dir)
    }

    /// Reopen the SAME directory — the relaunch case.
    private func reopen(_ dir: URL) -> LoanEventJournal {
        return LoanEventJournal(directory: dir)
    }

    private func bolus(_ units: Double, at date: Date = Date()) -> LoanDoseRecord {
        LoanDoseRecord(kind: .bolus, startDate: date, amount: units)
    }

    // MARK: - Seq and streaming

    func testSeqStartsAtOneAndIncrementsPerEvent() throws {
        let journal = makeJournal()
        try journal.begin(epoch: 1)

        let first = try journal.mintEvent(record: bolus(1.0), provenance: .confirmed)
        let second = try journal.mintEvent(record: bolus(2.0), provenance: .confirmed)

        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(second.seq, 2)
        XCTAssertEqual(journal.lastEventSeq, 2)
    }

    func testUnackedEventsAreEverythingAboveTheCursor() throws {
        let journal = makeJournal()
        try journal.begin(epoch: 1)
        _ = try journal.mintEvent(record: bolus(1.0), provenance: .confirmed)
        _ = try journal.mintEvent(record: bolus(2.0), provenance: .confirmed)
        _ = try journal.mintEvent(record: bolus(3.0), provenance: .confirmed)

        XCTAssertEqual(journal.unackedEvents().map(\.seq), [1, 2, 3])

        journal.applyAck(committedCursor: 2)
        XCTAssertEqual(journal.unackedEvents().map(\.seq), [3], "acked events stop streaming")
    }

    /// The ack cursor is MONOTONIC. A stale or replayed ack — routine, since offers resend
    /// every 15 s and acks can arrive out of order — must never move it backward, which
    /// would re-stream already-committed records.
    func testStaleAckCannotMoveTheCursorBackward() throws {
        let journal = makeJournal()
        try journal.begin(epoch: 1)
        for units in [1.0, 2.0, 3.0] { _ = try journal.mintEvent(record: bolus(units), provenance: .confirmed) }

        journal.applyAck(committedCursor: 3)
        XCTAssertTrue(journal.unackedEvents().isEmpty)

        journal.applyAck(committedCursor: 1)   // replayed older ack
        XCTAssertTrue(journal.unackedEvents().isEmpty, "a replayed ack must not resurrect committed events")
    }

    /// §16's seq-gap concern, at the journal layer: the cursor is a WATERMARK, so acking a
    /// later seq silently covers an earlier one. This is exactly why
    /// PodLoanWatchController.handleAck caps the applied cursor below the lowest WITHHELD
    /// seq before calling applyAck — the journal itself cannot know an event was withheld.
    /// Pinned so that a future "simplification" of the cap has to argue with a red test.
    func testCursorIsAWatermarkSoAGapMustBeCappedByTheCaller() throws {
        let journal = makeJournal()
        try journal.begin(epoch: 1)
        let withheld = try journal.mintEvent(record: bolus(1.0), provenance: .assumed(.bolusUncertain))
        let later = try journal.mintEvent(record: bolus(2.0), provenance: .confirmed)

        // The phone only ever saw `later` (the uncertain one was withheld), so it acks 2.
        // Applied raw — no `withholding` — that buries the withheld event forever. This is
        // the trap, and it is still reachable, because a caller with nothing withheld is the
        // common case and must stay cheap.
        journal.applyAck(committedCursor: later.seq)
        XCTAssertFalse(journal.unackedEvents().contains { $0.id == withheld.id },
                       "raw max-seq ack buries the withheld event — this is what `withholding:` exists to prevent")

        // Now the production path. The caller names the withheld ID; the JOURNAL computes the
        // cap. Before 2026-08-12 this line read `applyAck(committedCursor: min(later2.seq,
        // withheld2.seq - 1))` — the test doing the controller's arithmetic for it, so no
        // change to `handleAck` could ever turn this red. The cap now lives in the journal and
        // this exercises it.
        let capped = makeJournal()
        try capped.begin(epoch: 1)
        let withheld2 = try capped.mintEvent(record: bolus(1.0), provenance: .assumed(.bolusUncertain))
        let later2 = try capped.mintEvent(record: bolus(2.0), provenance: .confirmed)
        capped.applyAck(committedCursor: later2.seq, withholding: [withheld2.id])

        XCTAssertTrue(capped.unackedEvents().contains { $0.id == withheld2.id },
                      "capped ack keeps the withheld event streamable once it classifies")
        XCTAssertTrue(capped.unackedEvents().contains { $0.id == later2.id },
                      "the LATER event is withheld too — a max-seq cursor cannot commit seq 2 while seq 1 is open, so it re-streams and the phone dedups it by ID")
    }

    /// The cap must bite ONLY on the withheld events, and only while they are still unacked.
    /// Two failure modes this pins, both of which would look like "the loan never drains":
    /// a cap computed from an already-acked event would freeze the cursor forever, and a cap
    /// applied when the withheld ID is not in the journal at all (annulled mid-drain — the
    /// certain-refusal path, #99) would do the same.
    func testCapIgnoresWithheldEventsThatAreAlreadyAckedOrGone() throws {
        let journal = makeJournal()
        try journal.begin(epoch: 1)
        let first = try journal.mintEvent(record: bolus(1.0), provenance: .confirmed)
        let second = try journal.mintEvent(record: bolus(2.0), provenance: .confirmed)

        // `first` is committed and acked normally.
        journal.applyAck(committedCursor: first.seq)
        XCTAssertEqual(journal.unackedEvents().map(\.seq), [second.seq])

        // A later ack still naming `first` as withheld must NOT drag the cursor back to 0.
        // (`applyAck` is monotonic, so the regression would surface as a stuck cursor rather
        // than a rewind — either way the loan stops draining.)
        journal.applyAck(committedCursor: second.seq, withholding: [first.id])
        XCTAssertTrue(journal.unackedEvents().isEmpty,
                      "an already-acked event must not cap the cursor — the loan would never drain")

        // An ID the journal has never heard of (annulled, or from a prior epoch) is inert.
        let other = makeJournal()
        try other.begin(epoch: 2)
        let only = try other.mintEvent(record: bolus(3.0), provenance: .confirmed)
        other.applyAck(committedCursor: only.seq, withholding: [UUID()])
        XCTAssertTrue(other.unackedEvents().isEmpty,
                      "an unknown withheld ID must not cap the cursor")
    }

    /// The gap case with THREE events, which is where an off-by-one shows itself: withholding
    /// the middle one must commit everything below it and nothing at or above it.
    func testCapCommitsBelowTheGapAndNothingAtOrAboveIt() throws {
        let journal = makeJournal()
        try journal.begin(epoch: 1)
        let below = try journal.mintEvent(record: bolus(1.0), provenance: .confirmed)
        let gap = try journal.mintEvent(record: bolus(2.0), provenance: .assumed(.bolusUncertain))
        let above = try journal.mintEvent(record: bolus(3.0), provenance: .confirmed)

        journal.applyAck(committedCursor: above.seq, withholding: [gap.id])

        let stillOpen = Set(journal.unackedEvents().map(\.id))
        XCTAssertFalse(stillOpen.contains(below.id), "seq below the gap is safely committed")
        XCTAssertTrue(stillOpen.contains(gap.id), "the withheld event stays open")
        XCTAssertTrue(stillOpen.contains(above.id), "seq above the gap re-streams; the phone dedups by ID")
    }

    // MARK: - Relaunch recovery

    /// The recovered-hand-back trigger: a relaunch that finds unacked events must report
    /// undrained work, and must NOT report it once everything is acked. This is the flag
    /// that decides whether a relaunched watch enters drain-only mode.
    func testRelaunchSeesUndrainedEventsUntilTheyAreAcked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)

        let journal = LoanEventJournal(directory: dir)
        try journal.begin(epoch: 4)
        _ = try journal.mintEvent(record: bolus(1.0), provenance: .confirmed)

        let afterCrash = reopen(dir)
        XCTAssertTrue(afterCrash.hasUndrainedEvents, "a relaunch with unacked events is a recovered hand-back")
        XCTAssertEqual(afterCrash.activeEpoch, 4, "the epoch survives the relaunch")
        XCTAssertEqual(afterCrash.unackedEvents().count, 1)

        afterCrash.applyAck(committedCursor: 1)
        let afterDrain = reopen(dir)
        XCTAssertFalse(afterDrain.hasUndrainedEvents, "once acked, a relaunch has nothing to recover")
    }

    /// Tombstones are pending work in their own right. The sequence that produces a LONE
    /// tombstone is the real one: an assumed event streams, the phone commits it and acks,
    /// and only THEN does the pod verdict refute it — so the phone holds a dose the watch
    /// has since retracted. `annul` removes the event and leaves the tombstone, and
    /// `hasUndrainedEvents` must stay true on that tombstone alone, or a relaunch would
    /// drop the retraction and leave phantom insulin on the phone's books.
    ///
    /// (Ordering matters: `applyAck` CLEARS tombstones, since the commit it reports covers
    /// them — see testAckClearsTombstones. Annulling before the ack, as an earlier draft of
    /// this test did, therefore proves nothing.)
    func testTombstoneMintedAfterTheAckKeepsTheJournalUndrained() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)

        let journal = LoanEventJournal(directory: dir)
        try journal.begin(epoch: 2)
        let event = try journal.mintEvent(record: bolus(1.0), provenance: .assumed(.bolusUncertain))
        journal.applyAck(committedCursor: event.seq)      // phone committed it...
        XCTAssertTrue(journal.unackedEvents().isEmpty, "precondition: nothing left unacked")

        journal.annul(id: event.id)                       // ...then the verdict refuted it

        XCTAssertEqual(journal.pendingTombstones(), [event.id], "the retraction is pending delivery")
        XCTAssertTrue(journal.hasUndrainedEvents, "a lone tombstone is undrained work")
        XCTAssertTrue(reopen(dir).hasUndrainedEvents, "and it survives a relaunch")
    }

    /// An ack clears tombstones, because the commit it reports covers them.
    func testAckClearsTombstones() throws {
        let journal = makeJournal()
        try journal.begin(epoch: 1)
        let event = try journal.mintEvent(record: bolus(1.0), provenance: .assumed(.bolusUncertain))
        journal.annul(id: event.id)
        XCTAssertEqual(journal.pendingTombstones().count, 1)

        journal.applyAck(committedCursor: event.seq)
        XCTAssertTrue(journal.pendingTombstones().isEmpty)
    }

    // MARK: - Loan boundaries

    /// Refusing to clobber an undrained prior loan is the guard that keeps one loan's
    /// records from vanishing when the next one starts.
    func testStartLoanRefusesToClobberAnUndrainedPriorLoan() throws {
        let journal = makeJournal()
        try journal.begin(epoch: 1)
        _ = try journal.mintEvent(record: bolus(1.0), provenance: .confirmed)

        XCTAssertThrowsError(try journal.begin(epoch: 2)) { error in
            guard case LoanJournalError.undrainedPriorLoan(let epoch) = error else {
                return XCTFail("expected undrainedPriorLoan, got \(error)")
            }
            XCTAssertEqual(epoch, 1)
        }
    }

    func testMintWithoutAnActiveLoanThrows() throws {
        let journal = makeJournal()
        XCTAssertThrowsError(try journal.mintEvent(record: bolus(1.0), provenance: .confirmed)) { error in
            guard case LoanJournalError.noActiveLoan = error else {
                return XCTFail("expected noActiveLoan, got \(error)")
            }
        }
    }
}
