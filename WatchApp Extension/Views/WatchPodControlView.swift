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

/// Why the pod-control screen was opened — decides what it shows while the watch
/// holds the pod (.active). Passed as the presentController context.
enum PodControlEntry {
    case start   // horse tapped when NOT in Show Mode → the untether/start flow
    case bolus   // Bolus button in Show Mode → the bolus dial
    case basal   // Override button in Show Mode → the basal dial
    case end     // horse tapped while in Show Mode → End Show Mode
}

struct WatchPodControlView: View {
    @ObservedObject var coordinator: WatchPodLoanCoordinator
    var entry: PodControlEntry = .start
    /// Return to the main HUD (set by the hosting controller). Used by the dose
    /// screens to dismiss after a delivery, like the regular bolus flow.
    var dismiss: () -> Void = {}

    var body: some View {
        Group {
            if isDoseScreen {
                // Dose screens must NOT sit inside a ScrollView: the scroll view captures
                // the Digital Crown, so the dial/confirm wouldn't respond until tapped.
                // Outside a scroll (like the regular bolus screen) the crown works
                // immediately, and the trailing Spacer can pin the action button.
                content
            } else {
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

    /// The crown-driven bolus/basal dose screens — rendered outside the ScrollView so the
    /// Digital Crown reaches them immediately (no tap-to-focus needed).
    private var isDoseScreen: Bool {
        coordinator.phase == .active && (entry == .bolus || entry == .basal)
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
            activeContent
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
            Text("Untethers from your iPhone — the watch runs the pod phone-free. Turn your iPhone's Bluetooth off, then enable.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if coordinator.busy && coordinator.phase == .armed {
                // Takeover in progress (Untether tapped) — BUG-3: visible feedback.
                ProgressView()
                Text("Enabling Show Mode…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Button(action: coordinator.claim) {
                    Label("Enable Show Mode", systemImage: "checkmark.circle")
                }
                .disabled(coordinator.phase != .armed)   // lit only once keys have arrived
                Button("Cancel", action: coordinator.cancelArmed)
                    .disabled(coordinator.busy)
            }
        }
    }

    // While the watch holds the pod, this screen is opened from a specific main-HUD
    // button, and shows only that one control (single dial → the crown drives it
    // cleanly, no two-dial focus juggling). The loan journal is intentionally not
    // shown here — it surfaces on the hand-back summary (doneSection).
    @ViewBuilder
    private var activeContent: some View {
        switch entry {
        case .bolus:
            ShowModeDoseView(kind: .bolus, coordinator: coordinator, onFinish: dismiss)
        case .basal:
            ShowModeDoseView(kind: .basal, coordinator: coordinator, onFinish: dismiss)
        case .start, .end:
            endSection
        }
    }

    private var endSection: some View {
        VStack(spacing: 10) {
            statusCard
            Button(action: coordinator.handBack) {
                Label("End Show Mode", systemImage: "iphone")
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

// The watch-resident bolus / basal control used in Show Mode, built from the same
// polished pieces as Loop's regular watch bolus screen — DoseVolumeInput's big rounded
// number + BolusConfirmationView's "turn Digital Crown to confirm" — but wired straight
// to the pod (WatchPodLoanCoordinator) instead of the phone. Bolus and basal share this
// view; they differ only in unit, action verb, and which command delivers. Two steps,
// mirroring the regular bolus UX: pick the amount (crown), then a turn-crown-to-confirm
// gesture delivers and returns to the main HUD. Both amounts are hard-capped in the
// coordinator regardless of the dial.
//
// (Lives here rather than its own file so it compiles without a project.pbxproj change;
// split into ShowModeDoseView.swift via Xcode if desired.)
struct ShowModeDoseView: View {
    enum Kind: Equatable {
        case bolus
        case basal

        var unit: String { self == .bolus ? "U" : "U/hr" }
        var max: Double {
            self == .bolus ? WatchPodLoanCoordinator.maxBolusUnits
                           : WatchPodLoanCoordinator.maxTempBasalRate
        }
        var defaultAmount: Double {
            self == .bolus ? WatchPodLoanCoordinator.defaultBolusUnits
                           : WatchPodLoanCoordinator.defaultBasalRate
        }
        /// The +/- button increment — coarser than the crown's 0.05, matching the regular
        /// bolus screen (0.5 U). Basal is dialed in smaller steps, so 0.1 U/hr.
        var buttonStep: Double { self == .bolus ? 0.5 : 0.1 }
    }

    let kind: Kind
    @ObservedObject var coordinator: WatchPodLoanCoordinator
    /// Called after delivery to return to the main HUD (the confirmation gesture is the
    /// commit, so we dismiss right after — like the regular bolus flow).
    let onFinish: () -> Void

    @State private var amount: Double
    @State private var confirming = false
    @State private var confirmProgress: Double = 0
    /// For basal with a temp already running: the user has tapped "Change" on the
    /// options step and wants the dial.
    @State private var showingDial = false

    private let step = 0.05

    init(kind: Kind, coordinator: WatchPodLoanCoordinator, onFinish: @escaping () -> Void) {
        self.kind = kind
        self.coordinator = coordinator
        self.onFinish = onFinish
        // Basal dial starts at the temp that's already running, if any.
        let initial = (kind == .basal ? coordinator.sessionBasalRate : nil) ?? kind.defaultAmount
        _amount = State(initialValue: initial)
    }

    var body: some View {
        if confirming {
            confirmStep
        } else if kind == .basal, !showingDial, let activeRate = coordinator.sessionBasalRate {
            // A temp is already running: offer Change or Cancel before the dial.
            optionsStep(activeRate: activeRate)
        } else {
            pickStep
        }
    }

    // MARK: - Active temp: change or cancel

    private func optionsStep(activeRate: Double) -> some View {
        VStack(spacing: 4) {
            Text(String(format: NSLocalizedString("Basal %.2f U/hr", comment: "Show Mode active temp header"), activeRate))
                .font(.headline)
            Text(cancelHint)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            ActionButton(
                title: Text(NSLocalizedString("Change", comment: "Show Mode active-temp action: open the dial")),
                color: .insulin,
                action: {
                    amount = activeRate
                    showingDial = true
                }
            )
            ActionButton(
                title: Text(NSLocalizedString("Cancel Temp", comment: "Show Mode active-temp action: revert to scheduled basal")),
                color: .darkTurfColor,
                action: {
                    coordinator.cancelBasal()
                    onFinish()
                }
            )
        }
    }

    private var cancelHint: String {
        if let scheduled = coordinator.currentScheduledRate {
            return String(format: NSLocalizedString("Cancel resumes schedule (%.2f U/hr)", comment: "Show Mode cancel-temp hint with scheduled rate"), scheduled)
        }
        return NSLocalizedString("Cancel resumes scheduled basal", comment: "Show Mode cancel-temp hint")
    }

    // MARK: - Pick the amount

    private var pickStep: some View {
        VStack(spacing: 2) {
            DoseVolumeInput(
                volume: amount,
                unit: Text(kind.unit),
                isEditable: true,
                increment: { amount = min(amount + kind.buttonStep, kind.max) },   // +/- buttons: coarse
                decrement: { amount = max(amount - kind.buttonStep, 0) },
                formatVolume: { String(format: "%.2f", $0) }
            )
            .focusable(true)
            .digitalCrownRotation($amount,                                          // crown: fine (0.05)
                                  from: 0, through: kind.max, by: step,
                                  sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)

            Spacer()

            // The orange pill from the regular bolus screen, pinned to the bottom.
            ActionButton(
                title: Text(actionTitle),
                color: actionEnabled ? .insulin : .gray,
                action: {
                    confirmProgress = 0
                    confirming = true
                }
            )
            .disabled(!actionEnabled)
        }
    }

    /// Bolus needs a positive amount; basal is always actionable (0 = suspend).
    private var actionEnabled: Bool { kind == .basal || amount > 0 }

    // MARK: - Turn-crown-to-confirm

    private var confirmStep: some View {
        VStack(spacing: 6) {
            Text(confirmSummary)
                .font(.caption)
                .multilineTextAlignment(.center)
            BolusConfirmationView(progress: $confirmProgress, helpText: confirmHelpText) {
                deliver()
            }
            Button("Cancel") { confirming = false }
        }
    }

    private func deliver() {
        let dose = (amount / step).rounded() * step   // snap to pod resolution
        switch kind {
        case .bolus: coordinator.bolus(units: dose)
        case .basal: coordinator.setBasalRate(dose)
        }
        onFinish()
    }

    // MARK: - Labels

    private var isSuspend: Bool { kind == .basal && amount <= 0 }

    private var actionTitle: String {
        switch kind {
        case .bolus: return NSLocalizedString("Bolus", comment: "Show Mode bolus action")
        case .basal: return isSuspend
            ? NSLocalizedString("Suspend", comment: "Show Mode basal-zero action")
            : NSLocalizedString("Set basal", comment: "Show Mode basal action")
        }
    }

    private var confirmSummary: String {
        switch kind {
        case .bolus: return String(format: NSLocalizedString("Bolus %.2f U", comment: "Show Mode bolus confirm summary"), amount)
        case .basal: return isSuspend
            ? NSLocalizedString("Suspend basal", comment: "Show Mode suspend confirm summary")
            : String(format: NSLocalizedString("Basal %.2f U/hr", comment: "Show Mode basal confirm summary"), amount)
        }
    }

    private var confirmHelpText: Text? {
        switch kind {
        case .bolus:
            return nil   // BolusConfirmationView's default ("Turn Digital Crown to bolus")
        case .basal:
            return Text(isSuspend
                        ? NSLocalizedString("Turn Digital Crown\nto suspend", comment: "Show Mode suspend confirm help")
                        : NSLocalizedString("Turn Digital Crown\nto set basal", comment: "Show Mode basal confirm help"))
        }
    }
}
