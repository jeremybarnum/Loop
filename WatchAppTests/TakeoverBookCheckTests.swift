//
//  TakeoverBookCheckTests.swift
//  WatchAppTests
//
//  The takeover book check (ported from next-dev ac23c1d1, 2026-09-24). At every Start the watch
//  compares the pod's total with the total its copy carried, and books what the copy's own
//  records cannot explain as a bolus delivered now. The case it exists for: a meal bolus given on
//  the phone after the standing copy was made, then out of the door without the phone — that
//  insulin is otherwise in nobody's book on the wrist, and the watch would dose on top of it.
//

import XCTest
import LoopKit
@testable import WatchApp_Extension

final class TakeoverBookCheckTests: XCTestCase {

    /// A fixed instant, so nothing here depends on the wall clock or the day boundary.
    private let copyAt = Date(timeIntervalSince1970: 1_758_020_400)   // mid-day UTC
    private var now: Date { copyAt.addingTimeInterval(.minutes(10)) }
    private let schedule = BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 1.2)])!

    private func check(podTotal: Double, records: [LoanDoseRecord] = []) -> Double {
        PodLoanWatchController.insulinTheCopyCannotExplain(copyTotal: 10.0, copyAt: copyAt, podTotal: podTotal,
                                                           now: now, records: records, schedule: schedule)
    }

    /// An ordinary Start: ten minutes of 1.2 U/h schedule is 0.20 U; a little drift on top stays
    /// inside the phone's 0.20 U band and books nothing.
    func testAnOrdinaryStartBooksNothing() {
        XCTAssertEqual(check(podTotal: 10.20), 0, "exactly the schedule")
        XCTAssertEqual(check(podTotal: 10.35), 0, "+0.15 U of drift is inside the band")
    }

    /// The forgotten phone: a 6 U bolus given after the copy was made, in no record the watch has.
    func testAPhoneBolusAfterTheCopyIsBookedWhole() {
        XCTAssertEqual(check(podTotal: 10.0 + 0.20 + 6.0), 6.0, accuracy: 0.001)
    }

    /// A bolus still delivering when the copy's pod reading was taken: part of it is already in
    /// the copy's total, part lands after. Its record starts BEFORE the reading, so without the
    /// proration the watch would book, a second time, a bolus the copy already knows.
    func testABolusStillDeliveringAtTheCopyIsNotBookedTwice() {
        // 4 U over 160 s, 60 s of it before the copy's reading: 1.5 U already in the copy, 2.5 U after.
        let bolus = LoanDoseRecord(kind: .bolus, startDate: copyAt.addingTimeInterval(-60),
                                   endDate: copyAt.addingTimeInterval(100), amount: 4.0)
        XCTAssertEqual(check(podTotal: 10.0 + 0.20 + 2.5, records: [bolus]), 0,
                       "the tail of a known bolus is explained, not booked")
    }

    /// A temp in the copy explains its own delivery: 3.0 U/h for the ten minutes is 0.50 U.
    func testATempInTheCopyExplainsItsOwnDelivery() {
        let temp = LoanDoseRecord(kind: .tempBasal, startDate: copyAt.addingTimeInterval(-.minutes(5)),
                                  endDate: copyAt.addingTimeInterval(.minutes(25)), unitsPerHour: 3.0)
        XCTAssertEqual(check(podTotal: 10.50, records: [temp]), 0)
    }

    /// Nothing to compare: a pod total below the copy's (a read artefact) or no time elapsed.
    func testNoWindowOrALowerPodTotalBooksNothing() {
        XCTAssertEqual(check(podTotal: 9.0), 0)
        XCTAssertEqual(PodLoanWatchController.insulinTheCopyCannotExplain(
            copyTotal: 10.0, copyAt: copyAt, podTotal: 16.0, now: copyAt, records: [], schedule: schedule), 0)
    }

    /// End to end, down to the book the loop doses from: the booked entry is insulin on board.
    func testTheBookedEntryIsInsulinOnBoard() {
        var ledger = SessionInsulinLedger(
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration)
        ledger.seed(finished: [], live: [])
        let booked = DoseEntry(type: .bolus, startDate: now, endDate: now, value: 6.0, unit: .units,
                               deliveredUnits: 6.0, syncIdentifier: "PODLOAN-WATCHGAP-e7")
        ledger.recordEnact(booked)
        XCTAssertEqual(ledger.insulinOnBoard(at: now, basalSchedule: schedule), 6.0, accuracy: 0.1,
                       "booked now, so all of it is on board now")
    }
}
