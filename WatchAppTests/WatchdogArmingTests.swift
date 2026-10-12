//
//  WatchdogArmingTests.swift
//  WatchAppTests
//
//  The three dead-man alerts' arming: each refresh replaces its own identifier (never stacks),
//  and no two alerts share one. Delivery still needs the wrist.
//

import XCTest
import UserNotifications
@testable import WatchApp

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

    /// Recorded inline by the double, so no polling.
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
        XCTAssertEqual(intervals, expected, "the phone's exact ladder")
    }

    func testHandbackStuckArmsAtTwoMinutes() {
        HandbackStuckAlert.arm()
        let reqs = pending()
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(interval(of: reqs[0]), 2 * 60, "this times a COMMIT acknowledgement, not presence — a 5 s budget split the pod")
    }

    // MARK: - Replacement, which is the whole mechanism

    /// Stacking would fire the first alarm during a healthy loop.
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

    /// A loan started with the phone out of reach leaves the phone's Loop-Failure rungs on the watch.
    /// The watch removes them by the phone's identifiers (AlertManager: category + interval) and keeps its own.
    func testThePhonesRungsAreTakenOffTheWatchAndItsOwnStay() {
        XCTAssertEqual(LoopStallWatchdog.phoneRungIdentifiers,
                       ["loopNotRunning1200.0", "loopNotRunning2400.0", "loopNotRunning3600.0", "loopNotRunning7200.0"],
                       "must match AlertManager.scheduleLoopNotRunningNotifications")
        for id in LoopStallWatchdog.phoneRungIdentifiers {
            scheduler.add(UNNotificationRequest(identifier: id, content: UNMutableNotificationContent(),
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)))
        }
        LoopStallWatchdog.refresh()
        XCTAssertEqual(pending().count, 8)

        LoopStallWatchdog.removePhoneRungs()

        XCTAssertEqual(pending().count, 4, "only the watch's own ladder is left")
        XCTAssertTrue(Set(pending().map(\.identifier)).isDisjoint(with: LoopStallWatchdog.phoneRungIdentifiers))
        XCTAssertEqual(Set(scheduler.deliveredRemovals), Set(LoopStallWatchdog.phoneRungIdentifiers),
                       "delivered copies are cleared too")
        LoopStallWatchdog.disarm()
    }

    func testHandbackAlertFiresLongBeforeTheLoopWatchdog() {
        XCTAssertLessThan(HandbackStuckAlert.interval, LoopStallWatchdog.interval)
    }
}
