//  NOT YET IN THE TEST TARGET — port in progress.
//
//  Constructs the watch's stores the old way: PresetInsulinModelProvider, a DoseStore that owns
//  schedules, and a CarbStore that takes defaultAbsorptionTimes. All three moved with the
//  stateless algorithm — see StockLoopStack.makeStores for the shape it should build now.
//
//
//  WatchStoreEffectsTests.swift
//  LoopTests
//
//  Sim-side proof of the watch store-configuration chain, iterated locally
//  instead of one 20-minute TestFlight cycle per guard.
//
//  The field bug: StockLoopStack.makeStores built the watch CarbStore/DoseStore
//  with no schedules and no overrideHistory, and nothing propagated the loan
//  grant's therapy settings to the stores — so carbStore.getGlucoseEffects
//  (.notConfigured) and doseStore.getGlucoseEffects (.configurationError)
//  failed on EVERY loop cycle and the watch's automatic loop never once
//  produced a dose recommendation. Instrumentation surfaced it as
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
import LoopAlgorithm
import LoopCore
@testable import Loop

final class WatchStoreEffectsTests: XCTestCase {

    private var cacheDir: URL!
    private var cacheStore: PersistenceController!

    // Fixture schedules — shapes match a real grant snapshot.
    private let basal = BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)])!
    private let isf = InsulinSensitivitySchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)])!
    private let carbRatio = CarbRatioSchedule(unit: .gram, dailyItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)])!
    /// Production's own constant — the exact value StockLoopStack.makeStores passes.
    private let absorptionTimes = LoopCoreConstants.defaultCarbAbsorptionTimes

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cacheStore = PersistenceController(directoryURL: cacheDir)
        waitUntilStoreIsUp(cacheStore)
    }

    /// The other half of the zero-rows flake. Removing the synchronous unlink from tearDown
    /// fixed the race at the END of a test; this is the one at the START. PersistenceController
    /// attaches its persistent store ASYNCHRONOUSLY (its own readyState machine), so a test that
    /// writes and reads immediately can be served by a coordinator that has no store attached
    /// yet — and that presents as a query answering with ZERO ROWS, which is indistinguishable
    /// from a real accounting bug.
    ///
    /// Field signature this closes, measured 2026-08-13/14: an IOB delta asserted at 0.083 U
    /// returned 0.083 (green), then 0.038, then 0.000 across identical runs, and the suite's
    /// failure COUNT wandered 2 -> 4 -> 4 -> 3, which is a race rather than arithmetic. A
    /// grid-alignment theory was tried first and falsified — the phase of the query was never
    /// the problem; an empty store was.
    private func waitUntilStoreIsUp(_ store: PersistenceController,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let ready = expectation(description: "persistent store attached")
        store.onReady { error in
            XCTAssertNil(error, "store failed to come up", file: file, line: line)
            ready.fulfill()
        }
        wait(for: [ready], timeout: 10)
    }

    override func tearDown() {
        cacheStore = nil
        // Never unlink a temp store directory synchronously — PersistenceController's
        // Core Data stack comes up ASYNCHRONOUSLY, and the unlink race presents as a store that
        // answers with zero rows, in whichever suite happens to be running. The OS reclaims temp.
        cacheDir = nil
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
    /// The entire `checkPumpDataAndLoop` fix depends on this: the pod's BLE link is
    /// released between doses, an idle pod produces no dose events, and if a status-only
    /// read could not refresh recency the loop would stay deadlocked forever. If LoopKit ever
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
                       "an empty event batch must still advance lastAddedPumpData — otherwise a status-only pod read can never clear pumpDataTooOld while the pod link is released between doses")
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
                quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 120 + Double(i) * 3),
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

    // MARK: - phone→watch carb seeding: idempotent across re-takeovers

    /// The load-bearing correctness property. The watch re-ingests the grant on EVERY
    /// re-takeover (~12 epochs occurred in a single 2026-07-22 session), so seeding carbs
    /// with addCarbEntry — which mints a fresh syncIdentifier each call — would multiply COB.
    /// syncCarbObjects upserts on (syncIdentifier, provenanceIdentifier); this proves a
    /// second seed of the same carb leaves COB unchanged.
    func testSeededCarbsAreIdempotentAcrossRetakeovers() {
        let (_, carbStore) = makeStoresFixed()
        let now = Date()
        let obj = SyncCarbObject(
            absorptionTime: .hours(3), createdByCurrentApp: false, foodType: nil,
            grams: 25, startDate: now.addingTimeInterval(-.minutes(5)), uuid: nil,
            provenanceIdentifier: "com.loopkit.Loop.phone", syncIdentifier: "carb-idem-1",
            syncVersion: 1, userCreatedDate: now, userUpdatedDate: nil, userDeletedDate: nil,
            operation: .create, addedDate: nil, supercededDate: nil)

        func seed() {
            let exp = expectation(description: "sync")
            carbStore.syncCarbObjects([obj]) { error in XCTAssertNil(error); exp.fulfill() }
            waitForExpectations(timeout: 10)
        }
        func cob() -> Double {
            var grams = -1.0
            let exp = expectation(description: "cob")
            carbStore.carbsOnBoard(at: now) { result in
                if case .success(let v) = result { grams = v.quantity.doubleValue(for: .gram) }
                exp.fulfill()
            }
            waitForExpectations(timeout: 10)
            return grams
        }

        seed(); let first = cob()
        seed(); let second = cob()   // the re-takeover

        XCTAssertGreaterThan(first, 0, "a seeded carb must produce COB (the reported bug: it did not)")
        XCTAssertEqual(first, second, accuracy: 0.01, "re-seeding the SAME carb must NOT double COB")
    }

    // MARK: - Wrist carb delete on the mirror store

    // Two field failures, one release each, both authorship gates: 258 died on
    // deleteCarbEntry's method guard ("unauthorized"), 260 died on
    // cachedCarbObjectFromStoredCarbEntry's OWN guard + predicate ("noData") — seeded
    // entries are createdByCurrentApp:false / uuid:nil BY DESIGN. This test replicates the
    // production path byte-for-byte (setSyncCarbObjects seed, getCarbEntries read-back,
    // the fork delete) so the third gate, if one exists, dies HERE and not on the wrist.
    func testSeededCarbDeleteSkippingAuthorship_theTwoReleaseBug() {
        let (_, carbStore) = makeStoresFixed()
        let now = Date()
        let obj = SyncCarbObject(
            absorptionTime: .hours(3), createdByCurrentApp: false, foodType: nil,
            grams: 15, startDate: now.addingTimeInterval(-.minutes(10)), uuid: nil,
            provenanceIdentifier: "com.loopkit.Loop.phone", syncIdentifier: "carb-del-1",
            syncVersion: nil,   // the grant may carry nil — the lookup must not require it
            userCreatedDate: now, userUpdatedDate: nil, userDeletedDate: nil,
            operation: .create, addedDate: nil, supercededDate: nil)

        // Seed EXACTLY as ingestGrantCarbs does: wipe-then-replace.
        let seedExp = expectation(description: "seed")
        carbStore.setSyncCarbObjects([obj]) { error in XCTAssertNil(error); seedExp.fulfill() }
        waitForExpectations(timeout: 10)

        // Read back EXACTLY as the carb list does.
        var entry: StoredCarbEntry?
        let readExp = expectation(description: "read")
        carbStore.getCarbEntries(start: now.addingTimeInterval(-.hours(6))) { result in
            if case .success(let entries) = result { entry = entries.first }
            readExp.fulfill()
        }
        waitForExpectations(timeout: 10)
        guard let victim = entry else { return XCTFail("seeded carb did not read back") }
        XCTAssertFalse(victim.createdByCurrentApp, "precondition: the seeded entry must be foreign-authored, or this test proves nothing")
        XCTAssertNil(victim.uuid, "precondition: seeded entries carry no HK uuid")

        // The STOCK door must still refuse — pins that the fork left it unchanged.
        let stockExp = expectation(description: "stock refusal")
        carbStore.deleteCarbEntry(victim) { result in
            if case .failure(let error) = result, case .unauthorized = error {} else {
                XCTFail("stock deleteCarbEntry must still refuse foreign-authored entries, got \(result)")
            }
            stockExp.fulfill()
        }
        waitForExpectations(timeout: 10)

        // The fork door must succeed, via the syncIdentifier stage.
        let delExp = expectation(description: "fork delete")
        carbStore.deleteCarbEntrySkippingAuthorshipCheck(victim) { result, diag in
            if case .failure(let error) = result {
                XCTFail("fork delete failed (\(error)) · lookup: \(diag)")
            }
            XCTAssertTrue(diag.contains("syncId[carb-del"), "expected the syncIdentifier stage to match, got: \(diag)")
            delExp.fulfill()
        }
        waitForExpectations(timeout: 10)

        // And the store must agree it is gone — the read-back the wrist renders from.
        let goneExp = expectation(description: "gone")
        carbStore.getCarbEntries(start: now.addingTimeInterval(-.hours(6))) { result in
            if case .success(let entries) = result {
                XCTAssertTrue(entries.isEmpty, "deleted carb still reads back: \(entries)")
            }
            goneExp.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    // The watch-entered variant: no syncIdentifier reaches the wire, so the (startDate, grams)
    // stage is load-bearing. addCarbEntry mints its own identity; delete must still land.
    func testWatchEnteredCarbDelete_fallsBackToDateGrams() {
        let (_, carbStore) = makeStoresFixed()
        let now = Date()
        let addExp = expectation(description: "add")
        var added: StoredCarbEntry?
        carbStore.addCarbEntry(NewCarbEntry(quantity: LoopQuantity(unit: .gram, doubleValue: 8),
                                            startDate: now.addingTimeInterval(-.minutes(3)),
                                            foodType: nil, absorptionTime: .hours(3))) { result in
            if case .success(let stored) = result { added = stored }
            addExp.fulfill()
        }
        waitForExpectations(timeout: 10)
        guard var victim = added else { return XCTFail("add failed") }

        // Simulate the identity gap: strip the syncIdentifier the way a grant-less entry
        // presents at the reconciler (the wire carries none for watch-entered carbs).
        victim = StoredCarbEntry(startDate: victim.startDate, quantity: victim.quantity,
                                 uuid: nil, provenanceIdentifier: victim.provenanceIdentifier,
                                 syncIdentifier: nil, syncVersion: nil,
                                 foodType: victim.foodType, absorptionTime: victim.absorptionTime,
                                 createdByCurrentApp: false,
                                 userCreatedDate: victim.userCreatedDate, userUpdatedDate: nil)

        let delExp = expectation(description: "delete by date+grams")
        carbStore.deleteCarbEntrySkippingAuthorshipCheck(victim) { result, diag in
            if case .failure(let error) = result {
                XCTFail("date+grams delete failed (\(error)) · lookup: \(diag)")
            }
            XCTAssertTrue(diag.contains("date+grams"), "expected the fallback stage, got: \(diag)")
            delExp.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    // MARK: - Grant insulin seeding across epochs

    // The insulin analog of the carb test above, and the regression guard for the
    // worst bug of 2026-07-22. Carb seeding is idempotent because it reuses the
    // phone's own syncIdentifiers; the insulin seed mints EPOCH-KEYED ones
    // ("loanv2-grant-<epoch>-<index>"), so a new epoch re-inserted the same 16 h of
    // history as brand-new entries. Three takeovers in one day put IOB at 7.40 U
    // against <= ~2.5 U physically deliverable, and the automatic-dosing clamp
    // (2 x maxBolus) then refused every high temp at eventual 256 — the loop looked
    // broken when the books were.
    //
    // The fix is wipe-then-seed in ingestGrantHistory: the grant IS ground truth at
    // takeover, so rebuild from it rather than accumulate onto it. These two tests
    // pin both halves — that the naive re-seed really does double (so nobody
    // "simplifies" the wipe away), and that wipe-then-seed holds steady.

    /// One 30-min temp basal above schedule, keyed to an epoch exactly as
    /// PodLoanWatchController.ingestGrantHistory mints them.
    private func grantDoses(epoch: Int, now: Date) -> [DoseEntry] {
        [DoseEntry(type: .tempBasal,
                   startDate: now.addingTimeInterval(-.minutes(25)),
                   endDate: now.addingTimeInterval(-.minutes(5)),
                   value: 3.45,
                   unit: .unitsPerHour,
                   syncIdentifier: "loanv2-grant-\(epoch)-0")]
    }

    private func addDoses(_ doses: [DoseEntry], to doseStore: DoseStore) {
        let exp = expectation(description: "addDoses")
        // Fixed contract: completion fires exactly once.
        doseStore.addDoses(doses, from: nil) { error in
            XCTAssertNil(error)
            exp.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    private func iob(_ doseStore: DoseStore, at date: Date) -> Double {
        var value = -1.0
        let exp = expectation(description: "iob")
        doseStore.insulinOnBoard(at: date) { result in
            if case .success(let v) = result { value = v.value }
            exp.fulfill()
        }
        waitForExpectations(timeout: 10)
        return value
    }

    /// THE BUG: epoch-keyed identifiers mean a re-takeover is NOT deduped, so the
    /// same delivered insulin lands twice and IOB inflates.
    func testEpochKeyedInsulinReSeedDoublesIOB_theBugBehindTheClamp() {
        let (doseStore, _) = makeStoresFixed()
        let now = Date()

        addDoses(grantDoses(epoch: 57, now: now), to: doseStore)
        let afterFirstGrant = iob(doseStore, at: now)

        addDoses(grantDoses(epoch: 58, now: now), to: doseStore)   // the re-takeover
        let afterSecondGrant = iob(doseStore, at: now)

        XCTAssertGreaterThan(afterFirstGrant, 0, "a seeded temp basal must produce IOB")
        XCTAssertGreaterThan(afterSecondGrant, afterFirstGrant * 1.5,
                             "epoch-keyed re-seed double-counts — this is why the wipe exists")
    }

    /// THE FIX: wipe both tables, then seed from the grant. Idempotent by
    /// construction, whatever the epoch.
    func testWipeThenSeedKeepsIOBStableAcrossEpochs() {
        let (doseStore, _) = makeStoresFixed()
        let now = Date()

        func wipeThenSeed(epoch: Int) {
            let wiped = expectation(description: "wipe")
            doseStore.deleteAllPumpEvents { _ in
                doseStore.insulinDeliveryStore.purgeCachedInsulinDeliveryObjects(before: nil) { _ in
                    wiped.fulfill()
                }
            }
            waitForExpectations(timeout: 10)
            addDoses(grantDoses(epoch: epoch, now: now), to: doseStore)
        }

        wipeThenSeed(epoch: 57); let firstTakeover = iob(doseStore, at: now)
        wipeThenSeed(epoch: 58); let secondTakeover = iob(doseStore, at: now)
        wipeThenSeed(epoch: 59); let thirdTakeover = iob(doseStore, at: now)

        XCTAssertGreaterThan(firstTakeover, 0, "the rebuilt books must still carry the grant's insulin")
        XCTAssertEqual(firstTakeover, secondTakeover, accuracy: 0.01,
                       "wipe-then-seed must be idempotent across a re-takeover")
        XCTAssertEqual(firstTakeover, thirdTakeover, accuracy: 0.01,
                       "...and across three, the count that produced 7.40 U in the field")
    }

    // MARK: - Handover fidelity: the real seed path via the shared seedDoseEntries

    /// A minimal grant carrying the given records (the fields seedDoseEntries reads).
    private func makeGrant(epoch: Int, doseHistory: [LoanDoseRecord], boundary: LoanDoseRecord?) -> LoanGrant {
        LoanGrant(epoch: epoch, expiresAt: Date().addingTimeInterval(.minutes(5)),
                  pumpManagerRawState: Data(), podAddress: 0,
                  therapySettingsRaw: Data(), settingsTimeZoneID: TimeZone.current.identifier,
                  doseHistory: doseHistory, boundaryRecord: boundary)
    }

    /// Seed exactly as production `ingestGrantHistory` now does: shared `seedDoseEntries`
    /// (record→DoseEntry, freezing scheduledBasalRate from the grant schedule) →
    /// NewPumpEvents → `addPumpEvents` (so stock reconciled() collapses overlaps).
    private func seedViaAddPumpEvents(_ grant: LoanGrant, into doseStore: DoseStore) {
        let entries = grant.seedDoseEntries()
        let events = entries.map { dose in
            NewPumpEvent(date: dose.startDate, dose: dose,
                         raw: LoanSeedIdentity.raw(forSyncIdentifier: dose.syncIdentifier ?? UUID().uuidString),
                         title: "Temp Basal")
        }
        let exp = expectation(description: "seed addPumpEvents")
        exp.assertForOverFulfill = false
        doseStore.addPumpEvents(events, lastReconciliation: Date(), replacePendingEvents: true) { error in
            XCTAssertNil(error)
            exp.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    private func wipe(_ doseStore: DoseStore) {
        let exp = expectation(description: "wipe")
        doseStore.deleteAllPumpEvents { _ in
            doseStore.insulinDeliveryStore.purgeCachedInsulinDeliveryObjects(before: nil) { _ in exp.fulfill() }
        }
        waitForExpectations(timeout: 10)
    }

    /// Field-confirmed `boundaryDup=YES`: a running temp arrives in doseHistory as the
    /// open temp AND (older phones) as a same-start boundaryRecord. Seeding via addPumpEvents
    /// runs stock reconciled(), which collapses the same-start overlap to ONE dose, so the
    /// boundary does not inflate IOB — the pre-fix `addDoses` side door summed them (the
    /// ~0.3 U takeover bump). Guards Fix 1 (phone stops sending it) + Fix 2 (seed reconciles).
    func testHandoverBoundaryDoesNotDoubleSeedIOB() {
        let (doseStore, _) = makeStoresFixed()   // basal 1.0 U/hr
        let now = Date()
        let runningTemp = LoanDoseRecord(kind: .tempBasal,
                                         startDate: now.addingTimeInterval(-.minutes(25)),
                                         endDate: now.addingTimeInterval(.minutes(5)),   // open past takeover
                                         unitsPerHour: 3.0)
        let boundary = LoanDoseRecord(kind: .boundaryTruncation,
                                      startDate: now.addingTimeInterval(-.minutes(25)),   // SAME start & rate
                                      endDate: now,
                                      unitsPerHour: 3.0)

        seedViaAddPumpEvents(makeGrant(epoch: 1, doseHistory: [runningTemp], boundary: nil),
                             into: doseStore)
        let iobNoBoundary = iob(doseStore, at: now)

        wipe(doseStore)
        seedViaAddPumpEvents(makeGrant(epoch: 2, doseHistory: [runningTemp], boundary: boundary),
                             into: doseStore)
        let iobWithBoundary = iob(doseStore, at: now)

        XCTAssertGreaterThan(iobNoBoundary, 0, "the seeded running temp must produce IOB")
        // reconciled() collapses the same-start pair to ONE dose; which endDate survives is
        // nondeterministic (the boundary's truncated window or the open temp's), so IOB lands
        // near — not exactly at — the single-temp value. The point is it is NOT ~2x (the field
        // double-seed). A naive double would be ≈1.8x; bound it well under that, and above zero.
        XCTAssertLessThan(iobWithBoundary, iobNoBoundary * 1.4,
                          "boundaryRecord must NOT double-seed — addPumpEvents+reconciled() collapses the same-start duplicate")
        XCTAssertGreaterThan(iobWithBoundary, iobNoBoundary * 0.5,
                             "...and the temp must still count once, not vanish")
    }

    /// The takeover-fidelity invariant Jeremy asked for: IOB is conserved across takeover.
    /// The same insulin, expressed as the phone's DoseEntries vs the grant's wire records
    /// seeded on the watch, must yield the same IOB.
    func testHandoverIOBConservationAcrossTakeover() {
        let (doseStore, _) = makeStoresFixed()   // basal 1.0 U/hr
        let now = Date()
        let scheduled = LoopQuantity(unit: DoseEntry.unitsPerHour, doubleValue: 1.0)
        let phoneDoses: [DoseEntry] = [
            DoseEntry(type: .bolus, startDate: now.addingTimeInterval(-.minutes(30)),
                      endDate: now.addingTimeInterval(-.minutes(30)), value: 2.0, unit: .units,
                      syncIdentifier: "phone-bolus"),
            DoseEntry(type: .tempBasal, startDate: now.addingTimeInterval(-.minutes(20)),
                      endDate: now.addingTimeInterval(-.minutes(5)), value: 2.5, unit: .unitsPerHour,
                      syncIdentifier: "phone-temp", scheduledBasalRate: scheduled),
        ]
        addDoses(phoneDoses, to: doseStore)
        let phoneIOB = iob(doseStore, at: now)

        wipe(doseStore)
        let grant = makeGrant(epoch: 1, doseHistory: [
            LoanDoseRecord(kind: .bolus, startDate: now.addingTimeInterval(-.minutes(30)), amount: 2.0),
            LoanDoseRecord(kind: .tempBasal, startDate: now.addingTimeInterval(-.minutes(20)),
                           endDate: now.addingTimeInterval(-.minutes(5)), unitsPerHour: 2.5),
        ], boundary: nil)
        seedViaAddPumpEvents(grant, into: doseStore)
        let watchIOB = iob(doseStore, at: now)

        XCTAssertGreaterThan(phoneIOB, 0, "sanity: the phone books carry IOB")
        XCTAssertEqual(watchIOB, phoneIOB, accuracy: 0.05,
                       "IOB must be conserved across takeover — the watch seed reproduces the phone's IOB")
    }

    /// The watch nets seeded temps against its `basalProfile`, which is FROZEN to the grant
    /// schedule for the loan — that (not a per-dose stamped rate) is what yields correct
    /// delivery-time netting. Established empirically here: the addPumpEvents/pump-event path
    /// does NOT persist a dose's scheduledBasalRate; LoopKit re-derives it from the profile at
    /// read. So this pins net (delivery-time) IOB, and documents that a profile change re-nets —
    /// which is exactly why the watch freezes the profile, and why the phone-side
    /// retroactive-netting fix (profile CAN change mid-loan there) is a separate open task.
    func testSeededTempNetsAgainstFrozenGrantSchedule() {
        let (doseStore, _) = makeStoresFixed()   // basalProfile = 1.0 U/hr (the frozen grant schedule)
        let now = Date()
        // 3.0 U/hr for 15 min, ending 5 min ago. Net above the 1.0 schedule = 2.0 U/hr → 0.5 U.
        let temp = LoanDoseRecord(kind: .tempBasal, startDate: now.addingTimeInterval(-.minutes(20)),
                                  endDate: now.addingTimeInterval(-.minutes(5)), unitsPerHour: 3.0)
        seedViaAddPumpEvents(makeGrant(epoch: 1, doseHistory: [temp], boundary: nil), into: doseStore)

        let iobNet = iob(doseStore, at: now)
        // GROSS would be 3.0*0.25 = 0.75 U; asserting ~0.5 proves it netted against the schedule.
        XCTAssertEqual(iobNet, 0.5, accuracy: 0.06,
                       "seeded temp must net against the frozen grant schedule (delivery-time netting), not count gross")

        // Mechanism: netting rides the (re-derived) profile on the pump-event path, so changing
        // it re-nets — which is precisely why the watch freezes the profile for the whole loan.
        doseStore.basalProfile = BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 2.5)])!
        let iobAfterProfileChange = iob(doseStore, at: now)
        XCTAssertNotEqual(iobNet, iobAfterProfileChange, accuracy: 0.1,
                          "netting rides the current profile on the pump-event path — the watch's frozen profile keeps it stable")
    }

    // MARK: - Double-hex fix: seed identity must round-trip to the pod-native raw

    /// Counts distinct bolus doses visible to IOB (the same delivery-store ∪ pump-event dedup
    /// union `insulinOnBoard` reads, over a fixed 6 h window).
    private func bolusCount(_ doseStore: DoseStore, around now: Date) -> Int {
        var count = -1
        let exp = expectation(description: "normalized dose read")
        doseStore.getNormalizedDoseEntries(start: now.addingTimeInterval(-.hours(6)), end: now) { result in
            if case .success(let doses) = result { count = doses.filter { $0.type == .bolus }.count }
            exp.fulfill()
        }
        waitForExpectations(timeout: 10)
        return count
    }

    /// The field bug (epoch 47, build 179): a bolus finishing seconds before takeover rides the
    /// grant's podState un-pruned; the watch's rebuilt pump manager re-reports it at the first
    /// status read under its deterministic pod-native raw (OmniBLE `UnfinalizedDose.uniqueKey`).
    /// The phone's syncIdentifier IS hex(raw) of that same key, so a seed that hex-DECODES the
    /// syncId collides with the re-report on the PumpEvent raw uniqueness constraint → ONE dose.
    func testSeedIdentityDedupsPodNativeReReport() {
        let (doseStore, _) = makeStoresFixed()
        let now = Date()
        let start = now.addingTimeInterval(-.minutes(30))
        // Identity exactly as OmniBLE builds it: raw = utf8("bolus <units> <ISO8601 start>").
        let podRaw = Data("bolus 1.15 2026-07-28T21:41:30Z".utf8)
        let phoneSyncId = podRaw.map { String(format: "%02hhx", $0) }.joined()   // == raw.hexadecimalString

        XCTAssertEqual(LoanSeedIdentity.raw(forSyncIdentifier: phoneSyncId), podRaw,
                       "seed raw must hex-decode the phone syncId back to the pod-native bytes")

        // 1) The grant seed, as production encodes it.
        let seededDose = DoseEntry(type: .bolus, startDate: start, endDate: start.addingTimeInterval(46),
                                   value: 1.15, unit: .units, syncIdentifier: phoneSyncId)
        let seedEvent = NewPumpEvent(date: start, dose: seededDose,
                                     raw: LoanSeedIdentity.raw(forSyncIdentifier: phoneSyncId), title: "Bolus")
        let seedExp = expectation(description: "seed")
        doseStore.addPumpEvents([seedEvent], lastReconciliation: now.addingTimeInterval(-60), replacePendingEvents: true) { error in
            XCTAssertNil(error); seedExp.fulfill()
        }
        waitForExpectations(timeout: 10)
        XCTAssertEqual(bolusCount(doseStore, around: now), 1)

        // 2) The pod re-report: same physical dose, pod-native raw (no syncIdentifier on the dose —
        //    PumpEvent derives it from raw, exactly as OmniBLE's NewPumpEvent(UnfinalizedDose) does).
        let reReported = DoseEntry(type: .bolus, startDate: start, endDate: start.addingTimeInterval(46),
                                   value: 1.15, unit: .units)
        let podEvent = NewPumpEvent(date: start, dose: reReported, raw: podRaw, title: "Bolus")
        let reportExp = expectation(description: "pod re-report")
        doseStore.addPumpEvents([podEvent], lastReconciliation: now, replacePendingEvents: true) { error in
            XCTAssertNil(error); reportExp.fulfill()
        }
        waitForExpectations(timeout: 10)

        XCTAssertEqual(bolusCount(doseStore, around: now), 1,
                       "the pod's re-report of a seeded dose must land on the SAME row — two rows is the +1.15U cycle-1 IOB echo (epoch 47)")
    }

    /// Sensitivity control — the PRE-fix shape: seeding raw = utf8(hexString) (hex-of-hex identity)
    /// lets the pod-native re-report create a second row. If LoopKit's dedup semantics ever change
    /// so the main test would pass vacuously, this control fails and flags the assumption.
    func testDoubleHexSeedIdentityDuplicates_preFixRegressionShape() {
        let (doseStore, _) = makeStoresFixed()
        let now = Date()
        let start = now.addingTimeInterval(-.minutes(30))
        let podRaw = Data("bolus 1.15 2026-07-28T21:41:30Z".utf8)
        let phoneSyncId = podRaw.map { String(format: "%02hhx", $0) }.joined()

        let seededDose = DoseEntry(type: .bolus, startDate: start, endDate: start.addingTimeInterval(46),
                                   value: 1.15, unit: .units, syncIdentifier: phoneSyncId)
        // The bug: utf8 bytes OF THE HEX STRING (identity becomes hex-of-hex).
        let buggySeedEvent = NewPumpEvent(date: start, dose: seededDose, raw: Data(phoneSyncId.utf8), title: "Bolus")
        let seedExp = expectation(description: "buggy seed")
        doseStore.addPumpEvents([buggySeedEvent], lastReconciliation: now.addingTimeInterval(-60), replacePendingEvents: true) { error in
            XCTAssertNil(error); seedExp.fulfill()
        }
        waitForExpectations(timeout: 10)

        let reReported = DoseEntry(type: .bolus, startDate: start, endDate: start.addingTimeInterval(46),
                                   value: 1.15, unit: .units)
        let podEvent = NewPumpEvent(date: start, dose: reReported, raw: podRaw, title: "Bolus")
        let reportExp = expectation(description: "pod re-report")
        doseStore.addPumpEvents([podEvent], lastReconciliation: now, replacePendingEvents: true) { error in
            XCTAssertNil(error); reportExp.fulfill()
        }
        waitForExpectations(timeout: 10)

        XCTAssertEqual(bolusCount(doseStore, around: now), 2,
                       "hex-of-hex seeding must double-count — this control proves the main test is sensitive to the bug it guards")
    }

    /// The SECOND guaranteed field shape (adversarial-review finding): the inherited RUNNING temp
    /// re-reports as a MUTABLE full-span dose under the same raw on every status read. The seeded
    /// row is the immutable Fix-2-trimmed version and must win: replacePendingEvents' mutable-only
    /// purge must not delete it, and the mutable re-report must lose on the raw uniqueness
    /// constraint (store-trump merge). The full-span future tail must NOT resurrect into IOB.
    func testMutableTempReReportLosesToSeededTrimmedRow() {
        let (doseStore, _) = makeStoresFixed()   // basal 1.0 U/hr
        let now = Date()
        let start = now.addingTimeInterval(-.minutes(20))
        let trimEnd = now.addingTimeInterval(-.minutes(10))
        let podRaw = Data("tempBasal 3.0 2026-07-28T21:38:02Z".utf8)   // uniqueKey shape; cancel-stable
        let phoneSyncId = podRaw.map { String(format: "%02hhx", $0) }.joined()

        // Seed: the Fix-2-trimmed immutable temp [start, trimEnd] @ 3.0 U/hr.
        let trimmed = DoseEntry(type: .tempBasal, startDate: start, endDate: trimEnd,
                                value: 3.0, unit: .unitsPerHour, syncIdentifier: phoneSyncId)
        let seedExp = expectation(description: "seed trimmed temp")
        doseStore.addPumpEvents([NewPumpEvent(date: start, dose: trimmed,
                                              raw: LoanSeedIdentity.raw(forSyncIdentifier: phoneSyncId),
                                              title: "Temp Basal")],
                                lastReconciliation: trimEnd, replacePendingEvents: true) { error in
            XCTAssertNil(error); seedExp.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Pod re-report: the same temp as the pod still sees it — MUTABLE, full programmed span
        // (ends 10 min in the FUTURE), same raw.
        let mutableFullSpan = DoseEntry(type: .tempBasal, startDate: start,
                                        endDate: start.addingTimeInterval(.minutes(30)),
                                        value: 3.0, unit: .unitsPerHour, isMutable: true)
        let reportExp = expectation(description: "mutable re-report")
        doseStore.addPumpEvents([NewPumpEvent(date: start, dose: mutableFullSpan, raw: podRaw, title: "Temp Basal")],
                                lastReconciliation: now, replacePendingEvents: true) { error in
            XCTAssertNil(error); reportExp.fulfill()
        }
        waitForExpectations(timeout: 10)

        var temps: [DoseEntry] = []
        let readExp = expectation(description: "normalized read")
        doseStore.getNormalizedDoseEntries(start: now.addingTimeInterval(-.hours(6)), end: now.addingTimeInterval(.hours(1))) { result in
            if case .success(let doses) = result { temps = doses.filter { $0.type == .tempBasal } }
            readExp.fulfill()
        }
        waitForExpectations(timeout: 10)

        XCTAssertEqual(temps.count, 1, "one identity → one temp; the mutable re-report must collapse onto the seeded row")
        XCTAssertEqual(temps.first?.endDate.timeIntervalSince1970 ?? 0, trimEnd.timeIntervalSince1970, accuracy: 1.0,
                       "the seeded trimmed endDate must survive — a full-span resurrection re-inflates IOB with the undelivered tail")
        XCTAssertEqual(temps.first?.isMutable, false, "the surviving row is the immutable seeded version")
    }

    // MARK: - SessionInsulinLedger — the single-owner timeline

    private func flatSchedule(_ rate: Double = 1.0) -> BasalRateSchedule {
        BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: rate)])!
    }
    private func makeLedger(basalRate: Double = 1.0) -> SessionInsulinLedger {
        SessionInsulinLedger(
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration)
    }

    /// THE STOCK-MATH GUARANTEE: identical finished doses into the DoseStore (via the seed
    /// path) and into the ledger must produce the same IOB — the ledger changes STORAGE,
    /// never math. (Small tolerance: DoseStore.insulinOnBoard picks the max of the two
    /// 5-min-grid values adjacent to the query date; the ledger evaluates at the date.)
    func testLedgerMatchesDoseStoreIOB() {
        let (doseStore, _) = makeStoresFixed()   // basal 1.0 U/hr
        let now = Date()
        let doses = [
            DoseEntry(type: .tempBasal, startDate: now.addingTimeInterval(-.minutes(90)),
                      endDate: now.addingTimeInterval(-.minutes(60)), value: 3.0, unit: .unitsPerHour,
                      syncIdentifier: "aa01"),
            DoseEntry(type: .bolus, startDate: now.addingTimeInterval(-.minutes(45)),
                      endDate: now.addingTimeInterval(-.minutes(44)), value: 1.5, unit: .units,
                      syncIdentifier: "aa02"),
            DoseEntry(type: .tempBasal, startDate: now.addingTimeInterval(-.minutes(30)),
                      endDate: now.addingTimeInterval(-.minutes(10)), value: 0.0, unit: .unitsPerHour,
                      syncIdentifier: "aa03"),
        ]
        let events = doses.map { dose in
            NewPumpEvent(date: dose.startDate, dose: dose,
                         raw: LoanSeedIdentity.raw(forSyncIdentifier: dose.syncIdentifier!),
                         title: "seed")
        }
        let exp = expectation(description: "store seed")
        doseStore.addPumpEvents(events, lastReconciliation: now, replacePendingEvents: false) { error in
            XCTAssertNil(error); exp.fulfill()
        }
        waitForExpectations(timeout: 10)
        let storeIOB = iob(doseStore, at: now)

        var ledger = makeLedger()
        ledger.seed(finished: doses, live: [])
        let ledgerIOB = ledger.insulinOnBoard(at: now, basalSchedule: flatSchedule())

        XCTAssertEqual(ledgerIOB, storeIOB, accuracy: 0.03,
                       "same doses, same math — the ledger replaces storage, not InsulinMath")
    }

    /// The single coherence rule: an enact truncates the open predecessor at its start —
    /// the same supersede fold the hand-back journal applies on the phone.
    func testLedgerSupersedeTruncation() {
        var ledger = makeLedger()
        let now = Date()
        let t1Start = now.addingTimeInterval(-.minutes(20))
        ledger.recordEnact(DoseEntry(type: .tempBasal, startDate: t1Start,
                                     endDate: t1Start.addingTimeInterval(.minutes(30)),
                                     value: 3.0, unit: .unitsPerHour))
        let t2Start = now.addingTimeInterval(-.minutes(10))
        ledger.recordEnact(DoseEntry(type: .tempBasal, startDate: t2Start,
                                     endDate: t2Start.addingTimeInterval(.minutes(30)),
                                     value: 2.0, unit: .unitsPerHour))

        XCTAssertEqual(ledger.doses.count, 2)
        XCTAssertEqual(ledger.doses[0].endDate.timeIntervalSince1970, t2Start.timeIntervalSince1970, accuracy: 0.001,
                       "predecessor truncated at the successor's start")
        // Net delivered: 3.0 for 10 min (net 2.0/hr → 0.333) + 2.0 running 10 min (net 1.0/hr →
        // 0.167 delivered-so-far) ≈ 0.5, PLUS the running temp's ~10-min model-delay lookahead
        // (stock counts not-yet-acting insulin at 100% remaining: ≈ +0.167) minus early decay —
        // the same delivered-plus-lookahead semantics as the phone's own mutable row.
        let iobNow = ledger.insulinOnBoard(at: now, basalSchedule: flatSchedule())
        XCTAssertEqual(iobNow, 0.67, accuracy: 0.15, "delivered-so-far + delay lookahead, decayed")
    }

    /// Jeremy's 0.50→0.57 example, ledger-native: a live (inherited) temp seeded full-span
    /// tracks its delivery in real time — no re-arm, no mutability machinery.
    func testLedgerLiveTempTracksDelivery() {
        var ledger = makeLedger()   // schedule 1.0
        let start = Date().addingTimeInterval(-.minutes(10))
        ledger.seed(finished: [], live: [
            DoseEntry(type: .tempBasal, startDate: start,
                      endDate: start.addingTimeInterval(.minutes(30)),
                      value: 2.0, unit: .unitsPerHour)   // net +1.0 U/hr
        ])
        let iobAt5 = ledger.insulinOnBoard(at: start.addingTimeInterval(.minutes(5)), basalSchedule: flatSchedule())
        let iobAt10 = ledger.insulinOnBoard(at: start.addingTimeInterval(.minutes(10)), basalSchedule: flatSchedule())
        XCTAssertGreaterThan(iobAt10, iobAt5, "IOB grows while the live temp delivers")
        XCTAssertEqual(iobAt10 - iobAt5, 0.083, accuracy: 0.04,
                       "~0.08 U per 5 min of a +1.0 U/hr net temp — reality-tracking by construction")
    }

    // MARK: - A pod-owned live temp must make IOB TRACK delivery in real time

    /// Jeremy's reference example: schedule 1.0 U/hr, a 2.0 U/hr temp running at
    /// takeover → net +1.0 U/hr → IOB must GROW ~0.08 U per 5 min (minus early decay) while the
    /// temp runs. SCOPE (adversarial-review correction): this test pins the STORE half —
    /// GIVEN a mutable full-span row, stock IOB math (delivery integrated only to eval-time +
    /// model delay, InsulinMath's continuousDeliveryInsulinOnBoard loop bound) yields
    /// delivered-so-far + a constant ~delay lookahead, so the delta between two instants is pure
    /// delivery tracking. The MANAGER half — that the watch's pump manager actually supplies the
    /// mutable row for an inherited temp (it arrives C5-cancelled in the grant blob and must be
    /// re-armed) — is pinned separately in OmniTests (testPodLoanRearm*); this test injects the
    /// row by hand and cannot certify that layer.
    func testPodOwnedMutableTempTracksDeliveryInIOB() {
        let (doseStore, _) = makeStoresFixed()   // schedule 1.0 U/hr
        let now = Date()
        let start = now.addingTimeInterval(-.minutes(10))
        // The pod manager's report: mutable, full programmed span, pod-native raw. No seeded row.
        let running = DoseEntry(type: .tempBasal, startDate: start,
                                endDate: start.addingTimeInterval(.minutes(30)),
                                value: 2.0, unit: .unitsPerHour, isMutable: true)
        let exp = expectation(description: "pod report")
        doseStore.addPumpEvents([NewPumpEvent(date: start, dose: running,
                                              raw: Data("tempBasal 2.0 2026-07-28T22:00:00Z".utf8),
                                              title: "Temp Basal")],
                                lastReconciliation: now, replacePendingEvents: true) { error in
            XCTAssertNil(error); exp.fulfill()
        }
        waitForExpectations(timeout: 10)

        let iobAt5  = iob(doseStore, at: start.addingTimeInterval(.minutes(5)))
        let iobAt10 = iob(doseStore, at: start.addingTimeInterval(.minutes(10)))

        XCTAssertGreaterThan(iobAt10, iobAt5, "IOB must grow while the pod-owned temp delivers")
        // Net delivery between the two instants = 1.0 U/hr × 5 min ≈ 0.083 U, minus a sliver of
        // early decay. This is the 0.50 → 0.57 behavior: reality-tracking, not frozen-at-takeover.
        XCTAssertEqual(iobAt10 - iobAt5, 0.083, accuracy: 0.04,
                       "the IOB delta over 5 min of a +1.0 U/hr net temp must be ~0.08 U")
    }
}
