# Unified Insulin Model — watch IOB, watch prediction, phone reconciliation

**Status:** design proposal (2026-07-09), for review. Supersedes the odometer-remainder
approach to *basal* reconciliation in `IOB_RECONCILIATION.md` (Phase B). Boluses are
unaffected — they stay journaled-at-real-timestamps.

This doc integrates four threads that were being solved separately — watch Show-Mode
IOB, watch prediction, phone hand-back reconciliation, and the pod emulator's fidelity —
into **one model** with a single source of truth.

---

## 0. The pod architecture this rests on (verified 2026-07-09, code-cited)

Two layers, and the whole design turns on keeping them straight:

- **Command layer — typed.** `0x1a PROGRAM_INSULIN` carries a schedule-type byte
  (`SetInsulinScheduleCommand.swift:14-18`): `0 = basalSchedule`, `1 = tempBasal`,
  `2 = bolus`, each with its own table struct. The pod runs the basal schedule
  **autonomously** on its own pulse timer (`3600 / pulsesPerHour`; 0.05 U/pulse); a
  temp basal overrides that rate for its window; a bolus is a fast burst overlaid on
  top. Delivery-status bits prove concurrency (`Pod.swift:105-114`: state 5 = bolus +
  scheduled basal both active).
- **Accounting layer — untyped.** Lifetime delivery is a **single merged pulse
  counter** — `StatusResponse.insulinDelivered` / `DetailedStatus.totalInsulinDelivered`
  (`/20` scaling). There is **no** basal-delivered or bolus-delivered field. The pod
  knows a pulse's source *while delivering it* (status bits, `bolusNotDelivered`), then
  discards that distinction once the pulse is out.

**Consequence (the crux):** you cannot recover the basal/bolus split, the timing, or a
below-schedule shortfall from the odometer. A merged total yields only the **net**
surplus, **collapsed to a point**. Symmetry and correct timing are therefore
*impossible* from the odometer and *only* available from the watch's own journal.

---

## 1. The unifying principle

> The **journal** (the watch's typed, timestamped record of the boluses and basal
> changes it commanded) is the authoritative source of what was delivered.
> The **basal schedule + ISF schedule live on the watch**.
> **One** net-basal-vs-schedule computation then serves three consumers.

| Consumer | Today (deferred/hack) | Unified model |
|---|---|---|
| Watch Show-Mode IOB | bolus-only, labeled "Bolus IOB" | **true net IOB** (bolus decay + net basal vs schedule) |
| Watch prediction | ships dark (no ISF on watch) | **live** `predict()` with real ISF + schedule |
| Phone reconciliation | odometer-remainder → one late bolus; positive-only | **journal basal → temp-basal DoseEntries**; symmetric via InsulinMath; odometer = audit |

The pod odometer stops being a *source* and becomes a *cross-check*.

---

## 2. Enabling change: ship the schedule + ISF to the watch

Today the grant carries pod identity + insulin **type** only (the `"it"` key). Add the
two schedules the model needs:

- **Basal schedule** — to compute net basal (temp/commanded rate − scheduled rate).
- **Insulin sensitivity schedule (ISF)** — to turn IOB into a BG projection.

