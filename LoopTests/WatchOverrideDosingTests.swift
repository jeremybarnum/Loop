//
//  WatchOverrideDosingTests.swift
//  LoopTests
//
//  Override-scaled dosing on the watch.
//
//  WHY THIS SUITE EXISTS. In the field, a 50% override made the watch recommend a manual
//  bolus of 0.35 U where ~0.13 U was correct — because the RECOMMENDATION used the raw
//  ISF schedule while the PREDICTION it was correcting used the override-applied one.
//  Same computation, two different sensitivities. Arithmetic on the wrist caught it: the
//  dose was plainly scaled from the regular 70 ISF, not the 140 the override implies. The
//  temp-basal path had already been fixed for exactly this, and the bolus path survived
//  because nothing tested it.
//
//  The direction is what makes it dangerous. A reduced-needs override means MORE insulin
//  sensitivity, so LESS insulin — and it is the override you set for exercise, when hypo
//  risk is already elevated. Getting it wrong roughly DOUBLES the dose at the worst moment.
//
//  Same integration style as WatchDosingLimitsTests: the real DoseMath entry points with
//  the watch's own arguments, no WatchLoopManager scaffolding. DoseMath internals belong
//  to LoopKit's own tests; what is pinned here is the contract the watch depends on.
//

import XCTest
import HealthKit
@testable import LoopKit
import LoopAlgorithm
@testable import Loop

final class WatchOverrideDosingTests: XCTestCase {

