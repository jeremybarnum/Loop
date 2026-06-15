//
//  TimeInRangeBar.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopUI

/// captūrAGP / IDC report palette for the glucose bands, matched to the standard
/// Ambulatory Glucose Profile report colors.
extension GlucoseBand {
    var agpColor: Color {
        switch self {
        case .veryLow:  return Color(red: 0.60, green: 0.13, blue: 0.15)  // dark red
        case .low:      return Color(red: 0.85, green: 0.26, blue: 0.24)  // red
        case .target:   return Color(red: 0.36, green: 0.65, blue: 0.37)  // green
        case .high:     return Color(red: 0.91, green: 0.77, blue: 0.26)  // gold / yellow
        case .veryHigh: return Color(red: 0.85, green: 0.55, blue: 0.24)  // orange
        }
    }

    var localizedTitle: String {
        switch self {
        case .veryLow:  return NSLocalizedString("Very Low", comment: "Time-in-range band label (<54 mg/dL)")
        case .low:      return NSLocalizedString("Low", comment: "Time-in-range band label (54–69 mg/dL)")
        case .target:   return NSLocalizedString("In Range", comment: "Time-in-range band label (70–180 mg/dL)")
        case .high:     return NSLocalizedString("High", comment: "Time-in-range band label (181–250 mg/dL)")
        case .veryHigh: return NSLocalizedString("Very High", comment: "Time-in-range band label (>250 mg/dL)")
        }
    }
}

/// A horizontal stacked bar showing the fraction of time spent in each glucose
/// band, plus a legend with the percentages.
struct TimeInRangeBar: View {
    let timeInRange: [GlucoseBand: Double]

    // Display order, lowest band first (left to right).
    private static let order: [GlucoseBand] = [.veryLow, .low, .target, .high, .veryHigh]

    private func percent(_ band: GlucoseBand) -> Int {
        Int((timeInRange[band] ?? 0) * 100 + 0.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Self.order, id: \.self) { band in
                        let fraction = timeInRange[band] ?? 0
                        band.agpColor
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: 24)

            // Legend, most-clinically-relevant first.
            VStack(alignment: .leading, spacing: 4) {
                ForEach([GlucoseBand.veryHigh, .high, .target, .low, .veryLow], id: \.self) { band in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(band.agpColor)
                            .frame(width: 12, height: 12)
                        Text(band.localizedTitle)
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

#if DEBUG
#Preview {
    TimeInRangeBar(timeInRange: [.veryLow: 0.02, .low: 0.05, .target: 0.74, .high: 0.15, .veryHigh: 0.04])
        .padding()
}
#endif
