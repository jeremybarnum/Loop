//
//  PodLoanTimerCharacterizationTests.swift
//  WatchAppTests
//
//  Characterization, not specification: these tests record what the timers DO today so that
//  the refactor that follows has something to contradict. A characterization test that fails
//  after a refactor is doing its job — it means behavior moved, and the diff has to say why.
//
//  What makes this possible is the scheduling seam carrying its LABEL. Asserting "a request
//  arms exactly [request-timeout @25s]" is a claim about behavior; asserting "a request arms
//  one timer" is a claim about arithmetic, and arithmetic survives refactors that break
//  behavior.
//

import XCTest
import LoopKit
import LoopCore
@testable import WatchApp_Extension

/// Records every timer the controller arms, and fires none of them unless a test says so.
/// Holding all time still is the default because most characterization questions are "what
/// got armed", not "what happens when it fires".
final class TimerRecorder {
    struct Armed: Equatable, CustomStringConvertible {
        let label: String
        let delay: TimeInterval
        var description: String { "\(label)@\(delay < 1 ? String(format: "%.2f", delay) : String(format: "%.0f", delay))s" }
    }

    private let lock = NSLock()
    private var _armed: [Armed] = []
    private var _work: [String: DispatchWorkItem] = [:]

    /// Set to fire work items inline as they are armed — a virtual jump to every deadline.
    var fireInline = false

    var armed: [Armed] { lock.lock(); defer { lock.unlock() }; return _armed }
    var labels: [String] { armed.map(\.label) }

    func install(on controller: PodLoanWatchController) {
        controller.scheduler = { [weak self] delay, label, work in
            guard let self = self else { return }
            self.lock.lock()
            self._armed.append(Armed(label: label, delay: delay))
            self._work[label] = work
            let fire = self.fireInline
            self.lock.unlock()
            if fire { work.perform() }
        }
    }

    /// Fire one armed timer by label — virtual time for exactly that deadline.
    @discardableResult
    func fire(_ label: String) -> Bool {
        lock.lock()
        let work = _work[label]
        lock.unlock()
        guard let work = work else { return false }
        work.perform()
        return true
    }

    func reset() { lock.lock(); _armed.removeAll(); _work.removeAll(); lock.unlock() }
}

final class PodLoanTimerCharacterizationTests: XCTestCase {

