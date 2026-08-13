//
//  ICEInvalidationTests.swift
//  LoopTests
//
//  A2: `insulinCounteractionEffects` is an append-only memo. `update(for:)` only ever extends
//  it forward from its own last endDate (the "frontier"), so a dose written into its PAST leaves
//  every bin over that window computed against an insulin-effect curve that no longer exists.
//  Those bins then credit the dose's glucose-lowering to unexplained movement, and dynamic carb
//  absorption attributes it as carbs — COB over-counts until the app relaunches and rebuilds
//  cold. Stock guards exactly one back-dated writer, `addReservoirValue`, by pruning the memo
//  back to the rewrite point; the watch hand-back is three more writers with no guard, which is
//  what made a rare stock defect routine here.
//
//  What the three tests separate:
//
//    T1  the OWNER's common case — a back-dated CARB edit. Carbs are not an input to the
//        counteraction computation, so no bin may move, and stock's own notification machinery
//        heals the attribution by itself. Pins that A2 is not needed here and must not fire.
//    T2  the FIELD SIGNATURE — a back-dated DOSE batch lands, the memo is NOT pruned, and the
//        bins over the loan window stay exactly as they were. Documents the bug; it is what
//        goes red if the prune is deleted from `finishCommit`.
//    T3  the FIX and its statelessness — after `insulinHistoryRewritten(startingAt:)` the bins
//        past the model-delay margin are regenerated and agree with a manager built COLD over
//        the same final stores, while the bins inside the margin are untouched.
//
//  Harness: the `LoopDataManagerTests` idiom — a REAL `LoopDataManager` over Mock stores that
//  compute REAL math from mutable script arrays, seeded from the `live_capture_input` fixture
//  (real glucose, real doses, real carb entries) so the numbers are the shape of a real day and
//  not a synthetic ramp. `now` is a mutable box so the clock can advance between updates.
//
//  Observables. `carbEffect` and `carbsOnBoard` are `private` on LoopDataManager, and
//  `MockCarbStore.carbsOnBoard` returns `.notConfigured`, so neither is readable — see the
//  deviation note in `carbOnlyPrediction`. The memo itself is readable through
//  `LoopState.insulinCounteractionEffects`, and `carbEffect` is readable INDIRECTLY and exactly
//  through `LoopState.predictGlucose(using: [.carbs] …)`, whose only effect input is
//  `self.carbEffect`.
//
//  Thresholds: the absolute floors below are set an order of magnitude inside the signal this
//  scenario produces (a 6 U bolus + a 20-minute 3 U/h temp against a 60 mg/dL/U sensitivity),
//  and the "did the fix work" assertions are written as RATIOS so they do not depend on that
//  estimate at all.
//

import XCTest
import HealthKit
import LoopKit
@testable import LoopCore
@testable import Loop

class ICEInvalidationTests: LoopDataManagerTests {

    // MARK: - Rig

    /// A `now` that can be advanced between updates. `LoopDataManager` takes `() -> Date` once,
    /// at init, so the clock has to live in a box the closure can read through.
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private struct Rig {
        let manager: LoopDataManager
        let doseStore: MockDoseStore
        let glucoseStore: MockGlucoseStore
        let carbStore: MockCarbStore
        let clock: Clock
    }

    /// Every rig built by a test, held for its duration: `LoopDataManager`'s notification
    /// observers capture it strongly, so nothing else here guarantees the stores outlive the
    /// updates that read them.
    private var rigs: [Rig] = []

    private var input: LoopPredictionInput!

    /// The last real glucose sample in the fixture, and the baseline `now`.
    private var t0: Date!

    private let mgdL = HKUnit.milligramsPerDeciliter
    private let mgdLPerMinute = HKUnit.milligramsPerDeciliter.unitDivided(by: HKUnit.minute())

