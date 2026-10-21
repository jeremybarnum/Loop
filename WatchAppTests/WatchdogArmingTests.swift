//
//  WatchdogArmingTests.swift
//  WatchAppTests
//
//  The three pre-scheduled dead-man alerts, tested for the first time. TEST_COVERAGE_PLAN.md
//  listed "pre-scheduled notification delivery" as field-only, which was true while every test
//  ran in an iOS host. This target runs in the watch extension itself, so ARMING is now
//  observable — delivery still is not, and still needs the wrist.
//
//  Why arming is worth testing at all: these alerts work by replacement. Each refresh() adds a
//  request under the SAME identifier, which watchOS treats as replacing the pending one, so a
//  loop that keeps completing perpetually defers its own alarm. If an identifier ever varied,
//  refresh would STACK requests instead of deferring, and the watchdog would fire during a
//  perfectly healthy loop. If two alerts ever shared an identifier, disarming one would
//  silently cancel the other. Neither failure is visible from reading the call sites, and both
//  produce a dead-man's switch that is wrong in the dangerous direction.
//

import XCTest
import LoopKit
import LoopCore
import UserNotifications
@testable import WatchApp_Extension

final class WatchdogArmingTests: XCTestCase {

    private var scheduler: RecordingWristAlertScheduler!

    override func setUp() {
        super.setUp()
        scheduler = RecordingWristAlertScheduler()
        WristAlerts.scheduler = scheduler
    }

    override func tearDown() {
        WristAlerts.scheduler = UNUserNotificationCenter.current()
        scheduler = nil
        super.tearDown()
    }

    /// The requests the alerts have asked for. Synchronous: the double records inline, so the
    /// polling the old suite needed against a separate daemon process is gone, and with it the
    /// class of failure where a premature read returned ONE request and looked like correct
    /// replacement.
    private func pending() -> [UNNotificationRequest] { scheduler.pending }
    private func settledPending(timeout: TimeInterval = 3) -> [UNNotificationRequest] { scheduler.pending }

    private func interval(of request: UNNotificationRequest) -> TimeInterval? {
        (request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval
    }

    // MARK: - Arming

    func testLoopStallLadderArmsStockRungs() {
        LoopStallWatchdog.refresh()
        let reqs = pending()
        XCTAssertEqual(reqs.count, 4, "stock parity: 20/40m + 1/2h, one request per rung")
        let intervals: Set<TimeInterval> = Set(reqs.compactMap { interval(of: $0) })
        let expected: Set<TimeInterval> = [1200, 2400, 3600, 7200]
        XCTAssertEqual(intervals, expected, "the phone's exact ladder (ruling 2026-08-24)")
    }

    func testHandbackStuckArmsAtTwoMinutes() {
        HandbackStuckAlert.arm()
        let reqs = pending()
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(interval(of: reqs[0]), 2 * 60)
    }

    // MARK: - Replacement, which is the whole mechanism

    /// The load-bearing property. Every completed loop cycle calls refresh(); if that STACKED
    /// requests instead of replacing, the first one armed would still fire on schedule and the
    /// watchdog would alarm during a perfectly healthy loop.
    func testRefreshReplacesRatherThanStacking() {
        for _ in 0..<5 { LoopStallWatchdog.refresh() }
        XCTAssertEqual(pending().count, 4, "same identifiers replace — five refreshes still leave one ladder")
    }

    func testDisarmClearsTheWholeLadderButNotOtherAlerts() {
        LoopStallWatchdog.refresh()
        HandbackStuckAlert.arm()
        XCTAssertEqual(pending().count, 5)
        LoopStallWatchdog.disarm()
        let left = pending()
        XCTAssertEqual(left.count, 1, "disarm removes exactly the ladder's four rungs")
        XCTAssertEqual(interval(of: left[0]), HandbackStuckAlert.interval)
        HandbackStuckAlert.disarm()
    }

    func testHandbackAlertFiresLongBeforeTheLoopWatchdog() {
        XCTAssertLessThan(HandbackStuckAlert.interval, LoopStallWatchdog.interval)
    }
}

// MARK: - Pod alerts on the wrist (ported from next-dev WatchAlertPresenterTests)
//
// While the watch holds the pod it is the only device that can hear the pump, so a pod fault or an
// occlusion has nowhere to go but the wrist. These pin that the alert reaches the notification
// centre at all — on this line it reached only the system log — and that the words, the urgency
// and the ability to take it back survive the trip.

final class WatchAlertPresenterTests: XCTestCase {

    private var scheduler: RecordingWristAlertScheduler!

    override func setUp() {
        super.setUp()
        scheduler = RecordingWristAlertScheduler()
        WristAlerts.scheduler = scheduler
    }

    override func tearDown() {
        WristAlerts.scheduler = UNUserNotificationCenter.current()
        scheduler = nil
        super.tearDown()
    }

    private func alert(_ alertIdentifier: String = "podFault",
                       manager: String = "Omnipod",
                       title: String = "Pod Fault",
                       body: String = "Insulin delivery stopped. Change your pod now.",
                       level: LoopKit.Alert.InterruptionLevel = .critical,
                       trigger: LoopKit.Alert.Trigger = .immediate) -> LoopKit.Alert {
        let content = LoopKit.Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK")
        return LoopKit.Alert(identifier: .init(managerIdentifier: manager, alertIdentifier: alertIdentifier),
                             foregroundContent: content, backgroundContent: content,
                             trigger: trigger, interruptionLevel: level)
    }

