//
//  PodLoanEpochScopingTests.swift
//  WatchAppTests
//

import XCTest
import LoopKit
import OmnipodKit
import LoopCore
import LoopAlgorithm
@testable import WatchApp

// MARK: - The lean reacquisition path's one piece of persisted state

/// The per-pod BLE handle cache's decisions; whether a handle is still valid only the radio knows.
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

    /// Keyed per pod: a stale handle would hang a bare connect().
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


    /// `PodState` decodes the LTK and BLE handle in one `if let`, so dropping the handle drops
    /// the key (field 2026-08-20).
    func testLtkAndHandleAreCoupledInPodStateDecoding() throws {
        let podStatePath = #filePath
            .replacingOccurrences(of: "Loop/WatchAppTests/PodLoanEpochScopingTests.swift",
                                  with: "OmnipodKit/OmnipodKit/PumpManager/PodState.swift")
        let source = try String(contentsOfFile: podStatePath, encoding: .utf8)
        // Read the ltk line itself: a compound condition continues with a comma.
        guard let ltkLine = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.contains("let ltkString = rawValue[\"ltk\"]") })
        else {
            return XCTFail("PodState no longer decodes ltk the way this test expects — re-check every site that edits a grant's raw podState")
        }
        let trimmed = ltkLine.trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(trimmed.hasSuffix("{"),
                      "PodState's ltk decode is a COMPOUND condition again (line: \(trimmed)). Whatever it is bound with — bleIdentifier historically — becomes load-bearing for the pod's ENCRYPTION KEY, so dropping that disposable field silently drops the key and the pod hangs up ~108 ms after the first command. Decode ltk on its own.")
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

// MARK: - Stranded sensor identity (#104's blind spot)

/// The age predicate shared by the persist filter and the launch restore, which lets a real
/// sensor change through.
final class StrandedSensorIdentityTests: XCTestCase {

    /// With no reported session length the bound is the longest G7 session.
    private let lifeBound: TimeInterval = WatchLoopManager.longestSessionWithGrace

    func testAFreshSensorIsNotPastLife() {
        let activated = Date().addingTimeInterval(-.hours(24))
        XCTAssertFalse(WatchLoopManager.persistedSensorIsPastLife(activated))
    }

    /// The boundary matters: a sensor at 10d11h is still nominally alive and forgetting it would
    /// re-open the false-forget #104 exists to prevent.
    func testJustInsideTheGraceWindowIsKept() {
        let now = Date()
        let activated = now.addingTimeInterval(-(lifeBound - .minutes(30)))
        XCTAssertFalse(WatchLoopManager.persistedSensorIsPastLife(activated, now: now))
    }

    func testPastTheLongestSessionIsDiscardable() {
        let now = Date()
        let activated = now.addingTimeInterval(-(lifeBound + .minutes(1)))
        XCTAssertTrue(WatchLoopManager.persistedSensorIsPastLife(activated, now: now))
    }

    /// A 15-day sensor at 15 days is in its grace window and must survive a relaunch, even though
    /// a 10-day session would be over (field 2026-09-29: a live sensor discarded at launch).
    func testFifteenDaySensorInItsGraceWindowIsKept() {
        let now = Date()
        let activated = now.addingTimeInterval(-.hours(15 * 24 + 1))
        XCTAssertFalse(WatchLoopManager.persistedSensorIsPastLife(activated, now: now))
    }

