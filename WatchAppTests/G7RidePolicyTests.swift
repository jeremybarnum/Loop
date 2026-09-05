//
//  G7RidePolicyTests.swift
//  WatchAppTests
//
//  Ride-only (2026-09-05): while a sensor is adopted, no pending connect of ours on the bond;
//  join Dexcom's link when the OS reports it. Pinned as a pure policy after the day's arms
//  showed our parked request alone — app asleep — is enough to mute both apps.
//

import XCTest
import G7SensorKit

final class G7RidePolicyTests: XCTestCase {

    func testAdoptedAndRideOnlyIssuesNoRequestOfOurs() {
        XCTAssertFalse(G7RidePolicy.shouldIssueConnect(rideOnly: true, adopted: true))
    }

    func testEverythingElseStillConnectsAsBefore() {
        XCTAssertTrue(G7RidePolicy.shouldIssueConnect(rideOnly: false, adopted: true), "switch off: stock behaviour")
        XCTAssertTrue(G7RidePolicy.shouldIssueConnect(rideOnly: true, adopted: false),
                      "un-adopted acquisition is unchanged — there is no link of Dexcom's to ride until we know the sensor")
    }

    func testJoinsDexcomsLinkExactlyWhenItComesUpOnTheAdoptedSensor() {
        XCTAssertTrue(G7RidePolicy.shouldJoin(rideOnly: true, connected: true, isAdoptedPeripheral: true, alreadyConnected: false))
        XCTAssertFalse(G7RidePolicy.shouldJoin(rideOnly: true, connected: false, isAdoptedPeripheral: true, alreadyConnected: false), "a disconnect event is not a link to join")
        XCTAssertFalse(G7RidePolicy.shouldJoin(rideOnly: true, connected: true, isAdoptedPeripheral: false, alreadyConnected: false), "a neighbour's sensor is not ours to join")
        XCTAssertFalse(G7RidePolicy.shouldJoin(rideOnly: true, connected: true, isAdoptedPeripheral: true, alreadyConnected: true), "already on the link — nothing to do")
        XCTAssertFalse(G7RidePolicy.shouldJoin(rideOnly: false, connected: true, isAdoptedPeripheral: true, alreadyConnected: false), "switch off: the pending connect handles it, as it always has")
    }

    func testTheSwitchIsOffByDefault() {
        UserDefaults.standard.removeObject(forKey: G7RidePolicy.key)
        XCTAssertFalse(G7RidePolicy.rideOnlyEnabled)
    }
}
