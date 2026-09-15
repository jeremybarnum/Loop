//
//  G7TimedConnectTests.swift
//  WatchAppTests
//
//  Pins the grid arithmetic behind the timed, bounded connect (G7TimedConnect). The anchor is a
//  READING's own sensor timestamp; the request goes up `fireOffset` seconds after each
//  `period`-spaced grid point, which is ~1 s before the sensor starts advertising.
//

import XCTest
@testable import G7SensorKit
@testable import WatchApp

final class G7TimedConnectTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_000_000)

    func testFiresJustAfterTheNextGridPoint() {
        let fire = G7TimedConnect.nextFire(anchor: anchor, now: anchor.addingTimeInterval(100))
        XCTAssertEqual(fire.timeIntervalSince(anchor), G7TimedConnect.period + G7TimedConnect.fireOffset, accuracy: 0.001)
    }

    func testSkipsAGridPointThatIsInsideTheMargin() {
        // 0.5 s before the fire time, with a 1-s margin: too close, take the next one.
        let now = anchor.addingTimeInterval(G7TimedConnect.period + G7TimedConnect.fireOffset - 0.5)
        let fire = G7TimedConnect.nextFire(anchor: anchor, now: now)
        XCTAssertEqual(fire.timeIntervalSince(anchor), 2 * G7TimedConnect.period + G7TimedConnect.fireOffset, accuracy: 0.001)
    }

    func testStaysGridAlignedManyCyclesLater() {
        // A stale anchor is no longer fatal: it is the sensor's own clock, so an anchor hours old
        // still names the grid (crystal drift ≈ 4 s/day against a 5-s bound).
        let now = anchor.addingTimeInterval(47 * G7TimedConnect.period + 12)
        let fire = G7TimedConnect.nextFire(anchor: anchor, now: now)
        XCTAssertEqual(fire.timeIntervalSince(anchor), 48 * G7TimedConnect.period + G7TimedConnect.fireOffset, accuracy: 0.001)
    }

    func testTheRequestSitsInsideTheBurst() {
        // The sensor starts advertising +2.0…+3.2 s after the reading timestamp (61 cycles,
        // 2026-09-12) and keeps going ≥ 7 s. Being late is free (a mid-burst request completes
        // in ~0.03 s); being early wastes window. So the request goes up at the burst start and
        // the whole bound sits inside the shortest burst.
        let burstStart = 2.0, burstEnd = 9.0
        XCTAssertGreaterThanOrEqual(G7TimedConnect.fireOffset, burstStart)
        XCTAssertLessThanOrEqual(G7TimedConnect.fireOffset + G7TimedConnect.bound, burstEnd)
    }

    func testTheSystemHeldArmIsAnExperimentThatStaysOff() {
        // The start-delay arm opts the watch central into state restoration and lodges requests
        // the app cannot withdraw while asleep. It is a measurement, not a default.
        UserDefaults.standard.removeObject(forKey: G7TimedConnect.systemHeldKey)
        XCTAssertFalse(G7TimedConnect.systemHeld)
    }

    func testEveryAskIsWithdrawnInsideTheDaemonsFastScan() {
        // The -70 is written by a failure more than 6 s after the connect REQUEST. Every request
        // of ours — grid ask, second ask, retry — must be withdrawn before that, so a refusal can
        // add to the daemon's COUNT but can never park the floor.
        XCTAssertLessThan(G7TimedConnect.bound, 6)
        XCTAssertGreaterThan(G7TimedConnect.secondAskDelay, 0)
        XCTAssertLessThan(G7TimedConnect.secondAskDelay, 2)   // the burst must still be on the air
    }
}

final class BluetoothTaskLedgerTests: XCTestCase {
    // The Bluetooth alert task ledger says where the day stands against the documented
    // five-per-24 h budget. It must count this delivery, keep the last 24 h, and drop older stamps.
    func testTheLedgerCountsARolling24Hours() {
        let suite = "BluetoothTaskLedgerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let t0 = Date(timeIntervalSince1970: 2_000_000)

        XCTAssertEqual(ExtensionDelegate.recordBluetoothWake(at: t0, defaults: defaults), 1)
        XCTAssertEqual(ExtensionDelegate.recordBluetoothWake(at: t0.addingTimeInterval(7 * 60), defaults: defaults), 2)
        XCTAssertEqual(ExtensionDelegate.recordBluetoothWake(at: t0.addingTimeInterval(23 * 3600), defaults: defaults), 3)
        // 24 h + 1 s after the first: the first stamp falls out, the other two stay.
        XCTAssertEqual(ExtensionDelegate.recordBluetoothWake(at: t0.addingTimeInterval(24 * 3600 + 1), defaults: defaults), 3)
    }
}

final class DirectAuthFastPathTests: XCTestCase {
    // The Swift AES-8 replaces the C side's encrypt8AES on the fast path. Pin the primitive
    // to FIPS-197 C.1 so a stored key can never be replayed through wrong arithmetic.
    func testTheAESBlockMatchesFIPS197() {
        let key: [UInt8]   = Array(0x00...0x0f)
        let plain: [UInt8] = [0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff]
        let expect: [UInt8] = [0x69,0xc4,0xe0,0xd8,0x6a,0x7b,0x04,0x30,0xd8,0xcd,0xb7,0x80,0x70,0xb4,0xc5,0x5a]
        XCTAssertEqual(G7AuthCrypto.aesBlock(plain, key: key), expect)
        // AES-8 is that block over the 8 bytes doubled, first 8 bytes out.
        let d8: [UInt8] = [0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77]
        XCTAssertEqual(G7AuthCrypto.aes8(d8, key: key), Array(G7AuthCrypto.aesBlock(d8 + d8, key: key).prefix(8)))
    }

    // The per-sensor key store: round-trips 16 bytes, refuses an all-zero key (the library's
    // "no J-PAKE yet" value), and clears on demand.
    func testTheKeyStoreRoundTripsAndRefusesZeros() {
        let suite = "DirectAuthFastPathTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key: [UInt8] = Array(0x10...0x1f)
        XCTAssertNil(G7DirectAuthKeyStore.load(for: "DXCMQB", defaults: defaults))
        G7DirectAuthKeyStore.save(key, for: "DXCMQB", defaults: defaults)
        XCTAssertEqual(G7DirectAuthKeyStore.load(for: "DXCMQB", defaults: defaults), key)
        XCTAssertNil(G7DirectAuthKeyStore.load(for: "DXCMXX", defaults: defaults), "keys are per sensor")
        G7DirectAuthKeyStore.save([UInt8](repeating: 0, count: 16), for: "DXCMZZ", defaults: defaults)
        XCTAssertNil(G7DirectAuthKeyStore.load(for: "DXCMZZ", defaults: defaults), "an all-zero key is 'none'")
        G7DirectAuthKeyStore.clear(for: "DXCMQB", defaults: defaults)
        XCTAssertNil(G7DirectAuthKeyStore.load(for: "DXCMQB", defaults: defaults))
    }

    func testTheFastPathAndStandingRequestDefaultOn() {
        UserDefaults.standard.removeObject(forKey: G7DirectAuth.fastPathKey)
        UserDefaults.standard.removeObject(forKey: G7TimedConnect.standingKey)
        XCTAssertTrue(G7DirectAuth.fastPath)
        XCTAssertTrue(G7TimedConnect.standing)
    }
}
