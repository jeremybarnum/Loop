# Prediction & Dosing Surfaces — the temp-basal forward-assumption, pinned

**Why this document exists (2026-08-08).** Every dosing debate this project has had eventually
collides with one question: *when a temp basal is running, how much of its future delivery does
each surface assume?* The answer is **different for different surfaces**, all by stock design,
and conversations that don't name the surface first go in circles. This pins the convention per
surface, with the stock source lines, the watch-port lines, and the delta verdict. Read this
before asserting anything about prediction or recommendation behavior.

The one-sentence summary:

> **Dosing trims the temp at now. Bolus recommendations run it to its scheduled end. Displayed
> IOB counts it ~10 minutes forward. Three conventions, all stock, all deliberate.**

---

## The mechanism everything hangs on: `basalDosingEnd`

`DoseStore.getGlucoseEffects(start:end:basalDosingEnd:)` trims continuing (mutable) doses at
`basalDosingEnd` — "the date at which continuing doses should be assumed to be cancelled"
(LoopKit `DoseStore.swift:1342-1362`, `dose.trimmed(to: basalDosingEnd)`).

Stock keeps **two cached insulin-effect timelines** (phone `LoopDataManager.swift`):

| Timeline | Call | Running temp is assumed to… |
|---|---|---|
| `insulinEffect` | `getGlucoseEffects(…, basalDosingEnd: now())` — `:1036` | **stop at now** (zero forward credit) |
| `insulinEffectIncludingPendingInsulin` | `getGlucoseEffects(…, basalDosingEnd: nil)` — `:1052` | **run to its scheduled end** (full remaining span, ≤30 min) |

`predictGlucose(…, includingPendingInsulin:)` selects between them — literally
`let basalDosingEnd = includingPendingInsulin ? nil : now()` (`LoopDataManager.swift:1387`).

---

## Surface (a): the automatic loop — prediction and temp-basal dosing

**Convention: the running temp is trimmed AT NOW. Zero forward credit.**

- Stock: the loop's `predictedGlucose` is built from plain `insulinEffect`
  (`basalDosingEnd: now()`), and `recommendedTempBasal` is computed from that prediction. The
  recommendation *replaces* the running temp, so crediting the temp's future would double-count
  the very thing being re-decided. Each 5-minute cycle re-derives the temp from
  delivered-insulin-only.
- The running temp still matters to the *decision* in one way: DoseMath's
  `ifNecessary(…, lastTempBasal:)` compares the fresh recommendation against the running temp
  to decide whether a new command is even needed (continuation/suppression) — but that is
  command-economy, not prediction credit.
- Watch port: identical. `predictedGlucose = try predictGlucose()` (no pending) feeds
  `predictedGlucose.recommendedTempBasal(…)` (`WatchLoopManager.swift:2130-2168`), and the
  effects use the same trim (`:1559/:1562`, both `basalDosingEnd: now()`; the ledger path's
  comment at `:1540` states the contract explicitly).

So for the *loop*, "does the temp run 30 minutes or until the next cycle?" — **neither**: the
prediction assumes it stops *now*. The practical difference from "until the next 5-minute
cycle" is one cycle's delivery (≤ ~0.3 U at 4 U/hr), and the next cycle re-books whatever was
actually delivered. Jeremy's formulation "literally current, or until the next cycle — a very
small difference" is exactly right *for this surface*.

## Surface (b): the IOB (and COB) numbers in the UI

**IOB convention: the running temp is counted to now + the insulin model's delay (~10 min) —
between the other two conventions.** *(Challenged 2026-08-08 and re-verified by exact numeric
replication of the integral — see below. The delay itself is NOT "incorporated into IOB"; the
forward-counting is an interaction of three verified facts.)*

The three facts, each cited:

1. **The display path does not trim the running temp.** `DoseStore.insulinOnBoard(at: now)` →
   `getInsulinOnBoardValues(…, basalDosingEnd: nil — the default)` → `trimmed(to: nil)` = the
   dose keeps its full scheduled span (LoopKit `DoseStore.swift:1319-1329`). The chain to the
   screen: `doseStore.insulinOnBoard(at: now())` → `self.insulinOnBoard` →
   `dosingDecision.insulinOnBoard` (phone `LoopDataManager.swift:1128, 1160`).
