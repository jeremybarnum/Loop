//
//  LoanBooksHarnessTests.swift
//  LoopTests
//
//  A scripted "session replay" harness for the watch loan insulin books, built from the
//  2026-07-29 field incidents. The loan session keeps TWO books: the real Core Data
//  DoseStore (multi-writer, mutable-dose lifecycle, raw-identity dedup) and the
//  SessionInsulinLedger (#73/#74, single-owner [DoseEntry] timeline, SHADOW MODE). Every
//  field incident so far has been a coherence failure BETWEEN writers or ACROSS the
//  handover seam — never in InsulinMath itself. So the harness replays one scripted
//  session against BOTH books at once and pins the seams:
//
//   1. testInheritedTempSpanBooksOnBothSides — the inherited running temp, healthy shape
//      (full-span in both books → parity) AND the dead-re-arm bug shape (store frozen at
//      the C5-truncated seed record → divergence grows at exactly the schedule rate).
//   2. testDuplicateBolusTwinDetection — the zero-length journal bolus + pod-native twin
//      pair double-booking ~0.95 U of phantom IOB, in the store AND (documented, not
//      blessed) in the ledger.
//   3. testHandbackSeamCloses — the 21:16 → 21:21 hand-back seam must be fully explained
//      by decay + the zero-temp's withheld basal; when the rows match, nothing leaks.
//   4. testReGrantRoundTripPreservesBooks — seed → enact chain → hand-back fold →
//      re-grant reseed must conserve IOB across the epoch boundary (cross-epoch fidelity).
//
//  Conventions copied from WatchStoreEffectsTests: PersistenceController-per-store temp
//  dirs, the fixed-store construction (shared TemporaryScheduleOverrideHistory at init,
//  schedules via the property setters), seeds through addPumpEvents so stock reconciled()
//  runs, and the #69 identity contract (syncId == hex(raw); LoanSeedIdentity hex-DECODES
//  the phone syncId back to the pod-native bytes). Basal here is 0.70 U/hr FLAT — the
//  field profile behind every number below — not the 1.0 of the older fixtures.
//
//  Determinism: DoseStore's cacheLength (24 h) and purge logic need doses near wall-clock
//  now, so each test derives EVERY instant from a single `let now = Date()` — offsets are
//  fixed, so the arithmetic is deterministic run-to-run even though the absolute dates
//  float. No bare Date() appears anywhere else.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

// MARK: - File fixtures

/// The field basal schedule: 0.70 U/hr flat. The dead-re-arm divergence (test 1b) grows
/// at exactly this rate, and the hand-back seam (test 3) withholds exactly this rate —
/// keeping the fixture equal to the field profile keeps the pinned deltas literal.
private let fieldBasalRate = 0.70

private let iso8601 = ISO8601DateFormatter()

/// Pod-native identity, OmniBLE's `UnfinalizedDose.uniqueKey` shape:
/// raw = utf8("\(doseType) \(units-or-rate) \(ISO8601 start)") — deterministic and
/// cancel-stable (UnfinalizedDose.swift:54). The exact number formatting need not match
/// OmniBLE byte-for-byte here; what the tests rely on is the dose-identity CONTRACT:
/// the phone's stored syncIdentifier IS hex(raw), and LoanSeedIdentity.raw(forSyncIdentifier:)
/// hex-decodes it back to these same bytes.
private func podRaw(type: String, value: Double, start: Date) -> Data {
    return Data("\(type) \(value) \(iso8601.string(from: start))".utf8)
}

private func hexString(_ data: Data) -> String {
    return data.map { String(format: "%02hhx", $0) }.joined()
}

// MARK: - The driver

/// Scripted session-replay driver: one loan session run against BOTH books at once.
///
/// Store side: a real DoseStore fed through `addPumpEvents`, playing the pod's report
/// lifecycle exactly as OmniBLE does — the running temp is re-asserted MUTABLE full-span
/// in every report batch (replacePendingEvents purges and the batch re-asserts), then
/// finalized on supersede/hand-back as the SAME raw with the truncated span, immutable.
/// Grant seeds run the REAL split (`LoanGrant.seedDoseEntries(finishedBy:)`) and land via
/// `addPumpEvents(lastReconciliation:replacePendingEvents: false)` under hex-decoded raws.
///
/// Ledger side: `seed(finished:live:)` at takeover, `recordEnact` at each pod accept —
/// the same two hooks WatchLoopManager's shadow mode calls.
private final class LoanBooksDriver {

