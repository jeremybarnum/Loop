//
//  PredictionView.swift
//  WatchApp Extension
//
//  A2 split (docs/WATCH_STANDALONE_UI_AUTOLOOP.md):
//  - BGEntryView: tap the BG number → dial a reading → Log. Stores the entry,
//    runs the cycle, shows the checkmark, gets out of the way — results land
//    on the HUD rows. The rider's whole interaction is dial-and-confirm.
//  - PredictionDetailView: tap Eventual → the read-only rich readout
//    (eventual, range, IOB/COB, temp recommendation, inputs) for
//    cross-checking and debugging. Doses nothing, stores nothing.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import HealthKit
import LoopKit

// MARK: - Entry

struct BGEntryView: View {
    let engine: WatchPredictionEngine
    let unit: HKUnit
    var onFinish: () -> Void = {}

    @State private var bgValue: Double
    @State private var seeded = false
    @State private var seedCaption: String?
    @State private var busy = false
    @State private var done = false
    @State private var errorText: String?

    init(engine: WatchPredictionEngine, unit: HKUnit, onFinish: @escaping () -> Void = {}) {
        self.engine = engine
        self.unit = unit
        self.onFinish = onFinish
        _bgValue = State(initialValue: unit == .milligramsPerDeciliter ? 120 : 6.7)
    }

    private var isMgdl: Bool { unit == .milligramsPerDeciliter }
    private var crownStep: Double { isMgdl ? 1 : 0.1 }
    private var crownRange: ClosedRange<Double> { isMgdl ? 40...400 : 2.2...22.2 }

    var body: some View {
        VStack(spacing: 6) {
            if done {
                CompletionCheckmark(checkmarkColor: .turf, circleStrokeColor: .turf)
                    .frame(width: 44, height: 44)
                Text("Logged")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(isMgdl ? String(format: "%.0f", bgValue) : String(format: "%.1f", bgValue))
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .foregroundColor(.turf)
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

                if let seedCaption {
                    Text(seedCaption)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if let errorText {
                    Text(errorText)
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                ActionButton(
                    title: busy ? Text("Logging…", comment: "BG entry button while running") : Text("Log", comment: "BG entry button"),
                    color: .turf,
                    action: log
                )
                .disabled(busy)
            }
        }
        .onAppear(perform: seedFromLatestGlucose)
    }

    private func log() {
        busy = true
        errorText = nil
        engine.predict(manualBG: HKQuantity(unit: unit, doubleValue: bgValue)) { result in
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success:
                    done = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onFinish() }
                case .failure(let error):
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func seedFromLatestGlucose() {
        guard !seeded else { return }
        engine.latestGlucose { sample in
            guard !seeded, let sample else { return }
            seeded = true
            bgValue = (sample.quantity.doubleValue(for: unit) / crownStep).rounded() * crownStep
            let minutes = Int(-sample.startDate.timeIntervalSinceNow / 60)
            seedCaption = minutes < 1
                ? NSLocalizedString("last reading, just now", comment: "Prediction BG seed caption (fresh)")
                : String(format: NSLocalizedString("last reading, %d min ago", comment: "Prediction BG seed caption (aged)"), minutes)
        }
    }
}

// MARK: - Detail

struct PredictionDetailView: View {
    let engine: WatchPredictionEngine
    let unit: HKUnit

    @State private var output: WatchPredictionOutput?
    @State private var errorText: String?

    private var isMgdl: Bool { unit == .milligramsPerDeciliter }

    private func format(_ quantity: HKQuantity) -> String {
        let value = quantity.doubleValue(for: unit)
        return isMgdl ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let errorText {
                    Text(errorText)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                if let output {
                    row("Glucose", "\(format(output.currentBG)) \(unit.shortLocalizedUnitString())")
                    row("Eventual", format(output.eventualBG))
                    row("Range", "\(format(output.correctionRange.lowerBound))–\(format(output.correctionRange.upperBound))")

                    Divider()

                    row("Active Insulin", String(format: "%.2f U", output.activeInsulin))
                    row("Active Carbs", String(format: "%.0f g", output.activeCarbs))

                    Divider()

                    if let temp = output.recommendedTempBasal {
                        row("Temp Basal", String(format: "%.2f U/hr", temp.unitsPerHour))
                        row("Duration", String(format: "%.0f min", temp.duration.minutes))
                    } else {
                        row("Temp Basal", String(format: NSLocalizedString("none — %.2f fits", comment: "Prediction detail: schedule fits, with rate"), output.scheduledBasalRate))
                    }

                    if !output.usedPreLoanHistory {
                        Text("⚠️ No pre-session insulin history — IOB may be understated.")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }

                    Text("Inputs: \(output.inputDoseCount) doses, \(output.inputCarbCount) carbs")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Prediction")
        .onAppear(perform: refresh)
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

    /// Read-only: anchors on the newest stored sample, never fabricates one.
    private func refresh() {
        engine.latestGlucose { sample in
            guard let sample else {
                errorText = NSLocalizedString("No glucose yet — log a reading first.", comment: "Prediction detail with empty store")
                return
            }
            engine.predict(manualBG: sample.quantity, storeEntry: false) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let fresh): output = fresh
                    case .failure(let error): errorText = error.localizedDescription
                    }
                }
            }
        }
    }
}
