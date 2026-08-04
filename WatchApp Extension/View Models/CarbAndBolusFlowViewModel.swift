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
import UserNotifications
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
    /// Monotonic token identifying the newest in-flight recommendation request.
    ///
    /// The spinner used to be stranded by a STALE reply: the `defer` that clears
    /// `isComputingRecommendedBolus` sits AFTER the entry-equality guard, so a reply that did
    /// not match the current entry returned without ever clearing it — a permanent
    /// "REC: Calculating…" with the phone perfectly reachable. Mismatches are routine, not
    /// exotic: the context observer re-fires `recommendBolus` on EVERY loop cycle while the
    /// screen is open, so adjusting the dial puts two requests in flight and the older reply
    /// strands the flag. Only the newest request may touch the spinner or the value.
    private var recommendationRequestToken = 0

    // MARK: - Constants
    private static let defaultSupportedBolusVolumes = (0...600).map { 0.05 * Double($0) } // U
    private static let defaultMaxBolus: Double = 10 // U

    /// Whether the pod was on loan when this flow opened, latched once.
    ///
    /// Latched rather than live-read for two reasons. (1) `isLoanActive` is `queue.sync` onto
    /// the loan controller's serial queue — the same queue that runs the ~40s takeover ladder —
    /// and the context observer below runs on the MAIN thread on every loop cycle, so a live
    /// read there would put a main-thread hop onto a busy queue several times a minute.
    /// (2) The dial's ceiling must not move under the user's thumb mid-entry. Delivery still
    /// re-reads the LIVE gate at the moment it commits (see `sendSetBolusUserInfo`), which is
    /// the read that actually decides where insulin is commanded from.
    private let wasOnLoanAtOpen: Bool

    /// The dial's ceiling and increment ladder.
    ///
    /// During a loan the authority for the ceiling is the GRANT's therapy maximumBolus. The HUD
    /// `LoopDataManager.settings` is a different object whose only writer is a settings message
    /// the phone pushes, so in Sport Mode it is either stale or — on a watch that has never been
    /// in range of the phone — the hardcoded 10 U default. Both directions are wrong: below the
    /// prescribed max the user cannot dial it, above it the dial accepts an amount that
    /// `enactManualBolus` then refuses after the screen has dismissed.
    private static func pickerValues(hud: LoopDataManager, grantedMaxBolus: Double?) -> BolusPickerValues {
        BolusPickerValues(
            supportedVolumes: hud.supportedBolusVolumes ?? defaultSupportedBolusVolumes,
            maxBolus: grantedMaxBolus ?? hud.settings.maximumBolus ?? defaultMaxBolus
        )
    }

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

        let session = ExtensionDelegate.shared().stockLoopSession
        let onLoan = session.loanController.isLoanActive
        let grantedMaxBolus = onLoan ? session.stack.loopManager.grantedMaximumBolus : nil
        self.wasOnLoanAtOpen = onLoan

        self._bolusPickerValues = Published(
            initialValue: Self.pickerValues(hud: loopManager, grantedMaxBolus: grantedMaxBolus)
        )

        SportLog.event("bolus-ui", String(
            format: "flow open · %@ · dial max %.2f U (%@)",
            onLoan ? "ON LOAN" : "phone-owned",
            grantedMaxBolus ?? loopManager.settings.maximumBolus ?? Self.defaultMaxBolus,
            grantedMaxBolus != nil ? "grant" : (loopManager.settings.maximumBolus != nil ? "phone-pushed" : "DEFAULT 10U — phone never seen")
        ))

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
            
            // `wasOnLoanAtOpen` is latched, so this observer — which runs on MAIN on every
            // loop cycle — never touches the loan controller's queue.
            self.bolusPickerValues = Self.pickerValues(
                hud: loopManager,
                grantedMaxBolus: self.wasOnLoanAtOpen
                    ? ExtensionDelegate.shared().stockLoopSession.stack.loopManager.grantedMaximumBolus
                    : nil
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
        let potentialEntry = PotentialCarbEntryUserInfo(carbEntry: entry)
        recommendationRequestToken += 1
        let token = recommendationRequestToken
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

                        // Superseded by a newer request, which now owns the spinner — drop this
                        // reply entirely rather than clearing a flag we no longer own.
                        guard token == self.recommendationRequestToken else {
                            return
                        }

                        // Clear FIRST, unconditionally: this is the newest request, so whatever
                        // else is true about the reply, the screen is no longer computing.
                        self.isComputingRecommendedBolus = false

                        // Only publish if the recommendation corresponds to the entry under
                        // consideration (kept for the VALUE; it no longer gates the spinner).
                        guard context.potentialCarbEntry == self.carbEntryUnderConsideration else {
                            return
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
                        guard let self = self, token == self.recommendationRequestToken else { return }
                        self.isComputingRecommendedBolus = false
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

    /// A durable local notification for a loan-time bolus failure — survives the
    /// flow's auto-dismiss, the app backgrounding, and a lowered wrist.
    private static func notifyBolusFailure(units: Double, error: Swift.Error) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Bolus Not Delivered", comment: "Watch notification title for a failed loan-time bolus")
        content.body = String(
            format: NSLocalizedString("%1$@ U did not deliver. %2$@", comment: "Watch notification body for a failed loan-time bolus (1: units, 2: reason)"),
            NumberFormatter.localizedString(from: NSNumber(value: units), number: .decimal),
            error.localizedDescription)
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "loan.bolus.failure", content: content, trigger: nil))
    }

    private func sendSetBolusUserInfo(carbEntry: NewCarbEntry?, bolus: Double) {
        guard !hasSentConfirmationMessage else {
            return
        }
        self.hasSentConfirmationMessage = true

        // PODLOAN (R5): during an active loan the PHONE's pod link is released — a
        // bolus relayed there dies undelivered (found on-wrist 2026-07-18). Deliver
        // on the WATCH's pump; carbs go BOTH to the local store (this loop's COB
        // sees them now) and to the phone via the stock relay (the durable record,
        // bolus zeroed so nothing double-delivers).
        let session = ExtensionDelegate.shared().stockLoopSession
        if session.loanController.isLoanActive {
            let activationType: BolusActivationType = .activationTypeFor(recommendedAmount: recommendedBolusAmount, bolusAmount: bolus)
            if let carbEntry = carbEntry {
                // Local store (this loop's COB sees it now) + a CONFIRMED journal
                // record (rides the resend-until-ack channel to the phone's carb
                // store — durable even with the phone unreachable, which is the
                // whole point of Sport Mode).
                session.stack.loopManager.addLoanCarbEntry(carbEntry)
                session.loanController.loanDidRecordCarbs(carbEntry)
            }
            if bolus > 0 {
                let units = bolus
                session.stack.loopManager.enactManualBolus(units: units, activationType: activationType) { error in
                    if let error = error {
                        // LOUD certain-failure surfacing: the enact completion can
                        // land tens of seconds after the 1s auto-dismiss with the
                        // wrist down — a transient alert alone reads as delivered.
                        // (Do NOT re-open the send window: carbs are already
                        // journaled; a re-tap would double-log them.)
                        WKInterfaceDevice.current().play(.failure)
                        Self.notifyBolusFailure(units: units, error: error)
                        ExtensionDelegate.shared().present(error)
                    } else {
                        WKInterfaceDevice.current().play(.success)
                    }
                }
            } else if carbEntry != nil {
                WKInterfaceDevice.current().play(.success)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
                self.dismiss()
            }
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
