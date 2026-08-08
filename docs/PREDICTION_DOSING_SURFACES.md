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
between the other two conventions.**

- Displayed IOB comes from `DoseStore.insulinOnBoard(at: now)` → `getInsulinOnBoardValues`
  with **`basalDosingEnd: nil` (default — no trim)** (LoopKit `DoseStore.swift:1288-1329`).
- But the per-dose integration bounds itself at
  `doseDate <= min(floor((time + model.delay)/delta)·delta, doseDuration)`
  (LoopKit `InsulinMath.swift:34`) — segments up to **now + `model.delay`** count, and within
  the delay window `percentEffectRemaining` is 1.0, so they count at full value. For
  rapid-acting insulin the delay is ~10 minutes.
- Net: the IOB number includes the running temp's delivery through roughly the next 10 minutes,
  NOT through its scheduled end, and NOT trimmed at now. This is why hand-computing a
  prediction from displayed IOB × ISF is *systematically misleading* whenever a temp is
  running: the prediction (surface a) and the IOB number (surface b) count the same temp
  differently.
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
