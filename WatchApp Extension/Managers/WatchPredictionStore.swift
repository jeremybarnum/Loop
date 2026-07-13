//
//  WatchPredictionStore.swift
//  WatchApp Extension
//
//  The single source of the watch's current prediction during Show Mode.
//  App-scoped (owned by ExtensionDelegate) so BOTH HUD pages — the main
//  page's eventual-BG header and the swipe page's rows — read one output
//  instead of each computing its own (which drifted: the header and rows
//  could show different numbers). Refreshes when Show Mode activates, when a
//  new glucose sample lands, and at most every 5 minutes otherwise. Anchors
//  on the newest STORED sample (storeEntry:false — a refresh never fabricates
//  a reading).
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import Combine
import HealthKit
import LoopKit
import LoopCore
import os.log

@MainActor
final class WatchPredictionStore {

    /// Posted (main thread) whenever `latestOutput` or `recentSamples` changes,
    /// so the UIKit HUD controllers re-render. Loop-idiomatic: mirrors
    /// LoopDataManager.didUpdateContextNotification.
    static let didUpdateNotification = Notification.Name("WatchPredictionStore.didUpdate")

    private(set) var latestOutput: WatchPredictionOutput?
    /// Recent glucose (oldest→newest) backing the header/rows' value+trend.
    private(set) var recentSamples: [StoredGlucoseSample] = []

    private let log = OSLog(category: "WatchPredictionStore")
    private let loopManager: LoopDataManager
    private let coordinator: WatchPodLoanCoordinator
    private lazy var engine = WatchPredictionEngine(loopManager: loopManager, coordinator: coordinator)

    private var lastRefresh: Date = .distantPast
    private var sampleObserver: NSObjectProtocol?
    private var phaseCancellable: AnyCancellable?

    private var isActive: Bool {
        if case .active = coordinator.phase { return true }
        return false
    }

    init(loopManager: LoopDataManager, coordinator: WatchPodLoanCoordinator) {
        self.loopManager = loopManager
        self.coordinator = coordinator

        // New sample (dialed entry landing, backfill sync) → recompute now.
        sampleObserver = NotificationCenter.default.addObserver(forName: GlucoseStore.glucoseSamplesDidChange, object: loopManager.glucoseStore, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }

        // The instant Show Mode activates, the watch already has everything the
        // phone loop had a moment ago — so produce an eventual BG immediately,
        // not on the next page lifecycle event.
        phaseCancellable = coordinator.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard case .active = phase else { return }
                self?.refresh(force: true)
            }
    }

    deinit {
        if let sampleObserver {
            NotificationCenter.default.removeObserver(sampleObserver)
        }
    }

    /// Recompute from the newest stored sample. Throttled to 5 min unless forced.
    func refresh(force: Bool = false) {
        guard isActive else { return }
        guard force || -lastRefresh.timeIntervalSinceNow > .minutes(5) else { return }
        lastRefresh = Date()

        loopManager.glucoseStore.getGlucoseSamples(start: Date(timeIntervalSinceNow: -.hours(2)), end: Date()) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .success(let samples) = result {
                    self.recentSamples = samples.sorted { $0.startDate < $1.startDate }
                }
                guard let newest = self.recentSamples.last else {
                    self.latestOutput = nil
                    self.post()
                    return
                }
                self.engine.predict(manualBG: newest.quantity, storeEntry: false) { output in
                    Task { @MainActor in
                        if case .success(let output) = output {
                            self.latestOutput = output
                        }
                        self.post()
                    }
                }
            }
        }
    }

    /// Clear when a session ends so a stale eventual can't linger into the next.
    func reset() {
        latestOutput = nil
        recentSamples = []
        lastRefresh = .distantPast
        post()
    }

    private func post() {
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }
}
