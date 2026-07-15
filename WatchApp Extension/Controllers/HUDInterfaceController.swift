//
//  HUDInterfaceController.swift
//  WatchApp Extension
//
//  Created by Bharat Mediratta on 6/29/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import WatchKit
import Combine
import LoopCore
import LoopKit

extension Bundle {
    /// TEMPORARY test aid: build number + the binary's link-time mtime = a true build
    /// timestamp with no build-system machinery. Shown as the HUD screen title.
    var buildStamp: String {
        let v = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let linked = executableURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        return "b\(v) \(linked.map { HUDInterfaceController.buildStampFormatter.string(from: $0) } ?? "")"
    }
}

class HUDInterfaceController: WKInterfaceController {
    private var activeContextObserver: NSObjectProtocol?
    private var glucoseSamplesObserver: NSObjectProtocol?
    private var predictionStoreObserver: NSObjectProtocol?
    private var commandFailureCancellable: AnyCancellable?

    @IBOutlet weak var loopHUDImage: WKInterfaceImage!
    @IBOutlet weak var glucoseLabel: WKInterfaceLabel!
    @IBOutlet weak var eventualGlucoseLabel: WKInterfaceLabel!

    var loopManager = ExtensionDelegate.shared().loopManager

    /// True while the watch actually holds the pod (Sport Mode is live) — derived from
    /// the loan coordinator's real .active phase, never a separate flag. Routes the
    /// shared action buttons (Bolus, and the horse's pod screen) to the pod instead of
    /// the phone. Subclasses (ActionHUDController) use it for button appearance too.
    var isInShowMode: Bool {
        ExtensionDelegate.shared().podLoanCoordinator.phase == .active
    }

