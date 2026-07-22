//
//  WatchStoreEffectsTests.swift
//  LoopTests
//
//  Track B of the 2026-07-21 two-track plan (task #41): sim-side proof of the
//  watch store-configuration chain, iterated locally instead of one 20-minute
//  TestFlight cycle per guard.
//
//  The field bug: StockLoopStack.makeStores built the watch CarbStore/DoseStore
//  with no schedules and no overrideHistory, and nothing propagated the loan
//  grant's therapy settings to the stores — so carbStore.getGlucoseEffects
//  (.notConfigured) and doseStore.getGlucoseEffects (.configurationError)
//  failed on EVERY loop cycle and the watch's automatic loop never once
//  produced a dose recommendation. Build 142's instrumentation surfaced it as
//  "NOT DOSING — prediction missing carbEffect", then (after the schedule fix)
//  "missing insulinEffect" — the second wall being the overrideHistory
//  asymmetry these tests pin down.
//
//  Three tests, three states:
//   1. testUnconfiguredStoresFail_asShippedThrough143 — the original bug.
//   2. testSchedulesWithoutOverrideHistory_insulinEffectStillFails — wall #2:
//      CarbStore.getGlucoseEffects guards RAW schedules (passes), but
//      DoseStore.getGlucoseEffects guards insulinSensitivityScheduleApplying-
//      OverrideHistory, which is nil whenever overrideHistory is nil — even
//      with the schedule set. (Note basalProfileApplyingOverrideHistory has a
//      `?? basalProfile` fallback; the ISF getter does not. That one-line
//      asymmetry in LoopKit is the whole second wall.)
//   3. testGrantConfiguredStores_fullEffectChainSucceeds — stores built the
//      FIXED way (shared overrideHistory at init, schedules applied as the
//      WatchLoopManager.settings didSet does): carbEffect, insulinEffect, IOB,
//      and momentum all produce values → every missingDataError guard in
//      WatchLoopManager.updatePredictedGlucoseAndRecommendedDose clears.
//      (The recommendation math beyond the guards is stock DoseMath, already
//      covered by LoopKit's DoseMathTests.)
//

import XCTest
import HealthKit
import LoopKit
import LoopCore

final class WatchStoreEffectsTests: XCTestCase {

    private var cacheDir: URL!
    private var cacheStore: PersistenceController!

