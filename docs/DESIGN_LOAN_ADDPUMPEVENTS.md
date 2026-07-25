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
