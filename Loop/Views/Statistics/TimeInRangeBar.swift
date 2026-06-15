//
//  TimeInRangeBar.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopUI

/// A horizontal stacked bar showing the fraction of time spent in each glucose
/// band, plus a legend with the percentages.
struct TimeInRangeBar: View {
    let timeInRange: [GlucoseBand: Double]

    // Display order, bottom band first (left to right).
    private static let order: [GlucoseBand] = [.veryLow, .low, .target, .high, .veryHigh]

    private static func color(for band: GlucoseBand) -> Color {
        switch band {
        case .veryLow:  return .glucoseVeryLow
        case .low:      return .glucoseLow
        case .target:   return .glucoseNormal
        case .high:     return .glucoseHigh
        case .veryHigh: return .glucoseVeryHigh
        }
    }

    private static func label(for band: GlucoseBand) -> String {
        switch band {
        case .veryLow:  return NSLocalizedString("Very Low", comment: "Time-in-range band label (<54 mg/dL)")
        case .low:      return NSLocalizedString("Low", comment: "Time-in-range band label (54–69 mg/dL)")
        case .target:   return NSLocalizedString("In Range", comment: "Time-in-range band label (70–180 mg/dL)")
        case .high:     return NSLocalizedString("High", comment: "Time-in-range band label (181–250 mg/dL)")
        case .veryHigh: return NSLocalizedString("Very High", comment: "Time-in-range band label (>250 mg/dL)")
        }
    }

    private func percent(_ band: GlucoseBand) -> Int {
        Int((timeInRange[band] ?? 0) * 100 + 0.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Self.order, id: \.self) { band in
                        let fraction = timeInRange[band] ?? 0
                        Self.color(for: band)
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: 24)

            // Legend, most-clinically-relevant first.
            VStack(alignment: .leading, spacing: 4) {
                ForEach([GlucoseBand.target, .high, .veryHigh, .low, .veryLow], id: \.self) { band in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.color(for: band))
                            .frame(width: 12, height: 12)
                        Text(Self.label(for: band))
                            .font(.subheadline)
                        Spacer()
                        Text("\(percent(band))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}
