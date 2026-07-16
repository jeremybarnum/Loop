//
//  PodControllerGuardTests.swift
//  OmniBLECoreTests
//
//  Input guards on PodController.setTempBasal. These run against an
//  unpaired controller: a request that fails VALIDATION returns its specific
//  error synchronously, while a request that passes validation proceeds to
//  runCommand and fails with .notPaired — so .notPaired doubles as the
//  "validation accepted this input" signal.
//

import XCTest
@testable import OmniBLECore

class PodControllerGuardTests: XCTestCase {

    private func setTempBasalError(rate: Double, duration: TimeInterval) -> Error? {
        let controller = PodController()
        let exp = expectation(description: "completion")
        var result: Result<PodControlStatus, Error>?
        controller.setTempBasal(rate: rate, duration: duration) {
            result = $0
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        guard case .failure(let error)? = result else {
            XCTFail("expected failure on unpaired controller")
            return nil
        }
        return error
    }

    func testRefusesSubThirtyMinuteDuration() {
        let error = setTempBasalError(rate: 1.0, duration: .minutes(17))
        guard case PodControlError.tempBasalDurationNotSupported? = error else {
            XCTFail("expected tempBasalDurationNotSupported, got \(String(describing: error))")
            return
        }
    }

    func testRefusesZeroDuration() {
        let error = setTempBasalError(rate: 1.0, duration: 0)
        guard case PodControlError.tempBasalDurationNotSupported? = error else {
            XCTFail("expected tempBasalDurationNotSupported, got \(String(describing: error))")
            return
        }
    }

    func testRefusesOverTwelveHourDuration() {
        let error = setTempBasalError(rate: 1.0, duration: .hours(12.5))
        guard case PodControlError.tempBasalDurationNotSupported? = error else {
            XCTFail("expected tempBasalDurationNotSupported, got \(String(describing: error))")
            return
        }
    }

    func testAcceptsSupportedDuration() {
        let error = setTempBasalError(rate: 1.0, duration: .hours(3))
        guard case PodControlError.notPaired? = error else {
            XCTFail("expected notPaired (validation passed), got \(String(describing: error))")
            return
        }
    }

    func testOffGridRateSnapsDownWithinCap() {
        // 3.02 snaps to 3.00 == tempBasalRateProofLimit, so validation passes
        // and the unpaired controller fails with notPaired, not the cap error.
        let error = setTempBasalError(rate: 3.02, duration: .hours(3))
        guard case PodControlError.notPaired? = error else {
            XCTFail("expected notPaired (3.02 should snap to 3.00), got \(String(describing: error))")
            return
        }
    }

    func testOffGridRateSnapsUpPastCap() {
        // 3.03 snaps to 3.05 > tempBasalRateProofLimit and must be refused.
        let error = setTempBasalError(rate: 3.03, duration: .hours(3))
        guard case PodControlError.tempBasalExceedsProofLimit? = error else {
            XCTFail("expected tempBasalExceedsProofLimit (3.03 should snap to 3.05), got \(String(describing: error))")
            return
        }
    }

    func testNegativeRateClampsToZeroTemp() {
        // A negative rate must not trap in command encoding — it clamps to a
        // legal zero temp, passes validation, and fails only as notPaired.
        let error = setTempBasalError(rate: -1.0, duration: .hours(3))
        guard case PodControlError.notPaired? = error else {
            XCTFail("expected notPaired (negative clamps to 0), got \(String(describing: error))")
            return
        }
    }
}
