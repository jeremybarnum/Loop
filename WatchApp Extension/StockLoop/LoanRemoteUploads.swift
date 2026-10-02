//
//  LoanRemoteUploads.swift
//  WatchApp
//
//  EXPERIMENT (experiment/ns-watch): Nightscout and Tidepool uploads from the wrist while it
//  holds the pod. Stock's RemoteDataServicesManager, compiled into this target unchanged, drives
//  an in-memory NightscoutService and/or TidepoolService built from what the session grant
//  carried. Its triggers are the store delegates stock's DeviceDataManager uses on the phone.
//
//  Nothing here persists a credential: the Nightscout site and secret and the Tidepool session
//  live in memory from grant acceptance until the pump is torn down, and are never logged. A
//  relaunch mid-loan therefore resumes without uploads. The query anchors are stock's, in this
//  app's defaults, so a later loan carries on from where the last one stopped.
//

import Foundation
import LoopKit
import LoopAlgorithm
import LoopCore
import NightscoutServiceKit
import TidepoolServiceKit
import TidepoolKit

/// Stock declares this in DeviceDataManager.swift, which the watch does not compile.
protocol UploadEventListener {
    func triggerUpload(for triggeringType: RemoteDataType)
}

final class LoanRemoteUploads {
    static let shared = LoanRemoteUploads()

    private let lock = UnfairLock()

    /// From accepted grants; consumed when the matching service starts. Cleared only by `end`.
    private var stagedNightscout: LoanNightscoutCredentials?
    private var stagedTidepool: LoanTidepoolSession?

    /// Set while the loan is ACTIVE; credentials staged then start their service at once.
    private weak var activeLoop: WatchLoopManager?

    private var manager: RemoteDataServicesManager?
    private var nightscout: NightscoutService?
    private var tidepool: TidepoolService?
    private var tidepoolObserver: TidepoolSessionLog?

    /// Bumped by `end`, so a start still waiting for main does not outlive its loan.
    private var generation = 0

    /// Stock's manager wants a CGM event store; the wrist records none, so this one stays empty.
    private static let emptyCgmEventStore: LoopKit.CgmEventStore? = {
        guard let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let cacheStore = LoopKit.PersistenceController(directoryURL: documents.appendingPathComponent("NSExperimentCgmEvents"), isReadOnly: false)
        return LoopKit.CgmEventStore(cacheStore: cacheStore)
    }()

    /// Called on grant acceptance. A grant without one kind never clears what is already staged
    /// (only `end` does); anything arriving while the loan is ACTIVE starts at once.
    func stage(nightscout: LoanNightscoutCredentials?, tidepool: LoanTidepoolSession?) {
        let active = lock.withLock { () -> WatchLoopManager? in
            if let nightscout { stagedNightscout = nightscout }
            if let tidepool { stagedTidepool = tidepool }
            return activeLoop
        }
        SportLog.event("ns-exp", "grant: Nightscout credentials \(nightscout == nil ? "absent (staged kept)" : "present")")
        SportLog.event("tp-exp", "grant: Tidepool session \(tidepool == nil ? "absent (staged kept)" : "present")")
        if let active { startStaged(loopManager: active) }
    }

    /// Loan ACTIVE: start whatever is staged; later grants can add more.
    func begin(loopManager: WatchLoopManager) {
        lock.withLock { activeLoop = loopManager }
        startStaged(loopManager: loopManager)
    }

