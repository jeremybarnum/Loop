//
//  LoanTwoSidedContractTests.swift
//  LoopTests
//
//  Coverage plan item 5: the two ends of the loan protocol in ONE process, joined by a
//  transport, asserting BOTH books at once.
//
//  Everything here is production code except one piece:
//
//    REAL  PodLoanPhoneController  — the phone half entire, driven through its Deps seam
//    REAL  LoanEventJournal        — the watch's protocol ledger, cursor arithmetic included
//    REAL  LoanMessage wire format — every hop encodes to a transport dictionary and decodes
//                                    back, so a Codable regression fails here and not in the field
//    MODEL WatchDrainDriver        — the watch's PHASE MACHINE only (see below)
//
//  Why the watch's phase machine is modeled and not executed: `PodLoanWatchController` is a
//  member of the `WatchApp Extension` target only, and its transitive closure reaches
//  `ExtensionDelegate`, `ChartHUDController`, `HUDInterfaceController` and `WKExtension` —
//  measured, not assumed (2026-08-12). Compiling that into the iOS test host is not a cost
//  worth paying; the honest unblock is a watchOS unit-test target, which is real
//  infrastructure and is recorded as such in TEST_COVERAGE_PLAN.md rather than hand-waved.
//
//  So be precise about what these tests are worth. They CANNOT catch a bug in the watch's
//  phase transitions — `cancelHandback`, the finalize gates, the `.handingBack`/`.revoked`
//  guards. What they CAN catch is every defect in the JOINT behavior: the wire format, the
//  phone's commit/dedup/ack, the journal's cursor, and — the part no single-sided test can
//  reach — whether the watch's cursor cap and the phone's ID dedup actually COMPOSE. Test 3
//  is that property, and it is the one that motivated the file: each side is individually
//  correct under its own tests and could still lose insulin between them.
//
//  Conventions: one temp directory per journal (the journal persists to a fixed filename);
//  UserDefaults + staging file cleared per test, matching PodLoanPhoneControllerTests, since
//  the phone controller persists there. Every instant derives from one `let now` so the
//  arithmetic is deterministic run-to-run.
//

import XCTest
import HealthKit
import LoopKit
import LoopCore
import MockKit
@testable import Loop

// MARK: - The modeled watch half

/// The watch's drain loop, and nothing else.
///
/// It owns a REAL `LoanEventJournal` and speaks the REAL wire format; what it models is the
/// decision of WHEN to offer and WHAT to withhold. Kept deliberately small — every line here
/// is a line that could disagree with `PodLoanWatchController` without anything noticing, so
/// the less of it there is, the less the tests can lie.
private final class WatchDrainDriver {

    let journal: LoanEventJournal
    private(set) var epoch: Int?

    /// Events minted but NOT yet streamed — in-flight commands and verdict-chase-pending
    /// ones (§1.3). The controller keeps these in `inFlightEventIDs` / `pendingUncertainEventID`.
    var withheld: Set<UUID> = []

    /// Set by the harness to route into the phone controller.
    var send: (([String: Any]) -> Void)?

    /// Every ack the driver accepted, and the streamed contents of every offer it sent —
    /// the assertion surface for "what actually crossed the wire".
    private(set) var acks: [HandbackAck] = []
    private(set) var offeredEvents: [[LoanEvent]] = []
    private(set) var revoked = false

    init(directory: URL) {
        journal = LoanEventJournal(directory: directory)
    }

    func begin(epoch: Int) throws {
        self.epoch = epoch
        try journal.begin(epoch: epoch)
    }

    @discardableResult
    func mint(_ record: LoanDoseRecord,
              provenance: EventProvenance = .confirmed,
              withhold: Bool = false,
              at date: Date) throws -> LoanEvent {
        let event = try journal.mintEvent(record: record, provenance: provenance, at: date)
        if withhold { withheld.insert(event.id) }
        return event
    }

    /// A command's verdict landed: it may stream from here on.
    func classify(_ event: LoanEvent) {
        withheld.remove(event.id)
        journal.confirm(id: event.id)
    }

    /// The pod REFUTED an assumed command (#99): drop the event and tombstone its ID, so an
    /// already-streamed copy is unwound phone-side. Stops being withheld either way — there is
    /// nothing left to withhold.
    func refute(_ event: LoanEvent) {
        withheld.remove(event.id)
        journal.annul(id: event.id)
    }

    /// Streams everything unacked EXCEPT the withheld set — the controller's `streamRecords`
    /// shape. `released: false` is WS1's interim drain (still dosing, still holding the pod).
    func sendOffer(released: Bool, recovered: Bool = false, at date: Date) {
        guard let epoch = epoch else { return }
        let streamable = journal.unackedEvents().filter { !withheld.contains($0.id) }
        offeredEvents.append(streamable)
        let offer = HandbackOffer(epoch: epoch,
                                  handedBackAt: date,
                                  finalStatus: nil,
                                  odometer: nil,
                                  events: streamable,
                                  tombstones: journal.pendingTombstones(),
                                  recovered: recovered,
                                  released: released,
                                  watchClosedLoopEnabled: true)
        send?(try! LoanMessage.handbackOffer(offer).transportDictionary())
    }

    /// §2.4 streaming: records flow to the phone DURING the loan and are STAGED there, not
    /// committed. This is the path that leaves the phone holding uncommitted records when the
    /// wrist goes quiet, which is the precondition for #66.
    func streamRecords(at date: Date) {
        guard let epoch = epoch else { return }
        let streamable = journal.unackedEvents().filter { !withheld.contains($0.id) }
        send?(try! LoanMessage.doseRecordBatch(
            DoseRecordBatch(epoch: epoch, events: streamable, tombstones: journal.pendingTombstones())
        ).transportDictionary())
    }

