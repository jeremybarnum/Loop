//
//  LoanRemoteUploads.swift
//  WatchApp
//
//  Nightscout uploads from the wrist while it holds the pod. Stock's RemoteDataServicesManager,
//  compiled into this target unchanged, drives an in-memory NightscoutService built from the
//  site and secret the Start grant carried. Its triggers are the store delegates stock's
//  DeviceDataManager uses on the phone.
//
//  Nothing here persists a credential: the site and secret live in memory from grant acceptance
//  until the pump is torn down, and are never logged. A relaunch mid-loan therefore resumes
//  without uploads. The query anchors are stock's, in this app's defaults, so a later loan
//  carries on from where the last one stopped.
//

import Foundation
import LoopKit
import LoopAlgorithm
import LoopCore
import NightscoutServiceKit

/// Stock declares this in DeviceDataManager.swift, which the watch does not compile.
protocol UploadEventListener {
    func triggerUpload(for triggeringType: RemoteDataType)
}

final class LoanRemoteUploads {
    static let shared = LoanRemoteUploads()

    private let lock = UnfairLock()

    /// From accepted grants; consumed when the service starts. Cleared only by `end`.
    private var stagedNightscout: LoanNightscoutCredentials?

    /// The phone's CGM's answer to "upload glucose?", from the grant. Cleared by `end`.
    private var phoneUploadsGlucose: Bool?

    /// Set while the loan is ACTIVE; credentials staged then start the service at once.
    private weak var activeLoop: WatchLoopManager?

    private var manager: RemoteDataServicesManager?
    private var nightscout: NightscoutService?

    /// Bumped by `end`, so a start still waiting for main does not outlive its loan.
    private var generation = 0

    /// Stock's manager wants a CGM event store; the wrist records none, so this one stays empty.
    private static let emptyCgmEventStore: LoopKit.CgmEventStore? = {
        guard let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let cacheStore = LoopKit.PersistenceController(directoryURL: documents.appendingPathComponent("LoanUploadsCgmEvents"), isReadOnly: false)
        return LoopKit.CgmEventStore(cacheStore: cacheStore)
    }()

    init() {}

    /// Credentials are staged or a running service holds them. For tests; says nothing of their values.
    var holdsNightscoutCredentials: Bool {
        lock.withLock { stagedNightscout != nil || nightscout != nil }
    }

    /// Called on grant acceptance. A grant without credentials never clears what is already
    /// staged (only `end` does); credentials arriving while the loan is ACTIVE start at once.
    func stage(nightscout: LoanNightscoutCredentials?) {
        let active = lock.withLock { () -> WatchLoopManager? in
            if let nightscout {
                stagedNightscout = nightscout
                phoneUploadsGlucose = nightscout.uploadsGlucose
            }
            return activeLoop
        }
        SportLog.event("uploads", "grant: Nightscout credentials \(nightscout == nil ? "absent (staged kept)" : "present")")
        if let active { startStaged(loopManager: active) }
    }

    /// Loan ACTIVE: start whatever is staged; a later grant can still bring credentials.
    func begin(loopManager: WatchLoopManager) {
        lock.withLock { activeLoop = loopManager }
        startStaged(loopManager: loopManager)
    }

    private func startStaged(loopManager: WatchLoopManager) {
        let (credentials, running, beganIn) = lock.withLock { () -> (LoanNightscoutCredentials?, Bool, Int) in
            defer { if nightscout == nil { stagedNightscout = nil } }
            return (nightscout == nil ? stagedNightscout : nil, nightscout != nil, generation)
        }
        guard let credentials else {
            if !running {
                SportLog.event("uploads", "loan active, no Nightscout credentials yet — uploads start if a grant brings them")
            }
            return
        }

        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard let manager = managerForLoan(loopManager, beganIn: beganIn) else { return }
                startNightscout(credentials, manager: manager, beganIn: beganIn)
            }
        }
    }

    /// One stock manager per loan, with stock's store-delegate triggers.
    @MainActor
    private func managerForLoan(_ loopManager: WatchLoopManager, beganIn: Int) -> RemoteDataServicesManager? {
        if let existing = lock.withLock({ self.generation == beganIn ? self.manager : nil }) { return existing }
        guard let alertStore = loopManager.alertStore,
              let dosingDecisionStore = loopManager.dosingDecisionStore,
              let deviceLog = loopManager.deviceLog,
              let emptyCgmEventStore = LoanRemoteUploads.emptyCgmEventStore else {
            SportLog.event("uploads", "a store is missing — uploads OFF for this loan")
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
            SportLog.event("uploads", "loan ended before uploads started — not starting")
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
        SportLog.event("uploads", "uploads ON — stock RemoteDataServicesManager driving NightscoutService (site and secret not logged)")
    }

    /// Pump teardown or loan end. Synchronous, so nothing the teardown writes afterwards is
    /// uploaded; idempotent.
    func end() {
        let (service, loopManager) = lock.withLock { () -> (NightscoutService?, WatchLoopManager?) in
            defer {
                manager = nil; nightscout = nil; stagedNightscout = nil; activeLoop = nil; phoneUploadsGlucose = nil
                generation += 1
            }
            return (nightscout, activeLoop)
        }

        // An upload already under way finds no configuration and returns.
        if let service {
            service.siteURL = nil
            service.apiSecret = nil
            SportLog.event("uploads", "uploads OFF — loan over, service dropped")
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
    /// As stock DeviceDataManager, the CGM manager decides. During a loan the watch is the only
    /// glucose uploader (the phone holds its own); with no CGM of its own it follows the phone's
    /// CGM, whose readings it holds (seeded and relayed). An older phone sends no answer: stock's yes.
    var shouldSyncGlucoseToRemoteService: Bool {
        let (loop, phone) = lock.withLock { (activeLoop, phoneUploadsGlucose) }
        return loop?.cgmManager?.shouldSyncToRemoteService ?? phone ?? true
    }
}

extension LoanRemoteUploads: AutomationHistoryProvider {
    /// The wrist keeps no automation history; the loan's current mode stands for the window.
    func automationHistory(from start: Date, to end: Date) async throws -> [AbsoluteScheduleValue<Bool>] {
        let enabled = lock.withLock { activeLoop }?.closedLoopEnabledNonBlocking ?? false
        return [AbsoluteScheduleValue(startDate: start, endDate: end, value: enabled)]
    }
}