**Transport:** extend `LoopSettingsUserInfo` (already flows watch↔phone) rather than the
grant — schedules are settings, not pod identity, and Loop already reserializes settings
on change. Send the full schedules (not a grant-time scalar): it's a few hundred bytes,
it's correct across the loan's duration and across midnight schedule steps, and it's
needed anyway for prediction. (This overrules the earlier "scalar-in-grant for v0"
shortcut — Jeremy's call, 2026-07-09: avoiding the schedule is pointless.)

**Watch side:** `WatchPodLoanCoordinator` stores the schedules from the settings context;
`PodLoanInsulinMath` gains a net-basal term (below).

---

## 3. Watch: true net IOB + live prediction

`PodLoanJournal` already records `.bolus`, `.tempBasal(rate,duration)`, `.suspend`,
`.resume` with timestamps. With the schedule on the watch:

```
netBasalIOB(at:) = Σ over journal basal segments:
    (commandedRate(segment) − scheduledRate(segment)) × hours(segment)
    decayed by the same insulin curve, integrated like LoopKit InsulinMath
bolusIOB(at:)    = Σ boluses × percentEffectRemaining        (already built)
IOB(at:)         = bolusIOB + netBasalIOB
```

- `netBasalIOB` reuses the exact **net-basal-vs-schedule** semantics LoopKit uses
  (`DoseEntry.netBasalUnits`): scheduled basal → 0, deviation → signed. Suspends are a
  temp of rate 0 (strongly negative net). This is symmetric on the watch for free.
- **Scope: session-only, and labeled as such.** This IOB reflects only what the WATCH
  did during the loan (its boluses + basal deviation). It does NOT include insulin on
  board when the loan began — the watch can't see that (the grant carries pod identity,
  not the phone's starting IOB). So the Show-Mode row is titled **"Insulin during show
  mode"** (net; can go negative), degrading to **"Bolus during show mode"** when the
  schedule hasn't reached the watch — deliberately NOT the phone's "Active Insulin",
  which would read as the full body figure.
- **Future work (deferred, not current priority): seed the baseline.** To show TRUE
  total active insulin, the phone would send its IOB at loan grant and the watch would
  carry it forward. Note this is more than a scalar: IOB is a sum of doses at different
  ages, so decaying a single starting number is an approximation — a faithful version
  needs the phone's active dose history (or an accepted approximation) sent at grant.
  Required for a real on-watch prediction; tracked with the direct-G7 BG work.
- `predict(currentBG:)` stops shipping dark: `eventualBG = currentBG − IOB × ISF`, with
  ISF and IOB both real. Still display-only; still must not gate dosing until the
  BG-on-watch (direct-G7) work lands.

Pins: the existing `PodLoanInsulinMathTests` vectors extend to net-basal cases
(high temp adds, suspend subtracts, scheduled nets to zero).

---

## 4. Phone reconciliation: journal-basal → temp-basal doses (symmetric)

Replace the basal half of `reconcileWatchLoan` (`WatchDataManager.swift:616-630`):

- **Boluses:** unchanged — entered at real timestamps (already correct).
- **Basal (new):** reconstruct the journal's basal timeline as **`.tempBasal`
  DoseEntries** with the real commanded rate **and** `scheduledBasalRate` populated from
  the phone's schedule, spanning each journal segment at its real times. Hand them to
  DoseStore. Loop's existing IOB math nets them vs schedule → **both directions fall
  out for free**, at the correct times (not collapsed to hand-back):
  - watch ran a high temp → positive net → adds IOB (as today, but time-accurate);
  - watch suspended / ran below schedule → negative net → **subtracts IOB** (the Phase-C
    gap, now closed).
- **Odometer → audit only:** compare `podDelta` against the journal-reconstructed total
  delivery. Within tolerance → log "consistent." Outside tolerance → log a warning and
  fall back to the conservative rule (enter positive surplus as a late bolus; never
  enter a negative from an *unreconciled* odometer). The odometer stops being the source
  and becomes the safety check that the journal isn't lying.

This removes the "collapse distributed extra basal into a point bolus" distortion and
the "can't represent below-schedule" gap — both were artifacts of using the merged
odometer as the source.

---

## 4a. Jeremy's direction on write-back mechanics (2026-07-09 evening — TO DISCUSS)

Recorded verbatim-in-spirit; constrains how §4 gets built. The §4 temp-basal-DoseEntry
reconstruction is ON HOLD in favor of this simpler frame:

1. **Feeding Loop's IOB retroactive temp-basal history is a bridge too far.** Stay
   within the **non-pump-insulin paradigm** (the mechanism already used for boluses);
   don't reach deeper into Loop's internal dose mechanics.
2. **Positive net basal MAY be sent back as a small "fake" bolus** at the segment's
   midpoint — e.g. +1.6 U/hr above schedule for 30 min → a 0.8 U bolus timestamped
   halfway through the window. (Maybe; to discuss.) Note: this is a timing refinement
   of what Phase B already does with the odometer remainder (lump at hand-back) —
   midpoint timing decays more accurately, journal-derived instead of odometer-derived.
3. **Netting is potentially acceptable:** a watch bolus + a negative basal deviation
   could be entered as the netted (reduced) bolus.
4. **Open to small, SAFE changes to let non-pump insulin accept negative boluses**,
   if that can be incorporated into Loop's IOB safely. Open verification item: whether
   HealthKit/DoseStore actually rejects negative insulin quantities was ASSERTED this
   session, never tested — test before designing on top of either answer.

All four remain subject to the §5 gate (real-pod validation of journal fidelity before
anything negative touches dosing IOB).

## 5. Safety — the pre-deployment gate (do NOT ship symmetric write-back unguarded)

**The asymmetry existed for a safety reason, and removing it removes a conservative
bias. This section is the gate Jeremy asked for.**

- **Direction of danger.** Overstating IOB → Loop doses **less** → high BG (uncomfortable,
  not acute). Understating IOB → Loop doses **more** → **hypo** (acute). Today's design
  drops negative remainders precisely because dropping them overstates IOB — the safe
  side. Symmetric write-back deliberately enters negatives, i.e. it **removes insulin
  from the model**, which is the hypo-adjacent direction. It must be *right*, not just
  present.
- **What must be validated before enabling negative write-back in production:**
  1. Journal basal segments faithfully reflect what the pod actually ran (rate, start,
     stop) — validated end-to-end on the **real pod** Friday, not just the emulator.
  2. Suspend/resume windows are captured with correct timestamps (a missed *resume*
     would over-subtract IOB → over-dose). Add a guard: if the loan ended while
     suspended per journal but the pod reports delivery resumed, distrust the negative.
  3. The odometer audit (§4) agrees within tolerance — a journal that under-reports
     delivery vs the pod's total is a red flag; do not write negatives when they
     disagree.
- **Staged rollout.** Phase 1: build symmetric math + reconstruction, **log** the
  negative net it *would* enter, but keep entering only the conservative positive
  (shadow mode). Compare shadow-negatives against reality across real-pod sessions.
  Phase 2: enable negative write-back only after the audit agrees consistently, with the
  guards in #2/#3 live. **Symmetry in the display (watch) is safe now; symmetry in the
  phone's dosing-input IOB is gated on this validation.**

---

## 6. Emulator patch (enables testing §3–§5 without waiting for Friday)

The emulator parses the type byte but **discards basal rate** and only moves `Delivered`
on a bolus (`pod.go:423-438`, `:435`; comment `:432-433`). Patch it to match a real
pod's *merged* odometer — **not** a per-type ledger (a real pod has none; a per-type
emulator would validate against a fiction):

