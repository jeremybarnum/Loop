//
//  AGPChartView.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import Charts
import LoopKit
import LoopAlgorithm
import LoopUI

/// The ambulatory glucose profile: percentile bands (5–95 and 25–75) and the
/// median, plotted across a single 24-hour day. Glucose values are converted to
/// the user's display unit for plotting.
struct AGPChartView: View {
    let profile: [AGPBand]
    let unit: LoopUnit
    /// Target range boundaries in mg/dL (consensus 70–180).
    var targetLowMgDL: Double = 70
    var targetHighMgDL: Double = 180

    private func display(_ mgdl: Double) -> Double {
        LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl).doubleValue(for: unit)
    }

    private func hours(_ band: AGPBand) -> Double { band.timeOfDay / 3600 }

    var body: some View {
        Chart {
            // Target range boundaries.
            RuleMark(y: .value("Target low", display(targetLowMgDL)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.glucoseNormal.opacity(0.6))
            RuleMark(y: .value("Target high", display(targetHighMgDL)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.glucoseNormal.opacity(0.6))

            ForEach(profile, id: \.timeOfDay) { band in
                // Outer band: 5th–95th percentile.
                AreaMark(
                    x: .value("Time", hours(band)),
                    yStart: .value("5th", display(band.p05)),
                    yEnd: .value("95th", display(band.p95))
                )
                .foregroundStyle(Color.glucose.opacity(0.15))
                .interpolationMethod(.monotone)

                // Inner band: 25th–75th percentile.
                AreaMark(
                    x: .value("Time", hours(band)),
                    yStart: .value("25th", display(band.p25)),
                    yEnd: .value("75th", display(band.p75))
                )
                .foregroundStyle(Color.glucose.opacity(0.3))
                .interpolationMethod(.monotone)
            }

            // Median line.
            ForEach(profile, id: \.timeOfDay) { band in
                LineMark(
                    x: .value("Time", hours(band)),
                    y: .value("Median", display(band.p50))
                )
                .foregroundStyle(Color.glucose)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...24)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let hour = value.as(Double.self) {
                        Text(hourLabel(Int(hour)))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .accessibilityLabel(Text(NSLocalizedString("Ambulatory glucose profile", comment: "Accessibility label for the AGP chart")))
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0, 24: return "12a"
        case 12:    return "12p"
        case ..<12: return "\(hour)a"
        default:    return "\(hour - 12)p"
        }
    }
}
