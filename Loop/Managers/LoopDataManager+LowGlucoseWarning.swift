//
//  LoopDataManager+LowGlucoseWarning.swift
//  Loop
//
//  The predicted-low warning on the phone: after every cycle, from the display run that ends it.
//  The decision and the delivery are shared with the watch (LoopCore/LowGlucoseWarning). While the
//  watch holds the pod the phone stands down: its books lack the watch's doses, so a warning computed
//  here would be wrong in both directions.
//

import Foundation
import LoopKit
import LoopCore
import LoopAlgorithm

extension LoopDataManager {
    func evaluateLowGlucoseWarning() async {
        guard let alerter = lowGlucoseWarningAlerter else { return }
        let settings = UserDefaults.standard.lowBGWarningSettings
        guard settings.enabled, !lowGlucoseWarningStandsDown() else {
            await alerter.standDown()
            return
        }
        guard let input = displayState.input, let output = displayState.output else { return }

        let now = input.predictionStart
        let scheduledBasal = (try? await settingsProvider.getBasalHistory(
            startDate: now, endDate: now.addingTimeInterval(input.recommendationInsulinModel.effectDuration))) ?? []
        let assessment = LowGlucoseWarning.assess(
            input: input, output: output,
            lastPumpDataDate: doseStore.lastAddedPumpData,
            scheduledBasal: scheduledBasal,
            now: now,
            settings: alerter.settingsForDecision(settings)) { self.logger.default("low BG warning: %{public}@", $0) }
        await alerter.handle(assessment, now: now) { self.logger.default("low BG warning: %{public}@", $0) }
    }
}
