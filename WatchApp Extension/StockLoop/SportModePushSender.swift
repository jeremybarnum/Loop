//
//  SportModePushSender.swift
//  WatchApp Extension
//
//  "Sport Mode started on the watch": at an offline start, a cellular watch tells the distant
//  phone over its own internet, with one visible, high-priority Apple push sent straight to Apple (no Nightscout).
//  A BACKUP, never relied on: without internet nothing is sent and nothing else changes — the
//  phone's insulin ledger already makes its return safe. With it, the phone stands aside before
//  its first reading and its pre-scheduled not-looping warnings stop reaching the wrist.
//
//  Production line only (ruled 2026-10-23): the APNs key is built into the app from an optional,
//  git-ignored xcconfig (SportModePush.local.xcconfig at the workspace root, written by
//  ops/push/install-push-key.sh), carried in this extension's Info.plist. Empty → feature off.
//  The phone's push address arrives in the grant (`LoanGrant.phoneReach`); the dormant grant the
//  phone keeps refreshing keeps it current. The payload carries the dormant grant's seize token,
//  so the key alone cannot fake a start: the phone acts only on its own outstanding token.
//
//  Phase 2 (2026-10-23): during an offline start only, the same sender also pushes the loan's
//  records to the distant phone, silently (background, low priority), so a watch that dies away
//  from the phone has already delivered them. When is decided by one policy
//  (`SportModeRecordsPushCadence`, below); this file only signs and sends.
//
//  Never logged: the key, the signed token (JWT), or the device token in full.
//

import Foundation
import CryptoKit

/// What the loan controller calls at an offline start's activation. Injectable for tests.
protocol OfflineStartNoticeSending: AnyObject {
    func sendOfflineStartNotice(_ notice: SportModeStartedNotice, reach: PhoneReach?)
}

/// What the loan controller calls when the cadence policy says to push the loan's records.
/// Injectable for tests.
protocol RecordsPushSending: AnyObject {
    /// A push key is built into this app. Without one, nothing is ever sent.
    var isConfigured: Bool { get }
    func sendRecordsPushes(_ pushes: [SportModeRecordsPush], push: PhoneReach.ApplePush)
}

/// The APNs signing credentials built into the app.
struct SportModePushCredentials {
    static let keyIDInfoKey = "SportModePushKeyID"
    static let teamIDInfoKey = "SportModePushTeamID"
    static let keyInfoKey = "SportModePushKeyP8Base64"

    let keyID: String
    let teamID: String
    let privateKey: P256.Signing.PrivateKey

    init(keyID: String, teamID: String, privateKey: P256.Signing.PrivateKey) {
        self.keyID = keyID
        self.teamID = teamID
        self.privateKey = privateKey
    }

    /// nil when any value is empty or the key does not parse. `p8Base64` is the .p8 file's PEM
    /// text, base64-encoded on one line; standard or URL-safe alphabet, padding optional (the
    /// install script writes URL-safe, because an xcconfig reads "//" as the start of a comment).
    init?(keyID: String?, teamID: String?, p8Base64: String?) {
        guard let keyID = keyID?.trimmingCharacters(in: .whitespacesAndNewlines), !keyID.isEmpty,
              let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), !teamID.isEmpty,
              let encoded = p8Base64?.trimmingCharacters(in: .whitespacesAndNewlines), !encoded.isEmpty,
              let pemData = Self.decodeBase64(encoded),
              let pem = String(data: pemData, encoding: .utf8),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { return nil }
        self.init(keyID: keyID, teamID: teamID, privateKey: key)
    }

    /// The credentials in this bundle's Info.plist, or nil (feature off).
    static func fromBundle(_ bundle: Bundle = .main) -> SportModePushCredentials? {
        SportModePushCredentials(keyID: bundle.object(forInfoDictionaryKey: keyIDInfoKey) as? String,
                                 teamID: bundle.object(forInfoDictionaryKey: teamIDInfoKey) as? String,
                                 p8Base64: bundle.object(forInfoDictionaryKey: keyInfoKey) as? String)
    }

    static func decodeBase64(_ text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder != 0 { standard += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: standard)
    }
}

/// Signs and sends the one push. All network work runs on URLSession's own queues; the caller
/// (the loan controller's queue) only hands over the notice.
final class SportModePushSender: OfflineStartNoticeSending, RecordsPushSending {

    /// The HTTP exchange, injectable for tests: (request, completion(status, apns-id, body, error)).
    typealias Transport = (_ request: URLRequest,
                           _ completion: @escaping (_ status: Int?, _ apnsID: String?, _ body: Data?, _ error: Error?) -> Void) -> Void

