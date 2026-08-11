//
//  PodLoanPhoneControllerTests.swift
//  LoopTests
//
//  Controller-level protocol invariants (DESIGN_LOAN_PROTOCOL_V2.md §10): the epoch
//  race (drill D22 / bench B4 as unit tests), cursor idempotency under offer
//  redelivery (row 10), stale-epoch offers drain records without touching loan state
//  (rows 13/14 — dead loans cannot speak), grant deny-on-missing-settings (R1), and
//  the reconcile-commit-ack ordering. The watch half and the timer-driven rows are
//  bench drills by design.
//

import XCTest
import HealthKit
import LoopKit
import LoopCore
import MockKit
@testable import Loop

/// Test-only lendable conformance so the full grant path runs against MockKit's pump.
extension MockPumpManager: PumpConnectionLendable {
    static var testConnectionReleased = false
    public var isConnectionReleased: Bool { Self.testConnectionReleased }
    public func releaseConnection() { Self.testConnectionReleased = true }
    public func reclaimConnection() { Self.testConnectionReleased = false }
}

final class PodLoanPhoneControllerTests: XCTestCase {

    private var sent: [LoanMessage] = []
    private var sentExpectations: [XCTestExpectation] = []
    private var addedDoses: [[DoseEntry]] = []
    /// #49/#66: every NewCarbEntry the controller committed, for round-trip assertions.
    private var addedCarbs: [NewCarbEntry] = []
    private var pauseCalls: [Bool] = []
    private var notices: [String] = []
    /// #42: drives Dependencies.isConnectionReady — false = pod still returning from a reclaim.
    private var connectionReady = true
    private var pump: MockPumpManager!
    private var settings: LoopSettings!
    private let lock = NSLock()

