//
//  SportModePushSender.swift
//  WatchApp Extension
//
//  "Sport Mode started on the watch": at an offline start, a cellular watch tells the distant
//  phone over its own internet, with one silent Apple push sent straight to Apple (no Nightscout).
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
//  Never logged: the key, the signed token (JWT), or the device token in full.
//

import Foundation
import CryptoKit

/// What the loan controller calls at an offline start's activation. Injectable for tests.
protocol OfflineStartNoticeSending: AnyObject {
    func sendOfflineStartNotice(_ notice: SportModeStartedNotice, reach: PhoneReach?)
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
final class SportModePushSender: OfflineStartNoticeSending {

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
            let jwt = try Self.makeJWT(keyID: credentials.keyID, teamID: credentials.teamID,
                                       key: credentials.privateKey, issuedAt: now())
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
        let host: String
        switch push.environment {
        case PhoneReach.ApplePush.sandbox: host = "api.sandbox.push.apple.com"
        case PhoneReach.ApplePush.production: host = "api.push.apple.com"
        default: return nil
        }
        let token = push.token
        guard !token.isEmpty, token.allSatisfy({ $0.isHexDigit }), !push.topic.isEmpty,
              let url = URL(string: "https://\(host)/3/device/\(token)"),
              let body = try? JSONSerialization.data(withJSONObject: notice.apnsPayload, options: [.sortedKeys]) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = attemptTimeout
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(push.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("background", forHTTPHeaderField: "apns-push-type")
        request.setValue("5", forHTTPHeaderField: "apns-priority")
        request.setValue(String(Int(notice.sentAt.addingTimeInterval(expiration).timeIntervalSince1970)),
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