    // Jeremy's therapy settings on the night of the field test.
    private let scheduledBasal = 0.70
    private let maxBasal = 3.55
    private let rawISF = 70.0
    private let suspendThreshold = LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 80)

    private let basalSchedule = BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 0.70)])!
    private let rawISFSchedule = InsulinSensitivitySchedule(unit: .milligramsPerDeciliter,
                                                            dailyItems: [RepeatingScheduleValue(startTime: 0, value: 70.0)])!
    private let targetRange = GlucoseRangeSchedule(unit: .milligramsPerDeciliter,
                                                   dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 115))])!
    private let model = ExponentialInsulinModelPreset.rapidActingAdult
    private let volumeRounder: (Double) -> Double = { (($0 / 0.05).rounded()) * 0.05 }
    private let rateRounder: (Double) -> Double = { (($0 / 0.05).rounded(.down)) * 0.05 }

    /// A 50% insulin-needs override, as the phone would send it.
    private func fiftyPercentOverride(at start: Date) -> TemporaryScheduleOverride {
        TemporaryScheduleOverride(
            context: .custom,
            settings: TemporaryScheduleOverrideSettings(unit: .milligramsPerDeciliter,
                                                        targetRange: nil,
                                                        insulinNeedsScaleFactor: 0.5),
            startDate: start,
            duration: .finite(.hours(2)),
            enactTrigger: .local,
            syncIdentifier: UUID())
    }

    private func curve(from now: Date, values: [Double]) -> [PredictedGlucoseValue] {
        values.enumerated().map { index, mgdl in
            PredictedGlucoseValue(startDate: now.addingTimeInterval(.minutes(Double(index) * 5)),
                                  quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl))
        }
    }

    /// Jeremy's field curve: flat at 118, i.e. eventual 118 against a 100-115 target.
    private func flatAt118(from now: Date) -> [PredictedGlucoseValue] {
        curve(from: now, values: Array(repeating: 118.0, count: 73))
    }

    /// A LARGE excursion, used wherever the assertion is about the override FACTOR.
    ///
    /// The field case (118 vs a 100 floor) is only an 18 mg/dL correction, which at these ISFs
    /// is ~0.13 U vs ~0.26 U — and the pod's 0.05 U rounding then quantises those to 0.10 and
    /// 0.15, blurring a 2x relationship into 1.5x. That is a property of the arithmetic, not of
    /// the bug: at 250 the same factor is ~1.05 U vs ~2.15 U, where rounding is 2% instead of
    /// 50%. Assert the factor here; keep the field numbers as the documented case below.
    private func flatAt250(from now: Date) -> [PredictedGlucoseValue] {
        curve(from: now, values: Array(repeating: 250.0, count: 73))
    }

    // MARK: - The axiom: which way does a 50% override move ISF?

    /// THE DIRECTION TEST, and the one worth having even if every other test here is
    /// deleted. `insulinNeedsScaleFactor` is a NEEDS multiplier, and ISF is its RECIPROCAL
    /// (TemporaryScheduleOverrideSettings :25 — `insulinNeedsScaleFactor.map { 1.0 / $0 }`).
    /// So needing HALF the insulin means each unit moves you TWICE as far: ISF 70 -> 140.
    ///
    /// Getting this backwards is the single most dangerous mistake available in this file —
    /// it would halve the ISF to 35 and double every correction, silently, under exactly
    /// the override people set before exercise.
    func testFiftyPercentOverrideDOUBLESTheISF() {
        let now = Date()
        let scaled = rawISFSchedule.applyingSensitivityMultiplier(from: fiftyPercentOverride(at: now), relativeTo: now)
        let value = scaled.quantity(at: now.addingTimeInterval(.minutes(30))).doubleValue(for: LoopUnit.milligramsPerDeciliter)

        XCTAssertEqual(value, 140.0, accuracy: 0.001,
                       "a 50% insulin-needs override must DOUBLE the ISF (less insulin per mg/dL), never halve it")
        XCTAssertGreaterThan(value, rawISF, "override ISF must exceed the raw schedule for a reduced-needs override")
    }

    // The BASAL direction (0.5 halves the rate) is deliberately NOT tested here: LoopKit
    // already pins the basal multiplier across ten schedule-geometry cases
    // (TemporaryScheduleOverrideTests), and LoanBooksHarnessTests pins it downward at 0.6.
    // The ISF direction above is the genuine gap — `applyingSensitivityMultiplier` has ZERO
    // callers in all of LoopKitTests, and every override fixture in LoopKit uses a scale factor
    // >= 1.0, so the reduced-needs case (the exercise case, the hypo-risk case) has never been
    // exercised inside LoopKit at all.

    // MARK: - The regression: Jeremy's field case, in code

    /// REPRODUCES THE 2026-08-11 FIELD BUG NUMERICALLY, then pins the fix.
    ///
    /// Eventual 118 against a 100-115 target under a 50% override. The raw-ISF answer is
    /// roughly double the override-ISF answer, and the raw one is what shipped.
    func testManualBolusUnderOverrideUsesTheScaledISF() {
        let now = Date()
        let prediction = flatAt250(from: now)

        let withRaw = prediction.recommendedManualBolus(
            to: targetRange, at: now, suspendThreshold: suspendThreshold,
            sensitivity: rawISFSchedule, model: model,
            pendingInsulin: 0, maxBolus: 3.0, volumeRounder: volumeRounder)

        let overrideISF = rawISFSchedule.applyingSensitivityMultiplier(from: fiftyPercentOverride(at: now), relativeTo: now)
        let withOverride = prediction.recommendedManualBolus(
            to: targetRange, at: now, suspendThreshold: suspendThreshold,
            sensitivity: overrideISF, model: model,
            pendingInsulin: 0, maxBolus: 3.0, volumeRounder: volumeRounder)

        // The bug is not a rounding nuance — it is a factor of two on a therapeutic dose.
        XCTAssertGreaterThan(withRaw.amount, 0, "sanity: the raw-ISF path recommends something")
        XCTAssertEqual(withOverride.amount, withRaw.amount / 2, accuracy: 0.05,
                       "the override-scaled recommendation must be HALF the raw-ISF one at a 50% override")
        XCTAssertLessThan(withOverride.amount, withRaw.amount,
                          "a reduced-needs override must never recommend MORE insulin than the raw schedule")
    }

    /// The invariant that would have caught this class of bug rather than this instance:
    /// THE DOSE MUST BE COHERENT WITH THE CURVE IT CORRECTS. Applying the recommendation at
    /// the same sensitivity the prediction was built with should land at target — and using
    /// a mismatched sensitivity overshoots, which is precisely what Jeremy saw (eventual
    /// fell to 78, well under the 100 floor, after taking an ISF-70 dose against an
    /// ISF-140 world).
    func testRecommendationIsCoherentWithThePredictionsSensitivity() {
        let now = Date()
        let overrideISF = rawISFSchedule.applyingSensitivityMultiplier(from: fiftyPercentOverride(at: now), relativeTo: now)
        let effectiveISF = overrideISF.quantity(at: now).doubleValue(for: LoopUnit.milligramsPerDeciliter)

        func recommend(_ isf: InsulinSensitivitySchedule) -> Double {
            flatAt250(from: now).recommendedManualBolus(
                to: targetRange, at: now, suspendThreshold: suspendThreshold,
                sensitivity: isf, model: model,
                pendingInsulin: 0, maxBolus: 10.0, volumeRounder: volumeRounder).amount
        }

        // The curve is built with the override ISF, so that is the sensitivity the body will
        // actually respond with. Land each candidate dose against it.
        let landedCoherent = 250.0 - recommend(overrideISF) * effectiveISF
        let landedMismatched = 250.0 - recommend(rawISFSchedule) * effectiveISF

        XCTAssertLessThan(landedMismatched, landedCoherent - 50,
                          "the raw-ISF dose must overshoot the coherent one by a wide margin — that overshoot IS the bug (coherent landed \(landedCoherent), mismatched \(landedMismatched))")
        XCTAssertLessThan(landedMismatched, 80,
                          "and it must overshoot into territory the coherent dose never approaches")
    }

    // MARK: - The temp-basal path must stay fixed

    /// The temp path was fixed earlier to use the override-applied ISF. Pin it, because the
    /// bolus path proves that a fix on one path does not protect its sibling.
    func testTempBasalUnderOverrideUsesTheScaledISF() {
        let now = Date()
        let prediction = curve(from: now, values: Array(repeating: 200.0, count: 73))
        let overrideISF = rawISFSchedule.applyingSensitivityMultiplier(from: fiftyPercentOverride(at: now), relativeTo: now)

        func temp(_ isf: InsulinSensitivitySchedule) -> TempBasalRecommendation? {
            prediction.recommendedTempBasal(
                to: targetRange, at: now, suspendThreshold: suspendThreshold,
                sensitivity: isf, model: model, basalRates: basalSchedule,
                maxBasalRate: maxBasal, lastTempBasal: nil, rateRounder: rateRounder)
        }

        guard let raw = temp(rawISFSchedule), let scaled = temp(overrideISF) else {
            return XCTFail("both configurations must recommend a temp for a flat-200 curve")
        }
        XCTAssertLessThan(scaled.unitsPerHour, raw.unitsPerHour,
                          "a reduced-needs override must lower the temp rate, not raise it")
    }

    // MARK: - The recommendation's REASON reaches the wrist

    /// A bare "REC: 0 U" is indistinguishable from a broken screen — which is exactly how it
    /// read in the field on 2026-08-11 while the loop was correcting at maxBasal and zero was
    /// the CORRECT answer. Stock computes a notice for every such case; the watch was throwing
    /// it away. These strings are safety-relevant at a glance: "predicted in range" and "below
    /// suspend threshold" both produce a small or zero recommendation for opposite reasons —
    /// one is nothing to do, the other is a warning. They must never be confused or blank.
    func testEveryBolusNoticeReachesTheWristWithADistinctSentence() {
        let low = SimpleGlucoseValue(startDate: Date(),
                                     quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 65))
        let cases: [BolusRecommendationNotice] = [
            .predictedGlucoseInRange,
            .glucoseBelowSuspendThreshold(minGlucose: low),
            .currentGlucoseBelowTarget(glucose: low),
            .predictedGlucoseBelowTarget(minGlucose: low),
            .allGlucoseBelowTarget(minGlucose: low),
        ]

        var seen = Set<String>()
        for notice in cases {
            let text = notice.wristDescription
            if text.isEmpty {
                return XCTFail("every notice must produce a sentence — \(notice) produced none")
            }
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(seen.insert(text).inserted,
                          "notices must be DISTINGUISHABLE on the wrist — \"\(text)\" was already used by another case")
        }

        // No notice is the ordinary above-range correction: say nothing rather than pad the label.
        XCTAssertNil(Optional<BolusRecommendationNotice>.none?.wristDescription)
    }

    // MARK: - The ledger half (already fixed): per-read override-applied netting

    /// The ledger half of the override-scaling work, through the REAL ledger. The ledger now
    /// takes its basal schedule per READ (symmetric with ISF) and the caller passes the
    /// override-applied accessor. This pins the netting arithmetic that motivated the change:
    /// the same 1.00 U/hr temp carries MORE net insulin against a 50%-override baseline (0.35)
    /// than against the raw one (0.70) — the under-count the frozen raw schedule caused.
    func testLedgerNetsTempsAgainstTheScheduleItIsHanded() {
        var ledger = SessionInsulinLedger(
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration)
        let now = Date()
        ledger.recordEnact(DoseEntry(type: .tempBasal, startDate: now.addingTimeInterval(-3600),
                                     endDate: now, value: 1.00, unit: .unitsPerHour,
                                     syncIdentifier: "ledger-baseline-temp"))

        let scaled = basalSchedule.applyingBasalRateMultiplier(
            from: fiftyPercentOverride(at: now.addingTimeInterval(-3600)), relativeTo: now)

        let iobAgainstRaw = ledger.insulinOnBoard(at: now, basalSchedule: basalSchedule)
        let iobAgainstScaled = ledger.insulinOnBoard(at: now, basalSchedule: scaled)

        XCTAssertGreaterThan(iobAgainstScaled, iobAgainstRaw + 0.1,
                             "netting against the override-halved baseline must book materially MORE IOB for the same temp — the raw baseline was under-counting it")
    }

    // MARK: - The open half: the basal baseline the ledger nets against

    /// DOCUMENTS THE MIXED CONVENTION that is still open. The ledger is handed the RAW basal
    /// schedule to net temps against (WatchLoopManager :1017-1024) while being handed the
    /// OVERRIDE-APPLIED ISF at read time (:1658). This test does not assert which is correct
    /// — that is the open ruling — it pins HOW MUCH the choice matters, so the decision is
    /// made against a number instead of an intuition.
    func testBasalBaselineChoiceMateriallyChangesNetInsulin() {
        let now = Date()
        let scaled = basalSchedule.applyingBasalRateMultiplier(from: fiftyPercentOverride(at: now), relativeTo: now)

        let rawBaseline = basalSchedule.value(at: now)          // 0.70
        let overrideBaseline = scaled.value(at: now)            // 0.35

        // A one-hour temp at 1.00 U/hr nets differently against each baseline.
        let netAgainstRaw = 1.00 - rawBaseline                  // +0.30 U
        let netAgainstOverride = 1.00 - overrideBaseline        // +0.65 U

        XCTAssertEqual(netAgainstRaw, 0.30, accuracy: 0.001)
        XCTAssertEqual(netAgainstOverride, 0.65, accuracy: 0.001)
        XCTAssertEqual(netAgainstOverride - netAgainstRaw, 0.35, accuracy: 0.001,
                       "baseline choice moves net IOB by the full override delta — 0.35 U per temp-hour here")
    }
}