2. **The IOB integral's loop walks `model.delay` past now**:
   `while doseDate <= min(floor((time + model.delay)/delta)·delta, doseDuration)`
   (LoopKit `InsulinMath.swift:34`) — so delivery segments starting up to ~10 min in the
   future are visited.
3. **The delay means exactly what it says** — insulin delivered now doesn't begin absorbing
   for `delay` (~10 min): `percentEffectRemaining(at: t) = 1 for t ≤ delay`, including
   negative t (`ExponentialInsulinModel.swift:54-58`). Consequence inside the integral: the
   future segments visited by (2) score 1.0 — full, unabsorbed weight.

(1)+(2)+(3) ⇒ displayed IOB counts the running temp's **next ~10 minutes of scheduled,
not-yet-delivered insulin at full value**. In the glucose-*effect* integral the same loop bound
is harmless — a future segment contributes `1 − pER = 0` — which is likely why the shared bound
exists; in the IOB integral it is not a no-op.

**Exact numeric replication** (the integrals and model transcribed verbatim; temp 3.8 U/hr vs
scheduled 0.7 (net 3.1 U/hr), 30-min temp, evaluated 10 min in):

| Convention | Temp's IOB contribution |
|---|---|
| untrimmed (display) | **1.292 U** — five 5-min segments at pER 1.0, including the segments starting at now, +5 min, +10 min |
| trimmed-at-now (dosing) | **0.517 U** — exactly the net insulin actually delivered |
| difference | **0.775 U of not-yet-delivered insulin in the displayed number** |

Two lesser forward biases stack on top: `insulinOnBoard(at:)` returns the **max** of the two
timeline values adjacent to `date` (±half a grid step; deliberate, commented for the
just-scheduled-bolus case — `DoseStore.swift:1294-1298`).

Net: hand-computing a prediction from displayed IOB × ISF is *systematically misleading*
whenever a temp is running — the prediction (surface a, trimmed at now) and the IOB number
(surface b, ~10 min forward) count the same temp differently, by up to
`net rate × delay` (≈ 0.5-0.8 U at typical sport-mode high temps).
- Watch: glance IOB = `SessionInsulinLedger.insulinOnBoard(at: now())` post-cutover
  (`WatchLoopManager.swift:598`), which uses the same public InsulinMath — same convention.
- **COB** has no temp-basal question. Both platforms: `carbStore.carbsOnBoard` with dynamic
  absorption driven by observed insulin-counteraction velocities (ICE). Phone
  `LoopDataManager.swift:913`; watch mirrors via `glanceCarbsOnBoard`
  (`WatchLoopManager.swift:630-648`).

## Surfaces (c) and (d): the carb-entry screen and the lightning-bolt bolus screen

**These are ONE code path, and the convention flips: when a temp is running (or a bolus is in
flight), the prediction assumes the temp RUNS TO ITS SCHEDULED END, and the recommendation is
only the insulin needed ON TOP of that.**

- Both screens call `recommendBolus(consideringPotentialCarbEntry:)` — the carb screen passes
  its entry, the lightning bolt passes nil (`LoopDataManager.swift:1480-1492`).
- That function computes `getPendingInsulin()` (`:1196-1220`):

  ```swift
  // the running temp's NET insulin above schedule, from NOW to lastTempBasal.endDate:
  remainingUnits = (lastTempBasal.unitsPerHour − normalBasalRate) × remainingTime
  pending = max(0, remainingUnits) + (lastRequestedBolus?.programmedUnits ?? 0)
  ```

  and if `pending > 0`, builds the prediction with `includingPendingInsulin: true` — i.e. the
  `basalDosingEnd: nil` effects, temp-to-scheduled-end (`:1488-1490`). The recommendation
  struct then reports `pendingInsulin: 0` "already reflected in the prediction" (`:1569`).