    let store: DoseStore
    private(set) var ledger: SessionInsulinLedger

    private unowned let host: XCTestCase

    /// The pod's current unfinalized temp — OmniBLE's UnfinalizedDose, in miniature.
    private struct RunningTemp {
        let raw: Data
        let rate: Double
        let start: Date
        let programmedEnd: Date
    }
    private var runningTemp: RunningTemp?

    /// Hand-back-shaped records accumulated as the session finalizes doses (temps
    /// truncated at supersede, same raws, syncIdentifier = hex(raw) — the identity
    /// contract). `handbackFold` returns seedRecords + these as the next grant.
    private var foldedSession: [LoanDoseRecord] = []
    private var seedRecords: [LoanDoseRecord] = []

    init(host: XCTestCase, cacheStore: PersistenceController, basalRate: Double) {
        self.host = host
        // Fixture construction (force-unwraps allowed here, per file convention).
        let schedule = BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: basalRate)])!
        let overrideHistory = TemporaryScheduleOverrideHistory()
        let doseStore = DoseStore(
            healthKitSampleStore: nil,
            cacheStore: cacheStore,
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            basalProfile: nil,
            insulinSensitivitySchedule: nil,
            overrideHistory: overrideHistory,
            provenanceIdentifier: "LoanBooksHarnessTests")
        // The WatchLoopManager.settings didSet path: schedule applied via the setter.
        doseStore.basalProfile = schedule
        self.store = doseStore
        self.ledger = SessionInsulinLedger(
            basalSchedule: schedule,
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration)
    }

    // MARK: Script steps

    /// seed(grant records): runs the REAL grant split. Finished history lands in the
    /// store under hex-decoded pod-native raws (#69); a live dose is NOT seeded (#72) —
    /// the driver plays the pod and reports it MUTABLE full-span. The ledger takes the
    /// identical split through `seed(finished:live:)`.
    func seed(_ records: [LoanDoseRecord], at instant: Date, epoch: Int = 1) {
        seedRecords = records
        let grant = LoanGrant(epoch: epoch, expiresAt: instant.addingTimeInterval(.minutes(5)),
                              pumpManagerRawState: Data(), podAddress: 0,
                              therapySettingsRaw: Data(), settingsTimeZoneID: TimeZone.current.identifier,
                              doseHistory: records, boundaryRecord: nil)
        let split = grant.seedDoseEntries(finishedBy: instant)

        let events = split.seed.map { dose in
            NewPumpEvent(date: dose.startDate, dose: dose,
                         raw: LoanSeedIdentity.raw(forSyncIdentifier: dose.syncIdentifier ?? UUID().uuidString),
                         title: "Loan Seed")
        }
        if !events.isEmpty {
            addToStore(events, lastReconciliation: instant, replacePendingEvents: false)
        }

        for dose in split.live where dose.type == .tempBasal {
            let temp = RunningTemp(
                raw: LoanSeedIdentity.raw(forSyncIdentifier: dose.syncIdentifier ?? UUID().uuidString),
                rate: dose.unitsPerHour, start: dose.startDate, programmedEnd: dose.endDate)
            runningTemp = temp
            addToStore([mutableEvent(for: temp)], lastReconciliation: instant, replacePendingEvents: true)
        }

        ledger.seed(finished: split.seed, live: split.live)
    }

    /// A pod-ACCEPTED temp: the report batch carries the superseded predecessor finalized
    /// (same raw, truncated at this accept, immutable) plus the new temp mutable full-span.
    /// The ledger takes the enact full-span and applies its own supersede truncation.
    func enactTemp(rate: Double, at instant: Date, duration: TimeInterval) {
        var batch: [NewPumpEvent] = []
        if let final = finalizeRunningTemp(at: instant) {
            batch.append(final)
        }
        let temp = RunningTemp(raw: podRaw(type: "tempBasal", value: rate, start: instant),
                               rate: rate, start: instant,
                               programmedEnd: instant.addingTimeInterval(duration))
        runningTemp = temp
        batch.append(mutableEvent(for: temp))
        addToStore(batch, lastReconciliation: instant, replacePendingEvents: true)

        ledger.recordEnact(DoseEntry(type: .tempBasal, startDate: instant,
                                     endDate: instant.addingTimeInterval(duration),
                                     value: rate, unit: .unitsPerHour))
    }

    /// A pod-ACCEPTED bolus, booked finalized on the next report (typical small bolus:
    /// ~38 s span). The running temp's mutable row is re-asserted in the same batch —
    /// replacePendingEvents purges mutable rows raw-blind, and OmniBLE survives that only
    /// because every report re-asserts the whole unfinalized set.
    func enactBolus(units: Double, at instant: Date, span: TimeInterval = 38) {
        let raw = podRaw(type: "bolus", value: units, start: instant)
        let dose = DoseEntry(type: .bolus, startDate: instant,
                             endDate: instant.addingTimeInterval(span),
                             value: units, unit: .units)
        var batch = [NewPumpEvent(date: instant, dose: dose, raw: raw, title: "Bolus")]
        if let temp = runningTemp {
            batch.append(mutableEvent(for: temp))
        }
        // lastReconciliation covers the bolus span: an IMMUTABLE dose must not end after
        // the reconciliation watermark (DoseStore.addPumpEvents' commented-out fatalError
        // documents that contract).
        addToStore(batch, lastReconciliation: instant.addingTimeInterval(span), replacePendingEvents: true)

        foldedSession.append(LoanDoseRecord(kind: .bolus, startDate: instant,
                                            endDate: instant.addingTimeInterval(span),
                                            amount: units, syncIdentifier: hexString(raw)))
        ledger.recordEnact(dose)
    }

    /// Sample both books. A pure read — replay order matters: tick BEFORE a later enact
    /// lands if the script wants the pre-enact view (the store is one Core Data table;
    /// once a row is in, every evaluation sees it).
    func tick(at instant: Date) -> (store: Double, ledger: Double) {
        return (storeIOB(at: instant), ledger.insulinOnBoard(at: instant))
    }

    /// Hand-back: cancel/finalize the running temp at `instant` (same raw, truncated
    /// span, immutable — the pod's own finalization shape) and emit the next grant's
    /// doseHistory: the original seed records plus every session dose in hand-back shape.
    /// The ledger is deliberately NOT truncated here — shadow mode has no hand-back hook;
    /// scripts that compare ledger1 post-fold arrange the last temp to expire naturally.
    func handbackFold(at instant: Date) -> [LoanDoseRecord] {
        if let final = finalizeRunningTemp(at: instant) {
            addToStore([final], lastReconciliation: instant, replacePendingEvents: true)
        }
        return seedRecords + foldedSession
    }

    // MARK: Low-level primitives (for scripting broken shapes)

    /// A finished/truncated row straight into the STORE only — test 1(b)'s known-wrong
    /// dead-re-arm shape (C5 record seeded, pod never re-reported).
    func storeFinished(_ dose: DoseEntry, raw: Data, lastReconciliation: Date) {
        addToStore([NewPumpEvent(date: dose.startDate, dose: dose, raw: raw, title: "Temp Basal")],
                   lastReconciliation: lastReconciliation, replacePendingEvents: false)
    }

    func ledgerSeed(finished: [DoseEntry], live: [DoseEntry]) {
        ledger.seed(finished: finished, live: live)
    }

    func storeBolusCount(start: Date, end: Date) -> Int {
        var count = -1
        let exp = host.expectation(description: "normalized dose read")
        store.getNormalizedDoseEntries(start: start, end: end) { result in
            if case .success(let doses) = result {
                count = doses.filter { $0.type == .bolus }.count
            }
            exp.fulfill()
        }
        host.wait(for: [exp], timeout: 10)
        return count
    }

    func storeIOB(at date: Date) -> Double {
        var value = Double.nan
        let exp = host.expectation(description: "insulinOnBoard")
        store.insulinOnBoard(at: date) { result in
            if case .success(let v) = result {
                value = v.value
            }
            exp.fulfill()
        }
        host.wait(for: [exp], timeout: 10)
        XCTAssertFalse(value.isNaN, "insulinOnBoard must resolve")
        return value
    }

    // MARK: Internals

    /// The pod's view of the running temp: MUTABLE, full programmed span, identity from
    /// raw only (no syncIdentifier on the dose — PumpEvent derives it from raw, exactly
    /// as OmniBLE's NewPumpEvent(UnfinalizedDose) does).
    private func mutableEvent(for temp: RunningTemp) -> NewPumpEvent {
        let dose = DoseEntry(type: .tempBasal, startDate: temp.start, endDate: temp.programmedEnd,
                             value: temp.rate, unit: .unitsPerHour, isMutable: true)
        return NewPumpEvent(date: temp.start, dose: dose, raw: temp.raw, title: "Temp Basal")
    }

    /// Finalization: same raw, span truncated to min(instant, programmed end) — a
    /// supersede truncates, a natural expiry keeps the full span — immutable. Also
    /// appends the hand-back-shaped record (syncIdentifier = hex(raw)).
    private func finalizeRunningTemp(at instant: Date) -> NewPumpEvent? {
        guard let temp = runningTemp else { return nil }
        let end = min(instant, temp.programmedEnd)
        let dose = DoseEntry(type: .tempBasal, startDate: temp.start, endDate: end,
                             value: temp.rate, unit: .unitsPerHour)
        foldedSession.append(LoanDoseRecord(kind: .tempBasal, startDate: temp.start, endDate: end,
                                            unitsPerHour: temp.rate,
                                            syncIdentifier: hexString(temp.raw)))
        runningTemp = nil
        return NewPumpEvent(date: temp.start, dose: dose, raw: temp.raw, title: "Temp Basal")
    }

    private func addToStore(_ events: [NewPumpEvent], lastReconciliation: Date, replacePendingEvents: Bool) {
        let exp = host.expectation(description: "addPumpEvents")
        // Defensive, same as WatchStoreEffectsTests: some DoseStore paths double-invoke
        // completions; not our bug and not worth failing over.
        exp.assertForOverFulfill = false
        store.addPumpEvents(events, lastReconciliation: lastReconciliation,
                            replacePendingEvents: replacePendingEvents) { error in
            XCTAssertNil(error)
            exp.fulfill()
        }
        host.wait(for: [exp], timeout: 10)
    }
}

