//
//  CarbAndBolusFlowViewModel.swift
//  WatchApp Extension
//
//  Created by Michael Pangburn on 3/31/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import Foundation
import Combine
import LoopAlgorithm
import WatchKit
import WatchConnectivity
import UserNotifications
import LoopKit
import LoopCore

@MainActor
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
    private var contextDate: Date?

    // MARK: - Constants
    private static let defaultSupportedBolusVolumes = (0...600).map { 0.05 * Double($0) } // U
    private static let defaultMaxBolus: Double = 10 // U

    // MARK: - Initialization
    let configuration: CarbAndBolusFlow.Configuration

    init(
        configuration: CarbAndBolusFlow.Configuration
    ) {
        let loopManager = LoopDataManager.shared
        self.configuration = configuration

        self._bolusPickerValues = Published(
            initialValue: BolusPickerValues(
                supportedVolumes: loopManager.supportedBolusVolumes ?? Self.defaultSupportedBolusVolumes,
                maxBolus: Self.activeMaxBolus(loopManager)
            )
        )

        switch configuration {
        case .carbEntry:
            break
        case .manualBolus:
            // If we start out on the manual bolus screen, fetch a fresh recommendation immediately
            Task { @MainActor in
                await recommendBolus()
            }
        }

        contextUpdateObservation = NotificationCenter.default.addObserver(
            forName: LoopDataManager.didUpdateContextNotification,
            object: loopManager,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleContextUpdate(loopManager: loopManager)
            }
        }
    }

    func handleContextUpdate(loopManager: LoopDataManager) {

        self.bolusPickerValues = BolusPickerValues(
            supportedVolumes: loopManager.supportedBolusVolumes ?? Self.defaultSupportedBolusVolumes,
            maxBolus: Self.activeMaxBolus(loopManager)
        )

        switch self.configuration {
        case .carbEntry:
            // If this new context wasn't generated in response to a potential carb entry message,
            // recompute the recommended bolus for the carb entry under consideration.
            let wasContextGeneratedFromPotentialCarbEntryMessage = loopManager.activeContext?.potentialCarbEntry != nil
            if !wasContextGeneratedFromPotentialCarbEntryMessage, let entry = self.carbEntryUnderConsideration {
                Task { @MainActor in
                    await self.recommendBolus(with: entry)
                }
            }
        case .manualBolus:
            let activeContext = loopManager.activeContext
            self.contextDate = activeContext?.creationDate
            if self.recommendedBolusAmount != activeContext?.recommendedBolusDose {
                self.recommendedBolusAmount = activeContext?.recommendedBolusDose
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

    func recommendBolus(forGrams grams: Int, eatenAt carbEntryDate: Date, absorptionTime carbAbsorptionTime: CarbAbsorptionTime, lastEntryDate: Date) async {
        let entry = NewCarbEntry(
            date: lastEntryDate,
            quantity: LoopQuantity(unit: .gram, doubleValue: Double(grams)),
            startDate: carbEntryDate,
            foodType: carbAbsorptionTime.emoji,
            absorptionTime: absorptionTime(for: carbAbsorptionTime)
        )

        guard entry.quantity.doubleValue(for: .gram) > 0 else {
            return
        }

        carbEntryUnderConsideration = entry
        await recommendBolus(with: entry)
    }

    private func recommendBolus(with entry: NewCarbEntry? = nil) async {
        // DURING A LOAN THE PHONE IS THE WRONG DEVICE TO ASK. It released its pod link at the
        // grant and its books have been frozen since, so its IOB, COB and prediction are the ones
        // it held when it handed the pod over — an answer computed from the wrong device's data.
        // With the phone switched off it cannot answer at all, which is exactly the case Sport
        // Mode exists for, and the failure surfaces as "Unable to Reach iPhone" at the bolus step
        // (field 2026-08-16, 23:33, phone off deliberately).
        //
        // The watch holds the pod, ran the loop, and owns the only current books — so it computes
        // its own recommendation.
        if let session = ExtensionDelegate.sharedIfAvailable()?.stockLoopSession,
           session.loanController.isLoanActive {
            await recommendLoanBolus(with: entry, session: session)
            return
        }

        do {
            isComputingRecommendedBolus = true
            let context = try await WCSession.default.fetchBolusRecommendation(entry)

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
        } catch {
            isComputingRecommendedBolus = false
            WKInterfaceDevice.current().play(.failure)
            self.error = .potentialCarbEntryMessageSendFailure
        }
    }


    /// The maximum the picker may offer. DURING A LOAN THIS IS THE GRANT'S, not the phone's.
    ///
    /// The phone's value arrives in a WatchContext and is whatever it last relayed — which during
    /// a loan can be stale, and with the phone off cannot be refreshed at all. The enact path
    /// already clamps against the granted maximum, so a picker offering more than the grant allows
    /// does not deliver an unsafe dose; it offers a dose that is then refused, which reads as a
    /// failure rather than as a limit.
    private static func activeMaxBolus(_ loopManager: LoopDataManager) -> Double {
        if let session = ExtensionDelegate.sharedIfAvailable()?.stockLoopSession,
           session.loanController.isLoanActiveNonBlocking,
           let granted = session.stack.loopManager.grantedMaximumBolus {
            return granted
        }
        return loopManager.watchInfo.loopSettings.maximumBolus ?? Self.defaultMaxBolus
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

    func addCarbsWithoutBolusing() async throws {
        guard let carbEntry = carbEntryUnderConsideration else {
            assertionFailure("Attempting to add carbs without a carb entry")
            return
        }

        try await sendSetBolusUserInfo(carbEntry: carbEntry, bolus: 0)
    }

    func addCarbsAndDeliverBolus(_ bolusAmount: Double) async throws {
        try await sendSetBolusUserInfo(carbEntry: carbEntryUnderConsideration, bolus: bolusAmount)
    }

    /// Shared so a verdict path can retract this once the pod's answer is in.
    static let bolusUnconfirmedNotificationID = "loan.bolus.failure"

    /// A bolus the wrist could not confirm. The pod beeps only when it ACCEPTS, so a bolus that
    /// never reached it is SILENT — and silence would otherwise mean both "still working" and
    /// "it failed". This is the one signal nothing else carries.
    private static func notifyBolusFailure(units: Double, carbGrams: Double?, error: Swift.Error) {
        let content = UNMutableNotificationContent()
        let unitsText = NumberFormatter.localizedString(from: NSNumber(value: units), number: .decimal)
        content.title = String(
            format: NSLocalizedString("Bolus Unconfirmed: %@ U", comment: "Watch notification title for a loan-time bolus whose delivery could not be confirmed (1: units)"),
            unitsText)
        if let carbGrams = carbGrams {
            content.body = String(
                format: NSLocalizedString("%@ g was saved. Loop couldn't confirm delivery. You can wait to see if it resolves.", comment: "Watch notification body when carbs were saved but bolus delivery is unconfirmed (1: grams)"),
                NumberFormatter.localizedString(from: NSNumber(value: Int(carbGrams.rounded())), number: .none))
        } else {
            // The error text goes to the LOG, not the lock screen: these are PodCommsError /
            // PumpManagerError values whose localizedDescription is developer copy of
            // unpredictable length.
            content.body = NSLocalizedString("Loop couldn't confirm delivery. You can wait to see if it resolves.", comment: "Watch notification body when a loan-time bolus delivery is unconfirmed")
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.bolusUnconfirmedNotificationID, content: content, trigger: nil))
    }

    /// The watch-local twin of the phone round-trip above, for a live loan.
    ///
    /// A FAILURE HERE IS SAID OUT LOUD rather than left to be inferred. Leaving the amount nil
    /// sits the dial at 0, and at 0 the flow's action button reads "Save" instead of "Save and
    /// Bolus" — carbs are stored, the bolus screen is skipped, and nothing announces that a
    /// recommendation was never computed. That is a degraded recommendation, not a trap (the user
    /// can still dial a dose by hand on this same screen), but it must never arrive silently.
    private func recommendLoanBolus(with entry: NewCarbEntry?, session: StockLoopSession) async {
        isComputingRecommendedBolus = true
        defer { isComputingRecommendedBolus = false }

        let result: Swift.Result<ManualBolusRecommendation, Swift.Error> = await withCheckedContinuation { continuation in
            session.stack.loopManager.recommendManualBolus(potentialCarbEntry: entry) { result in
                continuation.resume(returning: result)
            }
        }

        // Superseded while we were computing — the entry under consideration moved on, so this
        // answer describes carbs the user is no longer entering.
        guard entry == carbEntryUnderConsideration else { return }

        switch result {
        case .success(let recommendation):
            SportLog.event("bolus-ui", String(format: "REC carb %.0fg (watch-local): %.2f U",
                                              entry?.quantity.doubleValue(for: .gram) ?? 0,
                                              recommendation.amount))
            if recommendedBolusAmount != recommendation.amount {
                recommendedBolusAmount = recommendation.amount
            }
        case .failure(let error):
            SportLog.event("bolus-ui", "REC carb (watch-local) FAILED — \(error) · dial stays 0, button reads Save")
            recommendedBolusAmount = nil
        }
    }

    private func sendSetBolusUserInfo(carbEntry: NewCarbEntry?, bolus: Double) async throws {
        // PODLOAN: during an active loan the PHONE has RELEASED its pod link, so a bolus relayed
        // there dies undelivered — found on the wrist 2026-07-18, and again on this branch
        // 2026-08-16 when two boluses entered from these screens reached neither the pod nor the
        // phone's books. Deliver on the WATCH's pump instead.
        //
        // Carbs take both paths deliberately: the LOCAL store so this loop's COB sees them on the
        // very next cycle, and the loan JOURNAL — resend-until-ack — as the durable record that
        // reaches the phone even while it is unreachable, which is the entire point of Sport Mode.
        // The stock WC relay is skipped, not merely zeroed: it cannot deliver and its carb write
        // would race the journal's.
        if let session = ExtensionDelegate.sharedIfAvailable()?.stockLoopSession,
           session.loanController.isLoanActive {
            let activationType: BolusActivationType = .activationTypeFor(recommendedAmount: recommendedBolusAmount, bolusAmount: bolus)
            if let carbEntry = carbEntry {
                session.stack.loopManager.addLoanCarbEntry(carbEntry)
                session.loanController.loanDidRecordCarbs(carbEntry)
            }
            if bolus > 0 {
                let units = bolus
                session.stack.loopManager.enactManualBolus(units: units, activationType: activationType) { error in
                    if let error = error {
                        // FAILURE always buzzes — see notifyBolusFailure. Deliberately does NOT
                        // re-open the send window: the carbs are already journaled, so a re-tap
                        // would double-log them.
                        WKInterfaceDevice.current().play(.failure)
                        SportLog.event("bolus-ui", String(
                            format: "USER ALERTED 'Bolus Unconfirmed' — %.2f U did not confirm%@ · reason: %@ · haptic=failure",
                            units,
                            carbEntry.map { String(format: " (%.0f g ALREADY logged)", $0.quantity.doubleValue(for: .gram)) } ?? "",
                            error.localizedDescription))
                        Self.notifyBolusFailure(units: units,
                                                carbGrams: carbEntry?.quantity.doubleValue(for: .gram),
                                                error: error)
                    } else if !session.stack.loopManager.podBeepsOnManualBolus {
                        // Success haptic ONLY when the pod is silent. With beeps on, the pod's
                        // acknowledgement fires at this same instant and says the same thing.
                        WKInterfaceDevice.current().play(.success)
                    }
                }
            } else if carbEntry != nil {
                WKInterfaceDevice.current().play(.success)
            }
            return
        }

        let bolus = SetBolusUserInfo(value: bolus, startDate: Date(), contextDate: self.contextDate, carbEntry: carbEntry, activationType: .activationTypeFor(recommendedAmount: recommendedBolusAmount, bolusAmount: bolus))
        let updatedContext = try await WCSession.default.sendBolusMessage(bolus)
        if bolus.carbEntry != nil {
            if bolus.value == 0 {
                // Notify for a successful carb entry (sans bolus)
                WKInterfaceDevice.current().play(.success)
            }
        }
        LoopDataManager.shared.updateContext(updatedContext)
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
