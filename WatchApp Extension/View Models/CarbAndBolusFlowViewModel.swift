//
//  CarbAndBolusFlowViewModel.swift
//  WatchApp Extension
//
//  Created by Michael Pangburn on 3/31/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import Foundation
import Combine
import HealthKit
import WatchKit
import WatchConnectivity
import LoopKit
import LoopCore


final class CarbAndBolusFlowViewModel: ObservableObject {
    enum Error: Swift.Error {
        case potentialCarbEntryMessageSendFailure
        case bolusMessageSendFailure
    }

    // MARK: - Published state
    @Published var isComputingRecommendedBolus = false
    @Published var recommendedBolusAmount: Double?
    @Published var bolusPickerValues: BolusPickerValues
    @Published var error: Error?

    // MARK: - Other state
    let interactionStartDate = Date()
    private var carbEntryUnderConsideration: NewCarbEntry?
    private var contextUpdateObservation: AnyObject?
    private var hasSentConfirmationMessage = false
    private var contextDate: Date?

    // MARK: - Constants
    private static let defaultSupportedBolusVolumes = (0...600).map { 0.05 * Double($0) } // U
    // H18: the dial's pre-sync fallback max MUST equal the Sport Mode delivery
    // clamp (WatchPodLoanCoordinator.maxBolusUnits, same fallback), or the dial
    // lets the user pick e.g. 5 U while the pod command silently clamps to 1 U
    // with a success haptic — a silent under-bolus. One source of truth.
    private static let defaultMaxBolus: Double = WatchPodLoanCoordinator.fallbackMaxBolusUnits // U

    // MARK: - Initialization
    let configuration: CarbAndBolusFlow.Configuration
    private let dismiss: () -> Void

    init(
        configuration: CarbAndBolusFlow.Configuration,
        dismiss: @escaping () -> Void
    ) {
        let loopManager = ExtensionDelegate.shared().loopManager
        switch configuration {
        case .carbEntry:
            break
        case .manualBolus:
            let activeContext = loopManager.activeContext
            self.contextDate = activeContext?.creationDate
            self._recommendedBolusAmount = Published(initialValue: activeContext?.recommendedBolusDose)
        }

        self._bolusPickerValues = Published(
            initialValue: BolusPickerValues(
                supportedVolumes: loopManager.supportedBolusVolumes ?? Self.defaultSupportedBolusVolumes,
                maxBolus: loopManager.settings.maximumBolus ?? Self.defaultMaxBolus
            )
        )

        self.configuration = configuration
        self.dismiss = dismiss

        contextUpdateObservation = NotificationCenter.default.addObserver(
            forName: LoopDataManager.didUpdateContextNotification,
            object: loopManager,
            queue: nil
        ) { [weak self] _ in
            guard
                let self = self,
                !self.hasSentConfirmationMessage
            else {
                return
            }
            
            self.bolusPickerValues = BolusPickerValues(
                supportedVolumes: loopManager.supportedBolusVolumes ?? Self.defaultSupportedBolusVolumes,
                maxBolus: loopManager.settings.maximumBolus ?? Self.defaultMaxBolus
            )

            switch self.configuration {
            case .carbEntry:
                // If this new context wasn't generated in response to a potential carb entry message,
                // recompute the recommended bolus for the carb entry under consideration.
                let wasContextGeneratedFromPotentialCarbEntryMessage = loopManager.activeContext?.potentialCarbEntry != nil
                if !wasContextGeneratedFromPotentialCarbEntryMessage, let entry = self.carbEntryUnderConsideration {
                    self.recommendBolus(for: entry)
                }
            case .manualBolus:
                let activeContext = loopManager.activeContext
                self.contextDate = activeContext?.creationDate
                if self.recommendedBolusAmount != activeContext?.recommendedBolusDose {
                    self.recommendedBolusAmount = activeContext?.recommendedBolusDose
                }
            }
        }
    }