    /// When the sensor reported its own session end, that end decides.
    func testReportedEndDecides() {
        let now = Date()
        let activated = now.addingTimeInterval(-.hours(11 * 24))
        XCTAssertTrue(WatchLoopManager.persistedSensorIsPastLife(activated, reportedEnd: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(WatchLoopManager.persistedSensorIsPastLife(activated, reportedEnd: now.addingTimeInterval(60), now: now))
    }

    /// Never discard on a guess. A blob with no activation date tells us nothing about age, and
    /// throwing away a possibly-live identity costs direct readings for the rest of its life.
    func testUnknownAgeIsNeverDiscarded() {
        XCTAssertFalse(WatchLoopManager.persistedSensorIsPastLife(nil))
    }

    /// An identity restored past its expiry is discardable.
    func testTheFieldCaseNineteenHoursPastExpiryIsDiscardable() {
        let now = Date()
        let activated = now.addingTimeInterval(-(lifeBound + .hours(19)))
        XCTAssertTrue(WatchLoopManager.persistedSensorIsPastLife(activated, now: now),
                      "a sensor 19h past its grace window must not be restored at launch — the manager will auto-connect to it and fail auth forever")
    }
}

// MARK: - Sport Mode start gate

/// The Start gate keys on whether this watch has an enrolled, living sensor that has gone quiet.
final class SportModeStartGateTests: XCTestCase {

    private func verdict(_ sensorName: String?, _ activatedAt: Date?, _ lastDirect: Date?, _ now: Date) -> WatchLoopManager.StartGateVerdict {
        WatchLoopManager.startGateVerdict(sensorName: sensorName, sensorActivatedAt: activatedAt,
                                          lastDirectG7At: lastDirect, now: now)
    }

    /// No enrolled sensor warns rather than blocks.
    func testNoEnrolledSensorWarnsButDoesNotBlock() {
        let now = Date()
        XCTAssertEqual(verdict(nil, nil, nil, now), .noSensorEverEnrolled)
    }

    /// An identity past its life is a corpse the launch path discards; it must not block Start on
    /// its way out, or a dead sensor would lock the wearer out of Sport Mode entirely.
    func testExpiredSensorAllowsStart() {
        let now = Date()
        XCTAssertEqual(verdict("DXCMqL", now.addingTimeInterval(-(WatchLoopManager.longestSessionWithGrace + .hours(1))), nil, now), .allowed)
    }

    /// Enrolled, alive, delivering: the healthy case must not be refused.
    func testFreshDirectReadingAllowsStart() {
        let now = Date()
        XCTAssertEqual(verdict("DXCMqL", now.addingTimeInterval(-.hours(24)), now.addingTimeInterval(-.minutes(4)), now), .allowed)
    }

    /// Not a fault: a fresh enrollment legitimately takes minutes, so it gets the calmer wording
    /// rather than a "check Dexcom" prompt that reads as an error on a healthy new sensor.
    func testEnrolledButNeverDeliveredIsWaiting() {
        let now = Date()
        XCTAssertEqual(verdict("DXCMu0", now.addingTimeInterval(-.minutes(3)), nil, now), .waitingForFirstReading(sensorName: "DXCMu0"))
    }

    /// The field case: enrolled, alive, and silent past the bound. A loan here would run on relay
    /// alone and stop looping the moment the phone leaves.
    func testEnrolledAndSilentBlocksStart() {
        let now = Date()
        XCTAssertEqual(verdict("DXCMqL", now.addingTimeInterval(-.hours(24)), now.addingTimeInterval(-.minutes(31)), now), .noDirectConnection(sensorName: "DXCMqL", silentMinutes: 31))
    }

    /// The bound is 15 minutes, not the 7-minute display window: deciding whether the LINK works
    /// needs three missed cadence periods, or one jittered reading refuses a healthy setup.
    func testJustInsideTheBoundStillAllowsStart() {
        let now = Date()
        XCTAssertEqual(verdict("DXCMqL", now.addingTimeInterval(-.hours(24)), now.addingTimeInterval(-(WatchLoopManager.startGateSilenceLimit - .minutes(1))), now), .allowed)
    }
}


// MARK: - The BLE-wedge signature (PodLoanConnectClock.isWedge)

/// The wedge signature (CBError 11, or no connect at all) decides the user's remedy, so both
/// false positives and negatives give the wrong instruction.
final class BleWedgeSignatureTests: XCTestCase {

    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testCode11DuringTheAttemptIsAWedge() {
        XCTAssertTrue(PodLoanConnectClock.isWedge(lastCode11At: start.addingTimeInterval(5),
                                                  lastConnectAt: start.addingTimeInterval(2),
                                                  since: start),
                      "a slot refusal during the attempt is the wedge even if some connect landed")
    }

    /// Stale evidence must not indict a fresh attempt: the clock is reset at takeover start, but
    /// reclaim ladders share it across a loan, so the time test is what scopes the verdict.
    func testCode11FromBeforeTheAttemptIsNot() {
        XCTAssertFalse(PodLoanConnectClock.isWedge(lastCode11At: start.addingTimeInterval(-60),
                                                   lastConnectAt: start.addingTimeInterval(3),
                                                   since: start))
    }

    /// At takeover the pod is known-present — the phone was talking to it seconds ago and
    /// released it for us — so a whole attempt with zero didConnect is our radio, not the pod.
    func testNoConnectEverIsAWedge() {
        XCTAssertTrue(PodLoanConnectClock.isWedge(lastCode11At: nil, lastConnectAt: nil, since: start))
    }

    func testConnectLandedAndNoCode11IsNotAWedge() {
        XCTAssertFalse(PodLoanConnectClock.isWedge(lastCode11At: nil,
                                                   lastConnectAt: start.addingTimeInterval(1.3),
                                                   since: start))
    }

    /// A connect from BEFORE the attempt is somebody else's evidence — a prior ladder's success
    /// must not make this attempt read as healthy.
    func testConnectFromBeforeTheAttemptDoesNotCount() {
        XCTAssertTrue(PodLoanConnectClock.isWedge(lastCode11At: nil,
                                                  lastConnectAt: start.addingTimeInterval(-300),
                                                  since: start))
    }
}