// MARK: - The tests

final class LoanBooksHarnessTests: XCTestCase {

    /// One isolated PersistenceController per driver — two DoseStores must never share a
    /// Core Data table (test 3 and 4 run a watch store and a phone store side by side).
    private var cacheDirs: [URL] = []

    override func tearDown() {
        for dir in cacheDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        cacheDirs = []
        super.tearDown()
    }

    private func makeDriver() -> LoanBooksDriver {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cacheDirs.append(dir)
        return LoanBooksDriver(host: self,
                               cacheStore: PersistenceController(directoryURL: dir),
                               basalRate: fieldBasalRate)
    }

    // MARK: - 1. The inherited running temp — both spans, both books

    /// FIELD (2026-07-29, dead-re-arm incident): at takeover the watch inherited the
    /// phone's RUNNING 0.00 U/hr temp — started 7 min before the seed, 30 min programmed,
    /// schedule 0.70 U/hr. The C5-truncated record (ends at the handover stamp) landed in
    /// the store, but the re-arm was dead: the pod never re-reported the still-running
    /// temp, so the store's books froze at the seed instant while the pod kept WITHHOLDING
    /// 0.70 U/hr of basal. Store IOB drifted high versus reality at exactly the schedule
    /// rate — the signature this test pins as a regression canary.
    ///
    /// (a) is the healthy shape: full-span in BOTH books (store mutable via the pod's
    /// re-report, ledger live via the grant split) — stock eval-time bounding makes both
    /// track the temp's delivery identically, so they must agree.
    /// (b) is the bug shape: store gets the truncated-finalized twin, ledger keeps the
    /// full-span truth → the divergence must GROW at ≈ 0.70 U/hr × Δt. The store side is
    /// the KNOWN-WRONG book here; the assertion pins the failure signature, not health.
    func testInheritedTempSpanBooksOnBothSides() {
        let now = Date()
        let t0 = now.addingTimeInterval(-.minutes(20))                    // seed instant
        let tempStart = t0.addingTimeInterval(-.minutes(7))               // field geometry
        let tempEnd = tempStart.addingTimeInterval(.minutes(30))
        let raw = podRaw(type: "tempBasal", value: 0.0, start: tempStart)

        // (a) HEALTHY: the grant split classifies the temp live (endDate > seed instant);
        // the driver plays the pod's mutable full-span re-report; the ledger seeds live.
        let healthy = makeDriver()
        healthy.seed([LoanDoseRecord(kind: .tempBasal, startDate: tempStart, endDate: tempEnd,
                                     unitsPerHour: 0.0, syncIdentifier: hexString(raw))],
                     at: t0)
        for offset in [0.0, 5.0, 15.0] {
            let sample = healthy.tick(at: t0.addingTimeInterval(.minutes(offset)))
            XCTAssertEqual(sample.store, sample.ledger, accuracy: 0.05,
                           "full-span in both books must agree at +\(Int(offset)) min — same rows, same stock math")
        }

        // (b) THE BUG SHAPE: store gets the truncated twin ONLY (dead re-arm — no pod
        // re-report ever arrives); ledger gets the full-span truth.
        let broken = makeDriver()
        broken.storeFinished(DoseEntry(type: .tempBasal, startDate: tempStart, endDate: t0,
                                       value: 0.0, unit: .unitsPerHour),
                             raw: raw, lastReconciliation: t0)
        broken.ledgerSeed(finished: [],
                          live: [DoseEntry(type: .tempBasal, startDate: tempStart, endDate: tempEnd,
                                           value: 0.0, unit: .unitsPerHour)])

        let at5 = broken.tick(at: t0.addingTimeInterval(.minutes(5)))
        let at15 = broken.tick(at: t0.addingTimeInterval(.minutes(15)))
        let d5 = at5.store - at5.ledger     // store (frozen) minus ledger (tracking) — positive
        let d15 = at15.store - at15.ledger

        XCTAssertGreaterThan(d5, 0.05,
                             "the frozen store must already overstate IOB 5 min after the seed")
        XCTAssertGreaterThan(d15, d5,
                             "the divergence must GROW while the dead temp keeps withholding basal")
        // Grid-phase-dependent growth (measured 0.058 AND 0.116 on consecutive runs): the
        // model-delay bound floor((time+delay)/delta)*delta quantizes on the 5-min grid
        // relative to WALL CLOCK, so the +5→+15 divergence growth is one OR two grid
        // steps of withheld basal depending on where `now` fell — 0.70 × (5..10)/60.
        // Both are the field signature (linear phase Δ+0.16→+0.22, then the +0.22→+0.27
        // plateau, 2026-07-29). Pin the RANGE, not a point.
        XCTAssertGreaterThan(d15 - d5, fieldBasalRate * (5.0 / 60.0) - 0.03,
                             "dead-re-arm signature: at least one grid step of withheld basal must accrue")
        XCTAssertLessThan(d15 - d5, fieldBasalRate * (10.0 / 60.0) + 0.03,
                          "growth must cap at the linear rate — more means a book defect beyond the canary")
    }

