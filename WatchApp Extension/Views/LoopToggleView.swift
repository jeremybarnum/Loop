//
//  LoopToggleView.swift
//  WatchApp Extension
//
//  The open/closed loop screen for standalone Show Mode. Closing the loop is
//  consequential, so it uses Loop's turn-crown-to-confirm ceremony (the same
//  BolusConfirmationView the dose screens use); opening it back up is the safe
//  direction and takes one tap. B1: closed = SHADOW — decisions are computed
//  and logged on the session cadence, nothing doses.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

struct LoopToggleView: View {
    @ObservedObject var autoLoop: WatchAutoLoop

    @State private var confirming = false
    @State private var confirmProgress: Double = 0

    var body: some View {
        if confirming {
            confirmStep
        } else {
            statusStep
        }
    }

    // MARK: - Status + action

    private var statusStep: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle()
                            .strokeBorder(Color.turf, lineWidth: 3)
                            .frame(width: 22, height: 22)
                            .opacity(autoLoop.isEnabled ? 1 : 0.4)
                        Text(autoLoop.isEnabled
                             ? NSLocalizedString("Closed Loop", comment: "Loop screen state title (closed)")
                             : NSLocalizedString("Open Loop", comment: "Loop screen state title (open)"))
                            .font(.headline)
                        Spacer()
                    }

                    if autoLoop.isEnabled {
                        Text("Shadow: decisions are computed every 5 minutes and on each reading, and logged. Nothing is dosed.")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        if let cycle = autoLoop.lastCycle {
                            Divider()
                            HStack {
                                Text("Last cycle")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(relativeAge(of: cycle.date))
                                    .font(.caption2)
                            }
                            Text(cycle.decision.detailText)
                                .font(.caption)
                        }
                    } else {
                        Text("The pod runs its schedule plus anything you dose by hand. Closing the loop is per-session — it always starts open.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }

            if autoLoop.isEnabled {
                ActionButton(
                    title: Text("Open Loop", comment: "Button title to open the standalone loop"),
                    color: .gray,
                    action: { autoLoop.setEnabled(false) }
                )
            } else {
                ActionButton(
                    title: Text("Close Loop", comment: "Button title to begin closing the standalone loop"),
                    color: .turf,
                    action: {
                        confirmProgress = 0
                        confirming = true
                    }
                )
            }
        }
    }

    // MARK: - Turn-crown-to-confirm (same ceremony as dosing)

    private var confirmStep: some View {
        VStack(spacing: 6) {
            Text("Close the loop for this session?")
                .font(.caption)
                .multilineTextAlignment(.center)
            Text("Shadow mode — logs decisions, doses nothing.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            BolusConfirmationView(progress: $confirmProgress, helpText: Text("Turn to close the loop", comment: "Crown-confirm help text for closing the loop")) {
                autoLoop.setEnabled(true)
                confirming = false
            }
            Button("Cancel") { confirming = false }
        }
    }

    private func relativeAge(of date: Date) -> String {
        let minutes = Int(-date.timeIntervalSinceNow / 60)
        return minutes < 1
            ? NSLocalizedString("just now", comment: "Auto-loop last cycle age (fresh)")
            : String(format: NSLocalizedString("%dm ago", comment: "Auto-loop last cycle age"), minutes)
    }
}
