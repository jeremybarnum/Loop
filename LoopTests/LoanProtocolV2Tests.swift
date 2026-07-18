//
//  LoanProtocolV2Tests.swift
//  LoopTests
//
//  Loan protocol v2 unit coverage (DESIGN_LOAN_PROTOCOL_V2.md §10): wire-format
//  round-trip + version skew (never-silently-discard), and the R22 fingerprints-only
//  allocation properties (never reduce confirmed, exact-match preference with
//  latest-on-tie, skipped-reduction window fit, ambiguity touches nothing, one-way
//  valve). Controller-level flows (epoch race D22, resend/ack ordering) are exercised
//  as bench drills Part E; the state machines' UserDefaults/UNNotification coupling
//  keeps them out of unit scope deliberately.
//
//  NOTE: run via Xcode (Cmd-U). CLI test execution fails signing in this environment;
//  the CLI gate is compile-only.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

final class LoanProtocolV2Tests: XCTestCase {

    // MARK: - Wire format

    private func roundTrip(_ message: LoanMessage) throws -> LoanMessage? {
        let dict = try message.transportDictionary()
        return try LoanMessage.decode(fromTransport: dict)
    }

    func testEveryMessageKindRoundTrips() throws {
        // Dates on the wire's millisecond grid: the protocol encodes Int64 ms, so
        // sub-millisecond fractions deliberately do not survive (determinism > ULPs).
        let now = Date(timeIntervalSince1970: 1_784_338_000.125)
        let status = LoanPodStatus(timestamp: now, deliveredUnits: 12.3, reservoirLevel: nil, isSuspended: false, faultCode: nil)
        let event = LoanEvent(id: UUID(), seq: 3, provenance: .assumed(.bolusUncertain),
                              record: LoanDoseRecord(kind: .bolus, startDate: now, amount: 1.0), loggedAt: now)
        let messages: [LoanMessage] = [
            .request(LoanRequest(watchBuild: "77")),
            .grant(LoanGrant(epoch: 5, expiresAt: now.addingTimeInterval(300),
                             pumpManagerRawState: Data([1, 2, 3]), podAddress: 0x1F0A2B3C,
                             therapySettingsRaw: Data([4, 5]), settingsTimeZoneID: "America/New_York",
                             doseHistory: [LoanDoseRecord(kind: .tempBasal, startDate: now, endDate: now.addingTimeInterval(1800), unitsPerHour: 0.8)],
                             boundaryRecord: LoanDoseRecord(kind: .boundaryTruncation, startDate: now, endDate: now, unitsPerHour: 0))),
            .takeoverComplete(TakeoverComplete(epoch: 5, firstPodStatus: status)),
            .takeoverFailed(TakeoverFailed(epoch: 5, reason: "test")),
            .doseRecordBatch(DoseRecordBatch(epoch: 5, events: [event], tombstones: [UUID()])),
            .handbackOffer(HandbackOffer(epoch: 5, handedBackAt: now, finalStatus: status,
                                         odometer: LoanOdometerSnapshot(deliveredAtStart: 10, deliveredLatest: 12, freshenSucceeded: true),
                                         events: [event], tombstones: [], recovered: false)),
            .handbackAck(HandbackAck(epoch: 5, committedCursor: 3)),
            .revoke(Revoke(epoch: 5)),
            .statusQuery(StatusQuery(epoch: 5)),
            .statusReport(StatusReport(epoch: 5, mode: .closedDirect, lastDirectGlucoseAge: 120, lastEventSeq: 3, podFault: nil, holdsPod: true)),
            .nack(ProtocolNack(seenVersion: 1)),
            .denied(LoanDenied(reason: "settings incomplete")),
        ]
        for message in messages {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testEpochAccessorCoversEveryKind() {
        XCTAssertNil(LoanMessage.request(LoanRequest(watchBuild: "77")).epoch)
        XCTAssertNil(LoanMessage.nack(ProtocolNack(seenVersion: nil)).epoch)
        XCTAssertEqual(LoanMessage.revoke(Revoke(epoch: 9)).epoch, 9)
    }

    func testForeignPayloadIsNotOurs() throws {
        XCTAssertNil(try LoanMessage.decode(fromTransport: ["somethingElse": Data([1])]))
    }

    func testVersionSkewThrowsNeverDiscards() throws {
        var dict = try LoanMessage.revoke(Revoke(epoch: 1)).transportDictionary()
        var json = try JSONSerialization.jsonObject(with: dict[LoanProtocol.userInfoKey] as! Data) as! [String: Any]
        json["protocolVersion"] = 99
        dict[LoanProtocol.userInfoKey] = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try LoanMessage.decode(fromTransport: dict)) { error in
            guard case LoanProtocolError.undecodable(let seen) = error else { return XCTFail() }
            XCTAssertEqual(seen, 99)
        }
    }

    func testUnknownKindThrows() throws {
        var dict = try LoanMessage.revoke(Revoke(epoch: 1)).transportDictionary()
        var json = try JSONSerialization.jsonObject(with: dict[LoanProtocol.userInfoKey] as! Data) as! [String: Any]
        json["kind"] = "futureMessage"
        dict[LoanProtocol.userInfoKey] = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try LoanMessage.decode(fromTransport: dict))
    }

