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

    /// PRIMING vs NEWS. The screen opens showing a SEEDED recommendation — `activeContext`'s, up to
    /// a loop cycle old — and the loan paths then compute a fresh one. That first computed value
    /// REPLACES the seed; it is not a change the user needs to reconfirm. The view could not tell
    /// the difference, so it raised "Bolus Recommendation Updated · Please reconfirm the bolus
    /// amount" on essentially every bolus (Jeremy, field 2026-08-05: "this now appears before every
    /// bolus attempt which seems clunky").
    ///
    /// It fired even when the number was IDENTICAL, because `@Published` publishes on every
    /// assignment regardless of equality — the phone path guards against exactly that (:275) and
    /// the loan path I added did not. Both defects are closed here: `publishComputedRecommendation`
    /// dedupes like the phone path, and flags the first computed publish as priming.
    ///
    /// The alert itself is still right for its real purpose — a recommendation that moves WHILE the
    /// user is looking at it, which is why it also boots them out of the crown ceremony. Firing it
    /// on routine open-time refresh is what made it noise, and noise is what makes a real change
    /// invisible.
    private var pendingPrimingPublish = false
    private var hasPublishedComputedRecommendation = false

    /// Read-and-clear: was the value the view just received a priming publish?
    func consumeRecommendationPriming() -> Bool {
        defer { pendingPrimingPublish = false }
        return pendingPrimingPublish
    }

    /// The single seam through which the loan paths publish a computed recommendation.
    private func publishComputedRecommendation(_ amount: Double?) {
        let isFirst = !hasPublishedComputedRecommendation
        hasPublishedComputedRecommendation = true
        // Same guard the phone path uses: an identical value is not an update, and publishing it
        // would raise the reconfirm alert for nothing.
        guard recommendedBolusAmount != amount else { return }
        // Set BEFORE the assignment — Combine delivers to the view off the publish, so the flag has
        // to be true by the time `handleNewBolusRecommendation` reads it.
        pendingPrimingPublish = isFirst
        recommendedBolusAmount = amount
    }

    /// Set once the user reaches the crown-confirmation step. From there the amount is
    /// committed, so a recommendation that keeps changing is useless — and actively harmful.
    ///
    /// The `.carbEntry` arm of the context observer re-fires `recommendBolus` on EVERY loop
    /// cycle (and a loan posts one context per cycle, plus another from `activeContext`'s
    /// didSet). Each re-fire flips `isComputingRecommendedBolus`, which republishes through
    /// `@ObservedObject` and rebuilds `CarbAndBolusFlow.body` — constructing a BRAND NEW
    /// `BolusConfirmationView`, whose `resetProgress` PeriodicPublisher is a `let` and is
    /// therefore recreated and re-subscribed. That is the asymmetry behind "spinning the crown
    /// to bolus from carb delivery doesn't complete the spin" (Jeremy, on-wrist 2026-08-04):
    /// the `.manualBolus` arm never re-fires, so the standalone bolus is quiet and its spin
    /// lands. The crown SETTINGS were always identical — the churn was not.
    private var isAwaitingBolusConfirmation = false

    /// The flow reached the crown-confirmation step; stop soliciting recommendations.
    func beginBolusConfirmation() {
        isAwaitingBolusConfirmation = true
    }

    /// The user backed out of confirmation; recommendations may resume.
    func endBolusConfirmation() {
        isAwaitingBolusConfirmation = false
    }

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
    ///
    /// 2026-08-07: latching was not enough — the LATCHING READ ITSELF was `queue.sync` on MAIN,
    /// in this initialiser, i.e. at the instant the user opens the carb/bolus flow. That queue
    /// doubles as the pump's delegate queue and is held for the whole radio round-trip of a dose
    /// (up to ~15s; an E4 reclaim + bolus + release spans ~22s in the field log). So opening the
    /// carb screen during any pod work froze the UI for the length of that work. Field
    /// 2026-08-07, build 249: carbs entered fine, then "when I next checked it was frozen", and
    /// the app was terminated with the loan still open. Now reads the lock-guarded mirror, which
    /// is what every other UI-side caller already uses.
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
        // NON-BLOCKING: this runs on MAIN when the flow opens — see `wasOnLoanAtOpen`.
        let onLoan = session.loanController.isLoanActiveNonBlocking
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

        // FRESH ON OPEN, not once per cycle (field 2026-08-05: "bolus recommendation in sport
        // mode is a bit sluggish to update — even when the glance has the new IOB and the new
        // prediction, the recommendation doesn't").
        //
        // He is describing a real defect, not lag. The seed above comes from
        // activeContext.recommendedBolusDose, which publishHUDContext fills ONCE PER LOOP CYCLE
        // — so on opening the screen it can be five minutes old, computed against IOB that has
        // since changed. The glance looks live by comparison because it reads glanceData() on
        // every 2s tick. A dosing recommendation that stale is worse than no recommendation,
        // because it looks current.
        //
        // So recompute now, on the watch, at the moment the user is actually looking at it.
        // Loan only: off-loan the phone owns the number and pushes it, exactly as in stock.
        if onLoan, case .manualBolus = configuration {
            refreshLoanBolusRecommendation()
        }

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
                if !wasContextGeneratedFromPotentialCarbEntryMessage,
                   !self.isAwaitingBolusConfirmation,
                   let entry = self.carbEntryUnderConsideration {
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
        recommendationRequestToken += 1
        let token = recommendationRequestToken

        // #47. During a loan this asked the PHONE, and the phone has been paused since the grant:
        // its IOB, COB and prediction are the ones it held when it handed the pod over. So its
        // answer was not merely stale, it was computed from the wrong device's books — and the
        // failure was silent. A missing reply leaves `recommendedBolusAmount` nil, nil leaves the
        // dial at 0, and at 0 the flow's action button is `addCarbsWithoutBolusing()`
        // (CarbAndBolusFlow:242): carbs saved, bolus screen skipped, nothing said. Field
        // 2026-08-05: "it seems to just skip right past that, and it's not clear the Bolus is
        // being delivered or what." With the phone out of range that is the ONLY outcome, which
        // is precisely the case Sport Mode exists for.
        if wasOnLoanAtOpen {
            recommendLoanBolus(for: entry, token: token)
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

    /// Ask the WATCH for a recommendation right now (loan only). Mirrors what the phone does
    /// off-loan: compute against current state when the screen opens, rather than serving a
    /// number cached by the last loop cycle.
    private func refreshLoanBolusRecommendation() {
        isComputingRecommendedBolus = true
        ExtensionDelegate.shared().stockLoopSession.stack.loopManager.recommendManualBolus { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, !self.hasSentConfirmationMessage else { return }
                self.isComputingRecommendedBolus = false
                switch result {
                case .success(let recommendation):
                    SportLog.event("bolus-ui", String(format: "REC refreshed on open: %.2f U", recommendation.amount))
                    self.publishComputedRecommendation(recommendation.amount)
                case .failure(let error):
                    // Leave whatever the context seeded rather than blanking a usable number:
                    // the guards inside recommendManualBolus (momentum/carb/insulin effects) go
                    // unsatisfied in the first cycles of a loan, and a stale-but-real value beats
                    // "REC: – U" there. Said out loud so it is never inferred from silence.
                    SportLog.event("bolus-ui", "REC refresh on open FAILED — \(error) (keeping the cycle's value)")
                }
            }
        }
    }

    /// #47 loan path: the meal-bolus recommendation computed on the WATCH, with the unsaved entry
    /// folded into the watch's own prediction. Same shape as `refreshLoanBolusRecommendation`,
    /// but carb-aware — which also switches the target range to the pre-meal range, so it is a
    /// genuinely different recommendation and not just "manual bolus plus some carbs".
    private func recommendLoanBolus(for entry: NewCarbEntry, token: Int) {
        isComputingRecommendedBolus = true
        ExtensionDelegate.shared().stockLoopSession.stack.loopManager.recommendManualBolus(potentialCarbEntry: entry) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Superseded by a newer request, which now owns the spinner — drop this reply
                // rather than clearing a flag we no longer own (same discipline as the phone path).
                guard token == self.recommendationRequestToken else { return }
                self.isComputingRecommendedBolus = false

                guard entry == self.carbEntryUnderConsideration else { return }

                switch result {
                case .success(let recommendation):
                    SportLog.event("bolus-ui", String(format: "REC carb %.0fg (watch-local): %.2f U",
                                                      entry.quantity.doubleValue(for: .gram()), recommendation.amount))
                    self.publishComputedRecommendation(recommendation.amount)
                case .failure(let error):
                    // Leave it nil and SAY so. nil means the dial sits at 0 and the action button
                    // reads "Save" rather than "Save and Bolus" — the user can still dial a bolus
                    // by hand on this same screen, so this is a degraded recommendation rather
                    // than a trap. But it is exactly the state that used to arrive silently, so
                    // it never gets to be inferred from an empty log again.
                    SportLog.event("bolus-ui", "REC carb (watch-local) FAILED — \(error) · dial stays 0, button reads Save")
                    self.recommendedBolusAmount = nil
                }
            }
        }
    }

    /// A durable local notification for a loan-time bolus failure — survives the flow's
    /// auto-dismiss, the app backgrounding, and a lowered wrist.
    /// `carbGrams` non-nil means carbs were ALREADY journaled before the bolus was attempted —
    /// the trap case. The user cannot recover by re-running the carb flow (it would double-log,
    /// which is why the send window is deliberately not re-opened), so the notification has to
    /// say both that the carbs landed and that the bolus must be delivered from the plain Bolus
    /// screen. Field 2026-08-05 00:18: 6 g journaled, 0.20 U lost, and nothing said what to do.
    private static func notifyBolusFailure(units: Double, carbGrams: Double?, error: Swift.Error) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Bolus Not Delivered", comment: "Watch notification title for a failed loan-time bolus")
        let unitsText = NumberFormatter.localizedString(from: NSNumber(value: units), number: .decimal)
        if let carbGrams = carbGrams {
            content.body = String(
                format: NSLocalizedString("%1$@ g was logged, but %2$@ U did not deliver. Use the Bolus screen to deliver it — do NOT re-enter the carbs.", comment: "Watch notification body when carbs logged but the bolus failed (1: grams, 2: units)"),
                NumberFormatter.localizedString(from: NSNumber(value: Int(carbGrams.rounded())), number: .none),
                unitsText)
        } else {
            content.body = String(
                format: NSLocalizedString("%1$@ U did not deliver. %2$@", comment: "Watch notification body for a failed loan-time bolus (1: units, 2: reason)"),
                unitsText, error.localizedDescription)
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "loan.bolus.failure", content: content, trigger: nil))
    }

    private func sendSetBolusUserInfo(carbEntry: NewCarbEntry?, bolus: Double) {
        RuntimeStateLog.mark("carbflow.sendSetBolusUserInfo")
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
        RuntimeStateLog.mark("carbflow.deliveryGate(isLoanActive SYNC)")
        if session.loanController.isLoanActive {
            RuntimeStateLog.mark("carbflow.deliveryGate.passed")
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
                        // FAILURE always buzzes: the pod beeps only when it ACCEPTS, so a
                        // bolus that never reached it is silent — and silence would otherwise
                        // mean both "still working" and "it failed". This is the one signal
                        // nothing else carries.
                        WKInterfaceDevice.current().play(.failure)
                        Self.notifyBolusFailure(units: units, carbGrams: carbEntry?.quantity.doubleValue(for: .gram()), error: error)
                        ExtensionDelegate.shared().present(error)
                    } else if !session.stack.loopManager.podBeepsOnManualBolus {
                        // SUCCESS only when the pod is silent. With beeps on, the pod's
                        // acknowledgement beep fires at this same instant and says the same
                        // thing — two signals, one event, no added meaning (Jeremy 2026-08-05).
                        WKInterfaceDevice.current().play(.success)
                    }
                }
            } else if carbEntry != nil {
                WKInterfaceDevice.current().play(.success)
            }
            // DWELL, sized to what is actually happening (field 2026-08-06: carbs-only "sits on
            // that view for a second or two"). A BOLUS has a pod command in flight, so the hold
            // covers real work and gives the ceremony's completion state time to register. A
            // carbs-only save has already finished — the store write is local and synchronous —
            // so the same hold is dead time stacked on top of a ceremony the user just completed
            // by hand. Long enough to see the ring close, short enough not to feel stuck.
            let dwell: TimeInterval = bolus > 0 ? 1.0 : 0.4
            DispatchQueue.main.asyncAfter(deadline: .now() + dwell) {
                RuntimeStateLog.mark("carbflow.dwellDismiss")
                self.dismiss()
                // Land on the glance, not the stock HUD (Jeremy 2026-08-05). This flow is
                // presented FROM HUDInterfaceController, so dismiss() returns there — one swipe
                // away from the screen that carries the dose's own status ("reaching pod…",
                // "delivering"). StockLoopSession already rules the glance "the landing surface
                // during a loan" (:154) and calls this on takeover; it just was never applied
                // here. Loan only — outside one the stock HUD is the correct home.
                if ExtensionDelegate.shared().stockLoopSession.loanController.isLoanActiveNonBlocking {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        RuntimeStateLog.mark("carbflow.becomeCurrentPage")
                        GlanceController.current?.becomeCurrentPage()
                    }
                }
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

            // Flat 1s here, deliberately: this is the PHONE-RELAY path, where the carb entry is
            // still in flight and its confirmation arrives in sendBolusMessage's reply handler.
            // Shortening the dwell would dismiss before the ack — the original no-feedback bug.
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
