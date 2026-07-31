//
//  ActionHUDController.swift
//  Loop
//
//  Created by Nathan Racklyeft on 5/29/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import WatchKit
import WatchConnectivity
import HealthKit
import LoopKit
import LoopCore
import SwiftUI


final class ActionHUDController: HUDInterfaceController {
    @IBOutlet var preMealButton: WKInterfaceButton!
    @IBOutlet var preMealButtonImage: WKInterfaceImage!
    @IBOutlet var preMealButtonBackground: WKInterfaceGroup!
    @IBOutlet var overrideButton: WKInterfaceButton!
    @IBOutlet var overrideButtonImage: WKInterfaceImage!
    @IBOutlet var overrideButtonBackground: WKInterfaceGroup!
    @IBOutlet var carbsButton: WKInterfaceButton!
    @IBOutlet var carbsButtonImage: WKInterfaceImage!
    @IBOutlet var carbsButtonBackground: WKInterfaceGroup!
    @IBOutlet var bolusButton: WKInterfaceButton!
    @IBOutlet var bolusButtonImage: WKInterfaceImage!
    @IBOutlet var bolusButtonBackground: WKInterfaceGroup!

    private lazy var preMealButtonGroup = ButtonGroup(button: preMealButton, image: preMealButtonImage, background: preMealButtonBackground, onBackgroundColor: .carbsColor, offBackgroundColor: .darkCarbsColor, onIconColor: .darkCarbsColor, offIconColor: .carbsColor)

    private lazy var overrideButtonGroup = ButtonGroup(button: overrideButton, image: overrideButtonImage, background: overrideButtonBackground, onBackgroundColor: .overrideColor, offBackgroundColor: .darkOverrideColor, onIconColor: .darkOverrideColor, offIconColor: .overrideColor)

    private lazy var carbsButtonGroup = ButtonGroup(button: carbsButton, image: carbsButtonImage, background: carbsButtonBackground, onBackgroundColor: .carbsColor, offBackgroundColor: .darkCarbsColor, onIconColor: .darkCarbsColor, offIconColor: .carbsColor)

    private lazy var bolusButtonGroup = ButtonGroup(button: bolusButton, image: bolusButtonImage, background: bolusButtonBackground, onBackgroundColor: .insulin, offBackgroundColor: .darkInsulin, onIconColor: .darkInsulin, offIconColor: .insulin)

    @IBOutlet var overrideButtonLabel: WKInterfaceLabel?

