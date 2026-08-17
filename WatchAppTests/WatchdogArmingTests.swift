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

    func testLoopStallWatchdogArmsOneRequestAtItsInterval() {
        LoopStallWatchdog.refresh()
        let reqs = pending()
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(interval(of: reqs[0]), LoopStallWatchdog.interval)
        XCTAssertEqual(interval(of: reqs[0]), 15 * 60, "15 min = three G7 reading intervals")
    }

    func testSensorBlackoutArmsRepeatingAtTwentyMinutes() {
        SensorBlackoutAlert.refresh()
        let reqs = pending()
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(interval(of: reqs[0]), 20 * 60)
        XCTAssertEqual((reqs[0].trigger as? UNTimeIntervalNotificationTrigger)?.repeats, true,
                       "repeats while the blackout persists — a silent sensor must keep nagging")
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
        let reqs = settledPending()
        XCTAssertEqual(reqs.count, 1, "five refreshes must leave ONE pending alarm, not five")
        XCTAssertEqual(Set(reqs.map(\.identifier)).count, reqs.count)
    }

    func testSensorBlackoutRefreshAlsoReplaces() {
        for _ in 0..<4 { SensorBlackoutAlert.refresh() }
        XCTAssertEqual(settledPending().count, 1)
    }

    // MARK: - Independence

    /// Each alert must own a distinct identifier. Sharing one would make any disarm cancel the
    /// others — and these are disarmed independently (hand-back disarms its own alert while the
    /// loop watchdog must keep running), so a collision silently removes a live dead-man.
    func testTheThreeAlertsAreIndependentlyArmable() {
        LoopStallWatchdog.refresh()
        SensorBlackoutAlert.refresh()
        HandbackStuckAlert.arm()
        XCTAssertEqual(settledPending().count, 3, "three distinct identifiers, three pending requests")
    }

    func testDisarmingOneLeavesTheOthersArmed() {
        LoopStallWatchdog.refresh()
        SensorBlackoutAlert.refresh()
        HandbackStuckAlert.arm()

        HandbackStuckAlert.disarm()
        let afterHandback = pending()
        XCTAssertEqual(afterHandback.count, 2, "ending a hand-back must not cancel the loop dead-man")
        XCTAssertTrue(afterHandback.contains { interval(of: $0) == LoopStallWatchdog.interval })
        XCTAssertTrue(afterHandback.contains { interval(of: $0) == SensorBlackoutAlert.interval })

        LoopStallWatchdog.disarm()
        XCTAssertEqual(pending().count, 1)
        XCTAssertEqual(interval(of: pending()[0]), SensorBlackoutAlert.interval)

        SensorBlackoutAlert.disarm()
        XCTAssertEqual(pending().count, 0)
    }

    // MARK: - Ordering

    /// The hand-back alert must fire well before the loop watchdog. A hung hand-back leaves the
    /// watch still looping, so if the ordering inverted the user would be told the loop had
    /// STOPPED — pointing them at the wrong problem entirely — before being told the hand-back
    /// failed.
    func testHandbackAlertFiresLongBeforeTheLoopWatchdog() {
        XCTAssertLessThan(HandbackStuckAlert.interval, LoopStallWatchdog.interval)
    }
}