    override func setUp() {
        super.setUp()
        // The controller persists via UserDefaults.standard + a staging file; every
        // test starts from a clean slate.
        for key in ["PodLoanPhoneController.state", "PodLoanPhoneController.epoch",
                    "PodLoanPhoneController.cursor", "PodLoanPhoneController.pendingRevoke",
                    "PodLoanPhoneController.committedIDs", "PodLoanPhoneController.loanStartedAt"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.removeItem(at: base.appendingPathComponent("PodLoanStagedRecordsV2.json"))

        sent = []
        sentExpectations = []
        addedDoses = []
        pauseCalls = []
        notices = []
        connectionReady = true
        pump = MockPumpManager()
        MockPumpManager.testConnectionReleased = false

        let timeZone = TimeZone(identifier: "GMT")!
        settings = LoopSettings(
            dosingEnabled: true,
            glucoseTargetRangeSchedule: GlucoseRangeSchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 110))], timeZone: timeZone),
            insulinSensitivitySchedule: InsulinSensitivitySchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)], timeZone: timeZone),
            basalRateSchedule: BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)], timeZone: timeZone),
            carbRatioSchedule: CarbRatioSchedule(unit: .gram(), dailyItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)], timeZone: timeZone),
            maximumBasalRatePerHour: 3.0,
            maximumBolus: 5.0)
    }

    private func makeController() -> PodLoanPhoneController {
        return PodLoanPhoneController(dependencies: .init(
            pumpManager: { [weak self] in self?.pump },
            settings: { [weak self] in self?.settings ?? LoopSettings() },
            setAutomaticDosingPaused: { [weak self] paused in
                guard let self = self else { return }
                self.lock.lock(); self.pauseCalls.append(paused); self.lock.unlock()
            },
            send: { [weak self] dictionary in
                guard let self = self else { return }
                // #35 diagnostic breadcrumbs (.diag) aren't protocol messages the tests
                // assert on — drop them so they don't pollute `sent` or fulfill expectations.
                if let message = try? LoanMessage.decode(fromTransport: dictionary), case .diag = message { return }
                self.lock.lock()
                if let message = try? LoanMessage.decode(fromTransport: dictionary) {
                    self.sent.append(message)
                }
                let pending = self.sentExpectations
                self.sentExpectations = []
                self.lock.unlock()
                pending.forEach { $0.fulfill() }
            },
            addPumpEvents: { [weak self] events, _, completion in
                guard let self = self else { completion(nil); return }
                // Capture the doses inside the pump events so existing count assertions hold.
                self.lock.lock(); self.addedDoses.append(events.compactMap { $0.dose }); self.lock.unlock()
                completion(nil)
            },
            addCarb: { [weak self] entry, completion in
                self?.lock.lock(); self?.addedCarbs.append(entry); self?.lock.unlock()
                completion(nil)
            },
            doseHistory: { _, completion in completion([]) },
            issueNotice: { [weak self] title, _ in
                guard let self = self else { return }
                self.lock.lock(); self.notices.append(title); self.lock.unlock()
            },
            isConnectionReady: { [weak self] in self?.connectionReady ?? true }
        ))
    }

    /// Wait until the controller's send fires once more.
    private func expectSend() -> XCTestExpectation {
        let e = expectation(description: "message sent")
        lock.lock(); sentExpectations.append(e); lock.unlock()
        return e
    }

    private func lastSent() -> LoanMessage? {
        lock.lock(); defer { lock.unlock() }
        return sent.last
    }

    /// The ack fires the send expectation a hair before the controller's queue runs
    /// its post-commit transition; poll instead of racing it.
    private func waitForState(_ controller: PodLoanPhoneController, _ state: PodLoanPhoneController.State) {
        let e = expectation(description: "state \(state.rawValue)")
        DispatchQueue.global().async {
            while controller.state != state { usleep(20_000) }
            e.fulfill()
        }
        wait(for: [e], timeout: 5)
    }

    /// #49/#66: carbs the phone actually committed, for the watch->phone round-trip tests.
    private func carbEvent(seq: Int, grams: Double, at date: Date, absorption: TimeInterval) -> LoanEvent {
        LoanEvent(id: UUID(), seq: seq, provenance: .confirmed,
                  record: LoanDoseRecord(kind: .carb, startDate: date, amount: grams, absorptionTime: absorption),
                  loggedAt: date)
    }

    private func makeEvent(seq: Int, units: Double, at date: Date) -> LoanEvent {
        LoanEvent(id: UUID(), seq: seq, provenance: .confirmed,
                  record: LoanDoseRecord(kind: .bolus, startDate: date, amount: units), loggedAt: date)
    }

    private func tempEvent(seq: Int, rate: Double, start: Date, durationMinutes: Double) -> LoanEvent {
        LoanEvent(id: UUID(), seq: seq, provenance: .confirmed,
                  record: LoanDoseRecord(kind: .tempBasal, startDate: start,
                                         endDate: start.addingTimeInterval(durationMinutes * 60), unitsPerHour: rate),
                  loggedAt: start)
    }

    /// Drives a controller into LOANED at epoch 1, returning the grant it sent.
    @discardableResult
    private func establishLoan(_ controller: PodLoanPhoneController) -> LoanGrant {
        let grantSent = expectSend()
        controller.handleIncoming(userInfo: try! LoanMessage.request(LoanRequest(watchBuild: "t")).transportDictionary())
        wait(for: [grantSent], timeout: 5)
        guard case .grant(let grant)? = lastSent() else {
            XCTFail("expected a grant, got \(String(describing: lastSent()))")
            fatalError()
        }
        let status = LoanPodStatus(timestamp: Date(), deliveredUnits: 10, reservoirLevel: nil, isSuspended: false, faultCode: nil)
        controller.handleIncoming(userInfo: try! LoanMessage.takeoverComplete(TakeoverComplete(epoch: grant.epoch, firstPodStatus: status)).transportDictionary())
        // takeoverComplete sends nothing; poll state.
        let loaned = expectation(description: "loaned")
        DispatchQueue.global().async {
            while controller.state != .loaned { usleep(20_000) }
            loaned.fulfill()
        }
        wait(for: [loaned], timeout: 5)
        return grant
    }

    // MARK: - Grant path

    func testGrantFlowReachesLoanedAndPausesDosing() throws {
        let controller = makeController()
        let grant = establishLoan(controller)

        XCTAssertEqual(grant.epoch, 1)
        XCTAssertTrue(MockPumpManager.testConnectionReleased, "grant must release the pod connection")
        XCTAssertEqual(pauseCalls, [true], "dosing paused exactly once at grant")
        XCTAssertFalse(grant.pumpManagerRawState.isEmpty)
        XCTAssertFalse(grant.therapySettingsRaw.isEmpty)
        XCTAssertEqual(grant.settingsTimeZoneID, "GMT")
    }

    func testGrantDeniedOnIncompleteSettings() throws {
        settings.maximumBolus = nil  // R1: deny, never default
        let controller = makeController()
        controller.handleIncoming(userInfo: try LoanMessage.request(LoanRequest(watchBuild: "t")).transportDictionary())

        let refused = expectation(description: "refused")
        DispatchQueue.global().async {
            while true {
                self.lock.lock(); let done = self.notices.contains("Sport Mode Not Started"); self.lock.unlock()
                if done { refused.fulfill(); return }
                usleep(20_000)
            }
        }
        wait(for: [refused], timeout: 5)
        XCTAssertEqual(controller.state, .owner)
        XCTAssertTrue(pauseCalls.isEmpty, "denied grant must not touch dosing")
        // A denial is now reported to the watch (never a grant).
        if case .denied? = lastSent() {} else { XCTFail("expected a .denied message, got \(String(describing: lastSent()))") }
        if case .grant? = lastSent() { XCTFail("no grant may be sent on refusal") }
    }

    /// Bug E regression: a phone stranded in a transient non-owner state must recover
    /// on a fresh request and must never refuse forever.
    ///
    /// #42 (2026-08-02): the contract changed. Recovery still happens on the FIRST request,
    /// but it lands in .owner with the settle window open — a force-recovered phone has not
    /// yet completed a pod round-trip, and granting an unverified pod is exactly the race
    /// that fails takeovers in the field. So: first request recovers + denies (with the
    /// "still returning" reason, which eagerly kicks verification), and once the round-trip
    /// lands the NEXT request grants. The invariant this test protects is unchanged: no
    /// permanent refusal.
    func testStrandedStateRecoversOnNewRequest() throws {
        let controller = makeController()
        // Strand it: escape-hatch reclaim with no watch to hand back → reclaimPending.
        establishLoan(controller)
        controller.reclaimNow()
        waitForState(controller, .reclaimPending)

        // First request: force-recovers to owner, denies (unverified), and kicks the
        // verification round-trip.
        let deniedSent = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.request(LoanRequest(watchBuild: "t")).transportDictionary())
        wait(for: [deniedSent], timeout: 5)
        waitForState(controller, .owner)
        if case .denied? = lastSent() {} else if case .grant? = lastSent() {
            XCTFail("must not grant an unverified pod straight out of a stranded state (#42)")
        }

        // The eager kick runs MockPumpManager.ensureCurrentPumpData (fresh lastSync) —
        // wait for the settle window to clear, then a fresh request grants.
        waitUntil(timeout: 8, "reclaim verification") { !controller.isReclaimSettling }
        let grantSent = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.request(LoanRequest(watchBuild: "t")).transportDictionary())
        wait(for: [grantSent], timeout: 5)
        if case .grant? = lastSent() {} else {
            XCTFail("expected a grant after recovery + verification, got \(String(describing: lastSent()))")
        }
        waitForState(controller, .grantOffered)
    }

    /// #42 regression (field 2026-08-02, epoch 122): a TRANSPORT redelivery of the same
    /// request must be ignored. Before the fix, copy 2 arrived while the phone sat in
    /// .grantOffered from copy 1, took the stale-state recovery path, force-reclaimed the pod
    /// it had just released, and re-granted — which the reclaim-settle guard denied. The watch
    /// was left holding a grant for a pod still on the phone and every ladder read returned
    /// no-peripheral. Exactly one grant may result, and the pod must stay released.
    func testDuplicateRequestRedeliveryIsIgnored() throws {
        let controller = makeController()
        let request = LoanRequest(watchBuild: "t")          // ONE id, sent twice by the transport

        let granted = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.request(request).transportDictionary())
        wait(for: [granted], timeout: 5)
        guard case .grant? = lastSent() else { return XCTFail("expected a grant on the first copy") }
        waitForState(controller, .grantOffered)
        XCTAssertTrue(MockPumpManager.testConnectionReleased, "the grant released the pod")

        let epochAfterFirst = grantedEpochs().last
        XCTAssertEqual(grantedEpochs().count, 1, "one request, one grant")

        // The redelivered copy must change NOTHING. The assertion that bites is the grant
        // COUNT: without dedupe the second copy takes the stale-state recovery path and the
        // phone re-grants under a NEW epoch, which supersedes the grant the watch is already
        // acting on — that divergence is the field failure, and a "was there a denial?" check
        // does not catch it (verified: that weaker test passed with the fix disabled).
        controller.handleIncoming(userInfo: try LoanMessage.request(request).transportDictionary())
        settle()
        XCTAssertEqual(grantedEpochs().count, 1,
                       "a redelivered request must not mint a second grant (#42)")
        XCTAssertEqual(grantedEpochs().last, epochAfterFirst,
                       "the epoch the watch is acting on must not be superseded (#42)")
        XCTAssertFalse(sentKinds().contains("denied"),
                       "a redelivered request must not produce a denial (#42)")
        XCTAssertEqual(controller.state, .grantOffered, "state must be untouched by a redelivery")
        XCTAssertTrue(MockPumpManager.testConnectionReleased,
                      "the redelivery must not re-arm/reclaim the released pod (#42)")
    }

    /// Epochs of every grant sent so far — the count is the #42 invariant.
    private func grantedEpochs() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return sent.compactMap { if case .grant(let g) = $0 { return g.epoch } else { return nil } }
    }

    private func sentKinds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return sent.map { message in
            switch message {
            case .grant: return "grant"
            case .denied: return "denied"
            case .nack: return "nack"
            default: return "other"
            }
        }
    }

    /// Let the controller's serial queue drain when the expectation is that NOTHING is sent.
    private func settle(_ seconds: TimeInterval = 0.6) {
        let e = expectation(description: "queue settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + 2)
    }

    /// The dedupe keys on identity, not on "a request arrived recently" — a genuine retry
    /// carries a fresh ID and must still be honoured.
    func testFreshRequestAfterDuplicateStillHandled() throws {
        let controller = makeController()
        let first = LoanRequest(watchBuild: "t")
        let granted = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.request(first).transportDictionary())
        wait(for: [granted], timeout: 5)
        controller.handleIncoming(userInfo: try LoanMessage.request(first).transportDictionary())

        // A NEW request (fresh id) while .grantOffered takes the recovery path as before.
        let second = LoanRequest(watchBuild: "t")
        XCTAssertNotEqual(first.requestID, second.requestID, "each request mints its own id")
        let responded = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.request(second).transportDictionary())
        wait(for: [responded], timeout: 5)
        // Grant or deny is state-dependent; the invariant is that it was NOT silently dropped.
        switch lastSent() {
        case .grant?, .denied?: break
        default: XCTFail("a fresh request must be handled, got \(String(describing: lastSent()))")
        }
    }

    // MARK: - #49/#66 watch-entered carbs follow the pod home

    /// The round trip the carb button was disabled for. A carb entered on the wrist rides the
    /// journal like any other record; the hand-back drain must land it in the phone's CarbStore
    /// with quantity, start time and absorption interval intact.
    func testWatchCarbRoundTripsToThePhoneOnHandback() throws {
        let controller = makeController()
        let grant = establishLoan(controller)
        let mealAt = Date().addingTimeInterval(-.minutes(20))

        let acked = expectSend()
        let offer = HandbackOffer(epoch: grant.epoch, handedBackAt: Date(), finalStatus: nil, odometer: nil,
                                  events: [carbEvent(seq: 1, grams: 42, at: mealAt, absorption: .hours(3))],
                                  tombstones: [], recovered: false)
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(offer).transportDictionary())
        wait(for: [acked], timeout: 5)
        waitForState(controller, .owner)

        XCTAssertEqual(addedCarbs.count, 1, "the wrist carb must reach the phone's CarbStore")
        guard let carb = addedCarbs.first else { return }
        XCTAssertEqual(carb.quantity.doubleValue(for: .gram()), 42, accuracy: 0.001, "grams must survive the fold")
        XCTAssertEqual(carb.startDate.timeIntervalSince1970, mealAt.timeIntervalSince1970, accuracy: 1,
                       "meal time must survive — absorption is computed from it")
        XCTAssertEqual(carb.absorptionTime ?? -1, .hours(3), accuracy: 1,
                       "absorption interval must survive; without it the phone re-derives a default curve")
    }

    /// #66: NewCarbEntry carries NO identity and CarbStore mints a fresh syncIdentifier on every
    /// addCarbEntry, so the store itself can never dedupe. Idempotency has to come from the
    /// protocol's committed-ID gate. A redelivered offer (lost ack, row 10) must therefore commit
    /// the carb exactly once — otherwise every resend inflates COB, which is the #65 phantom-COB
    /// failure mode arriving by a different door.
    func testRedeliveredCarbCommitsOnlyOnce() throws {
        let controller = makeController()
        let grant = establishLoan(controller)
        let mealAt = Date().addingTimeInterval(-.minutes(10))
        let event = carbEvent(seq: 1, grams: 30, at: mealAt, absorption: .hours(2))

        let first = expectSend()
        let offer = HandbackOffer(epoch: grant.epoch, handedBackAt: Date(), finalStatus: nil, odometer: nil,
                                  events: [event], tombstones: [], recovered: false)
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(offer).transportDictionary())
        wait(for: [first], timeout: 5)
        XCTAssertEqual(addedCarbs.count, 1, "first delivery commits the carb")

        // Same offer, same event id — the watch resends until acked, so this is routine.
        let second = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(offer).transportDictionary())
        wait(for: [second], timeout: 5)
        XCTAssertEqual(addedCarbs.count, 1,
                       "a redelivered carb must NOT be committed twice — COB would inflate on every resend (#65/#66)")
    }

    /// Carbs and insulin arrive through different stores; a drain carrying both must not let one
    /// interfere with the other.
    func testMixedCarbAndBolusDrainLandsInBothStores() throws {
        let controller = makeController()
        let grant = establishLoan(controller)
        let at = Date().addingTimeInterval(-.minutes(5))

        let acked = expectSend()
        let offer = HandbackOffer(epoch: grant.epoch, handedBackAt: Date(), finalStatus: nil, odometer: nil,
                                  events: [makeEvent(seq: 1, units: 2.5, at: at),
                                           carbEvent(seq: 2, grams: 15, at: at, absorption: .hours(2))],
                                  tombstones: [], recovered: false)
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(offer).transportDictionary())
        wait(for: [acked], timeout: 5)
        waitForState(controller, .owner)

        XCTAssertEqual(addedCarbs.count, 1, "the carb landed")
        XCTAssertEqual(addedDoses.flatMap { $0 }.filter { $0.type == .bolus }.count, 1, "the bolus landed")
    }

    /// #66 (2026-08-04): forceReclaimToOwner commits STAGED events, and used to do so without
    /// recording their IDs — while also sending no handbackAck, so the watch's 15 s resend loop
    /// kept redelivering the same offer against an unchanged committedIDs set. Every resend
    /// added another copy of the carb.
    ///
    /// This is the path a watch takes whenever it goes unreachable mid-loan (the 45 s
    /// reachability timeout, a stranded relaunch, or a fresh request while loaned), so it is not
    /// an exotic corner. Insulin survived it because NewPumpEvent.raw dedupes at the store;
    /// NewCarbEntry has no identity, so the cursor is the only guard.
    func testForceReclaimThenRedeliveryCommitsCarbOnce() throws {
        let controller = makeController()
        let grant = establishLoan(controller)
        let mealAt = Date().addingTimeInterval(-.minutes(15))
        let event = carbEvent(seq: 1, grams: 25, at: mealAt, absorption: .hours(3))

        // The watch streams the carb, then goes unreachable before any hand-back completes.
        controller.handleIncoming(userInfo: try LoanMessage.doseRecordBatch(
            DoseRecordBatch(epoch: grant.epoch, events: [event], tombstones: [])).transportDictionary())
        settle()

        // The phone gives up and force-reclaims — this commits the staged carb.
        controller.forceReclaimToOwner(reason: "test: watch unreachable")
        waitForState(controller, .owner)
        let afterReclaim = addedCarbs.count
        XCTAssertEqual(afterReclaim, 1, "force-reclaim commits the staged carb once")

        // The watch reconnects and redelivers, as its resend loop does — no ack was ever sent.
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(
            HandbackOffer(epoch: grant.epoch, handedBackAt: Date(), finalStatus: nil, odometer: nil,
                          events: [event], tombstones: [], recovered: true)).transportDictionary())
        settle()

        XCTAssertEqual(addedCarbs.count, 1,
                       "the redelivered carb must NOT be committed again after a force-reclaim (#66) — " +
                       "duplicates here mirror into every later grant and inflate COB (#65)")
    }

    /// #66: a STALE offer (an epoch the phone has moved past) used to commit its carbs
    /// unconditionally while committedIDs.formUnion sat inside the `if !isStale` branch — so the
    /// carbs landed and nothing was recorded, and each resend added another. The override change
    /// on the very next line was already correctly gated, which is what makes this an
    /// inconsistency rather than a deliberate choice: a dead loan cannot add carbs either.
    func testStaleOfferDoesNotCommitCarbs() throws {
        let controller = makeController()
        let grant = establishLoan(controller)
        let mealAt = Date().addingTimeInterval(-.minutes(15))

        // Close the loan cleanly so the epoch advances; a later offer on the OLD epoch is stale.
        let acked = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(
            HandbackOffer(epoch: grant.epoch, handedBackAt: Date(), finalStatus: nil, odometer: nil,
                          events: [], tombstones: [], recovered: false)).transportDictionary())
        wait(for: [acked], timeout: 5)
        waitForState(controller, .owner)
        let baseline = addedCarbs.count

        // A stale offer arrives carrying a carb.
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(
            HandbackOffer(epoch: grant.epoch - 1, handedBackAt: Date(), finalStatus: nil, odometer: nil,
                          events: [carbEvent(seq: 9, grams: 40, at: mealAt, absorption: .hours(3))],
                          tombstones: [], recovered: false)).transportDictionary())
        settle()

        XCTAssertEqual(addedCarbs.count, baseline,
                       "a stale offer must not commit carbs — it records no IDs, so every resend would add another (#66)")
    }

    /// The R7 override: forceReclaimToOwner returns to owner and restores dosing.
    func testForceReclaimReturnsToOwner() throws {
        let controller = makeController()
        establishLoan(controller)
        controller.reclaimNow()
        waitForState(controller, .reclaimPending)

        controller.forceReclaimToOwner(reason: "test")
        waitForState(controller, .owner)
        XCTAssertFalse(MockPumpManager.testConnectionReleased, "pod reclaimed on force")
        XCTAssertEqual(pauseCalls.last, false, "dosing restored on force reclaim")
    }

    /// #42: a re-Start while the pod is still returning from the previous reclaim must
    /// deny-and-retry — never hand the watch a half-reconnected pod (the race that fails
    /// takeover). Once the pod is truly back (isConnectionReady), the next request grants.
    func testGrantDeferredWhilePodStillReturningFromReclaim() throws {
        let controller = makeController()
        establishLoan(controller)
        controller.reclaimNow()
        waitForState(controller, .reclaimPending)

        connectionReady = false                       // pod's BLE not truly back yet
        controller.forceReclaimToOwner(reason: "test")
        waitForState(controller, .owner)              // settle window now open

        let denied = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.request(LoanRequest(watchBuild: "t")).transportDictionary())
        wait(for: [denied], timeout: 5)
        if case .denied? = lastSent() {} else {
            XCTFail("expected .denied while the pod is returning, got \(String(describing: lastSent()))")
        }
        if case .grant? = lastSent() { XCTFail("must not grant a not-yet-returned pod (#42)") }
        XCTAssertFalse(MockPumpManager.testConnectionReleased, "a denied re-Start must not release the pod")

        // #42 (2026-08-02): the link coming up is no longer enough — readiness is a
        // completed pod ROUND-TRIP. Flip the link up, let the chase verify against
        // MockPumpManager (fresh lastSync), and only then does a request grant.
        connectionReady = true
        waitUntil(timeout: 8, "reclaim verification") { !controller.isReclaimSettling }
        let granted = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.request(LoanRequest(watchBuild: "t")).transportDictionary())
        wait(for: [granted], timeout: 5)
        if case .grant? = lastSent() {} else {
            XCTFail("expected a grant once the round-trip verified, got \(String(describing: lastSent()))")
        }
    }

    /// Spin-wait helper for conditions that settle via background queues (the reclaim
    /// verification chase ticks every 2 s and completes via MockPumpManager's main-queue
    /// ensureCurrentPumpData).
    private func waitUntil(timeout: TimeInterval, _ label: String, _ condition: @escaping () -> Bool) {
        let exp = expectation(description: label)
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { exp.fulfill(); return }
                usleep(100_000)
            }
        }
        wait(for: [exp], timeout: timeout + 1)
    }

    // MARK: - Hand-back ordering + idempotency

    func testHandbackCommitsThenAcksThenRestoresOwner() throws {
        let controller = makeController()
        let grant = establishLoan(controller)

        let event = makeEvent(seq: 1, units: 1.0, at: Date())
        let ackSent = expectSend()
        let offer = HandbackOffer(epoch: grant.epoch, handedBackAt: Date(), finalStatus: nil,
                                  odometer: nil, events: [event], tombstones: [], recovered: false)
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(offer).transportDictionary())
        wait(for: [ackSent], timeout: 5)

        guard case .handbackAck(let ack)? = lastSent() else { return XCTFail("expected ack") }
        XCTAssertEqual(ack.committedCursor, 1)
        XCTAssertFalse(ack.stale)
        XCTAssertEqual(addedDoses.count, 1)
        XCTAssertEqual(addedDoses[0].count, 1, "the bolus event enters the store before the ack")
        waitForState(controller, .owner)
        XCTAssertEqual(pauseCalls, [true, false], "dosing restored only after commit")
        XCTAssertFalse(MockPumpManager.testConnectionReleased, "pod reclaimed at loan close")
    }

    /// Row 10: the same offer redelivered (lost ack) re-acks the same cursor and
    /// writes NOTHING new.
    func testOfferRedeliveryIsIdempotent() throws {
        let controller = makeController()
        let grant = establishLoan(controller)
        let event = makeEvent(seq: 1, units: 1.0, at: Date())
        let offer = HandbackOffer(epoch: grant.epoch, handedBackAt: Date(), finalStatus: nil,
                                  odometer: nil, events: [event], tombstones: [], recovered: false)

        let firstAck = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(offer).transportDictionary())
        wait(for: [firstAck], timeout: 5)

        let secondAck = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(offer).transportDictionary())
        wait(for: [secondAck], timeout: 5)

        guard case .handbackAck(let ack)? = lastSent() else { return XCTFail("expected ack") }
        XCTAssertEqual(ack.committedCursor, 1, "same cursor on redelivery")
        let totalWritten = addedDoses.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalWritten, 1, "redelivery writes no duplicate doses")
    }

    /// Rows 13/14 + D22: a stale-epoch offer drains its records but cannot speak to
    /// loan state — the active loan is untouched and the ack says stale.
    func testStaleEpochOfferDrainsButCannotTouchState() throws {
        let controller = makeController()
        let grant1 = establishLoan(controller)

        // Close loan 1 normally.
        let ack1 = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(HandbackOffer(
            epoch: grant1.epoch, handedBackAt: Date(), finalStatus: nil, odometer: nil,
            events: [], tombstones: [], recovered: false)).transportDictionary())
        wait(for: [ack1], timeout: 5)
        waitForState(controller, .owner)

        // Open loan 2.
        let grant2 = establishLoan(controller)
        XCTAssertEqual(grant2.epoch, grant1.epoch + 1)

        // A late loan-1 offer arrives (WC redelivery). Its record still drains, the
        // ack is stale, and loan 2 is untouched.
        let staleAck = expectSend()
        let lateEvent = makeEvent(seq: 7, units: 0.5, at: Date())
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(HandbackOffer(
            epoch: grant1.epoch, handedBackAt: Date(), finalStatus: nil, odometer: nil,
            events: [lateEvent], tombstones: [], recovered: true)).transportDictionary())
        wait(for: [staleAck], timeout: 5)

        guard case .handbackAck(let ack)? = lastSent() else { return XCTFail("expected ack") }
        XCTAssertTrue(ack.stale, "dead loans cannot speak")
        XCTAssertEqual(ack.epoch, grant1.epoch)
        XCTAssertEqual(controller.state, .loaned, "the ACTIVE loan is untouched")
        let lastBatch = addedDoses.last ?? []
        XCTAssertEqual(lastBatch.count, 1, "the stale offer's record still drained")
    }

    /// #69/#52 regression guard for the finalize-deadlock fix. A WS1 INTERIM offer
    /// (released:false) carrying a still-running temp must ACK the open temp's cursor
    /// (so the watch's `unackedEvents` can empty and it sends the final offer — otherwise
    /// the pod is never handed back) while WITHHOLDING it from the store write; the
    /// subsequent FINAL offer writes it (re-drained from staging). This exercises the
    /// ack-cursor / committedIDs decoupling that the earlier reroute got wrong.
    func testInterimDrainAcksOpenTempButDefersWriteToFinal() throws {
        let controller = makeController()
        let grant = establishLoan(controller)
        let now = Date()
        // A temp still running: its 30-min window extends well past handedBackAt (now).
        let openTemp = tempEvent(seq: 1, rate: 1.5, start: now.addingTimeInterval(-60), durationMinutes: 30)

        // Phase 1 — INTERIM offer (released:false): watch still dosing.
        let interimAck = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(HandbackOffer(
            epoch: grant.epoch, handedBackAt: now, finalStatus: nil, odometer: nil,
            events: [openTemp], tombstones: [], recovered: false, released: false)).transportDictionary())
        wait(for: [interimAck], timeout: 5)

        guard case .handbackAck(let ack1)? = lastSent() else { return XCTFail("expected interim ack") }
        XCTAssertEqual(ack1.committedCursor, openTemp.seq, "open temp's seq IS acked so the watch can finalize (deadlock fix)")
        XCTAssertEqual(addedDoses.flatMap { $0 }.count, 0, "but the open temp is withheld from the store write")
        XCTAssertEqual(controller.state, .loaned, "an interim drain does not reclaim")

        // Phase 2 — FINAL offer (released:true): the watch acked everything, so it carries
        // no events; the phone re-drains the still-staged open temp and writes it.
        let finalAck = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(HandbackOffer(
            epoch: grant.epoch, handedBackAt: now.addingTimeInterval(5), finalStatus: nil, odometer: nil,
            events: [], tombstones: [], recovered: false, released: true)).transportDictionary())
        wait(for: [finalAck], timeout: 5)

        XCTAssertEqual(addedDoses.flatMap { $0 }.count, 1, "the withheld open temp is written on the final drain")
        waitForState(controller, .owner)
    }

    // MARK: - KNOWN_RESIDUALS §16 (WS1 test debt)

    /// §16: released-flag decode, key ABSENT — the pre-WS1 watch's wire shape.
    ///
    /// The companion decode test lives in LoanProtocolV2Tests; this pins the CONSEQUENCE,
    /// which is what actually matters: a legacy offer must finalize the loan. Such a watch
    /// only ever offers after it has stopped and released the pod, and it will never send
    /// anything more definitive — so treating nil as "interim" would strand the phone in
    /// .loaned with dosing paused indefinitely.
    func testLegacyOfferWithoutReleasedKeyFinalizesTheLoan() throws {
        let controller = makeController()
        let grant = establishLoan(controller)
        let event = makeEvent(seq: 1, units: 1.0, at: Date())

        var dict = try LoanMessage.handbackOffer(HandbackOffer(
            epoch: grant.epoch, handedBackAt: Date(), finalStatus: nil, odometer: nil,
            events: [event], tombstones: [], recovered: false, released: true)).transportDictionary()
        var json = try JSONSerialization.jsonObject(with: dict[LoanProtocol.userInfoKey] as! Data) as! [String: Any]
        XCTAssertTrue(Self.stripKey("released", from: &json), "fixture must contain a released key to strip")
        dict[LoanProtocol.userInfoKey] = try JSONSerialization.data(withJSONObject: json)

        let ackSent = expectSend()
        controller.handleIncoming(userInfo: dict)
        wait(for: [ackSent], timeout: 5)

        XCTAssertEqual(addedDoses.flatMap { $0 }.count, 1, "the legacy offer's records are committed")
        waitForState(controller, .owner)
        XCTAssertEqual(pauseCalls, [true, false], "dosing is restored — the loan is not left open")
    }

    /// §16: finalize-on-empty-drain. A final offer carrying NO events (everything already
    /// acked during interim drains) must still ack and close the loan. Asserted explicitly
    /// here rather than as a side effect of the interim test, because the failure mode —
    /// "nothing to write, so nothing happens" — leaves the pod on the watch with the phone
    /// paused, and would be invisible in a test that only counts store writes.
    func testFinalOfferWithNoEventsStillAcksAndReturnsToOwner() throws {
        let controller = makeController()
        let grant = establishLoan(controller)

        let ackSent = expectSend()
        controller.handleIncoming(userInfo: try LoanMessage.handbackOffer(HandbackOffer(
            epoch: grant.epoch, handedBackAt: Date(), finalStatus: nil, odometer: nil,
            events: [], tombstones: [], recovered: false, released: true)).transportDictionary())
        wait(for: [ackSent], timeout: 5)

        guard case .handbackAck(let ack)? = lastSent() else { return XCTFail("expected ack") }
        XCTAssertEqual(ack.committedCursor, 0, "an empty drain acks cursor 0 (finding :948)")
        XCTAssertFalse(ack.stale)
        XCTAssertEqual(addedDoses.flatMap { $0 }.count, 0, "nothing to write")
        waitForState(controller, .owner)
        XCTAssertEqual(pauseCalls, [true, false], "the loan still closes and dosing resumes")
        XCTAssertFalse(MockPumpManager.testConnectionReleased, "pod reclaimed on the empty close")
    }

    /// Recursively remove `key`; returns whether anything was removed. Mirrors the helper in
    /// LoanProtocolV2Tests so neither test pins the envelope's nesting.
    private static func stripKey(_ key: String, from json: inout [String: Any]) -> Bool {
        var removed = false
        if json.removeValue(forKey: key) != nil { removed = true }
        for (k, v) in json {
            if var child = v as? [String: Any] {
                if stripKey(key, from: &child) { json[k] = child; removed = true }
            }
        }
        return removed
    }
}
