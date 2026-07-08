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
import Combine


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

    // Show Mode toggle. Three visual states, respecting the HID/Loop convention that
    // GREY means "unavailable — don't press" (reserved for .disabled):
    //   • off / available → white icon on dark  (tap to start Show Mode)
    //   • on  / active    → green fill           (watch holds the pod)
    //   • .disabled is never used here — the toggle is always pressable.
    private lazy var preMealButtonGroup = ButtonGroup(button: preMealButton, image: preMealButtonImage, background: preMealButtonBackground, onBackgroundColor: .carbsColor, offBackgroundColor: .darkCarbsColor, onIconColor: .darkCarbsColor, offIconColor: .white)

    private lazy var overrideButtonGroup = ButtonGroup(button: overrideButton, image: overrideButtonImage, background: overrideButtonBackground, onBackgroundColor: .overrideColor, offBackgroundColor: .darkOverrideColor, onIconColor: .darkOverrideColor, offIconColor: .overrideColor)

    private lazy var carbsButtonGroup = ButtonGroup(button: carbsButton, image: carbsButtonImage, background: carbsButtonBackground, onBackgroundColor: .carbsColor, offBackgroundColor: .darkCarbsColor, onIconColor: .darkCarbsColor, offIconColor: .carbsColor)

    private lazy var bolusButtonGroup = ButtonGroup(button: bolusButton, image: bolusButtonImage, background: bolusButtonBackground, onBackgroundColor: .insulin, offBackgroundColor: .darkInsulin, onIconColor: .darkInsulin, offIconColor: .insulin)

    @IBOutlet var overrideButtonLabel: WKInterfaceLabel?

    private var loanPhaseCancellable: AnyCancellable?

    override func awake(withContext context: Any?) {
        super.awake(withContext: context)
        // Keep the horse button + Carbs availability in sync with the pod loan even
        // while the pod sheet is covering this screen: the phase changes while we're
        // inactive, and dismissing that sheet doesn't reliably fire willActivate — so
        // observe the phase directly and re-run update(). dropFirst() skips the current
        // value (willActivate paints the initial state); we only need later changes.
        loanPhaseCancellable = ExtensionDelegate.shared().podLoanCoordinator.$phase
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
    }

    override func willActivate() {
        super.willActivate()

        // The (unused) Pre-Meal button is repurposed as the "Show Mode" button — it
        // starts watch-only, phone-free mode for competition (opens the loan control
        // screen; its storyboard action is now `openPodControl`). Icon = equestrian, since this is initially
        // for Caitlin riding horses; the watch context is implicit (it's on her wrist).
        // The old pre-meal state management is removed from `update()` so it stays
        // enabled. (Later option: a custom watch+rider glyph to show the watch too.)
        let untetherIconConfig = UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        preMealButtonImage.setImage(UIImage(systemName: "figure.equestrian.sports", withConfiguration: untetherIconConfig))
        preMealButtonGroup.state = isInShowMode ? .on : .off

        // Update the override button description; cannot be done earlier than
        // `-willActivate` (e.g. didSet on the IBOutlet is too soon).
        updateOverrideLabel()

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

        // Pre-Meal button is now the Pod button — it no longer reflects pre-meal state
        // and stays enabled regardless of loop mode.
        updateForOverrideContext(activeOverrideContext)

        let isClosedLoop = loopManager.activeContext?.isClosedLoop ?? false

        // Show Mode button (repurposed Pre-Meal): green while the watch holds the pod.
        preMealButtonGroup.state = isInShowMode ? .on : .off

        if !isClosedLoop && FeatureFlags.simpleBolusCalculatorEnabled {
            overrideButtonGroup.state = .disabled
            carbsButtonGroup.state = .disabled
            bolusButtonGroup.state = .disabled
        } else {
            carbsButtonGroup.state = .off
            bolusButtonGroup.state = .off

            if !canEnableOverride {
                overrideButtonGroup.state = .disabled
            } else if overrideButtonGroup.state == .disabled {
                overrideButtonGroup.state = .off
            }
        }

        // In Show Mode the phone is away: Carbs (routes to the phone) is unavailable,
        // while Bolus and the Override button (which becomes the basal control) must
        // stay enabled since they drive the pod directly — regardless of the loop-mode
        // logic above that might otherwise disable them.
        if isInShowMode {
            carbsButtonGroup.state = .disabled
            bolusButtonGroup.state = .off
            overrideButtonGroup.state = .off
        }
        updateOverrideLabel()

        glucoseFormatter.updateUnit(to: loopManager.displayGlucoseUnit)
    }
    
    private var canEnableOverride: Bool {
        if FeatureFlags.sensitivityOverridesEnabled {
            return !loopManager.settings.overridePresets.isEmpty
        } else {
            return loopManager.settings.legacyWorkoutTargetRange != nil
        }
    }

    // isInShowMode is defined on HUDInterfaceController (shared with setBolus /
    // openPodControl). In Show Mode the horse button is green and Carbs is unavailable.

    /// The override button's label. In Show Mode this button is the basal control, so
    /// it reads "Basal"; otherwise it's the normal Preset/Workout override label.
    private func updateOverrideLabel() {
        if isInShowMode {
            overrideButtonLabel?.setText(NSLocalizedString("Basal", comment: "The Watch override button relabeled as the basal control in Show Mode"))
        } else if FeatureFlags.sensitivityOverridesEnabled {
            overrideButtonLabel?.setText(NSLocalizedString("Preset", comment: "The text for the Watch button for enabling a custom preset"))
        } else {
            overrideButtonLabel?.setText(NSLocalizedString("Workout", comment: "The text for the Watch button for enabling workout mode"))
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
        // In Show Mode this button becomes the basal control (drives the pod);
        // otherwise it's the normal phone-routed override/workout sheet.
        if isInShowMode {
            presentController(withName: WatchPodControlController.className, context: PodControlEntry.basal)
            return
        }
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
        pendingMessageResponses += 1

        var settings = loopManager.settings
        let isPreMealEnabled = settings.preMealOverride?.isActive() == true
        if override?.context == .legacyWorkout {
            settings.preMealOverride = nil
        }
        settings.scheduleOverride = override

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
}

extension ActionHUDController: OverrideSelectionControllerDelegate {
    func overrideSelectionController(_ controller: OverrideSelectionController, didSelectPreset preset: TemporaryScheduleOverridePreset) {
        let override = preset.createOverride(enactTrigger: .local)
        sendOverride(override)
    }
}
