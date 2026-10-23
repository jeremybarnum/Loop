//
//  SportModePushTests.swift
//  WatchAppTests
//
//  "Sport Mode started on the watch": at an offline start a cellular watch pushes one silent
//  Apple push straight to Apple, signed with the APNs key built into the app, to the phone's
//  push address carried in the grant. These tests use a key generated here, never a real one:
//
//    · the provider token (ES256 JWT) signs, and verifies with the key's public half,
//    · the request: host by environment, path, headers, payload,
//    · nothing is sent without the key or without the phone's push address,
//    · one retry when there is no answer, none when Apple answers,
//    · the controller sends once, at an offline start's activation, and not for a normal loan.
//

import XCTest
import CryptoKit
import HealthKit
import LoopKit
import LoopCore
@testable import WatchApp_Extension

final class SportModePushTests: XCTestCase {

    // MARK: - Fixtures

    private let key = P256.Signing.PrivateKey()
    private let push = PhoneReach.ApplePush(token: "0a1b2c3d4e5f60718293a4b5c6d7e8f9", environment: PhoneReach.ApplePush.sandbox,
                                            topic: "com.example.Loop")
    private let sentAt = Date(timeIntervalSince1970: 1_761_240_000)

    private var credentials: SportModePushCredentials {
        SportModePushCredentials(keyID: "KEY1234567", teamID: "TEAM123456", privateKey: key)
    }

    private func notice(loan: Int = 7, token: String = UUID().uuidString) -> SportModeStartedNotice {
        SportModeStartedNotice(loan: loan, token: token, sentAt: sentAt)
    }

    private static func decodeSegment(_ segment: Substring) -> [String: Any]? {
        guard let data = SportModePushCredentials.decodeBase64(String(segment)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Records every request; answers each from `answers` in turn (the last answer repeats).
    private final class RecordingTransport {
        typealias Answer = (status: Int?, apnsID: String?, body: Data?, error: Error?)
        var answers: [Answer] = [(200, "apns-1", nil, nil)]
        private(set) var requests: [URLRequest] = []
        private let lock = NSLock()
        var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }

        lazy var transport: SportModePushSender.Transport = { [unowned self] request, completion in
            self.lock.lock()
            self.requests.append(request)
            let answer = self.answers.count >= self.requests.count ? self.answers[self.requests.count - 1] : self.answers.last!
            self.lock.unlock()
            DispatchQueue.global().async { completion(answer.status, answer.apnsID, answer.body, answer.error) }
        }
    }

    private final class LogCollector {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    /// Wait for what the test asserts, rather than sleeping.
    private func waitUntil(_ label: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let done = expectation(description: label)
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { done.fulfill(); return }
                usleep(20_000)
            }
        }
        wait(for: [done], timeout: timeout + 1)
    }

    // MARK: - Credentials

    /// The xcconfig carries the .p8's PEM base64-encoded on one line; the install script writes the
    /// URL-safe alphabet without padding. Both alphabets read.
    func testCredentialsReadTheP8InEitherBase64Alphabet() throws {
        let pem = Data(key.pemRepresentation.utf8)
        let standard = pem.base64EncodedString()
        let urlSafe = SportModePushSender.base64URL(pem)
        for encoded in [standard, urlSafe] {
            let read = try XCTUnwrap(SportModePushCredentials(keyID: "KEY1234567", teamID: "TEAM123456", p8Base64: encoded))
            XCTAssertEqual(read.privateKey.publicKey.rawRepresentation, key.publicKey.rawRepresentation)
        }
    }

    /// Empty build settings (no local xcconfig) expand to empty strings: the feature is off.
    func testEmptyOrUnreadableCredentialsMeanTheFeatureIsOff() {
        let pem = Data(key.pemRepresentation.utf8).base64EncodedString()
        XCTAssertNil(SportModePushCredentials(keyID: "", teamID: "", p8Base64: ""))
        XCTAssertNil(SportModePushCredentials(keyID: nil, teamID: "TEAM123456", p8Base64: pem))
        XCTAssertNil(SportModePushCredentials(keyID: "KEY1234567", teamID: "", p8Base64: pem))
        XCTAssertNil(SportModePushCredentials(keyID: "KEY1234567", teamID: "TEAM123456", p8Base64: "bm90IGEga2V5"))
    }

    // MARK: - The provider token

    func testTheJWTSignsAndVerifiesWithTheKey() throws {
        let jwt = try SportModePushSender.makeJWT(keyID: "KEY1234567", teamID: "TEAM123456", key: key, issuedAt: sentAt)
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3)
        XCTAssertFalse(jwt.contains("="), "base64url, no padding")

