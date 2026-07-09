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

        if glucoseScene.isPaused {
            log.default("didAppear() unpausing")
            glucoseScene.isPaused = false
        } else {
            log.default("didAppear() not paused")
            glucoseScene.isPaused = false
        }

        // Force an update when our pixels need to move
        let pixelsWide = scene.size.width * WKInterfaceDevice.current().screenScale
        let pixelInterval = scene.visibleDuration / TimeInterval(pixelsWide)

        timer = Timer.scheduledTimer(withTimeInterval: pixelInterval, repeats: true) { [weak self] _ in
            self?.log.default("Timer fired, triggering update")
            self?.scene.setNeedsUpdate()
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
                }
            }
        ]

        if glucoseScene.isPaused {
            log.default("willActivate() unpausing")
            glucoseScene.isPaused = false
        } else {
            log.default("willActivate()")
        }

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

        // In Show Mode the phone-fed context is stale by construction (the phone is
        // away) — the watch is driving the pod, so show pod-session values instead.
        if isInShowMode {
            updateRowsForShowMode()
        } else {
            guard let activeContext = loopManager.activeContext else {
                return
            }
            updateRows(for: activeContext)
        }

        if glucoseScene.isPaused {
            log.default("update() unpausing")
            glucoseScene.isPaused = false
        }

        updateGlucoseChart()
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

    /// The two Show Mode rows: what the watch has done to the pod this session. No
    /// reservoir (a real pod reports only ">50 U" for most of its life — useless here),
    /// no IOB/COB placeholders (dashes say nothing actionable; real IOB returns with
    /// the watch-local tracking work).
    private enum ShowModeRow: Int, CaseIterable {
        case sessionBolus
        case basalRate

        var title: String {
            switch self {
            case .sessionBolus:
                return NSLocalizedString("Session Bolus", comment: "HUD row title for insulin bolused during Show Mode")
            case .basalRate:
                return NSLocalizedString("Basal Rate", comment: "HUD row title for the watch-set basal in Show Mode")
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
            case .sessionBolus:
                cell.setDetail(String(format: "%.2f U", coordinator.sessionBolusUnits))
            case .basalRate:
                if coordinator.sessionSuspended {
                    cell.setDetail(NSLocalizedString("Suspended", comment: "HUD row detail when delivery is suspended in Show Mode"))
                } else if let rate = coordinator.sessionBasalRate {
                    cell.setDetail(String(format: "%.2f U/hr", rate))
                } else {
                    cell.setDetail(NSLocalizedString("Scheduled", comment: "HUD row detail when the pod runs its scheduled basal in Show Mode"))
                }
            }
        }
    }

    private func updateGlucoseChart() {
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
        // Show Mode rows have different indices (and no carb entry — the phone is away).
        guard table == self.table, !isInShowMode, case .cob? = TableRow(rawValue: rowIndex) else {
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
