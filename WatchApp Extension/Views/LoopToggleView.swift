//
//  LoopToggleView.swift
//  WatchApp Extension
//
//  The standalone loop screen. Today the loop is OPEN: it always shows the
//  recommendation (correction math) and the trail of what it would do, and
//  doses nothing — exactly like open loop on the phone. Closing the loop
//  (automatic enactment) is B2; the crown-confirm ceremony is scaffolded but
//  the action is disabled until then.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import HealthKit
import LoopKit
import LoopCore

struct LoopToggleView: View {
    @ObservedObject var autoLoop: WatchAutoLoop

    /// Bumped on the store's didUpdate so the live derivation re-reads.
    @State private var storeTick = 0

    private var liveMath: WatchPredictionOutput.CorrectionMath? {
        _ = storeTick   // re-read when the store updates
        let store = ExtensionDelegate.shared().predictionStore
        guard !store.isAnchorStale else { return nil }
        return store.latestOutput?.correctionMath()
    }

    var body: some View {
        statusStep
            .onReceive(NotificationCenter.default.publisher(for: WatchPredictionStore.didUpdateNotification)) { _ in
                storeTick &+= 1
            }
    }

    // MARK: - Status + recommendation

    private var statusStep: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    // No loop glyph here — a plain Circle reads as "closed"
                    // regardless and would contradict the real open/closed ring
                    // shown on the HUD. The text carries the state.
                    Text(autoLoop.isClosed
                         ? NSLocalizedString("Closed Loop", comment: "Loop screen state title (closed)")
                         : NSLocalizedString("Open Loop", comment: "Loop screen state title (open)"))
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(autoLoop.isClosed
                         ? NSLocalizedString("Recommendations are enacted automatically.", comment: "Loop screen subtitle (closed)")
                         : NSLocalizedString("The recommendation below is shown but not enacted. The pod runs its schedule plus anything you dose by hand.", comment: "Loop screen subtitle (open)"))
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if let math = liveMath {
                        Divider()
                        Text("Recommendation")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        derivationBlock(math)
                    }

                    if !autoLoop.recentCycles.isEmpty {
                        Divider()
                        Text("Recent changes")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        ForEach(autoLoop.recentCycles) { cycle in
                            cycleRow(cycle)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            // B2 wires this to setClosed(true). Disabled until enactment exists,
            // so the ceremony is visible but can't dose.
            ActionButton(
                title: Text("Close Loop", comment: "Button title to begin closing the standalone loop"),
                color: .gray,
                action: {}
            )
            .disabled(true)
            Text("Automatic dosing coming soon")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    /// The correction math, shown step by step (eventual → target → Δ → ÷ISF →
    /// 30-min temp) — Loop's arithmetic for the eventual, made visible.
    @ViewBuilder
    private func derivationBlock(_ math: WatchPredictionOutput.CorrectionMath) -> some View {
        let g = NumberFormatter.glucoseFormatter(for: math.unit)
        VStack(alignment: .leading, spacing: 2) {
            derivationRow("Eventual", g.string(from: math.eventual) ?? "?")
            derivationRow("Target", String(format: "%@  (%@–%@)",
                                            g.string(from: math.targetMid) ?? "?",
                                            g.string(from: math.targetLow) ?? "?",
                                            g.string(from: math.targetHigh) ?? "?"))
            derivationRow("Difference", String(format: "%@%@",
                                               math.difference >= 0 ? "+" : "",
                                               g.string(from: math.difference) ?? "?"))
            derivationRow(String(format: "÷ ISF %@", g.string(from: math.sensitivity) ?? "?"),
                          String(format: "%+.2f U", math.insulin))
            derivationRow("Temp · 30m",
                          math.isSuspend
                          ? NSLocalizedString("0 (suspend)", comment: "Correction temp when floored to zero")
                          : String(format: "%.2f U/hr%@", math.tempRate, math.isCapped ? " (max)" : ""))
            Text(String(format: NSLocalizedString("scheduled %.2f U/hr", comment: "Scheduled basal reference under the temp"), math.scheduledBasal))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func derivationRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.caption)
        }
    }

    /// One line per shadow cycle: age, the BG→eventual it reasoned over, and
    /// the decision — the log trail made legible for validation.
    @ViewBuilder
    private func cycleRow(_ cycle: WatchAutoLoop.Cycle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(cycle.decision.detailText)
                    .font(.caption2)
                Spacer()
                Text(relativeAge(of: cycle.date))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if let context = bgContext(cycle) {
                Text(context)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    /// "BG 165 → 128" (eventual), or "BG 152" when there was no projection.
    private func bgContext(_ cycle: WatchAutoLoop.Cycle) -> String? {
        guard let bg = cycle.bg else { return nil }
        let unit = ExtensionDelegate.shared().loopManager.settings.glucoseUnit ?? .milligramsPerDeciliter
        let formatter = NumberFormatter.glucoseFormatter(for: unit)
        let bgText = formatter.string(from: bg.doubleValue(for: unit)) ?? "?"
        if let eventual = cycle.eventual, let evText = formatter.string(from: eventual.doubleValue(for: unit)) {
            return String(format: NSLocalizedString("BG %@ → %@", comment: "Shadow cycle context: anchor BG to eventual"), bgText, evText)
        }
        return String(format: NSLocalizedString("BG %@", comment: "Shadow cycle context: anchor BG only"), bgText)
    }

    private func relativeAge(of date: Date) -> String {
        let minutes = Int(-date.timeIntervalSinceNow / 60)
        return minutes < 1
            ? NSLocalizedString("just now", comment: "Auto-loop last cycle age (fresh)")
            : String(format: NSLocalizedString("%dm ago", comment: "Auto-loop last cycle age"), minutes)
    }
}