    // MARK: - 2. The bolus twin pair

    /// FIELD (2026-07-29): the grant carried the same physical 0.95 U bolus TWICE — once
    /// as the phone journal's zero-length row (start == end; LoanReconciler writes
    /// endDate ?? startDate, so a journal event with nil endDate mints exactly this) and
    /// once as the pod-native row (start +1 s, 38 s delivery span, different raw). Two
    /// identities → every dedup layer blind → the seed booked BOTH → ~+0.95 U of phantom
    /// IOB the moment the watch took over.
    func testDuplicateBolusTwinDetection() {
        let now = Date()
        let b = now.addingTimeInterval(-.minutes(5))

        // The journal twin: zero-length, journal-minted identity (non-hex → raw = utf8).
        let journalTwin = LoanDoseRecord(kind: .bolus, startDate: b, endDate: b, amount: 0.95,
                                         syncIdentifier: "loanv2-6D0F2A44-8E4C-4B1B-9A57-2F30E1C0AB12")
        // The pod-native twin: same units, start +1 s, 38 s span, pod-native identity.
        let podStart = b.addingTimeInterval(1)
        let podTwinRaw = podRaw(type: "bolus", value: 0.95, start: podStart)
        let podTwin = LoanDoseRecord(kind: .bolus, startDate: podStart,
                                     endDate: podStart.addingTimeInterval(38), amount: 0.95,
                                     syncIdentifier: hexString(podTwinRaw))

        let driver = makeDriver()
        driver.seed([journalTwin, podTwin], at: now)

        // STORE: two raws → two rows → double books. This is the bug being pinned.
        XCTAssertEqual(driver.storeBolusCount(start: now.addingTimeInterval(-.hours(6)), end: now), 2,
                       "distinct identities blind every store dedup layer — both twins land as rows")
        let sample = driver.tick(at: now)
        XCTAssertEqual(sample.store, 1.90, accuracy: 0.1,
                       "the store books BOTH twins: ~2 × 0.95 U of IOB for one physical bolus (+0.95 U phantom, field 2026-07-29)")

        // LEDGER: the seed's bolus-twin guard (#74 cutover, 2026-07-29) collapses
        // same-units (±0.01U) same-instant (±2s) bolus twins, keeping the longer span
        // (pod-actual timing) — one physical bolus books ONCE.
        XCTAssertEqual(sample.ledger, 0.95, accuracy: 0.1,
                       "the ledger's seed twin-guard must collapse the pair to one 0.95 U bolus")
    }