    /// The phone→watch direction. Mirrors `handleAck`'s epoch guard and the withholding cap.
    func receive(_ userInfo: [String: Any]) {
        guard let message = try? LoanMessage.decode(fromTransport: userInfo) else { return }
        switch message {
        case .handbackAck(let ack):
            guard ack.epoch == epoch, !ack.stale else { return }
            acks.append(ack)
            journal.applyAck(committedCursor: ack.committedCursor, withholding: withheld)
        case .revoke(let revoke):
            guard revoke.epoch == epoch else { return }
            revoked = true
        default:
            break
        }
    }

    var isDrained: Bool { journal.unackedEvents().isEmpty && journal.pendingTombstones().isEmpty }
}

// MARK: - The joined harness

final class LoanTwoSidedContractTests: XCTestCase {

    private var phone: PodLoanPhoneController!
    private var watch: WatchDrainDriver!
    private var pump: MockPumpManager!
    private var settings: LoopSettings!

    /// Everything the phone committed, and the wire traffic in both directions.
    private var committedDoses: [DoseEntry] = []
    private var committedCarbs: [NewCarbEntry] = []
    private var phoneToWatch: [LoanMessage] = []
    private let lock = NSLock()

    /// Drops the next N phone→watch acks on the floor — the transport-loss fault.
    private var acksToDrop = 0
    /// #118: per-call event counts for addPumpEvents, and an artificial write duration —
    /// the pile-up only exists while a write is slower than the offer cadence.
    private var pumpWriteEventCounts: [Int] = []
    private var pumpWriteDelay: TimeInterval = 0
    /// R36 store emulation + the controller-layer commit counter (see the addCarb stub).
    private var committedCarbIDs: Set<String> = []
    private var rawCarbCommits = 0
    /// e44: every store-identity upsert the phone attempted, and an injectable failure — a
    /// backfill that fails must be treated as a write failure (no ack; the resend is the retry).
    private var backfillCalls: [[DoseEntry]] = []
    private var backfillFailure: Error?

    private var journalDir: URL!

