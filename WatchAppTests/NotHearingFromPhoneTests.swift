//
//  NotHearingFromPhoneTests.swift
//  WatchAppTests
//
//  Control row 3 (ported from next-dev 1406bc8e, with the words reviewed in 5c99fd7e): with no loan
//  running, every word from the phone pushes out a pre-scheduled, time-sensitive watch notification
//  to 25 minutes later, so it fires only if the phone goes quiet. A loan starting removes it.
//  Nothing takes the pod. The Sport Mode page with no loan says "Not hearing from iPhone" in place
//  of "via iPhone" after 25 minutes without a word.
//

import XCTest
import UserNotifications
import HealthKit
import LoopKit
import LoopCore
@testable import WatchApp_Extension

final class NotHearingFromPhoneTests: XCTestCase {

    private var cacheStore: PersistenceController!
    private var journalDir: URL!
    private var defaults: UserDefaults!
    private var scheduler: RecordingWristAlertScheduler!

    private let readablePumpState: [String: Any] = [
        "basalSchedule": ["entries": [["rate": 1.0, "startTime": 0.0]]],
        "controllerId": UInt32(0x1234_5678), "podId": UInt32(0x1234_5679),
    ]

    override func setUp() {
        super.setUp()
        cacheStore = PersistenceController(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        journalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "NotHearingFromPhoneTests-\(UUID().uuidString)")!
        scheduler = RecordingWristAlertScheduler()
        WristAlerts.scheduler = scheduler
    }

    override func tearDown() {
        WristAlerts.scheduler = UNUserNotificationCenter.current()
        scheduler = nil
        cacheStore = nil; journalDir = nil; defaults = nil
        super.tearDown()
    }

    private func makeController() -> PodLoanWatchController {
        let doseStore = DoseStore(healthKitSampleStore: nil, cacheStore: cacheStore,
                                  insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
                                  longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
                                  basalProfile: nil, insulinSensitivitySchedule: nil,
                                  provenanceIdentifier: "NotHearingFromPhoneTests")
        let glucoseStore = GlucoseStore(healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(4),
                                        provenanceIdentifier: "NotHearingFromPhoneTests")
        let carbStore = CarbStore(healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(24),
                                  defaultAbsorptionTimes: LoopCoreConstants.defaultCarbAbsorptionTimes,
                                  provenanceIdentifier: "NotHearingFromPhoneTests")
        let manager = WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore)
        let controller = PodLoanWatchController(loopManager: manager,
                                                journal: LoanEventJournal(directory: journalDir),
                                                defaults: defaults)
        controller.scheduler = { _, _, _ in }
        return controller
    }

    private var warning: UNNotificationRequest? {
        scheduler.pending.first { $0.content.title == "Not Hearing From iPhone" }
    }

    /// With no loan, a word from the phone arms the warning: 25 minutes out, time-sensitive, the
    /// reviewed words.
    func testWithNoLoanAWordFromThePhoneArmsTheWarningTwentyFiveMinutesOut() throws {
        let c = makeController()
        c.notePhoneHeard()
        let snap = c.debugSnapshot()   // barrier: the queue block has run
        let request = try XCTUnwrap(warning, "a word from the phone arms the warning")
        XCTAssertEqual(scheduler.interval(of: request), 25 * 60)
        XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(request.content.body, "Your iPhone is probably not looping (off or out of range). Sport Mode on the watch is available to take over.")
        XCTAssertNotNil(snap.lastHeardFromPhoneAt)
    }

    /// Each word pushes it out: the same identifier, replaced, never stacked.
    func testEachWordReplacesTheWarningRatherThanStacking() {
        let c = makeController()
        c.notePhoneHeard()
        c.notePhoneHeard()
        _ = c.debugSnapshot()
        XCTAssertEqual(scheduler.pending.filter { $0.content.title == "Not Hearing From iPhone" }.count, 1)
    }

    /// Any loan message counts as a word from the phone.
    func testALoanMessageCountsAsAWord() throws {
        let c = makeController()
        c.handleIncoming(userInfo: try LoanMessage.diag(LoanDiag(epoch: 0, text: "hello")).transportDictionary(), channel: .queued)
        _ = c.debugSnapshot()
        XCTAssertNotNil(warning)
    }

    /// A loan running: the watch's own stall ladder covers it, so the warning is removed, and a
    /// word from the phone during the loan does not arm it again.
    func testALoanRemovesTheWarningAndWordsDuringItDoNotArmIt() {
        let c = makeController()
        c.notePhoneHeard()
        _ = c.debugSnapshot()
        XCTAssertNotNil(warning, "precondition")

        c.installLiveLoanForTesting(pumpRawState: readablePumpState)
        XCTAssertNil(warning, "a loan starting removes it")
        c.notePhoneHeard()
        _ = c.debugSnapshot()
        XCTAssertNil(warning, "and the phone's words during a loan do not bring it back")
    }

    /// A watch app relaunched with the phone already gone has heard nothing since it started:
    /// the quiet is counted from the launch, so the idle page still says so 25 minutes later.
    func testARelaunchWithThePhoneAlreadyGoneCountsFromTheLaunch() throws {
        let launched = Date()
        let c = makeController()
        let since = try XCTUnwrap(c.debugSnapshot().lastHeardFromPhoneAt, "counted from the launch")
        XCTAssertGreaterThanOrEqual(since, launched)
        XCTAssertFalse(GlanceViewModel.idleState(context: nil, phoneHeardAt: since, now: since.addingTimeInterval(24 * 60)).notHearingFromPhone)
        XCTAssertTrue(GlanceViewModel.idleState(context: nil, phoneHeardAt: since, now: since.addingTimeInterval(25 * 60)).notHearingFromPhone)
    }

    /// The idle page: "via iPhone" until 25 minutes without a word, then "Not hearing from iPhone".
    func testTheIdlePageSaysSoAfterTwentyFiveMinutes() {
        let now = Date()
        XCTAssertFalse(GlanceViewModel.idleState(context: nil, phoneHeardAt: nil, now: now).notHearingFromPhone,
                       "no clock (a preview): nothing to measure from")
        XCTAssertFalse(GlanceViewModel.idleState(context: nil, phoneHeardAt: now.addingTimeInterval(-24 * 60), now: now).notHearingFromPhone)
        XCTAssertTrue(GlanceViewModel.idleState(context: nil, phoneHeardAt: now.addingTimeInterval(-25 * 60), now: now).notHearingFromPhone)
    }
}