    private func startStaged(loopManager: WatchLoopManager) {
        let (ns, tp, beganIn) = lock.withLock { () -> (LoanNightscoutCredentials?, LoanTidepoolSession?, Int) in
            defer {
                if nightscout == nil { stagedNightscout = nil }
                if tidepool == nil { stagedTidepool = nil }
            }
            return (nightscout == nil ? stagedNightscout : nil, tidepool == nil ? stagedTidepool : nil, generation)
        }
        if ns == nil && nightscout == nil { SportLog.event("ns-exp", "loan active, no Nightscout credentials yet — uploads start if a grant brings them") }
        if tp == nil && tidepool == nil { SportLog.event("tp-exp", "loan active, no Tidepool session yet — uploads start if a grant brings one") }
        guard ns != nil || tp != nil else { return }

        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard let manager = managerForLoan(loopManager, beganIn: beganIn) else { return }
                if let ns { startNightscout(ns, manager: manager, beganIn: beganIn) }
                if let tp { startTidepool(tp, manager: manager, beganIn: beganIn) }
            }
        }
    }

    /// One stock manager per loan, shared by both services, with stock's store-delegate triggers.
    @MainActor
    private func managerForLoan(_ loopManager: WatchLoopManager, beganIn: Int) -> RemoteDataServicesManager? {
        if let existing = lock.withLock({ self.generation == beganIn ? self.manager : nil }) { return existing }
        guard let alertStore = loopManager.alertStore,
              let dosingDecisionStore = loopManager.dosingDecisionStore,
              let deviceLog = loopManager.deviceLog,
              let emptyCgmEventStore = LoanRemoteUploads.emptyCgmEventStore else {
            SportLog.event("ns-exp", "a store is missing — uploads OFF for this loan")
            return nil
        }
        let manager = RemoteDataServicesManager(
            alertStore: alertStore,
            carbStore: loopManager.carbStore,
            doseStore: loopManager.doseStore,
            dosingDecisionStore: dosingDecisionStore,
            glucoseStore: loopManager.glucoseStore,
            cgmEventStore: emptyCgmEventStore,
            settingsProvider: loopManager.settingsProvider,
            overrideHistory: loopManager.overrideHistory,
            insulinDeliveryStore: loopManager.doseStore.insulinDeliveryStore,
            deviceLog: deviceLog,
            automationHistoryProvider: self
        )
        manager.delegate = self
        let current = lock.withLock { () -> Bool in
            guard generation == beganIn else { return false }
            self.manager = manager
            return true
        }
        guard current else {
            SportLog.event("ns-exp", "loan ended before uploads started — not starting")
            return nil
        }

        // Stock's DeviceDataManager wiring. The dose store's delegate stays WatchLoopManager,
        // which forwards pump events here.
        alertStore.delegate = self
        loopManager.carbStore.delegate = self
        loopManager.glucoseStore.delegate = self
        dosingDecisionStore.delegate = self
        loopManager.doseStore.insulinDeliveryStore.delegate = self
        return manager
    }

    @MainActor
    private func startNightscout(_ credentials: LoanNightscoutCredentials, manager: RemoteDataServicesManager, beganIn: Int) {
        let service = NightscoutService()
        service.siteURL = credentials.siteURL
        service.apiSecret = credentials.apiSecret
        service.isOnboarded = true
        guard lock.withLock({ () -> Bool in
            guard generation == beganIn else { return false }
            nightscout = service
            return true
        }) else { return }
        // As stock's addService: everything past the saved anchors goes up now.
        manager.addService(service)
        SportLog.event("ns-exp", "uploads ON — stock RemoteDataServicesManager driving NightscoutService (site and secret not logged)")
    }

    @MainActor
    private func startTidepool(_ staged: LoanTidepoolSession, manager: RemoteDataServicesManager, beganIn: Int) {
        let session: TSession
        do {
            session = try JSONDecoder.tidepool.decode(TSession.self, from: staged.sessionJSON)
        } catch {
            SportLog.event("tp-exp", "session from the grant did not decode (\(type(of: error))) — Tidepool uploads OFF")
            return
        }

        // The PHONE's host identity, so stock's data-set lookup (by client name) finds the phone's
        // data set and Tidepool's deduplication sees one origin for both devices.
        let service = TidepoolService(hostIdentifier: staged.hostIdentifier, hostVersion: staged.hostVersion)
        // Stock's default storage is the keychain: a refresh would write the new session into
        // the WATCH keychain. Memory only for the experiment.
        service.sessionStorage = InMemoryTidepoolSessionStorage()
        service.session = session
        service.isOnboarded = true
        let observer = TidepoolSessionLog(installed: session)
        guard lock.withLock({ () -> Bool in
            guard generation == beganIn else { return false }
            tidepool = service
            tidepoolObserver = observer
            return true
        }) else { return }

        SportLog.event("tp-exp", "client name (data set key) \(staged.hostIdentifier) (phone's; the wrist's own would be \(Bundle.main.hostIdentifier)) · version \(staged.hostVersion) · environment \(session.environment.host) · client id \(BuildDetailsProbe.tidepoolClientId)")
        Task {
            await service.tapi.setURLSessionConfiguration(TidepoolHTTPLog.configuration())
            await service.tapi.addObserver(observer)
            await service.tapi.setSession(session)
            await MainActor.run {
                guard self.lock.withLock({ self.tidepool === service }) else { return }
                manager.addService(service)
                SportLog.event("tp-exp", "uploads ON — stock RemoteDataServicesManager driving TidepoolService (tokens not logged)")
            }
        }
    }

    /// Pump teardown or loan end. Synchronous, so nothing the teardown writes afterwards is
    /// uploaded; idempotent.
    func end() {
        let (ns, tp, loopManager) = lock.withLock { () -> (NightscoutService?, TidepoolService?, WatchLoopManager?) in
            defer {
                manager = nil; nightscout = nil; tidepool = nil; tidepoolObserver = nil
                stagedNightscout = nil; stagedTidepool = nil; activeLoop = nil; generation += 1
            }
            return (nightscout, tidepool, activeLoop)
        }

        // An upload already under way finds no configuration (Nightscout) or no user (Tidepool) and returns.
        if let ns {
            ns.siteURL = nil
            ns.apiSecret = nil
            SportLog.event("ns-exp", "uploads OFF — loan over, service dropped")
        }
        if let tp {
            DispatchQueue.main.async { tp.session = nil }
            // Local only: no logout, which would revoke the session the phone still uses.
            Task { await tp.tapi.setSession(nil) }
            SportLog.event("tp-exp", "uploads OFF — loan over, service and session dropped (no logout)")
        }
        if let loopManager {
            loopManager.alertStore?.delegate = nil
            loopManager.carbStore.delegate = nil
            loopManager.glucoseStore.delegate = nil
            loopManager.dosingDecisionStore?.delegate = nil
            loopManager.doseStore.insulinDeliveryStore.delegate = nil
        }
    }

    func trigger(_ type: RemoteDataType) {
        guard let manager = lock.withLock({ self.manager }) else { return }
        Task { @MainActor in manager.triggerUpload(for: type) }
    }
}

