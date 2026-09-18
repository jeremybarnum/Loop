//
//  WakeResumeTests.swift
//  WatchAppTests
//
//  R40(e), re-ruled 2026-09-18: a relaunch mid-loan is a STOCK relaunch. The controller saves
//  the pump manager's raw state while it holds the pod and rebuilds from it at launch — the
//  phone's own PumpManagerState persistence, on the wrist. Only an ACTIVE loan with saved
//  state resumes; every other relaunch keeps the data-first drain of spec §3.2.
//

import XCTest
import LoopKit
import LoopAlgorithm
import LoopCore
@testable import WatchApp

final class WakeResumeTests: XCTestCase {

    private var cacheDir: URL!
    private var cacheStore: PersistenceController!
    private var journalDir: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cacheStore = PersistenceController(directoryURL: cacheDir)
        journalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "WakeResumeTests-\(UUID().uuidString)")!
    }

    override func tearDown() {
        cacheStore = nil
        cacheDir = nil
        journalDir = nil
        defaults = nil
        super.tearDown()
    }

    private func makeController() async -> PodLoanWatchController {
        let doseStore = await DoseStore(healthKitSampleStore: nil, cacheStore: cacheStore,
                                        longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
                                        provenanceIdentifier: "WakeResumeTests")
        let glucoseStore = await GlucoseStore(healthKitSampleStore: nil, cacheStore: cacheStore,
                                              cacheLength: .hours(4), provenanceIdentifier: "WakeResumeTests")
        let carbStore = CarbStore(healthKitSampleStore: nil, cacheStore: cacheStore,
                                  cacheLength: .hours(24), provenanceIdentifier: "WakeResumeTests")
        let manager = WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore)
        return PodLoanWatchController(loopManager: manager,
                                      journal: LoanEventJournal(directory: journalDir),
                                      defaults: defaults)
    }

    /// The smallest raw state `OmniPumpManager(rawState:)` accepts: a basal schedule, and a
    /// controller id so it takes the DASH path the watch uses. No pod — nothing to connect to.
    private var readablePumpState: [String: Any] {
        ["basalSchedule": ["entries": [["rate": 1.0, "startTime": 0.0]]],
         "controllerId": UInt32(0x1234_5678), "podId": UInt32(0x1234_5679)]
    }

    private func relaunch(phase: PodLoanWatchController.Phase, epoch: Int = 7, savedState: [String: Any]?) async -> PodLoanWatchController {
        defaults.set(phase.rawValue, forKey: PodLoanWatchController.Keys.phase)
        defaults.set(epoch, forKey: PodLoanWatchController.Keys.epoch)
        if let savedState { defaults.set(savedState, forKey: PodLoanWatchController.Keys.pumpState) }
        let c = await makeController()
        c.resumeIfNeeded()   // what the session does once the hooks are wired
        c.queue.sync { }     // the resume is built on the queue; wait for it
        return c
    }

    func testActiveLoanWithSavedPodStateResumes() async {
        let c = await relaunch(phase: .active, savedState: readablePumpState)
        XCTAssertEqual(c.phase, .active, "an active loan with saved pod state resumes — not drained")
        XCTAssertEqual(c.epoch, 7, "the loan's epoch carries over unchanged")
        XCTAssertNotNil(c.pumpManager, "the pump manager is rebuilt from the saved state")
        XCTAssertNotNil(c.loopManager.pumpManager, "and handed to the loop, so dosing can resume")
        XCTAssertNotNil(defaults.dictionary(forKey: PodLoanWatchController.Keys.pumpState),
                        "the saved state stays on disk — the next relaunch resumes the same way")
    }

    func testActiveLoanWithoutSavedStateStillDrains() async {
        // A loan from before this build has no saved state: the pre-existing behaviour holds.
        let c = await relaunch(phase: .active, savedState: nil)
        XCTAssertEqual(c.phase, .recoveredDrain)
        XCTAssertNil(c.pumpManager)
    }

    func testUnreadableSavedStateFallsBackToDrain() async {
        let c = await relaunch(phase: .active, savedState: ["garbage": 1])
        XCTAssertEqual(c.phase, .recoveredDrain, "unreadable state returns the pod, as a relaunch always did")
        XCTAssertNil(c.pumpManager)
        XCTAssertNil(defaults.dictionary(forKey: PodLoanWatchController.Keys.pumpState), "and the bad state is discarded")
    }

    func testOnlyAnActiveLoanResumes() async {
        // Saved state can outlive an ACTIVE phase only by a crash inside teardown; mid-transition
        // phases keep their existing handling whatever is on disk.
        for phase in [PodLoanWatchController.Phase.handingBack, .revoked, .recoveredDrain] {
            let c = await relaunch(phase: phase, savedState: readablePumpState)
            XCTAssertEqual(c.phase, .recoveredDrain, "\(phase) at relaunch drains")
            XCTAssertNil(c.pumpManager, "\(phase) never rebuilds the pump")
        }
    }

    func testTeardownClearsSavedState() async {
        let c = await relaunch(phase: .active, savedState: readablePumpState)
        XCTAssertNotNil(c.pumpManager)
        c.queue.sync { c.teardownPump() }
        XCTAssertNil(c.pumpManager)
        XCTAssertNil(defaults.dictionary(forKey: PodLoanWatchController.Keys.pumpState),
                     "no pod held, nothing to resume — a relaunch now sees an ordinary closed loan")
    }
}
