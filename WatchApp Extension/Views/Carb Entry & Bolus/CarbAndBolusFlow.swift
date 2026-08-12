//
//  CarbAndBolusFlow.swift
//  WatchApp Extension
//
//  Created by Michael Pangburn on 3/23/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import SwiftUI
import HealthKit
import LoopKit


struct CarbAndBolusFlow: View {
    enum Configuration: Equatable {
        case carbEntry(NewCarbEntry?)
        case manualBolus
    }

    private enum FlowState {
        case carbEntry
        case bolusEntry
        case bolusConfirmation
    }

    fileprivate enum AlertState {
        case bolusRecommendationChanged
        case communicationError(CarbAndBolusFlowViewModel.Error)
    }

    // MARK: - State
    @State private var flowState: FlowState
    @ObservedObject private var viewModel: CarbAndBolusFlowViewModel
    @Environment(\.sizeClass) private var sizeClass

    // MARK: - State: Carb Entry
    // Date the user last changed the carb entry with the UI
    @State private var carbLastEntryDate = Date()
    @State private var carbAmount = 15
    // Date of the carb entry
    @State private var carbEntryDate = Date()
    @State private var carbAbsorptionTime: CarbAbsorptionTime = .medium
    @State private var inputMode: CarbEntryInputMode = .carbs

    // MARK: - State: Bolus Entry
    @State private var bolusAmount: Double = 0
    @State private var receivedInitialBolusRecommendation = false
    /// #116: the last value WE wrote into the dial, so a fresh recommendation can replace our
    /// own stale pre-fill without ever touching a user-dialled amount.
    @State private var programmaticBolusPrefill: Double?
    @State private var activeAlert: AlertState?

    // MARK: - State: Bolus Confirmation
    @State private var bolusConfirmationProgress: Double = 0

    // MARK: - Initialization

    private var configuration: Configuration { viewModel.configuration }

    init(viewModel: CarbAndBolusFlowViewModel) {
        switch viewModel.configuration {
        case .carbEntry(let entry):
            _flowState = State(initialValue: .carbEntry)
            
            if let entry = entry {
                _carbEntryDate = State(initialValue: entry.startDate)
                
                let initialCarbAmount = entry.quantity.doubleValue(for: .gram())
                _carbAmount = State(initialValue: Int(initialCarbAmount))                
            }
        case .manualBolus:
            _flowState = State(initialValue: .bolusEntry)
        }

        self.viewModel = viewModel
    }

    // MARK: - View Tree

    var body: some View {
        VStack(spacing: 2) {
            inputViews
            Spacer()
            actionView
        }
        // Position the carb labels via preference keys propagated up from lower in the view tree.
        .overlayPreferenceValue(CarbAmountPositionKey.self, positionedCarbAmountLabel)
        .overlayPreferenceValue(GramLabelPositionKey.self, positionedGramLabel)

        // Handle incoming bolus recommendations.
        .onReceive(viewModel.$recommendedBolusAmount, perform: handleNewBolusRecommendation)

        // Handle error states.
        .onReceive(viewModel.$error) { self.activeAlert = $0.map(AlertState.communicationError) }
        .alert(item: $activeAlert, content: alert(for:))
    }
}

// MARK: - Input views

extension CarbAndBolusFlow {
    private var inputViews: some View {
        VStack(spacing: 4) {
            if flowState == .carbEntry {
                CarbAndDateInput(
                    lastEntryDate: $carbLastEntryDate,
                    amount: $carbAmount,
                    date: $carbEntryDate,
                    initialDate: viewModel.interactionStartDate,
                    inputMode: $inputMode
                )
                .transition(.shrinkDownAndFade)
            } else {
                BolusInput(
                    amount: $bolusAmount,
                    isComputingRecommendedAmount: viewModel.isComputingRecommendedBolus,
                    recommendedAmount: viewModel.recommendedBolusAmount,
                    recommendationNotice: viewModel.recommendationNotice,
                    pickerValues: viewModel.bolusPickerValues,
                    isEditable: flowState == .bolusEntry
                )
            }

            if configuration != .manualBolus && flowState != .bolusConfirmation {
                AbsorptionTimeSelection(
                    lastEntryDate: $carbLastEntryDate,
                    selectedAbsorptionTime: $carbAbsorptionTime,
                    expanded: absorptionButtonsExpanded,
                    amount: carbAmount
                )
            }
        }
        .padding(.top, topPaddingToPositionInputViews)
    }

    private var absorptionButtonsExpanded: Binding<Bool> {
        Binding(
            get: { self.flowState == .carbEntry },
            set: { isExpanded in isExpanded ? self.returnToCarbEntry() : self.transitionToBolusEntry() }
        )
    }

