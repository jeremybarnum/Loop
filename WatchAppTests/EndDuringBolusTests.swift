//
//  EndDuringBolusTests.swift
//  WatchAppTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  Nobody takes the pod while it is giving a bolus (control document, rows G and H): the watch's
//  End is refused on the spot while its own bolus is being given, and a refusal is felt. Nor while a
//  command to it is unconfirmed: the pod driver keeps the pod, and the End is refused. Hosted with a real DASH manager, which
//  needs the host app's bluetooth-central background mode.
//

import XCTest
import LoopKit
import LoopCore
import LoopAlgorithm
@testable import OmnipodKit
@testable import WatchApp

@MainActor
final class EndDuringBolusTests: XCTestCase {

    private var defaults: UserDefaults!
    private var dir: URL!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "EndDuringBolusTests-\(UUID().uuidString)")!
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func makeController() async -> PodLoanWatchController {
        let cacheStore = PersistenceController(directoryURL: dir.appendingPathComponent("cache"))
        let doseStore = await DoseStore(healthKitSampleStore: nil, cacheStore: cacheStore,
                                        longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
                                        provenanceIdentifier: "EndDuringBolusTests")
        let glucoseStore = await GlucoseStore(healthKitSampleStore: nil, cacheStore: cacheStore,
                                              cacheLength: 4 * 60 * 60, provenanceIdentifier: "EndDuringBolusTests")
        let carbStore = CarbStore(healthKitSampleStore: nil, cacheStore: cacheStore,
                                  cacheLength: 24 * 60 * 60, provenanceIdentifier: "EndDuringBolusTests")
        let manager = WatchLoopManager(doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore,
                                       defaults: defaults, stateDirectory: dir)
        return PodLoanWatchController(loopManager: manager, journal: LoanEventJournal(directory: dir),
                                      stateDirectory: dir)
    }

    /// A DASH manager whose pod is giving a bolus (2 U, manual) started just now, or no bolus.
    private func makePumpMidBolus(_ bolusing: Bool = true, units: Double = 2.0, automatic: Bool = false) throws -> OmniPumpManager {
        var podState = PodState(address: 0x1f0b3557, firmwareVersion: "2.7.0", iFirmwareVersion: "2.7.0",
                                lotNo: 1, lotSeq: 1, insulinType: .novolog, podType: dashType)
        podState.setupProgress = .completed
        if bolusing {
            podState.unfinalizedBolus = UnfinalizedDose(doseId: nil, bolusAmount: units, startTime: Date(),
                                                        scheduledCertainty: .certain, insulinType: .novolog, automatic: automatic)
        }
        let raw: [String: Any] = ["basalSchedule": ["entries": [["rate": 1.0, "startTime": 0.0]]],
                                  "controllerId": UInt32(0x1234_5678), "podId": UInt32(0x1234_5679),
                                  "podState": podState.rawValue]
        return try XCTUnwrap(OmniPumpManager(rawState: raw))
    }

    /// End with the watch's bolus still being given: refused at once, no offer goes to the phone,
    /// the loan continues, and the screen says when to try again.
    func testEndWhileTheWatchsBolusIsBeingGivenIsRefusedAtOnce() async throws {
        let c = await makeController()
        let pump = try makePumpMidBolus()
        guard case .inProgress = pump.status.bolusState else { return XCTFail("precondition: the pod is giving a bolus") }
        await c.onMain {
            pump.pumpManagerDelegate = c
            c.pumpManager = pump
            c.loopManager.pumpManager = pump
            c.phase = .active
        }
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        var refusalsFelt = 0
        c.playRefusal = { refusalsFelt += 1 }

        c.beginHandback()
        await c.onMain { }

        XCTAssertEqual(refusalsFelt, 1, "felt as well as read")
        XCTAssertTrue(sent.isEmpty, "no offer goes out")
        let snapshot1 = await c.fencedSnapshot()
        XCTAssertFalse(snapshot1.handbackPending)
        XCTAssertEqual(c.phase, .active, "the loan continues")
        XCTAssertNotNil(c.pumpManager, "the watch still holds the pod")
        let snapshot2 = await c.fencedSnapshot()
        XCTAssertTrue(snapshot2.handbackFailureText?.contains("bolus") == true,
                      "on screen: why, and when to try again")
    }

    /// A loan whose pod is giving an automatic bolus of `units`, the End about to be tapped. Timers are
    /// held, not run.
    private func loanMidAutomaticBolus(_ c: PodLoanWatchController, units: Double) async throws -> OmniPumpManager {
        let pump = try makePumpMidBolus(units: units, automatic: true)
        await c.onMain {
            pump.pumpManagerDelegate = c
            c.pumpManager = pump
            c.loopManager.pumpManager = pump
            c.phase = .active
            c.epoch = 7
            c.scheduler = { _, _, _ in }
        }
        return pump
    }

    private func finishBolus(_ pump: OmniPumpManager) {
        pump.setState { state in
            var pod = state.podState
            pod?.unfinalizedBolus = nil
            state.updatePodStateFromPodComms(pod)
        }
    }

    private func offers(_ sent: [[String: Any]]) -> Int {
        sent.filter { if case .handbackOffer? = try? LoanMessage.decode(fromTransport: $0) { return true } else { return false } }.count
    }

    /// End during a short automatic bolus: not refused. The End waits ("ending…", new boluses refused),
    /// and goes ahead once the bolus is over.
    func testEndDuringAShortAutomaticBolusWaitsThenGoesAhead() async throws {
        let c = await makeController()
        let pump = try await loanMidAutomaticBolus(c, units: 0.05)
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        var refusalsFelt = 0
        c.playRefusal = { refusalsFelt += 1 }

        c.beginHandback()
        await c.onMain { }
        XCTAssertEqual(refusalsFelt, 0, "not refused")
        XCTAssertEqual(offers(sent), 0, "no offer while the bolus is given")
        let waiting = await c.fencedSnapshot()
        XCTAssertTrue(waiting.handbackPending, "the screen says ending")
        XCTAssertNotNil(c.bolusRefusalWhileEnding(), "no new bolus while the End waits")

        finishBolus(pump)
        await c.onMain { c.checkEndWaitingForBolus() }
        XCTAssertEqual(offers(sent), 1, "the End goes ahead")
        XCTAssertTrue(c.handbackRequested)
        XCTAssertEqual(refusalsFelt, 0)
    }

    /// An automatic bolus still being given at the wait's limit refuses the End as before.
    func testAnAutomaticBolusStillGoingAtTheLimitRefusesTheEnd() async throws {
        let c = await makeController()
        _ = try await loanMidAutomaticBolus(c, units: 0.3)   // 12 s on the pod
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        var refusalsFelt = 0
        c.playRefusal = { refusalsFelt += 1 }

        c.beginHandback()
        await c.onMain { }
        await c.onMain { c.checkEndWaitingForBolus(atLimit: true) }

        XCTAssertEqual(refusalsFelt, 1)
        XCTAssertEqual(offers(sent), 0)
        let snapshot = await c.fencedSnapshot()
        XCTAssertFalse(snapshot.handbackPending)
        XCTAssertTrue(snapshot.handbackFailureText?.contains("bolus") == true)
        XCTAssertEqual(c.phase, .active, "the loan continues")
    }

    /// An automatic bolus that ends beyond the wait's limit refuses the End at the tap.
    func testALongAutomaticBolusRefusesTheEndAtOnce() async throws {
        let c = await makeController()
        _ = try await loanMidAutomaticBolus(c, units: 1.0)   // 40 s on the pod
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        var refusalsFelt = 0
        c.playRefusal = { refusalsFelt += 1 }

        c.beginHandback()
        await c.onMain { }

        XCTAssertEqual(refusalsFelt, 1)
        XCTAssertEqual(offers(sent), 0)
        let snapshot = await c.fencedSnapshot()
        XCTAssertFalse(snapshot.handbackPending)
    }

    /// Cancel while the End waits for the bolus: nothing goes when the bolus ends.
    func testAnEndWaitingForTheBolusCanBeCancelled() async throws {
        let c = await makeController()
        let pump = try await loanMidAutomaticBolus(c, units: 0.05)
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }

        c.beginHandback()
        await c.onMain { }
        c.cancelHandback()
        await c.onMain { }
        finishBolus(pump)
        await c.onMain { c.checkEndWaitingForBolus() }

        XCTAssertEqual(offers(sent), 0)
        let snapshot = await c.fencedSnapshot()
        XCTAssertFalse(snapshot.handbackPending)
    }

    /// A loan with no bolus on the pod, the End about to be tapped.
    private func activeLoan(_ c: PodLoanWatchController) async throws -> OmniPumpManager {
        let pump = try makePumpMidBolus(false)
        await c.onMain {
            pump.pumpManagerDelegate = c
            c.pumpManager = pump
            c.loopManager.pumpManager = pump
            c.phase = .active
        }
        return pump
    }

    /// End tapped while the watch's bolus is still being sent, before the pod has taken it up: the
    /// bolus counts from the moment it is sent, so the End is refused on the spot, not started.
    func testEndWhileTheWatchsBolusIsBeingSentIsRefusedAtOnce() async throws {
        let c = await makeController()
        _ = try await activeLoan(c)
        c.loopManager.setManualBolusInFlight(true, units: 1)
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        var refusalsFelt = 0
        c.playRefusal = { refusalsFelt += 1 }

        c.beginHandback()
        await c.onMain { }

        XCTAssertTrue(sent.isEmpty, "no offer: no Cancel screen")
        let snapshot3 = await c.fencedSnapshot()
        XCTAssertFalse(snapshot3.handbackPending)
        XCTAssertEqual(refusalsFelt, 1)
        let snapshot4 = await c.fencedSnapshot()
        XCTAssertEqual(snapshot4.handbackFailureText, "A bolus is still being given. Try again when it has finished.")
    }

    /// A bolus started while the End waited for the phone: at the release the End is refused, and
    /// the watch keeps the pod.
    func testABolusStartedDuringAPendingEndRefusesItAtTheRelease() async throws {
        let c = await makeController()
        _ = try await activeLoan(c)
        c.send = { _ in }
        var refusalsFelt = 0
        c.playRefusal = { refusalsFelt += 1 }
        await c.onMain { c.handbackRequested = true }      // the End is waiting for the phone
        c.loopManager.setManualBolusInFlight(true, units: 1)

        await c.onMain { c.finalizeHandback() }            // the drain is complete

        XCTAssertEqual(c.phase, .active, "the loan continues")
        XCTAssertNotNil(c.pumpManager, "the watch still holds the pod")
        let snapshot5 = await c.fencedSnapshot()
        XCTAssertFalse(snapshot5.handbackPending)
        XCTAssertEqual(refusalsFelt, 1)
        let snapshot6 = await c.fencedSnapshot()
        XCTAssertTrue(snapshot6.handbackFailureText?.contains("bolus") == true)
    }

    /// A command to the pod unconfirmed at the release: the pod driver keeps the pod, the End is refused,
    /// no final offer goes out, and the watch's loop has the pod again.
    func testAnUnconfirmedCommandAtTheReleaseRefusesTheEnd() async throws {
        let c = await makeController()
        let pump = try await activeLoan(c)
        pump.setState { state in
            var pod = state.podState
            pod?.unacknowledgedCommand = .stopProgram(.tempBasal, 3, Date(), false)
            state.updatePodStateFromPodComms(pod)
        }
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        var refusalsFelt = 0
        c.playRefusal = { refusalsFelt += 1 }
        await c.onMain { c.handbackRequested = true }      // the End is waiting for the phone

        await c.onMain { c.finalizeHandback() }            // the drain is complete
        await c.loopManager.laneSettled()
        await c.onMain { }
        await c.loopManager.laneSettled()

        XCTAssertFalse(pump.isControlReleased, "the driver kept the pod")
        XCTAssertEqual(c.phase, .active, "the loan continues")
        XCTAssertTrue(c.pumpManager === pump, "the watch still holds the pod")
        XCTAssertTrue(c.loopManager.pumpManager === pump, "the watch's loop doses again")
        XCTAssertTrue(sent.isEmpty, "no final offer")
        let snapshot7 = await c.fencedSnapshot()
        XCTAssertFalse(snapshot7.handbackPending)
        XCTAssertEqual(refusalsFelt, 1)
        let snapshot8 = await c.fencedSnapshot()
        XCTAssertEqual(snapshot8.handbackFailureText, LoanControl.unconfirmedCommandRefusal)
    }

    /// Nobody starts a bolus while the pod is being handed back: with an End waiting, the watch
    /// refuses a bolus and says how to give one; the End itself is untouched.
    func testABolusIsRefusedWhileAnEndIsWaiting() async throws {
        let c = await makeController()
        _ = try await activeLoan(c)
        XCTAssertNil(c.bolusRefusalWhileEnding(), "no End waiting: a bolus may go")

        await c.onMain { c.handbackRequested = true }
        XCTAssertEqual(c.bolusRefusalWhileEnding(), "Sport Mode is ending. Bolus on the iPhone once it has the pod.")
        let snapshot9 = await c.fencedSnapshot()
        XCTAssertTrue(snapshot9.handbackPending, "the End carries on")

        let content = CarbAndBolusFlowViewModel.bolusFailureContent(units: 1, carbGrams: nil,
                                                                    error: BolusRefusedWhileEnding(reason: c.bolusRefusalWhileEnding()!))
        XCTAssertEqual(content.title, "Bolus Not Sent")
    }

    /// Where a bolus asked for on the watch goes, phase by phase. Once the End has stopped dosing the
    /// loan is no longer active, and stock's route would send the bolus to the phone, which gave it once
    /// it had the pod back (rig, T22): it is refused until the loan closes.
    func testABolusAskedForDuringTheEndNeverTakesStocksRoute() async throws {
        let c = await makeController()
        XCTAssertEqual(c.bolusRoute(units: 1), .stockRouteToPhone, "no loan: stock's route, unchanged")
        _ = try await activeLoan(c)
        XCTAssertEqual(c.bolusRoute(units: 1), .watchPump)

        await c.onMain { c.handbackRequested = true }
        XCTAssertEqual(c.bolusRoute(units: 1), .refused("Sport Mode is ending. Bolus on the iPhone once it has the pod."))

        await c.onMain { c.handbackRequested = false; c.phase = .handingBack }
        XCTAssertEqual(c.bolusRoute(units: 1), .refused("Sport Mode is ending. Bolus on the iPhone once it has the pod."),
                       "dosing stopped, loan not closed: refused, not sent to the phone")
        XCTAssertEqual(c.bolusRoute(units: 0), .stockRouteToPhone, "carbs alone may go")
    }

    /// A Start the phone denies (its own bolus still being given, for one) is felt on the watch too.
    func testAStartThePhoneDeniesIsFelt() async throws {
        let c = await makeController()
        var refusalsFelt = 0
        c.playRefusal = { refusalsFelt += 1 }
        let reason = "A bolus is still being given. Try again in 30 seconds."
        c.handleIncoming(userInfo: try LoanMessage.denied(LoanDenied(reason: reason)).transportDictionary())
        await c.onMain { }

        XCTAssertEqual(refusalsFelt, 1)
        XCTAssertEqual(c.phase, .idle)
    }
}