    // MARK: - 3. The hand-back seam

    /// FIELD (2026-07-29, 21:16 → 21:21): watch books at 21:16 held a 0.95 U bolus 31 min
    /// old plus the recent temp chain (high temp superseded by a zero temp — the decomp
    /// shape below reconstructs the DOSING-panel numbers). At 21:16 the watch enacted
    /// 0.00 U/hr × 30 min; at ~21:20:18 (+4.3 min) the hand-back cancelled/truncated it;
    /// at ~21:21 (+4.5 min) the phone evaluated its freshly-seeded books.
    ///
    /// The pin: the watch-at-21:16 vs phone-at-21:21 IOB seam must be FULLY explained by
    /// (decay over the window) + (the zero temp's withheld basal, 0.70 U/hr × 4.3 min ≈
    /// 0.050 U) — within 0.1 U, with NO forward terms. Canon: prediction trims at now;
    /// the only forward window in counted IOB is the model delay, and it cancels when the
    /// rows match on both sides.
    func testHandbackSeamCloses() {
        let now = Date()
        let t = now.addingTimeInterval(-.minutes(20))         // plays the field 21:16
        let handback = t.addingTimeInterval(.minutes(4.3))    // 21:20:18 — cancel/truncate
        let phoneEval = t.addingTimeInterval(.minutes(4.5))   // 21:21 — first phone sample

        let watch = makeDriver()
        // Build the 21:16 books via the session's own enacts. 0.95 U at t−31 min is the
        // field number; the temp chain (2.80 superseded by 0.00, expiring t−4 min) is the
        // field decomp's recent high-then-zero shape against the 0.70 schedule.
        watch.enactBolus(units: 0.95, at: t.addingTimeInterval(-.minutes(31)))
        watch.enactTemp(rate: 2.80, at: t.addingTimeInterval(-.minutes(26)), duration: .minutes(30))
        watch.enactTemp(rate: 0.00, at: t.addingTimeInterval(-.minutes(16)), duration: .minutes(12))

        // PRE-ENACT samples — replay order is load-bearing: both are pure reads taken
        // BEFORE the 21:16 enact lands, so preT is the watch's true pre-enact IOB and
        // preT45 is pure decay of the same books (no zero-temp term in either).
        let preT = watch.tick(at: t).store
        let preT45 = watch.tick(at: phoneEval).store

        // 21:16: enact 0.00 × 30 min. 21:20:18: hand back — the pod finalizes the temp
        // truncated [t, t+4.3], same raw, immutable.
        watch.enactTemp(rate: 0.00, at: t, duration: .minutes(30))
        let finalRecords = watch.handbackFold(at: handback)

        // Phone side: a FRESH store seeded from the truncated final records (the real
        // grant split again — hex syncIds decode back to the very same pod raws).
        let phone = makeDriver()
        phone.seed(finalRecords, at: phoneEval, epoch: 2)
        let phoneT45 = phone.tick(at: phoneEval).store
        let watchT45 = watch.tick(at: phoneEval).store

        // The explainable seam: decay + the zero temp's actually-withheld basal.
        let decay = preT - preT45
        let zeroTempWithheld = fieldBasalRate * (4.3 / 60.0)   // ≈ 0.050 U never delivered
        let seam = preT - phoneT45
        XCTAssertEqual(seam, decay + zeroTempWithheld, accuracy: 0.1,
                       "the 21:16→21:21 seam must be decay + zero-temp withholding and NOTHING else — any residual is booked insulin leaking across the hand-back")

        // And when the rows match, the seam closes exactly: same records, same instant,
        // both sides all-immutable and past-ended → the model-delay window cancels.
        XCTAssertEqual(watchT45, phoneT45, accuracy: 0.05,
                       "identical final rows on both sides must produce identical IOB — the seam has no store-of-origin term")
    }

