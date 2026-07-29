# Design: route loan insulin through `addPumpEvents` (#69 / #52)

**Status:** approved 2026-07-25 (Jeremy), implementing.
**Supersedes:** the `LoanReconciler.collapsingOverlappingBasals` truncation fix (commits `27cb6136`, `e6a4cb29`, builds 160/161). That was a correct *interim* fix; this is the durable one and removes the bespoke collapse.

## Problem

Loan doses were written via `DoseStore.addDoses(_:from:nil)`, which deposits `DoseEntry`s straight into `InsulinDeliveryStore` (HealthKit) **without** stock's reconciliation, and **never** writes a `PumpEvent` row. Two symptoms, one root cause (the `addDoses` side door):

1. **Over-count (#69):** the watch mints each temp with a full 30-min window and never trims the predecessor; nothing truncated the overlaps → ~6-7× IOB inflation (10.63 U for ~1.3 U delivered).
2. **Empty Event History (#52):** the in-app Insulin Delivery → History screen reads the `PumpEvent` table, which `addDoses` never populates.

## Decision

Write loan insulin the way a real pump does: **`DoseStore.addPumpEvents`**. It is the only path that (a) writes `PumpEvent` rows → History screen, (b) runs stock `InsulinMath.reconciled()` on the save-to-HealthKit read → overlap truncation for free, (c) mirrors reconciled doses into `InsulinDeliveryStore`/HealthKit, (d) posts `valuesDidChange` on the DoseStore → IOB recompute. "Minimum deviation" here means **mirroring OmnipodKit's own `UnfinalizedDose → NewPumpEvent` pattern**, since a loan is inherently a second insulin writer the pod manager doesn't know about.

## The critical subtlety (why this is more than a one-line swap)

`addPumpEvents`' save path filters `endDate <= now || isMutable`. A still-running temp has a **future** endDate, so if written **immutable** it is **deferred** (dropped from IOB). The stock answer is a mutable ongoing dose — but that model fought the loan's exactly-once `committedIDs` + WS1 finalize gate. An adversarial review caught the failure: withholding the open temp from the ack cursor means the watch's `unackedEvents` never empties, so it never sends the final offer and **never hands the pod back** (a finalize deadlock). **Resolution: don't write the open temp at an interim drain at all.** The phone is *paused* during the loan, so its store only has to be correct at hand-back; the open temp re-drains and is written once, correctly (clamped, immutable), on the **final** drain. We still ack its seq (decoupled from `committedIDs`) so the watch can finalize. No mutable loan doses.

## Stock recipe to mirror (OmnipodKit, verified)

`OmniPumpManager.store(doses:)` → `hasNewPumpEvents: doses.map { NewPumpEvent($0) }, lastReconciliation:, replacePendingEvents: true`.

- `NewPumpEvent(date: dose.startDate, dose: entry, raw: <deterministic key>, title:)`.
- **Identity lives in `raw`.** `NewPumpEvent.init` overwrites `dose.syncIdentifier = raw.hexadecimalString`, so our `loanv2-<uuid>` must be encoded into `raw` (`Data(syncId.utf8)`), not the DoseEntry syncIdentifier (discarded). `PumpEvent` dedups on `raw` (unique constraint + store-trump upsert) → deterministic `raw` = no duplicate History rows.
- Stock marks an in-progress dose `isMutable`; **the loan does not** — it withholds the open temp instead (see Implementation). All loan doses are immutable.
- `lastReconciliation` = the "finalized-through" watermark; **must be non-nil** or doses never promote to HealthKit (`getPumpEventDoseEntriesForSavingToInsulinDeliveryStore` bails on nil / ≤ start).

## Implementation

**Write path** (`PodLoanPhoneController` + `WatchDataManager:100`): add `deps.addPumpEvents(events, lastReconciliation, completion)`, wired to `doseStore.addPumpEvents(_, lastReconciliation:, replacePendingEvents: false)` — all loan doses are immutable so there's nothing to purge, and `false` must NOT purge the phone's own resumed-pod in-flight temp on a post-reclaim write. Route the two reconcile sites (`handleHandbackOffer`, `forceReclaimToOwner`) and the R6 audit / re-audit boluses through it.

**DoseEntry → NewPumpEvent wrapper** in the controller:
- `raw = Data(dose.syncIdentifier.utf8)` (the `loanv2-<uuid>` / `loanv2-audit-<epoch>` identity).
- `title` from dose type.
- **Mutability / trailing-dose handling:**
  - *Final* hand-back (or forced reclaim): every dose immutable; clamp any `endDate > handedBackAt` to `handedBackAt` (delivery stopped at reclaim, and this keeps it `<= now` so it is saved immediately, not deferred).
  - *Interim* drain: the still-open trailing temp (`endDate > handedBackAt`, `outcome.openEventID`) is **withheld from the write** (all others written immutable). It is written on the final drain.

**`lastReconciliation`** = `offer.handedBackAt` (final) / the drain instant (interim). Never a future time.

**`committedIDs` / ack-cursor decoupling (interim only):** keep the still-open temp OUT of `committedIDs` (so it re-drains and is written on the final drain), but DO advance the ack cursor past it (`newCursor` uses all `events`, not `committable`). Acking it lets the watch's `unackedEvents` empty and the final offer fire; keeping it out of `committedIDs` lets it re-drain. This decoupling is the fix for the finalize deadlock the review found. The phone re-derives the final drain's events from `staged` minus `committedIDs` (not from `offer.events`), so the withheld temp is written even though the final offer carries nothing.

**Remove `LoanReconciler.collapsingOverlappingBasals`** (stock `reconciled()` now does the inter-temp overlap truncation at the store, and trims the last loan temp against the phone's first resumed dose). **Keep `Input.isFinalHandback`** — it now drives two things: the final-drain clamp of every dose to `loanEnd` (so a full-window trailing temp isn't deferred by the save filter), and, on an interim drain, the withholding of `outcome.openEventID`. The reconciler's R22 audit / `expectedInsulin` / remainder valves are unchanged.

## Tests

- #69 fixture (9 overlapping temps + a phone resumed temp) through the real `addPumpEvents → reconciled()` path → correct integrated total AND History rows present.
- Idempotency: repeat drain / resend → no duplicate `PumpEvent` rows, no IOB double-count (deterministic `raw`).
- Interim: the open temp is withheld from the interim write (`testInterimDrainWithholdsOpenTempFromWrite`) and written on the final drain; the controller still acks it so finalize fires.

## Risks / verify on device

- `replacePendingEvents: false` — no loan mutable dose exists to replace, and it must not purge the phone's own resumed-pod in-flight temp on a post-reclaim write (re-audit / forced reclaim). Idempotency across resends / interim+final drains rests entirely on the deterministic `raw`.
- The brief gap `[handedBackAt → phone's first resumed dose]`: the last loan temp is clamped to `handedBackAt` and the gap is backfilled by scheduled basal — bounded (seconds) since the phone resumes immediately.
- Confirm loan temps now appear in Insulin Delivery → History, with correct sizes, and IOB matches delivered.

---

## Addendum — 2026-07-25 (late): the takeover SEED, and prediction fidelity (#69/#46/#45)

The section above routed the **hand-back** (watch→phone) through `addPumpEvents`. The **takeover
seed** (phone grant → watch, `ingestGrantHistory`) was still on the `addDoses` side door. Field
logs (build 163, `boundaryDup=YES` on four re-takeovers) plus new headless tests drove these:

**Fix 1 — drop the boundaryRecord (phone).** The phone had sent the running temp TWICE: once as
the open temp in `doseHistory` (from `getNormalizedDoseEntries`, fetched after `releaseConnection`,
which only truncates in-memory pod state — never the store) and again as a same-start, same-rate
`boundaryRecord`. Seeding both double-counted the `[start→handover]` slice. The phone now passes
`boundaryRecord: nil`. The `.boundaryTruncation` Kind + `LoanReconciler` handling are LEFT as
vestigial defensive/back-compat tolerance (the watch journal never mints that kind).

**Fix 2 — seed via `addPumpEvents`, not `addDoses`.** Same rationale as the hand-back: stock
`reconciled()` at the store collapses any same-start overlap AND puts the seed in one
reconciliation world with the watch's own enacted temps (the first watch temp truncates the
seeded open temp instead of overlapping its tail). `replacePendingEvents: true` is safe here
(the wipe already emptied the table); `lastReconciliation = takeover instant`.

**Fix 3 — REJECTED by test.** We tried freezing each seeded temp's `scheduledBasalRate` (from the
grant schedule) so net-basal IOB wouldn't re-net against a changed profile. The headless test
proved this does NOT work on the pump-event path: `addPumpEvents`/`PumpEvent` does not persist
`scheduledBasalRate` — LoopKit re-derives it from the reader's `basalProfile` at read
(`InsulinMath.annotated(with:)`). It is unnecessary anyway: the watch's `basalProfile` is frozen
to the grant schedule for the loan, so seeded temps net against the delivery-time schedule
correctly. (The PHONE-side retroactive-netting bug — the profile CAN change mid-loan there, and
the phone also writes via `addPumpEvents` — is therefore still open and needs a different
approach; parked.)

