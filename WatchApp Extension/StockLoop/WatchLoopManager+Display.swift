//
//  WatchLoopManager+Display.swift
//  WatchApp Extension
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import G7SensorKit
import WatchConnectivity
import os.log

extension WatchLoopManager {

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

    func glanceData() -> GlanceData {
        return dataAccessQueue.sync { self.buildGlanceData() }
    }

    func buildGlanceData() -> GlanceData {
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

    func publishOwnGlucoseContextWhenIdle() {
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

    func publishHUDContext() {
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
}
