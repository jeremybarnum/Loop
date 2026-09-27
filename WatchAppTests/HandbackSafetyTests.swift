//
//  HandbackSafetyTests.swift
//  WatchAppTests
//
//  The three hand-back rules ported from the next-dev line on 2026-09-20, each behind a field
//  incident there:
//    1. a LIVE hand-back offer is never queued, and End fails at once when the phone is
//       unreachable (2026-09-18: queued offers landed 65 min after the hand-back had timed out
//       and the loan had resumed — both devices dosed the pod for three hours);
//    2. the phone can refuse a hand-back out loud (its Bluetooth is off) and the watch stops
//       at once, keeping the loan;
//    3. released means released — after the FINAL offer no timer brings the loan back
//       (2026-09-19: resumed 0.6 s before the phone committed; two controllers for 7.6 min).
//

import XCTest
import LoopKit
import LoopCore
@testable import WatchApp_Extension

final class HandbackSafetyTests: XCTestCase {

    private var cacheStore: PersistenceController!
    private var journalDir: URL!
    private var defaults: UserDefaults!

    /// Builds an OmniPumpManager with no pod behind it — enough for the controller to hold.
    private let readablePumpState: [String: Any] = [
        "basalSchedule": ["entries": [["rate": 1.0, "startTime": 0.0]]],
        "controllerId": UInt32(0x1234_5678), "podId": UInt32(0x1234_5679),
    ]

    override func setUp() {
        super.setUp()
        cacheStore = PersistenceController(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        journalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "HandbackSafetyTests-\(UUID().uuidString)")!
    }

    override func tearDown() {
        cacheStore = nil; journalDir = nil; defaults = nil
        super.tearDown()
    }

