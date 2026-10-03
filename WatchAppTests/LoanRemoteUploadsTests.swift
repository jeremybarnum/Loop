//
//  LoanRemoteUploadsTests.swift
//  WatchAppTests
//
//  Nightscout credentials on the wrist: a grant without them keeps what is staged, and the
//  pump's teardown drops them with the loan.
//

import XCTest
import LoopKit
import LoopCore
import LoopAlgorithm
@testable import WatchApp

final class LoanRemoteUploadsTests: XCTestCase {

    private let credentials = LoanNightscoutCredentials(siteURL: URL(string: "https://fixture-site.example")!,
                                                        apiSecret: "fixture-secret")

    override func tearDown() {
        LoanRemoteUploads.shared.end()
        super.tearDown()
    }

    /// A later grant without credentials (a seize from the standing copy, an older phone) must
    /// not switch uploads off; only the loan's end does.
    func testACredentialLessGrantKeepsStagedCredentials() {
        let uploads = LoanRemoteUploads()
        XCTAssertFalse(uploads.holdsNightscoutCredentials)

        uploads.stage(nightscout: credentials)
        uploads.stage(nightscout: nil)
        XCTAssertTrue(uploads.holdsNightscoutCredentials, "a credential-less grant cleared the staged credentials")

        uploads.end()
        XCTAssertFalse(uploads.holdsNightscoutCredentials, "the loan's end left credentials behind")
    }

    /// Every way a loan ends runs through the pump's teardown; the credentials go with it.
    func testPumpTeardownEndsUploads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cacheStore = PersistenceController(directoryURL: directory.appendingPathComponent("cache"))
        let doseStore = await DoseStore(healthKitSampleStore: nil, cacheStore: cacheStore,
                                        longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
                                        provenanceIdentifier: "LoanRemoteUploadsTests")
        let glucoseStore = await GlucoseStore(healthKitSampleStore: nil, cacheStore: cacheStore,
                                              cacheLength: .hours(4), provenanceIdentifier: "LoanRemoteUploadsTests")
        let carbStore = CarbStore(healthKitSampleStore: nil, cacheStore: cacheStore,
                                  cacheLength: .hours(24), provenanceIdentifier: "LoanRemoteUploadsTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LoanRemoteUploadsTests-\(UUID().uuidString)"))
        let manager = WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore,
                                       defaults: defaults, stateDirectory: directory)
        let controller = PodLoanWatchController(loopManager: manager,
                                                journal: LoanEventJournal(directory: directory),
                                                stateDirectory: directory)

        LoanRemoteUploads.shared.stage(nightscout: credentials)
        XCTAssertTrue(LoanRemoteUploads.shared.holdsNightscoutCredentials)

        controller.queue.sync { controller.teardownPump() }
        XCTAssertFalse(LoanRemoteUploads.shared.holdsNightscoutCredentials, "uploads outlived the pump's teardown")
    }
}
