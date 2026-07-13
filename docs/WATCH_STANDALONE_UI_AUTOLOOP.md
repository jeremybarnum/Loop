# Standalone Watch: UI Restructure + Closed Loop — Design

**Date:** 2026-07-11 (evening, post-demo)
**Status:** Jeremy's rulings recorded; implementation staged below.
**Context:** The manual-BG prediction demo works end-to-end on paired sims
(eventual BG, correction range, temp-basal recommendation; IOB/COB cross-checked
against the phone). The G7 direct-connection project is going well, so the UI
is designed **optimistically for streaming BG** (manual entry becomes the
fallback / override), cutting back only if that lands badly.

## Rulings (Jeremy, 2026-07-11)

1. **Manual BG entry: tap the BG number** on the front screen. The carbs-button
   entry point dies (carbs button returns to disabled in Show Mode).
2. **Front screen: no chart** ("no one likes the chart") — use the space
   better. Design for streaming BG. Keep the door open for voice entry
   ("Siri refresh") on a cellular watch — a sweaty rider shouldn't need the
   crown. Nothing in the layout should assume touch-only input.
3. **Closed-loop staleness policy: lenient** — when the newest BG is older
   than the staleness window, stop issuing NEW temps; let the active temp run
   its ≤30-min course. The pod's temp auto-expiry is the fail-safe: schedule
   returns within 30 minutes no matter what the watch does.