    deinit {
        if let observation = contextUpdateObservation {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    func discardCarbEntryUnderConsideration() {
        carbEntryUnderConsideration = nil
        recommendedBolusAmount = nil
    }

    func recommendBolus(forGrams grams: Int, eatenAt carbEntryDate: Date, absorptionTime carbAbsorptionTime: CarbAbsorptionTime, lastEntryDate: Date) {
        let entry = NewCarbEntry(
            date: lastEntryDate,
            quantity: HKQuantity(unit: .gram(), doubleValue: Double(grams)),
            startDate: carbEntryDate,
            foodType: carbAbsorptionTime.emoji,
            absorptionTime: absorptionTime(for: carbAbsorptionTime)
        )

        guard entry.quantity.doubleValue(for: .gram()) > 0 else {
            return
        }

        carbEntryUnderConsideration = entry
        recommendBolus(for: entry)
    }

    private func recommendBolus(for entry: NewCarbEntry) {
        // SPORT MODE: the phone is away, so compute the meal-bolus recommendation LOCALLY
        // with the watch's own prediction engine — the SAME stock algorithm the phone
        // runs — with this carb injected. UI-driven, so on the main actor.
        if MainActor.assumeIsolated({ ExtensionDelegate.shared().podLoanCoordinator.phase == .active }) {
            MainActor.assumeIsolated {
                // C12: same recency gate as the phone's manual-bolus path
                // (recommendBolusValidatingDataRecency → glucoseTooOld) and the
                // auto-loop's enact gate. A missing or stale anchor produces NO
                // recommendation — never a dose computed from old glucose, and
                // never a fabricated placeholder BG. Carbs still log; the user
                // can still dial a bolus from their own judgment.
                let store = ExtensionDelegate.shared().predictionStore
                guard let anchorBG = store.anchorSample?.quantity, !store.isAnchorStale else {
                    self.recommendedBolusAmount = nil
                    return
                }
                self.isComputingRecommendedBolus = true
                let engine = WatchPredictionEngine(loopManager: ExtensionDelegate.shared().loopManager,
                                                   coordinator: ExtensionDelegate.shared().podLoanCoordinator)
                // storeEntry:false → the algorithm anchors on the stored G7 series; manualBG is
                // display-only here.
                engine.predict(manualBG: anchorBG, storeEntry: false, pendingCarb: entry) { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        self.isComputingRecommendedBolus = false
                        // Bound the shown recommendation by the same therapy max-bolus the pod
                        // command clamp uses (maxBolusUnits = settings.maximumBolus), so display
                        // == delivery. The engine already caps at maximumBolus, so this is
                        // normally a no-op — it just guarantees parity if the two ever skew.
                        let reco = (try? result.get())?.recommendedBolus ?? 0
                        self.recommendedBolusAmount = min(reco, WatchPodLoanCoordinator.maxBolusUnits)
                    }
                }
            }
            return
        }
        let potentialEntry = PotentialCarbEntryUserInfo(carbEntry: entry)
        do {
            isComputingRecommendedBolus = true
            try WCSession.default.sendPotentialCarbEntryMessage(potentialEntry,
                replyHandler: { [weak self] context in
                    DispatchQueue.main.async {
                        let loopManager = ExtensionDelegate.shared().loopManager
                        loopManager.updateContext(context)

                        guard let self = self else {
                            return
                        }

                        // Only update if this recommendation corresponds to the current carb entry under consideration.
                        guard context.potentialCarbEntry == self.carbEntryUnderConsideration else {
                            return
                        }

                        defer {
                            self.isComputingRecommendedBolus = false
                        }

                        self.contextDate = context.creationDate

                        // Don't publish a new value if the recommendation has not changed.
                        guard self.recommendedBolusAmount != context.recommendedBolusDose else {
                            return
                        }

                        self.recommendedBolusAmount = context.recommendedBolusDose
                    }
                },
                errorHandler: { error in
                    DispatchQueue.main.async { [weak self] in
                        self?.isComputingRecommendedBolus = false
                        WKInterfaceDevice.current().play(.failure)
                        ExtensionDelegate.shared().present(error)
                    }
                }
            )
        } catch {
            isComputingRecommendedBolus = false
            self.error = .potentialCarbEntryMessageSendFailure
        }
    }

    private func absorptionTime(for carbAbsorptionTime: CarbAbsorptionTime) -> TimeInterval {
        let defaultTimes = LoopCoreConstants.defaultCarbAbsorptionTimes

        switch carbAbsorptionTime {
        case .fast:
            return defaultTimes.fast
        case .medium:
            return defaultTimes.medium
        case .slow:
            return defaultTimes.slow
        }
    }

    func addCarbsWithoutBolusing() {
        guard let carbEntry = carbEntryUnderConsideration else {
            assertionFailure("Attempting to add carbs without a carb entry")
            return
        }

        sendSetBolusUserInfo(carbEntry: carbEntry, bolus: 0)
    }

    func addCarbsAndDeliverBolus(_ bolusAmount: Double) {
        sendSetBolusUserInfo(carbEntry: carbEntryUnderConsideration, bolus: bolusAmount)
    }

    private func sendSetBolusUserInfo(carbEntry: NewCarbEntry?, bolus: Double) {
        guard !hasSentConfirmationMessage else {
            return
        }
        self.hasSentConfirmationMessage = true

        // SPORT MODE: the phone is away. Store the carb in the WATCH's own carb store +
        // loan journal (so the loop doses for it and it reconciles on hand-back) and send
        // any bolus straight to the pod — instead of messaging the phone. UI-driven, so
        // on the main actor where the coordinator lives.
        let handledInSportMode = MainActor.assumeIsolated { () -> Bool in
            let coordinator = ExtensionDelegate.shared().podLoanCoordinator
            guard coordinator.phase == .active else { return false }
            if let carbEntry { coordinator.logCarb(carbEntry) }
            if bolus > 0 { coordinator.bolus(units: bolus) }
            return true
        }
        if handledInSportMode {
            WKInterfaceDevice.current().play(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { self.dismiss() }
            return
        }

        let bolus = SetBolusUserInfo(value: bolus, startDate: Date(), contextDate: self.contextDate, carbEntry: carbEntry, activationType: .activationTypeFor(recommendedAmount: recommendedBolusAmount, bolusAmount: bolus))
        do {
            try WCSession.default.sendBolusMessage(bolus) { [weak self] (error) in
                DispatchQueue.main.async {
                    if let error = error {
                        ExtensionDelegate.shared().present(error)
                        self?.hasSentConfirmationMessage = false
                    } else {
                        if bolus.carbEntry != nil {
                            if bolus.value == 0 {
                                // Notify for a successful carb entry (sans bolus)
                                WKInterfaceDevice.current().play(.success)
                            }
                        }
                    }
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
                self.dismiss()
            }
        } catch {
            self.error = .bolusMessageSendFailure
        }
    }
}

extension CarbAndBolusFlowViewModel.Error: LocalizedError {
    var failureReason: String? {
        switch self {
        case .potentialCarbEntryMessageSendFailure:
            return NSLocalizedString("Unable to Reach iPhone", comment: "The title of the alert controller displayed after a potential carb entry send attempt fails")
        case .bolusMessageSendFailure:
            return NSLocalizedString("Bolus Failed", comment: "The title of the alert controller displayed after a bolus attempt fails")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .potentialCarbEntryMessageSendFailure:
            return NSLocalizedString("Make sure your iPhone is nearby and try again.", comment: "The recovery message displayed after a potential carb entry send attempt fails")
        case .bolusMessageSendFailure:
            return NSLocalizedString("Make sure your iPhone is nearby and try again.", comment: "The recovery message displayed after a bolus attempt fails")
        }
    }
}

extension CarbAndBolusFlowViewModel.Error: Identifiable {
    var id: Self { self }
}
