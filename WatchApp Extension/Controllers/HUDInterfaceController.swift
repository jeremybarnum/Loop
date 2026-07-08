//
//  HUDInterfaceController.swift
//  WatchApp Extension
//
//  Created by Bharat Mediratta on 6/29/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import WatchKit
import LoopCore
import LoopKit

class HUDInterfaceController: WKInterfaceController {
    private var activeContextObserver: NSObjectProtocol?

    @IBOutlet weak var loopHUDImage: WKInterfaceImage!
    @IBOutlet weak var glucoseLabel: WKInterfaceLabel!
    @IBOutlet weak var eventualGlucoseLabel: WKInterfaceLabel!

    var loopManager = ExtensionDelegate.shared().loopManager

    /// True while the watch actually holds the pod (Show Mode is live) — derived from
    /// the loan coordinator's real .active phase, never a separate flag. Routes the
    /// shared action buttons (Bolus, and the horse's pod screen) to the pod instead of
    /// the phone. Subclasses (ActionHUDController) use it for button appearance too.
    var isInShowMode: Bool {
        ExtensionDelegate.shared().podLoanCoordinator.phase == .active
    }

    override func willActivate() {
        super.willActivate()

        update()

        if activeContextObserver == nil {
            activeContextObserver = NotificationCenter.default.addObserver(forName: LoopDataManager.didUpdateContextNotification, object: loopManager, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.update()
                }
            }
        }

        loopManager.requestContextUpdate(completion: {
            self.loopManager.requestGlucoseBackfillIfNecessary()
        })
    }

    override func didDeactivate() {
        super.didDeactivate()

        if let observer = activeContextObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        activeContextObserver = nil
    }

    func update() {
        guard let activeContext = loopManager.activeContext else {
            loopHUDImage.setHidden(true)
            return
        }
        loopHUDImage.setHidden(false)

        let date = activeContext.loopLastRunDate
        let isClosedLoop = activeContext.isClosedLoop ?? false
        loopHUDImage.setLoopImage(isClosedLoop: isClosedLoop, {
            if let date = date {
                switch date.timeIntervalSinceNow {
                case let t where t > .minutes(-6):
                    return .fresh
                case let t where t > .minutes(-20):
                    return .aging
                default:
                    return .stale
                }
            } else {
                return .unknown
            }
        }())

        if date != nil {
            glucoseLabel.setText(NSLocalizedString("– – –", comment: "No glucose value representation (3 dashes for mg/dL)"))
            glucoseLabel.setHidden(false)
            
            let showEventualGlucose = FeatureFlags.showEventualBloodGlucoseOnWatchEnabled
            if showEventualGlucose {
                eventualGlucoseLabel.setHidden(true)
            }
                
            if let glucose = activeContext.glucose, let glucoseDate = activeContext.glucoseDate, let unit = activeContext.displayGlucoseUnit, glucoseDate.timeIntervalSinceNow > -LoopCoreConstants.inputDataRecencyInterval {
                let formatter = NumberFormatter.glucoseFormatter(for: unit)
                
                if let glucoseValue = formatter.string(from: glucose.doubleValue(for: unit)) {
                    let trend = activeContext.glucoseTrend?.symbol ?? ""
                    glucoseLabel.setText(glucoseValue + trend)
                }
                
                if showEventualGlucose, let eventualGlucose = activeContext.eventualGlucose, let eventualGlucoseValue = formatter.string(from: eventualGlucose.doubleValue(for: unit)) {
                    eventualGlucoseLabel.setText(eventualGlucoseValue)
                    eventualGlucoseLabel.setHidden(false)
                }
            }
        }

    }

    @IBAction func addCarbs() {
        presentController(withName: CarbAndBolusFlowController.className, context: CarbAndBolusFlow.Configuration.carbEntry(nil))
    }
    
    func addCarbs(initialEntry: NewCarbEntry) {
        presentController(withName: CarbAndBolusFlowController.className, context: CarbAndBolusFlow.Configuration.carbEntry(initialEntry))
    }

    @IBAction func setBolus() {
        // In Show Mode the phone is away, so Bolus drives the pod directly (capped
        // dial); otherwise it's the normal phone-routed bolus flow.
        if isInShowMode {
            presentController(withName: WatchPodControlController.className, context: PodControlEntry.bolus)
        } else {
            presentController(withName: CarbAndBolusFlowController.className, context: CarbAndBolusFlow.Configuration.manualBolus)
        }
    }

    /// The horse button. Not in Show Mode → the start/untether flow. In Show Mode →
    /// end Show Mode immediately (hand back to the phone) and return to the main HUD —
    /// no screen. All dosing now lives on the main HUD, so there's nothing left to show
    /// on an "end" screen.
    //
    // TODO(pod-test, ~Fri): direct hand-back assumes the phone doesn't need Bluetooth
    // pre-enabled to reclaim the pod, and shows no on-screen feedback if hand-back fails
    // (phone unreachable — phase reverts to .active, horse goes back to green). Revisit
    // after real-pod testing: if a confirm or "re-enable Bluetooth" step is needed,
    // restore the presented end screen (PodControlEntry.end + endSection are retained).
    @IBAction func openPodControl() {
        if isInShowMode {
            ExtensionDelegate.shared().podLoanCoordinator.handBack()
        } else {
            presentController(withName: WatchPodControlController.className, context: PodControlEntry.start)
        }
    }

}
