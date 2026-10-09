//
//  GlanceComplicationTests.swift
//  WatchAppTests
//
//  The glance complication: its snapshot comes from the glance's own sources and formats, each value
//  dashes once it is older than 15 min, and the timeline carries those moments.
//

import XCTest
import LoopKit
import LoopAlgorithm
import LoopCore
@testable import WatchApp

@MainActor
final class GlanceComplicationTests: XCTestCase {

    private let now = Date()

    private func mgdl(_ value: Double) -> LoopQuantity { LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: value) }

    private func glanceData(glucoseAge: TimeInterval = 60, loopAge: TimeInterval = 60, iob: Double? = 2.345,
                            tempRate: Double? = 0.75, closed: Bool = true, overrideLabel: String? = nil) -> WatchLoopManager.GlanceData {
        WatchLoopManager.GlanceData(
            glucose: mgdl(106), glucoseDate: now.addingTimeInterval(-glucoseAge),
            directG7At: now.addingTimeInterval(-glucoseAge), phoneRelayAt: nil, sensorActivatedAt: nil,
            trend: .up, eventual: mgdl(112.4), iob: iob,
            dosingEventual: nil, dosingIOB: nil, dosingCOB: nil,
            tempRate: tempRate, lastLoopCompleted: now.addingTimeInterval(-loopAge),
            suspendThreshold: mgdl(70), closedLoopEnabled: closed,
            recommendedTempRate: nil, lastLoopErrorText: nil, predictionBreakdown: nil,
            retrospectiveCorrectionIsIntegral: false, retrospectiveDiscrepancyCount: 0,
            overrideLabel: overrideLabel)
    }

    // MARK: - Sources

    /// During a loan the numbers are the glance's own strings, so the two can never disagree.
    func testALoanPublishesTheGlancesOwnNumbers() {
        let data = glanceData(overrideLabel: "🏃 70% 140")
        let glance = GlanceViewModel.activeState(data: data, cob: 15.4, now: now)
        let s = GlanceComplicationPublisher.snapshot(loan: data, cob: 15.4, unit: .milligramsPerDeciliter, now: now)

        XCTAssertEqual(s.iobText, glance.iobText)
        XCTAssertEqual(s.cobText, glance.cobText)
        XCTAssertEqual(s.tempText, glance.tempText)
        XCTAssertEqual(s.overrideLabel, glance.overrideLabel)
        XCTAssertEqual(s.bg(at: now), glance.bgText)
        XCTAssertEqual(s.trend(at: now), glance.trendSymbol)
        XCTAssertEqual(s.eventual(at: now), glance.eventualText)
        XCTAssertEqual(s.bgRange, .inRange)
        XCTAssertTrue(s.watchHasPod)
    }

    /// A value the loop has not produced is a dash, not the glance's placeholder string.
    func testAMissingLoanValueIsADash() {
        let s = GlanceComplicationPublisher.snapshot(loan: glanceData(iob: nil, tempRate: nil), cob: nil,
                                                     unit: .milligramsPerDeciliter, now: now)
        XCTAssertEqual(s.line(.iobCob, at: now), "IOB — · COB —")
        XCTAssertEqual(s.value(.temp, at: now), "—")
    }

    /// Outside a loan: the phone's context, formatted as the glance formats, and its override.
    func testThePhonesContextIsFormattedAsTheGlance() {
        let context = WatchContext(glucose: mgdl(173), displayGlucoseUnit: .milligramsPerDeciliter, glucoseTrend: .flat,
                                   glucoseDate: now.addingTimeInterval(-60), loopLastRunDate: now.addingTimeInterval(-120),
                                   lastNetTempBasalDose: -0.4, cob: 22.6, iob: 0.04, isClosedLoop: true)
        let override = TemporaryScheduleOverride(context: .custom,
                                                 settings: TemporaryPresetSettings(unit: .milligramsPerDeciliter, targetRange: nil,
                                                                                   insulinNeedsScaleFactor: 0.7),
                                                 startDate: now.addingTimeInterval(-600), duration: .indefinite,
                                                 enactTrigger: .local, syncIdentifier: UUID())
        let s = GlanceComplicationPublisher.snapshot(phone: context, override: override)

        XCTAssertEqual(s.line(.bg, at: now), "BG 173→")
        XCTAssertEqual(s.line(.iobCob, at: now), "IOB 0.0 · COB 23")
        XCTAssertEqual(s.value(.temp, at: now), "-0.40")
        XCTAssertEqual(s.overrideLabel, "⏱ 70%")
        XCTAssertEqual(s.bgRange, .inRange, "coloured as during a loan; the icon says who holds the pod")
        XCTAssertFalse(s.watchHasPod)

        // The phone's suspend threshold sets the low line, as the glance's own rule; 180 the high one.
        let low = WatchContext(glucose: mgdl(78), displayGlucoseUnit: .milligramsPerDeciliter, glucoseTrend: .flat,
                               glucoseDate: now.addingTimeInterval(-60), loopLastRunDate: now.addingTimeInterval(-120),
                               lastNetTempBasalDose: 0, cob: 0, iob: 0, isClosedLoop: true)
        XCTAssertEqual(GlanceComplicationPublisher.snapshot(phone: low, override: nil, suspendThreshold: mgdl(80)).bgRange, .low)
        XCTAssertEqual(GlanceComplicationPublisher.snapshot(phone: low, override: nil).bgRange, .inRange, "70 when unknown")
        XCTAssertEqual(GlanceComplicationPublisher.range(mgdl: 181, suspendThreshold: nil), .high)
    }

    // MARK: - Staleness

    /// As stock's complication: a reading older than 15 min shows a dash, and so does the eventual.
    func testAStaleReadingDashesWithItsEventual() {
        let s = GlanceComplicationPublisher.snapshot(loan: glanceData(glucoseAge: 16 * 60), cob: 10,
                                                     unit: .milligramsPerDeciliter, now: now)
        XCTAssertEqual(s.line(.bgEventual, at: now), "— → —")
        XCTAssertNotNil(s.iob(at: now), "the loop's values stand on their own clock")
    }

    /// A frozen IOB on a face with no ring would be read as current; past 15 min it dashes.
    func testTheLoopsValuesDashWhenItsCycleIsOld() {
        let s = GlanceComplicationPublisher.snapshot(loan: glanceData(loopAge: 15.5 * 60), cob: 10,
                                                     unit: .milligramsPerDeciliter, now: now)
        XCTAssertEqual(s.line(.iobCob, at: now), "IOB — · COB —")
        XCTAssertEqual(s.value(.temp, at: now), "—")
        XCTAssertEqual(s.freshness(at: now), .aging)
    }

    /// Stock's HUD: an open loop always reads fresh, and its ring never schedules a change.
    func testAnOpenLoopRingReadsFresh() {
        let s = GlanceComplicationPublisher.snapshot(loan: glanceData(loopAge: 20 * 60, closed: false), cob: nil,
                                                     unit: .milligramsPerDeciliter, now: now)
        XCTAssertEqual(s.freshness(at: now), .fresh)
    }

    func testTheTimelineMarksEachChangeMoment() {
        let s = GlanceComplicationPublisher.snapshot(loan: glanceData(glucoseAge: 30, loopAge: 120), cob: 10,
                                                     unit: .milligramsPerDeciliter, now: now)
        let moments = s.changeMoments(after: now)
        XCTAssertEqual(moments.count, 4, "loop aging, loop values stale, loop stale, reading stale")
        XCTAssertEqual(s.freshness(at: moments[0]), .aging, "4 min: the ring turns")
        XCTAssertNil(s.iob(at: moments[1]), "13 min: the cycle's values dash")
        XCTAssertNotNil(s.bg(at: moments[1]))
        XCTAssertEqual(s.freshness(at: moments[2]), .stale, "14 min: the ring goes red")
        XCTAssertNil(s.bg(at: moments[3]), "14.5 min: the reading dashes")
    }

    // MARK: - Catalogue

    /// Every metric is offered in the face editor, each with its own name.
    func testEveryMetricIsRecommended() {
        let titles = GlanceMetric.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, GlanceMetric.allCases.count)
        XCTAssertEqual(GlanceMetric.allCases.count, 11)
    }

    func testTheSnapshotRoundTripsThroughDefaults() {
        let defaults = UserDefaults(suiteName: "GlanceComplicationTests")!
        defaults.removePersistentDomain(forName: "GlanceComplicationTests")
        let s = GlanceComplicationSnapshot.sample
        s.save(to: defaults)
        XCTAssertEqual(GlanceComplicationSnapshot.load(from: defaults), s)
    }

    /// The confirmation runs count what the widget served, read back by the app.
    func testServedTimelinesAreReadBackAfterADate() {
        let defaults = UserDefaults(suiteName: "GlanceComplicationServed")!
        defaults.removePersistentDomain(forName: "GlanceComplicationServed")
        GlanceComplicationSnapshot.noteServed("iob", at: now.addingTimeInterval(-120), defaults: defaults)
        GlanceComplicationSnapshot.noteServed("bg", at: now.addingTimeInterval(-30), defaults: defaults)
        let served = GlanceComplicationSnapshot.served(after: now.addingTimeInterval(-60), defaults: defaults)
        XCTAssertEqual(served.map(\.metric), ["bg"])
    }

    /// The loop's age reads in whole minutes, with a timeline mark at each, and stops counting at 30.
    func testTheLoopAgeCountsWholeMinutes() {
        let s = GlanceComplicationPublisher.snapshot(loan: glanceData(loopAge: 30), cob: 10,
                                                     unit: .milligramsPerDeciliter, now: now)
        XCTAssertEqual(s.loopAge(at: now), "now")
        XCTAssertEqual(s.loopAge(at: now.addingTimeInterval(4 * 60)), "4m")
        XCTAssertEqual(s.loopAge(at: now.addingTimeInterval(45 * 60)), "30m+")
        let marks = s.loopAgeMarks(after: now)
        XCTAssertEqual(marks.count, 30)
        XCTAssertEqual(s.loopAge(at: marks[0]), "1m")
    }

    /// A rectangle shows its value large and BG → eventual beneath, or the loop's numbers under BG.
    func testARectangleCarriesContext() {
        let s = GlanceComplicationPublisher.snapshot(loan: glanceData(), cob: 15, unit: .milligramsPerDeciliter, now: now)
        let up = GlucoseTrend.up.symbol
        XCTAssertEqual(s.headline(.iob, at: now), "2.3")
        XCTAssertEqual(s.context(.iob, at: now), "106\(up) → 112")
        XCTAssertEqual(s.headline(.bg, at: now), "106\(up)")
        XCTAssertEqual(s.headline(.bigBG, at: now), "106\(up)", "Big BG is the reading and its trend alone")
        XCTAssertEqual(s.context(.bg, at: now), "IOB 2.3 · COB 15")
    }

    /// A circle shows an override as its symbol over the rest of the label.
    func testAnOverrideSplitsForACircle() {
        var s = GlanceComplicationSnapshot()
        XCTAssertEqual(s.overrideParts.symbol, "—")
        s.overrideLabel = "🏃 70% 140"
        XCTAssertEqual(s.overrideParts.symbol, "🏃")
        XCTAssertEqual(s.overrideParts.rest, "70% 140")
        s.overrideLabel = "⏱"
        XCTAssertEqual(s.overrideParts.rest, "")
    }

    /// A reload is served within a second of the publish that asked for it: still counted.
    func testATimelineServedInTheSameSecondIsCounted() {
        let defaults = UserDefaults(suiteName: "GlanceComplicationServedSubsecond")!
        defaults.removePersistentDomain(forName: "GlanceComplicationServedSubsecond")
        let publish = Date(timeIntervalSince1970: 1_000_000.4)
        GlanceComplicationSnapshot.noteServed("bigBG", at: publish.addingTimeInterval(0.5), defaults: defaults)
        XCTAssertEqual(GlanceComplicationSnapshot.served(after: publish, defaults: defaults).map(\.metric), ["bigBG"])
    }

    /// Big BG's age counts from the reading, and goes with it once the reading dashes.
    func testTheReadingsAgeCountsFromTheReading() {
        let s = GlanceComplicationPublisher.snapshot(loan: glanceData(glucoseAge: 130), cob: 10,
                                                     unit: .milligramsPerDeciliter, now: now)
        XCTAssertEqual(s.bgAge(at: now), "2m")
        XCTAssertEqual(s.bgAge(at: now.addingTimeInterval(16 * 60)), "")
        XCTAssertEqual(s.bgAgeMarks(after: now).first, s.bgDate?.addingTimeInterval(3 * 60))
    }

    // MARK: - Redraw rule

    private func reading(_ mgdl: Double, trend: String = "→", holder: Bool = false, takenAgo: TimeInterval = 0,
                         iob: String = "1.0", at base: Date? = nil) -> GlanceComplicationSnapshot {
        var s = GlanceComplicationSnapshot()
        s.bgText = String(Int(mgdl))
        s.trendSymbol = trend
        s.bgDate = (base ?? now).addingTimeInterval(-takenAgo)
        s.bgStaleAt = s.bgDate?.addingTimeInterval(15 * 60)
        s.iobText = iob
        s.watchHasPod = holder
        return s
    }

    /// Plans a background request for a reading that linked up at `linkUp`, publishing at `at`, and records it.
    @discardableResult
    private func requestReading(_ policy: inout GlanceReloadPolicy, _ snapshot: GlanceComplicationSnapshot,
                                linkUp: Date, at: Date) -> Date? {
        _ = policy.save(snapshot)
        guard let plan = policy.plan(now: at, inFront: false, opened: false, sensorLinkUp: linkUp) else { return nil }
        policy.requested(at: plan.at, attached: GlanceReloadPolicy.attached(at: plan.at, sensorLinkUp: linkUp))
        return plan.at
    }

    /// A reading goes just after its link settles when the spacing allows.
    func testAReadingGoesWhenItsLinkSettles() {
        var policy = GlanceReloadPolicy()
        let t = requestReading(&policy, reading(100), linkUp: now, at: now.addingTimeInterval(0.4))
        XCTAssertEqual(t?.timeIntervalSince(now) ?? -1, 1.2, accuracy: 0.001)
        let next = now.addingTimeInterval(301)
        let second = requestReading(&policy, reading(104, at: next), linkUp: next, at: next.addingTimeInterval(0.5))
        XCTAssertEqual(second?.timeIntervalSince(next) ?? -1, 1.2, accuracy: 0.001, "301 s later: clear of the 300-s period")
    }

    /// A reading that comes early waits to be 300.1 s clear: inside its link if that is enough, else at the
    /// re-lodge, whose pending connect still counts as connected.
    func testAnEarlyReadingWaitsForTheSpacing() {
        var policy = GlanceReloadPolicy()
        requestReading(&policy, reading(100), linkUp: now, at: now)                         // goes at +1.2
        let early = now.addingTimeInterval(298.5)
        let second = requestReading(&policy, reading(103, at: early), linkUp: early, at: early.addingTimeInterval(0.3))
        XCTAssertEqual(second?.timeIntervalSince(early) ?? -1, 2.8, accuracy: 0.001, "300.1 s clear, still inside the link")
        let earlier = now.addingTimeInterval(1.2 + 300.1 + 296.0)
        let third = requestReading(&policy, reading(99, at: earlier), linkUp: earlier, at: earlier.addingTimeInterval(0.3))
        XCTAssertEqual(third?.timeIntervalSince(earlier) ?? -1, 35.5, accuracy: 0.001, "too early for its link: at the re-lodge")
    }

    /// A change outside this cycle's windows waits for the next reading instead of spending its slot.
    func testAChangeBetweenReadingsWaits() {
        var policy = GlanceReloadPolicy()
        requestReading(&policy, reading(100), linkUp: now, at: now)
        XCTAssertNil(requestReading(&policy, reading(100, iob: "2.0"), linkUp: now, at: now.addingTimeInterval(120)))
        XCTAssertTrue(policy.owed)
    }

    /// In front, only a reading the face hasn't drawn is requested; a current face is left alone, so opening the
    /// app doesn't spend the next reading's slot.
    func testInFrontOnlyAnUndrawnReadingIsRequested() {
        var policy = GlanceReloadPolicy()
        requestReading(&policy, reading(100), linkUp: now, at: now)
        _ = policy.save(reading(100, iob: "2.0"))
        XCTAssertNil(policy.plan(now: now.addingTimeInterval(60), inFront: true, opened: true, sensorLinkUp: now),
                     "the face shows the reading; IOB alone doesn't spend the slot")
        _ = policy.save(reading(108, at: now.addingTimeInterval(300)))
        XCTAssertEqual(policy.plan(now: now.addingTimeInterval(320), inFront: true, opened: true, sensorLinkUp: now)?.reason, "opened")
    }

    /// Only a connected request starts the daemon's period: one in front while disconnected doesn't hold the next reading.
    func testOnlyAConnectedRequestCountsTowardTheSpacing() {
        var policy = GlanceReloadPolicy()
        requestReading(&policy, reading(100), linkUp: now, at: now)
        _ = policy.save(reading(110, at: now.addingTimeInterval(10)))
        policy.requested(at: now.addingTimeInterval(10), attached: GlanceReloadPolicy.attached(at: now.addingTimeInterval(10), sensorLinkUp: now))
        let next = now.addingTimeInterval(300.5)
        let t = requestReading(&policy, reading(112, at: next), linkUp: next, at: next.addingTimeInterval(0.2))
        XCTAssertEqual(t?.timeIntervalSince(next) ?? -1, 1.2, accuracy: 0.001,
                       "the 10-s request was between the link and the re-lodge: not connected")
    }

    /// Connected by timing: the link's first seconds, and the pending connect from the re-lodge on.
    func testAttachedFollowsTheLinkAndTheReLodge() {
        XCTAssertTrue(GlanceReloadPolicy.attached(at: now.addingTimeInterval(2), sensorLinkUp: now))
        XCTAssertFalse(GlanceReloadPolicy.attached(at: now.addingTimeInterval(20), sensorLinkUp: now))
        XCTAssertTrue(GlanceReloadPolicy.attached(at: now.addingTimeInterval(36), sensorLinkUp: now))
        XCTAssertFalse(GlanceReloadPolicy.attached(at: now, sensorLinkUp: nil))
    }
}
