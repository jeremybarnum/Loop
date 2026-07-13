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
    private var journalObserver: NSObjectProtocol?
    private var phaseCancellable: AnyCancellable?
    private var heartbeat: Timer?

    /// The anchor BG is too old to project forward from — mirrors Loop's
    /// `glucoseTooOld` (same `inputDataRecencyInterval`). Evaluated live so it
    /// flips as the reading ages, not only when a new prediction is computed.
    /// IOB/COB are unaffected (they decay from doses, not glucose).
    var isAnchorStale: Bool {
        guard let newest = recentSamples.last else { return true }
        return -newest.startDate.timeIntervalSinceNow > LoopCoreConstants.inputDataRecencyInterval
    }

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

        // A dose landing in the journal (bolus/temp/suspend) changes IOB and the
        // prediction — recompute even though it's not a glucose change.
        journalObserver = NotificationCenter.default.addObserver(forName: WatchPodLoanCoordinator.journalDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }

        // The instant Show Mode activates, the watch already has everything the
        // phone loop had a moment ago — so produce an eventual BG immediately,
        // not on the next page lifecycle event.
        phaseCancellable = coordinator.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                if case .active = phase {
                    self.refresh(force: true)
                    self.startHeartbeat()
                } else {
                    self.stopHeartbeat()
                    self.reset()   // clear so a stale eventual can't linger past the session
                }
            }
    }

    /// A 60-second tick while active: re-render (so the anchor's age and the
    /// stale/fresh state flip promptly even with no new sample) and let the
    /// throttled recompute pick up IOB decay.
    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.post()
                self.refresh()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }

    deinit {
        if let sampleObserver {
            NotificationCenter.default.removeObserver(sampleObserver)
        }
        if let journalObserver {
            NotificationCenter.default.removeObserver(journalObserver)
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
