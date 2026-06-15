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

/// The ambulatory glucose profile, styled after the IDC / captūrAGP report:
/// glucose ranges are colored as horizontal zones (green target, gold high,
/// orange very-high, red lows), but the color shows only *inside* the 5–95%
/// percentile band, with the 25–75% inter-quartile band rendered more strongly
/// and the median as a bold line. Glucose is plotted in the user's display unit.
struct AGPChartView: View {
    let profile: [AGPBand]
    let unit: LoopUnit
    var targetLowMgDL: Double = 70
    var targetHighMgDL: Double = 180

    private struct Zone: Identifiable {
        let lo: Double, hi: Double, band: GlucoseBand
        var id: Double { lo }
    }

    // Horizontal zones (mg/dL) drawn as the colored background, top clamped to 350+.
    private var topMgDL: Double { max(350, (profile.map { $0.p95 }.max() ?? 350).rounded(.up)) }
    private var zones: [Zone] {
        [Zone(lo: 0, hi: 54, band: .veryLow),
         Zone(lo: 54, hi: 70, band: .low),
         Zone(lo: 70, hi: 180, band: .target),
         Zone(lo: 180, hi: 250, band: .high),
         Zone(lo: 250, hi: topMgDL, band: .veryHigh)]
    }

    private func display(_ mgdl: Double) -> Double {
        LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl).doubleValue(for: unit)
    }
    private func hours(_ band: AGPBand) -> Double { band.timeOfDay / 3600 }

    // Matches the plot background so masked regions blend seamlessly in light/dark mode.
    private var maskColor: Color { Color(.secondarySystemGroupedBackground) }

    var body: some View {
        Chart {
            // 1. Colored glucose zones across the full width.
            ForEach(zones) { zone in
                RectangleMark(
                    xStart: .value("Start", 0), xEnd: .value("End", 24),
                    yStart: .value("Low", display(zone.lo)), yEnd: .value("High", display(zone.hi))
                )
                .foregroundStyle(zone.band.agpColor.opacity(0.9))
            }

            // 2. Mask the zones outside the 5–95% band (above p95, below p05).
            ForEach(profile, id: \.timeOfDay) { b in
                AreaMark(x: .value("Time", hours(b)), yStart: .value("p95", display(b.p95)), yEnd: .value("Top", display(topMgDL)))
                    .foregroundStyle(maskColor)
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("Time", hours(b)), yStart: .value("Bottom", 0), yEnd: .value("p05", display(b.p05)))
                    .foregroundStyle(maskColor)
                    .interpolationMethod(.monotone)
            }

            // 3. Lighten the outer wings so the 25–75% inter-quartile band reads stronger.
            ForEach(profile, id: \.timeOfDay) { b in
                AreaMark(x: .value("Time", hours(b)), yStart: .value("p75", display(b.p75)), yEnd: .value("p95", display(b.p95)))
                    .foregroundStyle(maskColor.opacity(0.5))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("Time", hours(b)), yStart: .value("p05", display(b.p05)), yEnd: .value("p25", display(b.p25)))
                    .foregroundStyle(maskColor.opacity(0.5))
                    .interpolationMethod(.monotone)
            }

            // 4. Target-range boundaries.
            ForEach([targetLowMgDL, targetHighMgDL], id: \.self) { y in
                RuleMark(y: .value("Target", display(y)))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(GlucoseBand.target.agpColor)
            }

            // 5. Median.
            ForEach(profile, id: \.timeOfDay) { b in
                LineMark(x: .value("Time", hours(b)), y: .value("Median", display(b.p50)))
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .foregroundStyle(Color(red: 0.16, green: 0.40, blue: 0.20))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: 0...display(topMgDL))
        .chartPlotStyle { $0.background(maskColor) }
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisGridLine()
                AxisValueLabel { if let h = value.as(Double.self) { Text(hourLabel(Int(h))) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [54, 70, 180, 250, topMgDL].map { display($0) }) { value in
                AxisGridLine()
                AxisValueLabel()
            }
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

#if DEBUG
#Preview {
    let bands: [AGPBand] = (0..<48).map { i in
        let hour = Double(i) * 0.5
        let base = 150.0 + 55 * sin((hour - 4) / 24 * 2 * .pi)
        let spread = 25 + 18 * (1 + sin((hour - 8) / 24 * 2 * .pi))
        return AGPBand(
            timeOfDay: (Double(i) + 0.5) * 1800,
            p05: max(45, base - spread * 1.8), p25: base - spread * 0.7,
            p50: base, p75: base + spread * 0.8, p95: base + spread * 1.9
        )
    }
    return AGPChartView(profile: bands, unit: .milligramsPerDeciliter)
        .frame(height: 260)
        .padding()
}
#endif