// MARK: - Stock's store delegates (DeviceDataManager on the phone)

extension LoanRemoteUploads: AlertStoreDelegate {
    func alertStoreHasUpdatedAlertData(_ alertStore: AlertStore) { trigger(.alert) }
}

extension LoanRemoteUploads: CarbStoreDelegate {
    func carbStoreHasUpdatedCarbData(_ carbStore: CarbStore) { trigger(.carb) }
    func carbStore(_ carbStore: CarbStore, didError error: CarbStore.CarbStoreError) {}
}

extension LoanRemoteUploads: GlucoseStoreDelegate {
    func glucoseStoreHasUpdatedGlucoseData(_ glucoseStore: GlucoseStore) { trigger(.glucose) }
}

extension LoanRemoteUploads: DosingDecisionStoreDelegate {
    func dosingDecisionStoreHasUpdatedDosingDecisionData(_ dosingDecisionStore: DosingDecisionStore) { trigger(.dosingDecision) }
}

extension LoanRemoteUploads: InsulinDeliveryStoreDelegate {
    func insulinDeliveryStoreHasUpdatedDoseData(_ insulinDeliveryStore: InsulinDeliveryStore) { trigger(.dose) }
}

// MARK: - What stock's manager asks of its owner

extension LoanRemoteUploads: RemoteDataServicesManagerDelegate {
    /// As stock DeviceDataManager: the CGM manager decides, and no manager means yes.
    var shouldSyncGlucoseToRemoteService: Bool {
        lock.withLock { activeLoop }?.cgmManager?.shouldSyncToRemoteService ?? true
    }
}

extension LoanRemoteUploads: AutomationHistoryProvider {
    /// The wrist keeps no automation history; the loan's current mode stands for the window.
    func automationHistory(from start: Date, to end: Date) async throws -> [AbsoluteScheduleValue<Bool>] {
        let enabled = lock.withLock { activeLoop }?.closedLoopEnabledNonBlocking ?? false
        return [AbsoluteScheduleValue(startDate: start, endDate: end, value: enabled)]
    }
}

// MARK: - Tidepool session: memory-only storage and a token-free refresh log

/// Replaces stock's keychain storage for the loan; dropped with the service.
private final class InMemoryTidepoolSessionStorage: SessionStorage {
    private let lock = UnfairLock()
    private var sessions: [String: TSession] = [:]

