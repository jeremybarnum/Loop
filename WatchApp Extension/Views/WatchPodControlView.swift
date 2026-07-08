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
    @State private var bolusAmount = WatchPodLoanCoordinator.defaultBolusUnits
    @State private var confirmingBasal = false
    @State private var basalAmount = WatchPodLoanCoordinator.defaultBasalRate

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
        .onAppear {
            // Tapping the horse IS the intent to start Show Mode, so begin fetching the
            // pod credentials from the phone immediately (in the background) and land the
            // user straight on the "disconnect Bluetooth → Untether" screen — no separate
            // "Start" tap. Only auto-start from a resting phase (not mid-loan).
            if coordinator.phase == .idle || coordinator.phase == .done {
                coordinator.requestLoan()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .idle:
            idleSection
        case .requesting, .armed:
            untetherSection
        case .denied(let reason):
            deniedSection(reason)
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
            Text("Watch tethered")
                .font(.headline)
            Text("Insulin actions run through your iPhone.")
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

    // Single Show Mode entry screen (covers both .requesting and .armed). Opened
    // straight from the horse tap: the "disconnect Bluetooth" instruction shows
    // immediately while credentials are fetched in the background; the Untether button
    // is greyed until the keys arrive (.armed), then lights up and runs the takeover.
    private var untetherSection: some View {
        VStack(spacing: 10) {
            Text("Show Mode")
                .font(.headline)
            Text("Disconnect Bluetooth on your iPhone, then Untether watch.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if coordinator.busy && coordinator.phase == .armed {
                // Takeover in progress (Untether tapped) — BUG-3: visible feedback.
                ProgressView()
                Text("Untethering…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Button(action: coordinator.claim) {
                    Label("Untether watch", systemImage: "checkmark.circle")
                }
                .disabled(coordinator.phase != .armed)   // lit only once keys have arrived
                Button("Cancel", action: coordinator.cancelArmed)
                    .disabled(coordinator.busy)
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

            Divider()
            basalControl

            Divider()
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

    // Crown-dialed amount, hard-capped, with a two-tap confirm (no confirmationDialog
    // on the watchOS 7 floor). A manual capped correction — no BG gate yet.
    @ViewBuilder
    private var bolusControl: some View {
        if confirmingBolus {
            VStack(spacing: 6) {
                Button(String(format: "Give %.2f U", bolusAmount)) {
                    confirmingBolus = false
                    coordinator.bolus(units: bolusAmount)
                }
                Button("Cancel") { confirmingBolus = false }
            }
            .disabled(coordinator.busy)
        } else {
            VStack(spacing: 4) {
                Text(String(format: "%.2f U", bolusAmount))
                    .font(.title3)
                    .focusable(true)
                    .digitalCrownRotation($bolusAmount,
                                          from: 0.0,
                                          through: WatchPodLoanCoordinator.maxBolusUnits,
                                          by: 0.05,
                                          sensitivity: .medium,
                                          isContinuous: false,
                                          isHapticFeedbackEnabled: true)
                Button {
                    confirmingBolus = true
                } label: {
                    Label("Bolus", systemImage: "syringe")
                }
                .disabled(coordinator.busy || bolusAmount <= 0)
            }
        }
    }

    // Crown-dialed absolute basal rate, hard-capped, two-tap confirm. 0 U/hr = suspend.
    // Set-and-forget from the user's view (fixed 3h duration under the hood, auto-reverts).
    @ViewBuilder
    private var basalControl: some View {
        if confirmingBasal {
            VStack(spacing: 6) {
                Button(basalAmount <= 0 ? "Suspend basal" : String(format: "Set %.2f U/hr", basalAmount)) {
                    confirmingBasal = false
                    coordinator.setBasalRate(basalAmount)
                }
                Button("Cancel") { confirmingBasal = false }
            }
            .disabled(coordinator.busy)
        } else {
            VStack(spacing: 4) {
                Text(basalAmount <= 0 ? "Basal 0 (suspend)" : String(format: "Basal %.2f U/hr", basalAmount))
                    .font(.title3)
                    .focusable(true)
                    .digitalCrownRotation($basalAmount,
                                          from: 0.0,
                                          through: WatchPodLoanCoordinator.maxTempBasalRate,
                                          by: 0.05,
                                          sensitivity: .medium,
                                          isContinuous: false,
                                          isHapticFeedbackEnabled: true)
                Button {
                    confirmingBasal = true
                } label: {
                    Label("Set basal", systemImage: "dial.medium")
                }
                .disabled(coordinator.busy)
            }
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
            Text("Watch tethered")
                .font(.headline)
            if let summary = coordinator.liveSummary {
                Text(summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            // Back to the resting state — start a fresh Show Mode directly (BUG-1: also
            // the escape from the done state without force-quitting).
            Button("Start Show Mode", action: coordinator.requestLoan)
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
