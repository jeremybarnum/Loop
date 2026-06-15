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
/// the percentile bands are painted with the glucose-zone colors (green target,
/// gold high, orange very-high, red lows) — but only *within* the band — by
/// clipping each band to each zone. The 25–75% inter-quartile band sits on top
/// of the 5–95% band so it reads more strongly, with a bold median line and
/// green target-range boundaries. Glucose is plotted in the user's display unit.
struct AGPChartView: View {
    let profile: [AGPBand]
    let unit: LoopUnit
    var targetLowMgDL: Double = 70
    var targetHighMgDL: Double = 180

    private struct Zone { let lo: Double, hi: Double, band: GlucoseBand }

    // Top of the y-axis (mg/dL), clamped to at least the standard 350.
    private var topMgDL: Double { max(350, (profile.map { $0.p95 }.max() ?? 350).rounded(.up)) }
    private var zones: [Zone] {
        [Zone(lo: 0, hi: 54, band: .veryLow),
         Zone(lo: 54, hi: 70, band: .low),
         Zone(lo: 70, hi: 180, band: .target),
         Zone(lo: 180, hi: 250, band: .high),
         Zone(lo: 250, hi: topMgDL, band: .veryHigh)]
    }

    /// One band-slice for a single time bucket clipped to a single glucose zone.
    private struct Slice: Identifiable {
        let id: String
        let hour: Double
        let lo: Double     // display unit
        let hi: Double     // display unit
        let series: String
    }

    private func display(_ mgdl: Double) -> Double {
        LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl).doubleValue(for: unit)
    }
    private func clip(_ v: Double, _ z: Zone) -> Double { min(max(v, z.lo), z.hi) }

    /// Series names and their colors: each zone contributes a light "outer"
    /// (5–95%) series and a stronger "inner" (25–75%) series.
    private var seriesDomain: [String] { zones.flatMap { ["\($0.band.rawValue)-o", "\($0.band.rawValue)-i"] } }
    private var seriesRange: [Color] { zones.flatMap { [$0.band.agpColor.opacity(0.35), $0.band.agpColor.opacity(0.7)] } }

    private var slices: [Slice] {
        var out: [Slice] = []
        for z in zones {
            for b in profile {
                let hour = b.timeOfDay / 3600
                out.append(Slice(id: "\(z.band.rawValue)-o-\(b.timeOfDay)", hour: hour,
                                 lo: display(clip(b.p05, z)), hi: display(clip(b.p95, z)),
                                 series: "\(z.band.rawValue)-o"))
                out.append(Slice(id: "\(z.band.rawValue)-i-\(b.timeOfDay)", hour: hour,
                                 lo: display(clip(b.p25, z)), hi: display(clip(b.p75, z)),
                                 series: "\(z.band.rawValue)-i"))
            }
        }
        return out
    }

    var body: some View {
        Chart {
            // Percentile bands, painted per-zone so color appears only inside the band.
            ForEach(slices) { slice in
                AreaMark(
                    x: .value("Time", slice.hour),
                    yStart: .value("Low", slice.lo),
                    yEnd: .value("High", slice.hi)
                )
                .foregroundStyle(by: .value("Series", slice.series))
                .interpolationMethod(.monotone)
            }

            // Target-range boundaries.
            ForEach([targetLowMgDL, targetHighMgDL], id: \.self) { y in
                RuleMark(y: .value("Target", display(y)))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(GlucoseBand.target.agpColor)
            }

            // Median.
            ForEach(profile, id: \.timeOfDay) { b in
                LineMark(x: .value("Time", b.timeOfDay / 3600), y: .value("Median", display(b.p50)))
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .foregroundStyle(Color(red: 0.16, green: 0.40, blue: 0.20))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(domain: seriesDomain, range: seriesRange)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...24)
        .chartYScale(domain: 0...display(topMgDL))
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisGridLine()
                AxisValueLabel { if let h = value.as(Double.self) { Text(hourLabel(Int(h))) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [54, 70, 180, 250, topMgDL].map { display($0) }) { _ in
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