    private func returnToCarbEntry() {
        viewModel.endBolusConfirmation()
        withAnimation {
            flowState = .carbEntry
        }
        receivedInitialBolusRecommendation = false
        viewModel.discardCarbEntryUnderConsideration()

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) {
            self.bolusAmount = 0
        }
    }

    private func transitionToBolusEntry() {
        viewModel.recommendBolus(forGrams: carbAmount, eatenAt: carbEntryDate, absorptionTime: carbAbsorptionTime, lastEntryDate: carbLastEntryDate)
        withAnimation {
            flowState = .bolusEntry
            inputMode = .carbs
        }
    }

    private var topPaddingToPositionInputViews: CGFloat {
        guard flowState == .bolusConfirmation else {
            return 0
        }

        // Derived via experimentation to hold the bolus amount label in place in transition to bolus confirmation.
        switch sizeClass {
        case .size38mm:
            return 2
        case .size42mm:
            return 0
        case .size40mm, .size41mm:
            if case .carbEntry = configuration {
                return 7
            } else {
                return 19
            }
        case .size44mm, .size45mm:
            return 5
        case .size187x223, .size208x248, .size205x251, .size211x257:
            // Measured, not guessed. On a Series 11 46mm (208x248) sim, screenshotting the
            // bolus-amount label either side of the bolusEntry → bolusConfirmation transition
            // and nulling its drift — which is precisely what this constant is for:
            //
            //   manualBolus   5pt → -4.5pt drift · 14pt → 0.0 · 19pt → +2.5
            //   carbEntry                          9pt → 0.0 · 14pt → +2.5
            //
            // Drift moves 1pt per 1pt of padding, so these are the exact zeroes. The split
            // mirrors the 40/41mm arm, where carb entry likewise wants less than manual bolus.
            // Only 208x248 was measured; the other three are carried by analogy as large
            // screens. Before this arm existed they fell to .size40mm and got 7/19.
            if case .carbEntry = configuration {
                return 9
            } else {
                return 14
            }
        }
    }
}

// MARK: - Action views

extension CarbAndBolusFlow {
    private var actionView: some View {
        Group {
            if flowState == .carbEntry {
                continueToBolusEntryButton
            }

            if flowState == .bolusEntry {
                saveCarbsAndBolusButton
            }

            if flowState == .bolusConfirmation {
                bolusConfirmationView
            }
        }
    }

    private var continueToBolusEntryButton: some View {
        ActionButton(
            title: Text("Continue", comment: "Button text to continue from carb entry to bolus entry on Apple Watch"),
            color: .carbs
        ) {
            self.transitionToBolusEntry()
        }
        // No `.offset(y:)` here — see saveCarbsAndBolusButton.
        .transition(.fadeIn(after: 0.175))
    }

    private var saveCarbsAndBolusButton: some View {
        ActionButton(
            title: saveButtonText,
            color: bolusAmount > 0 || configuration == .manualBolus ? .insulin : .blue
        ) {
            // EVERY path now ends in the crown ceremony. Previously a bolus got the ceremony and a
            // zero-bolus carb save got no visible change at all: same green, same enabled button,
            // for the ~1s before the flow dismissed. The success haptic fires, but a watch off the
            // wrist swallows it — so the still-armed button read as "that didn't take", inviting a
            // second tap and then a full re-entry once the screen had gone (field 2026-08-06).
            //
            // Symmetry is also the correct SAFETY posture here, not just better feedback. During a
            // loan a carb entry cannot be edited or deleted on either device, and it drives dosing
            // for hours — so it deserves the same deliberate gesture as insulin.
            // A manual bolus dialled to zero has nothing to commit — no carbs, no insulin. Stay
            // put rather than run a ceremony that would deliver nothing (the pre-existing
            // behaviour; only the carb-entry path changes here).
            if self.bolusAmount <= 0, case .manualBolus = self.configuration { return }

            self.viewModel.beginBolusConfirmation()
            withAnimation {
                self.flowState = .bolusConfirmation
            }
        }
        // Stock shipped a per-size-class `.offset(y:)` here (20pt on 40/41mm, 27pt on
        // 44/45mm) to push the button toward the bezel on watchOS 6-era safe areas. `.offset`
        // is a render-time shift, not layout: the `Spacer()` above already bottom-aligns this
        // button, so the shift moves it *below* the safe area with nothing to absorb it. On
        // watchOS 10+ the bottom inset shrank and the capsule is sheared off — measured on a
        // 44mm SE 3 sim, which reproduces the on-wrist clipping exactly at 27 and is clean at
        // 0. Bottom alignment is now left to the layout system, which is size-class agnostic.
        .transition(.fadeIn(after: 0.35, removal: .identity))
    }

    private var saveButtonText: Text {
        switch configuration {
        case .carbEntry:
            return bolusAmount > 0
                ? Text("Save & Bolus", comment: "Button text to confirm carb entry and bolus on Apple Watch")
                : Text("Save", comment: "Button text to confirm carb entry without bolusing on Apple Watch")
        case .manualBolus:
            return Text("Bolus", comment: "Button text to confirm manual bolus on Apple Watch")
        }
    }

    private var bolusConfirmationView: some View {
        BolusConfirmationView(
            progress: $bolusConfirmationProgress,
            prompt: bolusAmount > 0
                ? Text("Turn Digital Crown\nto bolus", comment: "Help text for bolus confirmation on Apple Watch")
                : Text("Turn Digital Crown\nto save carbs", comment: "Help text for carb-only confirmation on Apple Watch"),
            onConfirmation: {
                // addCarbsAndDeliverBolus with 0 delivers no insulin — it files the carb entry and
                // nothing else — so one call covers both paths.
                self.viewModel.addCarbsAndDeliverBolus(self.bolusAmount)
            })
        .padding(.bottom, bolusConfirmationPadding)
        .transition(.fadeIn(after: 0.35))
    }