    override func willActivate() {
        super.willActivate()

        // Update the override button description based on the feature flag; this cannot be done earlier than `-willActivate` (e.g. didSet on the IBOutlet is too soon)
        if FeatureFlags.sensitivityOverridesEnabled {
            overrideButtonLabel?.setText(NSLocalizedString("Preset", comment: "The text for the Watch button for enabling a custom preset"))
        } else {
            overrideButtonLabel?.setText(NSLocalizedString("Workout", comment: "The text for the Watch button for enabling workout mode"))
        }

        let userActivity = NSUserActivity.forViewLoopStatus()
        if #available(watchOSApplicationExtension 5.0, *) {
            update(userActivity)
        } else {
            updateUserActivity(userActivity.activityType, userInfo: userActivity.userInfo, webpageURL: nil)
        }
    }

    override func update() {
        super.update()

        let activeOverrideContext: TemporaryScheduleOverride.Context?
        if let override = loopManager.settings.scheduleOverride, override.isActive() {
            activeOverrideContext = override.context
        } else {
            activeOverrideContext = nil
        }

        updateForPreMeal(enabled: loopManager.settings.preMealOverride?.isActive() == true)
        updateForOverrideContext(activeOverrideContext)

        let isClosedLoop = loopManager.activeContext?.isClosedLoop ?? false
        
        if !isClosedLoop && FeatureFlags.simpleBolusCalculatorEnabled {
            preMealButtonGroup.state = .disabled
            overrideButtonGroup.state = .disabled
            carbsButtonGroup.state = .disabled
            bolusButtonGroup.state = .disabled
        } else {
            carbsButtonGroup.state = .off
            bolusButtonGroup.state = .off
            
            if loopManager.settings.preMealTargetRange == nil {
                preMealButtonGroup.state = .disabled
            } else if preMealButtonGroup.state == .disabled {
                preMealButtonGroup.state = .off
            }
            
            if !canEnableOverride {
                overrideButtonGroup.state = .disabled
            } else if overrideButtonGroup.state == .disabled {
                overrideButtonGroup.state = .off
            }
        }

        // v1 Sport Mode build (Jeremy 2026-07-26): carb entry on the watch is suppressed — carbs are
        // one-way phone→watch (seeded + wiped-then-replaced at takeover) and watch-entered carbs are
        // NOT returned (loanDidRecordCarbs is a no-op). Rather than offer an action that won't
        // round-trip and confuse the user, grey the carb button unconditionally (overrides the state
        // set above). Revert this one line when bidirectional carb sync (#49/#66) lands.
        carbsButtonGroup.state = .disabled

        glucoseFormatter.updateUnit(to: loopManager.displayGlucoseUnit)
    }
    
    private var canEnableOverride: Bool {
        if FeatureFlags.sensitivityOverridesEnabled {
            return !loopManager.settings.overridePresets.isEmpty
        } else {
            return loopManager.settings.legacyWorkoutTargetRange != nil
        }
    }

    private func updateForPreMeal(enabled: Bool) {
        if enabled {
            preMealButtonGroup.state = .on
        } else {
            preMealButtonGroup.turnOff()
        }
    }

    private func updateForOverrideContext(_ context: TemporaryScheduleOverride.Context?) {
        switch context {
        case nil:
            overrideButtonGroup.turnOff()
        case .preset?, .custom?:
            overrideButtonGroup.state = .on
        case .legacyWorkout?:
            preMealButtonGroup.turnOff()
            overrideButtonGroup.state = .on
        case .preMeal?:
            assertionFailure()
        }
    }

    // MARK: - Menu Items

    private var pendingMessageResponses = 0

    private let glucoseFormatter = QuantityFormatter(for: .milligramsPerDeciliter)

    @IBAction func togglePreMealMode() {
        guard let range = loopManager.settings.preMealTargetRange else {
            return
        }
        
        let buttonToSelect = loopManager.settings.preMealOverride?.isActive() == true ? SelectedButton.on : SelectedButton.off
        let viewModel = OnOffSelectionViewModel(
            title: NSLocalizedString("Pre-Meal", comment: "Title for sheet to enable/disable pre-meal on watch"),
            message: formattedGlucoseRangeString(from: range),
            onSelection: setPreMealEnabled,
            selectedButton: buttonToSelect,
            selectedButtonTint: .carbsColor)
        
        presentController(withName: OnOffSelectionController.className, context: viewModel)
    }

    /// #68 part B scope note (Jeremy 2026-07-31): PRE-MEAL IS OUT OF SCOPE. This path is
    /// deliberately untouched, so during a loan a pre-meal target still requires the phone to
    /// acknowledge — the stock behavior. Only `scheduleOverride` (the Preset/Workout button)
    /// became watch-owned. If pre-meal is ever brought in, it needs the same three writes
    /// `applyOverrideDuringLoan` does plus its own journal payload; `LoopSettings` refuses to
    /// carry a `.preMeal` context in `scheduleOverride` (LoopSettings.swift:46), so it cannot
    /// be smuggled through the record kind added here.
    func setPreMealEnabled(_ isPreMealEnabled: Bool) {
        updateForPreMeal(enabled: isPreMealEnabled)
        pendingMessageResponses += 1

        var settings = loopManager.settings
        let overrideContext = settings.scheduleOverride?.context
        if isPreMealEnabled {
            settings.enablePreMealOverride(for: .hours(1))

            if !FeatureFlags.sensitivityOverridesEnabled {
                settings.clearOverride(matching: .legacyWorkout)
                updateForOverrideContext(nil)
            }
        } else {
            settings.clearOverride(matching: .preMeal)
        }

        let userInfo = LoopSettingsUserInfo(settings: settings)
        do {
            try WCSession.default.sendSettingsUpdateMessage(userInfo, completionHandler: { (result) in
                DispatchQueue.main.async {
                    self.pendingMessageResponses -= 1

                    switch result {
                    case .success(let context):
                        if self.pendingMessageResponses == 0 {
                            self.loopManager.settings.preMealOverride = settings.preMealOverride
                            self.loopManager.settings.scheduleOverride = settings.scheduleOverride
                        }

                        ExtensionDelegate.shared().loopManager.updateContext(context)
                    case .failure(let error):
                        if self.pendingMessageResponses == 0 {
                            ExtensionDelegate.shared().present(error)
                            self.updateForPreMeal(enabled: isPreMealEnabled)
                            self.updateForOverrideContext(overrideContext)
                        }
                    }
                }
            })
        } catch {
            pendingMessageResponses -= 1
            if pendingMessageResponses == 0 {
                updateForPreMeal(enabled: isPreMealEnabled)
                updateForOverrideContext(overrideContext)
                presentAlert(
                    withTitle: NSLocalizedString("Send Failed", comment: "The title of the alert controller displayed after a glucose range override send attempt fails"),
                    message: NSLocalizedString("Make sure your iPhone is nearby and try again", comment: "The recovery message displayed after a glucose range override send attempt fails"),
                    preferredStyle: .alert,
                    actions: [.dismissAction()]
                )
            }
        }
    }

    @IBAction func toggleOverride() {
        if FeatureFlags.sensitivityOverridesEnabled {
            overrideButtonGroup.state == .on
                ? sendOverride(nil)
                : presentController(withName: OverrideSelectionController.className, context: self as OverrideSelectionControllerDelegate)
        } else if let range = loopManager.settings.legacyWorkoutTargetRange {
            let buttonToSelect = loopManager.settings.nonPreMealOverrideEnabled() == true ? SelectedButton.on : SelectedButton.off
            
            let viewModel = OnOffSelectionViewModel(
                title: NSLocalizedString("Workout", comment: "Title for sheet to enable/disable workout mode on watch"),
                message: formattedGlucoseRangeString(from: range),
                onSelection: { isWorkoutEnabled in
                    let override = isWorkoutEnabled ? self.loopManager.settings.legacyWorkoutOverride(for: .infinity) : nil
                    self.sendOverride(override)
                },
                selectedButton: buttonToSelect,
                selectedButtonTint: .glucose
            )
            presentController(withName: OnOffSelectionController.className, context: viewModel)
        }
    }

    private func formattedGlucoseRangeString(from range: ClosedRange<HKQuantity>) -> String {
        let unit = loopManager.displayGlucoseUnit
        glucoseFormatter.updateUnit(to: unit)
        let rangeDouble = range.doubleRange(for: unit)
        return String(
            format: NSLocalizedString(
                "%1$@ – %2$@ %3$@",
                comment: "Format string for glucose range (1: lower bound)(2: upper bound)(3: unit)"
            ),
            glucoseFormatter.numberFormatter.string(from: rangeDouble.minValue) ?? String(rangeDouble.minValue),
            glucoseFormatter.numberFormatter.string(from: rangeDouble.maxValue) ?? String(rangeDouble.maxValue),
            glucoseFormatter.localizedUnitStringWithPlurality()
        )
    }

    private func sendOverride(_ override: TemporaryScheduleOverride?) {
        updateForOverrideContext(override?.context)

        var settings = loopManager.settings
        let isPreMealEnabled = settings.preMealOverride?.isActive() == true
        if override?.context == .legacyWorkout {
            settings.preMealOverride = nil
        }
        settings.scheduleOverride = override

        // #68 part B (Jeremy 2026-07-31): during a POD LOAN the watch owns overrides.
        //
        // Stock's path below only applies the override LOCALLY once the phone acknowledges the
        // settings message — correct when the phone is the therapy authority, and exactly wrong
        // for Sport Mode, where the phone is routinely out of range and the WATCH is the one
        // dosing. So when a loan is active the selection takes effect on the wrist immediately
        // and unconditionally, and the change rides the loan journal home instead of the WC
        // settings channel. Outside a loan nothing here changes: stock behavior, byte for byte.
        if ExtensionDelegate.shared().stockLoopSession.loanController.isLoanActive {
            applyOverrideDuringLoan(override, settings: settings)
            return
        }

        pendingMessageResponses += 1

        let userInfo = LoopSettingsUserInfo(settings: settings)
        do {
            try WCSession.default.sendSettingsUpdateMessage(userInfo, completionHandler: { (result) in
                DispatchQueue.main.async {
                    self.pendingMessageResponses -= 1

                    switch result {
                    case .success(let context):
                        if self.pendingMessageResponses == 0 {
                            self.loopManager.settings.scheduleOverride = override
                            self.loopManager.settings.preMealOverride = settings.preMealOverride
                        }

                        ExtensionDelegate.shared().loopManager.updateContext(context)
                    case .failure(let error):
                        if self.pendingMessageResponses == 0 {
                            ExtensionDelegate.shared().present(error)
                            self.updateForOverrideContext(override?.context)
                            self.updateForPreMeal(enabled: isPreMealEnabled)
                        }
                    }
                }
            })
        } catch {
            pendingMessageResponses -= 1
            if pendingMessageResponses == 0 {
                updateForOverrideContext(override?.context)
                updateForPreMeal(enabled: isPreMealEnabled)
                presentAlert(
                    withTitle: NSLocalizedString("Send Failed", comment: "The title of the alert controller displayed after a glucose range override send attempt fails"),
                    message: NSLocalizedString("Make sure your iPhone is nearby and try again", comment: "The recovery message displayed after a glucose range override send attempt fails"),
                    preferredStyle: .alert,
                    actions: [.dismissAction()]
                )
            }
        }
    }

    /// #68 part B: apply a wrist-selected override during an ACTIVE loan.
    ///
    /// Three writes, in this order, none of them gated on the phone:
    ///  1. the wrist UI's own settings (`LoopDataManager`, `@PersistedProperty`) — this is what
    ///     `update()` reads for the button state, so without it the button snaps back on the
    ///     next context refresh;
    ///  2. the LOAN's dosing settings (`WatchLoopManager`) — part A's didSet records into the
    ///     shared `TemporaryScheduleOverrideHistory`, which rescales basal / ISF / carb ratio
    ///     and invalidates the cached effects, so the next cycle doses under the override;
    ///  3. the loan JOURNAL — the durable channel that carries the change to the phone at
    ///     hand-back even if the phone was never reachable while the loan ran.
    ///
    /// The WC push at the end is a BEST-EFFORT courtesy so a phone that happens to be in range
    /// reflects the change now rather than at hand-back. Its failure is not surfaced (no "Send
    /// Failed" alert): an unreachable phone is the normal Sport Mode condition, and the override
    /// is already live and already durable. If it DOES land, the phone applies it immediately
    /// and the journal record later no-ops on the syncIdentifier idempotency check.
    private func applyOverrideDuringLoan(_ override: TemporaryScheduleOverride?, settings: LoopSettings) {
        let session = ExtensionDelegate.shared().stockLoopSession

        loopManager.settings.preMealOverride = settings.preMealOverride
        loopManager.settings.scheduleOverride = settings.scheduleOverride
        session.stack.loopManager.applyWristOverride(override)
        session.loanController.loanDidRecordOverride(override)

        let userInfo = LoopSettingsUserInfo(settings: settings)
        try? WCSession.default.sendSettingsUpdateMessage(userInfo, completionHandler: { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let context):
                    ExtensionDelegate.shared().loopManager.updateContext(context)
                case .failure:
                    // Expected during sport — the override is live on the wrist and journaled.
                    break
                }
            }
        })
    }
}

extension ActionHUDController: OverrideSelectionControllerDelegate {
    func overrideSelectionController(_ controller: OverrideSelectionController, didSelectPreset preset: TemporaryScheduleOverridePreset) {
        let override = preset.createOverride(enactTrigger: .local)
        sendOverride(override)
    }
}