    private var cacheDir: URL!
    private var cacheStore: PersistenceController!
    private var journalDir: URL!
    private var defaults: UserDefaults!
    /// The controller keeps `loopManager` private, so the test holds its own reference rather
    /// than widening production API for a test's convenience.
    private var loopManager: WatchLoopManager!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cacheStore = PersistenceController(directoryURL: cacheDir)
        journalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "PodLoanTimerCharacterization-\(UUID().uuidString)")!
    }

    override func tearDown() {
        // Never unlink a live store's directory synchronously — the async-init race answers
        // later reads with zero rows (the #103 lesson). Unique names mean nothing collides.
        cacheStore = nil; cacheDir = nil; journalDir = nil; defaults = nil; loopManager = nil
        super.tearDown()
    }

    private func makeController() -> PodLoanWatchController {
        let doseStore = DoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            basalProfile: nil,
            insulinSensitivitySchedule: nil,
            provenanceIdentifier: "TimerCharacterization"
        )
        let glucoseStore = GlucoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            cacheLength: .hours(4),
            provenanceIdentifier: "TimerCharacterization"
        )
        let carbStore = CarbStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            cacheLength: .hours(24),
            defaultAbsorptionTimes: LoopCoreConstants.defaultCarbAbsorptionTimes,
            provenanceIdentifier: "TimerCharacterization"
        )
        let manager = WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore)
        loopManager = manager
        return PodLoanWatchController(loopManager: manager,
                                      journal: LoanEventJournal(directory: journalDir),
                                      defaults: defaults)
    }

    /// Let the controller's serial queue drain, so a guard that runs after the call under test
    /// has actually run before we read the recorder.
    private func drain(_ controller: PodLoanWatchController, _ seconds: TimeInterval = 0.3) {
        let done = expectation(description: "queue drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    // MARK: - The real request path

    /// A bare request arms exactly one timer, and it is the 25 s no-grant timeout.
    func testRequestArmsOnlyTheRequestTimeout() {
        let controller = makeController()
        let rec = TimerRecorder()
        rec.install(on: controller)
        controller.send = { _ in }

        controller.requestLoan(watchBuild: "characterization")
        drain(controller)

        XCTAssertEqual(rec.armed, [.init(label: "request-timeout", delay: 25)])
    }

    /// A double-tap must not arm a second timeout — the pending request absorbs it. This is
    /// the timer-level statement of the dedupe; the seam test states the send-level one.
    func testDoubleTapArmsOneTimeoutNotTwo() {
        let controller = makeController()
        let rec = TimerRecorder()
        rec.install(on: controller)
        controller.send = { _ in }

        controller.requestLoan(watchBuild: "characterization")
        controller.requestLoan(watchBuild: "characterization")
        drain(controller)

        XCTAssertEqual(rec.labels, ["request-timeout"], "the second tap must not arm its own timeout")
    }

    /// After the timeout fires the controller is idle, and a fresh request arms a FRESH
    /// timeout. The recovery path has to re-arm or the second attempt hangs forever.
    func testTimeoutThenNewRequestArmsAFreshTimeout() {
        let controller = makeController()
        let rec = TimerRecorder()
        rec.install(on: controller)
        controller.send = { _ in }

        controller.requestLoan(watchBuild: "characterization")
        drain(controller)
        XCTAssertTrue(rec.fire("request-timeout"), "the timeout must have been armed")

        controller.requestLoan(watchBuild: "characterization")
        drain(controller)

        XCTAssertEqual(rec.labels, ["request-timeout", "request-timeout"],
                       "the recovered controller arms its own timeout rather than reusing the dead one")
    }

    // MARK: - The simulator flow driver
    //
    // Reachable here because WatchAppTests runs in the simulator, and the driver is a pure
    // phase machine on timers: no pod, no BLE, no WCSession. It is the only path that
    // characterizes a multi-timer transition without a real grant blob.

    /// The sim driver arms its grant and active hops together, up front — not chained.
    func testSimFlowArmsGrantAndActiveTogether() {
        let controller = makeController()
        defaults.set(true, forKey: "sim.fakeLoanFlow")
        let rec = TimerRecorder()
        rec.install(on: controller)
        controller.send = { _ in }

        controller.requestLoan(watchBuild: "characterization")
        drain(controller)

        XCTAssertEqual(rec.armed, [.init(label: "sim-grant", delay: 0.8),
                                   .init(label: "sim-active", delay: 2.4)],
                       "both hops are armed at start; each guards on the phase it expects to find")
    }

    /// Firing both hops in order walks idle → requested → takingOver → active, and the
    /// loan starts OPEN (R23). The phase guards are what make out-of-order firing safe.
    func testSimFlowHopsWalkToActiveAndOpenLoop() {
        let controller = makeController()
        defaults.set(true, forKey: "sim.fakeLoanFlow")
        let rec = TimerRecorder()
        rec.install(on: controller)
        controller.send = { _ in }

        controller.requestLoan(watchBuild: "characterization")
        drain(controller)
        XCTAssertEqual(controller.phase, .requested)

        rec.fire("sim-grant")
        XCTAssertEqual(controller.phase, .takingOver)

        rec.fire("sim-active")
        XCTAssertEqual(controller.phase, .active)
        XCTAssertFalse(loopManager.closedLoopEnabled,
                       "R23: a loan starts OPEN — the wearer closes it deliberately")
    }

    /// Out-of-order firing is inert: sim-active found the wrong phase and did nothing. This
    /// is the property that makes the arm-both-up-front design safe, so it is worth pinning
    /// before any refactor turns these into a chain.
    func testSimActiveIsInertWhenItsPhaseGuardFails() {
        let controller = makeController()
        defaults.set(true, forKey: "sim.fakeLoanFlow")
        let rec = TimerRecorder()
        rec.install(on: controller)
        controller.send = { _ in }

        controller.requestLoan(watchBuild: "characterization")
        drain(controller)

        rec.fire("sim-active")   // phase is .requested, not .takingOver
        XCTAssertEqual(controller.phase, .requested, "the guard held; no phase moved")

        rec.fire("sim-grant")
        XCTAssertEqual(controller.phase, .takingOver, "and the correct hop still works afterwards")
    }

    // MARK: - Harness integrity

    /// The harness's load-bearing assumption: what the recorder captures is the SEAM'S
    /// WRAPPER, not the raw body. Every other test here fires through that wrapper, so if the
    /// seam ever stopped wrapping — or wrapped something inert — those tests would keep
    /// passing while testing nothing. Firing the timeout must produce the body's real effects.
    func testRecorderCapturesTheSeamWrapperSoFiringHasRealEffects() {
        let controller = makeController()
        let rec = TimerRecorder()
        rec.install(on: controller)
        controller.send = { _ in }

        controller.requestLoan(watchBuild: "characterization")
        drain(controller)
        XCTAssertEqual(controller.phase, .requested)

        rec.fire("request-timeout")

        XCTAssertEqual(controller.phase, .idle, "the wrapper ran the real body")
        XCTAssertNotNil(controller.lastIdleNote, "and the body's user-visible reason was set")
    }

    // MARK: - Cross-epoch firing: NOT tested here, deliberately
    //
    // The seam LOGS a cross-epoch firing ("** armed e=N firing e=M **") but still calls
    // work.perform(). Every guard against a stale timer is hand-written at its call site,
    // across 14 sites — which is exactly the shape where one gets forgotten.
    //
    // That gap is real and is what phase 4 closes, but it is not honestly testable from here:
    // `epoch` is private and the only path that advances it is the simulator driver, whose
    // own call-site phase guards would mask the seam's policy rather than reveal it. A test
    // that drove it anyway would be asserting on the call-site guard while claiming to assert
    // on the seam. Phase 4 introduces the enforcement and its test together.

}