    private var bolusConfirmationPadding: CGFloat {
        switch sizeClass {
        case .size42mm:
            return 12
        default:
            return 0
        }
    }
}

// MARK: - Carb label layout

extension CarbAndBolusFlow {
    private var carbLabelScale: PositionedTextScale {
        flowState == .carbEntry ? .large : .small
    }

    private func positionedCarbAmountLabel(_ origin: Anchor<CGPoint>?) -> some View {
        origin.map { origin in
            carbLabelStyle(CarbAmountLabel(amount: carbAmount, origin: origin, scale: carbLabelScale))
        }
    }

    private func positionedGramLabel(_ origin: Anchor<CGPoint>?) -> some View {
        origin.map { origin in
            carbLabelStyle(GramLabel(origin: origin, scale: carbLabelScale))
        }
    }

    private func carbLabelStyle<Content: View>(_ content: Content) -> some View {
        let color: Color
        if flowState == .carbEntry {
            color = inputMode == .carbs ? .carbs : Color(.lightGray)
        } else {
            color = .white
        }

        return content
            .foregroundColor(color)
            .onTapGesture {
                if self.flowState == .carbEntry {
                    self.inputMode.toggle()
                } else {
                    self.returnToCarbEntry()
                }
            }
    }
}

// MARK: - Handling incoming data

extension CarbAndBolusFlow {
    private func handleNewBolusRecommendation(_ recommendedBolus: Double?) {
        guard flowState != .carbEntry else {
            return
        }

        // A PRIMING publish is the first COMPUTED recommendation replacing the seed the screen
        // opened with. It is not news, so it must be handled exactly like the initial value —
        // never as a change to reconfirm. See publishComputedRecommendation in the view model.
        let isPriming = viewModel.consumeRecommendationPriming()

        if !receivedInitialBolusRecommendation || isPriming {
            receivedInitialBolusRecommendation = true

            // If the user hasn't started to dial a bolus amount, update to the recommended amount.
            //
            // #116 (field 2026-08-11 22:34): `bolusAmount == 0` alone could not tell a USER-dialled
            // value from OUR OWN earlier pre-fill. The screen opens seeded with the last cycle's
            // published REC (1.10, computed before Jeremy re-enabled his override), that seed
            // pre-fills the dial, and when the on-open refresh landed with the override-correct
            // 0.55 the guard protected the stale 1.10 as if the user had chosen it. REC label and
            // dial disagreed by 2x on the same screen. So: remember what WE wrote — a value the
            // user has not touched is ours to replace; one they dialled is theirs, always.
            if flowState == .bolusEntry, let recommendedBolus = recommendedBolus,
               bolusAmount == 0 || bolusAmount == programmaticBolusPrefill {
                if bolusAmount != 0, bolusAmount != recommendedBolus {
                    SportLog.event("bolus-ui", String(format: "pre-fill re-seeded %.2f -> %.2f U (fresh REC replaced our stale seed; dial untouched by user)", bolusAmount, recommendedBolus))
                }
                bolusAmount = recommendedBolus
                programmaticBolusPrefill = recommendedBolus
            }
        } else {
            // Boot the user out of bolus confirmation to acknowledge the updated recommendation.
            if flowState == .bolusConfirmation {
                withAnimation {
                    flowState = .bolusEntry
                }
            }

            bolusAmount = recommendedBolus ?? 0
            activeAlert = .bolusRecommendationChanged
        }
    }

    private func alert(for activeAlert: AlertState) -> SwiftUI.Alert {
        switch activeAlert {
        case .bolusRecommendationChanged:
            return recommendedBolusUpdatedAlert
        case .communicationError(let error):
            return communicationErrorAlert(for: error)
        }
    }

    private var recommendedBolusUpdatedAlert: SwiftUI.Alert {
        SwiftUI.Alert(
            title: Text("Bolus Recommendation Updated", comment: "Alert title for updated bolus recommendation on Apple Watch"),
            message: Text("Please reconfirm the bolus amount.", comment: "Alert message for updated bolus recommendation on Apple Watch"),
            dismissButton: .default(Text("OK"))
        )
    }

    private func communicationErrorAlert(for error: CarbAndBolusFlowViewModel.Error) -> SwiftUI.Alert {
        let dismissAction: () -> Void
        switch error {
        case .potentialCarbEntryMessageSendFailure:
            dismissAction = {}
        case .bolusMessageSendFailure:
            dismissAction = { self.bolusConfirmationProgress = 0 }
        }

        return SwiftUI.Alert(
            title: Text(error.failureReason!),
            message: Text(error.recoverySuggestion!),
            dismissButton: .default(Text("OK"), action: dismissAction)
        )
    }
}

extension CarbAndBolusFlow.AlertState: Hashable, Identifiable {
    var id: Self { self }
}
