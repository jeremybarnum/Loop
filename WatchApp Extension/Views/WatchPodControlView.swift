//
//  WatchPodControlView.swift
//  WatchApp Extension
//
//  The wrist UI for borrowing the pod from the phone and controlling it during a
//  workout. Driven entirely by WatchPodLoanCoordinator's phase.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import OmniBLECore

struct WatchPodControlView: View {
    @ObservedObject var coordinator: WatchPodLoanCoordinator
    @State private var confirmingBolus = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                content

                if let error = coordinator.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .idle:
            idleSection
        case .requesting:
            progress("Starting Show Mode…")
        case .denied(let reason):
            deniedSection(reason)
        case .armed:
            armedSection
        case .active:
            activeSection
        case .handingBack:
            progress("Ending Show Mode…")
        case .done:
            doneSection
        }
    }

    // MARK: - Sections

    private var idleSection: some View {
        VStack(spacing: 10) {
            Text("iPhone in control")
                .font(.headline)
            Text("Start Show Mode to control insulin from your watch while your iPhone is away.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(action: coordinator.requestLoan) {
                Label("Start Show Mode", systemImage: "arrow.left.arrow.right")
            }
            .disabled(coordinator.busy)
        }
    }

    private func deniedSection(_ reason: String) -> some View {
        VStack(spacing: 10) {
            Text("Couldn't start Show Mode")
                .font(.headline)
            Text(reason)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: coordinator.requestLoan)
                .disabled(coordinator.busy)
        }
    }

    private var armedSection: some View {
        VStack(spacing: 10) {
            Text("Ready to start")
                .font(.headline)
            if coordinator.busy {
                // BUG-3: give the takeover visible feedback (it can take a few seconds).
                ProgressView()
                Text("Taking control…").font(.footnote)
            } else {
                Text("Power your iPhone off (or turn Bluetooth off in Settings), then tap Take control to run Show Mode from your watch.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: coordinator.claim) {
                    Label("Take control", systemImage: "checkmark.circle")
                }
                Button("Cancel", action: coordinator.cancelArmed)
            }
        }
    }

    private var activeSection: some View {
        VStack(spacing: 10) {
            statusCard

            HStack(spacing: 6) {
                Button(action: coordinator.suspend) {
                    Label("Suspend", systemImage: "pause.circle")
                }
                Button(action: coordinator.resume) {
                    Label("Resume", systemImage: "play.circle")
                }
            }
            .disabled(coordinator.busy)

            bolusControl

            Divider()

            Button(action: coordinator.handBack) {
                Label("End Show Mode", systemImage: "iphone")
            }
            .disabled(coordinator.busy)
        }
        // The running loan journal (liveSummary) is intentionally NOT shown here —
        // it's verbose "what the watch has done" logging. It surfaces on the
        // hand-back summary (doneSection) instead, keeping the active screen clean.
    }

    // Two-tap confirm rather than a one-tap dose (no confirmationDialog on the
    // watchOS 7 floor).
    @ViewBuilder
    private var bolusControl: some View {
        let units = WatchPodLoanCoordinator.fixedBolusUnits
        if confirmingBolus {
            HStack(spacing: 6) {
                Button(String(format: "Give %.1f U", units)) {
                    confirmingBolus = false
                    coordinator.bolus()
                }
                Button("Cancel") { confirmingBolus = false }
            }
            .disabled(coordinator.busy)
        } else {
            Button {
                confirmingBolus = true
            } label: {
                Label(String(format: "Bolus %.1f U", units), systemImage: "syringe")
            }
            .disabled(coordinator.busy)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let status = coordinator.status {
                Text(status.deliveryStatus)
                    .font(.headline)
                if let reservoir = status.reservoirLevel {
                    Text(String(format: "Reservoir %.0f U", reservoir))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(String(format: "Delivered %.2f U", status.insulinDelivered))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("In Show Mode")
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var doneSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.title2)
            Text("Show Mode ended")
                .font(.headline)
            if let summary = coordinator.liveSummary {
                Text(summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            // BUG-1: let the user start a new loan without force-quitting.
            Button("Start again", action: coordinator.reset)
                .disabled(coordinator.busy)
                .padding(.top, 4)
        }
    }

    private func progress(_ label: String) -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(label).font(.footnote)
        }
    }
}