1. Store the programmed basal rate (TableNum 0) and temp-basal rate + window (TableNum 1)
   — currently discarded.
2. Accrue basal into the **single** `Delivered` counter (and burn `Reservoir`) over
   elapsed wall-clock, compute-on-read at each GET_STATUS: `Delivered +=
   floor((now − lastAccrual) × activeRate / pulseSize)`; temp window overrides schedule
   rate; suspend contributes zero.
3. (Skip) per-pulse bolus ramping — irrelevant to reconciliation.

Then: re-run `setcap` after `go build` (known crash-loop-if-forgotten gotcha); back up
the binary + `state.toml` first; podsim bounces once (phone reclaims after). This makes
**both** the positive test (high temp → positive net) and the negative case
(suspend → negative net) exercisable on the emulator today.

---

## 7. Sequencing

1. **Emulator patch** (§6) — unblocks all basal testing. ~20 lines Go.
2. **Schedule+ISF transport** (§2) — the enabling change.
3. **Watch net IOB + live predict** (§3) — display-only, safe, immediately demoable.
4. **Phone reconstruction in shadow mode** (§4 + §5 Phase 1) — build symmetric, log
   negatives, still enter only conservative positives.
5. **Real-pod validation Friday** — journal fidelity, suspend timing, odometer audit.
6. **Enable negative write-back** (§5 Phase 2) — only after 4–5 agree.

Steps 1–4 are all buildable now on `watch-prediction`; nothing merges until reviewed.

---

## 8. Open decisions for Jeremy

1. **Transport:** full schedules via `LoopSettingsUserInfo` (recommended) vs a smaller
   grant-time payload. Recommend full — needed for prediction anyway.
2. **Watch label:** DECIDED (2026-07-09) — "Insulin during show mode" (net) /
   "Bolus during show mode" (bolus-only fallback). Session-scoped wording, provisional
   ("tweak later"); check width on the smallest watch. NOT "Active Insulin" — that reads
   as total body IOB, which the session figure is not (see §3 future work).
3. **Reconciliation source of record:** journal-primary with odometer-audit
   (recommended, this doc) vs keep odometer-primary. Journal-primary is the only path to
   symmetry + correct timing.
4. **Negative write-back gate:** shadow-mode-then-enable (recommended) vs enable on first
   real-pod green. Recommend shadow — the failure direction is hypo.
5. **Emulator fidelity:** merged-odometer accrual only (recommended, matches real pod)
   vs also expose per-type sub-totals (rejected — validates against a fiction).
