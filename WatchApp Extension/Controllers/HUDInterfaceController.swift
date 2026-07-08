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
    /// end Show Mode (hand the pod back to the phone) and return to the main HUD — no
    /// screen, since all dosing lives on the main HUD now.
    //
    // Ending requires the phone reachable: the phone needs its Bluetooth on to reclaim
    // the pod over BLE (and WatchConnectivity to receive the loan journal). Show Mode is
    // entered with the phone's BT OFF, so the user often still has it off here — confirmed
    // on the emulator that hand-back then silently does nothing. So if the phone isn't
    // reachable, surface an alert rather than no-op.
    @IBAction func openPodControl() {
        if isInShowMode {
            guard ExtensionDelegate.shared().podLoanCoordinator.phoneReachable else {
                presentAlert(
                    withTitle: NSLocalizedString("iPhone Bluetooth Is Off", comment: "Alert title shown when ending Show Mode while the phone is unreachable"),
                    message: NSLocalizedString("Show Mode is still on. To end it, turn your iPhone's Bluetooth on, then tap again.", comment: "Alert body shown when ending Show Mode while the phone is unreachable"),
                    preferredStyle: .alert,
                    actions: [WKAlertAction(title: NSLocalizedString("OK", comment: "OK button on the turn-on-Bluetooth alert"), style: .default, handler: {})]
                )
                return
            }
            ExtensionDelegate.shared().podLoanCoordinator.handBack()
        } else {
            presentController(withName: WatchPodControlController.className, context: PodControlEntry.start)
        }
    }

}
