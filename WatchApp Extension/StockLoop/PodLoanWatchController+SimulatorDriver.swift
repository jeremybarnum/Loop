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

    // MARK: - Simulator flow driver — NEVER compiled into a device build.
    #if targetEnvironment(simulator)
    // Drives the loan `phase` on timers so the watch UI FLOWS run without a pod/phone/BLE.
    // Touches NO pod, NO BLE, NO WCSession, NO dosing — only the observable `phase` the glance
    // polls. Gated by targetEnvironment(simulator): it cannot reach a device, where this
    // controller drives the real Omnipod enact seam. (Stage 2 will feed the phone's stock CGM
    // simulator into the real glucose store so prediction/DoseMath run for real; the pod enact
    // is faked. This stage is the flow skeleton.)
    func simDriveStart() {
        queue.async {
            guard self.phase == .idle else { return }
            SportLog.event("sim", "SIM start — driving idle→active on timers (no pod/BLE)")
            self.lastIdleNote = nil
            self.attemptStartedAt = self.now()
            self.phase = .requested
            self.schedule(after: 0.8, label: "sim-grant") { [weak self] in
                guard let self, self.phase == .requested else { return }
                self.attemptStartedAt = self.now()          // reset anchor for the ~10s takeover bar
                self.phase = .takingOver
            }
            self.schedule(after: 2.4, label: "sim-active") { [weak self] in
                guard let self, self.phase == .takingOver else { return }
                self.epoch = (self.epoch ?? 0) + 1
                self.phase = .active
                self.loopManager.setClosedLoopEnabled(false)   // Loans start OPEN
                self.simStartGlucoseFeed()                     // stage 2: feed phone-sim BG → real loop
            }
        }
    }

    func simDriveHandback() {
        queue.async {
            guard self.phase == .active else { return }
            SportLog.event("sim", "SIM hand-back — draining to idle")
            self.handbackRequested = true
            self.schedule(after: 2.5, label: "sim-handback") { [weak self] in
                guard let self, self.handbackRequested else { return }   // a cancel aborts the drain
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
        // Hops to main because the injection reads the watch's shared context, which is
        // main-actor state; the timer itself stays on the loan queue.
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
