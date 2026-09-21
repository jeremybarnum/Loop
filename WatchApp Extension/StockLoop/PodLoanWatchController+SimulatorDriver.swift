//
//  PodLoanWatchController+SimulatorDriver.swift
//  StockLoop
//
//  Part of PodLoanWatchController (see PodLoanWatchController.swift). Split by concern; stored properties live in the core class.
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import OmnipodKit
import WatchKit
import os.log

extension PodLoanWatchController {
    #if targetEnvironment(simulator)

    func simDriveStart() {
        queue.async {
            guard self.phase == .idle else { return }
            SportLog.event("sim", "SIM start — driving idle→active on timers (no pod/BLE)")
            self.lastIdleNote = nil
            self.attemptStartedAt = self.now()
            self.phase = .requested
            self.schedule(after: 0.8, label: "sim-grant") { [weak self] in
                guard let self, self.phase == .requested else { return }
                self.attemptStartedAt = self.now()
                self.phase = .takingOver
            }
            self.schedule(after: 2.4, label: "sim-active") { [weak self] in
                guard let self, self.phase == .takingOver else { return }
                self.epoch = (self.epoch ?? 0) + 1
                self.phase = .active
                self.loopManager.setClosedLoopEnabled(false)
                self.simStartGlucoseFeed()
            }
        }
    }

    func simDriveHandback() {
        queue.async {
            guard self.phase == .active else { return }
            SportLog.event("sim", "SIM hand-back — draining to idle")
            self.handbackRequested = true
            self.schedule(after: 2.5, label: "sim-handback") { [weak self] in
                guard let self, self.handbackRequested else { return }
                self.simStopGlucoseFeed()
                self.handbackRequested = false
                self.attemptStartedAt = nil
                self.phase = .idle
            }
        }
    }

    func simStartGlucoseFeed() {
        simStopGlucoseFeed()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 30)

        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.loopManager.simIngestPhoneGlucose() }
        }
        timer.resume()
        simGlucoseTimer = timer
    }

    private func simStopGlucoseFeed() {
        simGlucoseTimer?.cancel()
        simGlucoseTimer = nil
    }
    #endif
}