    // TEMPORARY test aid (watch installs have been flaky): build number + the appex binary's
    // link-time mtime = a true build timestamp with zero build-system machinery. Shown as the
    // screen title on both HUD pages; delete when install reliability is no longer in question.
    static let buildStampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "M/d HH:mm"
        return df
    }()

    override func willActivate() {
        super.willActivate()

        setTitle(Bundle.main.buildStamp)   // TEMPORARY test aid: which build is on the wrist

        update()

        if activeContextObserver == nil {
            activeContextObserver = NotificationCenter.default.addObserver(forName: LoopDataManager.didUpdateContextNotification, object: loopManager, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.update()
                }
            }
        }

        // Sport Mode's BG header is driven by the WATCH-LOCAL store, so it must
        // re-render when samples land — activation alone races the async write
        // of a just-dialed entry (header showed the pre-entry value live).
        if glucoseSamplesObserver == nil {
            glucoseSamplesObserver = NotificationCenter.default.addObserver(forName: GlucoseStore.glucoseSamplesDidChange, object: loopManager.glucoseStore, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.isInShowMode else { return }
                    self.update()
                }
            }
        }
        // The shared prediction store recomputed → refresh the eventual BG (and
        // header) on whichever HUD page is showing.
        if predictionStoreObserver == nil {
            predictionStoreObserver = NotificationCenter.default.addObserver(forName: WatchPredictionStore.didUpdateNotification, object: nil, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.isInShowMode else { return }
                    self.update()
                }
            }
        }
        // Kick an immediate recompute so eventual BG is present right away.
        if isInShowMode {
            ExtensionDelegate.shared().predictionStore.refresh(force: true)
        }

        loopManager.requestContextUpdate(completion: {
            self.loopManager.requestGlucoseBackfillIfNecessary()
        })

        // LOUD surfacing of failed Sport Mode pod commands (BUG-5): whichever HUD
        // page is active presents the alert. @Published replays the current value
        // on subscription, so a failure that lands while a dose screen is up is
        // presented as soon as the user returns to a HUD page. Clearing before
        // presenting dedupes across page switches.
        let coordinator = ExtensionDelegate.shared().podLoanCoordinator
        commandFailureCancellable = coordinator.$commandFailure
            .receive(on: DispatchQueue.main)
            .sink { [weak self] failure in
                guard let self, let failure else { return }
                coordinator.clearCommandFailure()
                self.presentAlert(withTitle: failure.title,
                                  message: failure.message,
                                  preferredStyle: .alert,
                                  actions: [WKAlertAction(title: NSLocalizedString("OK", comment: "Acknowledge failed pod command"), style: .default) {}])
            }
    }

    override func didDeactivate() {
        super.didDeactivate()

        if let observer = activeContextObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        activeContextObserver = nil
        commandFailureCancellable = nil
    }

    func update() {
        // Sport Mode: the ring is the turf-colored OPEN loop — Sport Mode's identity
        // color (shared with the horse button) — and it does NOT age: the freshness
        // colors encode phone-loop health, which is meaningless here (green would lie
        // that the loop is running; yellow/red would alarm about an intentional state).
        // The BG number + trend now come from the WATCH-LOCAL store (manual
        // entries today, streaming sensor when the direct-G7 work lands) — the
        // original stale-phone-value concern doesn't apply to samples we own.
        // Values older than 30 min degrade to dashes rather than looking live.
        // Eventual BG is the watch's own prediction (shared prediction store),
        // shown on BOTH HUD pages — it's the key output and is valid the instant
        // Sport Mode activates (the watch has what the phone loop had a moment ago).
        if isInShowMode {
            loopHUDImage.setHidden(false)
            // Same visual grammar as the phone: open ring = open loop, closed
            // ring = closed loop — but in turf, Sport Mode's green.
            let loopClosed = ExtensionDelegate.shared().autoLoop.isClosed
            loopHUDImage.setImageNamed(loopClosed ? "loop_show_closed" : "loop_show_open")
            updateShowModeGlucoseHeader()
            updateShowModeEventualGlucose()
            return
        }

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
                
                // The eventual BG is the phone's prediction — in Sport Mode it was
                // computed before untethering and assumes the phone is still looping,
                // so suppress it (the measured BG + trend above stay).
                if showEventualGlucose, !isInShowMode, let eventualGlucose = activeContext.eventualGlucose, let eventualGlucoseValue = formatter.string(from: eventualGlucose.doubleValue(for: unit)) {
                    eventualGlucoseLabel.setText(eventualGlucoseValue)
                    eventualGlucoseLabel.setHidden(false)
                }
            }
        }

    }

    /// Sport Mode eventual BG: the shared prediction store's latest output,
    /// same number the swipe page's Eventual row shows. Hidden only when no
    /// prediction exists yet (no BG at all).
    private func updateShowModeEventualGlucose() {
        guard FeatureFlags.showEventualBloodGlucoseOnWatchEnabled else {
            eventualGlucoseLabel.setHidden(true)
            return
        }
        let store = ExtensionDelegate.shared().predictionStore
        // A forward projection off a stale reading is misleading — refuse it,
        // same threshold Loop uses to stop predicting (glucoseTooOld). The
        // current-BG header still shows the last value + its age.
        guard let output = store.latestOutput, !store.isAnchorStale else {
            eventualGlucoseLabel.setHidden(true)
            return
        }
        let formatter = NumberFormatter.glucoseFormatter(for: output.unit)
        if let text = formatter.string(from: output.eventualBG.doubleValue(for: output.unit)) {
            eventualGlucoseLabel.setText(text)
            eventualGlucoseLabel.setHidden(false)
        }
    }

    /// Sport Mode BG header: newest watch-local sample + two-sample trend
    /// arrow; dashes when nothing fresh enough exists.
    private func updateShowModeGlucoseHeader() {
        loopManager.glucoseStore.getGlucoseSamples(start: Date(timeIntervalSinceNow: -.hours(1)), end: Date()) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                let samples = ((try? result.get()) ?? []).sorted { $0.startDate < $1.startDate }
                guard let newest = samples.last, -newest.startDate.timeIntervalSinceNow < .minutes(30) else {
                    self.glucoseLabel.setText(NSLocalizedString("– – –", comment: "No glucose value representation (3 dashes for mg/dL)"))
                    self.glucoseLabel.setHidden(false)
                    return
                }
                let unit = self.loopManager.settings.glucoseUnit ?? .milligramsPerDeciliter
                let formatter = NumberFormatter.glucoseFormatter(for: unit)
                var text = formatter.string(from: newest.quantity.doubleValue(for: unit)) ?? "– – –"
                if samples.count >= 2 {
                    text += Self.trendSymbol(from: samples[samples.count - 2], to: newest)
                }
                self.glucoseLabel.setText(text)
                self.glucoseLabel.setHidden(false)
            }
        }
    }

    /// Two-sample slope → arrow, mg/dL per minute thresholds. Empty when the
    /// pair is too far apart (or inverted) to mean anything.
    static func trendSymbol(from older: StoredGlucoseSample, to newer: StoredGlucoseSample) -> String {
        let minutes = newer.startDate.timeIntervalSince(older.startDate) / 60
        guard minutes > 0, minutes <= 30 else { return "" }
        let rate = (newer.quantity.doubleValue(for: .milligramsPerDeciliter)
            - older.quantity.doubleValue(for: .milligramsPerDeciliter)) / minutes
        switch rate {
        case ..<(-3): return "↓↓"
        case ..<(-2): return "↓"
        case ..<(-1): return "↘"
        case ...1: return "→"
        case ...2: return "↗"
        case ...3: return "↑"
        default: return "↑↑"
        }
    }

    /// Tap on the BG header (both HUD pages): in Sport Mode, straight to the
    /// entry dial + prediction. Tethered mode keeps the header inert.
    @IBAction func didTapGlucoseHeader(_ sender: Any) {
        guard isInShowMode else { return }
        presentController(withName: WatchPodControlController.className, context: PodControlEntry.bgEntry)
    }

    @IBAction func addCarbs() {
        presentController(withName: CarbAndBolusFlowController.className, context: CarbAndBolusFlow.Configuration.carbEntry(nil))
    }
    
    func addCarbs(initialEntry: NewCarbEntry) {
        presentController(withName: CarbAndBolusFlowController.className, context: CarbAndBolusFlow.Configuration.carbEntry(initialEntry))
    }

    @IBAction func setBolus() {
        // In Sport Mode the phone is away, so Bolus drives the pod directly (capped
        // dial); otherwise it's the normal phone-routed bolus flow.
        if isInShowMode {
            presentController(withName: WatchPodControlController.className, context: PodControlEntry.bolus)
        } else {
            presentController(withName: CarbAndBolusFlowController.className, context: CarbAndBolusFlow.Configuration.manualBolus)
        }
    }

    /// The horse button. Not in Sport Mode → the start/untether flow. In Sport Mode →
    /// end Sport Mode (hand the pod back to the phone) and return to the main HUD — no
    /// screen, since all dosing lives on the main HUD now.
    //
    // Ending requires the phone reachable: the phone needs its Bluetooth on to reclaim
    // the pod over BLE (and WatchConnectivity to receive the loan journal). Sport Mode is
    // entered with the phone's BT OFF, so the user often still has it off here — confirmed
    // on the emulator that hand-back then silently does nothing. So if the phone isn't
    // reachable, surface an alert rather than no-op.
    @IBAction func openPodControl() {
        if isInShowMode {
            guard ExtensionDelegate.shared().podLoanCoordinator.phoneReachable else {
                presentAlert(
                    withTitle: NSLocalizedString("iPhone Bluetooth Is Off", comment: "Alert title shown when ending Sport Mode while the phone is unreachable"),
                    message: NSLocalizedString("Sport Mode is still on. To end it, turn your iPhone's Bluetooth on, then tap again.", comment: "Alert body shown when ending Sport Mode while the phone is unreachable"),
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