**RC-freeze fix (#46).** Separately, the watch printed `RC —` on EVERY `[predict]` line all loan.
Root cause: the port dropped the phone's `LoopDataManager.carbEffect.didSet`. On the watch,
`retrospectiveGlucoseDiscrepancies` was set to `[]` at cold-start takeover and, with no didSet to
re-nil it, `updateRetrospectiveGlucoseEffect()` (guarded on `== nil`) never re-ran → RC frozen
empty. Restored a `carbEffect.didSet { retrospectiveGlucoseDiscrepancies = nil }`. We
deliberately do NOT also nil `predictedGlucose` (phone parity) — on the watch it is display-only
(DoseMath uses the local prediction) and #48 intentionally keeps the last eventual visible.

**Glucose in the grant (#45).** The watch's `GlucoseStore` was empty at takeover, so momentum was
blind ~15 min and RC never warmed. `LoanGrant` now carries ~3 h of glucose (`LoanGlucoseRecord`,
optional/backward-compatible); the watch seeds its `GlucoseStore` at takeover
(`ingestGrantGlucose`) so momentum + RC warm from the first cycle. Idempotent via the phone's
syncIds; at most a single boundary sample can duplicate (phone/watch derive different G7 syncIds),
which the algorithm tolerates.

**Extraction.** `record→DoseEntry` seeding moved to shared `LoanProtocolV2` (`seedDoseEntry` /
`seedDoseEntries`) so the watch seed and the tests (LoopTests, headless) exercise identical logic.

**Tests (LoopTests, no BLE):** `testHandoverBoundaryDoesNotDoubleSeedIOB`,
`testHandoverIOBConservationAcrossTakeover`, `testSeededTempNetsAgainstFrozenGrantSchedule`,
`testGrantGlucoseHistoryRoundTrips`. Reviewed by four independent adversarial passes — no blocker.

**Deferred (low-risk, noted):** `ingestGrantHistory` continues seeding on a failed wipe (could
stack epochs on a rare Core Data wipe failure — aborting the takeover would be safer); the
reservoir read branch could exclude the immutable open temp in a rare window; Event History may
show the running temp as two unreconciled rows (IOB unaffected).

---

## Addendum (2026-07-28, build ~180) — the identity contract, and the re-report this design missed

**What this design did not anticipate:** the watch's rebuilt `OmniPumpManager` RE-REPORTS
pre-takeover doses out of the inherited `podState`. Two guaranteed cases: (a) a bolus that
finished seconds before the grant rides `podState.unfinalizedBolus` un-pruned (the phone's
`beginGrant` does no quiesce read, and prune only happens inside a comms session's
`dosesForStorage`); the watch's first status read finalizes and re-reports it. (b) the running
temp re-reports as a mutable `NewPumpEvent` on every status-bearing read
(`PodState.dosesToStore` unconditionally appends `unfinalizedBolus`/`unfinalizedTempBasal`).
Field: epoch 47's `+1.15U` cycle-1 IOB echo; epochs 42/44/45's cross-epoch inflation.

**The identity contract (why this was ever a bug):** LoopKit's `PumpEvent` DISCARDS an incoming
`DoseEntry.syncIdentifier` and derives dose identity as `raw.hexadecimalString`
(`PumpEvent+CoreDataClass.swift:229`). OmniBLE's raw is `UnfinalizedDose.uniqueKey` =
`utf8("\(doseType) \(scheduledUnits ?? units) \(ISO8601 start)")` — deterministic, cancel-stable,
no UUID — so a re-report on ANY device carries byte-identical raw, and the phone's stored
syncIdentifier IS `hex(raw)`. The seed encoded `raw = utf8(hexString)` (hex-of-hex), giving one
physical dose two identities and blinding all three stock dedup layers (PumpEvent raw uniqueness
+ store-trump merge; `CachedInsulinDeliveryObject` syncIdentifier uniqueness; `appendedUnion`).
Log proof: one bolus as seeded `id=303561` vs pod-native `id=33305a`.

**The fix — `LoanSeedIdentity.raw(forSyncIdentifier:)` (LoanProtocolV2.swift):** hex-DECODE the
phone's syncIdentifier back to the original bytes (utf8 fallback for non-hex ids). Consequences,
all via stock machinery, no new filtering logic: pod re-reports land on the seeded row (silent
same-raw skip); re-seeds across epochs upsert-dedup EVEN IF the wipe misfires (the epoch-42
class); the mutable running-temp re-report collapses onto the seeded Fix-2-trimmed row (its
post-takeover continuation until the watch's first enact stays unbooked — bounded small, C5
territory, odometer audit still sees total truth). A watch-side "drop pre-takeover pod events"
filter was considered and REJECTED: it fights R12 (pod = delivery source of truth) and R5/R22
(never understate; never touch confirmed records); restoring identity lets the pod re-report
freely and dedups it instead.

**Still true / still deferred:** the wipe remains the only defense for (a) doses DELETED on the
phone between epochs (grant no longer carries them, so nothing upserts over stale rows) and
(b) watch-ENACTED prior-epoch doses, which live in the watch store under pod-native uniqueKey
raws but return in the next grant under the phone's JOURNAL identity (hex of utf8
"loanv2-<uuid>") — different raw, so the upsert protection does not cover them (adversarial
review, 2026-07-28). The `[wipe-audit]` instrumentation + force-repurge (build 179) stays to
catch both. A phone-side pre-grant quiesce (`refreshLentDeviceStatus` before `releaseConnection`)
would prune `podState` and freshen the odometer baseline (`deliveredAtGrant` currently uses a
CACHED odometer) at ~1s grant latency — deferred; with identity restored the re-reports it would
prevent are harmless.

**#72 step 1 (Jeremy's ruling, 2026-07-28 evening — "IOB should match reality"): the seed
carries FINISHED history only.** A dose still DELIVERING at the takeover instant is OMITTED
from the seed (`seedDoseEntries(finishedBy:)`) and ownership passes to the pod-state blob + the
watch's own pump manager. Status by dose kind (adversarial review, same evening):

- **Mid-flight bolus: RESOLVED.** C5 does not touch boluses, so it rides the blob genuinely
  unfinished; the watch's first status read reports it MUTABLE, IOB tracks its remaining
  infusion, and completion books actual units under the pod-native raw. (Pre-#72 it was seeded
  immutable at full programmed units and the pod's finalization was swallowed.)
- **Running temp: RESOLVED via the watch-side RE-ARM + the E4 orphan/handover release split
  (#72 step 2, same evening; both refined by a second adversarial pass).** Two mechanisms were
  freezing the record: (i) the phone's C5 record-close cancels `podState.unfinalizedTempBasal`
  at the handover stamp BEFORE `pump.rawValue` is serialized, so the watch inherits the temp
  already-cancelled (and stock's untracked-temp resurrect is commented out in this fork);
  (ii) the WATCH's own E4 releases reused `releaseConnection()` and re-ran the same C5 cancel
  at takeover+90s and after every dose — silently re-truncating the running temp (its own
  enacted temps included) on every orphan cycle. Fixes: `podLoanBeginTakeover(liveTempStart:
  liveTempEnd:)` RE-ARMS the inherited temp (`UnfinalizedDose.podLoanRearmHandoverCancel`) —
  the C5 cancel is exactly reversible (`cancel(at:)` stamps `scheduledUnits`/`scheduledTempRate`
  and nothing else ever sets them; restore is idempotent and uniqueKey-identity-stable); and
  the E4 paths now call `podLoanOrphanConnection()` (BLE drop WITHOUT the record-close — E4 is
  not a handover, the watch remains the controller). Guards from the review: the re-arm fires
  ONLY when the grant's dose history carries a MATCHING live temp record (start ±2s) — the
  phone's books distinguish a genuinely-live temp (mutable full-span record) from a stale C5
  signature lingering across back-to-back loans; and a 0 U/hr temp (Loop's standard predicted
  low, whose span the cancel math destroys as 0/0) restores from the record's programmed end
  (refuses without it). Post-re-arm the stock truth-table books reality: still running →
  mutable re-reports, IOB tracks (0.50 → 0.57); stopped early → finalized at the status date
  (units stay programmed-basis — stock behavior, noted); expired → full span. The PHONE's copy
  stays cancelled — R2 and hand-back accounting untouched; the watch never journals the
  inherited temp. Known residual edges (documented, not regressions): phone-ahead clock skew
  can classify a just-finished dose as live and omit it (narrow — requires skew exceeding the
  dose-end→ingest gap); the stale-signature corner survives only if the phone re-grants with
  NO status read since reclaim (the rapid-re-takeover #42 shape). Manager-layer tests
  (OmniTests): `testPodLoanRearmReversesC5Cancel`, `testPodLoanRearmSurvivesRawValueRoundTrip`
  (the grant-blob path), `testPodLoanRearmIdempotentAndSelective`,
  `testPodLoanRearmPreservesUniqueKeyIdentity`, `testPodLoanRearmExpiredTempBooksFullSpan`,
  `testPodLoanRearmZeroRateTempNeedsRecordEnd`.

Mechanics that DID verify: stock IOB integrates a dose's delivery only up to eval-time + model
delay (`InsulinMath.continuousDeliveryInsulinOnBoard`'s loop bound;
`percentEffectRemaining(t≤delay)=1`), so a genuinely-MUTABLE full-span row yields delivered-
so-far + a constant ~10-min lookahead — `testPodOwnedMutableTempTracksDeliveryInIOB` pins that
store-level mechanic — and with step 2's re-arm + orphan split the manager now supplies the
mutable row for temps as well as boluses. The seed also switched to
`replacePendingEvents:false` (a pod live-dose report racing ahead of the seed must not be
purged; every manager report runs replace:true and self-heals stragglers), and an EMPTY seed
still calls `addPumpEvents([])` to stamp `lastPumpEventsReconciliation` (pumpDataTooOld guard).
Field-log note: with a live dose omitted, SEED-IN IOB reads shifted by that dose's net
contribution until the first pod read lands — LOW for an above-schedule temp or a bolus, HIGH
for a below-schedule/zero temp — so an `[iob-diff]` Δwire offset with an opposite Δreconcile
rebound is EXPECTED at such takeovers; the seed log carries "N live dose(s) omitted" to flag it.

**Tests:** `testLoanSeedIdentityRawRoundTripAndFallbacks` (decoder),
`testSeedIdentityDedupsPodNativeReReport` (store round-trip: seed + pod re-report → ONE dose),
`testDoubleHexSeedIdentityDuplicates_preFixRegressionShape` (sensitivity control: the bug shape
must still double-count, proving the main test can fail).
