//
//  WatchLoopManager+LowGlucoseWarning.swift
//  WatchApp Extension
//
//  The predicted-low warning on the watch during a loan: the watch holds the pod, so it owns the
//  warning (the phone stands down). Same decision and delivery as the phone (LoopCore/LowGlucoseWarning),
//  with the phone's settings from the grant, after the watch's own display run.
//

import Foundation
import LoopKit
import LoopCore
import LoopAlgorithm

extension WatchLoopManager {

    /// From the grant, ahead of the first cycle; saved so a resumed loan warns the same way. The phone's
    /// last warning time moves the watch's snooze anchor forward.
    func setLowBGWarningSettings(_ settings: LowBGWarningSettings?) {
        updateLoopState { $0.lowBGWarningSettings = settings.flatMap { try? JSONEncoder().encode($0) } }
        defaults.adoptLowBGWarningLastNotificationTime(settings?.lastNotificationTime)
        dataAccessQueue.async {
            self.lowBGWarningSettings = settings
            SportLog.event("loan", "predicted-low warning: \(settings?.enabled == true ? "ON" : "off") (from grant)")
        }
    }

    static func decodeLowBGWarningSettings(_ data: Data?) -> LowBGWarningSettings? {
        data.flatMap { try? JSONDecoder().decode(LowBGWarningSettings.self, from: $0) }
    }

    /// After the display run that ends a cycle, on `dataAccessQueue`. Off, or no pod held: stand down.
    func evaluateLowGlucoseWarning() {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        guard let settings = lowBGWarningSettings, settings.enabled, pumpManager != nil,
              let input = displayState.input, let output = displayState.output else {
            Task { @MainActor in await self.lowGlucoseWarningAlerter.standDown() }
            return
        }
        let now = input.predictionStart
        let scheduledBasal = (try? runBlocking {
            try await self.settingsProvider.getBasalHistory(
                startDate: now, endDate: now.addingTimeInterval(input.recommendationInsulinModel.effectDuration))
        }) ?? []
        let lastPumpData = doseStore.lastAddedPumpData
        Task { @MainActor in
            let alerter = self.lowGlucoseWarningAlerter
            let assessment = LowGlucoseWarning.assess(
                input: input, output: output, lastPumpDataDate: lastPumpData, scheduledBasal: scheduledBasal,
                now: now, settings: alerter.settingsForDecision(settings)) { SportLog.event("lowbg", $0) }
            await alerter.handle(assessment, now: now) { SportLog.event("lowbg", $0) }
        }
    }
}