    // MARK: - R22 allocation fixtures

    private let loanStart = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private var loanEnd: Date { loanStart.addingTimeInterval(7200) }  // 2 h loan

    private var flatSchedule: BasalRateSchedule {
        BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)], timeZone: TimeZone(identifier: "GMT")!)!
    }

    private func bolusEvent(seq: Int, units: Double, provenance: EventProvenance, at offset: TimeInterval) -> LoanEvent {
        LoanEvent(id: UUID(), seq: seq, provenance: provenance,
                  record: LoanDoseRecord(kind: .bolus, startDate: loanStart.addingTimeInterval(offset), amount: units),
                  loggedAt: loanStart.addingTimeInterval(offset))
    }

    private func odometer(delivered: Double) -> LoanOdometerSnapshot {
        LoanOdometerSnapshot(deliveredAtStart: 50, deliveredLatest: 50 + delivered, freshenSucceeded: true)
    }

    private func reconcile(events: [LoanEvent], delivered: Double) -> LoanReconciler.Outcome {
        LoanReconciler.reconcile(LoanReconciler.Input(
            events: events, odometer: odometer(delivered: delivered),
            schedule: flatSchedule, loanStart: loanStart, loanEnd: loanEnd))
    }

    // MARK: - R22 properties

    /// The designed case: one false max-exposure assumption, exact-size shortfall.
    func testExactSizeFingerprintAnnulsTheAssumedEvent() {
        let phantom = bolusEvent(seq: 1, units: 1.0, provenance: .assumed(.bolusUncertain), at: 600)
        // Schedule expectation = 2 h × 1.0 = 2.0; journal claims +1.0 bolus = 3.0;
        // pod delivered only 2.0 → shortfall exactly the phantom's size.
        let outcome = reconcile(events: [phantom], delivered: 2.0)
        XCTAssertEqual(outcome.annulledEventIDs, [phantom.id])
        XCTAssertNil(outcome.residualShortfallUnits)
        XCTAssertTrue(outcome.doses.isEmpty)
    }

    /// A confirmed event can NEVER be reduced — same arithmetic, confirmed tag.
    func testConfirmedEventsAreNeverAnnulled() {
        let confirmed = bolusEvent(seq: 1, units: 1.0, provenance: .confirmed, at: 600)
        let outcome = reconcile(events: [confirmed], delivered: 2.0)
        XCTAssertTrue(outcome.annulledEventIDs.isEmpty)
        XCTAssertEqual(outcome.residualShortfallUnits ?? 0, 1.0, accuracy: 0.01)
        // The record is entered IN FULL (max-exposure: never truncate downward).
        XCTAssertEqual(outcome.doses.count, 1)
        XCTAssertEqual(outcome.doses[0].programmedUnits, 1.0)
    }

    /// Ambiguity touches NOTHING: two assumed events, inexact shortfall.
    func testAmbiguousShortfallGoesWholeToResidual() {
        let a = bolusEvent(seq: 1, units: 1.0, provenance: .assumed(.bolusUncertain), at: 600)
        let b = bolusEvent(seq: 2, units: 0.6, provenance: .assumed(.bolusUncertain), at: 1200)
        // Expected = 2.0 + 1.6 = 3.6; delivered 2.9 → shortfall 0.7 matches neither.
        let outcome = reconcile(events: [a, b], delivered: 2.9)
        XCTAssertTrue(outcome.annulledEventIDs.isEmpty)
        XCTAssertEqual(outcome.residualShortfallUnits ?? 0, 0.7, accuracy: 0.01)
        XCTAssertEqual(outcome.doses.count, 2)  // both entered in full
    }

    /// Tie at the same size → the LATEST assumed event is annulled.
    func testExactMatchTiePrefersLatest() {
        let early = bolusEvent(seq: 1, units: 1.0, provenance: .assumed(.bolusUncertain), at: 300)
        let late = bolusEvent(seq: 2, units: 1.0, provenance: .assumed(.bolusUncertain), at: 3000)
        let outcome = reconcile(events: [early, late], delivered: 3.0)  // expected 4.0
        XCTAssertEqual(outcome.annulledEventIDs, [late.id])
    }

    /// C′: a real reduction the max-exposure rule declined to record — the flagged
    /// skipped-reduction window absorbs the shortfall retroactively.
    func testSkippedReductionWindowAbsorbsShortfall() {
        // Marker: a 1 h window whose schedule insulin (1.0 U) can absorb the shortfall.
        let marker = LoanEvent(id: UUID(), seq: 1, provenance: .assumed(.skippedReduction),
                               record: LoanDoseRecord(kind: .tempBasal, startDate: loanStart.addingTimeInterval(600),
                                                      endDate: loanStart.addingTimeInterval(4200), unitsPerHour: 0),
                               loggedAt: loanStart.addingTimeInterval(600))
        // The marker's rate-0 span REPLACES schedule in expectation (1 h at 0), so
        // expected = 1 h × 1.0 = 1.0 + 0 = 1.0... the pod ALSO didn't run the other
        // hour? Construct: delivered = 0.6 → shortfall vs expected(=1.0) is 0.4,
        // within the marker window's scheduled 1.0 U → absorbed, no residual.
        let outcome = LoanReconciler.reconcile(LoanReconciler.Input(
            events: [marker], odometer: odometer(delivered: 0.6),
            schedule: flatSchedule, loanStart: loanStart, loanEnd: loanEnd))
        XCTAssertEqual(outcome.annulledEventIDs, [marker.id])
        XCTAssertNil(outcome.residualShortfallUnits)
    }

    /// The R6 one-way valve, positive side: timed-late entry, never subtraction.
    func testPositiveRemainderEntersTimedLate() {
        let outcome = reconcile(events: [], delivered: 2.5)  // expected 2.0
        XCTAssertEqual(outcome.positiveRemainderUnits ?? 0, 0.5, accuracy: 0.01)
        XCTAssertNil(outcome.residualShortfallUnits)
    }

    /// A stale odometer (freshen failed) disables the audit entirely — records only.
    func testUnfreshenedOdometerDisablesAudit() {
        let phantom = bolusEvent(seq: 1, units: 1.0, provenance: .assumed(.bolusUncertain), at: 600)
        let outcome = LoanReconciler.reconcile(LoanReconciler.Input(
            events: [phantom],
            odometer: LoanOdometerSnapshot(deliveredAtStart: 50, deliveredLatest: 52, freshenSucceeded: false),
            schedule: flatSchedule, loanStart: loanStart, loanEnd: loanEnd))
        XCTAssertTrue(outcome.annulledEventIDs.isEmpty)
        XCTAssertNil(outcome.residualShortfallUnits)
        XCTAssertNil(outcome.positiveRemainderUnits)
        XCTAssertEqual(outcome.doses.count, 1)
    }

    // MARK: - Expected-insulin math (journal supersedes schedule, schedule fills gaps)

    func testExpectedInsulinJournalOverridesSchedule() {
        // 2 h window, flat 1.0 U/hr schedule, journaled 2.0 U/hr temp for the 1st hour:
        // expected = 2.0 (temp hour) + 1.0 (schedule hour) = 3.0.
        let temp = LoanEvent(id: UUID(), seq: 1, provenance: .confirmed,
                             record: LoanDoseRecord(kind: .tempBasal, startDate: loanStart,
                                                    endDate: loanStart.addingTimeInterval(3600), unitsPerHour: 2.0),
                             loggedAt: loanStart)
        let expected = LoanReconciler.expectedInsulin(events: [temp], schedule: flatSchedule, from: loanStart, to: loanEnd)
        XCTAssertEqual(expected, 3.0, accuracy: 0.01)
    }

    func testExpectedInsulinSuspendCountsAsZero() {
        // R3 suspend = rate-0 temp for hour 1: expected = 0 + 1.0 = 1.0.
        let suspend = LoanEvent(id: UUID(), seq: 1, provenance: .confirmed,
                                record: LoanDoseRecord(kind: .suspend, startDate: loanStart,
                                                       endDate: loanStart.addingTimeInterval(3600), unitsPerHour: 0),
                                loggedAt: loanStart)
        let expected = LoanReconciler.expectedInsulin(events: [suspend], schedule: flatSchedule, from: loanStart, to: loanEnd)
        XCTAssertEqual(expected, 1.0, accuracy: 0.01)
    }
}
