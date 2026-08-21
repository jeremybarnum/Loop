//
//  PodLoanEpochScopingTests.swift
//  WatchAppTests
//
//  Phase 4: a timer armed for one loan must not fire into the next one.
//
//  The observable is `LogSink.shared.handler`, the process-wide sink SportLog already writes
//  through. It matters that the enforcement is observable at all: with no pump manager the
//  timer body early-returns anyway, so "refused because the epoch moved" and "ran and did
//  nothing" are otherwise byte-identical from outside — the same indistinguishability that
//  let an earlier bug survive two occurrences.
//

import XCTest
import LoopKit
import OmnipodKit
import LoopCore
import LoopAlgorithm
@testable import WatchApp

final class PodLoanEpochScopingTests: XCTestCase {

    private var cacheDir: URL!
    private var cacheStore: PersistenceController!
    private var journalDir: URL!
    private var defaults: UserDefaults!
    private var captured: [String] = []
    private let capturedLock = NSLock()

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cacheStore = PersistenceController(directoryURL: cacheDir)
        journalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "PodLoanEpochScoping-\(UUID().uuidString)")!
        defaults.set(true, forKey: "sim.fakeLoanFlow")   // the only path that advances `epoch`
        LogSink.shared.handler = { [weak self] line in
            guard let self = self else { return }
            self.capturedLock.lock(); self.captured.append(line); self.capturedLock.unlock()
        }
    }

    override func tearDown() {
        LogSink.shared.handler = nil   // process-wide: leaking it would bleed into other suites
        cacheStore = nil; cacheDir = nil; journalDir = nil; defaults = nil
        super.tearDown()
    }

    private func logLines() -> [String] {
        capturedLock.lock(); defer { capturedLock.unlock() }; return captured
    }
    private func clearLog() {
        capturedLock.lock(); captured.removeAll(); capturedLock.unlock()
    }

    private func makeController() async -> PodLoanWatchController {
        let doseStore = await DoseStore(
            healthKitSampleStore: nil, cacheStore: cacheStore,
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            provenanceIdentifier: "EpochScoping")
        let glucoseStore = await GlucoseStore(
            healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(4),
            provenanceIdentifier: "EpochScoping")
        let carbStore = CarbStore(
            healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(24),
            provenanceIdentifier: "EpochScoping")
        return PodLoanWatchController(
            loopManager: WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore),
            journal: LoanEventJournal(directory: journalDir),
            defaults: defaults)
    }

    private func drain(_ seconds: TimeInterval = 0.3) {
        let done = expectation(description: "queue drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    /// Walk the sim driver one full loan: idle -> takingOver -> active, advancing `epoch` by one.
    private func runOneLoanToActive(_ controller: PodLoanWatchController, _ rec: TimerRecorder) {
        controller.requestLoan(watchBuild: "epoch-scoping")
        drain()
        rec.fire("sim-grant")
        rec.fire("sim-active")
        XCTAssertEqual(controller.phase, .active)
    }

    /// End the loan through the sim hand-back, returning the controller to idle.
    private func handBack(_ controller: PodLoanWatchController, _ rec: TimerRecorder) {
        controller.beginHandback()
        drain()
        rec.fire("sim-handback")
        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: -

    /// THE POINT OF PHASE 4. post-dose-release drops the pod's BLE link 12 s after a dose and
    /// guards only on `.active` — but a LATER loan is also `.active`, so a hand-back and
    /// re-grant inside that window would let loan N tear down loan N+1's link. Scoped, it
    /// refuses, and says so.
    func testPostDoseReleaseRefusesToFireIntoALaterLoan() async {
        let controller = await makeController()
        let rec = TimerRecorder()
        rec.install(on: controller)
        controller.send = { _ in }

        runOneLoanToActive(controller, rec)          // epoch 1
        controller.releasePodAfterDose()             // arms post-dose-release, scoped to epoch 1
        drain()
        XCTAssertTrue(rec.labels.contains("post-dose-release"), "the release timer must be armed")

        handBack(controller, rec)
        runOneLoanToActive(controller, rec)          // epoch 2 — a different loan owns the pod

        clearLog()
        XCTAssertTrue(rec.fire("post-dose-release"), "the epoch-1 timer is still pending")

        let refused = logLines().contains { $0.contains("REFUSED post-dose-release") }
        XCTAssertTrue(refused, "a timer armed in epoch 1 must not act on the pod during epoch 2. Log was:\n\(logLines().joined(separator: "\n"))")
    }

    /// The other half, without which the test above passes for a build that refuses EVERYTHING:
    /// inside its own loan the same timer fires normally.
    func testPostDoseReleaseFiresNormallyWithinItsOwnLoan() async {
        let controller = await makeController()
        let rec = TimerRecorder()
        rec.install(on: controller)
        controller.send = { _ in }

        runOneLoanToActive(controller, rec)          // epoch 1
        controller.releasePodAfterDose()
        drain()

        clearLog()
        XCTAssertTrue(rec.fire("post-dose-release"))

        let lines = logLines()
        XCTAssertFalse(lines.contains { $0.contains("REFUSED post-dose-release") },
                       "same epoch — nothing to refuse")
        XCTAssertTrue(lines.contains { $0.contains("fired post-dose-release") },
                      "and it really did fire. Log was:\n\(lines.joined(separator: "\n"))")
    }

    /// Unscoped timers keep their old behavior. This is the guard against a later "just scope
    /// them all" edit: the two verify timers only OBSERVE the pod's BLE state, and a wedged
    /// peripheral is wedged regardless of which loan is running — scoping them would suppress
    /// a real signal rather than prevent a real action.
    func testUnscopedTimersStillFireAcrossAnEpochChange() async {
        let controller = await makeController()
        let rec = TimerRecorder()
        rec.install(on: controller)
        controller.send = { _ in }

        runOneLoanToActive(controller, rec)          // epoch 1
        handBack(controller, rec)
        runOneLoanToActive(controller, rec)          // epoch 2

        // sim-handback was armed in epoch 1 and is unscoped; firing it again in epoch 2 must
        // reach its body (where its own handbackRequested guard decides), not be refused.
        clearLog()
        rec.fire("sim-handback")
        XCTAssertFalse(logLines().contains { $0.contains("REFUSED") },
                       "only opted-in timers are epoch-scoped")
    }

    /// Reproduces a field failure. A cycle that reclaims TWICE — once because the pump
    /// data was 5 min stale, once to dose — called releasePodAfterDose twice 2.7 s apart, and
    /// TWO independent 12 s releases fired two seconds apart. The second was harmless
    /// only because the first had already released the link; had a new reclaim reconnected in
    /// that gap, both of its guards would have passed and it would have dropped the link out
    /// from under a live dose.
    ///
    /// Note this is deliberately NOT an epoch problem — both timers belong to the same epoch,
    /// so `epochScoped` cannot catch it. Cancel-before-rearm is what does.
    func testASecondDoseInTheSameCycleRearmsTheReleaseRatherThanStackingIt() async {
        let controller = await makeController()
        let rec = TimerRecorder()
        rec.install(on: controller)
        controller.send = { _ in }

        runOneLoanToActive(controller, rec)

        controller.releasePodAfterDose()     // the stale-pump-data reclaim
        drain()
        controller.releasePodAfterDose()     // the dose itself, moments later
        drain()

        let armings = rec.armed.filter { $0.label == "post-dose-release" }
        XCTAssertEqual(armings.count, 2, "each call still arms — the fix is cancellation, not suppression")

        // The first work item must have been cancelled, so only ONE release can actually run.
        // The seam reports a cancelled item as `skipped`, which is the observable.
        clearLog()
        rec.fireAll("post-dose-release")

        let lines = logLines()
        let fired = lines.filter { $0.contains("fired post-dose-release") }.count
        let skipped = lines.filter { $0.contains("skipped post-dose-release") }.count
        XCTAssertEqual(fired, 1, "exactly one release may run. Log was:\n\(lines.joined(separator: "\n"))")
        XCTAssertEqual(skipped, 1, "and the superseded one must say so rather than vanish")
    }

    /// A timer armed before any grant has NO epoch, and must never be suppressed by scoping —
    /// the request timeout is exactly this case, and it is the path that rescues a hung
    /// request. Blanket enforcement would have broken it, which is why scoping is opt-in.
    func testTimersArmedBeforeAnyGrantAreNeverRefused() async {
        let controller = await makeController()
        defaults.set(false, forKey: "sim.fakeLoanFlow")   // the REAL request path
        let rec = TimerRecorder()
        rec.install(on: controller)
        controller.send = { _ in }

        controller.requestLoan(watchBuild: "epoch-scoping")
        drain()

        clearLog()
        XCTAssertTrue(rec.fire("request-timeout"))
        XCTAssertFalse(logLines().contains { $0.contains("REFUSED") },
                       "armed with epoch nil — there is no loan for it to outlive")
        XCTAssertEqual(controller.phase, .idle, "and it did its job")
    }
}

// MARK: - The lean reacquisition path's one piece of persisted state

/// Discovery is name resolution: it turns a pod id we already know into a CoreBluetooth
/// handle THIS device can use. Handles are per-device, so the one in a grant is the phone's
/// and useless here — but ours is reusable for every later loan with the same pod.
///
/// These cover the decision logic only. Whether a cached handle is still VALID is a question
/// only the radio can answer, which is why the caller keeps a discovery fallback.
final class PodLoanBleIdentifierCacheTests: XCTestCase {

    private let podA: UInt32 = 0x177E6B7E
    private let podB: UInt32 = 0x1A2B3C4D

    override func setUp() {
        super.setUp()
        PodLoanBleIdentifierCache.removeAll()
    }

    override func tearDown() {
        PodLoanBleIdentifierCache.removeAll()
        super.tearDown()
    }

    func testAnUnknownPodHasNoHandleSoTheCallerMustDiscover() {
        XCTAssertNil(PodLoanBleIdentifierCache.identifier(forPodAddress: podA))
    }

    func testAHandleSurvivesForTheSamePod() {
        PodLoanBleIdentifierCache.store("UUID-A", forPodAddress: podA)
        XCTAssertEqual(PodLoanBleIdentifierCache.identifier(forPodAddress: podA), "UUID-A")
    }

    /// The key must be the POD, not "the last pod we saw". A pod change every three days
    /// would otherwise hand the new pod the old pod's handle — a bare connect() has no
    /// timeout, so that would hang rather than fail.
    func testHandlesAreKeyedPerPodAndDoNotBleed() {
        PodLoanBleIdentifierCache.store("UUID-A", forPodAddress: podA)
        PodLoanBleIdentifierCache.store("UUID-B", forPodAddress: podB)
        XCTAssertEqual(PodLoanBleIdentifierCache.identifier(forPodAddress: podA), "UUID-A")
        XCTAssertEqual(PodLoanBleIdentifierCache.identifier(forPodAddress: podB), "UUID-B")
    }

    /// Re-adopting the same pod on a different handle must REPLACE, not accumulate: the
    /// stale one can never be retrieved on this device and would pin the radio scanning.
    func testReAdoptingReplacesTheHandle() {
        PodLoanBleIdentifierCache.store("UUID-OLD", forPodAddress: podA)
        PodLoanBleIdentifierCache.store("UUID-NEW", forPodAddress: podA)
        XCTAssertEqual(PodLoanBleIdentifierCache.identifier(forPodAddress: podA), "UUID-NEW")
    }


    /// THE REGRESSION THIS SUITE MISSED (field 2026-08-20, epochs 150-152).
    ///
    /// `PodState` decodes the LTK and the BLE handle in a SINGLE `if let`, so removing
    /// `bleIdentifier` from a grant's raw state silently removes the pod's ENCRYPTION KEY with
    /// it. The takeover then connects normally and the pod hangs up ~100 ms after the first
    /// command — which looks nothing like "a key is missing", and cost three grants to spot.
    ///
    /// Every cache test below passed while that shipped, because the bug was never in the
    /// cache: it was in what the CALLER does on a cache MISS. This pins the coupling so nobody
    /// "tidies up" the foreign identifier again.
    func testLtkAndHandleAreCoupledInPodStateDecoding() throws {
        let podStatePath = #filePath
            .replacingOccurrences(of: "Loop/WatchAppTests/PodLoanEpochScopingTests.swift",
                                  with: "OmnipodKit/OmnipodKit/PumpManager/PodState.swift")
        let source = try String(contentsOfFile: podStatePath, encoding: .utf8)
        guard let ltkLine = source.range(of: "let ltkString = rawValue[\"ltk\"]") else {
            return XCTFail("PodState no longer decodes ltk the way this test expects — re-check every site that edits a grant's raw podState")
        }
        // The handle must still be read by the SAME condition, i.e. within a couple of lines.
        let tail = source[ltkLine.upperBound...].prefix(200)
        XCTAssertTrue(tail.contains("bleIdentifier"),
                      "ltk and bleIdentifier are no longer decoded together. If that is deliberate, PodLoanWatchController may now drop the handle alone — re-read its handle-substitution comment before changing it.")
    }

    /// `forget` is the escape hatch for a handle proven wrong, so the next loan pays for
    /// discovery once instead of pending forever on a dead UUID.
    func testForgettingSendsUsBackToDiscoveryForThatPodOnly() {
        PodLoanBleIdentifierCache.store("UUID-A", forPodAddress: podA)
        PodLoanBleIdentifierCache.store("UUID-B", forPodAddress: podB)
        PodLoanBleIdentifierCache.forget(podAddress: podA)
        XCTAssertNil(PodLoanBleIdentifierCache.identifier(forPodAddress: podA))
        XCTAssertEqual(PodLoanBleIdentifierCache.identifier(forPodAddress: podB), "UUID-B",
                       "forgetting one pod must not disturb another")
    }
}
