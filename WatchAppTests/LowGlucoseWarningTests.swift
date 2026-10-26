//
//  LowGlucoseWarningTests.swift
//  WatchAppTests
//
//  The predicted-low warning's decision (a truth table over three forecasts and a set of gates), its
//  delivery, and its settings' trip through a loan. Ported from the production line's tests; the
//  decision lives in LoopCore and is the same on the phone and the watch.
//

import XCTest
import LoopKit
import LoopCore
import LoopAlgorithm
@testable import WatchApp

final class LowGlucoseWarningTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // Suspend threshold 70, day offset 5 → warning level 65.
    private func settings(enabled: Bool = true,
                          nightWarningsEnabled: Bool = true,
                          snooze: TimeInterval = 9 * 60,
                          sooner: TimeInterval = 5 * 60,
                          later: TimeInterval = 45 * 60,
                          carbDelay: TimeInterval = 30 * 60,
                          lastNotification: Date? = nil) -> LowBGWarningSettings {
        LowBGWarningSettings(enabled: enabled, nightWarningsEnabled: nightWarningsEnabled,
                             dayWarningOffset: 5, nightWarningOffset: 10,
                             warningSnooze: snooze, dontWarnIfSooner: sooner, dontWarnIfLater: later,
                             delayAfterCarbEntry: carbDelay, lastNotificationTime: lastNotification)
    }

    /// A forecast that either dives below the warning level at +20 min or stays flat at 120, anchored to
    /// `from` so a test that moves the clock moves the forecast with it.
    private func prediction(crosses: Bool, from: Date? = nil, crossingAtStep step: Int = 4) -> [PredictedGlucoseValue] {
        let anchor = from ?? t0
        return (0..<73).map { i in
            let value: Double = crosses ? (i < step ? 120 - Double(i) * (65.0 / Double(step)) : 55) : 120
            return PredictedGlucoseValue(startDate: anchor.addingTimeInterval(TimeInterval(i) * 5 * 60),
                                         quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: value))
        }
    }

    private func inputs(p1: Bool, p2: Bool, p3: Bool, settings s: LowBGWarningSettings? = nil,
                        lastCarbEntry: Date? = nil, now: Date? = nil, crossingAtStep step: Int = 4) -> LowGlucoseWarning.Inputs {
        LowGlucoseWarning.Inputs(
            predictionWithZeroTemp: prediction(crosses: p1, from: now, crossingAtStep: step),
            predictionWithObservedAbsorption: prediction(crosses: p2, from: now, crossingAtStep: step),
            predictionWithObservedAbsorptionAndZeroTemp: prediction(crosses: p3, from: now, crossingAtStep: step),
            absorptionRatio: 0.6, suspendThreshold: 70, insulinSensitivity: 50, carbRatio: 10, correctionTarget: 100,
            mostRecentCarbEntryDate: lastCarbEntry, now: now ?? t0, settings: s ?? settings())
    }

    // MARK: - The truth table

    func testEveryCellOfTheTruthTable() {
        typealias Outcome = LowGlucoseWarning.Outcome
        // Every row where P2 does not cross is `.none`, and that is structural: the P2 guard returns
        // before the table is consulted.
        let table: [(p1: Bool, p2: Bool, p3: Bool, expected: Outcome, why: String)] = [
            (true,  true,  true,  .carbsDefinitelyNeeded, "low lands even with zero temping and full absorption"),
            (true,  true,  false, .carbsDefinitelyNeeded, "privileges the first True; same aggressive warning"),
            (false, true,  true,  .rescueCarbsLikelyNeeded, "observed absorption sends you low, low temping cannot save it"),
            (false, true,  false, .mayAvoidRescueCarbsWithEditing, "observed absorption sends you low, low temping might help"),
            (true,  false, false, .none, "unreachable: the P2 guard returns before the table"),
            (true,  false, true,  .none, "unreachable: same P2 guard"),
            (false, false, true,  .none, "unreachable: same P2 guard"),
            (false, false, false, .none, "ordinary no-warning case"),
        ]
        for row in table {
            let decision = LowGlucoseWarning.evaluate(inputs(p1: row.p1, p2: row.p2, p3: row.p3))
            XCTAssertEqual(decision.outcome, row.expected, "(\(row.p1),\(row.p2),\(row.p3)) — \(row.why)")
            if row.expected == .none {
                XCTAssertNil(decision.context, "silence carries no context")
            } else {
                let context = try? XCTUnwrap(decision.context)
                XCTAssertNotNil(context.flatMap { LowGlucoseWarning.messages(for: decision.outcome, context: $0) })
            }
        }
    }

    func testTheMessagesAreHerWording() throws {
        let decision = LowGlucoseWarning.evaluate(inputs(p1: true, p2: true, p3: true))
        let message = try XCTUnwrap(LowGlucoseWarning.messages(for: decision.outcome, context: XCTUnwrap(decision.context)))
        XCTAssertEqual(message.title, "Very likely low in 20 mins")
        XCTAssertTrue(message.body.hasPrefix("Take between "))
    }

    func testNoneOutcomeReturnsNilRatherThanTrapping() {
        let empty = LowGlucoseWarning.PredictionMetrics(minimumGlucose: nil, glucoseAtAbsorptionTime: nil,
                                                        timeToMinimumGlucose: nil, timeToCrossThreshold: nil,
                                                        velocityAtThresholdCrossing: nil)
        let context = LowGlucoseWarning.Context(standardWithSuspend: empty, observedAbsorption: empty,
                                                observedAbsorptionWithSuspend: empty, rescueCarbMessageStr: nil,
                                                absorptionRatio: 1)
        XCTAssertNil(LowGlucoseWarning.messages(for: .none, context: context))
    }

    // MARK: - Gates

    func testSwitchedOffStaysSilent() {
        let decision = LowGlucoseWarning.evaluate(inputs(p1: true, p2: true, p3: true, settings: settings(enabled: false)))
        XCTAssertEqual(decision.outcome, .none)
        XCTAssertFalse(decision.lowStillPredicted, "switched off withdraws a warning showing")
    }

    func testSnoozeSuppressesASecondWarningButDoesNotWithdrawIt() {
        let suppressed = LowGlucoseWarning.evaluate(
            inputs(p1: false, p2: true, p3: true, settings: settings(lastNotification: t0.addingTimeInterval(-3 * 60))))
        XCTAssertEqual(suppressed.outcome, .none)
        XCTAssertTrue(suppressed.lowStillPredicted, "the low is still coming: the warning stays up")

        let allowed = LowGlucoseWarning.evaluate(
            inputs(p1: false, p2: true, p3: true, settings: settings(lastNotification: t0.addingTimeInterval(-10 * 60))))
        XCTAssertEqual(allowed.outcome, .rescueCarbsLikelyNeeded, "past the 9-minute snooze: re-issued with fresh numbers")
    }

    func testRecentCarbsSuppressMostVerdictsButNotTheAggressiveOne() {
        let justAte = t0.addingTimeInterval(-5 * 60)
        let softened = LowGlucoseWarning.evaluate(inputs(p1: false, p2: true, p3: true, lastCarbEntry: justAte))
        XCTAssertEqual(softened.outcome, .none, "a low already being treated should not warn")
        XCTAssertTrue(softened.lowStillPredicted)

        let aggressive = LowGlucoseWarning.evaluate(inputs(p1: true, p2: true, p3: true, lastCarbEntry: justAte))
        XCTAssertEqual(aggressive.outcome, .carbsDefinitelyNeeded, "the (T,T,*) case fires even on recent carbs")
    }

    func testALowTooFarAwayIsNotPredictedAndATooCloseOneStillIs() {
        // Crossing at step 9 of a 10-step descent = 45 minutes: not inside "don't warn if farther than" (45).
        let far = LowGlucoseWarning.evaluate(inputs(p1: false, p2: true, p3: true, crossingAtStep: 10))
        XCTAssertEqual(far.outcome, .none)
        XCTAssertFalse(far.lowStillPredicted, "beyond the window: a warning showing is withdrawn")

        // Crossing at step 1 = 5 minutes: not past "don't warn if closer than" (5), but still coming.
        let near = LowGlucoseWarning.evaluate(inputs(p1: false, p2: true, p3: true, crossingAtStep: 1))
        XCTAssertEqual(near.outcome, .none)
        XCTAssertTrue(near.lowStillPredicted, "an imminent low keeps the warning up")
    }

    func testNightWarningsHonourTheSetting() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: t0)
        comps.hour = 2; comps.minute = 0
        let night = Calendar.current.date(from: comps)!

        let off = LowGlucoseWarning.evaluate(inputs(p1: true, p2: true, p3: true, settings: settings(nightWarningsEnabled: false), now: night))
        XCTAssertEqual(off.outcome, .none, "night warnings off means silence overnight")

        let on = LowGlucoseWarning.evaluate(inputs(p1: true, p2: true, p3: true, settings: settings(nightWarningsEnabled: true), now: night))
        XCTAssertEqual(on.outcome, .carbsDefinitelyNeeded)
    }

    func testNightWindowWrapsPastMidnight() {
        let s = settings()
        func at(_ hour: Int, _ minute: Int) -> Date {
            var c = Calendar.current.dateComponents([.year, .month, .day], from: t0)
            c.hour = hour; c.minute = minute
            return Calendar.current.date(from: c)!
        }
        XCTAssertTrue(s.isNightTime(at: at(23, 0)))
        XCTAssertTrue(s.isNightTime(at: at(2, 0)))
        XCTAssertFalse(s.isNightTime(at: at(12, 0)))
        XCTAssertFalse(s.isNightTime(at: at(22, 0)), "22:00 is before the window opens")
    }

    func testMissingTherapySettingsStaySilentRatherThanGuessing() {
        let base = inputs(p1: true, p2: true, p3: true)
        let input = LowGlucoseWarning.Inputs(
            predictionWithZeroTemp: base.predictionWithZeroTemp,
            predictionWithObservedAbsorption: base.predictionWithObservedAbsorption,
            predictionWithObservedAbsorptionAndZeroTemp: base.predictionWithObservedAbsorptionAndZeroTemp,
            absorptionRatio: base.absorptionRatio, suspendThreshold: nil, insulinSensitivity: 50, carbRatio: 10,
            correctionTarget: 100, mostRecentCarbEntryDate: nil, now: t0, settings: settings())
        let decision = LowGlucoseWarning.evaluate(input)
        XCTAssertEqual(decision.outcome, .none)
        XCTAssertNil(decision.context)
    }

    func testEmptyPredictionsStaySilent() {
        let input = LowGlucoseWarning.Inputs(
            predictionWithZeroTemp: [], predictionWithObservedAbsorption: [], predictionWithObservedAbsorptionAndZeroTemp: [],
            absorptionRatio: 1, suspendThreshold: 70, insulinSensitivity: 50, carbRatio: 10, correctionTarget: 100,
            mostRecentCarbEntryDate: nil, now: t0, settings: settings())
        XCTAssertEqual(LowGlucoseWarning.evaluate(input).outcome, .none)
    }

    // MARK: - Compression-low guard (a feature, ruled 2026-10-21)

    func testACompressionDropSkipsAndASlowerFallDoesNot() {
        func readings(_ values: [Double], minutesApart: Double = 5) -> [GlucoseValue] {
            values.enumerated().map { i, v in
                SimpleGlucoseValue(startDate: t0.addingTimeInterval(Double(i) * minutesApart * 60),
                                   quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: v))
            }
        }
        XCTAssertTrue(LowGlucoseWarning.isCompressionLow(readings([120, 110])), "a 10 mg/dL one-reading drop")
        XCTAssertFalse(LowGlucoseWarning.isCompressionLow(readings([120, 111])), "9 mg/dL is a fall, not an artifact")
        XCTAssertFalse(LowGlucoseWarning.isCompressionLow(readings([120, 100], minutesApart: 10)),
                       "readings more than 6 minutes apart are not consecutive")
    }

    // MARK: - Delivery

    @MainActor
    func testDeliveryIssuesRefreshesAndWithdraws() async throws {
        let issuer = RecordingAlertIssuer()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LowGlucoseWarningTests-\(UUID())"))
        let alerter = LowGlucoseWarningAlerter(alertIssuer: issuer, defaults: defaults)

        func assessment(_ decision: LowGlucoseWarning.Decision?) -> LowGlucoseWarning.Assessment {
            LowGlucoseWarning.Assessment(decision: decision, absorptionRatio: 1, observedAbsorptionEffect: [],
                                         predictionWithZeroTemp: [], predictionWithObservedAbsorption: [],
                                         predictionWithObservedAbsorptionAndZeroTemp: [])
        }

        // "Very likely": critical, her title.
        await alerter.handle(assessment(LowGlucoseWarning.evaluate(inputs(p1: true, p2: true, p3: true))), now: t0)
        XCTAssertEqual(issuer.issued.last?.interruptionLevel, .critical)
        XCTAssertEqual(issuer.issued.last?.backgroundContent.title, "Very likely low in 20 mins")
        XCTAssertEqual(alerter.lastNotificationTime, t0)
        XCTAssertTrue(alerter.isShowing)

        // Snoozed but still predicted: nothing issued, nothing withdrawn.
        let held = LowGlucoseWarning.evaluate(inputs(p1: false, p2: true, p3: true,
                                                     settings: alerter.settingsForDecision(settings()), now: t0.addingTimeInterval(5 * 60)))
        await alerter.handle(assessment(held), now: t0.addingTimeInterval(5 * 60))
        XCTAssertEqual(issuer.issued.count, 1)
        XCTAssertTrue(issuer.retracted.isEmpty)

        // Past the snooze: re-issued with fresh numbers, time-sensitive for "likely", same identifier.
        let later = t0.addingTimeInterval(10 * 60)
        await alerter.handle(assessment(LowGlucoseWarning.evaluate(inputs(p1: false, p2: true, p3: true,
                                                                          settings: alerter.settingsForDecision(settings()), now: later))), now: later)
        XCTAssertEqual(issuer.issued.count, 2)
        XCTAssertEqual(issuer.issued.last?.interruptionLevel, .timeSensitive)
        XCTAssertEqual(issuer.issued[0].identifier, issuer.issued[1].identifier, "each replaces the last")

        // A skipped assessment (stale data, compression low) changes nothing.
        await alerter.handle(assessment(nil), now: later)
        XCTAssertTrue(issuer.retracted.isEmpty)

        // No longer predicted: withdrawn.
        await alerter.handle(assessment(LowGlucoseWarning.evaluate(inputs(p1: false, p2: false, p3: false, now: later))), now: later)
        XCTAssertEqual(issuer.retracted.count, 1)
        XCTAssertFalse(alerter.isShowing)
    }

    @MainActor
    func testStandingDownWithdrawsAWarningShowing() async throws {
        let issuer = RecordingAlertIssuer()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LowGlucoseWarningTests-\(UUID())"))
        let alerter = LowGlucoseWarningAlerter(alertIssuer: issuer, defaults: defaults)
        await alerter.standDown()
        XCTAssertTrue(issuer.retracted.isEmpty, "nothing showing, nothing to withdraw")
        await alerter.issueTest()
        await alerter.standDown()
        XCTAssertEqual(issuer.retracted.count, 1)
    }

    // MARK: - Through a loan

    func testTheSettingsAndTheSnoozeAnchorTravelBothWays() throws {
        let sent = settings(lastNotification: t0)
        var grant = LoanGrant(epoch: 1, expiresAt: t0, pumpConfiguration: Data([1]), podAddress: 0,
                              therapySettingsRaw: Data([2]), settingsTimeZoneID: "GMT", doseHistory: [])
        let plain = try JSONDecoder().decode(LoanGrant.self, from: JSONEncoder().encode(grant))
        XCTAssertNil(plain.lowBGWarningSettings, "a phone without the warning: no warning on the watch")

        grant.lowBGWarningSettings = sent
        let travelled = try JSONDecoder().decode(LoanGrant.self, from: JSONEncoder().encode(grant.withEpoch(2, leaseUntil: t0)))
        XCTAssertEqual(travelled.lowBGWarningSettings, sent, "survives a seize and the wire")

        var offer = HandbackOffer(epoch: 2, handedBackAt: t0, finalStatus: nil, odometer: nil, events: [], tombstones: [],
                                  recovered: false)
        offer.lastLowBGWarningAt = t0.addingTimeInterval(600)
        let home = try JSONDecoder().decode(HandbackOffer.self, from: JSONEncoder().encode(offer))
        XCTAssertEqual(home.lastLowBGWarningAt, t0.addingTimeInterval(600))

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LowGlucoseWarningTests-\(UUID())"))
        defaults.lowBGWarningLastNotificationTime = t0
        defaults.adoptLowBGWarningLastNotificationTime(home.lastLowBGWarningAt)
        XCTAssertEqual(defaults.lowBGWarningLastNotificationTime, t0.addingTimeInterval(600), "a later anchor is adopted")
        defaults.adoptLowBGWarningLastNotificationTime(t0)
        XCTAssertEqual(defaults.lowBGWarningLastNotificationTime, t0.addingTimeInterval(600), "an earlier one is not")
    }

    func testTheStoredSettingsReadAsHerScreenWritesThem() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LowGlucoseWarningTests-\(UUID())"))
        XCTAssertEqual(defaults.lowBGWarningSettings, LowBGWarningSettings(), "nothing stored: off, production's defaults")
        defaults.set(true, forKey: "com.loopkit.Loop.lowBGNotificationsEnabled")
        defaults.set(7, forKey: "com.loopkit.Loop.dayWarningOffset")
        defaults.set(12, forKey: "com.loopkit.Loop.warningSnooze")
        let s = defaults.lowBGWarningSettings
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.dayWarningOffset, 7)
        XCTAssertEqual(s.warningSnooze, 12 * 60)
    }
}

@MainActor
private final class RecordingAlertIssuer: AlertIssuer {
    var issued: [Alert] = []
    var retracted: [Alert.Identifier] = []
    func issueAlert(_ alert: Alert) async { issued.append(alert) }
    func retractAlert(identifier: Alert.Identifier) async { retracted.append(identifier) }
}
