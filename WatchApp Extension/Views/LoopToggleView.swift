//
//  LoopToggleView.swift
//  WatchApp Extension
//
//  The open/closed loop screen for standalone Show Mode. B1: the toggle arms
//  SHADOW mode — the loop computes and logs its decisions on the session
//  cadence but doses nothing. Per-session, always starts OFF.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

struct LoopToggleView: View {
    @ObservedObject var autoLoop: WatchAutoLoop

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { autoLoop.isEnabled },
                    set: { autoLoop.setEnabled($0) }
                )) {
                    Text("Closed Loop")
                        .font(.headline)
                }

                Text("Shadow mode: every 5 minutes and on each new reading, the loop computes what it would do and logs it. Nothing is dosed.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if let cycle = autoLoop.lastCycle {
                    Divider()
                    HStack {
                        Text("Last cycle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(relativeAge(of: cycle.date))
                            .font(.caption)
                    }
                    Text(cycle.decision.detailText)
                        .font(.caption)
                }

                Text("The loop turns off automatically when Show Mode ends, and starts OFF every session.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Loop")
    }

    private func relativeAge(of date: Date) -> String {
        let minutes = Int(-date.timeIntervalSinceNow / 60)
        return minutes < 1
            ? NSLocalizedString("just now", comment: "Auto-loop last cycle age (fresh)")
            : String(format: NSLocalizedString("%dm ago", comment: "Auto-loop last cycle age"), minutes)
    }
}
