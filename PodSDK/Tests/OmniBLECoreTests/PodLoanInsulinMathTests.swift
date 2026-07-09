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
        XCTAssertEqual(p.bolusIOB, 0.500577, accuracy: accuracy)
        XCTAssertEqual(p.eventualBG, 180 - 0.500577 * 50, accuracy: 0.01)
        XCTAssertEqual(p.asOf, now)
    }

    func testPredictWithNoDosesReturnsCurrentBG() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        let j = journal(startedAt: t0)
        let p = j.predict(currentBG: 140, isfMgdlPerUnit: 40, at: t0.addingTimeInterval(600))
        XCTAssertEqual(p.bolusIOB, 0)
        XCTAssertEqual(p.eventualBG, 140)
    }
}