4. **Dose caps: therapy-settings max only** (maximumBasalRatePerHour), same
   bound as phone Loop — revisit later. Temp-basal only; **no auto-bolus** in
   the standalone loop. Frame everything Loop-native (this is a Loop project;
   avoid leaning on other systems' canon).
5. **No graphs on the watch** (Jeremy, 2026-07-12) — "waste of space." Trend
   ARROWS yes, glucose chart no (at least not now). When a surface needs more
   than fits, add another swipe screen rather than cramming or charting.
6. **Manual vs. streamed BG must follow the Loop idiom** (Jeremy, 2026-07-12) —
   Loop already anticipates BOTH no-live-BG and dosing off manual entries.
   Research the actual code behavior (see "Manual vs. streamed BG" below) and
   mirror it rather than inventing watch-specific rules.

## Front screen (Show Mode HUD)

The show-mode HUD keeps the chart hidden and gives the table the screen.
Rows (all existing tappable-table machinery, no storyboard surgery):

- **BG row** — big current BG + trend arrow + age ("142 → · 6m"). Fed from the
  watch-local glucose store: streaming sensor when it exists, backfilled CGM,
  manual entries. **Tap → BG entry dial** (crown), which stores the entry and
  re-runs the cycle.
- **Eventual BG row** — the engine's latest prediction ("→ 128 by 3:40").
  Tap → the prediction detail screen (rich readout: range, IOB, COB, temp
  recommendation, input counts — today's PredictionView, kept for debugging).
- **IOB / COB row** — compact "2.1 U · 23 g", the algorithm's own accounting.
- **Loop row** — "Loop: open" / "Loop: closed · set 1.4 U/hr 4m ago" /
  "Loop: paused — BG stale". Tap → the loop toggle screen.
- Session rows (delivered, reservoir) as today.

Prediction refresh: the engine runs after every new BG sample (manual entry
now; sensor sample later) and on a 5-minute tick while the session is active,
so the eventual/IOB/COB rows stay current without the rider asking.

## Closed loop (standalone)

A `WatchAutoLoop` manager owned by the session (started/stopped with the loan,
OFF by default every session — closing the loop is a deliberate per-session
act on the toggle screen).

Cycle, every 5 minutes and after every new BG sample:

1. Newest BG sample ≤ 15 min old? If not: **skip** (lenient — no cancel, no
   new temp; the active temp expires on the pod's own clock). Surface
   "paused — BG stale" on the Loop row.
2. Run the existing engine (`predict`) — identical math to the display path.
3. `recommendation.basalAdjustment` nil → nothing to do (schedule fits).
4. Enact via the coordinator's existing temp-basal path — the same journal
   recording, proof caps, and loud-failure surfacing the manual dial uses.

### What we leverage from regular Loop (unchanged)

- The full prediction + `recommendedTempBasal` math, including the
  continuation logic (`lastTempBasal`) that avoids re-issuing equivalent temps.
- Therapy settings as the single source of bounds (max basal, suspend
  threshold — `recommendedTempBasal` already zero-temps below threshold).
- The journal → hand-back reconciliation — automatic doses reconcile to the
  phone exactly like manual ones; nothing new to build.

### Inherent safety we get for free (worth stating, not rebuilding)

- **Pod temp auto-expiry (≤30 min)** — the dead-man's switch. Watch dies,
  app crashes, BLE drops: schedule returns inside 30 minutes.
- **Pod-layer proof limits** (bolus cap, temp cap, duration allow-list) sit
  BENEATH the loop — a bug in the loop cannot exceed them.
- **Single-writer** — the loop only exists while the watch holds the pod;
  hand-back/revoke tears it down with the session.
- **Suspend threshold** — any predicted point below it → zero temp, already
  in the shared math.

### Simplifications vs phone Loop (deliberate)

- No auto-bolus / partial-bolus dosing strategies — temp-only.
- No mid-session carb entry, overrides, or schedule edits — session inputs
  are frozen at untether plus BG.
- No HealthKit / Nightscout / remote — the journal is the only ledger.
- One insulin model, one pod, one writer — no device abstraction layers.

## Manual vs. streamed BG — mirroring Loop's own behavior

Researched against the actual code (file:line below, workspace root
`LoopWorkspace-prediction`). Headline: **Loop already anticipates both no-live-BG
and dosing off manual entries, and our watch choices independently match it.**

### Stale / missing glucose → don't dose, let the temp expire

- One constant gates everything: `inputDataRecencyInterval = 15 min`
  (`Loop/LoopCore/LoopCoreConstants.swift:14`). This is the same constant
  `WatchAutoLoop.bgStalenessLimit` already uses.
- When newest glucose is older than 15 min, Loop's automatic-dose builder
  collects `LoopError.glucoseTooOld` and returns **before** computing any
  recommendation (`LoopDataManager.swift:1849-1851, 1912-1916`); `loopInternal`
  then skips `enactRecommendedAutomaticDose()` entirely
  (`LoopDataManager.swift:944-952`). **It does not proactively cancel the
  running temp basal** — the temp is time-boxed by the pump and left to expire.
  ⇒ This is exactly our **lenient** staleness ruling; no change needed.
- Distinct path: an *unreliable* (not stale) CGM reading cancels the temp only
  if it's ABOVE schedule (`LoopDataManager.receivedUnreliableCGMReading`
  `651-661`) — a low/neutral temp is left alone. Worth mirroring later if the
  G7 path surfaces reading-quality; not relevant to manual entry.
- Momentum uses the **same** 15-min window, no longer allowance
  (`GlucoseMath.momentumDataInterval = 15 min`, `GlucoseMath.swift:13-14`); it
  self-returns `[]` below 3 continuous same-provenance samples.

### Loop doses off manual entries — via a dedicated path that drops momentum + RC

- Manual BG is first-class: `predictGlucoseFromManualGlucose`
  (`LoopDataManager.swift:1462-1555`) inserts the manual sample as the
  prediction's **starting glucose**, then predicts with **`[.insulin, .carbs]`
  only** (line 1543-1554). `recommendBolusForManualGlucose` (1557-1569)
  recommends off that. Momentum and retrospective correction are deliberately
  omitted — positive momentum/RC for manual boluses is even feature-flagged off
  by default (`BolusEntryViewModel.swift:728`).
- **This is precisely `WatchPredictionEngine`'s config today** (`[.insulin,
  .carbs]`, manual BG as anchor). We arrived at the Loop-idiomatic answer.
- Flags: `wasUserEntered` = human-typed BG; `isDisplayOnly` = calibration/
  display value — orthogonal (`GlucoseSampleValue.swift:15-19`). Manual entries
  are `isDisplayOnly:false, wasUserEntered:true`. Momentum's own guard filters
  on `isDisplayOnly` + continuity + single provenance, **not** `wasUserEntered`
  (`GlucoseMath.swift:92-100`) — so a manual entry perturbs momentum only by
  breaking the 5-min cadence, and the clean exclusion is done by omitting
  `.momentum` in the dosing path, not by flag.
- A manual entry does **not** reset the CGM-staleness clock:
  `getLatestCGMGlucose` filters `wasUserEntered == NO`
  (`GlucoseStore.swift:527`). A manual BG is a one-shot dosing input, not a
  stream heartbeat.

### The rule for the watch (decidable per sample, no bespoke "data age" logic)

Switch effects on the **newest sample's provenance**, exactly as Loop splits its
two paths:

- **Newest sample is a manual entry (`wasUserEntered`)** → `[.insulin, .carbs]`
  (the `predictGlucoseFromManualGlucose` path). What we do now.
- **Newest sample is from the stream (CGM, once the G7 work lands)** → the full
  automatic-loop effect set including momentum + RC
  (`settings.enabledEffects`, `LoopDataManager.swift:1920`), giving phone
  parity when the data supports it.
- **Staleness gate reads CGM-only glucose** (mirror `getLatestCGMGlucose`): a
  manual entry keeps the display fresh but does not by itself re-arm the
  closed loop — that needs a live stream, or a deliberate manual-dose action.

This is the "adaptive by data age" option from the design fork, but grounded in
Loop's own two-path split rather than a watch-invented heuristic. **Not yet
implemented — awaiting the streaming-BG source; the manual path (what ships
today) is already correct.**

## Staged implementation

- **A1** — Show-mode HUD rows (BG/eventual/IOB-COB/loop) + tap-BG entry dial;
  carbs button reverts to disabled. Engine refresh on new sample + 5-min tick.
- **A2** — Prediction detail screen reachable from the eventual row (reuse
  PredictionView, minus the entry dial it no longer needs).
- **B1** — Loop toggle screen (per-session, default OFF) + `WatchAutoLoop`
  skeleton running the cycle and LOGGING what it would enact (shadow mode).
- **B2** — DONE (sim). Enactment behind the crown-confirm close. Structure
  mirrors Loop: `coordinator.enactTempBasal(unitsPerHour:for:)` = the watch's
  `PumpManager.enactTempBasal` (duration is a parameter, from the
  recommendation; duration 0 = cancel, rate 0 = bounded zero temp);
  `WatchAutoLoop.enactIfClosed` = the `DoseEnactor` analog (one enactTempBasal
  from `recommendedTempBasal`, once per prediction, 5-min recency guard).
  Manual `setBasalRate` (3h, 0→indefinite suspend) left as-is for rider hold —
  a deliberate open question if the loop and manual paths should unify.
  **Before real-person closed loop: revert TEMP-TEST-CAP (maxTempBasalRate
  3.0 → 1.0) and get explicit device go-ahead.**
- **Later** — voice entry ("Siri refresh") via App Intents on cellular watch;
  streaming-BG source replaces manual as primary; revisit caps.
