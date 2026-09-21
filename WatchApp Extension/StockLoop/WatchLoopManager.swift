//
//  WatchLoopManager.swift
//  WatchApp Extension
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import G7SensorKit
import WatchConnectivity
import os.log

enum WatchLoopError: Error {
    case configurationError(String)

    case missingDataError(String)

    case enactFailed(String)

    case recommendationExpired(date: Date)

    case pumpSuspended

    case pumpManagerUnconnected
}

extension WatchLoopError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .configurationError(let field):
            return String(format: NSLocalizedString("Missing setting: %@", comment: "Watch loop error (1: setting name)"), field)
        case .missingDataError(let what):
            return String(format: NSLocalizedString("Missing data: %@", comment: "Watch loop error (1: data name)"), what)
        case .enactFailed(let why):

            return String(format: NSLocalizedString("The pod did not accept the dose: %@", comment: "Watch loop error (1: pump error)"), why)
        case .recommendationExpired:
            return NSLocalizedString("The recommendation expired before enacting.", comment: "Watch loop error")
        case .pumpSuspended:
            return NSLocalizedString("Insulin delivery is suspended.", comment: "Watch loop error")
        case .pumpManagerUnconnected:
            return NSLocalizedString("No pod connected to the watch.", comment: "Watch loop error")
        }
    }
}

final class WatchLoopManager {
    let doseStore: DoseStore
    let glucoseStore: GlucoseStore
    let carbStore: CarbStore

    let settingsProvider: WatchSettingsProvider

    let overrideHistory: TemporaryScheduleOverrideHistory

    private let grantedMaximumBolusLock = NSLock()
    private var _grantedMaximumBolus: Double?

    var grantedMaximumBolus: Double? {
        grantedMaximumBolusLock.lock()
        defer { grantedMaximumBolusLock.unlock() }
        return _grantedMaximumBolus
    }

    var settings: LoopSettings {
        didSet {
            grantedMaximumBolusLock.lock()
            _grantedMaximumBolus = settings.maximumBolus
            grantedMaximumBolusLock.unlock()

            settingsProvider.update(with: settings)

        }
    }

    private var _scheduleOverride: TemporaryScheduleOverride?

    var scheduleOverride: TemporaryScheduleOverride? {
        get { _scheduleOverride }
        set {
            let oldValue = _scheduleOverride
            guard newValue != oldValue else { return }
            _scheduleOverride = newValue
            overrideHistory.recordOverride(newValue)

            if let o = newValue {
                let target = o.settings.targetRange.map {
                    String(format: "%.0f-%.0f", $0.lowerBound.doubleValue(for: .milligramsPerDeciliter),
                           $0.upperBound.doubleValue(for: .milligramsPerDeciliter))
                } ?? "unchanged"
                SportLog.event("override", String(format: "APPLIED %@ · insulin needs %.0f%% (basal x%.2f, ISF x%.2f, CR x%.2f) · target %@ · ends %@",
                                                  o.context.presetNameForLog,
                                                  o.settings.effectiveInsulinNeedsScaleFactor * 100,
                                                  o.settings.basalRateMultiplier ?? 1.0,
                                                  o.settings.insulinSensitivityMultiplier ?? 1.0,
                                                  o.settings.carbRatioMultiplier ?? 1.0,
                                                  target,
                                                  o.duration.isInfinite ? "indefinite" : ISO8601DateFormatter().string(from: o.scheduledInterval.end)))
            } else if oldValue != nil {
                SportLog.event("override", "CLEARED — schedules resolve unscaled again")
            }

        }
    }

    func insulinModel(for type: InsulinType?) -> InsulinModel {
        switch type {
        case .fiasp: return ExponentialInsulinModelPreset.fiasp
        case .lyumjev: return ExponentialInsulinModelPreset.lyumjev
        case .afrezza: return ExponentialInsulinModelPreset.afrezza
        default: return settings.defaultRapidActingModel ?? ExponentialInsulinModelPreset.rapidActingAdult
        }
    }

    var pumpManager: PumpManager?

    var podBeepsOnManualBolusProbe: (() -> Bool)?

    var onCycleLanded: (() -> Void)?

    let awaitedPumpLock = NSLock()
    var awaitingPumpManager = false
    var readingArrivedWithoutPump = false

    func beginAwaitingPumpManager() {
        awaitedPumpLock.lock(); awaitingPumpManager = true; readingArrivedWithoutPump = false; awaitedPumpLock.unlock()
    }

    func endAwaitingPumpManager() -> Bool {
        awaitedPumpLock.lock(); defer { awaitedPumpLock.unlock() }
        let waited = readingArrivedWithoutPump
        awaitingPumpManager = false
        readingArrivedWithoutPump = false
        return waited
    }
    var podBeepsOnManualBolus: Bool { podBeepsOnManualBolusProbe?() ?? false }

