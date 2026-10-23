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
import UserNotifications
import HealthKit
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

    // MARK: 1 — never queued; End asks before it refuses (control row 8, ruled 2026-10-23)

    /// Captures every timer the controller arms, so a test fires exactly the one it means.
    private func captureTimers(_ c: PodLoanWatchController) -> () -> [(label: String, delay: TimeInterval, work: DispatchWorkItem)] {
        var timers: [(label: String, delay: TimeInterval, work: DispatchWorkItem)] = []
        let lock = NSLock()
        c.scheduler = { delay, label, work in lock.lock(); timers.append((label, delay, work)); lock.unlock() }
        return { lock.lock(); defer { lock.unlock() }; return timers }
    }

    /// The phone truly away: the link reads unreachable at the tap and for the whole answer wait.
    /// Nothing is queued, and End is refused only when the wait ends without an answer; the loan
    /// continues.
    func testLiveHandbackWithPhoneUnreachableIsRefusedAfterTheAnswerWaitAndKeepsTheLoan() {
        let c = makeLiveLoan()
        XCTAssertTrue(c.debugSnapshot().hasPumpManager, "precondition: a live loan holding a pump manager")
        let timers = captureTimers(c)
        c.isPhoneReachable = { false }
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }

        c.beginHandback()
        var snap = c.debugSnapshot()
        XCTAssertTrue(snap.handbackPending, "one unreachable reading at the tap is not a verdict: End asks first")
        XCTAssertNil(snap.lastIdleNote)
        XCTAssertEqual(timers().first { $0.label == "handback-answer" }?.delay, 10, "the on-screen query wait")
        XCTAssertTrue(offers(in: sent).isEmpty, "a live offer is never queued to an unreachable phone")

        // Still unreachable a second later: read again, nothing sent.
        c.onQueueForTesting { timers().last { $0.label == "handback-recheck" }?.work.perform() }
        XCTAssertTrue(offers(in: sent).isEmpty)
        XCTAssertTrue(c.debugSnapshot().handbackPending)

        // The wait ends with no answer: End is refused, and the loan continues.
        c.onQueueForTesting { timers().last { $0.label == "handback-answer" }?.work.perform() }
        snap = c.debugSnapshot()
        XCTAssertEqual(snap.phase, .active, "the loan continues")
        XCTAssertTrue(snap.hasPumpManager, "the watch still holds the pod")
        XCTAssertFalse(snap.handbackPending, "End is over — tap again when the phone is back")
        XCTAssertTrue(snap.endDidNotGoThrough, "and the screen says so")
        XCTAssertTrue(offers(in: sent).isEmpty, "no offer left the watch — nothing queued to land later")
    }

    /// The flag lies for a moment (the phone is there): read again a second later, the offer goes,
    /// and the phone's acknowledgement inside the wait means End is not refused.
    func testAnUnreachableReadingAtTheTapIsReadAgainAndAnAnswerInsideTheWaitKeepsTheEnd() throws {
        let c = makeLiveLoan()
        let timers = captureTimers(c)
        var reachable = false
        c.isPhoneReachable = { reachable }
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        // One record in the journal, so an acknowledgement that has not committed it yet leaves
        // the drain open (an empty journal would finalize on the first ack).
        c.loanDidRecordCarbs(NewCarbEntry(quantity: HKQuantity(unit: .gram(), doubleValue: 20), startDate: Date(),
                                          foodType: nil, absorptionTime: .hours(3)))
        _ = c.debugSnapshot()

        c.beginHandback()
        _ = c.debugSnapshot()
        XCTAssertTrue(offers(in: sent).isEmpty)

        reachable = true
        c.onQueueForTesting { timers().last { $0.label == "handback-recheck" }?.work.perform() }
        XCTAssertEqual(offers(in: sent).count, 1, "reachable again inside the wait: the offer goes")
        XCTAssertTrue(offers(in: sent)[0].urgentOnly, "still never queued")

        // The phone acknowledges the interim offer (records not all committed yet: cursor 0).
        c.handleIncoming(userInfo: try LoanMessage.handbackAck(HandbackAck(epoch: 7, committedCursor: 0)).transportDictionary(),
                         channel: .urgent)
        _ = c.debugSnapshot()
        c.onQueueForTesting { timers().last { $0.label == "handback-answer" }?.work.perform() }
        let snap = c.debugSnapshot()
        XCTAssertTrue(snap.handbackPending, "the phone answered: the End goes on")
        XCTAssertFalse(snap.endDidNotGoThrough)
    }

    /// Once the exchange is under way, a resend that finds the phone unreachable sends nothing and
    /// waits for the next; the hand-back holds for its budget (next-dev 86674900).
    func testAResendsUnreachableReadingDoesNotEndTheHandback() {
        let c = makeLiveLoan()
        let timers = captureTimers(c)
        var reachable = true
        c.isPhoneReachable = { reachable }
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        c.beginHandback()
        _ = c.debugSnapshot()
        XCTAssertEqual(offers(in: sent).count, 1, "the live offer went out")

        reachable = false
        c.onQueueForTesting { timers().last { $0.label == "handback-resend" }?.work.perform() }
        var snap = c.debugSnapshot()
        XCTAssertEqual(snap.phase, .active)
        XCTAssertTrue(snap.handbackPending, "one unreachable reading is not a verdict: the hand-back holds")
        XCTAssertFalse(snap.endDidNotGoThrough)
        XCTAssertEqual(offers(in: sent).count, 1, "nothing goes to an unreachable phone")

        reachable = true
        c.onQueueForTesting { timers().last { $0.label == "handback-resend" }?.work.perform() }
        snap = c.debugSnapshot()
        XCTAssertEqual(offers(in: sent).count, 2, "the next resend sends again")
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

        let reason = "The watch is still looping. To end, turn on iPhone Bluetooth and tap End again."
        c.handleIncoming(userInfo: try LoanMessage.denied(LoanDenied(reason: reason)).transportDictionary(), channel: .urgent)
        let snap = c.debugSnapshot()
        XCTAssertEqual(snap.phase, .active, "the loan continues")
        XCTAssertTrue(snap.hasPumpManager, "the watch still holds the pod")
        XCTAssertFalse(snap.handbackPending, "End stopped at once — no two-minute budget to wait out")
    }

    // MARK: 2a — a failed End says so (ruled 2026-10-19; field e42, 2026-10-13)

    /// End gives up after its budget and the loan carries on: exactly one notification remains,
    /// it says End didn't go through, the one pre-scheduled at End is gone, and the watch screen
    /// says the same until the next End.
    func testAFailedEndSaysSoOnceAndOnTheScreen() {
        let alerts = RecordingWristAlertScheduler()
        WristAlerts.scheduler = alerts
        defer { WristAlerts.scheduler = UNUserNotificationCenter.current() }
        let c = makeLiveLoan()
        c.isPhoneReachable = { true }
        c.send = { _ in }
        c.beginHandback()
        _ = c.debugSnapshot()                 // End runs on the controller's queue
        XCTAssertTrue(alerts.identifiers.contains("sportmode.handbackStuck"), "precondition: the fallback is pre-scheduled at End")

        c.expireHandbackForTesting()          // the budget ran out; nothing was refused or unreachable
        XCTAssertEqual(c.debugSnapshot().phase, .active, "the loan carries on")
        XCTAssertFalse(alerts.identifiers.contains("sportmode.handbackStuck"), "the pre-scheduled one is gone")
        XCTAssertEqual(alerts.pending.count, 1, "exactly one notification")
        XCTAssertEqual(alerts.pending.first?.content.title, "Couldn't End Sport Mode")
        XCTAssertEqual(alerts.pending.first?.content.body, PodLoanWatchController.endDidNotGoThroughText)
        XCTAssertTrue(c.debugSnapshot().endDidNotGoThrough, "and the screen says so")

        c.beginHandback()
        XCTAssertFalse(c.debugSnapshot().endDidNotGoThrough, "until the next End")
    }

    // MARK: 2c — a watch bolus counts from the tap (2026-10-22; builds 227/228, next-dev 8c4c778e, e6c51691)

    /// A bolus on its way to the pod (waiting for the sensor's radio window and the pod's
    /// reconnect) refuses End, and says so; once the pod has it, End's own check carries it.
    func testEndIsRefusedWhileAWatchBolusIsStillBeingSent() {
        let alerts = RecordingWristAlertScheduler()
        WristAlerts.scheduler = alerts
        defer { WristAlerts.scheduler = UNUserNotificationCenter.current() }
        let c = makeLiveLoan()
        c.isPhoneReachable = { true }
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }

        XCTAssertTrue(c.beginWatchBolus(), "no End waiting: the bolus goes ahead")
        c.beginHandback()
        let snap = c.debugSnapshot()
        XCTAssertFalse(snap.handbackPending, "End refused while the bolus is on its way")
        XCTAssertTrue(offers(in: sent).isEmpty, "nothing offered: the pod stays with the bolus")
        XCTAssertEqual(alerts.pending.last?.content.title, "Couldn't End Sport Mode")

        c.endWatchBolus()
        c.beginHandback()
        XCTAssertTrue(c.debugSnapshot().handbackPending, "the bolus reached the pod: End goes ahead")
    }

    /// The other order: once End is waiting for the phone, a new watch bolus is refused, so the
    /// hand-back can never cut one off on its way to the pod.
    func testAWatchBolusIsRefusedWhileAnEndIsWaiting() {
        let c = makeLiveLoan()
        c.isPhoneReachable = { true }
        c.send = { _ in }
        c.beginHandback()
        XCTAssertTrue(c.debugSnapshot().handbackPending, "precondition: End is waiting")
        XCTAssertFalse(c.beginWatchBolus(), "refused: bolus from the iPhone once it has the pod")
    }

    // MARK: 2d — Delete only where the phone would delete (2026-10-22, next-dev 2116be40)

    /// A carb copied from the phone is deletable on the watch only when the phone's Loop wrote it;
    /// another app's entry (the phone refuses to delete it) and one from an older phone that sent
    /// no flag stay protected. An entry made on the watch is always deletable.
    func testTheWatchOffersDeleteOnlyWhereThePhoneWouldDelete() {
        let c = makeLiveLoan()
        let now = Date()
        func record(_ id: String, _ flag: Bool?) -> LoanCarbRecord {
            LoanCarbRecord(syncIdentifier: id, provenanceIdentifier: "phone", syncVersion: 1, startDate: now,
                           grams: 20, absorptionTime: .hours(3), foodType: nil, userCreatedDate: now,
                           userUpdatedDate: nil, createdByCurrentApp: flag)
        }
        let grant = LoanGrant(epoch: 7, expiresAt: now.addingTimeInterval(300), pumpManagerRawState: Data([1]),
                              podAddress: 0, therapySettingsRaw: Data([2]), settingsTimeZoneID: "UTC",
                              doseHistory: [], boundaryRecord: nil,
                              carbHistory: [record("own", true), record("other", false), record("old", nil)])
        c.ingestGrantCarbsForTesting(grant)

        func copied(_ id: String) -> StoredCarbEntry {
            StoredCarbEntry(startDate: now, quantity: HKQuantity(unit: .gram(), doubleValue: 20),
                            provenanceIdentifier: "phone", syncIdentifier: id, createdByCurrentApp: false)
        }
        XCTAssertTrue(c.canDeleteOnWatch(copied("own")), "the phone's Loop wrote it: the phone deletes it too")
        XCTAssertFalse(c.canDeleteOnWatch(copied("other")), "another app's entry: the phone would refuse")
        XCTAssertFalse(c.canDeleteOnWatch(copied("old")), "no flag from an older phone: protected")
        let madeOnWatch = StoredCarbEntry(startDate: now, quantity: HKQuantity(unit: .gram(), doubleValue: 15))
        XCTAssertTrue(c.canDeleteOnWatch(madeOnWatch), "entered on the watch: deletable")
    }

    // MARK: 2b — a refused drain keeps offering (simulator P6, 2026-10-21)

    /// After the watch has let go (released, revoked or relaunched) the phone stays loaned until
    /// it accepts a final offer. A refusal — its Bluetooth is off — must not stop the offers: the
    /// watch used to go idle there, and the phone stayed loaned with nobody dosing.
    func testARefusedDrainKeepsOfferingUntilThePhoneCanTakeThePod() throws {
        let c = makeLiveLoan()
        var timers: [(label: String, work: DispatchWorkItem)] = []
        c.scheduler = { _, label, work in timers.append((label, work)) }
        c.isPhoneReachable = { true }
        c.send = { _ in }
        c.enterFinalStageForTesting()
        c.expireHandbackForTesting()          // released: the drain, holding no pod
        XCTAssertEqual(c.debugSnapshot().phase, .recoveredDrain, "precondition: the drain")

        c.handleIncoming(userInfo: try LoanMessage.denied(LoanDenied(reason: "The watch is still looping. To end, turn on iPhone Bluetooth and tap End again.")).transportDictionary(),
                         channel: .urgent)
        XCTAssertEqual(c.debugSnapshot().phase, .recoveredDrain, "still draining — never idle while the phone is loaned")
        let resend = timers.last { $0.label == "handback-resend" }
        XCTAssertNotNil(resend, "a resend is armed")
        XCTAssertEqual(resend?.work.isCancelled, false, "and it will fire")
    }

    /// A Start tapped over a drain with no records left, timing out: it comes back to rest in the
    /// drain, still owing the phone its final offer — not in idle with the offers stopped.
    func testAStartThatTimesOutOverADrainReturnsToTheDrain() {
        let c = makeLiveLoan()
        c.isPhoneReachable = { true }
        var sent: [[String: Any]] = []
        c.send = { sent.append($0) }
        c.enterFinalStageForTesting()
        c.expireHandbackForTesting()
        XCTAssertEqual(c.debugSnapshot().phase, .recoveredDrain, "precondition: the drain")
        let offersBefore = offers(in: sent).count

        c.scheduler = { _, label, work in if label == "request-timeout" { work.perform() } }
        c.requestLoan(watchBuild: "test")
        XCTAssertEqual(c.debugSnapshot().phase, .recoveredDrain, "back in the drain, not idle")
        XCTAssertGreaterThan(offers(in: sent).count, offersBefore, "and offering again")
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