    override func setUpWithError() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let url = try XCTUnwrap(bundle.url(forResource: "live_capture_input", withExtension: "json"))
        input = try decoder.decode(LoopPredictionInput.self, from: try Data(contentsOf: url))
        t0 = try XCTUnwrap(input.glucoseHistory.last).startDate
    }

    override func tearDownWithError() throws {
        rigs.removeAll()
        input = nil
        t0 = nil
        try super.tearDownWithError()
    }

    /// A real `LoopDataManager` over the fixture's therapy settings and the supplied stores.
    /// Deliberately the same construction as `LoopDataManagerDosingTests.testForecastFromLiveCaptureInputData`
    /// so a difference between a "cold" and a "warm" manager can only come from the sequence of
    /// calls made to it, never from how it was built.
    private func makeRig(glucose: [StoredGlucoseSample],
                         doses: [DoseEntry],
                         carbs: [StoredCarbEntry],
                         now: Date) -> Rig {
        let basalRateSchedule = BasalRateSchedule(dailyItems: [
            RepeatingScheduleValue(startTime: 0, value: input.settings.basal.first!.value)
        ])
        let insulinSensitivitySchedule = InsulinSensitivitySchedule(
            unit: .milligramsPerDeciliter,
            dailyItems: [
                RepeatingScheduleValue(startTime: 0, value: input.settings.sensitivity.first!.value.doubleValue(for: .milligramsPerDeciliter))
            ],
            timeZone: .utcTimeZone
        )!
        let carbRatioSchedule = CarbRatioSchedule(
            unit: .gram(),
            dailyItems: [
                RepeatingScheduleValue(startTime: 0.0, value: input.settings.carbRatio.first!.value)
            ],
            timeZone: .utcTimeZone
        )!

        let settings = LoopSettings(
            dosingEnabled: false,
            glucoseTargetRangeSchedule: glucoseTargetRangeSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule,
            basalRateSchedule: basalRateSchedule,
            carbRatioSchedule: carbRatioSchedule,
            maximumBasalRatePerHour: 10,
            maximumBolus: 10,
            suspendThreshold: suspendThreshold,
            automaticDosingStrategy: .automaticBolus
        )

        let glucoseStore = MockGlucoseStore()
        glucoseStore.storedGlucose = glucose

        let doseStore = MockDoseStore()
        doseStore.basalProfile = basalRateSchedule
        doseStore.basalProfileApplyingOverrideHistory = basalRateSchedule
        doseStore.sensitivitySchedule = insulinSensitivitySchedule
        doseStore.doseHistory = doses
        // Pump recency is a hard gate in predictGlucose (LoopError.pumpDataTooOld), and the
        // carb-only readout below goes through it. The scenario's premise is that the pump is
        // present and reporting — the WATCH held it, not that it went missing.
        doseStore.lastAddedPumpData = now

        let carbStore = MockCarbStore()
        carbStore.insulinSensitivityScheduleApplyingOverrideHistory = insulinSensitivitySchedule
        carbStore.carbRatioSchedule = carbRatioSchedule
        carbStore.carbRatioScheduleApplyingOverrideHistory = carbRatioSchedule
        carbStore.carbHistory = carbs

        let clock = Clock(now)
        let manager = LoopDataManager(
            lastLoopCompleted: now,
            basalDeliveryState: .active(now),
            settings: settings,
            overrideHistory: TemporaryScheduleOverrideHistory(),
            analyticsServicesManager: AnalyticsServicesManager(),
            localCacheDuration: .days(1),
            doseStore: doseStore,
            glucoseStore: glucoseStore,
            carbStore: carbStore,
            dosingDecisionStore: MockDosingDecisionStore(),
            latestStoredSettingsProvider: MockLatestStoredSettingsProvider(),
            now: { clock.now },
            pumpInsulinType: .novolog,
            automaticDosingStatus: AutomaticDosingStatus(automaticDosingEnabled: true, isAutomaticDosingAllowed: true),
            trustedTimeOffset: { 0 }
        )

        let rig = Rig(manager: manager, doseStore: doseStore, glucoseStore: glucoseStore, carbStore: carbStore, clock: clock)
        rigs.append(rig)
        return rig
    }

    // MARK: - Reading the manager

    private struct Snapshot {
        /// The memo itself.
        var ice: [GlucoseEffectVelocity]
        /// A prediction whose ONLY effect input is `carbEffect` — see `carbOnlyPrediction`.
        var carbOnly: [PredictedGlucoseValue]
    }

    /// Run one `update()` and read the state back.
    ///
    /// `getLoopState` is the production door: it drives `update(for: .getLoopState)` on the
    /// serial `dataAccessQueue`, so anything enqueued on that queue beforehand — a notification
    /// observer's invalidation, or `insulinHistoryRewritten`'s prune — is ordered ahead of it by
    /// construction, with no sleeping involved.
    @discardableResult
    private func settle(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) -> Snapshot {
        var ice: [GlucoseEffectVelocity] = []
        var carbOnly: [PredictedGlucoseValue] = []
        var predictionError: Error?

        let done = expectation(description: "getLoopState")
        rig.manager.getLoopState { _, state in
            ice = state.insulinCounteractionEffects
            do {
                carbOnly = try self.carbOnlyPrediction(state)
            } catch {
                predictionError = error
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)

        XCTAssertNil(predictionError, "the carb-only readout threw — the rig is misconfigured, not the code under test", file: file, line: line)
        XCTAssertFalse(ice.isEmpty, "the rig produced no counteraction effects at all — the fixture wiring is broken, not the code under test", file: file, line: line)
        XCTAssertFalse(carbOnly.isEmpty, "the carb-only readout is empty — carbEffect never computed", file: file, line: line)
        return Snapshot(ice: ice, carbOnly: carbOnly)
    }

    /// DEVIATION from the spec's "assert on carbEffect/COB", forced by visibility:
    /// `LoopDataManager.carbEffect` is `private` (file-visible only, so `@testable` cannot reach
    /// it) and `MockCarbStore.carbsOnBoard` returns `.notConfigured`, which leaves
    /// `LoopState.carbsOnBoard` nil in every rig. `predictGlucose(using: [.carbs] …)` with no
    /// potential entry appends exactly one effect array — `self.carbEffect` — and no momentum,
    /// no insulin and no retrospective correction, so this IS the carb effect, read through the
    /// only public door there is. Being free of the retrospective-correction object also means
    /// it cannot vary with how many updates a manager has run.
    private func carbOnlyPrediction(_ state: LoopState) throws -> [PredictedGlucoseValue] {
        try state.predictGlucose(using: [.carbs],
                                 potentialBolus: nil,
                                 potentialCarbEntry: nil,
                                 replacingCarbEntry: nil,
                                 includingPendingInsulin: false,
                                 considerPositiveVelocityAndRC: true)
    }

    /// Post a store notification and let it land before the next update is asked for.
    ///
    /// The dose observer is registered on `OperationQueue.main` (LoopDataManager :206-220), and
    /// `settle` blocks the main run loop. Draining the main queue here guarantees the observer's
    /// `dataAccessQueue.async` is enqueued FIRST; without it the next update would read
    /// pre-notification state and the test would measure nothing.
    private func postAndDeliver(_ name: Notification.Name, from object: AnyObject) {
        NotificationCenter.default.post(name: name, object: object)
        let delivered = expectation(description: "\(name.rawValue) delivered")
        OperationQueue.main.addOperation { delivered.fulfill() }
        wait(for: [delivered], timeout: 10)
    }

    // MARK: - Comparators

    private func velocity(_ v: GlucoseEffectVelocity) -> Double {
        v.quantity.doubleValue(for: mgdLPerMinute)
    }

    /// Bin-for-bin identity: same boundaries, same value. `accuracy: 0` means literally the same
    /// stored array, which is the claim T2 and T3 make about the bins the prune did not touch.
    private func assertBinsMatch(_ actual: [GlucoseEffectVelocity],
                                 _ expected: [GlucoseEffectVelocity],
                                 accuracy: Double,
                                 _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(message) — bin count", file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.startDate, e.startDate, "\(message) — bin start", file: file, line: line)
            XCTAssertEqual(a.endDate, e.endDate, "\(message) — bin end", file: file, line: line)
            XCTAssertEqual(velocity(a), velocity(e), accuracy: accuracy,
                           "\(message) — bin starting \(a.startDate)", file: file, line: line)
        }
    }

    /// Largest disagreement, in mg/dL/min, over the bins both timelines share whose start passes
    /// `over`. Matching on `startDate` rather than index so a count difference cannot silently
    /// shift the comparison.
    private func maxBinDeviation(_ a: [GlucoseEffectVelocity],
                                 _ b: [GlucoseEffectVelocity],
                                 over predicate: (Date) -> Bool = { _ in true }) -> Double {
        let rhs = Dictionary(b.map { ($0.startDate, velocity($0)) }, uniquingKeysWith: { _, last in last })
        var worst = 0.0
        var compared = 0
        for bin in a where predicate(bin.startDate) {
            guard let other = rhs[bin.startDate] else { continue }
            compared += 1
            worst = max(worst, abs(velocity(bin) - other))
        }
        return compared == 0 ? .nan : worst
    }

    /// Largest disagreement, in mg/dL, between two carb-only predictions, over their shared dates.
    private func maxPredictionDeviation(_ a: [PredictedGlucoseValue], _ b: [PredictedGlucoseValue]) -> Double {
        let rhs = Dictionary(b.map { ($0.startDate, $0.quantity.doubleValue(for: mgdL)) }, uniquingKeysWith: { _, last in last })
        var worst = 0.0
        var compared = 0
        for value in a {
            guard let other = rhs[value.startDate] else { continue }
            compared += 1
            worst = max(worst, abs(value.quantity.doubleValue(for: mgdL) - other))
        }
        return compared == 0 ? .nan : worst
    }

    // MARK: - The hand-back scenario

    /// The field shape. The phone's books stop at `loanStart` because the watch has the pod; a
    /// 20-minute temp and a meal bolus land ALL AT ONCE at `handbackAt`, entirely behind a
    /// frontier that has meanwhile advanced to `t0`.
    private struct HandbackScenario {
        let preLoanDoses: [DoseEntry]
        let loanDoses: [DoseEntry]
        let glucoseBefore: [StoredGlucoseSample]
        let glucoseAfter: [StoredGlucoseSample]
        let carbs: [StoredCarbEntry]
        /// The earliest rewritten dose start — the argument A2 passes to `insulinHistoryRewritten`.
        let loanStart: Date
        /// The instant of the hand-back, and the fresh glucose sample that advances the frontier.
        let handbackAt: Date

        /// Bins starting at or before this are KEPT by the prune: a dose cannot move glucose
        /// inside the model-delay window, so they were computed against a curve the rewrite does
        /// not change. `filterDateRange(nil, X)` drops `startDate > X`, so the boundary is closed.
        var margin: Date { loanStart.addingTimeInterval(.minutes(10)) }
    }

    private func handbackScenario() -> HandbackScenario {
        let loanStart = t0.addingTimeInterval(-.minutes(30))
        let loanEnd = t0.addingTimeInterval(-.minutes(10))
        let handbackAt = t0.addingTimeInterval(.minutes(5))

        // Everything the phone itself wrote before it lent the pod out. Cutting the fixture here
        // rather than adding doses on top of it keeps the loan window free of overlapping temps,
        // which is both what the field looks like and what makes the arithmetic legible.
        let preLoan = input.doses.filter { $0.startDate < loanStart }

        let loanTemp = DoseEntry(type: .tempBasal,
                                 startDate: loanStart,
                                 endDate: loanEnd,
                                 value: 3.0,
                                 unit: .unitsPerHour,
                                 syncIdentifier: "A2-LOAN-TEMP")
        // Placed AFTER the +10 min margin on purpose: the margin's whole claim is that a dose
        // cannot have moved glucose inside it, and a bolus sitting exactly on the boundary would
        // test the claim's edge rather than the prune. The temp still straddles the margin, so
        // the retained bins are not trivially identical to the truth either.
        let loanBolus = DoseEntry(type: .bolus,
                                  startDate: t0.addingTimeInterval(-.minutes(15)),
                                  endDate: t0.addingTimeInterval(-.minutes(13)),
                                  value: 6.0,
                                  unit: .units,
                                  syncIdentifier: "A2-LOAN-BOLUS")

        let fresh = StoredGlucoseSample(startDate: handbackAt,
                                        quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 186))

        return HandbackScenario(
            preLoanDoses: preLoan,
            loanDoses: [loanTemp, loanBolus],
            glucoseBefore: input.glucoseHistory,
            glucoseAfter: input.glucoseHistory + [fresh],
            carbs: input.carbEntries,
            loanStart: loanStart,
            handbackAt: handbackAt)
    }

    /// The commit: the doses appear in the store, one CGM reading arrives, the clock moves on,
    /// and the store notifications fire — everything the phone sees at a hand-back EXCEPT the A2
    /// prune. Note what the dose notification buys: `clearCachedInsulinEffects()` only. Nothing
    /// in stock touches the counteraction memo.
    private func landHandback(on rig: Rig, _ scenario: HandbackScenario) {
        rig.glucoseStore.storedGlucose = scenario.glucoseAfter
        rig.doseStore.doseHistory = scenario.preLoanDoses + scenario.loanDoses
        rig.doseStore.lastAddedPumpData = scenario.handbackAt
        rig.clock.now = scenario.handbackAt

        postAndDeliver(GlucoseStore.glucoseSamplesDidChange, from: rig.glucoseStore)
        postAndDeliver(DoseStore.valuesDidChange, from: rig.doseStore)
    }

    // MARK: - T1

    /// The owner's common case: a carb entry logged for 45 minutes ago.
    ///
    /// Two claims in one test. First, carbs are not an input to the counteraction computation
    /// (`getCounteractionEffects` takes glucose samples and the insulin-effect curve, nothing
    /// else), so a carb edit at ANY date must leave every retained bin exactly as it was — A2
    /// must not fire here, and if some future change makes it fire, this goes red. Second, stock
    /// already heals the attribution by itself: `carbEntriesDidChange` nils `carbEffect`, and the
    /// re-attribution is not incremental — `CarbStore.getGlucoseEffects` re-runs the whole carb
    /// set against the whole retained velocity timeline — so the result equals a cold build.
    func testBackDatedCarbEditLeavesTheMemoAloneAndHealsByItself() throws {
        let rig = makeRig(glucose: input.glucoseHistory,
                          doses: input.doses,
                          carbs: input.carbEntries,
                          now: t0)
        let before = settle(rig)

        let backDated = StoredCarbEntry(startDate: t0.addingTimeInterval(-.minutes(45)),
                                        quantity: HKQuantity(unit: .gram(), doubleValue: 35),
                                        absorptionTime: .hours(3))
        let healedCarbs = (input.carbEntries + [backDated]).sorted { $0.startDate < $1.startDate }
        rig.carbStore.carbHistory = healedCarbs
        postAndDeliver(CarbStore.carbEntriesDidChange, from: rig.carbStore)

        let after = settle(rig)

        assertBinsMatch(after.ice, before.ice, accuracy: 0,
                        "a back-dated carb edit must not move one counteraction bin")

        // The carb attribution DID change — otherwise the second half of this test is vacuous.
        let moved = maxPredictionDeviation(after.carbOnly, before.carbOnly)
        XCTAssertGreaterThan(moved, 1.0,
                             "adding 35 g at t-45m barely moved the carb effect — the scenario stopped exercising re-attribution")

        // …and it landed where a manager that had never seen the old carb set would have put it.
        let cold = makeRig(glucose: input.glucoseHistory,
                           doses: input.doses,
                           carbs: healedCarbs,
                           now: t0)
        let truth = settle(cold)

        assertBinsMatch(after.ice, truth.ice, accuracy: 1e-9,
                        "the memo a warm manager holds must equal the one a cold manager builds — carbs cannot enter it")
        XCTAssertLessThan(maxPredictionDeviation(after.carbOnly, truth.carbOnly), 1e-6,
                          "stock's own carb invalidation must reach the cold-build answer with no help from A2")
    }

    // MARK: - T2

    /// The field signature, with the fix deliberately NOT invoked.
    ///
    /// This is the bug written down. Deleting the `insulinHistoryRewritten` call from
    /// `PodLoanPhoneController.finishCommit` does not redden this test — it reddens T3. What
    /// reddens THIS one is somebody "fixing" the memo's append-only behaviour elsewhere, or the
    /// scenario ceasing to produce a back-dated rewrite at all.
    func testHandbackDosesLeaveTheMemoStaleWhenNothingPrunesIt() throws {
        let scenario = handbackScenario()
        let rig = makeRig(glucose: scenario.glucoseBefore,
                          doses: scenario.preLoanDoses,
                          carbs: scenario.carbs,
                          now: t0)
        let before = settle(rig)

        landHandback(on: rig, scenario)
        let stale = settle(rig)

        let cold = makeRig(glucose: scenario.glucoseAfter,
                           doses: scenario.preLoanDoses + scenario.loanDoses,
                           carbs: scenario.carbs,
                           now: scenario.handbackAt)
        let truth = settle(cold)

        // 1. Append-only, literally: the update added exactly the one bin the new CGM reading
        //    made possible and rewrote nothing behind it.
        XCTAssertEqual(stale.ice.count, before.ice.count + 1,
                       "the hand-back update should have appended exactly one frontier bin")
        assertBinsMatch(Array(stale.ice.prefix(before.ice.count)), before.ice, accuracy: 0,
                        "every pre-existing bin must be byte-for-byte what it was — that is the defect")

        // 2. And those bins are wrong. Over the loan window the truth disagrees, because the
        //    stale bins never had the loan's insulin subtracted from the observed rise.
        //    `frontier` is where the memo stood when the hand-back landed: everything before it
        //    is memo, everything from it on was computed fresh.
        let frontier: Date = t0
        let staleness = maxBinDeviation(stale.ice, truth.ice,
                                        over: { $0 >= scenario.loanStart && $0 < frontier })
        XCTAssertGreaterThan(staleness, 0.01,
                             "the loan window's bins should disagree with a cold build by a wide margin; got \(staleness) mg/dL/min")

        // 3. The bin computed AFTER the doses landed is fine. The defect is confined to the
        //    memo's past, which is why nothing downstream ever notices it as a fetch failure.
        let freshness = maxBinDeviation(stale.ice, truth.ice, over: { $0 >= frontier })
        XCTAssertLessThan(freshness, 1e-4,
                          "the bin computed after the hand-back must already be correct; got \(freshness) mg/dL/min")

        // 4. The consequence the field saw: carb attribution runs over the poisoned velocities.
        let carbError = maxPredictionDeviation(stale.carbOnly, truth.carbOnly)
        XCTAssertGreaterThan(carbError, 0.1,
                             "a stale memo must visibly mis-attribute carbs, or T3's heal proves nothing; got \(carbError) mg/dL")
    }

    // MARK: - T3

    /// The fix, and the property that makes it safe: pruned-and-recomputed == cold rebuild.
    ///
    /// Loop is stateless by design — the memo is a cache, and a cache is only correct if
    /// discarding part of it and refilling reaches the same answer as never having had it. That
    /// is the whole claim, and it is what lets A2 be a prune rather than a repair.
    ///
    /// Sabotage: delete the `filterDateRange` line from `insulinHistoryRewritten` and assertions
    /// 2 and 3 fail (the bins stay stale); widen the +10 min margin to hours and 2 fails; drop
    /// the `clearCachedInsulinEffects()` and the regenerated bins are rebuilt against the old
    /// insulin curve, failing 3.
    func testPruneRegeneratesTheRewrittenWindowToTheColdBuildAnswer() throws {
        let scenario = handbackScenario()
        let rig = makeRig(glucose: scenario.glucoseBefore,
                          doses: scenario.preLoanDoses,
                          carbs: scenario.carbs,
                          now: t0)
        let before = settle(rig)

        landHandback(on: rig, scenario)
        let stale = settle(rig)

        // A2. The same call `PodLoanPhoneController` makes from `finishCommit`, with the same
        // argument: the earliest start among the doses just written.
        rig.manager.insulinHistoryRewritten(startingAt: scenario.loanStart)
        let pruned = settle(rig)

        let cold = makeRig(glucose: scenario.glucoseAfter,
                           doses: scenario.preLoanDoses + scenario.loanDoses,
                           carbs: scenario.carbs,
                           now: scenario.handbackAt)
        let truth = settle(cold)

        let margin = scenario.margin
        let retained = pruned.ice.filter { $0.startDate <= margin }
        let regenerated = pruned.ice.filter { $0.startDate > margin }

        // 1. The margin was honoured in both directions: bins inside it are the untouched
        //    originals, and there are bins outside it to have regenerated.
        assertBinsMatch(retained, before.ice.filter { $0.startDate <= margin }, accuracy: 0,
                        "bins at or before the rewrite point + 10 min must survive the prune unchanged")
        XCTAssertFalse(regenerated.isEmpty,
                       "the prune dropped nothing — the scenario no longer writes behind the frontier")
        XCTAssertEqual(pruned.ice.count, stale.ice.count,
                       "regeneration must refill the memo to the same span, not leave a hole at the frontier")

        // 2. The regenerated bins actually moved…
        let movement = maxBinDeviation(pruned.ice, stale.ice, over: { $0 > margin })
        XCTAssertGreaterThan(movement, 0.01,
                             "the bins past the margin should have been rebuilt against the corrected insulin curve; got \(movement) mg/dL/min")

        // 3. …and they moved to the cold-build answer. This is the statelessness claim.
        let residual = maxBinDeviation(pruned.ice, truth.ice, over: { $0 > margin })
        XCTAssertLessThan(residual, 1e-4,
                          "a pruned-and-refilled memo must equal one built cold over the same stores; got \(residual) mg/dL/min")

        // 4. The carb attribution follows, because assigning the memo nils carbEffect. Written as
        //    a RATIO so it does not depend on an estimate of how big the poisoning is: whatever
        //    error the stale memo caused, the prune must remove essentially all of it. The
        //    remainder is the model-delay margin's own price — the retained bins still predate
        //    the loan temp — and stock pays exactly the same price on every reservoir rewrite.
        let staleCarbError = maxPredictionDeviation(stale.carbOnly, truth.carbOnly)
        let prunedCarbError = maxPredictionDeviation(pruned.carbOnly, truth.carbOnly)
        XCTAssertGreaterThan(staleCarbError, 0.1,
                             "no carb signal to heal — the scenario stopped reproducing the field defect; got \(staleCarbError) mg/dL")
        XCTAssertGreaterThan(staleCarbError, 20 * prunedCarbError,
                             "the prune must remove essentially all of the carb mis-attribution, not merely some of it (stale \(staleCarbError) mg/dL vs pruned \(prunedCarbError) mg/dL)")
    }
}