- Watch port: `recommendManualBolus` (`WatchLoopManager.swift:2237-2274`) passes
  `includingPendingInsulin: true` **unconditionally** (`:2252`). Behaviorally identical to
  stock's `pending > 0` gate: with no running temp and no in-flight bolus, the two effect
  timelines coincide, so the unconditional flag changes nothing. Both flows (carbs, bolus)
  route through it during a loan (`:718-741`).

### The worked example (field, 2026-08-08 tennis loan)

Eventual 160, target top 115, ISF 70 → naive correction ≈ (160−115)/70 ≈ **0.64 U**. But the
loop was (correctly) already high-temping — say 3.8 U/hr vs 0.7 scheduled with ~25 min left →
pending ≈ 3.1 × 0.42 ≈ **1.3 U**. The bolus screen's prediction includes that 1.3 U, lands at
or below target, and recommends **0 U**. Screen shows "eventual 160" next to "REC 0" and looks
broken. It is not: the recommendation's semantics are *"insulin needed beyond what the running
temp will already deliver"* — Loop refusing to hand you a bolus for a correction it is already
making through the temp. If you accept the recommendation and the loop later cuts the temp
short (BG falling), the next cycles re-book reality; the conservatism is one-sided by design.

**Answer to the 2026-08-08 question:** stock's lightning bolt does **not** count only the
insulin the temp has delivered so far and top up the rest — it assumes the running temp
continues to its scheduled end and recommends only the excess. (Option "b", not option "a".)

---

## Why eventual-vs-range head-math fails — the mechanics, ranked (added 2026-08-10)

Jeremy's field method: read eventual BG and the correction range off the glance, check the
running temp against them. His challenge: "the argument that it's counting the future temp
just doesn't make sense." **He is right, and the record should be clean: the automatic loop
counts ZERO future temp (surface a, above). Forward-credit exists only on the bolus-rec
surface (c/d), where it is coherent** — both the bolus AND the already-commanded temp will
physically deliver; the loop can only claw the temp back NEXT cycle, so recommending only the
excess is the anti-double-dosing choice. The confusion was adjacency: a glance eventual
computed with no temp credit sits next to a REC computed with full temp credit.

The real reasons the intuition fails, from `LoopKit/LoopAlgorithm/DoseMath.swift`, in order
of how often they bite:

1. **The dose is not computed from eventual at all.** `insulinCorrection` (:256-371) walks
   EVERY predicted point within the insulin model's effect duration and takes the MINIMUM
   over points of "units needed to bring THIS point to ITS target" (:326). Eventual is just
   the last point. Any point on the curve that is closer to its target than eventual is to
   the range caps the whole dose. The semantics: the largest dose that overshoots no point.
2. **Each point's target is not the correction range.** `targetGlucoseValue` (:200-214) ramps:
   for the first 50% of effect duration the target is the SUSPEND THRESHOLD, then rises
   linearly to the range average. A +90 min prediction of 100 with suspendThreshold 80 has
   20 mg/dL of headroom, not −15 against a 115 range top.
3. **Per-point sensitivity is absorption-weighted** (:304-309): units-to-correct a point =
   Δ ÷ (fraction of insulin absorbed by then × ISF). Only the eventual point sees ~full ISF.
   The naive (eventual − midpoint)/ISF is exactly the eventual point's own correction — the
   actual dose is ≤ that, bounded by every other point.
4. **The min-BG guard** (:419-423): in `.aboveRange`, if the curve's MINIMUM point is below
   the eventual target's lower bound, `maxBasalRate` collapses to the SCHEDULED rate — high
   temps forbidden outright while eventual reads high. This is the "eventual 160 and it
   won't high-temp" archetype.
5. **Suspend threshold** (:282-285): any predicted point below it → immediate zero-temp,
   regardless of eventual.
6. **The IOB clamp** (:425-428): rate ≤ 2 × (automaticDosingIOBLimit headroom) + scheduled.
7. **maxBasal + rate conversion + rounding** (`asTempBasal` :42-64): units spread over 30 min
   (rate = units/0.5h + scheduled) then min'd with maxBasal — 0.9 U of "need" is a 2.5 U/hr
   temp, not a max temp.
