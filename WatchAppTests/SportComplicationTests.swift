//
//  SportComplicationTests.swift
//  WatchAppTests
//
//  The Utility-face corner complications: IOB, COB, eventual BG, and BG → eventual.
//

import XCTest
import ClockKit
import HealthKit
import LoopCore
import LoopKit
@testable import WatchApp_Extension

final class SportComplicationTests: XCTestCase {

    private let now = Date()

    private func reading(loopAge: TimeInterval = 60, glucoseAge: TimeInterval = 60) -> ComplicationController.SportReading {
        ComplicationController.SportReading(
            glucose: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 120), glucoseDate: now.addingTimeInterval(-glucoseAge),
            iob: 1.24, cob: 23.6, eventual: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 128),
            unit: .milligramsPerDeciliter, loopDate: now.addingTimeInterval(-loopAge))
    }

    private func text(_ value: ComplicationController.SportValue, _ family: CLKComplicationFamily,
                      _ r: ComplicationController.SportReading) -> String? {
        let template = ComplicationController.sportTemplate(value, family: family, reading: r, at: now)
        let provider = (template as? CLKComplicationTemplateUtilitarianSmallFlat)?.textProvider
            ?? (template as? CLKComplicationTemplateUtilitarianLargeFlat)?.textProvider
        return (provider as? CLKSimpleTextProvider)?.text
    }

    func testCornerTextsAreShort() {
        let r = reading()
        XCTAssertEqual(text(.iob, .utilitarianSmallFlat, r), "1.2U")
        XCTAssertEqual(text(.cob, .utilitarianSmallFlat, r), "24g")
        XCTAssertEqual(text(.eventual, .utilitarianSmallFlat, r), "→128")
        XCTAssertEqual(text(.glucoseToEventual, .utilitarianSmall, r), "120→128")
    }

    func testBottomSlotSaysWhatEachNumberIs() {
        let r = reading()
        XCTAssertEqual(text(.iob, .utilitarianLarge, r), "IOB 1.2 U")
        XCTAssertEqual(text(.cob, .utilitarianLarge, r), "COB 24 g")
        XCTAssertEqual(text(.eventual, .utilitarianLarge, r), "Eventually 128")
        XCTAssertEqual(text(.glucoseToEventual, .utilitarianLarge, r), "BG 120 → 128")
    }

    /// A stale loop must not leave yesterday's insulin on the wrist as if it were current.
    func testAStaleLoopShowsDashes() {
        let r = reading(loopAge: 20 * 60)
        XCTAssertEqual(text(.iob, .utilitarianSmallFlat, r), "IOB —")
        XCTAssertEqual(text(.cob, .utilitarianSmallFlat, r), "COB —")
        XCTAssertEqual(text(.eventual, .utilitarianSmallFlat, r), "→—")
        XCTAssertEqual(text(.glucoseToEventual, .utilitarianSmallFlat, r), "120→—", "the reading is still fresh")
    }

    func testAStaleReadingDashesOnlyTheCurrentValue() {
        XCTAssertEqual(text(.glucoseToEventual, .utilitarianSmallFlat, reading(glucoseAge: 20 * 60)), "—→128")
    }

    func testOnlyUtilityFamiliesAreOffered() {
        XCTAssertNil(ComplicationController.sportTemplate(.iob, family: .graphicRectangular, reading: reading(), at: now))
        XCTAssertEqual(Set(ComplicationController.sportFamilies), [.utilitarianSmall, .utilitarianSmallFlat, .utilitarianLarge])
    }
}
