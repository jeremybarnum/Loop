//
//  PodLoanInsulinMathTests.swift
//  OmniBLECoreTests
//
//  Pins PodLoanInsulinModel to LoopKit's ExponentialInsulinModel algebra.
//  Expected values were computed independently from the LoopKit formula
//  (rapidActingAdult: actionDuration 21600 s, peak 4500 s, delay 600 s):
//
//      tau = peak * (1 - peak/AD) / (1 - 2*peak/AD)
//      a   = 2*tau/AD
//      S   = 1 / (1 - a + (1 + a) * exp(-AD/tau))
//      IOB(t) = 1 - S*(1-a)*((t²/(tau*AD*(1-a)) - t/tau - 1)*e^(-t/tau) + 1)
//
//  If these fail after touching PodLoanInsulinMath, the port has drifted from
//  LoopKit — fix the port, not the vectors.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import OmniBLECore

class PodLoanInsulinMathTests: XCTestCase {

    private let model = PodLoanInsulinModel.rapidActingAdult
    private let accuracy = 1e-5

    // MARK: - Model curve

    func testFullIOBWithinDelay() {
        XCTAssertEqual(model.percentEffectRemaining(at: 0), 1.0)
        XCTAssertEqual(model.percentEffectRemaining(at: .minutes(5)), 1.0)   // still inside the 10-min delay
        XCTAssertEqual(model.percentEffectRemaining(at: .minutes(10)), 1.0)
    }

    func testDecayCurveMatchesLoopKitFormula() {
        XCTAssertEqual(model.percentEffectRemaining(at: .minutes(30)), 0.965975, accuracy: accuracy)
        XCTAssertEqual(model.percentEffectRemaining(at: .minutes(60)), 0.833799, accuracy: accuracy)
        XCTAssertEqual(model.percentEffectRemaining(at: .minutes(120)), 0.500577, accuracy: accuracy)
        XCTAssertEqual(model.percentEffectRemaining(at: .minutes(180)), 0.240574, accuracy: accuracy)
        XCTAssertEqual(model.percentEffectRemaining(at: .minutes(300)), 0.019826, accuracy: accuracy)
    }

    func testZeroAfterDelayPlusDuration() {
        XCTAssertEqual(model.percentEffectRemaining(at: .minutes(370)), 0.0)   // 10 min delay + 360 min action
        XCTAssertEqual(model.percentEffectRemaining(at: .minutes(600)), 0.0)
    }

    func testAfrezzaDecaysFaster() {
        // afrezza: actionDuration 300 min, peak 29 min — computed from the same formula.
        XCTAssertEqual(PodLoanInsulinModel.afrezza.percentEffectRemaining(at: .minutes(120)), 0.094855, accuracy: accuracy)
    }

    func testInsulinTypeRawMapping() {
        XCTAssertEqual(PodLoanInsulinModel.forInsulinTypeRaw(3), .fiasp)
        XCTAssertEqual(PodLoanInsulinModel.forInsulinTypeRaw(4), .lyumjev)
        XCTAssertEqual(PodLoanInsulinModel.forInsulinTypeRaw(5), .afrezza)
        XCTAssertEqual(PodLoanInsulinModel.forInsulinTypeRaw(0), .rapidActingAdult)   // novolog
        XCTAssertEqual(PodLoanInsulinModel.forInsulinTypeRaw(nil), .rapidActingAdult)
        XCTAssertEqual(PodLoanInsulinModel.forInsulinTypeRaw(99), .rapidActingAdult)
    }

    // MARK: - Journal bolus IOB

    private func journal(startedAt t0: Date) -> PodLoanJournal {
        PodLoanJournal(startedAt: t0, deliveredAtStart: 0)
    }