    let deviceLogThrottle = DeviceLogThrottle()

    private let manualBolusLock = NSLock()
    private var _manualBolusInFlight = false

    var manualBolusStartedAt: Date? {
        manualBolusLock.lock(); defer { manualBolusLock.unlock() }
        return _manualBolusInFlight ? _manualBolusStartedAt : nil
    }
    private var _manualBolusStartedAt: Date?

    private var _manualBolusPendingUnits: Double?
    var manualBolusPendingUnits: Double? {
        manualBolusLock.lock(); defer { manualBolusLock.unlock() }
        return _manualBolusInFlight ? _manualBolusPendingUnits : nil
    }
    func setManualBolusInFlight(_ inFlight: Bool, units: Double? = nil) {
        manualBolusLock.lock()
        _manualBolusInFlight = inFlight
        _manualBolusStartedAt = inFlight ? self.now() : nil
        _manualBolusPendingUnits = inFlight ? units : nil
        manualBolusLock.unlock()
    }

    private var _manualBolusDelivery: (units: Double, startedAt: Date, endsAt: Date)?

    var manualBolusDelivery: (units: Double, startedAt: Date, endsAt: Date)? {
        manualBolusLock.lock(); defer { manualBolusLock.unlock() }
        guard let d = _manualBolusDelivery, d.endsAt > self.now() else { return nil }
        return d
    }
    func setManualBolusDelivering(units: Double, from startedAt: Date, to endsAt: Date) {
        manualBolusLock.lock()
        _manualBolusDelivery = (units: units, startedAt: startedAt, endsAt: endsAt)
        manualBolusLock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .manualBolusStateDidChange, object: nil)
        }
    }

    var _closedLoopEnabled = false
    var closedLoopEnabled: Bool {
        dataAccessQueue.sync { _closedLoopEnabled }
    }

    private let closedLoopMirrorLock = NSLock()
    private var _closedLoopMirror = false
    var closedLoopEnabledNonBlocking: Bool {
        closedLoopMirrorLock.lock()
        defer { closedLoopMirrorLock.unlock() }
        return _closedLoopMirror
    }

    static let closedLoopDefaultsKey = "WatchLoopManager.closedLoopEnabled"
    static let integralRCDefaultsKey = "WatchLoopManager.integralRetrospectiveCorrection"
    var isIntegralRetrospectiveCorrectionEnabled: Bool { dataAccessQueue.sync { integralRetrospectiveCorrectionEnabled } }

    func resetClosedLoopForSessionEnd() {
        UserDefaults.standard.set(false, forKey: Self.closedLoopDefaultsKey)
        closedLoopMirrorLock.lock()
        _closedLoopMirror = false
        closedLoopMirrorLock.unlock()
        dataAccessQueue.async {
            self._closedLoopEnabled = false
        }
    }

    func setClosedLoopEnabled(_ enabled: Bool, reason: String = "by user") {
        UserDefaults.standard.set(enabled, forKey: Self.closedLoopDefaultsKey)

        closedLoopMirrorLock.lock()
        let wasEnabled = _closedLoopMirror
        _closedLoopMirror = enabled
        closedLoopMirrorLock.unlock()

        dataAccessQueue.async {
            self._closedLoopEnabled = enabled
            SportLog.event("loop", enabled ? "CLOSED \(reason) — the watch will adjust basal" : "OPENED \(reason) — advisory only, no dosing")

            self.publishHUDContext()

            guard wasEnabled, !enabled else { return }
            let recommendation = AutomaticDoseRecommendation(basalAdjustment: .cancel, direction: .decrease)
            self.recommendedAutomaticDose = (recommendation: recommendation, date: self.now())
            if let error = self.enactRecommendedAutomaticDose() {
                SportLog.event("loop", "OPEN: temp cancel FAILED — \(String(describing: error)); the pod keeps its current rate until the temp expires")
            } else {
                SportLog.event("loop", "OPEN: running temp cancelled — pod reverts to the user's schedule")
            }
        }
    }

    func applyWristOverride(_ override: TemporaryScheduleOverride?) {
        if let o = override {
            let target = o.settings.targetRange.map {
                String(format: "%.0f-%.0f", $0.lowerBound.doubleValue(for: .milligramsPerDeciliter),
                       $0.upperBound.doubleValue(for: .milligramsPerDeciliter))
            } ?? "unchanged"
            SportLog.event("override", String(format: "SET-ON-WRIST %@ · insulin needs %.0f%% · target %@ · ends %@ · sync %@",
                                              o.context.presetNameForLog,
                                              o.settings.effectiveInsulinNeedsScaleFactor * 100,
                                              target,
                                              o.duration.isInfinite ? "indefinite" : ISO8601DateFormatter().string(from: o.scheduledInterval.end),
                                              o.syncIdentifier.uuidString))
        } else {
            SportLog.event("override", "SET-ON-WRIST · CLEARED by user — the loan's schedules resolve unscaled from here")
        }
        scheduleOverride = override
    }

    struct PredictionBreakdown {
        let startMgdl: Double

        let eventualMgdl: Double
        let insulinMgdl: Double
        let carbMgdl: Double
        let momentumMgdl: Double
        let retrospectiveMgdl: Double

        let residualMgdl: Double

        let insulinRawTailMgdl: Double?

        let insulinExpectedMgdl: Double?
        let isfMgdlPerU: Double?
        let iobUnits: Double?
        let momentumPointCount: Int
        let computedAt: Date

        static func round0(_ v: Double) -> Double {
            guard v.isFinite else { return 0 }
            let x = v.rounded()
            return x == 0 ? 0 : x
        }
    }

    struct GlanceData {
        let glucose: LoopQuantity?
        let glucoseDate: Date?

        let directG7At: Date?
        let phoneRelayAt: Date?
        let trend: GlucoseTrend?
        let eventual: LoopQuantity?
        let iob: Double?

        let tempRate: Double?
        let lastLoopCompleted: Date?
        let suspendThreshold: LoopQuantity?
        let closedLoopEnabled: Bool

        let recommendedTempRate: Double?
        let lastLoopErrorText: String?

        let predictionBreakdown: PredictionBreakdown?

        let retrospectiveCorrectionIsIntegral: Bool
        let retrospectiveDiscrepancyCount: Int

        let overrideLabel: String?
    }

    func runningTempBasal() -> DoseEntry? {
        if case .some(.tempBasal(let dose)) = pumpManager?.status.basalDeliveryState { return dose }
        return nil
    }

    let glanceMirrorLock = NSLock()
    var _glanceMirror: GlanceData?
    var _glanceRefreshPending = false

    var mirroredGlanceData: GlanceData? {
        glanceMirrorLock.lock()
        defer { glanceMirrorLock.unlock() }
        return _glanceMirror
    }

    static let glanceMirrorDidUpdate = Notification.Name("com.loopkit.Loop.glanceMirrorDidUpdate")

    let deviceQueue = DispatchQueue(label: "com.loopkit.Loop.WatchLoopManager.deviceQueue", qos: .utility)

    let dataAccessQueue = DispatchQueue(label: "com.loopkit.Loop.WatchLoopManager.dataAccessQueue", qos: .utility)

    let log = OSLog(category: "WatchLoopManager")

    var now: () -> Date = { Date() }

    var defaults: UserDefaults = .standard

    init(doseStore: DoseStore, glucoseStore: GlucoseStore, carbStore: CarbStore,
         overrideHistory: TemporaryScheduleOverrideHistory = TemporaryScheduleOverrideHistory(),
         settings: LoopSettings = LoopSettings()) {
        self.doseStore = doseStore
        self.glucoseStore = glucoseStore
        self.carbStore = carbStore
        self.settingsProvider = WatchSettingsProvider(settings: settings)
        self.overrideHistory = overrideHistory
        self.settings = settings
        self.lastLoopCompleted = UserDefaults.standard.object(forKey: Self.lastLoopCompletedKey) as? Date
        let closed = UserDefaults.standard.bool(forKey: Self.closedLoopDefaultsKey)
        self._closedLoopEnabled = closed
        self._closedLoopMirror = closed
        self.integralRetrospectiveCorrectionEnabled = UserDefaults.standard.bool(forKey: Self.integralRCDefaultsKey)

        doseStore.delegate = self
        #if !targetEnvironment(simulator)

        NotificationCenter.default.addObserver(forName: LoopDataManager.didUpdateContextNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.ingestPhoneGlucoseFromContext()
        }
        #endif
    }

    private let bgSourceLock = NSLock()
    private var _lastDirectG7At: Date?
    private var _lastPhoneRelayAt: Date?

    static let startGateSilenceLimit: TimeInterval = .minutes(15)

    enum StartGateVerdict: Equatable {
        case allowed

        case noDirectConnection(sensorName: String, silentMinutes: Int)

        case waitingForFirstReading(sensorName: String)

        case noSensorEverEnrolled
    }

    static func startGateVerdict(sensorName: String?,
                                 sensorActivatedAt: Date?,
                                 lastDirectG7At: Date?,
                                 now: Date) -> StartGateVerdict {
        guard let name = sensorName else { return .noSensorEverEnrolled }

        guard !persistedSensorIsPastLife(sensorActivatedAt, now: now) else { return .allowed }
        guard let lastDirect = lastDirectG7At else {
            return .waitingForFirstReading(sensorName: name)
        }
        let silent = now.timeIntervalSince(lastDirect)
        guard silent > startGateSilenceLimit else { return .allowed }
        return .noDirectConnection(sensorName: name, silentMinutes: Int(silent / 60))
    }

    func sportModeStartGate(now: Date = Date()) -> StartGateVerdict {
        Self.startGateVerdict(sensorName: g7Manager?.sensorName,
                              sensorActivatedAt: g7Manager?.sensorActivatedAt,
                              lastDirectG7At: lastGlucoseSourceStamps.direct,
                              now: now)
    }

    static func persistedSensorIsPastLife(_ activatedAt: Date?, now: Date = Date()) -> Bool {
        guard let activatedAt else { return false }
        return now.timeIntervalSince(activatedAt) > .hours(10 * 24 + 12)
    }

    weak var g7Manager: G7CGMManager?

    var lastPersistedSensorID: String?

    static let lastDirectG7DefaultsKey = "SportMode.lastDirectG7At"

    func noteGlucoseSource(directG7: Bool) {
        bgSourceLock.lock()
        if directG7 { _lastDirectG7At = self.now() } else { _lastPhoneRelayAt = self.now() }
        bgSourceLock.unlock()
        if directG7 {
            defaults.set(self.now(), forKey: Self.lastDirectG7DefaultsKey)
        }

        refreshGlanceData()
    }

    func notePhoneGlucoseDelivered() {
        noteGlucoseSource(directG7: false)
    }

    var g7ContentionSummary: String {
        let stamps = lastGlucoseSourceStamps
        func age(_ d: Date?) -> String { d.map { String(format: "%.0fs", now().timeIntervalSince($0)) } ?? "never" }

        return "g7direct=\(age(stamps.direct)) phoneRelay=\(age(stamps.phone))"
    }

    var lastGlucoseSourceStamps: (direct: Date?, phone: Date?) {
        bgSourceLock.lock()
        let mem = (_lastDirectG7At, _lastPhoneRelayAt)
        bgSourceLock.unlock()

        let direct = mem.0 ?? defaults.object(forKey: Self.lastDirectG7DefaultsKey) as? Date
        return (direct, mem.1)
    }

    var basalRateScheduleApplyingOverrideHistory: BasalRateSchedule? {
        settings.basalRateSchedule.map { overrideHistory.resolvingRecentBasalSchedule($0) }
    }

    func setIntegralRetrospectiveCorrection(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.integralRCDefaultsKey)
        dataAccessQueue.async {
            self.integralRetrospectiveCorrectionEnabled = enabled
            SportLog.event("loan", "retrospective correction: \(enabled ? "INTEGRAL" : "standard") (from grant)")
        }
    }

    var liveInsulinOnBoard: Double? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        return insulinOnBoardFromStore(at: now()) ?? activeInsulin
    }

    var integralRetrospectiveCorrectionEnabled = false

    var predictedGlucose: [PredictedGlucoseValue]?

    var activeInsulin: Double?
    var activeCarbs: Double?
    var lastAlgorithmEffects: LoopAlgorithmEffects<StoredCarbEntry>?

    var lastPredictionBreakdown: PredictionBreakdown?

    var recommendedAutomaticDose: (recommendation: AutomaticDoseRecommendation, date: Date)?

    var phonePredictionSnapshotAtGrant: LoanPredictionSnapshot?
    func stashPhonePredictionSnapshot(_ snapshot: LoanPredictionSnapshot?) {
        dataAccessQueue.async { self.phonePredictionSnapshotAtGrant = snapshot }
    }

    var lastRecommendation: AutomaticDoseRecommendation?

    private static let lastLoopCompletedKey = "WatchLoopManager.lastLoopCompleted"
    var lastLoopCompleted: Date? {
        didSet { UserDefaults.standard.set(lastLoopCompleted, forKey: Self.lastLoopCompletedKey) }
    }

    func seedLastLoopCompleted(_ date: Date, source: String) {
        guard (lastLoopCompleted ?? .distantPast) < date else { return }
        lastLoopCompleted = date
        SportLog.event("loop", String(format: "loop recency SEEDED from %@ — last cycle %.0fs ago", source, self.now().timeIntervalSince(date)))
    }
    var lastLoopError: Error?

    var lastCGMLoopTrigger: Date = .distantPast

    var lastPhoneFallbackSyncId: String?

    let doseEnactor = WatchDoseEnactor()

    var loggedIdleNoPump = false

}

extension TemporaryScheduleOverride.Context {
    var presetNameForLog: String {
        switch self {
        case .preMeal: return "pre-meal"
        case .preset(let preset):
            return [preset.symbol?.textGlyph, preset.name].compactMap { $0 }.joined(separator: " ")
        case .activity(let preset):
            return [preset.activityType.symbol.textGlyph, preset.activityType.name].compactMap { $0 }.joined(separator: " ")
        case .custom: return "custom"
        }
    }
}

private extension PresetSymbol {
    var textGlyph: String? { symbolType == .emoji ? value : nil }
}
