//
//  StatisticsView.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI
import LoopAlgorithm
import LoopUI

/// "How am I doing?" overview — an Ambulatory Glucose Profile report: summary
/// metrics, a time-in-range breakdown, and the 24-hour percentile AGP chart,
/// over a selectable look-back window.
struct StatisticsView: View {
    @StateObject private var viewModel: StatisticsViewModel
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    init(glucoseStore: GlucoseStoreProtocol) {
        _viewModel = StateObject(wrappedValue: StatisticsViewModel(glucoseStore: glucoseStore))
    }

    var body: some View {
        List {
            Section {
                Picker(NSLocalizedString("Range", comment: "Statistics date-range picker label"),
                       selection: $viewModel.selectedRange) {
                    ForEach(StatisticsViewModel.DateRange.allCases) { range in
                        Text("\(range.days)d").tag(range)
                    }
                }
                .pickerStyle(.segmented)
            }

            if let stats = viewModel.statistics, stats.sampleCount > 0 {
                metricsSection(stats)
                timeInRangeSection(stats)
                agpSection(stats)
            } else if viewModel.isLoading {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } else {
                Section {
                    Text(NSLocalizedString("No glucose data for this period.", comment: "Statistics empty state"))
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(Text(NSLocalizedString("Statistics", comment: "Statistics screen title")))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    // MARK: - Sections

    private func metricsSection(_ stats: GlucoseStatistics) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                metric(NSLocalizedString("GMI", comment: "Glucose Management Indicator metric title"),
                       stats.gmi.map { String(format: "%.1f%%", $0) })
                metric(NSLocalizedString("Average", comment: "Average glucose metric title"),
                       stats.averageGlucose.map {
                           displayGlucosePreference.format(LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: $0))
                       })
                metric(NSLocalizedString("CV", comment: "Coefficient of variation metric title"),
                       stats.coefficientOfVariation.map { String(format: "%.0f%%", $0) })
                metric(NSLocalizedString("CGM Active", comment: "Percent of time CGM data present metric title"),
                       String(format: "%.0f%%", stats.percentActive * 100))
            }
            .padding(.vertical, 4)
        }
    }

    private func metric(_ title: String, _ value: String?) -> some View {
        VStack(spacing: 4) {
            Text(value ?? "–")
                .font(.title2.bold().monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func timeInRangeSection(_ stats: GlucoseStatistics) -> some View {
        Section(header: Text(NSLocalizedString("Time in Range", comment: "Time-in-range section header"))) {
            TimeInRangeBar(timeInRange: stats.timeInRange)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func agpSection(_ stats: GlucoseStatistics) -> some View {
        Section(header: Text(NSLocalizedString("Ambulatory Glucose Profile", comment: "AGP section header")),
                footer: Text(NSLocalizedString("Median (line) with 25–75% and 5–95% bands, by time of day.", comment: "AGP chart explanation"))) {
            if stats.agpProfile.isEmpty {
                Text(NSLocalizedString("Not enough data to plot a profile.", comment: "AGP empty state"))
                    .foregroundColor(.secondary)
            } else {
                AGPChartView(profile: stats.agpProfile, unit: displayGlucosePreference.unit)
                    .frame(height: 240)
                    .padding(.vertical, 8)
            }
        }
    }
}

#if DEBUG
/// Generates a daily glucose pattern with day-to-day spread so the AGP bands and
/// metrics populate in the canvas. Deterministic (seeded) so previews are stable.
private final class PreviewGlucoseStore: GlucoseStoreProtocol {
    private let samples: [StoredGlucoseSample]

    init() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func unit01() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        let cal = Calendar.current
        let now = Date()
        let cadence: TimeInterval = 15 * 60
        var t = now.addingTimeInterval(-14 * 24 * 60 * 60)
        var out: [StoredGlucoseSample] = []
        while t < now {
            let hour = t.timeIntervalSince(cal.startOfDay(for: t)) / 3600
            let base = 140.0 + 40 * sin((hour - 4) / 24 * 2 * .pi)
            let value = max(45, base + (unit01() - 0.5) * 70)
            out.append(StoredGlucoseSample(startDate: t, quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: value)))
            t = t.addingTimeInterval(cadence)
        }
        samples = out
    }

    var latestGlucose: GlucoseSampleValue? { samples.last }

    func getGlucoseSamples(start: Date?, end: Date?) async throws -> [StoredGlucoseSample] {
        samples.filter { (start == nil || $0.startDate >= start!) && (end == nil || $0.startDate < end!) }
    }

    func addGlucoseSamples(_ samples: [NewGlucoseSample]) async throws -> [StoredGlucoseSample] { [] }
}

#Preview {
    NavigationView {
        StatisticsView(glucoseStore: PreviewGlucoseStore())
            .environmentObject(DisplayGlucosePreference(displayGlucoseUnit: .milligramsPerDeciliter))
    }
}
#endif