    private func makeLiveLoan() -> PodLoanWatchController {
        let doseStore = DoseStore(healthKitSampleStore: nil, cacheStore: cacheStore,
                                  insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
                                  longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
                                  basalProfile: nil, insulinSensitivitySchedule: nil,
                                  provenanceIdentifier: "HandbackSafetyTests")
        let glucoseStore = GlucoseStore(healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(4),
                                        provenanceIdentifier: "HandbackSafetyTests")
        let carbStore = CarbStore(healthKitSampleStore: nil, cacheStore: cacheStore, cacheLength: .hours(24),
                                  defaultAbsorptionTimes: LoopCoreConstants.defaultCarbAbsorptionTimes,
                                  provenanceIdentifier: "HandbackSafetyTests")
        let manager = WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore)
        let controller = PodLoanWatchController(loopManager: manager,
                                                journal: LoanEventJournal(directory: journalDir),
                                                defaults: defaults)
        controller.scheduler = { _, _, _ in }   // timers armed-only: nothing fires by itself
        controller.installLiveLoanForTesting(pumpRawState: readablePumpState)
        return controller
    }

    private func offers(in sent: [[String: Any]]) -> [(offer: HandbackOffer, urgentOnly: Bool)] {
        sent.compactMap { dict in
            guard let message = try? LoanMessage.decode(fromTransport: dict), case .handbackOffer(let offer) = message else { return nil }
            return (offer, dict["urgentOnly"] as? Bool == true)
        }
    }

    // MARK: 1 — never queued, fails at once

    func testLiveHandbackWithPhoneUnreachableFailsFastAndKeepsTheLoan() {
        let c = makeLiveLoan()
        XCTAssertTrue(c.debugSnapshot().hasPumpManager, "precondition: a live loan holding a pump manager")
        c.isPhoneReachable = { false }
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }

        c.beginHandback()
        let snap = c.debugSnapshot()
        XCTAssertEqual(snap.phase, .active, "the loan continues")
        XCTAssertTrue(snap.hasPumpManager, "the watch still holds the pod")
        XCTAssertFalse(snap.handbackPending, "End is over — tap again when the phone is back")
        XCTAssertTrue(offers(in: sent).isEmpty, "no offer left the watch — nothing queued to land later")
    }

    func testALiveOfferIsMarkedUrgentOnlyAndADrainIsNot() {
        let c = makeLiveLoan()
        c.isPhoneReachable = { true }
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }

        c.beginHandback()
        _ = c.debugSnapshot()
        let live = offers(in: sent)
        XCTAssertEqual(live.count, 1, "the interim offer went out")
        XCTAssertTrue(live[0].urgentOnly, "a live offer must never reach the queued transport")
        XCTAssertEqual(live[0].offer.released, false, "interim: the watch is still dosing")
    }

    // MARK: 2 — the phone's refusal

    func testPhoneRefusalEndsTheHandbackAtOnceAndKeepsTheLoan() throws {
        let c = makeLiveLoan()
        c.isPhoneReachable = { true }
        c.send = { _ in }
        c.beginHandback()
        XCTAssertTrue(c.debugSnapshot().handbackPending, "precondition: End is in flight")

        let reason = "iPhone Bluetooth is off — still running"
        c.handleIncoming(userInfo: try LoanMessage.denied(LoanDenied(reason: reason)).transportDictionary(), channel: .urgent)
        let snap = c.debugSnapshot()
        XCTAssertEqual(snap.phase, .active, "the loan continues")
        XCTAssertTrue(snap.hasPumpManager, "the watch still holds the pod")
        XCTAssertFalse(snap.handbackPending, "End stopped at once — no two-minute budget to wait out")
    }

    // MARK: 3 — released means released

    func testAReleasedWatchNeverResumesByTimer() {
        let c = makeLiveLoan()
        c.isPhoneReachable = { true }
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        c.enterFinalStageForTesting()          // the final offer is out; the ack never came

        c.expireHandbackForTesting()
        let snap = c.debugSnapshot()
        XCTAssertEqual(snap.phase, .recoveredDrain, "drain-only — never back to .active by a timer")
        XCTAssertFalse(snap.hasPumpManager, "the pod is let go so the phone can reach it")
        let last = offers(in: sent).last
        XCTAssertEqual(last?.offer.released, true, "what keeps offering is a FINAL offer")
        XCTAssertEqual(last?.offer.recovered, true, "as a drain — true whenever it lands")
        XCTAssertEqual(last?.urgentOnly, false, "and this one MAY be queued")
    }

    func testAnInterimTimeoutStillKeepsTheLoan() {
        let c = makeLiveLoan()
        c.isPhoneReachable = { true }
        c.send = { _ in }
        c.beginHandback()
        c.expireHandbackForTesting()
        let snap = c.debugSnapshot()
        XCTAssertEqual(snap.phase, .active, "the watch never stopped dosing — the loan continues")
        XCTAssertTrue(snap.hasPumpManager)
    }

    // MARK: pod totals survive for the drain (field 2026-09-24, e95 + e103: unaudited hand-backs)

    func testAReleasedDrainStillCarriesThePodTotals() {
        let c = makeLiveLoan()
        c.setPodTotalsForTesting(start: 10.0, latest: 10.5)
        c.isPhoneReachable = { true }
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        c.enterFinalStageForTesting()
        c.expireHandbackForTesting()          // the final offer went unanswered: released, drain

        XCTAssertEqual(c.debugSnapshot().phase, .recoveredDrain, "precondition: the drain")
        guard let drain = offers(in: sent).last?.offer else { return XCTFail("the drain offered nothing") }
        XCTAssertEqual(drain.odometer?.deliveredAtStart, 10.0, "the start survives the release — without it the phone audits nothing")
        XCTAssertEqual(drain.odometer?.deliveredLatest, 10.5)
    }

    func testThePodTotalsSurviveARelaunch() {
        let c = makeLiveLoan()
        c.setPodTotalsForTesting(start: 10.0, latest: 10.5)

        let relaunched = PodLoanWatchController(loopManager: c.loopManagerForTesting,
                                                journal: LoanEventJournal(directory: journalDir),
                                                defaults: defaults)
        let totals = relaunched.podTotalsForTesting()
        XCTAssertEqual(totals.start, 10.0, "a relaunched watch still knows where the loan started")
        XCTAssertEqual(totals.latest, 10.5)
    }
}
