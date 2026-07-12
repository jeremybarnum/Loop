//
//  ChartHUDController.swift
//  Loop
//
//  Created by Bharat Mediratta on 6/26/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import WatchKit
import WatchConnectivity
import LoopKit
import HealthKit
import SpriteKit
import os.log
import LoopCore
import OmniBLECore

final class ChartHUDController: HUDInterfaceController, WKCrownDelegate {
    private enum TableRow: Int, CaseIterable {
        case iob
        case cob
        case netBasal
        case reservoirVolume

        var title: String {
            switch self {
            case .iob:
                return NSLocalizedString("Active Insulin", comment: "HUD row title for IOB")
            case .cob:
                return NSLocalizedString("Active Carbs", comment: "HUD row title for COB")
            case .netBasal:
                return NSLocalizedString("Net Basal Rate", comment: "HUD row title for Net Basal Rate")
            case .reservoirVolume:
                return NSLocalizedString("Reservoir Volume", comment: "HUD row title for remaining reservoir volume")
            }
        }

        var isLast: Bool {
            return self == TableRow.allCases.last
        }
    }

    @IBOutlet private weak var table: WKInterfaceTable!

    @IBOutlet private weak var glucoseScene: WKInterfaceSKScene!
    /// The fixed-height container around the chart. Hiding the SCENE alone leaves
    /// this group's height as an empty band; hiding the GROUP collapses it so the
    /// table reflows into the space (Show Mode).
    @IBOutlet private weak var graphGroup: WKInterfaceGroup!
    private let scene = GlucoseChartScene()
    private var timer: Timer? {
        didSet {
            oldValue?.invalidate()
        }
    }
    private let log = OSLog(category: "ChartHUDController")
    private var hasInitialActivation = false