        let header = try XCTUnwrap(Self.decodeSegment(parts[0]))
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "KEY1234567")
        let claims = try XCTUnwrap(Self.decodeSegment(parts[1]))
        XCTAssertEqual(claims["iss"] as? String, "TEAM123456")
        XCTAssertEqual(claims["iat"] as? Int, Int(sentAt.timeIntervalSince1970))

        let raw = try XCTUnwrap(SportModePushCredentials.decodeBase64(String(parts[2])))
        XCTAssertEqual(raw.count, 64, "JOSE signature: raw r||s, not DER")
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: signingInput))
        XCTAssertFalse(P256.Signing.PrivateKey().publicKey.isValidSignature(signature, for: signingInput),
                       "another key does not verify it")
    }

    // MARK: - The request

    func testTheRequestIsBuiltForTheSandbox() throws {
        let n = notice(loan: 12, token: "8D3C1E2A-0000-4000-8000-000000000001")
        let request = try XCTUnwrap(SportModePushSender.makeRequest(notice: n, push: push, jwt: "h.c.s"))

        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.sandbox.push.apple.com/3/device/0a1b2c3d4e5f60718293a4b5c6d7e8f9")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "bearer h.c.s")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "com.example.Loop")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "background")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-priority"), "5")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-expiration"),
                       String(Int(sentAt.timeIntervalSince1970) + 600), "Apple holds it ten minutes at most")

        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((payload["aps"] as? [String: Any])?["content-available"] as? Int, 1)
        XCTAssertNil((payload["aps"] as? [String: Any])?["alert"], "silent: no alert")
        let sportMode = try XCTUnwrap(payload["sport-mode"] as? [String: Any])
        XCTAssertEqual(sportMode["event"] as? String, "started-on-watch")
        XCTAssertEqual(sportMode["loan"] as? Int, 12)
        XCTAssertEqual(sportMode["token"] as? String, "8D3C1E2A-0000-4000-8000-000000000001")
        XCTAssertEqual(sportMode["sent-at"] as? String, "2025-10-23T17:20:00.000Z")
        XCTAssertEqual(SportModeStartedNotice(userInfo: payload), n, "the phone reads back exactly what was sent")
    }

    func testTheRequestGoesToProductionForATestFlightPhone() throws {
        let production = PhoneReach.ApplePush(token: push.token, environment: PhoneReach.ApplePush.production, topic: push.topic)
        let request = try XCTUnwrap(SportModePushSender.makeRequest(notice: notice(), push: production, jwt: "j"))
        XCTAssertEqual(request.url?.host, "api.push.apple.com")
    }

    func testAnUnusablePushAddressBuildsNoRequest() {
        let unknownEnvironment = PhoneReach.ApplePush(token: push.token, environment: "development", topic: push.topic)
        let notHex = PhoneReach.ApplePush(token: "abc/../x", environment: PhoneReach.ApplePush.sandbox, topic: push.topic)
        let noTopic = PhoneReach.ApplePush(token: push.token, environment: PhoneReach.ApplePush.sandbox, topic: "")
        for bad in [unknownEnvironment, notHex, noTopic] {
            XCTAssertNil(SportModePushSender.makeRequest(notice: notice(), push: bad, jwt: "j"), "\(bad)")
        }
    }

    // MARK: - Sending

    func testNothingIsSentWithoutTheKey() {
        let transport = RecordingTransport()
        let logs = LogCollector()
        let sender = SportModePushSender(credentials: nil, transport: transport.transport, retryDelay: 0, log: logs.append)
        sender.sendOfflineStartNotice(notice(), reach: PhoneReach(push: push))
        XCTAssertEqual(transport.count, 0)
        XCTAssertTrue(logs.all.contains { $0.contains("NOT sent — no push key") })
    }

    func testNothingIsSentWithoutThePhonesPushAddress() {
        let transport = RecordingTransport()
        let logs = LogCollector()
        let sender = SportModePushSender(credentials: credentials, transport: transport.transport, retryDelay: 0, log: logs.append)
        sender.sendOfflineStartNotice(notice(), reach: nil)
        sender.sendOfflineStartNotice(notice(), reach: PhoneReach(push: nil))
        XCTAssertEqual(transport.count, 0)
        XCTAssertEqual(logs.all.filter { $0.contains("NOT sent — the phone's grant carried no push address") }.count, 2)
    }

    /// Sent once, signed with the key; the outcome is logged with the HTTP status and apns-id,
    /// and nothing logged carries the key, the signed token or the device token in full.
    func testOneSignedPushIsSentAndItsOutcomeLogged() throws {
        let transport = RecordingTransport()
        let logs = LogCollector()
        let sender = SportModePushSender(credentials: credentials, transport: transport.transport, retryDelay: 0,
                                         now: { [sentAt] in sentAt }, log: logs.append)
        sender.sendOfflineStartNotice(notice(), reach: PhoneReach(push: push))
        waitUntil("outcome logged") { logs.all.contains { $0.contains("DELIVERED") } }

        XCTAssertEqual(transport.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "authorization"))
        XCTAssertTrue(authorization.hasPrefix("bearer "))
        let jwt = String(authorization.dropFirst("bearer ".count))
        let parts = jwt.split(separator: ".")
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(SportModePushCredentials.decodeBase64(String(parts[2]))))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))

        let delivered = try XCTUnwrap(logs.all.first { $0.contains("DELIVERED") })
        XCTAssertTrue(delivered.contains("HTTP 200") && delivered.contains("apns-1"), delivered)
        for line in logs.all {
            XCTAssertFalse(line.contains(jwt), "the signed token is never logged")
            XCTAssertFalse(line.contains(push.token), "the device token is never logged in full")
            XCTAssertFalse(line.contains("PRIVATE KEY"))
        }
    }

    /// No network on the first try: one retry, then give up.
    func testNoAnswerIsRetriedOnceThenGivenUp() {
        let transport = RecordingTransport()
        transport.answers = [(nil, nil, nil, URLError(.notConnectedToInternet))]
        let logs = LogCollector()
        let sender = SportModePushSender(credentials: credentials, transport: transport.transport, retryDelay: 0, log: logs.append)
        sender.sendOfflineStartNotice(notice(), reach: PhoneReach(push: push))
        waitUntil("given up") { logs.all.contains { $0.contains("given up") } }
        usleep(200_000)
        XCTAssertEqual(transport.count, 2, "one retry, no more")
    }

    func testAnAnswerOnTheRetryIsDelivered() {
        let transport = RecordingTransport()
        transport.answers = [(nil, nil, nil, URLError(.timedOut)), (200, "apns-2", nil, nil)]
        let logs = LogCollector()
        let sender = SportModePushSender(credentials: credentials, transport: transport.transport, retryDelay: 0, log: logs.append)
        sender.sendOfflineStartNotice(notice(), reach: PhoneReach(push: push))
        waitUntil("delivered on the retry") { logs.all.contains { $0.contains("DELIVERED") && $0.contains("attempt 2") } }
        XCTAssertEqual(transport.count, 2)
    }

    /// Apple answered (here: a token for the other environment): the same request cannot fare
    /// better, so no retry; the reason is logged.
    func testARefusalFromAppleIsNotRetried() {
        let transport = RecordingTransport()
        transport.answers = [(400, "apns-3", Data(#"{"reason":"BadDeviceToken"}"#.utf8), nil)]
        let logs = LogCollector()
        let sender = SportModePushSender(credentials: credentials, transport: transport.transport, retryDelay: 0, log: logs.append)
        sender.sendOfflineStartNotice(notice(), reach: PhoneReach(push: push))
        waitUntil("refusal logged") { logs.all.contains { $0.contains("REFUSED") } }
        usleep(200_000)
        XCTAssertEqual(transport.count, 1)
        XCTAssertTrue(logs.all.contains { $0.contains("HTTP 400 BadDeviceToken") })
    }

    // MARK: - The controller: once, at an offline start's activation

    private final class RecordingNoticeSender: OfflineStartNoticeSending {
        private let lock = NSLock()
        private var calls: [(SportModeStartedNotice, PhoneReach?)] = []
        func sendOfflineStartNotice(_ notice: SportModeStartedNotice, reach: PhoneReach?) {
            lock.lock(); calls.append((notice, reach)); lock.unlock()
        }
        var sent: [(notice: SportModeStartedNotice, reach: PhoneReach?)] {
            lock.lock(); defer { lock.unlock() }; return calls.map { (notice: $0.0, reach: $0.1) }
        }
    }

    private var cacheDir: URL!
    private var journalDir: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        journalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "SportModePushTests-\(UUID().uuidString)")!
    }

    private func makeController() -> PodLoanWatchController {
        let cacheStore = PersistenceController(directoryURL: cacheDir)
        let doseStore = DoseStore(
            healthKitSampleStore: nil, cacheStore: cacheStore,
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            basalProfile: nil, insulinSensitivitySchedule: nil, provenanceIdentifier: "SportModePushTests")
        let glucoseStore = GlucoseStore(healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(4),
                                        provenanceIdentifier: "SportModePushTests")
        let carbStore = CarbStore(healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(24),
                                  defaultAbsorptionTimes: LoopCoreConstants.defaultCarbAbsorptionTimes,
                                  provenanceIdentifier: "SportModePushTests")
        return PodLoanWatchController(
            loopManager: WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore),
            journal: LoanEventJournal(directory: journalDir),
            defaults: defaults)
    }

    /// A dormant grant as the phone sends it, with its push address.
    private func dormant(epoch: Int = 3, token: UUID, reach: PhoneReach?) -> DormantGrant {
        let issuedAt = Date().addingTimeInterval(-600)
        let grant = LoanGrant(epoch: epoch, expiresAt: issuedAt, pumpManagerRawState: Data([1, 2, 3]), podAddress: 0x1F0A2B3C,
                              therapySettingsRaw: Data([4, 5]), settingsTimeZoneID: "GMT",
                              doseHistory: [], boundaryRecord: nil, phoneReach: reach)
        return DormantGrant(grant: grant, issuedAt: issuedAt, seizeToken: token)
    }

    /// Phone away, the request times out, the offline start is offered and confirmed. The fixture's
    /// pod bytes are not a pod, so the activation stops short of .active; the ACTIVE flip's hook is
    /// then driven through its seam with the grant that would have reached it.
    private func confirmOfflineStart(_ controller: PodLoanWatchController, _ credential: DormantGrant) {
        controller.send = { _ in }
        controller.isPhoneReachable = { false }
        controller.scheduler = { _, _, work in work.perform() }
        controller.handleDormantGrant(credential)
        controller.requestLoan(watchBuild: "push-test")
        XCTAssertNotNil(controller.debugSnapshot().seizeOfferIssuedAt, "precondition: the offline start is offered")
        controller.confirmSeize()
        _ = controller.debugSnapshot()   // fence: the confirm and the activation attempt have run
    }

    func testTheNoticeIsSentOnceWhenTheOfflineStartBecomesActive() throws {
        let controller = makeController()
        let recorder = RecordingNoticeSender()
        controller.offlineStartNoticeSender = recorder
        let token = UUID()
        let reach = PhoneReach(push: push)
        let credential = dormant(epoch: 3, token: token, reach: reach)

        confirmOfflineStart(controller, credential)
        XCTAssertEqual(recorder.sent.count, 0, "nothing at the confirm: the start is not proven until the pod is taken")

        let activated = credential.grant.withEpoch(3, leaseUntil: Date().addingTimeInterval(120))
        XCTAssertEqual(activated.phoneReach, reach, "the activation's grant keeps the push address")
        controller.noteActiveForTesting(grant: activated)
        controller.noteActiveForTesting(grant: activated)

        XCTAssertEqual(recorder.sent.count, 1, "once")
        let sent = try XCTUnwrap(recorder.sent.first)
        XCTAssertEqual(sent.notice.event, SportModeStartedNotice.startedOnWatch)
        XCTAssertEqual(sent.notice.loan, 3, "the seized loan's epoch")
        XCTAssertEqual(sent.notice.token, token.uuidString, "the dormant grant's seize token")
        XCTAssertEqual(sent.reach, reach)
    }

    /// A normal loan granted by a phone that is right here owes no notice — even one that reuses
    /// the epoch a failed offline start had minted.
    func testANormalGrantAfterAFailedOfflineStartSendsNothing() {
        let controller = makeController()
        let recorder = RecordingNoticeSender()
        controller.offlineStartNoticeSender = recorder
        let credential = dormant(epoch: 3, token: UUID(), reach: PhoneReach(push: push))
        confirmOfflineStart(controller, credential)

        let normal = credential.grant.withEpoch(3, leaseUntil: Date().addingTimeInterval(60))
        controller.receiveGrantForTesting(normal)
        controller.noteActiveForTesting(grant: normal)

        XCTAssertEqual(recorder.sent.count, 0)
    }

    /// A loan that never went through the offline start sends nothing at all.
    func testAnActivationWithoutAnOfflineStartSendsNothing() {
        let controller = makeController()
        let recorder = RecordingNoticeSender()
        controller.offlineStartNoticeSender = recorder
        controller.noteActiveForTesting(grant: dormant(token: UUID(), reach: PhoneReach(push: push)).grant)
        XCTAssertEqual(recorder.sent.count, 0)
    }

    /// End to end through the real sender with no key built in (the default build): the
    /// activation calls the sender, which sends nothing.
    func testWithoutAKeyTheActivationSendsNothingOverTheNetwork() {
        let controller = makeController()
        let transport = RecordingTransport()
        controller.offlineStartNoticeSender = SportModePushSender(credentials: nil, transport: transport.transport, log: { _ in })
        let credential = dormant(epoch: 3, token: UUID(), reach: PhoneReach(push: push))
        confirmOfflineStart(controller, credential)
        controller.noteActiveForTesting(grant: credential.grant.withEpoch(3, leaseUntil: Date().addingTimeInterval(120)))
        XCTAssertEqual(transport.count, 0)
    }
}
