//
//  SportModeRecordsPushTests.swift
//  WatchAppTests
//
//  Phase 2 of the internet backup: during an offline start a cellular watch also pushes its loan's
//  records to the distant phone (silent pushes, signed with the key built into the app, to the
//  phone's push address carried in the grant). Spec tests 6-9 (TELL_THE_PHONE_OVER_THE_INTERNET.md,
//  "Phase 2 design"):
//
//    6 · the cadence policy at each battery level, including the turn to critical,
//    7 · a big loan splits into pushes under 4 KB that together carry every record,
//    8 · nothing is pushed for a normal (granted) loan, or with no key or push address,
//    9 · a batch encoded by the watch decodes on the phone unchanged (the shared type).
//
//  Keys here are generated in the test, never a real one.
//

import XCTest
import CryptoKit
import HealthKit
import LoopKit
import LoopCore
@testable import WatchApp_Extension

final class SportModeRecordsPushTests: XCTestCase {

    // MARK: - Fixtures

    private let push = PhoneReach.ApplePush(token: "0a1b2c3d4e5f60718293a4b5c6d7e8f9", environment: PhoneReach.ApplePush.sandbox,
                                            topic: "com.example.Loop")
    /// Whole milliseconds: the loan protocol's dates travel as integer milliseconds.
    private let sentAt = Date(timeIntervalSince1970: 1_761_240_000.250)

    private func tempEvent(seq: Int, at start: Date) -> LoanEvent {
        LoanEvent(id: UUID(), seq: seq, provenance: .confirmed,
                  record: LoanDoseRecord(kind: .tempBasal, startDate: start, endDate: start.addingTimeInterval(1800),
                                         unitsPerHour: 0.85),
                  loggedAt: start)
    }

    private func bolusEvent(seq: Int, units: Double, at start: Date) -> LoanEvent {
        LoanEvent(id: UUID(), seq: seq, provenance: .assumed(.bolusUncertain),
                  record: LoanDoseRecord(kind: .bolus, startDate: start, amount: units), loggedAt: start)
    }

    /// The APNs body as Apple hands it to the phone: JSON in, JSON out (numbers become NSNumber).
    private func delivered(_ records: SportModeRecordsPush) throws -> [AnyHashable: Any] {
        let body = try XCTUnwrap(records.apnsBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [AnyHashable: Any])
    }

    private final class RecordingRecordsSender: RecordsPushSending {
        var isConfigured = true
        private let lock = NSLock()
        private var calls: [(pushes: [SportModeRecordsPush], push: PhoneReach.ApplePush)] = []
        func sendRecordsPushes(_ pushes: [SportModeRecordsPush], push: PhoneReach.ApplePush) {
            lock.lock(); calls.append((pushes, push)); lock.unlock()
        }
        var sent: [(pushes: [SportModeRecordsPush], push: PhoneReach.ApplePush)] {
            lock.lock(); defer { lock.unlock() }; return calls
        }
    }

    private final class SilentNoticeSender: OfflineStartNoticeSending {
        func sendOfflineStartNotice(_ notice: SportModeStartedNotice, reach: PhoneReach?) {}
    }

