//
//  SeizeActivationTests.swift
//  WatchAppTests
//
//  R40 seize: the first field activation (2026-08-30) died 900 ms after the user's
//  confirm — the dormant credential's expiresAt is issuedAt BY CONTRACT ("meaningless
//  dormant"), the activation rebuild carried it verbatim, and the ladder's mid-takeover
//  lease guard aborted at read 1, twice, before the un-restamped lease was identified.
//  These tests pin the activation contract so it cannot regress silently:
//
//    · the rebuild mints the LIVE lease alongside the fresh epoch (the root-cause fix),
//    · a timed-out request offers the offline start only when a credential is stored,
//    · an unreachable phone shortens the request timeout (accelerate, never gate — R40(b)),
//    · a confirm alone never persists the reunion token — promotion happens only at
//      .active, which no failed activation reaches, so nothing stale can ever match the
//      phone's retro-ack.
//
//  Same harness recipe as PodLoanTimerSeamTests: real stores against a temp directory,
//  the scheduler seam for virtual time, and debugSnapshot() (queue.sync) as the fence
//  that drains the controller's serial queue before each assertion.
//

import XCTest
import LoopKit
import LoopCore
@testable import WatchApp_Extension

final class SeizeActivationTests: XCTestCase {

    private var cacheDir: URL!
    private var cacheStore: PersistenceController!
    private var journalDir: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cacheStore = PersistenceController(directoryURL: cacheDir)
        journalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "SeizeActivationTests-\(UUID().uuidString)")!
    }

    override func tearDown() {
        cacheStore = nil
        cacheDir = nil
        journalDir = nil
        defaults = nil
        super.tearDown()
    }

    private func makeController() -> PodLoanWatchController {
        let doseStore = DoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            basalProfile: nil,
            insulinSensitivitySchedule: nil,
            provenanceIdentifier: "SeizeActivationTests"
        )
        let glucoseStore = GlucoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            cacheLength: .hours(4),
            provenanceIdentifier: "SeizeActivationTests"
        )
        let carbStore = CarbStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            cacheLength: .hours(24),
            defaultAbsorptionTimes: LoopCoreConstants.defaultCarbAbsorptionTimes,
            provenanceIdentifier: "SeizeActivationTests"
        )
        let manager = WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore)
        return PodLoanWatchController(loopManager: manager,
                                      journal: LoanEventJournal(directory: journalDir),
                                      defaults: defaults)
    }

    /// A credential exactly as the phone builds it dormant: expiresAt == issuedAt
    /// ("meaningless dormant"), minimal-but-valid everything else. With
    /// `completeSettings`, the therapy snapshot decodes fully so an activation gets past
    /// settings validation and into the journal step (it still dies at the pump rebuild —
    /// the bytes aren't a pod — which is exactly far enough to observe the fold).
    private func fixtureDormant(issuedAt: Date, epoch: Int = 3, token: UUID = UUID(),
                                completeSettings: Bool = false) -> DormantGrant {
        let grant = LoanGrant(epoch: epoch, expiresAt: issuedAt,
                              pumpManagerRawState: Data([1, 2, 3]), podAddress: 0x1F0A2B3C,
                              therapySettingsRaw: completeSettings ? Self.completeTherapySettingsRaw() : Data([4, 5]),
                              settingsTimeZoneID: "GMT",
                              doseHistory: [], boundaryRecord: nil)
        return DormantGrant(grant: grant, issuedAt: issuedAt, seizeToken: token)
    }

    /// A fully-populated LoopSettings snapshot, serialized the way a grant carries it.
    private static func completeTherapySettingsRaw() -> Data {
        let tz = TimeZone(identifier: "GMT")!
        let settings = LoopSettings(
            dosingEnabled: false,
            glucoseTargetRangeSchedule: GlucoseRangeSchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 110))], timeZone: tz),
            insulinSensitivitySchedule: InsulinSensitivitySchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)], timeZone: tz),
            basalRateSchedule: BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)], timeZone: tz),
            carbRatioSchedule: CarbRatioSchedule(unit: .gram(), dailyItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)], timeZone: tz),
            maximumBasalRatePerHour: 3.0,
            maximumBolus: 5.0)
        return try! PropertyListSerialization.data(fromPropertyList: settings.rawValue, format: .binary, options: 0)
    }

    // MARK: - The root-cause pin

    /// The activation rebuild must mint BOTH rewritten fields: the forced-fresh epoch and
    /// the live lease. Field 2026-08-30: only the epoch was rewritten, so the credential
    /// walked into the ladder wearing its issue-time expiresAt and the mid-takeover lease
    /// guard killed it at read 1 — "grant lease expired mid-takeover", 900 ms after confirm.
    func testActivationRebuildMintsTheEpochAndTheLiveLease() {
        let issuedAt = Date().addingTimeInterval(-3600)   // an hour-old credential, routine for seize
        let dormant = fixtureDormant(issuedAt: issuedAt, epoch: 3)
        XCTAssertEqual(dormant.grant.expiresAt, issuedAt, "precondition: dormant lease is issuedAt by contract")

        let leaseUntil = Date().addingTimeInterval(PodLoanWatchController.seizeActivationLease)
        let rebuilt = dormant.grant.withEpoch(9, leaseUntil: leaseUntil)

        XCTAssertEqual(rebuilt.epoch, 9, "the provisional epoch is forced fresh")
        XCTAssertEqual(rebuilt.expiresAt, leaseUntil,
                       "the LIVE lease is minted at activation — the handshake starts at the confirm, not at issue")
        XCTAssertGreaterThan(rebuilt.expiresAt.timeIntervalSinceNow, 240,
                             "an hour-old credential must still enter the ladder with (almost) the full 5-minute budget")
        // Every other field carries verbatim.
        XCTAssertEqual(rebuilt.pumpManagerRawState, dormant.grant.pumpManagerRawState)
        XCTAssertEqual(rebuilt.podAddress, dormant.grant.podAddress)
        XCTAssertEqual(rebuilt.therapySettingsRaw, dormant.grant.therapySettingsRaw)
        XCTAssertEqual(rebuilt.settingsTimeZoneID, dormant.grant.settingsTimeZoneID)
    }

    // MARK: - The entry gate

    /// No credential stored: the timeout keeps its pre-seize behavior (idle note, no offer).
    /// With a stored credential: the offer appears. R40(b): offered, never auto-taken.
    func testTimedOutRequestOffersOfflineStartOnlyWithACredential() {
        let controller = makeController()
        controller.send = { _ in }
        controller.scheduler = { _, _, work in work.perform() }   // virtual time: fire timeouts inline

        controller.requestLoan(watchBuild: "seize-test")
        var snap = controller.debugSnapshot()                     // queue.sync — drains the request+timeout block
        XCTAssertNil(snap.seizeOfferIssuedAt, "no credential, no offer")
        XCTAssertNotNil(snap.lastIdleNote, "the pre-seize timeout note stands")

        let issuedAt = Date().addingTimeInterval(-1200)
        controller.handleDormantGrant(fixtureDormant(issuedAt: issuedAt))
        controller.requestLoan(watchBuild: "seize-test")
        snap = controller.debugSnapshot()
        XCTAssertNotNil(snap.seizeOfferIssuedAt, "credential stored → the timeout offers the offline start")
        XCTAssertEqual(snap.seizeOfferIssuedAt.map { abs($0.timeIntervalSince(issuedAt)) < 1 }, true,
                       "the offer carries the credential's issue stamp (R40(d): age shown)")
        XCTAssertNil(snap.lastIdleNote, "the offer replaces the failure note")
    }

    // MARK: - The shortened timeout

    /// R40(b): advisory reachability ACCELERATES the offer, never gates the attempt. A
    /// session already reporting unreachable gets an 8 s timeout instead of 25 s — the
    /// field seize spent 25 s twice against a powered-off phone. The request itself must
    /// still be sent (the phone might answer anyway; the short timer is the only change).
    func testUnreachablePhoneShortensTheRequestTimeout() {
        let controller = makeController()
        controller.isPhoneReachable = { false }

        var sent = 0
        controller.send = { _ in sent += 1 }
        var captured: [(TimeInterval, String)] = []
        let timerArmed = expectation(description: "timeout armed")
        controller.scheduler = { delay, label, _ in captured.append((delay, label)); timerArmed.fulfill() }

        controller.requestLoan(watchBuild: "seize-test")
        wait(for: [timerArmed], timeout: 5)

        XCTAssertEqual(sent, 1, "unreachable is advisory — the request still goes out")
        XCTAssertEqual(captured.map(\.0), [8], "unreachable phone → the short timeout")
        XCTAssertEqual(captured.map(\.1), ["request-timeout"])
    }

    // MARK: - Reunion-token hygiene

    /// A confirm alone must never persist the reunion token. This activation dies inside
    /// handleGrant (the fixture's pump/settings bytes don't decode — any failed activation
    /// exercises the same property): the controller returns to idle, and the persisted
    /// active-token slot stays empty. Promotion happens only at .active — so an aborted
    /// seize leaves nothing a later offer could echo into the phone's retro-ack, which
    /// would otherwise acknowledge a loan that never ran.
    func testConfirmAloneNeverPersistsTheReunionToken() {
        let controller = makeController()
        controller.send = { _ in }
        controller.scheduler = { _, _, work in work.perform() }

        let token = UUID()
        controller.handleDormantGrant(fixtureDormant(issuedAt: Date().addingTimeInterval(-600), token: token))
        controller.requestLoan(watchBuild: "seize-test")
        XCTAssertNotNil(controller.debugSnapshot().seizeOfferIssuedAt, "precondition: the offer is live")

        controller.confirmSeize()
        let snap = controller.debugSnapshot()                     // fence: confirm + activation attempt drained

        XCTAssertNil(snap.seizeOfferIssuedAt, "the confirm consumed the offer")
        XCTAssertEqual(snap.phase, .idle, "the fixture activation fails and returns to idle (startable again)")
        XCTAssertNil(defaults.string(forKey: "PodLoanWatchController.activeSeizeToken"),
                     "no .active, no persisted token — a failed activation must leave nothing to echo")
    }

    // MARK: - Re-entry over a parked drain (R40, field 2026-08-30)

    /// The journal fold: adoptEpoch re-tags the epoch and keeps every event, seq, cursor,
    /// and tombstone — the one sanctioned way past begin()'s refuse-to-clobber.
    func testJournalAdoptEpochPreservesTheParkedDrain() throws {
        let journal = LoanEventJournal(directory: journalDir)
        try journal.begin(epoch: 5)
        let now = Date()
        let a = try journal.mintEvent(record: LoanDoseRecord(kind: .bolus, startDate: now, amount: 1.0), provenance: .confirmed)
        let b = try journal.mintEvent(record: LoanDoseRecord(kind: .tempBasal, startDate: now, endDate: now.addingTimeInterval(1800), unitsPerHour: 0.8), provenance: .confirmed)
        journal.applyAck(committedCursor: 1)                      // event a acked, b still parked

        XCTAssertThrowsError(try journal.begin(epoch: 9), "begin must still refuse to clobber an undrained loan")

        let carried = journal.adoptEpoch(9)
        XCTAssertEqual(carried, 1, "one undrained event rides the fold")
        XCTAssertEqual(journal.activeEpoch, 9, "epoch re-tagged")
        let unacked = journal.unackedEvents()
        XCTAssertEqual(unacked.map(\.id), [b.id], "same identity — that's what keeps every downstream layer idempotent")
        XCTAssertEqual(unacked.map(\.seq), [b.seq], "same seq — the phone's contiguous-cursor arithmetic just works")
        _ = a
    }

    /// The full re-entry: a controller that woke up on a parked drain (the reboot case)
    /// must accept Start, rest back on the drain when the request times out — with the
    /// resend chain re-kicked — offer the seize, and on confirm FOLD the drain into the
    /// new loan (epoch above the parked one, token persisted at fold so the drain keeps
    /// the retro-ack door even though this activation dies at the pump rebuild).
    func testStartAndSeizeOverAParkedDrainFoldsIt() throws {
        // Park a drain: a prior loan (epoch 5) with one unacked event, as a reboot leaves it.
        let seeded = LoanEventJournal(directory: journalDir)
        try seeded.begin(epoch: 5)
        let parked = try seeded.mintEvent(record: LoanDoseRecord(kind: .bolus, startDate: Date(), amount: 0.5), provenance: .confirmed)

        let controller = makeController()                          // loads the same journal file
        var sent = 0
        controller.send = { _ in sent += 1 }
        var labels: [String] = []
        controller.scheduler = { _, label, work in
            labels.append(label)
            if label == "request-timeout" { work.perform() }       // inline ONLY the timeout: an inline resend would recurse
        }
        XCTAssertEqual(controller.debugSnapshot().phase, .recoveredDrain, "precondition: woke up on the parked drain")

        let token = UUID()
        controller.handleDormantGrant(fixtureDormant(issuedAt: Date().addingTimeInterval(-900), epoch: 3,
                                                     token: token, completeSettings: true))
        controller.requestLoan(watchBuild: "seize-test")
        var snap = controller.debugSnapshot()
        XCTAssertEqual(snap.phase, .recoveredDrain, "timed out → rests ON the drain, not plain idle")
        XCTAssertNotNil(snap.seizeOfferIssuedAt, "…and the offline offer is up")
        XCTAssertTrue(labels.contains("handback-resend"), "the resend chain was re-kicked on return to the drain")
        XCTAssertGreaterThanOrEqual(sent, 2, "the request went out and so did a recovered offer")
        XCTAssertNil(defaults.string(forKey: "PodLoanWatchController.activeSeizeToken"),
                     "before the confirm the token is pending-only")

        controller.confirmSeize()
        snap = controller.debugSnapshot()                          // fence: fold + failed activation drained

        let after = LoanEventJournal(directory: journalDir)        // fresh instance = the persisted truth
        XCTAssertEqual(after.activeEpoch, 6, "folded to max(credential 3, journal 5 + 1)")
        XCTAssertEqual(after.unackedEvents().map(\.id), [parked.id], "the parked record rides the new loan's stream")
        XCTAssertEqual(defaults.string(forKey: "PodLoanWatchController.activeSeizeToken"), token.uuidString,
                       "token persisted at FOLD — a tokenless future-epoch offer would be dropped by the phone")
        XCTAssertEqual(snap.phase, .recoveredDrain, "the failed activation rests back on the drain, still startable")
    }
}
