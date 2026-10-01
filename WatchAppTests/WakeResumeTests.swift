//
//  WakeResumeTests.swift
//  WatchAppTests
//
//  A relaunch mid-loan rebuilds from saved pump state, as the phone does. Only an active loan
//  with saved state resumes; anything else drains.
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

    /// The grant's settings payload on disk, including the supplement's basal schedule.
    private func persistGrantedSettings() {
        let basal = BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)])!
        let raw = try! PropertyListSerialization.data(fromPropertyList: LoopSettings().rawValue, format: .binary, options: 0)
        let supplement = try! PropertyListSerialization.data(fromPropertyList: ["basalRateSchedule": basal.rawValue], format: .binary, options: 0)
        defaults.set(["raw": raw, "supplement": supplement, "interim": true, "overrideRecords": true],
                     forKey: PodLoanWatchController.Keys.grantedTherapySettings)
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
        let manager = WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore,
                                       defaults: defaults, stateDirectory: journalDir)
        return PodLoanWatchController(loopManager: manager,
                                      journal: LoanEventJournal(directory: journalDir),
                                      defaults: defaults, stateDirectory: journalDir)
    }

    /// The smallest raw state `OmniPumpManager(rawState:)` accepts: a basal schedule, and a
    /// controller id so it takes the DASH path the watch uses. No pod — nothing to connect to.
    private var readablePumpState: [String: Any] {
        ["basalSchedule": ["entries": [["rate": 1.0, "startTime": 0.0]]],
         "controllerId": UInt32(0x1234_5678), "podId": UInt32(0x1234_5679)]
    }

    private func relaunch(phase: PodLoanWatchController.Phase, epoch: Int = 7, savedState: [String: Any]?,
                          granted: Bool = true) async -> PodLoanWatchController {
        if granted { persistGrantedSettings() }
        defaults.set(phase.rawValue, forKey: PodLoanWatchController.Keys.phase)
        defaults.set(epoch, forKey: PodLoanWatchController.Keys.epoch)
        if let savedState { defaults.set(savedState, forKey: PodLoanWatchController.Keys.pumpState) }
        let c = await makeController()
        c.resumeIfNeeded()   // what the session does once the hooks are wired
        c.queue.sync { }     // the resume is built on the queue; wait for it
        return c
    }

    /// Keys no build reads any more are removed at launch.
    func testRetiredKeysAreSweptAtLaunch() async {
        for key in PodLoanWatchController.retiredKeys { defaults.set(true, forKey: key) }
        _ = await makeController()
        for key in PodLoanWatchController.retiredKeys { XCTAssertNil(defaults.object(forKey: key), key) }
    }

    /// The direct-reading clock is memory, seeded at launch from the sensor; the old key goes.
    func testDirectReadingClockIsSeededNotReadFromDefaults() async {
        defaults.set(Date(), forKey: WatchLoopManager.lastDirectG7DefaultsKey)
        let c = await makeController()
        XCTAssertNil(defaults.object(forKey: WatchLoopManager.lastDirectG7DefaultsKey), "the retired key is swept")
        XCTAssertNil(c.loopManager.lastGlucoseSourceStamps.direct, "a stored stamp no longer feeds the clock")

        let reading = Date().addingTimeInterval(-300)
        c.loopManager.seedLastDirectG7At(reading)
        XCTAssertEqual(c.loopManager.lastGlucoseSourceStamps.direct, reading)
        c.loopManager.seedLastDirectG7At(reading.addingTimeInterval(-600))
        XCTAssertEqual(c.loopManager.lastGlucoseSourceStamps.direct, reading, "a seed never moves the clock back")
    }

    /// The G7 state moves from UserDefaults to its file once; a later launch reads only the file.
    func testCGMStateMigratesOnceToItsFile() async {
        let activated = Date().addingTimeInterval(-.hours(24))
        defaults.set(["sensorID": "DXCMqL", "activatedAt": activated], forKey: WatchLoopManager.cgmStateDefaultsKey)
        let first = await makeController()
        XCTAssertEqual(first.loopManager.cgmManagerState.wrappedValue?["sensorID"] as? String, "DXCMqL")
        XCTAssertEqual(first.loopManager.cgmManagerState.wrappedValue?["activatedAt"] as? Date, activated)
        XCTAssertNil(defaults.object(forKey: WatchLoopManager.cgmStateDefaultsKey), "the legacy key goes once the file holds it")

        defaults.set(["sensorID": "STALE"], forKey: WatchLoopManager.cgmStateDefaultsKey)
        let second = await makeController()
        XCTAssertEqual(second.loopManager.cgmManagerState.wrappedValue?["sensorID"] as? String, "DXCMqL",
                       "a re-seeded legacy key never overrides the file")
        XCTAssertNil(defaults.object(forKey: WatchLoopManager.cgmStateDefaultsKey))
    }

    func testActiveLoanWithSavedPodStateResumes() async {
        let c = await relaunch(phase: .active, savedState: readablePumpState)
        XCTAssertEqual(c.phase, .active, "an active loan with saved pod state resumes — not drained")
        XCTAssertEqual(c.epoch, 7, "the loan's epoch carries over unchanged")
        XCTAssertNotNil(c.pumpManager, "the pump manager is rebuilt from the saved state")
        XCTAssertNotNil(c.loopManager.pumpManager, "and handed to the loop, so dosing can resume")
        XCTAssertTrue(c.isLoanActiveNonBlocking,
                      "the main-safe mirror is set — init loads the phase without its didSet (bench 2026-09-18: onboarding screen + blank IOB)")
        XCTAssertNotNil(c.loopManager.settings.basalRateSchedule,
                        "the granted therapy settings came back from disk (bench 2026-09-18: blank IOB, no schedule)")
        XCTAssertTrue(c.phoneSupportsInterimHandback,
                      "the phone's hand-back capability comes back with the grant payload (bench 2026-09-18: resumed loan handed back single-phase)")
        XCTAssertNotNil(defaults.dictionary(forKey: PodLoanWatchController.Keys.pumpState),
                        "the saved state stays on disk — the next relaunch resumes the same way")
    }

    func testResumeWithoutTherapySettingsDrains() async {
        // Saved pod state but no granted settings on disk: a pump that cannot dose is not resumed.
        let c = await relaunch(phase: .active, savedState: readablePumpState, granted: false)
        XCTAssertEqual(c.phase, .recoveredDrain)
        XCTAssertNil(c.pumpManager)
        XCTAssertNil(defaults.dictionary(forKey: PodLoanWatchController.Keys.pumpState))
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

    func testLastLoopTimeSurvivesRelaunch() async {
        // Display only, but it is what the ring reads: after a resume the ring must show the
        // real age of the last cycle, as the phone's does after a relaunch, not "never".
        let first = await makeController()
        let completed = Date(timeIntervalSinceNow: -180)
        first.loopManager.seedLastLoopCompleted(completed, source: "test")
        let relaunched = await makeController()
        XCTAssertEqual(relaunched.loopManager.lastLoopCompleted?.timeIntervalSince1970 ?? 0,
                       completed.timeIntervalSince1970, accuracy: 0.001,
                       "the last-loop time comes back from disk (bench 2026-09-18: gray ring for one cycle)")
    }

    func testLiveHandbackWithPhoneUnreachableFailsFastAndKeepsTheLoan() async {
        // Ruled 2026-09-19: a live hand-back is never queued. Out of reach, End fails at once
        // and the loan continues — no offer is sent, nothing can land later and take the pod.
        let c = await relaunch(phase: .active, savedState: readablePumpState)
        XCTAssertNotNil(c.pumpManager)
        c.isPhoneReachable = { false }
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        c.beginHandback()
        c.queue.sync { }
        XCTAssertEqual(c.phase, .active, "the loan continues")
        XCTAssertNotNil(c.pumpManager, "the watch still holds the pod")
        XCTAssertTrue(sent.isEmpty, "no offer left the watch — nothing queued to land later")
        XCTAssertNotNil(c.debugSnapshot().handbackFailureText, "and the glance has the reason to show, on screen rather than as a notification")
    }

    func testPhoneRefusalEndsTheHandbackAtOnceAndKeepsTheLoan() async throws {
        // Goal (a), 2026-09-19: with the phone's Bluetooth off, End is refused and the watch
        // knows at once — no budget to wait out. The phone says so; the watch shows its reason.
        let c = await relaunch(phase: .active, savedState: readablePumpState)
        c.isPhoneReachable = { true }
        var sent = 0
        c.send = { _ in sent += 1 }
        c.beginHandback()
        c.queue.sync { }
        XCTAssertEqual(sent, 1, "the interim offer went out")
        let reason = "iPhone Bluetooth is off — still running"
        c.handleIncoming(userInfo: try LoanMessage.denied(LoanDenied(reason: reason)).transportDictionary(), channel: .urgent)
        c.queue.sync { }
        XCTAssertEqual(c.phase, .active, "the loan continues")
        XCTAssertNotNil(c.pumpManager, "the watch still holds the pod")
        XCTAssertEqual(c.debugSnapshot().handbackFailureText, reason, "the glance shows the phone's own reason")
        XCTAssertFalse(c.debugSnapshot().handbackPending, "End is over — tap again once Bluetooth is back")
    }

    func testResumeRestoresEverythingALoanHadInstalled() async {
        // One list, so a new grant field cannot be left out of the saved state.
        let live = await makeController()
        live.loopManager.setClosedLoopEnabled(true, reason: "test")
        live.loopManager.setIntegralRetrospectiveCorrection(true)
        defaults.set(12.5, forKey: PodLoanWatchController.Keys.deliveredAtTakeover)

        let c = await relaunch(phase: .active, savedState: readablePumpState)
        XCTAssertNotNil(c.loopManager.settings.basalRateSchedule, "therapy settings")
        XCTAssertTrue(c.loopManager.closedLoopEnabledNonBlocking, "closed-loop mode — bench: a resumed loan came back OPEN")
        XCTAssertTrue(c.loopManager.isIntegralRetrospectiveCorrectionEnabled, "retrospective-correction mode")
        XCTAssertTrue(c.phoneSupportsInterimHandback, "the phone's interim hand-back capability")
        XCTAssertTrue(c.phoneSupportsOverrideRecords, "the phone's override-records capability")
        XCTAssertEqual(c.deliveredAtTakeover, 12.5, "the delivery baseline — bench: the hand-back audit read delivered=n/a")
        XCTAssertTrue(c.isLoanActiveNonBlocking, "the live-loan mirror")
    }

    func testClosedLoopDoesNotOutliveItsLoan() async {
        let live = await makeController()
        live.loopManager.setClosedLoopEnabled(true, reason: "test")
        live.loopManager.resetClosedLoopForSessionEnd()
        let next = await makeController()
        XCTAssertFalse(next.loopManager.closedLoopEnabledNonBlocking, "loop mode is per loan: the next launch starts open")
    }

    // MARK: insulin the copy cannot explain

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private var flatSchedule: BasalRateSchedule { BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 1.2)])! }
    private func unexplained(podTotal: Double, after minutes: Double, records: [LoanDoseRecord] = []) -> Double {
        PodLoanWatchController.insulinTheCopyCannotExplain(copyTotal: 10.0, copyAt: t0, podTotal: podTotal,
                                                           now: t0.addingTimeInterval(.minutes(minutes)),
                                                           records: records, schedule: flatSchedule)
    }

    func testAnOrdinaryStartHasNothingToBook() {
        // Ten minutes at 1.2 U/h is 0.2 U of scheduled basal, and that is all the pod delivered.
        XCTAssertEqual(unexplained(podTotal: 10.2, after: 10), 0)
        XCTAssertEqual(unexplained(podTotal: 10.35, after: 10), 0, "0.15 U over is inside the 0.20 U band — the phone's band at reclaim")
    }

    func testAPhoneBolusGivenAfterTheCopyIsBooked() {
        // A copy older than a phone bolus: the watch books the unexplained insulin.
        XCTAssertEqual(unexplained(podTotal: 16.2, after: 10), 6.0, accuracy: 0.001)
    }

    func testABolusTheCopyAlreadyKnowsIsNotBookedTwice() {
        // Still delivering when the copy's pod reading was taken: half of it is in that reading,
        // the other half arrives after it — and the copy's own record explains that half.
        let bolus = LoanDoseRecord(kind: .bolus, startDate: t0.addingTimeInterval(-.minutes(2)),
                                   endDate: t0.addingTimeInterval(.minutes(2)), amount: 6.0)
        XCTAssertEqual(unexplained(podTotal: 10.0 + 3.0 + 0.2, after: 10, records: [bolus]), 0)
        // …and a bolus wholly after the reading is explained in full.
        let later = LoanDoseRecord(kind: .bolus, startDate: t0.addingTimeInterval(.minutes(1)),
                                   endDate: t0.addingTimeInterval(.minutes(3)), amount: 2.0)
        XCTAssertEqual(unexplained(podTotal: 10.0 + 2.0 + 0.2, after: 10, records: [later]), 0)
    }

    func testATempInTheCopyExplainsItsOwnDelivery() {
        let temp = LoanDoseRecord(kind: .tempBasal, startDate: t0.addingTimeInterval(-.minutes(5)),
                                  endDate: t0.addingTimeInterval(.minutes(25)), unitsPerHour: 3.0)
        XCTAssertEqual(unexplained(podTotal: 10.5, after: 10, records: [temp]), 0, "ten minutes at 3.0 U/h is 0.5 U")
        XCTAssertEqual(unexplained(podTotal: 12.5, after: 10, records: [temp]), 2.0, accuracy: 0.001, "anything beyond it is not")
    }

    func testBookedInsulinIsInTheBookTheLoopDosesFrom() async {
        // The rule is only worth anything if the loop SEES the booking: through the same door the
        // phone's history is seeded by, into the same store insulin on board is computed from.
        let c = await makeController()
        var settings = LoopSettings()
        settings.basalRateSchedule = flatSchedule
        c.loopManager.settings = settings
        let copyAt = Date().addingTimeInterval(-.minutes(10))
        c.queue.sync {
            c.takeoverCopyTotal = (10.0, copyAt)
            c.takeoverCopyRecords = []
            c.bookInsulinTheCopyCannotExplain(podTotal: 16.2, epoch: 7)   // 0.2 U of basal, 6.0 U nobody recorded
        }
        let iob: Double? = await withCheckedContinuation { done in
            c.loopManager.primeIOBFromStore(at: Date().addingTimeInterval(.minutes(1))) { done.resume(returning: $0) }
        }
        XCTAssertEqual(iob ?? 0, 6.0, accuracy: 0.5, "six units, a minute old, are all still on board")
        XCTAssertNotNil(c.debugSnapshot().startNoteText, "and the wrist says so")
        XCTAssertNil(c.takeoverCopyTotal, "consumed: one check per Start")
    }

    // MARK: the rebuild after a relaunch

    func testASavedSessionIsLiveFromLaunchNotFromTheEndOfItsRebuild() async {
        // State shows a live session before the slow pump rebuild finishes (field 2026-09-20).
        persistGrantedSettings()
        defaults.set(PodLoanWatchController.Phase.active.rawValue, forKey: PodLoanWatchController.Keys.phase)
        defaults.set(7, forKey: PodLoanWatchController.Keys.epoch)
        defaults.set(readablePumpState, forKey: PodLoanWatchController.Keys.pumpState)
        let c = await makeController()
        XCTAssertTrue(c.isLoanActiveNonBlocking, "live from the moment the saved session is found")
        XCTAssertTrue(c.isResumingNonBlocking, "and known to be rebuilding — what the glance shows instead of nothing")

        c.resumeIfNeeded()
        c.queue.sync { }
        XCTAssertFalse(c.isResumingNonBlocking, "rebuilt")
        XCTAssertTrue(c.isLoanActiveNonBlocking)
        XCTAssertNotNil(c.pumpManager)
    }

    func testAFailedRebuildIsNeitherLiveNorResuming() async {
        defaults.set(PodLoanWatchController.Phase.active.rawValue, forKey: PodLoanWatchController.Keys.phase)
        defaults.set(7, forKey: PodLoanWatchController.Keys.epoch)
        defaults.set(readablePumpState, forKey: PodLoanWatchController.Keys.pumpState)
        let c = await makeController()          // no granted settings on disk: the rebuild must fail
        c.resumeIfNeeded()
        c.queue.sync { }
        XCTAssertFalse(c.isResumingNonBlocking)
        XCTAssertFalse(c.isLoanActiveNonBlocking, "a session that could not be rebuilt is not live")
        XCTAssertFalse(c.loopManager.endAwaitingPumpManager(), "and nothing is left waiting for a pump")
    }

    func testAReadingThatArrivesDuringTheRebuildIsRemembered() async {
        // Stock restores the pump before the CGM, so a reading can never find no pump. Here the
        // sensor is wired first; the reading that arrives in between must not cost a cycle.
        let c = await makeController()
        let loop = c.loopManager
        loop.checkPumpDataAndLoop()
        XCTAssertFalse(loop.endAwaitingPumpManager(), "no rebuild pending: an idle reading is just an idle reading")

        loop.beginAwaitingPumpManager()
        loop.checkPumpDataAndLoop()             // the reading arrives; no pump yet
        XCTAssertTrue(loop.endAwaitingPumpManager(), "remembered — the rebuild's last act runs its cycle")
        XCTAssertFalse(loop.endAwaitingPumpManager(), "once")
    }

    // MARK: the hold

    func testEveryLandedCycleRenewsTheHoldEvenWithNothingToReport() async throws {
        // The watch's hold on the pod is this message being recent — so it goes out on every
        // landed cycle, stamped, and an empty one is never queued (late, it would renew nothing).
        let c = await relaunch(phase: .active, savedState: readablePumpState)
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        let before = Date()
        c.renewHold()
        c.queue.sync { }
        XCTAssertEqual(sent.count, 1, "one renewal")
        let dictionary = try XCTUnwrap(sent.first)
        XCTAssertEqual(dictionary["urgentOnly"] as? Bool, true, "an empty renewal is never queued")
        guard case .doseRecordBatch(let batch)? = try LoanMessage.decode(fromTransport: dictionary) else {
            return XCTFail("the renewal is the ordinary record batch")
        }
        XCTAssertEqual(batch.epoch, 7)
        XCTAssertTrue(batch.events.isEmpty)
        XCTAssertEqual(try XCTUnwrap(batch.sentAt).timeIntervalSince(before), 0, accuracy: 2,
                       "stamped with its send time — the phone judges freshness by this")
    }

    func testAnIdleWatchRenewsNothing() async {
        let c = await makeController()
        var sent = 0
        c.send = { _ in sent += 1 }
        c.renewHold()
        c.queue.sync { }
        XCTAssertEqual(sent, 0, "no loan, no hold")
    }

    func testAReleasedWatchNeverResumesByTimer() async throws {
        // Once released, no timer brings the watch back to dosing (field 2026-09-19).
        let c = await relaunch(phase: .active, savedState: readablePumpState)
        c.isPhoneReachable = { true }
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        c.beginHandback()
        c.queue.sync { }
        c.handleIncoming(userInfo: try LoanMessage.handbackAck(HandbackAck(epoch: 7, committedCursor: 0)).transportDictionary(), channel: .urgent)
        c.queue.sync { }; c.queue.sync { }   // the ack finalizes; finalize sends the final offer on the queue
        XCTAssertEqual(c.phase, .handingBack, "released: the final offer is out")
        XCTAssertNil(c.loopManager.pumpManager, "and dosing has stopped")

        c.queue.sync { c.handbackTimedOut() }

        XCTAssertNotEqual(c.phase, .active, "released means released")
        XCTAssertEqual(c.phase, .recoveredDrain, "drain-only: the offer itself is the news")
        XCTAssertNil(c.pumpManager, "the pod is let go, so the phone can reach it")
        XCTAssertNil(c.loopManager.pumpManager, "no dosing")
        guard case .handbackOffer(let offer)? = try LoanMessage.decode(fromTransport: try XCTUnwrap(sent.last)) else {
            return XCTFail("it keeps offering")
        }
        XCTAssertEqual(offer.released, true)
        XCTAssertTrue(offer.recovered, "as a drain: it may be queued now — late, it is still true")
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