    /// How long Apple may hold the push for a phone that is off or out of coverage. The phone
    /// ignores a notice older than the same horizon (PodLoanPhoneController.offlineStartNoticeMaxAge).
    static let expiration: TimeInterval = 10 * 60
    /// The wait for a network on one attempt, and the pause before the single retry.
    static let attemptTimeout: TimeInterval = 20
    static let defaultRetryDelay: TimeInterval = 10

    private let credentials: SportModePushCredentials?
    private let transport: Transport
    private let retryDelay: TimeInterval
    private let now: () -> Date
    private let log: (String) -> Void
    private let retryQueue = DispatchQueue(label: "com.loopkit.Loop.SportModePushSender", qos: .utility)
    /// The signed provider token, reused: Apple refuses a token that changes more often than every
    /// 20 minutes (429 TooManyProviderTokenUpdates) and one older than an hour. One push at an
    /// offline start never met either; record pushes every few minutes would meet the first.
    static let providerTokenLifetime: TimeInterval = 30 * 60
    private let tokenLock = NSLock()
    private var providerToken: (jwt: String, issuedAt: Date)?

    init(credentials: SportModePushCredentials?,
         transport: Transport? = nil,
         retryDelay: TimeInterval = SportModePushSender.defaultRetryDelay,
         now: @escaping () -> Date = Date.init,
         log: @escaping (String) -> Void = { SportLog.event("push", $0) }) {
        self.credentials = credentials
        self.transport = transport ?? Self.urlSessionTransport
        self.retryDelay = retryDelay
        self.now = now
        self.log = log
    }

    /// The production sender: credentials from the Info.plist, URLSession.
    static func fromBundle() -> SportModePushSender {
        SportModePushSender(credentials: SportModePushCredentials.fromBundle())
    }

    var isConfigured: Bool { credentials != nil }

    // MARK: - Send

    func sendOfflineStartNotice(_ notice: SportModeStartedNotice, reach: PhoneReach?) {
        let what = "offline-start notice e\(notice.loan)"
        guard let credentials = credentials else {
            log("\(what) NOT sent — no push key built into this app (feature off) [push]")
            return
        }
        guard let push = reach?.push else {
            log("\(what) NOT sent — the phone's grant carried no push address (older phone, or no push token yet) [push]")
            return
        }
        let request: URLRequest
        do {
            let jwt = try currentJWT(credentials)
            guard let built = Self.makeRequest(notice: notice, push: push, jwt: jwt) else {
                log("\(what) NOT sent — the phone's push address is unusable (environment \"\(push.environment)\", token …\(push.token.suffix(6))) [push]")
                return
            }
            request = built
        } catch {
            log("\(what) NOT sent — signing failed: \(error.localizedDescription) [push]")
            return
        }
        log("\(what) sending to APNs \(push.environment), device …\(push.token.suffix(6)), topic \(push.topic) [push]")
        attempt(request, what: what, number: 1, startedAt: now())
    }

    /// The loan's records, silently (see `makeRequest(records:push:jwt:)`). Each push is sent and
    /// retried on its own, like the notice; the outcome of each is logged.
    func sendRecordsPushes(_ pushes: [SportModeRecordsPush], push: PhoneReach.ApplePush) {
        guard let first = pushes.first else { return }
        let what = "records push e\(first.loan)"
        guard let credentials = credentials else {
            log("\(what) NOT sent — no push key built into this app (feature off) [push]")
            return
        }
        let jwt: String
        do {
            jwt = try currentJWT(credentials)
        } catch {
            log("\(what) NOT sent — signing failed: \(error.localizedDescription) [push]")
            return
        }
        for records in pushes {
            let part = String(format: "%@ part %d/%d (%d event(s), %d tombstone(s), %d bytes)", what, records.part, records.parts,
                              records.batch.events.count, records.batch.tombstones.count, records.apnsBody?.count ?? -1)
            guard let request = Self.makeRequest(records: records, push: push, jwt: jwt) else {
                log("\(part) NOT sent — unusable push address or payload over \(SportModeRecordsPush.maxPayloadBytes) bytes (environment \"\(push.environment)\", token …\(push.token.suffix(6))) [push]")
                continue
            }
            log("\(part) sending to APNs \(push.environment), device …\(push.token.suffix(6)) [push]")
            attempt(request, what: part, number: 1, startedAt: now())
        }
    }

    /// The provider token to sign with: the cached one while it is younger than
    /// `providerTokenLifetime`, else a fresh one.
    private func currentJWT(_ credentials: SportModePushCredentials) throws -> String {
        tokenLock.lock(); defer { tokenLock.unlock() }
        let at = now()
        if let cached = providerToken, at.timeIntervalSince(cached.issuedAt) < Self.providerTokenLifetime,
           at >= cached.issuedAt {
            return cached.jwt
        }
        let jwt = try Self.makeJWT(keyID: credentials.keyID, teamID: credentials.teamID,
                                   key: credentials.privateKey, issuedAt: at)
        providerToken = (jwt, at)
        return jwt
    }

