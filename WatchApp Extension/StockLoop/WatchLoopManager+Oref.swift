//
//  WatchLoopManager+Oref.swift
//  WatchApp Extension
//
//  The phone's dosing-algorithm choice on the watch during a loan. The grant carries it
//  (`LoanGrant.orefContext`); without it, or from a phone that never set it, the watch doses with
//  Loop's algorithm as before. The translation to and from oref is shared with the phone (OrefAdapter).
//

import Foundation
import LoopKit
import LoopAlgorithm
import LoopCore
import Trio

extension WatchLoopManager {

    /// From the grant, ahead of the first cycle; saved so a resumed loan doses the same way.
    func setOrefContext(_ data: Data?) {
        updateLoopState { $0.orefContext = data }
        let context = Self.decodeOrefContext(data)
        dataAccessQueue.async {
            self.orefContext = context
            SportLog.event("loan", "dosing algorithm: \(context?.configuration.algorithm.rawValue ?? "loop") (from grant)")
        }
    }

    static func decodeOrefContext(_ data: Data?) -> OrefLoanContext? {
        data.flatMap { try? JSONDecoder().decode(OrefLoanContext.self, from: $0) }
    }

    /// The phone's `LoopDataManager.applyOref`, on `dataAccessQueue`: oref replaces Loop's automatic
    /// recommendation when chosen, is only logged when alongside, and fails the cycle if it fails.
    func applyOref(to output: inout AlgorithmOutput<StoredCarbEntry>, input: StoredDataAlgorithmInput, at now: Date) throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        guard let context = orefContext, context.configuration.algorithm != .loop else { return }

        let currentTemp = pumpManager?.status.basalDeliveryState?.currentTempBasal
        let orefOutput: OrefOutput
        do {
            let orefInput = try runBlocking {
                try await OrefAdapter.input(
                    at: now, preferences: context.configuration.preferences, settings: self.settingsProvider.settings,
                    doseStore: self.doseStore, carbStore: self.carbStore, glucoseStore: self.glucoseStore,
                    activeOverride: self.scheduleOverride.flatMap { $0.isActive(at: now) ? $0 : nil },
                    currentTempBasal: currentTemp, insulinType: self.pumpManager?.status.insulinType,
                    // The watch holds too little dose history for daily totals: the phone's, from the grant.
                    dailyDoses: context.dailyDoses)
            }
            orefOutput = try Oref.determine(orefInput)
        } catch {
            SportLog.event("oref", "failed: \(error)")
            if context.configuration.algorithm == .oref { throw error }
            return
        }
        SportLog.event("oref", OrefAdapter.logLine(orefOutput))

        guard context.configuration.algorithm == .oref else { return }
        guard let scheduledBasal = input.basal.closestPrior(to: now)?.value else {
            throw LoopError.configurationError(.basalRateSchedule)
        }
        let recommendation = OrefAdapter.recommendation(from: orefOutput, scheduledBasal: scheduledBasal,
                                                        currentTempBasal: currentTemp, maxBolus: input.maxBolus)
        output.recommendationResult = .success(.init(automatic: recommendation))
    }
}
