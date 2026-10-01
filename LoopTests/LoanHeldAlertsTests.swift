//
//  LoanHeldAlertsTests.swift
//  LoopTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  While the watch holds the pod, the phone's predicted low and missed-meal checks wait: the
//  watch's doses and carbs reach the phone's stores only at hand-back. Outside a loan, stock.
//

import XCTest
import LoopKit
import LoopAlgorithm
@testable import Loop

@MainActor
final class LoanHeldAlertsTests: XCTestCase {

    private final class RecordingIssuer: AlertIssuer {
        var issued: [Alert.AlertIdentifier] = []
        func issueAlert(_ alert: Alert) async { issued.append(alert.identifier.alertIdentifier) }
        func retractAlert(identifier: Alert.Identifier) async {}
    }

    private final class CountingAlgorithmState: AlgorithmDisplayStateProvider {
        var reads = 0
        var algorithmState: AlgorithmDisplayState {
            get async { reads += 1; return AlgorithmDisplayState() }
        }
    }

    private struct NoSettings: SettingsWithOverridesProvider {
        var insulinSensitivityScheduleApplyingOverrideHistory: InsulinSensitivitySchedule? { nil }
        var carbRatioSchedule: CarbRatioSchedule? { nil }
        var maximumBolus: Double? { nil }
    }

    private struct NoBolus: BolusStateProvider {
        var bolusState: PumpManagerStatus.BolusState? { nil }
    }

    private var loanActive = false
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        loanActive = false
        suiteName = "LoanHeldAlertsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    /// Falls through the predicted-low threshold (60) inside the 20-minute horizon.
    private func fallingForecast(from now: Date) -> [PredictedGlucoseValue] {
        (0...6).map { i in
            PredictedGlucoseValue(startDate: now.addingTimeInterval(Double(i) * 5 * 60),
                                  quantity: .glucose(value: 120 - Double(i) * 20))
        }
    }

    func testThePhonesPredictedLowWaitsForTheLoanToEnd() async {
        let issuer = RecordingIssuer()
        let manager = GlucoseAlertManager(alertIssuer: issuer, userDefaults: defaults)
        manager.predictedLowSuppressionGate = { [unowned self] in self.loanActive }

        loanActive = true
        let now = Date()
        await manager.evaluatePredictedGlucose(fallingForecast(from: now), now: now)
        XCTAssertTrue(issuer.issued.isEmpty, "the forecast leaves out the watch's insulin; the wrist runs its own")

        loanActive = false
        let later = now.addingTimeInterval(5 * 60)
        await manager.evaluatePredictedGlucose(fallingForecast(from: later), now: later)
        XCTAssertEqual(issuer.issued, [GlucoseAlertManager.predictedLowAlertIdentifier],
                       "back with the phone, stock fires as before — nothing was spent during the loan")
    }

    func testMissedMealDetectionDoesNotRunDuringALoan() async {
        let state = CountingAlgorithmState()
        let manager = MealDetectionManager(algorithmStateProvider: state, settingsProvider: NoSettings(),
                                           bolusStateProvider: NoBolus())
        manager.loanSuppressionGate = { [unowned self] in self.loanActive }

        loanActive = true
        await manager.run()
        XCTAssertEqual(state.reads, 0, "carbs logged on the wrist are not in the phone's store yet")

        loanActive = false
        await manager.run()
        XCTAssertEqual(state.reads, 1, "outside a loan detection runs as stock")
    }
}