    private func attempt(_ request: URLRequest, what: String, number: Int, startedAt: Date) {
        transport(request) { [weak self] status, apnsID, body, error in
            guard let self = self else { return }
            let elapsed = String(format: "%.1fs", self.now().timeIntervalSince(startedAt))
            if let status = status {
                let reason = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["reason"] as? String
                if status == 200 {
                    self.log("\(what) DELIVERED to Apple — HTTP 200, apns-id \(apnsID ?? "?"), attempt \(number), \(elapsed) [push]")
                } else {
                    // Apple answered: retrying the same request cannot change its answer.
                    self.log("\(what) REFUSED by Apple — HTTP \(status) \(reason ?? ""), apns-id \(apnsID ?? "?"), attempt \(number), \(elapsed) — given up [push]")
                }
                return
            }
            let description = error.map { ($0 as NSError).domain + " " + String(($0 as NSError).code) + " " + $0.localizedDescription } ?? "no response"
            if number == 1 {
                self.log("\(what) no answer (\(description)), attempt 1, \(elapsed) — one retry in \(Int(self.retryDelay))s [push]")
                self.retryQueue.asyncAfter(deadline: .now() + self.retryDelay) { [weak self] in
                    self?.attempt(request, what: what, number: 2, startedAt: startedAt)
                }
            } else {
                self.log("\(what) NOT delivered (\(description)), attempt \(number), \(elapsed) — given up; the insulin ledger covers the phone's return [push]")
            }
        }
    }

    // MARK: - Building blocks (pure, tested)

    /// The APNs provider token: ES256 JWT, header {alg, kid}, claims {iss, iat}, JOSE (raw r||s)
    /// signature.
    static func makeJWT(keyID: String, teamID: String, key: P256.Signing.PrivateKey, issuedAt: Date) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID], options: [.sortedKeys])
        let claims = try JSONSerialization.data(withJSONObject: ["iss": teamID, "iat": Int(issuedAt.timeIntervalSince1970)],
                                                options: [.sortedKeys])
        let signingInput = base64URL(header) + "." + base64URL(claims)
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }

    /// The POST to Apple, or nil when the address is unusable (unknown environment, a token that
    /// is not hex, an empty topic).
    static func makeRequest(notice: SportModeStartedNotice, push: PhoneReach.ApplePush, jwt: String) -> URLRequest? {
        guard let body = try? JSONSerialization.data(withJSONObject: notice.apnsPayload, options: [.sortedKeys]) else {
            return nil
        }
        // A visible alert at high priority: Apple delivers it at once. A background push is
        // low priority and iOS may hold it for minutes on a sleeping phone.
        // One loan, one notice on the phone's screen, however many copies arrive (collapse id).
        return makeRequest(body: body, push: push, jwt: jwt, pushType: "alert", priority: "10",
                           collapseID: "sport-mode-e\(notice.loan)", sentAt: notice.sentAt)
    }

    /// A record push: SILENT (background, priority 5 — records can wait minutes, and a silent push
    /// shows nothing), the same 10-minute expiry as the notice, and NO collapse id: collapsing
    /// would let Apple drop one part of a split in favour of another. nil when the address is
    /// unusable or the body is over Apple's limit.
    static func makeRequest(records: SportModeRecordsPush, push: PhoneReach.ApplePush, jwt: String) -> URLRequest? {
        guard let body = records.apnsBody, body.count <= SportModeRecordsPush.maxPayloadBytes else { return nil }
        return makeRequest(body: body, push: push, jwt: jwt, pushType: "background", priority: "5",
                           collapseID: nil, sentAt: records.sentAt)
    }

    /// The POST to Apple, or nil when the address is unusable (unknown environment, a token that
    /// is not hex, an empty topic).
    private static func makeRequest(body: Data, push: PhoneReach.ApplePush, jwt: String, pushType: String,
                                    priority: String, collapseID: String?, sentAt: Date) -> URLRequest? {
        let host: String
        switch push.environment {
        case PhoneReach.ApplePush.sandbox: host = "api.sandbox.push.apple.com"
        case PhoneReach.ApplePush.production: host = "api.push.apple.com"
        default: return nil
        }
        let token = push.token
        guard !token.isEmpty, token.allSatisfy({ $0.isHexDigit }), !push.topic.isEmpty,
              let url = URL(string: "https://\(host)/3/device/\(token)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = attemptTimeout
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(push.topic, forHTTPHeaderField: "apns-topic")
        request.setValue(pushType, forHTTPHeaderField: "apns-push-type")
        request.setValue(priority, forHTTPHeaderField: "apns-priority")
        if let collapseID = collapseID {
            request.setValue(collapseID, forHTTPHeaderField: "apns-collapse-id")
        }
        request.setValue(String(Int(sentAt.addingTimeInterval(expiration).timeIntervalSince1970)),
                         forHTTPHeaderField: "apns-expiration")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - URLSession

    /// Waits for connectivity up to `attemptTimeout` (a cellular watch that has just left the
    /// phone may still be bringing its radio up), then reports no response.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = attemptTimeout
        configuration.timeoutIntervalForResource = attemptTimeout
        configuration.allowsCellularAccess = true
        return URLSession(configuration: configuration)
    }()

    private static let urlSessionTransport: Transport = { request, completion in
        session.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            completion(http?.statusCode, http?.value(forHTTPHeaderField: "apns-id"), data, error)
        }.resume()
    }
}

