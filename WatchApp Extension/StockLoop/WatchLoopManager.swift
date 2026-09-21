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

    private let awaitedPumpLock = NSLock()
    private var awaitingPumpManager = false
    private var readingArrivedWithoutPump = false

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

    private let deviceLogThrottle = DeviceLogThrottle()

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
    fileprivate func setManualBolusInFlight(_ inFlight: Bool, units: Double? = nil) {
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
    fileprivate func setManualBolusDelivering(units: Double, from startedAt: Date, to endsAt: Date) {
        manualBolusLock.lock()
        _manualBolusDelivery = (units: units, startedAt: startedAt, endsAt: endsAt)
        manualBolusLock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .manualBolusStateDidChange, object: nil)
        }
    }

    private var _closedLoopEnabled = false
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

    private let glanceMirrorLock = NSLock()
    private var _glanceMirror: GlanceData?
    private var _glanceRefreshPending = false

    var mirroredGlanceData: GlanceData? {
        glanceMirrorLock.lock()
        defer { glanceMirrorLock.unlock() }
        return _glanceMirror
    }

    func refreshGlanceData() {
        glanceMirrorLock.lock()
        if _glanceRefreshPending { glanceMirrorLock.unlock(); return }
        _glanceRefreshPending = true
        glanceMirrorLock.unlock()

        dataAccessQueue.async { [weak self] in
            guard let self = self else { return }
            let data = self.buildGlanceData()
            self.glanceMirrorLock.lock()
            self._glanceMirror = data
            self._glanceRefreshPending = false
            self.glanceMirrorLock.unlock()

            NotificationCenter.default.post(name: Self.glanceMirrorDidUpdate, object: nil)
        }
    }

    static let glanceMirrorDidUpdate = Notification.Name("com.loopkit.Loop.glanceMirrorDidUpdate")

    func glanceData() -> GlanceData {
        return dataAccessQueue.sync { self.buildGlanceData() }
    }

    private func buildGlanceData() -> GlanceData {
            let latest = glucoseStore.latestGlucose
            var tempRate: Double?
            if let dose = runningTempBasal() {
                let scheduled = (basalRateScheduleApplyingOverrideHistory ?? settings.basalRateSchedule)?.value(at: now()) ?? 0
                tempRate = dose.unitsPerHour - scheduled
            }
            let sources = self.lastGlucoseSourceStamps

            let liveIOB: Double? = liveInsulinOnBoard
            return GlanceData(
                glucose: latest?.quantity,
                glucoseDate: latest?.startDate,
                directG7At: sources.direct,
                phoneRelayAt: sources.phone,
                trend: (latest as? StoredGlucoseSample)?.trend,

                eventual: predictedGlucose?.last?.quantity,
                iob: liveIOB,
                tempRate: tempRate,
                lastLoopCompleted: lastLoopCompleted,
                suspendThreshold: settings.suspendThreshold?.quantity,
                closedLoopEnabled: _closedLoopEnabled,

                recommendedTempRate: lastRecommendation?.basalAdjustment.unitsPerHour,
                lastLoopErrorText: lastLoopError.map { String(describing: $0) },

                predictionBreakdown: lastPredictionBreakdown,

                retrospectiveCorrectionIsIntegral: integralRetrospectiveCorrectionEnabled,
                retrospectiveDiscrepancyCount: lastAlgorithmEffects?.retrospectiveGlucoseDiscrepancies.count ?? 0,
                overrideLabel: {
                    guard let o = scheduleOverride, o.isActive() else { return nil }

                    var parts: [String] = []
                    if case .preset(let p) = o.context,
                       let symbol = p.symbol?.textualRepresentation, !symbol.isEmpty {
                        parts.append(symbol)
                    } else {
                        parts.append("⏱")
                    }
                    if let scale = o.settings.insulinNeedsScaleFactor {
                        parts.append("\(Int((scale * 100).rounded()))%")
                    }
                    if let range = o.settings.targetRange {
                        let mid = (range.lowerBound.doubleValue(for: .milligramsPerDeciliter)
                                   + range.upperBound.doubleValue(for: .milligramsPerDeciliter)) / 2
                        parts.append(String(format: "%.0f", mid))
                    }
                    return parts.joined(separator: " ")
                }())
    }

    func glanceCarbsOnBoard(_ completion: @escaping (Double?) -> Void) {
        dataAccessQueue.async { [weak self] in

            completion(self?.activeCarbs)
        }
    }

    private func publishOwnGlucoseContextWhenIdle() {
        guard pumpManager == nil, let latest = glucoseStore.latestGlucose else { return }
        let trend = (latest as? StoredGlucoseSample)?.trend
        let mgdl = Int(latest.quantity.doubleValue(for: .milligramsPerDeciliter).rounded())
        DispatchQueue.main.async {
            let manager = LoopDataManager.shared
            let ctx = manager.activeContext.flatMap { WatchContext(rawValue: $0.rawValue) } ?? WatchContext()
            ctx.isWatchAuthored = true
            ctx.glucoseSyncIdentifier = nil
            ctx.glucose = latest.quantity
            ctx.glucoseDate = latest.startDate
            ctx.glucoseTrend = trend
            manager.updateContext(ctx)
            NotificationCenter.default.post(name: LoopDataManager.didUpdateContextNotification, object: manager)
            SportLog.event("glucose", "complication fed from the watch's own reading (idle, no loan) — \(mgdl) mg/dL")
        }
    }

    private func publishHUDContext() {
        guard pumpManager != nil else { return }
        let ctx = WatchContext()
        ctx.isWatchAuthored = true

        ctx.isOnboardingCompleted = true

        ctx.predictedGlucose = predictedGlucose.flatMap { WatchPredictedGlucose(values: $0) }
        let latest = glucoseStore.latestGlucose
        ctx.glucose = latest?.quantity
        ctx.glucoseDate = latest?.startDate
        ctx.glucoseTrend = (latest as? StoredGlucoseSample)?.trend

        ctx.iob = liveInsulinOnBoard
        ctx.loopLastRunDate = lastLoopCompleted
        ctx.isClosedLoop = _closedLoopEnabled
        if let dose = runningTempBasal() {
            let scheduled = (basalRateScheduleApplyingOverrideHistory ?? settings.basalRateSchedule)?.value(at: now()) ?? 0
            ctx.lastNetTempBasalDose = dose.unitsPerHour - scheduled
            ctx.lastNetTempBasalDate = dose.startDate
        } else {
            ctx.lastNetTempBasalDose = 0
            ctx.lastNetTempBasalDate = now()
        }

        do {
            if let cob = activeCarbs {
                ctx.cob = cob

                if cob > 0.05 { SportLog.event("loop", String(format: "COB %.1f g on board", cob)) }
            }

            switch self.manualBolusRecommendationOnQueue() {
            case .success(let recommendation):

                SportLog.event("loan", String(format: "REC bolus %.2f U — published to the stock bolus flow", recommendation.amount))
                ctx.recommendedBolusDose = recommendation.amount
            case .failure(let error):

                SportLog.event("loan", "REC bolus UNAVAILABLE — \(error) (the flow will show 'REC: – U')")
            }
            DispatchQueue.main.async {
                guard let loopDataManager = ExtensionDelegate.sharedIfAvailable()?.loopManager else { return }
                ctx.displayGlucoseUnit = loopDataManager.activeContext?.displayGlucoseUnit ?? ctx.displayGlucoseUnit
                loopDataManager.updateContext(ctx)
                NotificationCenter.default.post(name: LoopDataManager.didUpdateContextNotification, object: loopDataManager)
            }
        }
    }

    let deviceQueue = DispatchQueue(label: "com.loopkit.Loop.WatchLoopManager.deviceQueue", qos: .utility)

    private let dataAccessQueue = DispatchQueue(label: "com.loopkit.Loop.WatchLoopManager.dataAccessQueue", qos: .utility)

    private let log = OSLog(category: "WatchLoopManager")

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

    private func noteGlucoseSource(directG7: Bool) {
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

    private var lastGlucoseSourceStamps: (direct: Date?, phone: Date?) {
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

    private var liveInsulinOnBoard: Double? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        return insulinOnBoardFromStore(at: now()) ?? activeInsulin
    }

    private var integralRetrospectiveCorrectionEnabled = false

    private var predictedGlucose: [PredictedGlucoseValue]?

    private var activeInsulin: Double?
    private var activeCarbs: Double?
    private var lastAlgorithmEffects: LoopAlgorithmEffects<StoredCarbEntry>?

    private var lastPredictionBreakdown: PredictionBreakdown?

    private var recommendedAutomaticDose: (recommendation: AutomaticDoseRecommendation, date: Date)?

    private var phonePredictionSnapshotAtGrant: LoanPredictionSnapshot?
    func stashPhonePredictionSnapshot(_ snapshot: LoanPredictionSnapshot?) {
        dataAccessQueue.async { self.phonePredictionSnapshotAtGrant = snapshot }
    }

    private var lastRecommendation: AutomaticDoseRecommendation?

    private static let lastLoopCompletedKey = "WatchLoopManager.lastLoopCompleted"
    private(set) var lastLoopCompleted: Date? {
        didSet { UserDefaults.standard.set(lastLoopCompleted, forKey: Self.lastLoopCompletedKey) }
    }

    func seedLastLoopCompleted(_ date: Date, source: String) {
        guard (lastLoopCompleted ?? .distantPast) < date else { return }
        lastLoopCompleted = date
        SportLog.event("loop", String(format: "loop recency SEEDED from %@ — last cycle %.0fs ago", source, self.now().timeIntervalSince(date)))
    }
    private(set) var lastLoopError: Error?

    private var lastCGMLoopTrigger: Date = .distantPast

    var lastPhoneFallbackSyncId: String?

    func seedInsulinHistory(_ entries: [DoseEntry]) async throws {
        try await doseStore.syncDoseEntries(entries)
    }

    func recordPumpEvents(_ events: [NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool) async throws {
        try await doseStore.addPumpEvents(events, lastReconciliation: lastReconciliation, replacePendingEvents: replacePendingEvents)
    }

    func resetInsulinBook(reason: String) async {
        do {
            try await doseStore.resetPumpData()
        } catch {
            SportLog.event("book", "reset FAILED (pump events) — \(reason): \(String(describing: error))")
        }
        await doseStore.insulinDeliveryStore.purgeCachedInsulinDeliveryObjects()
        SportLog.event("book", "insulin book reset — \(reason)")
    }

    func insulinOnBoardFromStore(at date: Date) -> Double? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        guard let basal = basalRateScheduleApplyingOverrideHistory else { return nil }
        let longest = doseStore.longestEffectDuration
        guard let doses = try? runBlocking({
            try await self.doseStore.getNormalizedDoseEntries(start: date.addingTimeInterval(-longest), end: nil)
        }) else { return nil }
        if doses.isEmpty { return 0 }
        let window = (start: doses.map(\.startDate).min() ?? date,
                      end: (doses.map(\.endDate).max() ?? date).addingTimeInterval(longest))
        let basalTimeline = BasalRateSchedule.generateTimeline(
            schedules: [(date: .distantPast, schedule: basal)],
            startDate: window.start,
            endDate: window.end)
        let timeline = doses
            .map { $0.simpleDose(with: insulinModel(for: $0.insulinType)) }
            .annotated(with: basalTimeline)
            .insulinOnBoardTimeline(longestEffectDuration: longest,
                                    from: date.addingTimeInterval(-.minutes(5)),
                                    to: date.addingTimeInterval(.minutes(5)))
        let before = timeline.last(where: { $0.startDate <= date })?.value
        let after = timeline.first(where: { $0.startDate >= date })?.value
        return max(before ?? 0, after ?? 0)
    }

    func primeIOBFromStore(at date: Date, _ completion: @escaping (Double?) -> Void) {
        dataAccessQueue.async {
            let iob = self.insulinOnBoardFromStore(at: date)
            if let iob { self.activeInsulin = iob }
            completion(iob)
        }
    }

    private let doseEnactor = WatchDoseEnactor()

    private var loggedIdleNoPump = false

    func checkPumpDataAndLoop() {
        guard let pumpManager = pumpManager else {
            awaitedPumpLock.lock()
            if awaitingPumpManager { readingArrivedWithoutPump = true }
            awaitedPumpLock.unlock()

            if !loggedIdleNoPump {
                loggedIdleNoPump = true
                SportLog.event("loop", "idle — no pod on the watch; cycles paused until the next grant (glucose still ingesting)")
            }
            return
        }
        loggedIdleNoPump = false

        pumpManager.ensureCurrentPumpData { _ in self.loop() }
    }

    func loop() {
        dataAccessQueue.async {
            self.log.default("Loop running")
            self.lastLoopError = nil
            let startDate = self.now()

            var error: WatchLoopError? = nil
            if error == nil {
                error = self.updatePredictedGlucoseAndRecommendedDose()
            }

            if case .missingDataError(let what)? = error {
                SportLog.event("loop", "NOT DOSING — prediction missing \(what)")
            }

            let decided = self.recommendedAutomaticDose?.recommendation
            self.lastRecommendation = decided
            if error == nil, self._closedLoopEnabled {
                error = self.enactRecommendedAutomaticDose()
            } else if error == nil {
                self.log.default("Advisory (open loop) — computed but not enacting.")
            }

            self.lastLoopError = error

            let enactVerdict: String
            if !self._closedLoopEnabled { enactVerdict = "none(open-loop)" }
            else if decided?.basalAdjustment == nil && decided != nil { enactVerdict = "none(no-change)" }
            else if decided == nil { enactVerdict = "none(nothing-decided)" }
            else if case .enactFailed(let why)? = error { enactVerdict = "FAILED \(why)" }
            else if error != nil { enactVerdict = "not-attempted(\(error!))" }
            else { enactVerdict = "ok" }

            let watchdogRefreshed = (error == nil && self.pumpManager != nil)
            if watchdogRefreshed { LoopStallWatchdog.refresh(); self.onCycleLanded?() }
            let sinceCompleted = self.lastLoopCompleted.map { Int(self.now().timeIntervalSince($0)) }

            let computeSucceeded: Bool = {
                switch error {
                case .none: return true
                case .enactFailed, .pumpManagerUnconnected: return true
                default: return false
                }
            }()

            SportLog.event("loop", String(format: "CYCLE VERDICT computed=%@ enact=%@ watchdog=%@ lastCompletedAge=%@",
                                          computeSucceeded ? "ok" : "FAILED",
                                          enactVerdict,
                                          watchdogRefreshed ? "refreshed" : "HELD",
                                          sinceCompleted.map { "\($0)s" } ?? "never") + " · " + batteryTag())

            if let error {
                self.log.error("Loop ended with error: %{public}@", String(describing: error))

                if case .missingDataError = error {} else {
                    SportLog.event("loop", "cycle ended with error: \(error)")
                }
            } else {
                self.lastLoopCompleted = self.now()
                self.log.default("Loop ended (duration %.1fs)", self.now().timeIntervalSince(startDate))
                let bg = self.glucoseStore.latestGlucose.map { String(format: "%.0f", $0.quantity.doubleValue(for: .milligramsPerDeciliter)) } ?? "—"

                let rec = decided.map { String(format: "%.2f U/h", $0.basalAdjustment.unitsPerHour) } ?? "none"
                SportLog.event("loop", "cycle OK — BG \(bg), IOB \(self.activeInsulin.map { String(format: "%.2f", $0) } ?? "—"), temp \(rec)")
                self.logPredictionBreakdown(decided: decided)
            }

            self.publishHUDContext()
        }
    }

    func refreshPredictionForGlance() {
        dataAccessQueue.async {
            var error: WatchLoopError? = nil
            if error == nil {
                error = self.updatePredictedGlucoseAndRecommendedDose()
            }
            if case .missingDataError(let what)? = error {
                SportLog.event("loop", "takeover prediction refresh — not yet (missing \(what))")
            } else if error == nil {
                self.lastRecommendation = self.recommendedAutomaticDose?.recommendation
                SportLog.event("loop", "takeover prediction refresh — IOB \(self.activeInsulin.map { String(format: "%.2f U", $0) } ?? "—"), eventual + carbs refreshed (no enact)")
                self.logPredictionBreakdown(decided: self.recommendedAutomaticDose?.recommendation)
            }
            self.publishHUDContext()
        }
    }

    private func logPredictionBreakdown(decided: AutomaticDoseRecommendation? = nil) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        func net(_ effects: [GlucoseEffect]?) -> String {
            guard let effects, !effects.isEmpty else { return "—" }
            let forward = effects.filter { $0.startDate >= now() }
            guard let first = forward.first, let last = forward.last else { return "—" }
            let mgdl = LoopUnit.milligramsPerDeciliter
            return String(format: "%+.0f", last.quantity.doubleValue(for: mgdl) - first.quantity.doubleValue(for: mgdl))
        }

        let mgdlU = LoopUnit.milligramsPerDeciliter
        let eventual = predictedGlucose?.last.map { String(format: "%.0f", $0.quantity.doubleValue(for: mgdlU)) } ?? "—"

        let rec: String

        if let r = decided ?? recommendedAutomaticDose?.recommendation {
            let basal = String(format: "%.2f U/h", r.basalAdjustment.unitsPerHour)
            let bolus = r.bolusUnits.map { String(format: " + auto-bolus %.2f U", $0) } ?? ""
            rec = basal + bolus
        } else {
            rec = "none"
        }

        let minPredicted: String = {
            guard let fwd = predictedGlucose?.filter({ $0.startDate >= now() }), !fwd.isEmpty,
                  let m = fwd.min(by: { $0.quantity.doubleValue(for: mgdlU) < $1.quantity.doubleValue(for: mgdlU) })
            else { return "—" }
            return String(format: "%.0f@%dm", m.quantity.doubleValue(for: mgdlU), Int(m.startDate.timeIntervalSince(now()) / 60))
        }()
        let suspendThr = settings.suspendThreshold.map { String(format: "%.0f", $0.quantity.doubleValue(for: mgdlU)) } ?? "—"

        let e = lastAlgorithmEffects

        lastPredictionBreakdown = {
            func delta(_ effects: [GlucoseEffect]?) -> Double {
                guard let effects else { return 0 }
                let forward = effects.filter { $0.startDate >= now() }
                guard let first = forward.first, let last = forward.last else { return 0 }
                return last.quantity.doubleValue(for: mgdlU) - first.quantity.doubleValue(for: mgdlU)
            }
            guard let start = glucoseStore.latestGlucose?.quantity.doubleValue(for: mgdlU),
                  let eventualValue = predictedGlucose?.last?.quantity.doubleValue(for: mgdlU) else { return nil }
            let insulin = delta(e?.insulin)
            let carb = delta(e?.carbs)
            let momentum = delta(e?.momentum)
            let retro = delta(e?.retrospectiveCorrection)

            let rawTail: Double? = {
                guard let tail = e?.insulin, let last = tail.last else { return nil }
                let base = tail.last(where: { $0.startDate <= now() }) ?? tail.first
                guard let base else { return nil }
                return last.quantity.doubleValue(for: mgdlU) - base.quantity.doubleValue(for: mgdlU)
            }()
            return PredictionBreakdown(
                startMgdl: start,
                eventualMgdl: eventualValue,
                insulinMgdl: insulin,
                carbMgdl: carb,
                momentumMgdl: momentum,
                retrospectiveMgdl: retro,
                residualMgdl: eventualValue - (start + insulin + carb + momentum + retro),
                insulinRawTailMgdl: rawTail,
                insulinExpectedMgdl: nil,
                isfMgdlPerU: nil,
                iobUnits: activeInsulin,
                momentumPointCount: e?.momentum.count ?? 0,
                computedAt: now())
        }()
        SportLog.event("predict", "eventual \(eventual) · min \(minPredicted) · suspendThr \(suspendThr) · net effects: carbs \(net(e?.carbs)), insulin \(net(e?.insulin)), momentum \(net(e?.momentum)), RC \(net(e?.retrospectiveCorrection)) · IOB \(activeInsulin.map { String(format: "%.2f", $0) } ?? "—") · COB \(activeCarbs.map { String(format: "%.0f", $0) } ?? "—") · momPts \(e?.momentum.count ?? 0) · rcDisc \(e?.retrospectiveGlucoseDiscrepancies.count ?? 0) · rec \(rec)")
        SportLog.event("curve", curveSummary(predictedGlucose))
        logPredictionDiffAgainstPhone(effects: e)
    }

    private func logPredictionDiffAgainstPhone(effects e: LoopAlgorithmEffects<StoredCarbEntry>?) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        guard let snap = phonePredictionSnapshotAtGrant else { return }
        let age = now().timeIntervalSince(snap.snapshotAt)
        guard age <= .minutes(20) else { return }

        let mgdl = LoopUnit.milligramsPerDeciliter

        func fwd(_ effects: [GlucoseEffect]?) -> Double? {
            guard let effects else { return nil }
            let forward = effects.filter { $0.startDate >= now() }
            guard let first = forward.first, let last = forward.last else { return nil }
            return last.quantity.doubleValue(for: mgdl) - first.quantity.doubleValue(for: mgdl)
        }
        func col(_ label: String, _ watch: Double?, _ phone: Double) -> String {
            guard let w = watch else { return "\(label) —/\(String(format: "%+.0f", phone))" }
            return String(format: "%@ %+.0f vs %+.0f (Δ%+.0f)", label, w, phone, w - phone)
        }

        let wEventual = predictedGlucose?.last?.quantity.doubleValue(for: mgdl)
        let eventualCol = wEventual.map { String(format: "eventual %.0f vs %.0f (Δ%+.0f)", $0, snap.eventualMgdl, $0 - snap.eventualMgdl) }
            ?? String(format: "eventual —/%.0f", snap.eventualMgdl)
        let iobCol = activeInsulin.map { String(format: "IOB %.2f vs %.2f (Δ%+.2f)", $0, snap.iobUnits, $0 - snap.iobUnits) }
            ?? String(format: "IOB —/%.2f", snap.iobUnits)
        let cobCol = activeCarbs.map { String(format: "COB %.0f vs %.0f", $0, snap.cobGrams) }
            ?? String(format: "COB —/%.0f", snap.cobGrams)

        SportLog.event("predict-diff", String(
            format: "@+%.0fs (watch vs phone@grant) — %@ | %@ · %@ · %@ · %@ | %@ · %@ | momPts %d vs %d · rcDisc %d vs %d",
            age,
            eventualCol,
            col("mom", fwd(e?.momentum), snap.impactMomentumMgdl),
            col("ins", fwd(e?.insulin), snap.impactInsulinMgdl),
            col("carb", fwd(e?.carbs), snap.impactCarbMgdl),
            col("RC", fwd(e?.retrospectiveCorrection), snap.impactRCMgdl),
            iobCol, cobCol,
            e?.momentum.count ?? 0, snap.momentumPointCount,
            e?.retrospectiveGlucoseDiscrepancies.count ?? 0, snap.rcDiscrepancyCount))
    }

    func dumpIOBDecomp(_ label: String, at t: Date) {
        dataAccessQueue.async {
            guard let basal = self.basalRateScheduleApplyingOverrideHistory else {
                SportLog.event("iob-decomp", "@\(label) — no schedule yet")
                return
            }
            let longest = self.doseStore.longestEffectDuration
            let bookDoses = (try? self.runBlocking {
                try await self.doseStore.getNormalizedDoseEntries(start: t.addingTimeInterval(-longest), end: nil)
            }) ?? []
            do {
                let window = (start: bookDoses.map(\.startDate).min() ?? t,
                              end: (bookDoses.map(\.endDate).max() ?? t).addingTimeInterval(InsulinMath.defaultInsulinActivityDuration))
                let basalTimeline = BasalRateSchedule.generateTimeline(
                    schedules: [(date: .distantPast, schedule: basal)],
                    startDate: window.start,
                    endDate: window.end)
                let doses = bookDoses
                    .map { $0.simpleDose(with: self.insulinModel(for: $0.insulinType)) }
                    .annotated(with: basalTimeline)
                let uhr = LoopUnit.internationalUnit.unitDivided(by: .hour)
                let tf = DateFormatter()
                tf.dateFormat = "HH:mm:ss"
                var netSum = 0.0
                var rows: [String] = []
                for d in doses where abs(d.netBasalUnits) > 0.0001 || d.type == .bolus {
                    netSum += d.netBasalUnits
                    let sched = String(format: "%.2f", d.volume / max(d.duration / 3600, .ulpOfOne))
                    let id = "—"

                    let del = String(format: "%.3f", d.volume)
                    rows.append(String(format: "%@ %@..%@ net=%+.3f sched=%@ vol=%@ id=%@",
                                       "\(d.type)", tf.string(from: d.startDate), tf.string(from: d.endDate),
                                       d.netBasalUnits, sched, del, id))
                }
                SportLog.event("iob-decomp", "@\(label) Σnet=\(String(format: "%.3f", netSum))U n=\(rows.count) · " + rows.joined(separator: " | "))
            }
        }
    }

    private func curveSummary(_ predicted: [PredictedGlucoseValue]?) -> String {
        guard let predicted, !predicted.isEmpty else { return "—" }
        let mgdl = LoopUnit.milligramsPerDeciliter
        let t0 = now()
        let fwd = predicted.filter { $0.startDate >= t0 }
        guard let minPoint = (fwd.isEmpty ? predicted : fwd)
            .min(by: { $0.quantity.doubleValue(for: mgdl) < $1.quantity.doubleValue(for: mgdl) }) else { return "—" }
        let minV = Int(minPoint.quantity.doubleValue(for: mgdl).rounded())
        let minOff = Int((minPoint.startDate.timeIntervalSince(t0) / 60).rounded())
        let samples = [0, 30, 60, 90, 120].map { m -> String in
            let mark = t0.addingTimeInterval(.minutes(Double(m)))
            guard let p = predicted.last(where: { $0.startDate <= mark }) ?? predicted.first else { return "—" }
            return "\(Int(p.quantity.doubleValue(for: mgdl).rounded()))"
        }.joined(separator: "→")
        return "min \(minV)@\(minOff)m · t0–120: \(samples)"
    }

    private func runBlocking<T>(_ work: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task {
            do { result = .success(try await work()) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    private func roundedBasalRate(_ unitsPerHour: Double) -> Double {
        guard let supported = pumpManager?.supportedBasalRates, !supported.isEmpty else { return unitsPerHour }
        return supported.enumerated().min(by: {
            abs($0.element - unitsPerHour) < abs($1.element - unitsPerHour)
        })?.element ?? unitsPerHour
    }

    private func fetchAlgorithmInput(at baseTime: Date, recommendationType: DoseRecommendationType) async throws -> StoredDataAlgorithmInput {
        let dosesInputHistory = CarbMath.maximumAbsorptionTimeInterval + InsulinMath.defaultInsulinActivityDuration
        var dosesStart = baseTime.addingTimeInterval(-dosesInputHistory)

        let pumpDataAge = baseTime.timeIntervalSince(doseStore.lastAddedPumpData)
        guard pumpDataAge <= LoopAlgorithm.inputDataRecencyInterval else {
            throw WatchLoopError.missingDataError(String(format: "pumpDataTooOld (%.0f s since the last pump report)", pumpDataAge))
        }

        let doses: [DoseEntry] = try await doseStore.getNormalizedDoseEntries(start: dosesStart, end: baseTime)
            .compactMap { $0.trimmed(to: baseTime) }
        dosesStart = min(dosesStart, doses.map { $0.startDate }.min() ?? dosesStart)
        let dosesEnd = max(baseTime, doses.map { $0.endDate }.max() ?? baseTime)

        let rawBasal = try await settingsProvider.getBasalHistory(startDate: dosesStart, endDate: dosesEnd)
        guard !rawBasal.isEmpty else { throw WatchLoopError.configurationError("basalRateSchedule") }

        let basal: [AbsoluteScheduleValue<Double>] = rawBasal.reduce(into: []) { acc, entry in
            if let last = acc.last, last.value == entry.value, last.endDate == entry.startDate {
                acc[acc.count - 1] = AbsoluteScheduleValue(startDate: last.startDate, endDate: entry.endDate, value: last.value)
            } else {
                acc.append(entry)
            }
        }

        let forecastEndTime = baseTime.addingTimeInterval(InsulinMath.defaultInsulinActivityDuration).dateCeiledToTimeInterval(GlucoseMath.defaultDelta)
        let carbsStart = baseTime.addingTimeInterval(CarbMath.maximumAbsorptionTimeInterval * -1)

        let carbEntries = try await carbStore.getCarbEntries(start: carbsStart, end: forecastEndTime)
            .filter { $0.userCreatedDate ?? $0.startDate < baseTime }

        let carbRatio = try await settingsProvider.getCarbRatioHistory(startDate: carbsStart, endDate: forecastEndTime)
        guard !carbRatio.isEmpty else { throw WatchLoopError.configurationError("carbRatioSchedule") }

        let glucose = try await glucoseStore.getGlucoseSamples(start: carbsStart, end: baseTime)

        let dosesWithModel = doses.map { $0.simpleDose(with: insulinModel(for: $0.insulinType)) }
        let recommendationInsulinModel = insulinModel(for: pumpManager?.status.insulinType)

        let neededSensitivityTimeline = LoopAlgorithm.timelineIntervalForSensitivity(
            doses: dosesWithModel,
            glucoseHistoryStart: glucose.first?.startDate ?? baseTime,
            recommendationEffectInterval: DateInterval(start: baseTime, duration: recommendationInsulinModel.effectDuration)
        )
        let sensitivity = try await settingsProvider.getInsulinSensitivityHistory(
            startDate: neededSensitivityTimeline.start,
            endDate: neededSensitivityTimeline.end
        )
        guard !sensitivity.isEmpty else { throw WatchLoopError.configurationError("insulinSensitivitySchedule") }

        let dosingLimits = try await settingsProvider.getDosingLimits(at: baseTime)
        guard let maxBolus = dosingLimits.maxBolus else { throw WatchLoopError.configurationError("maximumBolus") }
        guard let maxBasalRate = dosingLimits.maxBasalRate else { throw WatchLoopError.configurationError("maximumBasalRatePerHour") }
        guard let suspendThreshold = dosingLimits.suspendThreshold else { throw WatchLoopError.configurationError("suspendThreshold") }

        let overrides = overrideHistory.getOverrideHistory(startDate: neededSensitivityTimeline.start, endDate: forecastEndTime)

        var target: [AbsoluteScheduleValue<ClosedRange<LoopQuantity>>]
        if let activeOverride = scheduleOverride, activeOverride.isActive(at: baseTime) {
            guard let schedule = settings.glucoseTargetRangeSchedule else {
                throw WatchLoopError.configurationError("glucoseTargetRangeSchedule")
            }
            let overridden = activeOverride.effectiveCorrectionRangeDuring(scheduledRange: schedule.quantityRange(at: baseTime))
            target = [AbsoluteScheduleValue(startDate: baseTime, endDate: forecastEndTime, value: overridden)]
        } else {
            target = try await settingsProvider.getTargetRangeHistory(startDate: baseTime, endDate: forecastEndTime)
        }
        guard !target.isEmpty else { throw WatchLoopError.configurationError("glucoseTargetRangeSchedule") }

        return StoredDataAlgorithmInput(
            glucoseHistory: glucose,
            doses: dosesWithModel,
            carbEntries: carbEntries,
            predictionStart: baseTime,
            basal: overrides.applyBasal(over: basal),
            sensitivity: overrides.applySensitivity(over: sensitivity),
            carbRatio: overrides.applyCarbRatio(over: carbRatio),
            target: target,
            suspendThreshold: suspendThreshold,
            maxBolus: maxBolus,
            maxBasalRate: maxBasalRate,
            useIntegralRetrospectiveCorrection: integralRetrospectiveCorrectionEnabled,
            includePositiveVelocityAndRC: true,
            carbAbsorptionModel: .piecewiseLinear,
            recommendationInsulinModel: recommendationInsulinModel,
            recommendationType: recommendationType
        )
    }

    private func updatePredictedGlucoseAndRecommendedDose() -> WatchLoopError? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        let startDate = now()

        guard settings.automaticDosingStrategy == .tempBasalOnly else {
            return .configurationError("automaticDosingStrategy: automaticBolus is not supported on the watch (temps only)")
        }

        let input: StoredDataAlgorithmInput
        do {
            input = try runBlocking { try await self.fetchAlgorithmInput(at: startDate, recommendationType: .tempBasal) }
        } catch let error as WatchLoopError {
            return error
        } catch {
            return .missingDataError(String(describing: error))
        }

        let output = LoopAlgorithm.run(input: input)

        predictedGlucose = output.predictedGlucose
        activeInsulin = output.activeInsulin
        activeCarbs = output.activeCarbs
        lastAlgorithmEffects = output.effects

        switch output.recommendationResult {
        case .failure(let error):
            recommendedAutomaticDose = nil
            SportLog.event("dosemath", "algorithm declined: \(String(describing: error))")
            return .missingDataError(String(describing: error))

        case .success(let recommendation):
            guard var automatic = recommendation.automatic else {
                recommendedAutomaticDose = nil
                self.log.default("No dose recommended.")
                return nil
            }

            var basal = automatic.basalAdjustment
            basal.unitsPerHour = roundedBasalRate(basal.unitsPerHour)
            let scheduledBasalRate = input.basal.closestPrior(to: startDate)?.value ?? 0
            let adjusted = basal.adjustForCurrentDelivery(
                at: startDate,
                neutralBasalRate: scheduledBasalRate,
                currentTempBasal: runningTempBasal(),
                continuationInterval: .minutes(11),
                neutralBasalRateMatchesPump: scheduleOverride == nil
            )

            guard let adjusted else {
                recommendedAutomaticDose = nil
                SportLog.event("dosemath", String(format: "no command needed — pod already at %.2f U/hr", basal.unitsPerHour))
                return nil
            }
            automatic.basalAdjustment = adjusted

            recommendedAutomaticDose = (recommendation: automatic, date: startDate)
            let derivation = algorithmSummary(input: input, output: output, enacting: adjusted)
            SportLog.event("dosemath", derivation)
            return nil
        }
    }

    private func algorithmSummary(input: StoredDataAlgorithmInput,
                                  output: AlgorithmOutput<StoredCarbEntry>,
                                  enacting: TempBasalRecommendation) -> String {
        let mgdl = LoopUnit.milligramsPerDeciliter
        let target = input.target.closestPrior(to: input.predictionStart)?.value
        return String(
            format: "eventual %@ vs target %@ · running %@ · scheduled %.2f · maxBasal %.2f · IOB %.2f · COB %.0f · suspendThr %@ => temp %.2f U/hr x %.0f min",
            output.predictedGlucose.last.map { String(format: "%.0f", $0.quantity.doubleValue(for: mgdl)) } ?? "—",
            target.map { String(format: "%.0f-%.0f", $0.lowerBound.doubleValue(for: mgdl), $0.upperBound.doubleValue(for: mgdl)) } ?? "—",
            runningTempBasal().map { String(format: "%.2f U/hr", $0.unitsPerHour) } ?? "none(scheduled)",
            input.basal.closestPrior(to: input.predictionStart)?.value ?? 0,
            input.maxBasalRate,
            output.activeInsulin ?? 0,
            output.activeCarbs ?? 0,
            input.suspendThreshold?.doubleValue(for: mgdl).description ?? "none",
            enacting.unitsPerHour,
            enacting.duration / 60)
    }

    func updateDisplayState() {
        dataAccessQueue.async {
            self.publishHUDContext()
            self.refreshGlanceData()
        }
    }

    func recommendManualBolus(potentialCarbEntry: NewCarbEntry? = nil,
                              completion: @escaping (Swift.Result<ManualBolusRecommendation, Error>) -> Void) {
        dataAccessQueue.async {
            completion(self.manualBolusRecommendationOnQueue(potentialCarbEntry: potentialCarbEntry))
        }
    }

    private func manualBolusRecommendationOnQueue(potentialCarbEntry: NewCarbEntry? = nil) -> Swift.Result<ManualBolusRecommendation, Error> {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        var result: Swift.Result<ManualBolusRecommendation, Error>!
        let completion: (Swift.Result<ManualBolusRecommendation, Error>) -> Void = { result = $0 }
        do {
                var input = try self.runBlocking {
                    try await self.fetchAlgorithmInput(at: self.now(), recommendationType: .manualBolus)
                }

                if let potentialCarbEntry {
                    input.carbEntries += [StoredCarbEntry(
                        startDate: potentialCarbEntry.startDate,
                        quantity: potentialCarbEntry.quantity,
                        foodType: potentialCarbEntry.foodType,
                        absorptionTime: potentialCarbEntry.absorptionTime)]
                }

                let output = LoopAlgorithm.run(input: input)

                self.predictedGlucose = output.predictedGlucose
                self.activeInsulin = output.activeInsulin
                self.activeCarbs = output.activeCarbs
                self.lastAlgorithmEffects = output.effects

                switch output.recommendationResult {
                case .failure(let error):
                    throw error
                case .success(let recommendation):
                    guard var manual = recommendation.manual else {
                        throw WatchLoopError.missingDataError("no manual bolus recommendation")
                    }

                    if let pump = self.pumpManager {
                        manual.amount = pump.roundToSupportedBolusVolume(units: manual.amount)
                    }
                    completion(.success(manual))
                }
        } catch {
            completion(.failure(error))
        }
        return result
    }

    func enactManualBolus(units: Double, activationType: BolusActivationType, completion: @escaping (Error?) -> Void) {
        dataAccessQueue.async {
            guard let pumpManager = self.pumpManager else {
                DispatchQueue.main.async { completion(WatchLoopError.pumpManagerUnconnected) }
                return
            }
            guard let maxBolus = self.settings.maximumBolus else {
                DispatchQueue.main.async { completion(WatchLoopError.configurationError("maximumBolus")) }
                return
            }
            guard units <= maxBolus + .ulpOfOne else {
                DispatchQueue.main.async { completion(WatchLoopError.configurationError("bolus exceeds therapy maximum")) }
                return
            }
            let rounded = pumpManager.roundToSupportedBolusVolume(units: units)

            let deliverBolus = {
                SportLog.event("loan", String(format: "MANUAL BOLUS %.2f U — enacting on the watch pump", rounded))
                pumpManager.enactBolus(decisionId: nil, units: rounded, activationType: activationType) { error in
                    if let error = error {
                        SportLog.event("loan", "MANUAL BOLUS FAILED — \(String(describing: error))")
                    } else {
                        let acceptedAt = self.now()
                        let deliveryEndsAt = acceptedAt.addingTimeInterval(rounded / 1.5 * 60)
                        SportLog.event("loan", String(format: "MANUAL BOLUS delivering %.2f U — estimated done in %.0fs",
                                                      rounded, deliveryEndsAt.timeIntervalSince(acceptedAt)))

                        self.setManualBolusDelivering(units: rounded, from: acceptedAt, to: deliveryEndsAt)

                        self.loop()
                    }
                    self.setManualBolusInFlight(false)
                    DispatchQueue.main.async { completion(error) }
                }
            }
            self.setManualBolusInFlight(true, units: rounded)

            self.dataAccessQueue.async { deliverBolus() }
        }
    }

    func addLoanCarbEntry(_ entry: NewCarbEntry) {
        carbStore.addCarbEntry(entry) { result in
            switch result {
            case .success(let stored):
                SportLog.event("loan", String(format: "carbs logged locally: %.0f g", stored.quantity.doubleValue(for: .gram)))

                self.loop()
            case .failure(let error):
                SportLog.event("loan", "carb store add FAILED — \(String(describing: error))")
            }
        }
    }

    func deleteLoanCarbEntry(_ entry: StoredCarbEntry, completion: @escaping (Bool) -> Void) {
        let grams = entry.quantity.doubleValue(for: .gram)

        SportLog.event("loan", String(format: "carb delete attempt %.0f g @ %@ · uuid=%@ sync=%@ ver=%@ prov=%@ mine=%@",
                                      grams, ISO8601DateFormatter().string(from: entry.startDate),
                                      entry.uuid == nil ? "nil" : "set",
                                      entry.syncIdentifier.map { String($0.prefix(8)) } ?? "nil",
                                      entry.syncVersion.map(String.init) ?? "nil",
                                      String(entry.provenanceIdentifier.prefix(12)),
                                      entry.createdByCurrentApp ? "y" : "n"))

        carbStore.deleteCarbEntrySkippingAuthorshipCheck(entry) { result, lookupDiag in
            switch result {
            case .success:
                SportLog.event("loan", String(format: "carb DELETED locally: %.0f g · lookup: %@", grams, lookupDiag))
                self.loop()

                let start = min(Calendar.current.startOfDay(for: self.now()),
                                Date(timeIntervalSinceNow: -CarbMath.maximumAbsorptionTimeInterval))
                self.carbStore.getCarbEntries(start: start) { readback in
                    if case .success(let remaining) = readback {
                        let total = remaining.reduce(0.0) { $0 + $1.quantity.doubleValue(for: .gram) }
                        SportLog.event("loan", String(format: "post-delete store: %d entr%@ remain, %.0f g total",
                                                      remaining.count, remaining.count == 1 ? "y" : "ies", total))
                    }
                }
                completion(true)
            case .failure(let error):
                SportLog.event("loan", "carb store delete FAILED — \(String(describing: error)) · lookup: \(lookupDiag)")
                completion(false)
            }
        }
    }

    private func enactRecommendedAutomaticDose() -> WatchLoopError? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let recommendedDose = self.recommendedAutomaticDose else {
            return nil
        }

        guard abs(recommendedDose.date.timeIntervalSince(now())) < TimeInterval(minutes: 5) else {
            return .recommendationExpired(date: recommendedDose.date)
        }

        guard let pumpManager = pumpManager else {
            return .pumpManagerUnconnected
        }

        if case .suspended = pumpManager.status.basalDeliveryState {
            return .pumpSuspended
        }

        guard !pumpManager.status.deliveryIsUncertain else {
            SportLog.event("dose", "enact refused — the pod's last command is unacknowledged (delivery uncertain); the pump manager resolves it on its next session")
            return .enactFailed("delivery uncertain")
        }
        var enactError: WatchLoopError?

        let recommendation = recommendedDose.recommendation

        let temp = recommendation.basalAdjustment
        SportLog.event("dose", String(format: "enacting temp %.2f U/hr × %.0f min", temp.unitsPerHour, temp.duration / 60))
        if let bolus = recommendation.bolusUnits, bolus > 0 {
            SportLog.event("dose", String(format: "enacting bolus %.2f U", bolus))
        }
        do {
            try runBlocking {
                try await self.doseEnactor.enact(decisionId: nil, bolus: recommendation.bolusUnits,
                                                 tempBasal: recommendation.basalAdjustment, with: pumpManager)
            }
            SportLog.event("dose", String(format: "temp %.2f U/hr ACCEPTED by pod", temp.unitsPerHour))
        } catch {
            SportLog.event("dose", "enact FAILED — \(String(describing: error))")
            enactError = .enactFailed(String(describing: error))
        }

        if enactError == nil {
            self.recommendedAutomaticDose = nil
        }

        return enactError
    }
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

extension WatchLoopManager: CGMManagerDelegate {
    func startDateToFilterNewData(for manager: CGMManager) -> Date? {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        return glucoseStore.latestGlucose?.startDate
    }

    func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        log.default("CGMManager:%{public}@ did update with %{public}@", String(describing: type(of: manager)), String(describing: readingResult))
        processCGMReadingResult(manager, readingResult: readingResult) {
            let now = self.now()

            if case .newData = readingResult, now.timeIntervalSince(self.lastCGMLoopTrigger) > .minutes(4.2) {
                self.log.default("Triggering loop from new CGM data at %{public}@", String(describing: now))
                self.lastCGMLoopTrigger = now

                self.checkPumpDataAndLoop()
            }

            if case .newData = readingResult {
                Self.queueLogTransferThrottled()
            }
        }
    }

    var latestGlucoseAge: TimeInterval? {
        return glucoseStore.latestGlucose.map { self.now().timeIntervalSince($0.startDate) }
    }

    private static var lastLogTransfer = Date.distantPast
    static func queueLogTransferThrottled() {
        guard Date().timeIntervalSince(lastLogTransfer) > 4.5 * 60 else { return }
        guard WCSession.default.activationState == .activated, let url = LogFile.url else { return }
        lastLogTransfer = Date()
        WCSession.default.transferFile(url, metadata: ["kind": "g7watch.log"])
    }

    private func processCGMReadingResult(_ manager: CGMManager, readingResult: CGMReadingResult, completion: @escaping () -> Void) {
        switch readingResult {
        case .newData(let rawValues):
            let values = rawValues

            dropAlreadyStored(values) { kept in

            let deliveredCount = values.count
            let latest = kept.max(by: { $0.date < $1.date }) ?? values.max(by: { $0.date < $1.date })
            let latestDesc: String = {
                guard let s = latest else { return "none" }
                let mgdl = Int(s.quantity.doubleValue(for: .milligramsPerDeciliter).rounded())
                return "\(mgdl) mg/dL age \(Int(self.now().timeIntervalSince(s.date)))s"
            }()
            let batchTag = deliveredCount > 1 ? " BATCH(backfill+live)" : ""

            if deliveredCount > 0 { self.noteGlucoseSource(directG7: true) }

            SportLog.event("glucose",
                "INGEST src=direct-G7 kept=\(kept.count)/\(deliveredCount) · latest \(latestDesc)\(batchTag)")
            guard !kept.isEmpty else { completion(); return }
            Task {
                do {
                    _ = try await self.glucoseStore.addGlucoseSamples(kept)

                    if let newest = kept.map(\.date).max(),
                       (self.glucoseStore.latestGlucose?.startDate ?? .distantPast) < newest.addingTimeInterval(-1) {
                        SportLog.event("glucose", "STORE LATEST IS STALE after a write — wrote up to \(newest), store says \(self.glucoseStore.latestGlucose.map { String(describing: $0.startDate) } ?? "nil") [glucose-store]")
                    }
                } catch {
                    self.log.error("Failure adding glucose samples: %{public}@", String(describing: error))
                    SportLog.event("glucose", "STORE WRITE FAILED — \(kept.count) reading(s) NOT written: \(error) [glucose-store]")
                }

                self.dataAccessQueue.async { self.publishOwnGlucoseContextWhenIdle() }
                completion()
            }
            }
        case .unreliableData:

            log.default("CGM reported unreliable data")
            completion()
        case .noData:
            completion()
        case .error(let error):
            log.error("CGM reading error: %{public}@", String(describing: error))
            completion()
        }
    }

    func cgmManager(_ manager: CGMManager, hasNew events: [PersistedCgmEvent]) {
        log.default("CGM event(s): %{public}d", events.count)
    }

    @MainActor
    func ingestPhoneGlucoseFromContext() {
        guard pumpManager != nil else { return }

        guard let ctx = ExtensionDelegate.sharedIfAvailable()?.loopManager.phoneRelayContext,
              let sample = ctx.newGlucoseSample else { return }
        deviceQueue.async {
            if sample.syncIdentifier == self.lastPhoneFallbackSyncId { return }
            self.lastPhoneFallbackSyncId = sample.syncIdentifier

            if let latest = self.glucoseStore.latestGlucose?.startDate, latest >= sample.date { return }
            self.dropAlreadyStored([sample]) { kept in
            guard !kept.isEmpty else { return }
            Task {
                do {
                    _ = try await self.glucoseStore.addGlucoseSamples(kept)
                } catch {
                    self.log.error("phone-BG fallback add failed: %{public}@", String(describing: error))
                    return
                }
                let mgdl = Int(sample.quantity.doubleValue(for: .milligramsPerDeciliter))
                self.noteGlucoseSource(directG7: false)
                SportLog.event("glucose",
                    "INGEST src=phone-relay stored=1/1 · latest \(mgdl) mg/dL age \(Int(self.now().timeIntervalSince(sample.date)))s (direct-G7 gap)")
                SportLog.event("loan", "phone-BG fallback: ingested \(mgdl) mg/dL syncId=\(sample.syncIdentifier ?? "?") (direct-G7 gap) — triggering loop")
                let now = self.now()
                if now.timeIntervalSince(self.lastCGMLoopTrigger) > .minutes(4.2) {
                    self.lastCGMLoopTrigger = now
                    self.checkPumpDataAndLoop()
                }
            }
            }
        }
    }

    private static func sensorIdentity(_ syncIdentifier: String?) -> String? {
        guard let s = syncIdentifier, let sp = s.firstIndex(of: " ") else { return nil }
        let tail = s[s.index(after: sp)...]
        return tail.isEmpty ? nil : String(tail)
    }

    private func dropAlreadyStored(_ samples: [NewGlucoseSample],
                                   completion: @escaping ([NewGlucoseSample]) -> Void) {
        let wanted = samples.compactMap { Self.sensorIdentity($0.syncIdentifier) }
        guard !wanted.isEmpty else { completion(samples); return }

        let since = self.now().addingTimeInterval(-.minutes(30))
        Task {
            guard let stored = try? await glucoseStore.getGlucoseSamples(start: since, end: nil) else {
                completion(samples)
                return
            }
            let seen = Set(stored.compactMap { Self.sensorIdentity($0.syncIdentifier) })
            guard !seen.isEmpty else { completion(samples); return }
            var dropped: [String] = []
            let kept = samples.filter { s in
                guard let id = Self.sensorIdentity(s.syncIdentifier), seen.contains(id) else { return true }
                dropped.append(id)
                return false
            }
            if !dropped.isEmpty {
                SportLog.event("glucose", "#83 dedup: dropped \(dropped.count) already-filed reading(s) [\(dropped.joined(separator: ", "))] — same sensor stamp, different device name tag")
            }
            completion(kept)
        }
    }

    #if targetEnvironment(simulator)

    @MainActor
    func simIngestPhoneGlucose() {
        let ctx = ExtensionDelegate.sharedIfAvailable()?.loopManager.activeContext
        guard let quantity = ctx?.glucose, let date = ctx?.glucoseDate else { return }
        deviceQueue.async {
            if let latest = self.glucoseStore.latestGlucose?.startDate, latest >= date { return }
            let sample = NewGlucoseSample(
                date: date,
                quantity: quantity,
                condition: nil,
                trend: ctx?.glucoseTrend,
                trendRate: ctx?.glucoseTrendRate,
                isDisplayOnly: false,
                wasUserEntered: false,
                syncIdentifier: "sim-\(Int(date.timeIntervalSince1970))")
            Task {
                do {
                    _ = try await self.glucoseStore.addGlucoseSamples([sample])
                } catch {
                    self.log.error("SIM glucose add failed: %{public}@", String(describing: error))
                }

                let now = self.now()
                if now.timeIntervalSince(self.lastCGMLoopTrigger) > .minutes(4.2) {
                    self.lastCGMLoopTrigger = now
                    SportLog.event("sim", "SIM CGM \(Int(quantity.doubleValue(for: .milligramsPerDeciliter))) mg/dL (phone sim) — triggering real loop")
                    self.checkPumpDataAndLoop()
                }
            }
        }
    }
    #endif

    func cgmManagerWantsDeletion(_ manager: CGMManager) {
        log.default("CGM manager requested deletion (ignored on watch)")
    }

    static let cgmStateDefaultsKey = "g7.cgmManagerRawState"

    func cgmManagerDidUpdateState(_ manager: CGMManager) {
        guard manager is G7CGMManager else { return }
        let raw = manager.rawState
        let sensorID = raw["sensorID"] as? String

        if sensorID == nil,
           let stored = defaults.dictionary(forKey: Self.cgmStateDefaultsKey),
           let storedID = stored["sensorID"] as? String {
            let activated = stored["activatedAt"] as? Date
            let expired = Self.persistedSensorIsPastLife(activated, now: now())
            if !expired {
                if lastPersistedSensorID != nil {
                    SportLog.event("cgm", "G7 state: manager forgot sensor \(storedID) — KEEPING the persisted identity (#104: nil means unknown, not forget)")
                    lastPersistedSensorID = nil
                }
                return
            }
            SportLog.event("cgm", "G7 state: sensor \(storedID) is past its 10-day life — honouring the clear")
        }

        defaults.set(raw, forKey: Self.cgmStateDefaultsKey)
        if sensorID != lastPersistedSensorID {
            lastPersistedSensorID = sensorID
            SportLog.event("cgm", "G7 state persisted — sensor \(sensorID ?? "none") (survives relaunch/update)")
        }
    }

    func credentialStoragePrefix(for manager: CGMManager) -> String {
        return "com.loopkit.Loop.WatchLoopManager"
    }

    func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {
        log.default("CGM status did update")
    }

    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        log.default("Device %{public}@: %{public}@", deviceIdentifier ?? "unknown", message)

        let source = manager is G7CGMManager ? "cgm" : "pod-ble"

        let line = "\(type) \(deviceIdentifier ?? "—"): \(message)"
        switch deviceLogThrottle.admit(line, at: now()) {
        case .suppress:
            completion?(nil)
            return
        case .write(let flushing):
            if flushing > 0 {
                SportLog.event(source, "(previous line repeated ×\(flushing) — suppressed)")
            }
        }
        SportLog.event(source, line)
        completion?(nil)
    }

    func issueAlert(_ alert: LoopKit.Alert) {
        log.default("Alert issued: %{public}@", alert.identifier.value)
    }

    func retractAlert(identifier: LoopKit.Alert.Identifier) {
        log.default("Alert retracted: %{public}@", identifier.value)
    }

    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier) async throws -> Bool {
        false
    }

    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] {
        []
    }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] {
        []
    }

    func recordRetractedAlert(_ alert: LoopKit.Alert, at date: Date) {
        log.default("Retracted alert recorded: %{public}@", alert.identifier.value)
    }
}

extension WatchLoopManager: DoseStoreDelegate {
    func scheduledBasalHistory(from start: Date, to end: Date) async throws -> [AbsoluteScheduleValue<Double>] {
        try await settingsProvider.getBasalHistory(startDate: start, endDate: end)
    }

    func doseStoreHasUpdatedPumpEventData(_ doseStore: DoseStore) {
    }
}