    private var cacheDir: URL!
    private var journalDir: URL!
    private var defaults: UserDefaults!
    private var battery: Float? = 0.80

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        journalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "SportModeRecordsPushTests-\(UUID().uuidString)")!
        battery = 0.80
    }

    private func makeController(sender: RecordingRecordsSender) -> PodLoanWatchController {
        let cacheStore = PersistenceController(directoryURL: cacheDir)
        let doseStore = DoseStore(
            healthKitSampleStore: nil, cacheStore: cacheStore,
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            basalProfile: nil, insulinSensitivitySchedule: nil, provenanceIdentifier: "SportModeRecordsPushTests")
        let glucoseStore = GlucoseStore(healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(4),
                                        provenanceIdentifier: "SportModeRecordsPushTests")
        let carbStore = CarbStore(healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(24),
                                  defaultAbsorptionTimes: LoopCoreConstants.defaultCarbAbsorptionTimes,
                                  provenanceIdentifier: "SportModeRecordsPushTests")
        let controller = PodLoanWatchController(
            loopManager: WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore),
            journal: LoanEventJournal(directory: journalDir),
            defaults: defaults)
        controller.send = { _ in }
        controller.offlineStartNoticeSender = SilentNoticeSender()
        controller.recordsPushSender = sender
        controller.batteryLevel = { [unowned self] in self.battery }
        return controller
    }

    private func grant(epoch: Int = 9, reach: PhoneReach?) -> LoanGrant {
        LoanGrant(epoch: epoch, expiresAt: Date().addingTimeInterval(120), pumpManagerRawState: Data([1, 2, 3]),
                  podAddress: 0x1F0A2B3C, therapySettingsRaw: Data([4, 5]), settingsTimeZoneID: "GMT",
                  doseHistory: [], boundaryRecord: nil, phoneReach: reach)
    }

    // The watch's own record writers, as the loop and the wrist call them.
    private func recordCarbs(_ controller: PodLoanWatchController, grams: Double = 20) {
        controller.loanDidRecordCarbs(NewCarbEntry(quantity: HKQuantity(unit: .gram(), doubleValue: grams), startDate: Date(),
                                                   foodType: nil, absorptionTime: .hours(3)))
        controller.onQueueForTesting { }
    }

    private func recordTemp(_ controller: PodLoanWatchController) {
        let id = controller.loanWillEnactTempBasal(unitsPerHour: 0.9, duration: .minutes(30))
        controller.loanDidEnact(eventID: id, error: nil)
        controller.onQueueForTesting { }
    }

    private func recordBolus(_ controller: PodLoanWatchController, units: Double = 1.5) {
        let id = controller.loanWillEnactBolus(units: units)
        controller.loanDidEnact(eventID: id, error: nil)
        controller.onQueueForTesting { }
    }

    /// The loop cycle's consult (each landed cycle renews the hold, which builds a batch).
    private func cycle(_ controller: PodLoanWatchController) {
        controller.renewHold()
        controller.onQueueForTesting { }
    }

    // MARK: - 6 · The cadence policy (pure)

    private typealias Cadence = SportModeRecordsPushCadence

    private func decide(_ battery: Float?, unconfirmed: Bool = true, new: Bool, significant: Bool = false,
                        lastPushMinutesAgo: Double? = nil, criticalDone: Bool = false) -> Cadence.Decision {
        let now = Date()
        return Cadence.decide(battery: battery, hasUnconfirmed: unconfirmed, newSinceLastPush: new,
                              significantSinceLastPush: significant,
                              lastPushAt: lastPushMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
                              criticalPushDone: criticalDone, now: now)
    }

    func testTheBatteryLevels() {
        XCTAssertEqual(Cadence.level(battery: 0.80), .comfortable)
        XCTAssertEqual(Cadence.level(battery: 0.31), .comfortable)
        XCTAssertEqual(Cadence.level(battery: 0.30), .low, "30% or less is low")
        XCTAssertEqual(Cadence.level(battery: 0.11), .low)
        XCTAssertEqual(Cadence.level(battery: 0.10), .critical, "10% or less is critical")
        XCTAssertEqual(Cadence.level(battery: 0.0), .critical)
        XCTAssertEqual(Cadence.level(battery: nil), .comfortable, "unreadable counts as comfortable")
        XCTAssertEqual(Cadence.level(battery: -1), .comfortable, "WKInterfaceDevice's -1 (monitoring off) too")
    }

    /// Above 30%: a bolus, carbs or a deletion goes at once; anything else waits for the
    /// 15-minute push.
    func testComfortableBatteryPushesTheImportantAtOnceAndTheRestEveryFifteenMinutes() {
        XCTAssertTrue(decide(0.80, new: true, significant: true, lastPushMinutesAgo: 1).push, "bolus/carbs/deletion at once")
        XCTAssertFalse(decide(0.80, new: true, lastPushMinutesAgo: 5).push, "a routine temp waits")
        XCTAssertFalse(decide(0.80, new: true, lastPushMinutesAgo: 14.9).push)
        XCTAssertTrue(decide(0.80, new: true, lastPushMinutesAgo: 15).push, "…until 15 minutes after the last push")
        XCTAssertTrue(decide(0.80, new: true, lastPushMinutesAgo: nil).push, "the loan's first records go at once")
        XCTAssertFalse(decide(0.80, new: false, lastPushMinutesAgo: 60).push, "nothing new, nothing sent")
        XCTAssertFalse(decide(0.80, unconfirmed: false, new: false).push)
    }

    /// 30% or less: every batch with something new.
    func testLowBatteryPushesEveryBatch() {
        XCTAssertTrue(decide(0.30, new: true, lastPushMinutesAgo: 1).push, "a routine temp goes at once")
        XCTAssertTrue(decide(0.20, new: true, lastPushMinutesAgo: 0.1).push)
        XCTAssertFalse(decide(0.20, new: false, lastPushMinutesAgo: 1).push, "nothing new, nothing sent")
        XCTAssertFalse(decide(0.20, new: true).criticalPushDone)
    }

    /// 10% or less: one push of everything at the turn, even with nothing new; then every batch.
    func testCriticalBatteryPushesEverythingOnceAtTheTurnThenEveryBatch() {
        let turn = decide(0.10, new: false, lastPushMinutesAgo: 1, criticalDone: false)
        XCTAssertTrue(turn.push, "the turn to critical pushes everything unconfirmed")
        XCTAssertTrue(turn.criticalPushDone)

        let after = decide(0.09, new: false, lastPushMinutesAgo: 0.1, criticalDone: turn.criticalPushDone)
        XCTAssertFalse(after.push, "once")
        XCTAssertTrue(decide(0.09, new: true, lastPushMinutesAgo: 0.1, criticalDone: true).push, "then every batch")

        // Charged above critical, then drained again: the turn comes round again.
        let charged = decide(0.50, new: false, lastPushMinutesAgo: 1, criticalDone: true)
        XCTAssertFalse(charged.criticalPushDone)
        XCTAssertTrue(decide(0.10, new: false, lastPushMinutesAgo: 1, criticalDone: charged.criticalPushDone).push)

        // A turn with nothing to carry is spent, not saved for later.
        let empty = decide(0.10, unconfirmed: false, new: false, criticalDone: false)
        XCTAssertFalse(empty.push)
        XCTAssertTrue(empty.criticalPushDone)
    }

    /// The same policy driven through the controller, with the battery falling through a loan.
    func testAFallingBatteryStepsTheCadenceUpThroughALoan() {
        let sender = RecordingRecordsSender()
        let controller = makeController(sender: sender)
        controller.installActiveLoanForTesting(grant: grant(reach: PhoneReach(push: push)), offlineStartToken: UUID())

        battery = 0.80
        recordCarbs(controller)
        XCTAssertEqual(sender.sent.count, 1, "comfortable: carbs go at once")
        recordTemp(controller)
        cycle(controller)
        XCTAssertEqual(sender.sent.count, 1, "comfortable: a routine temp waits for the 15-minute push")
        recordBolus(controller)
        XCTAssertEqual(sender.sent.count, 2, "comfortable: a bolus goes at once, carrying the waiting temp too")
        XCTAssertEqual(sender.sent.last?.pushes.flatMap { $0.batch.events }.count, 3, "everything unconfirmed")

        battery = 0.25
        cycle(controller)
        XCTAssertEqual(sender.sent.count, 2, "low: nothing new, nothing sent")
        recordTemp(controller)
        XCTAssertEqual(sender.sent.count, 3, "low: every batch")

        battery = 0.08
        cycle(controller)
        XCTAssertEqual(sender.sent.count, 4, "critical: one push of everything at the turn")
        XCTAssertEqual(sender.sent.last?.pushes.flatMap { $0.batch.events }.count, 4)
        cycle(controller)
        XCTAssertEqual(sender.sent.count, 4, "…once")
        recordTemp(controller)
        XCTAssertEqual(sender.sent.count, 5, "critical: every batch")
        XCTAssertEqual(sender.sent.last?.push, push, "to the phone's push address from the grant")
    }

    // MARK: - 7 · The split

    /// A long loan's records are too big for one push: they split into pushes Apple accepts, which
    /// together carry every record and tombstone, each on its own a complete batch for its share,
    /// newest last.
    func testABigLoanSplitsIntoPushesUnderFourKilobytesCarryingEveryRecord() throws {
        let start = sentAt.addingTimeInterval(-.hours(6))
        let events = (1...150).map { tempEvent(seq: $0, at: start.addingTimeInterval(Double($0) * 120)) }
            + [bolusEvent(seq: 151, units: 2.35, at: sentAt.addingTimeInterval(-60))]
        let tombstones = [UUID(), UUID(), UUID()]
        let token = UUID().uuidString

        let pushes = SportModeRecordsPush.pushes(loan: 12, token: token, sentAt: sentAt, events: events.shuffled(),
                                                 tombstones: tombstones)

        XCTAssertGreaterThan(pushes.count, 1, "151 records do not fit one push")
        var seenEvents: [UUID] = []
        var seenTombstones: [UUID] = []
        for (index, records) in pushes.enumerated() {
            let size = try XCTUnwrap(records.apnsBody?.count)
            XCTAssertLessThanOrEqual(size, SportModeRecordsPush.maxPayloadBytes, "part \(index + 1) is \(size) bytes")
            XCTAssertEqual(records.part, index + 1)
            XCTAssertEqual(records.parts, pushes.count)
            // Each part, as the phone receives it, is a whole batch for the loan.
            let read = try XCTUnwrap(SportModeRecordsPush(userInfo: try delivered(records)))
            XCTAssertEqual(read.batch.epoch, 12)
            XCTAssertEqual(read.token, token)
            XCTAssertEqual(read.batch, records.batch)
            seenEvents += read.batch.events.map(\.id)
            seenTombstones += read.batch.tombstones
        }
        XCTAssertEqual(seenEvents, events.map(\.id), "every record exactly once, in seq order")
        XCTAssertEqual(seenTombstones, tombstones)
        XCTAssertEqual(pushes.last?.batch.events.last?.record.kind, .bolus, "the newest record rides the last push")
        XCTAssertEqual(pushes.last?.batch.tombstones, tombstones, "tombstones ride with the newest")

        XCTAssertEqual(SportModeRecordsPush.pushes(loan: 12, token: token, sentAt: sentAt, events: [], tombstones: []).count, 0,
                       "nothing to carry, nothing to send")
        let small = SportModeRecordsPush.pushes(loan: 12, token: token, sentAt: sentAt, events: Array(events.prefix(3)), tombstones: [])
        XCTAssertEqual(small.count, 1, "a short loan is one push")
    }

    /// Each part goes to Apple as its own silent request: background, low priority, the 10-minute
    /// expiry, and no collapse id (collapsing would let Apple drop a part).
    func testEachPartIsSentAsASilentPushApplesLimitAccepts() throws {
        let key = P256.Signing.PrivateKey()
        let credentials = SportModePushCredentials(keyID: "KEY1234567", teamID: "TEAM123456", privateKey: key)
        let lock = NSLock()
        var requests: [URLRequest] = []
        let sender = SportModePushSender(credentials: credentials, transport: { request, completion in
            lock.lock(); requests.append(request); lock.unlock()
            completion(200, "apns", nil, nil)
        }, retryDelay: 0, now: { [sentAt] in sentAt }, log: { _ in })
        let start = sentAt.addingTimeInterval(-.hours(6))
        let events = (1...150).map { tempEvent(seq: $0, at: start.addingTimeInterval(Double($0) * 120)) }
        let pushes = SportModeRecordsPush.pushes(loan: 12, token: UUID().uuidString, sentAt: sentAt, events: events, tombstones: [])

        sender.sendRecordsPushes(pushes, push: push)

        lock.lock(); let sent = requests; lock.unlock()
        XCTAssertEqual(sent.count, pushes.count, "one request per part")
        let jwts = Set(sent.compactMap { $0.value(forHTTPHeaderField: "authorization") })
        XCTAssertEqual(jwts.count, 1, "one provider token for all parts: Apple refuses one that changes too often")
        for request in sent {
            XCTAssertEqual(request.url?.absoluteString, "https://api.sandbox.push.apple.com/3/device/\(push.token)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "background")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apns-priority"), "5")
            XCTAssertNil(request.value(forHTTPHeaderField: "apns-collapse-id"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "apns-expiration"), String(Int(sentAt.timeIntervalSince1970) + 600))
            let body = try XCTUnwrap(request.httpBody)
            XCTAssertLessThanOrEqual(body.count, SportModeRecordsPush.maxPayloadBytes)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let aps = try XCTUnwrap(payload["aps"] as? [String: Any])
            XCTAssertEqual(aps["content-available"] as? Int, 1)
            XCTAssertNil(aps["alert"], "silent: nothing shown on the phone")
        }
    }

    // MARK: - 8 · Only an offline start, only with a key and an address

    func testAnOfflineStartWithAKeyAndAnAddressPushesItsRecords() throws {
        let sender = RecordingRecordsSender()
        let controller = makeController(sender: sender)
        let token = UUID()
        controller.installActiveLoanForTesting(grant: grant(epoch: 9, reach: PhoneReach(push: push)), offlineStartToken: token)

        recordCarbs(controller)

        let sent = try XCTUnwrap(sender.sent.first)
        XCTAssertEqual(sent.push, push)
        XCTAssertEqual(sent.pushes.first?.loan, 9)
        XCTAssertEqual(sent.pushes.first?.token, token.uuidString, "the offline start's credential")
        XCTAssertEqual(sent.pushes.first?.batch.events.first?.record.kind, .carb)
    }

    func testNothingIsPushedForANormalGrantedLoan() {
        let sender = RecordingRecordsSender()
        let controller = makeController(sender: sender)
        controller.installActiveLoanForTesting(grant: grant(reach: PhoneReach(push: push)), offlineStartToken: nil)
        recordCarbs(controller)
        recordBolus(controller)
        battery = 0.05
        cycle(controller)
        XCTAssertEqual(sender.sent.count, 0, "the phone granted this loan and takes its records over WatchConnectivity")
    }

    func testNothingIsPushedWithoutAKeyBuiltIn() {
        let sender = RecordingRecordsSender()
        sender.isConfigured = false
        let controller = makeController(sender: sender)
        controller.installActiveLoanForTesting(grant: grant(reach: PhoneReach(push: push)), offlineStartToken: UUID())
        recordCarbs(controller)
        XCTAssertEqual(sender.sent.count, 0)
    }

    func testNothingIsPushedWithoutThePhonesPushAddress() {
        for reach in [nil, PhoneReach(push: nil)] {
            let sender = RecordingRecordsSender()
            let controller = makeController(sender: sender)
            controller.installActiveLoanForTesting(grant: grant(reach: reach), offlineStartToken: UUID())
            recordCarbs(controller)
            XCTAssertEqual(sender.sent.count, 0, "\(String(describing: reach))")
        }
    }

    /// Once the phone acknowledges the loan over WatchConnectivity it has adopted it and takes the
    /// records that way; a pushed batch would only be refused, so the pushes stop.
    func testPushesStopOnceThePhoneAnswersOverWatchConnectivity() {
        let sender = RecordingRecordsSender()
        let controller = makeController(sender: sender)
        controller.installActiveLoanForTesting(grant: grant(epoch: 9, reach: PhoneReach(push: push)), offlineStartToken: UUID())
        recordCarbs(controller)
        XCTAssertEqual(sender.sent.count, 1)

        controller.receiveAckForTesting(HandbackAck(epoch: 9, committedCursor: 0))
        recordBolus(controller)
        battery = 0.05
        cycle(controller)
        XCTAssertEqual(sender.sent.count, 1)
    }

    /// Through the real sender with no key built in (the default build): nothing reaches the network.
    func testTheDefaultBuildWithoutAKeySendsNothingOverTheNetwork() {
        let sender = SportModePushSender(credentials: nil, transport: { _, _ in XCTFail("no request without a key") }, log: { _ in })
        XCTAssertFalse(sender.isConfigured)
        sender.sendRecordsPushes(SportModeRecordsPush.pushes(loan: 9, token: UUID().uuidString, sentAt: sentAt,
                                                             events: [tempEvent(seq: 1, at: sentAt)], tombstones: []),
                                 push: push)
    }

    // MARK: - 9 · Round trip: watch encode → phone decode

    func testABatchEncodedByTheWatchDecodesOnThePhoneUnchanged() throws {
        let events = [tempEvent(seq: 1, at: sentAt.addingTimeInterval(-900)),
                      bolusEvent(seq: 2, units: 1.25, at: sentAt.addingTimeInterval(-300)),
                      LoanEvent(id: UUID(), seq: 3, provenance: .confirmed,
                                record: LoanDoseRecord(kind: .carb, startDate: sentAt.addingTimeInterval(-200), amount: 30,
                                                       absorptionTime: .hours(3)),
                                loggedAt: sentAt.addingTimeInterval(-200))]
        let tombstone = UUID()
        let token = UUID().uuidString
        let pushes = SportModeRecordsPush.pushes(loan: 21, token: token, sentAt: sentAt, events: events, tombstones: [tombstone])
        XCTAssertEqual(pushes.count, 1)
        let sent = try XCTUnwrap(pushes.first)

        let userInfo = try delivered(sent)
        XCTAssertTrue(SportModeStartedNotice.isSportModePayload(userInfo), "routed as a Sport Mode push, never to the services")
        XCTAssertEqual(SportModeStartedNotice(userInfo: userInfo)?.event, SportModeRecordsPush.recordsEvent,
                       "the phone reads the same header as the start notice")
        let read = try XCTUnwrap(SportModeRecordsPush(userInfo: userInfo))
        XCTAssertEqual(read, sent, "unchanged: loan, token, sent-at, every record, the tombstone")
        XCTAssertEqual(read.batch.events, events)
        XCTAssertEqual(read.batch.tombstones, [tombstone])
        XCTAssertEqual(read.batch.sentAt, sentAt)

        // Compressed: the base64 batch is smaller than the plain JSON it carries.
        let plain = try LoanProtocol.encoder.encode(sent.batch)
        let encoded = try XCTUnwrap(SportModeRecordsPush.encode(sent.batch))
        XCTAssertLessThan(encoded.count, plain.count)

        // Not a records push: the start notice, and a corrupt batch.
        XCTAssertNil(SportModeRecordsPush(userInfo: SportModeStartedNotice(loan: 21, token: token, sentAt: sentAt).apnsPayload))
        var corrupt = try XCTUnwrap(userInfo[SportModeStartedNotice.payloadKey] as? [String: Any])
        corrupt["batch"] = "bm90IGEgYmF0Y2g="
        XCTAssertNil(SportModeRecordsPush(userInfo: [SportModeStartedNotice.payloadKey: corrupt]))
    }
}