8. **`ifNecessary` suppression** (:147-173): same rate as the running temp with >11 min left
   → no command at all; matches-schedule → cancel. Invisible in the UI either way.

### The refresh asymmetry — Jeremy's hypothesis, CONFIRMED for the stock phone

Verified call graph: `loop()` — compute AND enact — has exactly one caller,
`DeviceDataManager.checkPumpDataAndLoop()` (:571-587), which is CGM-reading-triggered.
Dosing lives on the glucose grid. But the DISPLAYED prediction does not: any store mutation
(carb add/edit/**delete**, dose change) invalidates effect caches and posts `.LoopDataUpdated`
(`LoopDataManager.swift:175-220`), the status screen refetches state, and `getLoopState` runs
`update(for: .getLoopState)` (:2188-2194) — a FULL prediction recompute, including a fresh
recommendation it stores but does not enact. So on the stock phone, deleting a carb updates
the chart and eventual within seconds while the enacted temp remains whatever the last
glucose-triggered cycle commanded — up to ~5 minutes of genuine on-screen incongruity.
The remembered "these numbers are not internally consistent" moments have this exact
mechanism, and carb deletion is literally one of the triggers.

**The sport-mode watch does NOT have this incongruity.** Glance eventual and glance temp are
both products of the same `loop()` pass (`predictedGlucose` is cached per-cycle and read
"only for DISPLAY", `WatchLoopManager.swift:847`; temp = `runningTempBasal()`), and store
mutations on the watch re-run the FULL loop including enact (the 134 carb-add fix and the
R30 delete both invalidate + `loop()`). The watch's only staleness is the 5-minute grid
itself. During a loan the watch is more coherent than the stock phone here — a deliberate
deviation in stock's spirit.

### Consequence for #29 (the audit trail)

The reconciliation a tester needs is: WHICH of the eight limiters bound this cycle. The
existing `[dosemath]` log line prints inputs and verdict but not the binding constraint. The
#29 design: per cycle, log the chain — naive eventual-correction units → min-over-curve units
(naming the binding point's time and value) → min-guard state → IOB clamp → maxBasal →
ifNecessary verdict. Then head-math vs wrist-math reconciles in one line.

---

## Stock vs watch: the delta table

| Surface | Stock | Watch | Delta |
|---|---|---|---|
| (a) loop prediction/dosing | temp trimmed at now (`LoopDataManager:1036,1387`) | same (`WatchLoopManager:1559-1562, 2130`) | **none** |
| (b) IOB display | untrimmed + model-delay bound (`DoseStore:1288`, `InsulinMath:34`) | ledger, same InsulinMath (`WatchLoopManager:598,1540`) | **none** in convention |
| (b) COB display | dynamic absorption w/ ICE | same | none |
| (c) carb-screen rec | pending-insulin prediction when temp/bolus in flight (`LoopDataManager:1196,1488`) | same, flag unconditional (`WatchLoopManager:2252`) | **none behaviorally** |
| (d) lightning-bolt rec | same path as (c) | same | **none behaviorally** |

**Verdict: there is no convention difference between stock and the watch port, and no reason to
introduce one.** The port's one textual difference (unconditional `includingPendingInsulin:
true`) is outcome-identical.

## The real gap this investigation surfaced (UX, not algorithm)

The bolus screen shows the *output* (REC 0) beside an eventual (160) computed under a
*different convention* (the loop's trimmed-at-now prediction on the glance), with the
reconciling quantity — pending insulin — invisible. Every "the recommendation looks wrong"
report this week decomposes into that hidden term. The fix is presentation, not math: the REC
line should carry its reason (e.g. `REC 0 U — temp covers 1.3 U pending`). Tracked with the
diagnostic-screen limiter work (#29).

*Verified against source 2026-08-08 (phone Loop 3.14.3 fork, LoopKit fork, watch port at
b662df81+). Line numbers drift; the function names and the `basalDosingEnd` contract are the
stable anchors.*
