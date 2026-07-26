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
@testable import Loop

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

    // MARK: - #49 phone→watch carb seeding: idempotent across re-takeovers

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
                if case .success(let v) = result { grams = v.quantity.doubleValue(for: .gram()) }
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

    // MARK: - Grant insulin seeding across epochs (#53)

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
        // Stock DoseStore.addDoses invokes its completion TWICE on success: once when
        // addDoseEntries lands, again after syncPumpEventsToInsulinDeliveryStore. Not our
        // bug and not worth deviating over — just don't let XCTest treat it as a violation.
        exp.assertForOverFulfill = false
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

    // MARK: - Handover fidelity (#69): the real seed path via the shared seedDoseEntries

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
                         raw: Data((dose.syncIdentifier ?? UUID().uuidString).utf8),
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

    /// #69, field-confirmed `boundaryDup=YES`: a running temp arrives in doseHistory as the
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
                          "boundaryRecord must NOT double-seed — addPumpEvents+reconciled() collapses the same-start duplicate (#69)")
        XCTAssertGreaterThan(iobWithBoundary, iobNoBoundary * 0.5,
                             "...and the temp must still count once, not vanish")
    }

    /// The takeover-fidelity invariant Jeremy asked for: IOB is conserved across takeover.
    /// The same insulin, expressed as the phone's DoseEntries vs the grant's wire records
    /// seeded on the watch, must yield the same IOB.
    func testHandoverIOBConservationAcrossTakeover() {
        let (doseStore, _) = makeStoresFixed()   // basal 1.0 U/hr
        let now = Date()
        let scheduled = HKQuantity(unit: DoseEntry.unitsPerHour, doubleValue: 1.0)
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
}