    private var observers: [Any] = [] {
        didSet {
            for observer in oldValue {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    override init() {
        super.init()

        glucoseScene.presentScene(scene)
    }

    override func awake(withContext context: Any?) {
        super.awake(withContext: context)

        table.setNumberOfRows(TableRow.allCases.count, withRowType: HUDRowController.className)
    }

    override func didAppear() {
        super.didAppear()

        applyChartVisibility()
        refreshPredictionForShowMode(force: true)

        // Force an update when our pixels need to move. Capped at 60 s so the
        // Show Mode rows (session numbers, live basal accrual) also repaint while
        // the page stays up — swipe-in alone would leave them frozen.
        let pixelsWide = scene.size.width * WKInterfaceDevice.current().screenScale
        let pixelInterval = min(scene.visibleDuration / TimeInterval(pixelsWide), 60)

        timer = Timer.scheduledTimer(withTimeInterval: pixelInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isInShowMode {
                // Chart is hidden in Show Mode; keep the session rows current and
                // re-run the prediction at most every 5 minutes (throttled inside).
                self.updateRowsForShowMode()
                self.refreshPredictionForShowMode()
            } else {
                self.scene.setNeedsUpdate()
            }
        }

        // These margins are only available after we appear (sadly)

        scene.textInsets.left = max(scene.textInsets.left, systemMinimumLayoutMargins.leading)
        scene.textInsets.right = max(scene.textInsets.right, systemMinimumLayoutMargins.trailing)

        // Row count varies by mode (see configureTable) — only touch rows that exist.
        for index in 0..<TableRow.allCases.count {
            if let cell = table.rowController(at: index) as? HUDRowController {
                cell.setContentInset(systemMinimumLayoutMargins)
            }
        }
    }

    override func willDisappear() {
        super.willDisappear()

        log.default("willDisappear")

        timer = nil
    }

    override func willActivate() {
        super.willActivate()

        observers = [
            NotificationCenter.default.addObserver(forName: GlucoseStore.glucoseSamplesDidChange, object: loopManager.glucoseStore, queue: nil) { [weak self] (note) in
                self?.log.default("Received GlucoseSamplesDidChange notification: %{public}@. Updating chart", String(describing: note.userInfo ?? [:]))

                DispatchQueue.main.async {
                    self?.updateGlucoseChart()
                    // New sample (dialed entry landing, backfill sync) → the
                    // prediction rows must recompute from it, not wait 5 min.
                    self?.refreshPredictionForShowMode(force: true)
                }
            }
        ]

        applyChartVisibility()

        if !hasInitialActivation && UserDefaults.standard.startOnChartPage {
            log.default("Switching to startOnChartPage")
            becomeCurrentPage()
        }

        hasInitialActivation = true

        loopManager.requestGlucoseBackfillIfNecessary()
    }

    override func didDeactivate() {
        super.didDeactivate()

        observers = []

        log.default("didDeactivate() pausing")
        glucoseScene.isPaused = true
    }

    override func update() {
        super.update()

        applyChartVisibility()

        // In Show Mode the phone-fed context is stale by construction (the phone is
        // away) — the watch is driving the pod. Show the session rows and skip the
        // chart entirely (it's hidden; the BG history is frozen and not actionable).
        if isInShowMode {
            updateRowsForShowMode()
            return
        }

        guard let activeContext = loopManager.activeContext else {
            return
        }
        updateRows(for: activeContext)
        updateGlucoseChart()
    }

    /// The BG-history chart earns its screen space only in normal mode. In Show
    /// Mode it's hidden and paused — WatchKit reflows the freed space to the
    /// session table, and we skip the render/data work entirely.
    private func applyChartVisibility() {
        let hideChart = isInShowMode
        // Collapse the whole fixed-height graph GROUP (not just the scene), so
        // WatchKit reflows its space to the session table.
        graphGroup.setHidden(hideChart)
        glucoseScene.isPaused = hideChart
    }

    private func updateRows(for activeContext: WatchContext) {
        configureTable(forShowMode: false)
        for row in TableRow.allCases {
            guard let cell = table.rowController(at: row.rawValue) as? HUDRowController else { continue }
            cell.setTitle(row.title)
            cell.setIsLastRow(row.isLast)
            cell.setContentInset(systemMinimumLayoutMargins)

            let isActiveContextStale = Date().timeIntervalSince(activeContext.creationDate) > LoopCoreConstants.inputDataRecencyInterval

            switch row {
            case .iob:
                cell.setActiveInsulin(isActiveContextStale ? nil : activeContext.activeInsulin)
            case .cob:
                cell.setActiveCarbohydrates(isActiveContextStale ? nil : activeContext.activeCarbohydrates)
            case .netBasal:
                cell.setNetTempBasalDose(isActiveContextStale ? nil : activeContext.lastNetTempBasalDose)
            case .reservoirVolume:
                cell.setReservoirVolume(isActiveContextStale ? nil : activeContext.reservoirVolume)
            }
        }
    }

    /// The Show Mode status rows — what the watch has DONE this session (raw,
    /// undecayed cumulative amounts), plus the current basal rate:
    ///  - Session Bolus:   boluses delivered this session.
    ///  - Session Basal:   net insulin delivered above (+) / below (−) the
    ///                     scheduled basal — a suspend / low temp is NEGATIVE.
    ///  - Session Insulin: the sum of the two (net insulin this session).
    ///  - Basal Rate:      the current watch-set rate ("Suspended" / "x U/hr" /
    ///                     "Scheduled" when nothing's been changed).
    /// Four rows match the normal HUD table's row count, so they fit as-is.
    private enum ShowModeRow: Int, CaseIterable {
        case currentBG
        case eventualBG
        case activeInsulin
        case activeCarbs
        case loopStatus
        case sessionBolus
        case sessionBasal
        case sessionInsulin
        case basalRate

        var title: String {
            switch self {
            case .currentBG:
                return NSLocalizedString("Glucose", comment: "HUD row: current glucose in Show Mode (tap to enter)")
            case .eventualBG:
                return NSLocalizedString("Eventual", comment: "HUD row: predicted eventual glucose in Show Mode")
            case .activeInsulin:
                return NSLocalizedString("Active Insulin", comment: "HUD row: active insulin in Show Mode")
            case .activeCarbs:
                return NSLocalizedString("Active Carbs", comment: "HUD row: active carbs in Show Mode")
            case .loopStatus:
                return NSLocalizedString("Loop", comment: "HUD row: standalone loop status in Show Mode")
            case .sessionBolus:
                return NSLocalizedString("Session Bolus", comment: "HUD row: insulin bolused during Show Mode")
            case .sessionBasal:
                return NSLocalizedString("Session Basal", comment: "HUD row: net basal insulin delivered vs schedule during Show Mode")
            case .sessionInsulin:
                return NSLocalizedString("Session Insulin", comment: "HUD row: total net insulin (bolus + basal) during Show Mode")
            case .basalRate:
                return NSLocalizedString("Basal Rate", comment: "HUD row: the watch-set basal rate in Show Mode")
            }
        }

        var isLast: Bool {
            return self == ShowModeRow.allCases.last
        }
    }

    /// Which layout the table currently holds (nil until first configured). Rebuilding
    /// rows is only needed when the mode actually flips.
    private var tableShowsShowModeRows: Bool?

    private func configureTable(forShowMode showMode: Bool) {
        guard tableShowsShowModeRows != showMode else { return }
        tableShowsShowModeRows = showMode
        let count = showMode ? ShowModeRow.allCases.count : TableRow.allCases.count
        table.setNumberOfRows(count, withRowType: HUDRowController.className)
    }

    private func updateRowsForShowMode() {
        configureTable(forShowMode: true)
        let coordinator = ExtensionDelegate.shared().podLoanCoordinator
        for row in ShowModeRow.allCases {
            guard let cell = table.rowController(at: row.rawValue) as? HUDRowController else { continue }
            cell.setTitle(row.title)
            cell.setIsLastRow(row.isLast)
            cell.setContentInset(systemMinimumLayoutMargins)

            switch row {
            case .currentBG:
                cell.setDetail(currentBGDetail())
            case .eventualBG:
                if let output = predictionOutput {
                    cell.setDetail(formatBG(output.eventualBG, unit: output.unit))
                } else {
                    cell.setDetail("—")
                }
            case .activeInsulin:
                if let output = predictionOutput {
                    cell.setDetail(String(format: "%.2f U", output.activeInsulin))
                } else {
                    cell.setDetail("—")
                }
            case .activeCarbs:
                if let output = predictionOutput {
                    cell.setDetail(String(format: "%.0f g", output.activeCarbs))
                } else {
                    cell.setDetail("—")
                }
            case .loopStatus:
                let autoLoop = ExtensionDelegate.shared().autoLoop
                if !autoLoop.isEnabled {
                    cell.setDetail(NSLocalizedString("Open", comment: "HUD loop row detail: loop open"))
                } else if let cycle = autoLoop.lastCycle {
                    cell.setDetail(String(format: NSLocalizedString("Shadow · %@", comment: "HUD loop row detail: shadow decision"), cycle.decision.detailText))
                } else {
                    cell.setDetail(NSLocalizedString("Shadow · starting", comment: "HUD loop row detail: shadow armed, no cycle yet"))
                }
            case .sessionBolus:
                cell.setDetail(String(format: "%.2f U", coordinator.sessionBolusUnits))
            case .sessionBasal:
                cell.setDetail(Self.signedInsulinString(coordinator.sessionBasalDelivered))
            case .sessionInsulin:
                cell.setDetail(Self.signedInsulinString(coordinator.sessionInsulinTotal))
            case .basalRate:
                if coordinator.sessionSuspended {
                    cell.setDetail(NSLocalizedString("Suspended", comment: "HUD row detail when delivery is suspended in Show Mode"))
                } else if let rate = coordinator.sessionBasalRate {
                    if let scheduled = coordinator.currentScheduledRate {
                        // Rate plus signed deviation from schedule: "2.50 U/hr (+1.50)".
                        cell.setDetail(String(format: "%.2f U/hr (%+.2f)", rate, rate - scheduled))
                    } else {
                        cell.setDetail(String(format: "%.2f U/hr", rate))
                    }
                } else if let scheduled = coordinator.currentScheduledRate {
                    // Following the schedule — say what that means right now.
                    cell.setDetail(String(format: NSLocalizedString("Sched (%.2f)", comment: "HUD row detail: scheduled basal with the current rate"), scheduled))
                } else {
                    cell.setDetail(NSLocalizedString("Scheduled", comment: "HUD row detail when the pod runs its scheduled basal in Show Mode"))
                }
            }
        }
    }

    /// Signed U string for a net figure that may be negative or unavailable:
    /// "—" when nil (schedule not yet synced), else e.g. "+0.30 U" / "-0.20 U".
    private static func signedInsulinString(_ value: Double?) -> String {
        guard let value = value else { return "—" }
        return String(format: "%+.2f U", value)
    }

    // MARK: - Show Mode prediction rows

    private lazy var predictionEngine = WatchPredictionEngine(
        loopManager: ExtensionDelegate.shared().loopManager,
        coordinator: ExtensionDelegate.shared().podLoanCoordinator)
    private var predictionOutput: WatchPredictionOutput?
    private var recentSamples: [StoredGlucoseSample] = []
    private var lastPredictionRefresh: Date = .distantPast

    private var displayUnit: HKUnit {
        loopManager.settings.glucoseUnit ?? .milligramsPerDeciliter
    }

    private func formatBG(_ quantity: HKQuantity, unit: HKUnit) -> String {
        let value = quantity.doubleValue(for: unit)
        return unit == .milligramsPerDeciliter ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// "142 ↗ · 6m" — newest stored sample, a two-sample trend arrow, and age.
    private func currentBGDetail() -> String {
        guard let newest = recentSamples.last else {
            return NSLocalizedString("Tap to enter", comment: "HUD glucose row detail when no sample exists")
        }
        var parts = [formatBG(newest.quantity, unit: displayUnit)]
        if recentSamples.count >= 2 {
            let arrow = Self.trendSymbol(from: recentSamples[recentSamples.count - 2], to: newest)
            if !arrow.isEmpty { parts.append(arrow) }
        }
        let age = Int(-newest.startDate.timeIntervalSinceNow / 60)
        parts.append(age < 1 ? NSLocalizedString("now", comment: "HUD glucose row age (fresh)") : "\(age)m")
        return parts.joined(separator: " ")
    }

    /// Re-run the prediction for the HUD rows: on activation and at most every
    /// 5 minutes from the repaint timer. Anchors on the newest STORED sample
    /// (storeEntry false — a refresh must not fabricate readings).
    private func refreshPredictionForShowMode(force: Bool = false) {
        guard isInShowMode else { return }
        guard force || -lastPredictionRefresh.timeIntervalSinceNow > .minutes(5) else { return }
        lastPredictionRefresh = Date()

        loopManager.glucoseStore.getGlucoseSamples(start: Date(timeIntervalSinceNow: -.hours(2)), end: Date()) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .success(let samples) = result {
                    self.recentSamples = samples.sorted { $0.startDate < $1.startDate }
                }
                guard let newest = self.recentSamples.last else {
                    self.updateRowsForShowMode()
                    return
                }
                self.predictionEngine.predict(manualBG: newest.quantity, storeEntry: false) { output in
                    DispatchQueue.main.async {
                        if case .success(let output) = output {
                            self.predictionOutput = output
                        }
                        self.updateRowsForShowMode()
                    }
                }
            }
        }
    }

    private func updateGlucoseChart() {
        // The chart is hidden in Show Mode — skip the data generation and render.
        guard !isInShowMode else { return }

        loopManager.generateChartData { chartData in
            DispatchQueue.main.async {
                var chartData = chartData
                // In Show Mode the phone's prediction was computed BEFORE untethering
                // (assuming the phone was still running the loop) and only gets more
                // wrong with time — actively misleading. Keep the glucose history
                // (true data, honestly old); drop the prediction.
                if self.isInShowMode {
                    chartData?.predictedGlucose = nil
                }
                self.scene.data = chartData
                self.scene.setNeedsUpdate()
            }
        }
    }

    override func table(_ table: WKInterfaceTable, didSelectRowAt rowIndex: Int) {
        guard table == self.table else { return }

        if isInShowMode {
            switch ShowModeRow(rawValue: rowIndex) {
            case .loopStatus:
                presentController(withName: WatchPodControlController.className, context: PodControlEntry.loopToggle)
            case .currentBG, .eventualBG:
                // Tap the number → the entry dial + prediction readout. (A2
                // splits these into entry vs detail; one screen serves both today.)
                presentController(withName: WatchPodControlController.className, context: PodControlEntry.predict)
            default:
                break
            }
            return
        }

        guard case .cob? = TableRow(rawValue: rowIndex) else {
            return
        }

        presentController(withName: CarbEntryListController.className, context: nil)
    }

    @IBAction func didTapOnChart(_ sender: Any) {
        scene.decreaseVisibleDuration()
    }

    @IBAction func didDoubleTapOnChart(_ sender: Any) {
        scene.increaseVisibleDuration()
    }

}
