//
//  PredictionView.swift
//  WatchApp Extension
//
//  Manual-BG prediction screen: dial in a glucose with the crown, run the
//  Loop algorithm on-watch (WatchPredictionEngine), and see eventual BG, the
//  correction range, and the temp-basal recommendation. Display/recommend
//  only — nothing here doses.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import HealthKit
import LoopKit

struct PredictionView: View {
    let engine: WatchPredictionEngine
    let unit: HKUnit

    @State private var bgValue: Double
    @State private var output: WatchPredictionOutput?
    @State private var errorText: String?
    @State private var busy = false

    init(engine: WatchPredictionEngine, unit: HKUnit) {
        self.engine = engine
        self.unit = unit
        _bgValue = State(initialValue: unit == .milligramsPerDeciliter ? 120 : 6.7)
    }

    private var isMgdl: Bool { unit == .milligramsPerDeciliter }
    private var crownStep: Double { isMgdl ? 1 : 0.1 }
    private var crownRange: ClosedRange<Double> { isMgdl ? 40...400 : 2.2...22.2 }

    private func format(_ quantity: HKQuantity) -> String {
        let value = quantity.doubleValue(for: unit)
        return isMgdl ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Current BG")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(isMgdl ? String(format: "%.0f", bgValue) : String(format: "%.1f", bgValue))
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .foregroundColor(.accentColor)
                    .focusable(true)
                    .digitalCrownRotation(
                        $bgValue,
                        from: crownRange.lowerBound,
                        through: crownRange.upperBound,
                        by: crownStep,
                        sensitivity: .medium,
                        isContinuous: false,
                        isHapticFeedbackEnabled: true)
                Text(unit.shortLocalizedUnitString())
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Button(action: runPrediction) {
                    if busy {
                        ProgressView()
                    } else {
                        Label("Predict", systemImage: "chart.line.uptrend.xyaxis")
                    }
                }
                .disabled(busy)

                if let errorText {
                    Text(errorText)
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let output {
                    resultSection(output)
                }
            }
        }
        .navigationTitle("Predict")
    }

    @ViewBuilder
    private func resultSection(_ output: WatchPredictionOutput) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()

            row("Eventual BG", "\(format(output.eventualBG)) \(unit.shortLocalizedUnitString())")
            row("Range", "\(format(output.correctionRange.lowerBound))–\(format(output.correctionRange.upperBound))")

            if let temp = output.recommendedTempBasal {
                row("Temp basal", String(format: "%.2f U/hr", temp.unitsPerHour))
                row("Duration", String(format: "%.0f min", temp.duration.minutes))
            } else {
                row("Temp basal", String(format: "none — schedule %.2f U/hr fits", output.scheduledBasalRate))
            }

            if !output.usedPreLoanHistory {
                Text("⚠️ No pre-session insulin history — IOB may be understated.")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            Text("Recommendation only — nothing is dosed from this screen.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Text("Inputs: \(output.inputDoseCount) doses, \(output.inputCarbCount) carbs")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
        }
    }

    private func runPrediction() {
        busy = true
        errorText = nil
        let quantity = HKQuantity(unit: unit, doubleValue: bgValue)
        engine.predict(manualBG: quantity) { result in
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let prediction):
                    output = prediction
                case .failure(let error):
                    output = nil
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