    func setSession(_ session: TSession?, for service: String) throws {
        lock.withLock { sessions[service] = session }
    }

    func getSession(for service: String) throws -> TSession? {
        lock.withLock { sessions[service] }
    }
}

/// Logs each session change TAPI makes after the grant's session is installed: whether the
/// access token and refresh token changed, never their values.
private final class TidepoolSessionLog: TAPIObserver {
    private var current: TSession?

    init(installed: TSession) {
        current = installed
    }

    func apiDidUpdateSession(_ session: TSession?) {
        defer { current = session }
        guard let session else {
            SportLog.event("tp-exp", "session CLEARED by TidepoolKit (refresh refused or loan end)")
            return
        }
        guard let previous = current, session != previous else { return }
        let rotated = session.refreshToken != previous.refreshToken
        SportLog.event("tp-exp", "session REFRESHED on the wrist — access token \(session.accessToken != previous.accessToken ? "new" : "same") · refresh token \(rotated ? "ROTATED (the phone's copy may now be stale)" : "unchanged") · kept in memory only")
    }
}

/// Reads the client id TidepoolService will use, for the log (it is not a secret).
private enum BuildDetailsProbe {
    static var tidepoolClientId: String {
        guard let url = Bundle.main.url(forResource: "BuildDetails", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return "BuildDetails.plist MISSING" }
        return dict["TidepoolServiceClientId"] as? String ?? "TidepoolServiceClientId MISSING"
    }
}

/// Every TidepoolKit request on the wrist passes through here: method, path, status, and for
/// data uploads the datum count by type. No header, token or token-endpoint body is ever read.
final class TidepoolHTTPLog: URLProtocol {
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TidepoolHTTPLog.self] + (configuration.protocolClasses ?? [])
        return configuration
    }

    private static let forwarding = URLSession(configuration: .ephemeral)
    private var forwardingTask: URLSessionDataTask?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var forwarded = request
        if forwarded.httpBody == nil, let stream = forwarded.httpBodyStream {
            forwarded.httpBody = Self.read(stream)
            forwarded.httpBodyStream = nil
        }
        let method = forwarded.httpMethod ?? "GET"
        let path = forwarded.url?.path ?? "?"
        let isTokenEndpoint = path.contains("/token")
        let summary = isTokenEndpoint ? "" : Self.datumSummary(forwarded.httpBody)

        forwardingTask = Self.forwarding.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode
            if isTokenEndpoint {
                SportLog.event("tp-exp", "token refresh \(method) → \(status.map(String.init) ?? "no response (\(error.map { "\(type(of: $0))" } ?? "?"))")")
            } else {
                let query = forwarded.url?.query.map { "?\($0)" } ?? ""
                SportLog.event("tp-exp", "HTTP \(method) \(path)\(query) → \(status.map(String.init) ?? "no response")\(summary)\(Self.dataSetSummary(path: path, data: data))")
            }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwardingTask?.resume()
    }

    override func stopLoading() {
        forwardingTask?.cancel()
    }

    private static func read(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    /// " · N datum(s): type×n, …" for a JSON array of datums; empty otherwise.
    private static func datumSummary(_ body: Data?) -> String {
        guard let body, let array = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]], !array.isEmpty else { return "" }
        var counts: [String: Int] = [:]
        for datum in array { counts[datum["type"] as? String ?? "?", default: 0] += 1 }
        return " · \(array.count) datum(s): " + counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
    }

    /// For the data-set list and create calls: which data sets (id and client name) came back.
    private static func dataSetSummary(path: String, data: Data?) -> String {
        guard path.hasSuffix("/data_sets"), let data,
              let object = try? JSONSerialization.jsonObject(with: data) else { return "" }
        let sets: [[String: Any]] = (object as? [[String: Any]])
            ?? ((object as? [String: Any])?["data"] as? [String: Any]).map { [$0] } ?? []
        let described = sets.map { set -> String in
            let id = set["uploadId"] as? String ?? set["id"] as? String ?? "?"
            let client = (set["client"] as? [String: Any])?["name"] as? String ?? "?"
            return "\(id) (client \(client))"
        }
        return " · data sets: " + (described.isEmpty ? "none" : described.joined(separator: ", "))
    }
}
