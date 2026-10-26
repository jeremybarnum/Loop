//
//  OrefDosing.swift
//  Loop
//
//  Trio's oref algorithm as a second dosing algorithm, on the phone: the stored choice, the settings
//  screen, and the one call LoopDataManager.loop() makes. The translation to and from oref is shared
//  with the watch, in OrefAdapter.swift; a Sport Mode grant carries the choice to the watch.
//

import Foundation
import SwiftUI
import LoopKit
import LoopCore
import LoopAlgorithm
import Trio

/// The stored algorithm choice and oref settings, and oref's latest decision for the settings screen.
@MainActor
final class OrefStatus: ObservableObject {
    static let shared = OrefStatus()

    @Published var configuration: OrefConfiguration {
        didSet { configuration.save(to: UserDefaults.appGroup ?? .standard) }
    }
    @Published var lastOutput: OrefOutput?

    private init() {
        configuration = OrefConfiguration.load(from: UserDefaults.appGroup ?? .standard)
    }

    /// For a loan grant, which is assembled off the main actor: read straight from the store.
    nonisolated static func loanContext() -> OrefLoanContext {
        OrefLoanContext(configuration: OrefConfiguration.load(from: UserDefaults.appGroup ?? .standard),
                        dailyDoses: OrefAdapter.lastDailyDoses)
    }
}

struct OrefSettingsScreen: View {
    @ObservedObject var status = OrefStatus.shared

    var body: some View {
        OrefSettingsView(configuration: $status.configuration, lastOutput: status.lastOutput)
    }
}

extension DosingAlgorithm {
    var title: String {
        switch self {
        case .loop: return "Loop"
        case .orefShadow: return "Loop, oref alongside"
        case .oref: return "oref (Trio)"
        }
    }
}

extension LoopDataManager {
    /// When oref is chosen, replaces Loop's automatic recommendation in `output` with oref's; when oref runs
    /// alongside, only logs it. Loop's forecast in `output` is kept either way: the screen, the warnings and
    /// the bolus calculator keep using it. If oref fails, the cycle fails rather than falling back to Loop.
    func applyOref(to output: inout AlgorithmOutput<StoredCarbEntry>, input: StoredDataAlgorithmInput, at now: Date) async throws {
        let configuration = OrefStatus.shared.configuration
        guard configuration.algorithm != .loop else { return }

        let currentTemp = deliveryDelegate?.basalDeliveryState?.currentTempBasal
        let orefOutput: OrefOutput
        do {
            let dailyDoses = try await OrefAdapter.dailyDoses(at: now, doseStore: doseStore)
            let orefInput = try await OrefAdapter.input(
                at: now, preferences: configuration.preferences, settings: settingsProvider.settings,
                doseStore: doseStore, carbStore: carbStore, glucoseStore: glucoseStore,
                activeOverride: temporaryPresetsManager.presetHistory.activeOverride(at: now),
                currentTempBasal: currentTemp, insulinType: deliveryDelegate?.pumpInsulinType,
                dailyDoses: dailyDoses)
            orefOutput = try await Task.detached(priority: .userInitiated) { try Oref.determine(orefInput) }.value
        } catch {
            logger.error("oref failed: %{public}@", String(describing: error))
            if configuration.algorithm == .oref { throw error }
            return
        }
        OrefStatus.shared.lastOutput = orefOutput
        logger.default("%{public}@", OrefAdapter.logLine(orefOutput))

        guard configuration.algorithm == .oref else { return }
        guard let scheduledBasal = input.basal.closestPrior(to: now)?.value else {
            throw LoopError.configurationError(.basalRateSchedule)
        }
        let recommendation = OrefAdapter.recommendation(from: orefOutput, scheduledBasal: scheduledBasal,
                                                        currentTempBasal: currentTemp, maxBolus: input.maxBolus)
        output.recommendationResult = .success(.init(automatic: recommendation))
    }
}