    // MARK: - 4. Re-grant round trip

    /// The cross-epoch fidelity pin (the 2026-07-29 session cycled multiple epochs): a
    /// full session — seed → three temp enacts (supersede chain) + a bolus → hand-back
    /// fold (temps truncated at supersede, same raws) → RE-SEED a fresh store + ledger
    /// from the folded records — must conserve IOB. Every takeover re-derives the books
    /// from records, so any per-cycle leak compounds across epochs (the class of bug
    /// behind the 7.40 U takeover inflation of 2026-07-22, re-pinned here through the
    /// current fold + split path).
    ///
    /// Geometry note: the last temp's programmed span ends exactly at the hand-back
    /// instant (a loop-cycle hand-back at temp expiry — a real session shape). That keeps
    /// ledger1's full-span row identical to the folded record, so the three-way
    /// comparison at H carries no forward-delay asymmetry (shadow mode has no ledger
    /// hand-back truncation hook — see handbackFold).
    func testReGrantRoundTripPreservesBooks() {
        let now = Date()
        let s = now.addingTimeInterval(-.minutes(100))    // epoch-1 takeover
        let h = s.addingTimeInterval(.minutes(50))        // hand-back = temp3's natural expiry

        // Grant history: phone-side rows under the identity contract (syncId = hex(raw)).
        let histTempStart = s.addingTimeInterval(-.minutes(45))
        let histBolusStart = s.addingTimeInterval(-.minutes(40))
        let history = [
            LoanDoseRecord(kind: .tempBasal, startDate: histTempStart,
                           endDate: s.addingTimeInterval(-.minutes(15)), unitsPerHour: 1.40,
                           syncIdentifier: hexString(podRaw(type: "tempBasal", value: 1.40, start: histTempStart))),
            LoanDoseRecord(kind: .bolus, startDate: histBolusStart,
                           endDate: histBolusStart.addingTimeInterval(38), amount: 0.80,
                           syncIdentifier: hexString(podRaw(type: "bolus", value: 0.80, start: histBolusStart))),
        ]

        let epoch1 = makeDriver()
        epoch1.seed(history, at: s, epoch: 1)
        epoch1.enactTemp(rate: 2.80, at: s, duration: .minutes(30))                              // → truncated [s, s+10]
        epoch1.enactTemp(rate: 0.00, at: s.addingTimeInterval(.minutes(10)), duration: .minutes(30)) // → truncated [s+10, s+20]
        epoch1.enactBolus(units: 0.95, at: s.addingTimeInterval(.minutes(15)))
        epoch1.enactTemp(rate: 1.05, at: s.addingTimeInterval(.minutes(20)), duration: .minutes(30)) // runs to natural expiry at h

        let nextGrantRecords = epoch1.handbackFold(at: h)
        let ledger1 = epoch1.ledger.insulinOnBoard(at: h)

        // Epoch 2: fresh store + fresh ledger, seeded from the folded records — the real
        // split runs again, hex syncIds decode back to the same pod-native raws.
        let epoch2 = makeDriver()
        epoch2.seed(nextGrantRecords, at: h, epoch: 2)
        let sample2 = epoch2.tick(at: h)

        XCTAssertGreaterThan(ledger1, 0.3, "sanity: the session books carry insulin at hand-back")
        XCTAssertEqual(sample2.store, sample2.ledger, accuracy: 0.05,
                       "epoch-2 store and ledger read the same folded records — same rows, same math")
        XCTAssertEqual(sample2.ledger, ledger1, accuracy: 0.05,
                       "the ledger's live timeline and its folded-and-reseeded twin must agree — the fold loses nothing")
        XCTAssertEqual(sample2.store, ledger1, accuracy: 0.05,
                       "cross-epoch fidelity: IOB is conserved through fold → re-grant → reseed")
    }
}