// MARK: - When to push the loan's records (phase 2)

/// THE policy for pushing an offline start's records: one small pure function, consulted every
/// loop cycle and whenever a record is written. The mechanism (`PodLoanWatchController`) asks it
/// and does what it says; the levels and thresholds are chosen here and nowhere else.
///
/// The risk this guards is the watch's battery dying away from the phone, and every push costs
/// battery (it wakes the cellular radio), so sending gets more eager as the battery drops:
///   · comfortable (above 30%): at once when a bolus, carbs or a deletion was recorded since the
///     last push; any other new record waits, at most 15 minutes after the last push;
///   · low (30% or less): every batch with something new;
///   · critical (10% or less): every batch with something new, plus one push of everything at the
///     moment it first turns critical.
/// Every push carries everything the phone has not confirmed, so "everything" is not a different
/// payload, only a push that does not wait for something new. Thresholds to settle on the bench.
enum SportModeRecordsPushCadence {
    static let lowBattery: Float = 0.30
    static let criticalBattery: Float = 0.10
    static let comfortableInterval: TimeInterval = 15 * 60

    enum Level: String {
        case comfortable, low, critical
    }

    /// An unknown level (nil: not readable, e.g. monitoring off) counts as comfortable.
    static func level(battery: Float?) -> Level {
        guard let battery = battery, battery >= 0 else { return .comfortable }
        if battery <= criticalBattery { return .critical }
        if battery <= lowBattery { return .low }
        return .comfortable
    }

    struct Decision: Equatable {
        let push: Bool
        /// For the log.
        let reason: String
        /// Carry into the next call: the one push owed at the turn to critical has been made (or
        /// was not needed). Reset whenever the battery is above critical, so a watch charged and
        /// drained again gets it again.
        let criticalPushDone: Bool
    }

    /// - Parameters:
    ///   - hasUnconfirmed: anything at all for the phone (records or tombstones it has not confirmed).
    ///   - newSinceLastPush: some of it was not in the last push.
    ///   - significantSinceLastPush: among the new: a bolus, carbs, a carb deletion, or a tombstone.
    static func decide(battery: Float?, hasUnconfirmed: Bool, newSinceLastPush: Bool, significantSinceLastPush: Bool,
                       lastPushAt: Date?, criticalPushDone: Bool, now: Date) -> Decision {
        let level = level(battery: battery)
        let done = level == .critical ? criticalPushDone : false
        guard hasUnconfirmed else {
            // Nothing to carry. At the turn to critical there is nothing to push either, so the
            // turn is spent.
            return Decision(push: false, reason: "nothing unconfirmed", criticalPushDone: level == .critical)
        }
        switch level {
        case .critical:
            if !done {
                return Decision(push: true, reason: "battery turned critical — everything unconfirmed", criticalPushDone: true)
            }
            return newSinceLastPush
                ? Decision(push: true, reason: "battery critical — every batch", criticalPushDone: true)
                : Decision(push: false, reason: "battery critical — nothing new", criticalPushDone: true)
        case .low:
            return newSinceLastPush
                ? Decision(push: true, reason: "battery low — every batch", criticalPushDone: false)
                : Decision(push: false, reason: "battery low — nothing new", criticalPushDone: false)
        case .comfortable:
            if significantSinceLastPush {
                return Decision(push: true, reason: "bolus, carbs or a deletion recorded", criticalPushDone: false)
            }
            guard newSinceLastPush else {
                return Decision(push: false, reason: "nothing new", criticalPushDone: false)
            }
            if let last = lastPushAt, now.timeIntervalSince(last) < comfortableInterval {
                return Decision(push: false, reason: "routine records wait for the 15-minute push", criticalPushDone: false)
            }
            return Decision(push: true, reason: lastPushAt == nil ? "routine records, the loan's first push"
                                                                  : "routine records, 15 minutes since the last push",
                            criticalPushDone: false)
        }
    }
}
