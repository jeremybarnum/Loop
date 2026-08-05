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
        // R23, finally applied here: during a loan the ring's freshness is BG RECENCY, on the
        // same thresholds the glance uses — "meaningful OPEN or CLOSED, and stale G7 is the
        // likely failure. Drives the stock ring color." It was ruled 2026-07-18 and only ever
        // implemented on the glance, so the two screens could disagree on BOTH inputs and
        // thresholds: this used loopLastRunDate at 6/20 min, the glance uses glucose age at
        // 7/15. A loop that ran a minute ago against a G7 that has been quiet for twelve read
        // fresh here and aging there (Jeremy, field 2026-08-04).
        //
        // Outside a loan the phone owns dosing and stock's own loop-run convention is correct,
        // so that path is untouched. `isLoanActiveNonBlocking` is a lock-guarded mirror — the
        // live gate is queue.sync onto the pump's delegateQueue and must not be read from here.
        let onLoan = ExtensionDelegate.shared().stockLoopSession.loanController.isLoanActiveNonBlocking
        // ...and the SHAPE has to come from the same place as the colour. This read
        // `activeContext.isClosedLoop` unconditionally — the PHONE's mode — so during a loan the
        // stock screen showed the phone's loop while the glance showed the watch's. Field
        // 2026-08-05: "glance is closed and stock is open, even though they are both green."
        // Green matched because the colour fix above landed; the shape never did, and I closed
        // that observation as fixed when only half of it was.
        //
        // During a loan the WATCH is the dosing controller and its mode is the true one (R23 as
        // amended: the watch is sovereign in a loan). Non-blocking mirror for the same reason
        // isLoanActiveNonBlocking is: the live accessor takes the dosing queue.
        let isClosedLoop = onLoan
            ? ExtensionDelegate.shared().stockLoopSession.stack.loopManager.closedLoopEnabledNonBlocking
            : (activeContext.isClosedLoop ?? false)
        loopHUDImage.setLoopImage(isClosedLoop: isClosedLoop, {
            if onLoan {
                guard let glucoseDate = activeContext.glucoseDate else { return .unknown }
                let age = -glucoseDate.timeIntervalSinceNow
                return age < .minutes(7) ? .fresh : (age < .minutes(15) ? .aging : .stale)
            }
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
        presentController(withName: CarbAndBolusFlowController.className, context: CarbAndBolusFlow.Configuration.manualBolus)
    }

}