    override func setUp() {
        super.setUp()
        for key in ["PodLoanPhoneController.state", "PodLoanPhoneController.epoch",
                    "PodLoanPhoneController.cursor", "PodLoanPhoneController.pendingRevoke",
                    "PodLoanPhoneController.committedIDs", "PodLoanPhoneController.loanStartedAt",
                    "PodLoanPhoneController.deliveredAuthoritative",
                    "PodLoanPhoneController.residualHistory"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.removeItem(at: base.appendingPathComponent("PodLoanStagedRecordsV2.json"))

        committedDoses = []
        committedCarbs = []
        phoneToWatch = []
        acksToDrop = 0
        pumpWriteEventCounts = []
        pumpWriteDelay = 0
        committedCarbIDs = []
        rawCarbCommits = 0
        backfillCalls = []
        backfillFailure = nil
        pump = MockPumpManager()
        MockPumpManager.testConnectionReleased = false
        MockPumpManager.testOdometer = nil

        let timeZone = TimeZone(identifier: "GMT")!
        settings = LoopSettings(
            dosingEnabled: true,
            glucoseTargetRangeSchedule: GlucoseRangeSchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 110))], timeZone: timeZone),
            insulinSensitivitySchedule: InsulinSensitivitySchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)], timeZone: timeZone),
            basalRateSchedule: BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)], timeZone: timeZone),
            carbRatioSchedule: CarbRatioSchedule(unit: .gram(), dailyItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)], timeZone: timeZone),
            maximumBasalRatePerHour: 3.0,
            maximumBolus: 5.0)

        journalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        watch = WatchDrainDriver(directory: journalDir)
        phone = makePhone()
        // Close the loop: the driver's sends go into the phone controller.
        watch.send = { [weak self] userInfo in self?.phone.handleIncoming(userInfo: userInfo) }
    }

    override func tearDown() {
        // #103: no synchronous unlink of a directory a live object may still be writing.
        //
        // And NO NIL-ING EITHER (2026-08-12): a timed-out waitUntil poller gets a ~1 s grace
        // before its deadline stops it, and `self?.watch.acks` force-unwraps the IUO — so
        // `watch = nil` here turned any timeout into a SIGTRAP that killed the runner and every
        // suite after it (the :615 fatal). XCTest allocates a FRESH INSTANCE per test method,
        // so releasing these properties frees nothing that matters; the next test never sees
        // this instance at all.
        super.tearDown()
    }

    private func makePhone() -> PodLoanPhoneController {
        return PodLoanPhoneController(dependencies: .init(
            pumpManager: { [weak self] in self?.pump },
            settings: { [weak self] in self?.settings ?? LoopSettings() },
            setAutomaticDosingPaused: { _ in },
            send: { [weak self] dictionary in
                guard let self = self else { return }
                guard let message = try? LoanMessage.decode(fromTransport: dictionary) else { return }
                if case .diag = message { return }

                self.lock.lock()
                self.phoneToWatch.append(message)
                var drop = false
                if case .handbackAck = message, self.acksToDrop > 0 {
                    self.acksToDrop -= 1
                    drop = true
                }
                self.lock.unlock()

                // The transport fault: the ack was produced (so the phone believes the
                // records are committed) but never arrives. This is the case that decides
                // whether "exactly once" is a property of the protocol or of good luck.
                guard !drop else { return }
                self.watch.receive(dictionary)
            },
            addPumpEvents: { [weak self] events, _, completion in
                guard let self = self else { completion(nil); return }
                self.lock.lock()
                self.pumpWriteEventCounts.append(events.count)
                self.committedDoses.append(contentsOf: events.compactMap { $0.dose })
                let delay = self.pumpWriteDelay
                self.lock.unlock()
                if delay > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { completion(nil) }
                } else {
                    completion(nil)
                }
            },
            addCarb: { [weak self] entry, syncIdentifier, completion in
                guard let self = self else { completion(nil); return }
                self.lock.lock()
                // Emulates the R36 store: insert-if-absent on the wire identity. carbs() is the
                // STORE view (what a person's record ends up as); rawCarbCommitCount is the
                // CONTROLLER view (how many commit calls were made) — assert on raw when the
                // test is about controller guards, on carbs() when it is about the outcome.
                self.rawCarbCommits += 1
                if !self.committedCarbIDs.contains(syncIdentifier) {
                    self.committedCarbIDs.insert(syncIdentifier)
                    self.committedCarbs.append(entry)
                }
                self.lock.unlock()
                completion(nil)
            },
            doseHistory: { _, completion in completion([]) },
            issueNotice: { _, _ in },
            isConnectionReady: { true },
            cancelTempBasalAfterPodReturn: { completion in completion(nil) },
            openLoopForUncertainReconciliation: { },
            backfillDoses: { [weak self] doses, completion in
                guard let self = self else { completion(nil); return }
                self.lock.lock()
                self.backfillCalls.append(doses)
                let failure = self.backfillFailure
                self.lock.unlock()
                completion(failure)
            }
        ))
    }

    // MARK: - Harness helpers

    private func doses() -> [DoseEntry] { lock.lock(); defer { lock.unlock() }; return committedDoses }
    private func writeCounts() -> [Int] { lock.lock(); defer { lock.unlock() }; return pumpWriteEventCounts }
    private func rawCarbCommitCount() -> Int { lock.lock(); defer { lock.unlock() }; return rawCarbCommits }
    private func carbs() -> [NewCarbEntry] { lock.lock(); defer { lock.unlock() }; return committedCarbs }
    private func backfills() -> [[DoseEntry]] { lock.lock(); defer { lock.unlock() }; return backfillCalls }
    private func acks() -> [HandbackAck] {
        lock.lock(); defer { lock.unlock() }
        return phoneToWatch.compactMap { if case .handbackAck(let a) = $0 { return a } else { return nil } }
    }

    /// Poll until `condition` holds. The DEADLINE is not decoration: without it the polling
    /// closure spins forever after the wait has already failed, and it is still spinning when
    /// tearDown releases the controller — which is how a failing assertion turns into a SIGTRAP
    /// that kills the test runner and takes every remaining suite with it (observed 2026-08-12,
    /// crash log in hand). A test that crashes the runner is worse than a test that fails: the
    /// gate can no longer tell "your code is broken" from "the environment is broken", which is
    /// the exact confusion that gets gates switched off.
    /// Let the controller's serial queue drain. Same idiom as PodLoanPhoneControllerTests —
    /// needed where the phone's reaction produces NO observable output (a streamed batch just
    /// stages, silently), so there is nothing to poll on.
    private func settle(_ seconds: TimeInterval = 0.6) {
        let e = expectation(description: "queue settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + 2)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let e = expectation(description: description)
        let deadline = Date().addingTimeInterval(timeout + 1)
        DispatchQueue.global().async {
            while !condition() {
                guard Date() < deadline else { return }
                usleep(20_000)
            }
            e.fulfill()
        }
        wait(for: [e], timeout: timeout)
    }

    private func grants() -> [LoanGrant] {
        lock.lock(); defer { lock.unlock() }
        return phoneToWatch.compactMap { if case .grant(let g) = $0 { return g } else { return nil } }
    }

    /// Grant → takeoverComplete → both sides at the new epoch, watch journal open.
    ///
    /// Counts grants rather than looking for "a grant": test 5 establishes TWO loans in one
    /// process, and matching on presence made the second call return the FIRST loan's grant —
    /// which then drove epoch 1's takeoverComplete into a phone sitting at epoch 2 and hung.
    @discardableResult
    private func establishLoan(at now: Date) throws -> LoanGrant {
        let before = grants().count
        phone.handleIncoming(userInfo: try LoanMessage.request(LoanRequest(watchBuild: "twosided")).transportDictionary())
        waitUntil("grant #\(before + 1) sent") { [weak self] in (self?.grants().count ?? 0) > before }
        let grant = try XCTUnwrap(grants().last)

        try watch.begin(epoch: grant.epoch)
        let status = LoanPodStatus(timestamp: now, deliveredUnits: 10, reservoirLevel: nil, isSuspended: false, faultCode: nil)
        phone.handleIncoming(userInfo: try LoanMessage.takeoverComplete(TakeoverComplete(epoch: grant.epoch, firstPodStatus: status)).transportDictionary())
        waitUntil("loaned") { [weak self] in self?.phone?.state == .loaned }
        return grant
    }

    private func bolus(_ units: Double, at date: Date) -> LoanDoseRecord {
        LoanDoseRecord(kind: .bolus, startDate: date, amount: units)
    }

    private func temp(_ rate: Double, at date: Date, minutes: Double) -> LoanDoseRecord {
        LoanDoseRecord(kind: .tempBasal, startDate: date,
                       endDate: date.addingTimeInterval(minutes * 60), unitsPerHour: rate)
    }

    private func carb(_ grams: Double, at date: Date) -> LoanDoseRecord {
        LoanDoseRecord(kind: .carb, startDate: date, amount: grams, absorptionTime: 3 * 3600)
    }

    // MARK: - 1. The whole round trip, both books

    /// grant → mint → interim drain → commit → ack → final drain → finalize. The baseline the
    /// other tests deviate from: everything the watch minted is on the phone exactly once, and
    /// the watch's journal is empty.
    func testFullRoundTripLeavesBothBooksAgreeing() throws {
        let now = Date()
        try establishLoan(at: now)

        try watch.mint(bolus(1.5, at: now.addingTimeInterval(-600)), at: now.addingTimeInterval(-600))
        try watch.mint(temp(0.8, at: now.addingTimeInterval(-300), minutes: 30), at: now.addingTimeInterval(-300))
        try watch.mint(carb(24, at: now.addingTimeInterval(-240)), at: now.addingTimeInterval(-240))

        watch.sendOffer(released: false, at: now)
        waitUntil("interim ack") { [weak self] in (self?.watch.acks.count ?? 0) >= 1 }

        XCTAssertTrue(watch.isDrained, "the interim ack must clear the journal — nothing withheld here")
        XCTAssertEqual(phone.state, .loaned, "an INTERIM offer commits records but must not end the loan (WS1)")

        // The watch releases and offers final; the phone finalizes.
        watch.sendOffer(released: true, at: now)
        waitUntil("owner") { [weak self] in self?.phone?.state == .owner }

        let insulin = doses()
        XCTAssertEqual(insulin.filter { $0.type == .bolus }.count, 1, "exactly one bolus crossed")
        XCTAssertEqual(insulin.filter { $0.type == .tempBasal }.count, 1, "exactly one temp crossed")
        XCTAssertEqual(carbs().count, 1, "exactly one carb crossed")
        XCTAssertEqual(carbs().first?.quantity.doubleValue(for: .gram()), 24)
        XCTAssertTrue(watch.isDrained, "the watch journal ends empty")
    }

    // MARK: - 2. Exactly-once under a lost ack

    /// The transport fault that makes "commit exactly once" load-bearing: the phone commits
    /// and acks, the ACK is lost, and the watch — which has no way to know the difference
    /// between a lost ack and a lost offer — re-offers the same events with the same IDs.
    ///
    /// If the phone deduped by anything weaker than event ID (by arrival, by seq window, by
    /// dose content), this double-books insulin. That is the failure that shows up in the
    /// field as phantom IOB, which is why it is worth an end-to-end test rather than a
    /// phone-side one: the retry-stability of the IDs is the WATCH's guarantee, and only a
    /// joined test checks that the two halves are talking about the same identity.
    func testLostAckThenReofferCommitsExactlyOnce() throws {
        let now = Date()
        try establishLoan(at: now)

        try watch.mint(bolus(2.0, at: now.addingTimeInterval(-600)), at: now.addingTimeInterval(-600))
        try watch.mint(bolus(0.5, at: now.addingTimeInterval(-540)), at: now.addingTimeInterval(-540))

        lock.lock(); acksToDrop = 1; lock.unlock()

        watch.sendOffer(released: false, at: now)
        waitUntil("phone committed") { [weak self] in (self?.doses().count ?? 0) >= 2 }
        XCTAssertTrue(watch.acks.isEmpty, "the ack was dropped — the watch still believes it owes records")
        XCTAssertFalse(watch.isDrained, "and its journal still holds them")

        // Same events, same IDs — the retry.
        watch.sendOffer(released: false, at: now)
        waitUntil("second ack") { [weak self] in (self?.watch.acks.count ?? 0) >= 1 }

        XCTAssertEqual(doses().count, 2,
                       "the re-offer must not double-book — the phone dedups by event ID (got \(doses().count))")
        XCTAssertTrue(watch.isDrained, "and the surviving ack drains the journal")
        XCTAssertEqual(watch.offeredEvents.map(\.count), [2, 2], "both offers carried both events")
    }

    // MARK: - 3. The composition property — cursor cap × ID dedup

    /// The one property no single-sided test can reach.
    ///
    /// A command is in flight when the drain starts, so it is WITHHELD: the phone never sees
    /// it, and acks the max seq it did see. Two mechanisms then have to cooperate.
    ///
    ///   - the WATCH's cursor cap keeps the withheld event (and everything above it) unacked,
    ///     because a max-seq watermark cannot express a gap;
    ///   - the PHONE's ID dedup absorbs the events above the gap when they re-stream.
    ///
    /// Each side is correct alone and the pair can still be wrong: drop the cap and the
    /// withheld dose is lost forever; drop the dedup and everything above the gap is booked
    /// twice. Both failures are silent, and both are insulin.
    func testWithheldEventSurvivesTheGapAndCommitsOnceWhenItClassifies() throws {
        let now = Date()
        try establishLoan(at: now)

        // seq 1 is uncertain and in flight; seq 2 completed normally after it.
        let uncertain = try watch.mint(bolus(1.0, at: now.addingTimeInterval(-600)),
                                       provenance: .assumed(.bolusUncertain),
                                       withhold: true,
                                       at: now.addingTimeInterval(-600))
        let later = try watch.mint(bolus(3.0, at: now.addingTimeInterval(-300)), at: now.addingTimeInterval(-300))

        watch.sendOffer(released: false, at: now)
        waitUntil("first ack") { [weak self] in (self?.watch.acks.count ?? 0) >= 1 }

        XCTAssertEqual(watch.offeredEvents.first?.map(\.seq), [later.seq],
                       "the withheld event must not be streamed")
        XCTAssertEqual(doses().count, 1, "the phone commits only what it was shown")
        XCTAssertTrue(watch.journal.unackedEvents().contains { $0.id == uncertain.id },
                      "THE CAP: the withheld event must survive an ack that covers a higher seq")

        // The pod's verdict lands. The event may stream now — and `later` re-streams with it,
        // because the cursor could not advance past the gap.
        watch.classify(uncertain)
        watch.sendOffer(released: false, at: now)
        waitUntil("second ack") { [weak self] in (self?.watch.acks.count ?? 0) >= 2 }

        XCTAssertEqual(watch.offeredEvents.last?.map(\.seq), [uncertain.seq, later.seq],
                       "the second offer re-streams both — this is what the dedup has to absorb")

        let booked = doses().filter { $0.type == .bolus }
        XCTAssertEqual(booked.count, 2, "THE COMPOSITION: exactly two boluses, not one and not three")
        XCTAssertEqual(booked.map { $0.unitsInDeliverableIncrements }.sorted(), [1.0, 3.0],
                       "and they are the two the watch actually delivered")
        XCTAssertTrue(watch.isDrained, "the journal drains once the gap closes")
    }

    // MARK: - 4. Revoke during a drain

    /// The phone takes the pod back mid-loan (`reclaimNow` — the End/escape path). Records the
    /// watch had already minted must still reach the phone: a revoke reclaims the POD, it does
    /// not discard the insulin history, and the drain that follows is a recovered one.
    func testRevokeMidLoanStillDrainsTheWatchsRecords() throws {
        let now = Date()
        try establishLoan(at: now)

        try watch.mint(bolus(1.25, at: now.addingTimeInterval(-420)), at: now.addingTimeInterval(-420))
        try watch.mint(temp(0.0, at: now.addingTimeInterval(-120), minutes: 30), at: now.addingTimeInterval(-120))

        phone.reclaimNow()
        waitUntil("revoke seen by the watch") { [weak self] in self?.watch.revoked == true }
        XCTAssertEqual(phone.state, .reclaimPending)

        // The watch drains what it has, marked recovered/released — the `handleRevoke` shape.
        watch.sendOffer(released: true, recovered: true, at: now)
        waitUntil("records committed") { [weak self] in (self?.doses().count ?? 0) >= 2 }

        XCTAssertEqual(doses().filter { $0.type == .bolus }.count, 1, "the bolus survived the revoke")
        XCTAssertEqual(doses().filter { $0.type == .tempBasal }.count, 1, "so did the zero temp")
        waitUntil("owner") { [weak self] in self?.phone?.state == .owner }
        XCTAssertTrue(watch.isDrained)
    }

    // MARK: - 5. A dead loan cannot speak

    /// An offer for a superseded epoch must drain its records without touching live loan state
    /// (rows 13/14) — the #102 field incident, where two already-acked epoch-1 offers were
    /// redelivered while epoch 2 was live and wrote temps ending before they started.
    ///
    /// Two-sided version: the stale offer's events are a real journal's contents through a real
    /// encode/decode, not a hand-built message.
    func testStaleEpochOfferDrainsWithoutDisturbingTheLiveLoan() throws {
        let now = Date()
        let first = try establishLoan(at: now)

        try watch.mint(bolus(0.75, at: now.addingTimeInterval(-900)), at: now.addingTimeInterval(-900))
        try watch.mint(carb(31, at: now.addingTimeInterval(-880)), at: now.addingTimeInterval(-880))
        let orphan = watch.journal.unackedEvents()

        // The loan ends and a NEW one begins; the old epoch's offer is still in flight.
        watch.sendOffer(released: true, at: now)
        waitUntil("owner") { [weak self] in self?.phone?.state == .owner }

        let secondDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        watch = WatchDrainDriver(directory: secondDir)
        watch.send = { [weak self] userInfo in self?.phone.handleIncoming(userInfo: userInfo) }
        let second = try establishLoan(at: now)
        XCTAssertGreaterThan(second.epoch, first.epoch)

        let before = doses().count
        let staleOffer = HandbackOffer(epoch: first.epoch, handedBackAt: now, finalStatus: nil,
                                       odometer: nil, events: orphan, tombstones: [],
                                       recovered: true, released: true, watchClosedLoopEnabled: true)
        phone.handleIncoming(userInfo: try LoanMessage.handbackOffer(staleOffer).transportDictionary())

        // The stale offer's records were already committed under the first epoch, so the phone
        // must dedup them AND must not end the live loan.
        waitUntil("stale offer acked") { [weak self] in
            (self?.acks().filter { $0.epoch == first.epoch }.count ?? 0) >= 2
        }
        // WHAT THE PHONE GUARANTEES, and what it delegates. `committedIDs` is cleared at every
        // grant (PodLoanPhoneController :762), so the ID filter cannot span epochs and the
        // controller DOES re-emit this dose — verified here, `before + 1`. That is by design,
        // not a hole: `newPumpEvents` derives `raw` deterministically from the dose's
        // syncIdentifier (:117), so the re-emitted event is byte-identical to the first and
        // LoopKit's DoseStore dedups it on `raw`. The comment at :1451 states this layering
        // explicitly. It is invisible HERE only because `addPumpEvents` is a stub that counts
        // calls rather than store rows — so this assertion pins the CONTRACT (the controller
        // re-emits; the store dedups), and a future reader does not re-chase it as a bug.
        XCTAssertEqual(doses().count, before + 1,
                       "the controller re-emits across epochs; DoseStore dedups on the stable raw")

        // Carbs are the higher-stakes case — NewCarbEntry has no identity field, so there is no
        // store-level net beneath them (#65/#66 phantom COB). Observed: the stale offer did NOT
        // re-book the carb. Pinned rather than derived — the mechanism is not isolated here, and
        // if this ever reads 2 it is a phantom-COB regression worth stopping for.
        XCTAssertEqual(carbs().count, 1, "the stale offer must not re-book the carb (#65)")

        // The actual safety property, and the one #102 was about: a dead epoch may drain its own
        // records and must touch nothing else.
        XCTAssertEqual(phone.state, .loaned, "a stale offer must not end the loan that is actually running")
    }

    // MARK: - 6. Fault variants (coverage plan item 6)

    /// CERTAIN REFUSAL (#99), end to end. A bolus goes out, the pod's verdict refutes it, and
    /// the phantom-IOB guarantee is that those units are never booked ANYWHERE.
    ///
    /// The interesting part is that two mechanisms have to line up. Withholding keeps the
    /// unclassified command off the wire, so the phone never sees it; annulment then removes it
    /// from the journal and tombstones the ID. Neither alone is sufficient — without
    /// withholding the phone would have committed it and there is no unwind path on the phone
    /// (the commit filter skips tombstoned events, it does not delete written doses), and
    /// without annulment the watch would stream it once it classified.
    func testRefutedCommandIsNeverBookedOnEitherSide() throws {
        let now = Date()
        try establishLoan(at: now)

        let doomed = try watch.mint(bolus(4.0, at: now.addingTimeInterval(-300)),
                                    provenance: .assumed(.bolusUncertain),
                                    withhold: true,
                                    at: now.addingTimeInterval(-300))
        let real = try watch.mint(bolus(0.6, at: now.addingTimeInterval(-120)), at: now.addingTimeInterval(-120))

        watch.sendOffer(released: false, at: now)
        waitUntil("first ack") { [weak self] in (self?.watch.acks.count ?? 0) >= 1 }
        XCTAssertEqual(doses().count, 1, "only the confirmed bolus was ever shown to the phone")

        // The pod says it never happened.
        watch.refute(doomed)
        watch.sendOffer(released: true, at: now)
        waitUntil("owner") { [weak self] in self?.phone?.state == .owner }

        let booked = doses().filter { $0.type == .bolus }
        XCTAssertEqual(booked.count, 1, "the refuted bolus must not appear")
        XCTAssertEqual(booked.first?.unitsInDeliverableIncrements, 0.6)
        XCTAssertFalse(booked.contains { ($0.unitsInDeliverableIncrements ?? 0) > 3.0 },
                       "4 U of phantom insulin would be the #99 failure")
        XCTAssertTrue(watch.isDrained, "the tombstone clears with the ack")
    }

    /// UNREACHABLE PHONE. The watch's resend loop reoffers every 15 s while it cannot hear an
    /// ack, so the phone receives the SAME records several times over. #35's field shape: 28
    /// offers, one loan. Nothing may accumulate.
    func testRepeatedRedeliveryWhileTheAckIsUnheardCommitsOnce() throws {
        let now = Date()
        try establishLoan(at: now)

        try watch.mint(bolus(1.0, at: now.addingTimeInterval(-600)), at: now.addingTimeInterval(-600))
        // FINISHED temp, deliberately: an interim drain acks an OPEN temp but defers its write to
        // the final offer (PodLoanPhoneControllerTests.testInterimDrainAcksOpenTempButDefersWrite\
        // ToFinal), so a still-running temp would never appear here and the redelivery count
        // would be measuring the wrong thing.
        try watch.mint(temp(1.4, at: now.addingTimeInterval(-500), minutes: 5), at: now.addingTimeInterval(-500))
        try watch.mint(carb(18, at: now.addingTimeInterval(-400)), at: now.addingTimeInterval(-400))

        lock.lock(); acksToDrop = 3; lock.unlock()
        for _ in 0..<3 {
            watch.sendOffer(released: false, at: now)
            waitUntil("commit attempt") { [weak self] in (self?.doses().count ?? 0) >= 2 }
        }
        XCTAssertTrue(watch.acks.isEmpty, "the watch heard nothing, so it kept offering")

        // #118 changed the transport model this test may assume. Duplicates arriving during an
        // in-flight write now COALESCE — probed on 2026-08-12: offers 3 and 4 merged into one
        // replay, so four offers produced THREE acks, and a fixed drop-3-then-hear-the-4th
        // ledger times out. That is the fix working, not a liveness hole: the watch does not
        // need one ack per copy, it needs ONE, and its 15 s resend guarantees an offer
        // eventually arrives with no write in flight. So model the resend loop.
        var heard = false
        for _ in 0..<6 {
            watch.sendOffer(released: false, at: now)
            settle(0.15)
            if !watch.acks.isEmpty { heard = true; break }
        }
        XCTAssertTrue(heard, "an offer arriving with no write in flight gets acked — the resend loop converges")

        XCTAssertEqual(doses().filter { $0.type == .bolus }.count, 1, "one bolus, however many deliveries it took")
        XCTAssertEqual(doses().filter { $0.type == .tempBasal }.count, 1, "one temp")
        XCTAssertEqual(carbs().count, 1, "one carb — carbs have no store-level net")
        XCTAssertTrue(watch.isDrained)
    }

    /// #66, END TO END, and the reason it needs the STREAMING path to mean anything.
    ///
    /// Records reach the phone two ways. An OFFER commits them immediately (and records the IDs
    /// at :1215). A STREAM only STAGES them. #66's fix — the `committedIDs.formUnion` inside
    /// `forceReclaimToOwner` — exists for the second case: records that were staged, never
    /// committed through an offer, and then written by the force-reclaim itself. Build this on
    /// an offer instead and the test passes no matter what, because :1215 already deduped it;
    /// that is exactly what the first version of this test did, and sabotaging the #66 fix left
    /// it green.
    ///
    /// Carbs are the point. `NewPumpEvent` carries `raw` and the DoseStore dedups on it, so
    /// insulin has a net underneath. `NewCarbEntry` has no identity field and CarbStore mints a
    /// fresh syncIdentifier per add, so committedIDs is the ONLY guard — and a duplicate here
    /// mirrors into every later grant through wipe-then-replace, which is #65's phantom COB with
    /// the phone as the source.
    func testForceReclaimThenWatchReofferDoesNotDoubleTheCarb() throws {
        let now = Date()
        try establishLoan(at: now)

        try watch.mint(carb(42, at: now.addingTimeInterval(-700)), at: now.addingTimeInterval(-700))
        try watch.mint(bolus(2.2, at: now.addingTimeInterval(-690)), at: now.addingTimeInterval(-690))

        // Streamed, not offered: the phone stages these and commits nothing. Staging is silent,
        // so there is nothing to poll — settle the queue instead.
        watch.streamRecords(at: now)
        settle()
        XCTAssertEqual(carbs().count, 0, "streaming stages; it must not commit")
        XCTAssertEqual(doses().count, 0, "streaming stages; it must not commit")

        // The wrist goes quiet — 45 s reachability timeout, or a stranded relaunch. The phone
        // abandons the loan, and writes the staged records first: never understate IOB.
        phone.forceReclaimToOwner(reason: "watch unreachable (test)")
        waitUntil("owner") { [weak self] in self?.phone?.state == .owner }
        XCTAssertEqual(carbs().count, 1, "force-reclaim preserves the staged carb")
        XCTAssertEqual(doses().count, 1, "and the staged bolus")

        // The wrist comes back and does exactly what the protocol says: it never heard an ack,
        // so it resends. Same event IDs.
        watch.sendOffer(released: true, recovered: true, at: now)
        waitUntil("reoffer acked") { [weak self] in (self?.watch.acks.count ?? 0) >= 1 }

        XCTAssertEqual(carbs().count, 1,
                       "THE #66 INVARIANT: the re-offer must not re-book the carb (got \(carbs().count))")
        XCTAssertEqual(doses().count, 1, "nor the bolus")
        // THE LIVELOCK (found here 2026-08-12, fixed the same day). Before the fix the phone acked
        // `committedCursor = 0` — forceReclaimToOwner recorded the committed IDs but never advanced
        // the cursor — so the watch's journal kept seq [1, 2] forever, `handleAck` never saw an
        // empty unacked set, and its 15 s resend loop ran indefinitely. No insulin was at risk (the
        // assertions above show the dedup holding); the loan simply never closed on the wrist.
        //
        // Worth knowing when reading a log: it presents as #35's "28 offers" signature but with the
        // phone ACKING rather than silently dropping, so the #35 diagnosis does not match it.
        XCTAssertTrue(watch.acks.count >= 1, "the phone replies")
        XCTAssertEqual(watch.acks.last?.committedCursor, 2,
                       "the ack must carry the max committed seq, not the stale 0")
        XCTAssertTrue(watch.isDrained,
                      "THE FIX: an advanced cursor lets the returning watch finally drain and close the loan")
    }
    // MARK: - #118 one commit in flight

    /// e27 (2026-08-12): the watch sent 3 offers on its normal 15 s cadence; the phone logged
    /// 12 receipts and started a Core Data write for EVERY one — eleven concurrent writes,
    /// 3-19 s each, for a single 0.15 U dose. Events only enter committedIDs in the write's
    /// COMPLETION, so every duplicate arriving before that saw them as uncommitted. And it
    /// self-amplifies: slow writes delay the ack, the watch resends, more writes.
    ///
    /// The guard: one write in flight; duplicates COALESCE (§2.9 — never drop a message) and
    /// replay after the completion, where committedIDs makes them a cheap re-ack.
    func testDuplicateOffersDuringASlowWriteCollapseToOneCommit() throws {
        let now = Date()
        try establishLoan(at: now)
        try watch.mint(bolus(1.0, at: now.addingTimeInterval(-300)), at: now.addingTimeInterval(-300))
        // #119: the carb is the load-bearing passenger. Doses survive a pile-up via raw-dedup
        // at the store; CarbStore mints a fresh syncIdentifier per add, so every extra commit
        // is a NEW carb. Field 2026-08-12 22:19: 12 queued offers flushed into a waking phone
        // -> 12 copies of one confirmed 10 g entry -> 120.7 g phantom COB -> max basal.
        try watch.mint(carb(10, at: now.addingTimeInterval(-290)), at: now.addingTimeInterval(-290))

        lock.lock(); pumpWriteDelay = 0.4; lock.unlock()
        for _ in 0..<4 { watch.sendOffer(released: false, at: now) }

        waitUntil("ack lands") { [weak self] in (self?.watch.acks.count ?? 0) >= 1 }
        settle()   // let the coalesced replay finish

        let counts = writeCounts()
        XCTAssertEqual(counts.filter { $0 > 0 }.count, 1,
                       "one dose-bearing write for four copies of the offer (got \(counts))")
        XCTAssertLessThanOrEqual(counts.count, 2,
                                 "the coalesced duplicates collapse to at most one empty re-ack write (got \(counts))")
        XCTAssertEqual(doses().count, 1)
        XCTAssertEqual(carbs().count, 1,
                       "THE #119 INVARIANT: one confirmed carb stays ONE carb through the storm — every extra commit is 10 g of phantom COB feeding max basal")
        XCTAssertEqual(rawCarbCommitCount(), 1,
                       "#118 alone must hold this at ONE COMMIT CALL — the R36 store dedupe is the independent second layer, not this test's excuse")
        XCTAssertTrue(watch.isDrained)
    }

    /// A FINAL offer arriving while an interim write is still running must be neither lost nor
    /// run concurrently: it coalesces (a final is never displaced by an interim), replays after
    /// the completion, and closes the loan.
    func testFinalOfferDuringInterimWriteStillClosesTheLoan() throws {
        let now = Date()
        try establishLoan(at: now)
        try watch.mint(bolus(0.5, at: now.addingTimeInterval(-300)), at: now.addingTimeInterval(-300))

        lock.lock(); pumpWriteDelay = 0.4; lock.unlock()
        watch.sendOffer(released: false, at: now)   // write 1 in flight
        watch.sendOffer(released: true, at: now)    // coalesces behind it

        waitUntil("owner", timeout: 8) { [weak self] in self?.phone?.state == .owner }
        XCTAssertEqual(doses().count, 1, "the dose committed exactly once through the pile-up")
        XCTAssertTrue(watch.isDrained)
    }

    /// #66's family, one layer deeper: a force-reclaim firing DURING an in-flight commit used
    /// to read committedIDs before the completion updated it and re-commit the same staged
    /// records — insulin survives (raw dedup at the store) but carbs have no identity and
    /// DOUBLE. The guard defers the reclaim until the write lands; drainAfterCommit then runs
    /// it against an up-to-date committedIDs.
    func testForceReclaimDuringInFlightCommitDoesNotDoubleTheCarb() throws {
        let now = Date()
        try establishLoan(at: now)
        try watch.mint(carb(30, at: now.addingTimeInterval(-400)), at: now.addingTimeInterval(-400))
        try watch.mint(bolus(1.0, at: now.addingTimeInterval(-390)), at: now.addingTimeInterval(-390))

        lock.lock(); pumpWriteDelay = 0.4; lock.unlock()
        watch.sendOffer(released: false, at: now)
        settle(0.1)   // the write is now in flight (0.4 s duration); carbs commit in its completion
        phone.forceReclaimToOwner(reason: "test: user escape during commit")

        waitUntil("owner", timeout: 8) { [weak self] in self?.phone?.state == .owner }
        settle()
        XCTAssertEqual(carbs().count, 1, "the carb must commit exactly once (#118 / #66's family)")
        XCTAssertEqual(rawCarbCommitCount(), 1, "the deferral means ONE commit call, not two deduped ones")
        XCTAssertEqual(doses().filter { $0.type == .bolus }.count, 1, "and the bolus once")
    }

    // MARK: - e44: the commit has to land doses PAST the store's basal boundary

    /// FIELD (loan e44, 2026-08-13, −0.25 U of real insulin missing from the books): a
    /// force-reclaim salvaged the staged tail, the phone resumed and wrote its own basal records,
    /// and the watch came back minutes later with the whole journal. Every dose was written, and
    /// only the BOLUS reached the books. `DoseStore` syncs pump events into the delivery store
    /// starting at the last immutable basal end date and drops anything basal-shaped that begins
    /// before it (DoseStore.swift:1174 — the `|| $0.type == .bolus` escape is why the asymmetry is
    /// the field signature). The salvage record and the phone's own resumed records had moved that
    /// boundary past the entire loan window, so the temps had nowhere to land.
    ///
    /// The fix is a second write with no boundary: upsert the FULL loan's reconciled doses under
    /// the identity the STORE gave them. This test pins the CONTROLLER contract — what is upserted,
    /// under what identity, and what happens when the upsert fails. The store mechanism itself
    /// needs a real DoseStore and is pinned in
    /// `LoanBooksHarnessTests.testForceReclaimSalvageThenLateJournalCommitLandsTempsInTheBooks`.
    func testForceReclaimThenReofferBackfillsDosesPastTheBoundary() throws {
        let now = Date()
        try establishLoan(at: now)

        let firstTemp = try watch.mint(temp(2.35, at: now.addingTimeInterval(-.minutes(26)), minutes: 30),
                                       at: now.addingTimeInterval(-.minutes(26)))
        let theBolus = try watch.mint(bolus(0.60, at: now.addingTimeInterval(-.minutes(24))),
                                      at: now.addingTimeInterval(-.minutes(24)))
        let lastTemp = try watch.mint(temp(1.15, at: now.addingTimeInterval(-.minutes(14)), minutes: 30),
                                      at: now.addingTimeInterval(-.minutes(14)))

        // Streamed, never offered — so the phone is holding them staged when the wrist goes quiet,
        // which is the state a force-reclaim salvages from.
        watch.streamRecords(at: now)
        settle()
        phone.forceReclaimToOwner(reason: "test: watch dead (e44)")
        waitUntil("owner") { [weak self] in self?.phone?.state == .owner }
        XCTAssertEqual(doses().count, 3, "the salvage preserved the staged records")

        // The watch comes back and re-offers. Every event is already in committedIDs, so the
        // pump-event write commits nothing new — and that is precisely the shape that lost the
        // temps in the field, because by now the boundary sits past all of them.
        lock.lock(); backfillCalls = []; lock.unlock()
        watch.sendOffer(released: true, recovered: true, at: now)
        waitUntil("re-offer acked") { [weak self] in (self?.watch.acks.count ?? 0) >= 1 }

        let backfill = try XCTUnwrap(backfills().last, "the commit must restate the loan's doses by store identity")
        XCTAssertEqual(backfill.count, 3,
                       "the WHOLE loan's dose set, not the uncommitted tail — the tail is empty here (got \(backfill.count))")
        XCTAssertEqual(backfill.filter { $0.type == .bolus }.count, 1)
        XCTAssertEqual(backfill.filter { $0.type == .tempBasal }.count, 2)

        // THE IDENTITY IS THE WHOLE FIX. `NewPumpEvent.init` discards `dose.syncIdentifier` and
        // stores hex(raw) instead, so an upsert carrying the bare "loanv2-<uuid>" string would
        // insert a SECOND row rather than correcting the one already written — doubling the books
        // instead of completing them.
        func hexIdentity(_ event: LoanEvent) -> String {
            Data("loanv2-\(event.id.uuidString)".utf8).map { String(format: "%02hhx", $0) }.joined()
        }
        XCTAssertEqual(Set(backfill.compactMap(\.syncIdentifier)),
                       Set([firstTemp, theBolus, lastTemp].map(hexIdentity)),
                       "the upsert must use hex(loanv2-<eventID>) — the identity the store gave these very doses")

        // A FAILED UPSERT MAY NOT ACK. The ack is what stops the watch's 15 s resend loop, and
        // that resend is the only retry this commit has; the upsert is idempotent, so replaying it
        // costs nothing and acking early costs the temps.
        lock.lock(); backfillCalls = []; backfillFailure = NSError(domain: "test.backfill", code: 1); lock.unlock()
        let acksBefore = acks().count
        watch.sendOffer(released: true, recovered: true, at: now)
        waitUntil("failing backfill attempted") { [weak self] in (self?.backfills().count ?? 0) >= 1 }
        settle()
        XCTAssertEqual(acks().count, acksBefore,
                       "no ack while any part of the commit is unwritten — the resend is the retry")
    }
}