    func testBolusIOBSingleDose() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        var j = journal(startedAt: t0)
        j.record(.bolus(units: 1.0), at: t0)
        let now = t0.addingTimeInterval(.minutes(120))
        XCTAssertEqual(j.bolusIOB(at: now, model: model), 0.500577, accuracy: accuracy)
    }

    func testBolusIOBStacksDoses() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        var j = journal(startedAt: t0)
        j.record(.bolus(units: 1.0), at: t0)                                  // 2 h before read
        j.record(.bolus(units: 0.5), at: t0.addingTimeInterval(.minutes(60))) // 1 h before read
        let now = t0.addingTimeInterval(.minutes(120))
        // 1.0×0.500577 + 0.5×0.833799
        XCTAssertEqual(j.bolusIOB(at: now, model: model), 0.917476, accuracy: accuracy)
    }

    func testBolusIOBIgnoresNonBolusEvents() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        var j = journal(startedAt: t0)
        j.record(.tempBasal(rate: 1.0, duration: .minutes(180)), at: t0)
        j.record(.suspend, at: t0.addingTimeInterval(60))
        j.record(.resume, at: t0.addingTimeInterval(120))
        XCTAssertEqual(j.bolusIOB(at: t0.addingTimeInterval(.minutes(60))), 0.0)
    }

    func testBolusIOBFreshDoseIsFullyActive() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        var j = journal(startedAt: t0)
        j.record(.bolus(units: 0.75), at: t0)
        XCTAssertEqual(j.bolusIOB(at: t0.addingTimeInterval(60)), 0.75)   // within delay
    }

    // MARK: - predict()

    func testPredictAppliesISF() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        var j = journal(startedAt: t0)
        j.record(.bolus(units: 1.0), at: t0)
        let now = t0.addingTimeInterval(.minutes(120))
        let p = j.predict(currentBG: 180, isfMgdlPerUnit: 50, at: now, model: model)
        XCTAssertEqual(p.iob, 0.500577, accuracy: accuracy)
        XCTAssertEqual(p.eventualBG, 180 - 0.500577 * 50, accuracy: 0.01)
        XCTAssertEqual(p.asOf, now)
    }

    func testPredictWithNoDosesReturnsCurrentBG() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        let j = journal(startedAt: t0)
        let p = j.predict(currentBG: 140, isfMgdlPerUnit: 40, at: t0.addingTimeInterval(600))
        XCTAssertEqual(p.iob, 0)
        XCTAssertEqual(p.eventualBG, 140)
    }

    // MARK: - Net basal vs schedule (symmetric IOB)
    //
    // Expected values computed independently from the LoopKit formula with the
    // same 5-minute slicing (see file header discipline): net contribution of a
    // slice = (actualRate − scheduledRate) × hours × percentEffectRemaining
    // measured from the slice midpoint.

    private var flatSchedule: PodLoanBasalSchedule {
        PodLoanBasalSchedule(items: [.init(startOffset: 0, rate: 1.0)], timeZoneSecondsFromGMT: 0)
    }

    func testScheduleRateLookup() {
        let sched = PodLoanBasalSchedule(items: [
            .init(startOffset: 0, rate: 0.5),
            .init(startOffset: 43200, rate: 1.5),   // noon
        ], timeZoneSecondsFromGMT: 0)
        let midnight = Date(timeIntervalSince1970: 1_780_012_800)  // 2026-05-29 00:00:00 UTC
        XCTAssertEqual(sched.rate(at: midnight.addingTimeInterval(6 * 3600)), 0.5)    // 06:00
        XCTAssertEqual(sched.rate(at: midnight.addingTimeInterval(13 * 3600)), 1.5)   // 13:00
        XCTAssertEqual(sched.rate(at: midnight.addingTimeInterval(23 * 3600)), 1.5)   // 23:00
    }

    func testTempAboveScheduleAddsNetIOB() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        var j = journal(startedAt: t0)
        j.record(.tempBasal(rate: 2.0, duration: .minutes(30)), at: t0)
        let now = t0.addingTimeInterval(.minutes(30))
        XCTAssertEqual(j.netBasalIOB(at: now, schedule: flatSchedule, model: model), 0.496111, accuracy: accuracy)
    }

    func testSuspendSubtractsNetIOB() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        var j = journal(startedAt: t0)
        j.record(.suspend, at: t0)
        j.record(.resume, at: t0.addingTimeInterval(.minutes(60)))
        // Read at resume: a full hour of missing 1.0 U/hr, barely decayed.
        XCTAssertEqual(j.netBasalIOB(at: t0.addingTimeInterval(.minutes(60)), schedule: flatSchedule, model: model),
                       -0.948783, accuracy: accuracy)
        // An hour later the deficit has decayed toward zero.
        XCTAssertEqual(j.netBasalIOB(at: t0.addingTimeInterval(.minutes(120)), schedule: flatSchedule, model: model),
                       -0.666317, accuracy: accuracy)
    }

    func testTempEqualToScheduleNetsToZero() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        var j = journal(startedAt: t0)
        j.record(.tempBasal(rate: 1.0, duration: .minutes(60)), at: t0)
        XCTAssertEqual(j.netBasalIOB(at: t0.addingTimeInterval(.minutes(45)), schedule: flatSchedule, model: model),
                       0.0, accuracy: 1e-9)
    }

    func testTempExpiryRevertsToScheduleInIOB() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        var j = journal(startedAt: t0)
        // 30-min temp; read at 60 min — the second half hour followed schedule (net 0),
        // so only the first 30 min contribute, decayed by the extra 30 min.
        j.record(.tempBasal(rate: 2.0, duration: .minutes(30)), at: t0)
        let iobAtEnd = j.netBasalIOB(at: t0.addingTimeInterval(.minutes(30)), schedule: flatSchedule, model: model)
        let iobLater = j.netBasalIOB(at: t0.addingTimeInterval(.minutes(60)), schedule: flatSchedule, model: model)
        XCTAssertLessThan(iobLater, iobAtEnd)   // decays, no new accrual after expiry
        XCTAssertGreaterThan(iobLater, 0)
    }

    func testNetBasalDeliveredIsRawUndecayed() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        var j = journal(startedAt: t0)
        // Temp 2.0 vs schedule 1.0 for 30 min → (2.0−1.0)×0.5h = +0.5 U delivered.
        j.record(.tempBasal(rate: 2.0, duration: .minutes(30)), at: t0)
        XCTAssertEqual(j.netBasalDelivered(until: t0.addingTimeInterval(.minutes(30)), schedule: flatSchedule),
                       0.5, accuracy: accuracy)
        // Read an hour later: no new accrual after expiry (temp reverted to schedule).
        XCTAssertEqual(j.netBasalDelivered(until: t0.addingTimeInterval(.minutes(90)), schedule: flatSchedule),
                       0.5, accuracy: accuracy)
    }

    func testNetBasalDeliveredNegativeForSuspend() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        var j = journal(startedAt: t0)
        j.record(.suspend, at: t0)
        j.record(.resume, at: t0.addingTimeInterval(.minutes(60)))
        // 60 min of missing 1.0 U/hr = −1.0 U delivered (raw, undecayed).
        XCTAssertEqual(j.netBasalDelivered(until: t0.addingTimeInterval(.minutes(60)), schedule: flatSchedule),
                       -1.0, accuracy: accuracy)
    }

    func testCombinedIOBIsBolusPlusNetBasal() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        var j = journal(startedAt: t0)
        j.record(.bolus(units: 0.5), at: t0)
        j.record(.suspend, at: t0)
        j.record(.resume, at: t0.addingTimeInterval(.minutes(30)))
        let now = t0.addingTimeInterval(.minutes(30))
        // 0.5 U bolus (0.482987 remaining) ≈ cancelled by 30-min suspend of 1.0 U/hr (−0.496111).
        XCTAssertEqual(j.iob(at: now, schedule: flatSchedule, model: model), -0.013124, accuracy: accuracy)
        // Without a schedule, degrades to bolus-only.
        XCTAssertEqual(j.iob(at: now, schedule: nil, model: model), 0.482987, accuracy: accuracy)
    }
}