    /// The bug on this line was the WIRING: the pump manager's `issueAlert` reached the watch loop
    /// manager and stopped at a log line. Drive it through the delegate call the pod driver makes.
    func testTheLoopManagerPutsAPodAlertOnTheWrist() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = PersistenceController(directoryURL: dir)
        let manager = WatchLoopManager(
            doseStore: DoseStore(healthKitSampleStore: nil, cacheStore: cache,
                                 insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
                                 longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
                                 basalProfile: nil, insulinSensitivitySchedule: nil, provenanceIdentifier: "alerts"),
            glucoseStore: GlucoseStore(healthKitSampleStore: nil, cacheStore: cache, cacheLength: .hours(4),
                                       provenanceIdentifier: "alerts"),
            carbStore: CarbStore(healthKitSampleStore: nil, cacheStore: cache, cacheLength: .hours(24),
                                 defaultAbsorptionTimes: LoopCoreConstants.defaultCarbAbsorptionTimes,
                                 provenanceIdentifier: "alerts"))
        let fault = alert()
        manager.issueAlert(fault)
        XCTAssertEqual(scheduler.pending.count, 1, "the pod driver's alert reaches the wrist, not just the log")
        manager.retractAlert(identifier: fault.identifier)
        XCTAssertTrue(scheduler.pending.isEmpty, "and the driver can take it back")
    }

    /// The whole point: an alert raised during a loan is presented, not merely logged.
    func testAPodAlertReachesTheWrist() {
        WatchAlertPresenter.present(alert())

        XCTAssertEqual(scheduler.pending.count, 1, "a pod fault during a loan must reach the wrist")
        let request = try? XCTUnwrap(scheduler.pending.first)
        XCTAssertEqual(request?.content.title, "Pod Fault", "the user is told what happened")
        XCTAssertEqual(request?.content.body, "Insulin delivery stopped. Change your pod now.",
                       "and what to do about it")
        XCTAssertNil(request?.trigger, "an immediate alert fires now, not on a timer")
    }

    /// A pod fault is not something to sleep through.
    func testUrgencySurvivesTheTrip() {
        WatchAlertPresenter.present(alert(level: .critical))
        XCTAssertEqual(scheduler.pending.first?.content.interruptionLevel, .critical)
        XCTAssertNotNil(scheduler.pending.first?.content.sound, "a critical alert makes a noise")

        scheduler = RecordingWristAlertScheduler(); WristAlerts.scheduler = scheduler
        WatchAlertPresenter.present(alert("reservoirLow", level: .timeSensitive))
        XCTAssertEqual(scheduler.pending.first?.content.interruptionLevel, .timeSensitive,
                       "a low reservoir is urgent, not critical — it must not cry wolf")
    }

    /// Retracting is how a driver says the condition cleared. An alarm left standing after the
    /// pod recovered costs the next one its weight.
    func testRetractingTakesItBack() {
        let fault = alert()
        WatchAlertPresenter.present(fault)
        XCTAssertEqual(scheduler.pending.count, 1)

        WatchAlertPresenter.retract(fault.identifier)
        XCTAssertTrue(scheduler.pending.isEmpty, "the pending alert is withdrawn")
        XCTAssertEqual(scheduler.deliveredRemovals.count, 1,
                       "and so is one already on the wrist — the user must not be left staring at a stale alarm")
    }

    /// Two alerts must not be able to cancel each other, and re-issuing one must replace its own
    /// copy rather than stack a second.
    func testIdentifiersAreIndependentAndReIssuingReplaces() {
        WatchAlertPresenter.present(alert("podFault"))
        WatchAlertPresenter.present(alert("occlusion", title: "Occlusion", body: "Delivery is blocked."))
        XCTAssertEqual(scheduler.pending.count, 2, "distinct conditions are distinct alerts")

        WatchAlertPresenter.present(alert("podFault", body: "Insulin delivery stopped. Change your pod now."))
        XCTAssertEqual(scheduler.pending.count, 2, "re-issuing replaces its own copy, never stacks")

        WatchAlertPresenter.retract(LoopKit.Alert.Identifier(managerIdentifier: "Omnipod", alertIdentifier: "podFault"))
        XCTAssertEqual(scheduler.pending.count, 1, "retracting one leaves the other standing")
        XCTAssertEqual(scheduler.pending.first?.content.title, "Occlusion")
    }

    /// The dead-man ladder owns its own identifiers. Retracting a pod alert must never reach them.
    func testAPodRetractionCannotCancelTheDeadManLadder() {
        LoopStallWatchdog.refresh()
        let ladder = scheduler.identifiers
        XCTAssertFalse(ladder.isEmpty, "the ladder is armed")

        WatchAlertPresenter.present(alert())
        WatchAlertPresenter.retract(LoopKit.Alert.Identifier(managerIdentifier: "Omnipod", alertIdentifier: "podFault"))

        XCTAssertTrue(ladder.isSubset(of: scheduler.identifiers),
                      "every dead-man rung survives a pod alert being taken back")
    }

    /// The notification centre silently drops a repeating trigger under a minute, so a driver
    /// asking for something shorter must still get an alarm.
    func testARepeatingAlertIsNeverLostToTooShortAnInterval() {
        WatchAlertPresenter.present(alert(trigger: .repeating(repeatInterval: 5)))

        let trigger = scheduler.pending.first?.trigger as? UNTimeIntervalNotificationTrigger
        XCTAssertEqual(trigger?.timeInterval ?? 0, 60, accuracy: 0.001,
                       "raised to the centre's floor rather than dropped")
        XCTAssertEqual(trigger?.repeats, true)
    }

    /// A delayed alert keeps its delay.
    func testADelayedAlertKeepsItsDelay() {
        WatchAlertPresenter.present(alert(trigger: .delayed(interval: 900)))

        let trigger = scheduler.pending.first?.trigger as? UNTimeIntervalNotificationTrigger
        XCTAssertEqual(trigger?.timeInterval ?? 0, 900, accuracy: 0.001)
        XCTAssertEqual(trigger?.repeats, false)
    }
}