    // Fixture schedules — shapes match a real grant snapshot.
    private let basal = BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)])!
    private let isf = InsulinSensitivitySchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)])!
    private let carbRatio = CarbRatioSchedule(unit: .gram(), dailyItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)])!
    /// Production's own constant — the exact value StockLoopStack.makeStores passes.
    private let absorptionTimes = LoopCoreConstants.defaultCarbAbsorptionTimes

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cacheStore = PersistenceController(directoryURL: cacheDir)
    }

    override func tearDown() {
        cacheStore = nil
        try? FileManager.default.removeItem(at: cacheDir)
        super.tearDown()
    }

    // MARK: - Store builders

    /// The stores exactly as StockLoopStack.makeStores shipped them through
    /// build 143: schedule-less, overrideHistory-less.
    private func makeStoresAsShipped() -> (DoseStore, CarbStore) {
        let doseStore = DoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            basalProfile: nil,
            insulinSensitivitySchedule: nil,
            provenanceIdentifier: "WatchStoreEffectsTests"
        )
        let carbStore = CarbStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            cacheLength: .hours(24),
            defaultAbsorptionTimes: absorptionTimes,
            provenanceIdentifier: "WatchStoreEffectsTests"
        )
        return (doseStore, carbStore)
    }

    /// The stores the FIXED way: shared overrideHistory at construction
    /// (mirroring the phone's DeviceDataManager wiring), then schedules applied
    /// through the property setters — exactly what the WatchLoopManager.settings
    /// didSet does when the grant lands.
    private func makeStoresFixed() -> (DoseStore, CarbStore) {
        let overrideHistory = TemporaryScheduleOverrideHistory()
        let doseStore = DoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            basalProfile: nil,
            insulinSensitivitySchedule: nil,
            overrideHistory: overrideHistory,
            provenanceIdentifier: "WatchStoreEffectsTests"
        )
        let carbStore = CarbStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            cacheLength: .hours(24),
            defaultAbsorptionTimes: absorptionTimes,
            overrideHistory: overrideHistory,
            provenanceIdentifier: "WatchStoreEffectsTests"
        )
        // The didSet, verbatim.
        carbStore.carbRatioSchedule = carbRatio
        carbStore.insulinSensitivitySchedule = isf
        doseStore.insulinSensitivitySchedule = isf
        doseStore.basalProfile = basal
        return (doseStore, carbStore)
    }

    // MARK: - 1. The original bug (as shipped through 143's predecessor)

    func testUnconfiguredStoresFail_asShippedThrough143() {
        let (doseStore, carbStore) = makeStoresAsShipped()

        let carbExp = expectation(description: "carb effects")
        carbStore.getGlucoseEffects(start: Date().addingTimeInterval(-.hours(6)), end: nil, effectVelocities: []) { result in
            guard case .failure = result else {
                return XCTFail("expected .notConfigured from a schedule-less CarbStore — the field bug")
            }
            carbExp.fulfill()
        }

        let doseExp = expectation(description: "insulin effects")
        doseStore.getGlucoseEffects(start: Date().addingTimeInterval(-.hours(6))) { result in
            guard case .failure = result else {
                return XCTFail("expected .configurationError from a schedule-less DoseStore — the field bug")
            }
            doseExp.fulfill()
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - 2. Wall #2 — schedules alone are NOT enough for the DoseStore

    func testSchedulesWithoutOverrideHistory_insulinEffectStillFails() {
        let (doseStore, carbStore) = makeStoresAsShipped()
        // Apply schedules post-hoc (what the first fix did) — but overrideHistory
        // stays nil, because it is init-only on both stores.
        carbStore.carbRatioSchedule = carbRatio
        carbStore.insulinSensitivitySchedule = isf
        doseStore.insulinSensitivitySchedule = isf
        doseStore.basalProfile = basal

        // The exact getter DoseStore.getGlucoseEffects guards on:
        XCTAssertNil(doseStore.insulinSensitivityScheduleApplyingOverrideHistory,
                     "ISF-applying-override must be nil without an overrideHistory — the wall-#2 asymmetry")

        // CarbStore passes (guards raw schedules) — why carbEffect fixed first:
        let carbExp = expectation(description: "carb effects succeed")
        carbStore.getGlucoseEffects(start: Date().addingTimeInterval(-.hours(6)), end: nil, effectVelocities: []) { result in
            guard case .success = result else {
                return XCTFail("CarbStore should succeed on raw schedules without overrideHistory")
            }
            carbExp.fulfill()
        }

        // DoseStore still fails — the field's "missing insulinEffect":
        let doseExp = expectation(description: "insulin effects still fail")
        doseStore.getGlucoseEffects(start: Date().addingTimeInterval(-.hours(6))) { result in
            guard case .failure = result else {
                return XCTFail("DoseStore.getGlucoseEffects must still fail without overrideHistory — wall #2")
            }
            doseExp.fulfill()
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - 3. The full fix — every loop guard input populates

    func testGrantConfiguredStores_fullEffectChainSucceeds() {
        let (doseStore, carbStore) = makeStoresFixed()

        // The wall-#2 getter now resolves:
        XCTAssertNotNil(doseStore.insulinSensitivityScheduleApplyingOverrideHistory)

        // carbEffect populates (guard :672):
        let carbExp = expectation(description: "carb effects")
        carbStore.getGlucoseEffects(start: Date().addingTimeInterval(-.hours(6)), end: nil, effectVelocities: []) { result in
            guard case .success = result else { return XCTFail("carbEffect must populate on fixed stores") }
            carbExp.fulfill()
        }

        // insulinEffect populates (guard :673) — empty effects are valid (no doses):
        let doseExp = expectation(description: "insulin effects")
        doseStore.getGlucoseEffects(start: Date().addingTimeInterval(-.hours(6))) { result in
            guard case .success = result else { return XCTFail("insulinEffect must populate on fixed stores") }
            doseExp.fulfill()
        }

        // activeInsulin populates (guard :674):
        let iobExp = expectation(description: "IOB")
        doseStore.insulinOnBoard(at: Date()) { result in
            guard case .success = result else { return XCTFail("IOB must resolve on fixed stores") }
            iobExp.fulfill()
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - The linchpin of the pump-data-recency fix (2026-07-22)

    /// `lastAddedPumpData` is `max(lastReservoirValue?.startDate, lastPumpEventsReconciliation)`,
    /// and `addPumpEvents` assigns `lastPumpEventsReconciliation` BEFORE its
    /// `guard events.count > 0` early return. So a pod status read that yields no new
    /// doses STILL advances the loop's `pumpDataTooOld` gate.
    ///
    /// The entire `checkPumpDataAndLoop` fix depends on this: under E4 the pod is
    /// orphaned, an idle pod produces no dose events, and if a status-only read could
    /// not refresh recency the loop would stay deadlocked forever. If LoopKit ever
    /// moves that assignment below the guard, this test fails loudly instead of the
    /// watch silently refusing to dose again.
    func testEmptyPumpEventsStillRefreshesLastAddedPumpData() {
        let (doseStore, _) = makeStoresFixed()
        XCTAssertEqual(doseStore.lastAddedPumpData, .distantPast, "a fresh store has no pump data")

        let reconciliation = Date()
        let exp = expectation(description: "add empty pump events")
        doseStore.addPumpEvents([], lastReconciliation: reconciliation) { error in
            XCTAssertNil(error)
            exp.fulfill()
        }
        waitForExpectations(timeout: 10)

        XCTAssertEqual(doseStore.lastAddedPumpData.timeIntervalSince1970,
                       reconciliation.timeIntervalSince1970,
                       accuracy: 0.001,
                       "an empty event batch must still advance lastAddedPumpData — otherwise a status-only pod read can never clear pumpDataTooOld under E4")
    }

    // MARK: - momentum (guard :671) — glucose-store-only, no schedules involved

    func testMomentumEffectResolvesFromGlucoseSamples() {
        let glucoseStore = GlucoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            cacheLength: .hours(4),
            provenanceIdentifier: "WatchStoreEffectsTests"
        )
        let now = Date()
        let samples = (0..<3).map { i in
            NewGlucoseSample(
                date: now.addingTimeInterval(.minutes(Double(-10 + 5 * i))),
                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 120 + Double(i) * 3),
                condition: nil, trend: nil, trendRate: nil,
                isDisplayOnly: false, wasUserEntered: false,
                syncIdentifier: "momentum-\(i)"
            )
        }
        let addExp = expectation(description: "add samples")
        glucoseStore.addGlucoseSamples(samples) { _ in addExp.fulfill() }
        waitForExpectations(timeout: 10)

        let momentumExp = expectation(description: "momentum")
        glucoseStore.getRecentMomentumEffect { result in
            guard case .success = result else { return XCTFail("momentum must resolve from 3 fresh samples") }
            momentumExp.fulfill()
        }
        waitForExpectations(timeout: 10)
    }
}
