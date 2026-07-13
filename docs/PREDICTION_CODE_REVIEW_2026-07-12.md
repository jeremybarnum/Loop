# Watch Closed-Loop Code Review — 2026-07-12

Automated review of the prediction component (`e129d6cf..HEAD`, 37 commits) for
Loop faithfulness, reinvent-the-wheel, inconsistency, and closed-loop safety.
Findings for discussion; nothing changed. Ranked; phone = canonical Loop.

## Top 4 to discuss first
Enacted insulin can differ from Loop's proven path or from what the screen shows:
**#1 missing IOB clamp**, **#2 manual-suspend override**, **#4 silent proof-cap
clamp vs displayed rate**, **#13 what the real cap should be**.

## Divergences from Loop (silent)

**1. Closed loop lacks the phone's IOB clamp (`additionalActiveInsulinClamp`).** HIGH.
- Watch `WatchPredictionEngine.run` → `generateRecommendation(.tempBasal)`
  (`LoopKit/.../LoopAlgorithm.swift:117-130`) calls `recommendedTempBasal`
  **without** `additionalActiveInsulinClamp`.
- Phone `LoopDataManager.swift:1993-2007` passes `iobHeadroom = maxBolus*2 - IOB`
  (`:1952-1953`); `DoseMath.swift:425-428` caps the temp so total IOB can't
  exceed 2×maxBolus.
- The watch can drive IOB past the phone's hard ceiling. Design ruling #4's
  "same bound as phone Loop" is inaccurate — phone applies max-basal AND the IOB
  clamp. Masked today by the low proof cap; unmasked if the cap rises. Either
  wire `iobHeadroom` through `generateRecommendation`, or document dropping it.

**2. Closed loop overrides a manual suspend; phone blocks auto-dosing while suspended.** HIGH.
- Phone: `enactRecommendedAutomaticDose()` returns `LoopError.pumpSuspended`
  and does nothing when suspended (`LoopDataManager.swift:2044-2046`).
- Watch `WatchAutoLoop.loopCycle` (`WatchAutoLoop.swift:213-224`) has no suspend
  check. Rider manually suspends with loop closed → next tick either un-suspends
  the pod or fails loudly every cycle. Not in the design doc.

**3. Enactment marked "done" before success confirmed — no retry within the prediction.** MEDIUM.
- Watch sets `lastEnactedPredictionDate = output.date` (`WatchAutoLoop.swift:219`)
  BEFORE `enactTempBasal` and never re-checks the result; a failed enact waits
  ~5 min. Phone only clears the recommendation on `delegateError == nil`
  (`LoopDataManager.swift:2058-2060`) → retries next loop.
- Compounding: `runPodCommand` silently no-ops when `busy`
  (`WatchPodLoanCoordinator.swift:579`). Bounded by 30-min pod expiry, but the
  optimistic advance is a real difference.

## Reinvention / inconsistency risks

**4. Enacted temp silently clamped below the recommended/displayed temp.** MED-HIGH.
- Recommendation + HUD row + `CorrectionMath` all show the therapy-max-bounded
  rate (`WatchPredictionEngine.swift:299,93`; `WatchAutoLoop.swift:183`), but
  `enactTempBasal` re-caps at `maxTempBasalRate` (`WatchPodLoanCoordinator.swift:567`,
  1.0 intended). "would set 2.50" → pod gets 1.00. Proof floor is good; the
  display/enact mismatch is a transparency + validation hazard. Surface the
  effective (proof-capped) rate.

**5. Three independent `WatchPredictionEngine` instances re-introduce the drift the store removed.** MEDIUM.
- Store exists to kill header/row drift (`WatchPredictionStore.swift:5-12`), but
  `BGEntryView` (`PredictionView.swift:23,100`) and `PredictionDetailView`
  (`:131,210`) each run independent full predictions. A manual Log runs TWO full
  predictions + duplicate WC pulls. `PredictionDetailView`'s eventual can differ
  from the HUD "Eventual" row. Route both screens through the store.

**6. `CorrectionMath` re-derives DoseMath by hand for display.** LOW-MED.
- `WatchPredictionEngine.swift:77-108` recomputes the temp; its own comment
  (`:68-76`) says it ignores interim-low/ramped-target/suspend-threshold, so it
  can disagree with `recommendedTempBasal`. OK as an explicitly-approximate
  teaching view; standing drift risk — make sure readers know it's not enacted.

**7. Decision classification duplicated.** LOW. `WatchAutoLoop.Decision`
(`:178-184`) and `coordinator.enactTempBasal` (`:562-572`) independently map
duration==0→cancel / rate 0→suspend. Two mappings that must stay in sync; shared
helper.

**8. Trend-arrow slope reimplemented.** LOW. `HUDInterfaceController.trendSymbol`
(`:229-243`) hand-rolls thresholds. Legit (watch samples carry no trend), but
`GlucoseTrend` exists; revisit for streaming BG.

## Closed-loop safety notes

**9. `loopCycle`'s 5-min recency guard is a no-op.** LOW. `output.date` is `Date()`
at recompute time, always ~0s old (`WatchAutoLoop.swift:218`); guard can't trip.
Harmless but not protecting what the comment claims.

**10. Background refreshes re-stamp the anchor BG to "now."** LOW.
`WatchPredictionEngine.swift:327-330` anchors at now from the last sample even on
`storeEntry:false`; only the staleness gate sees the real age. Small impact
(no momentum, 15-min gate), but the prediction never ages its own anchor.

**11. Lenient staleness (no proactive cancel) is faithful.** POSITIVE — matches
phone (`LoopDataManager.swift:1849-1851, 944-952`); pod expiry backstops.

**12. The oscillation fix (enact on `didLoopTick` only) is sound and complete.**
POSITIVE — verified. Only glucose/phase/throttled-heartbeat post `didLoopTick`
(`WatchPredictionStore.swift:76,108,190-194`); carb/journal/settings post
`didUpdate` only. Dedup by `output.date`. No feedback path remains.

## Deliberate choices worth re-confirming

**13. TEMP-TEST-CAP 3.0→1.0 — but is 1.0 the loop ceiling?** With a 1.0 proof cap,
the loop is bounded far below therapy max, contradicting ruling #4. Decide
whether 1.0 is the loop ceiling or just the manual-dial ceiling; if the former,
the loop's real bound is 1.0 and #1/#4 change character.
(`WatchPodLoanCoordinator.swift:241-245`.)

**14. Manual entries currently re-arm the closed loop.** Design end-state says
only a live stream should re-arm (CGM-only staleness gate). Today
`glucoseSamplesDidChange` fires `loopWorthy:true` for manual entries
(`WatchPredictionStore.swift:75-77`) → the closed loop doses off typed BGs. Doc
marks CGM-only gate "not yet — awaiting streaming BG"; confirm acceptable for
the manual-only stage.

**15. `[.insulin,.carbs]`, temp-only.** Documented, faithful to
`predictGlucoseFromManualGlucose`. Revisit at streaming.

## LoopKit changes — checked
- Target-range decode fix (`6e018f62`) correct + important (upper bound was built
  from minValue, collapsing the range). Watch live path built the range correctly
  already, so it was never exposed, but the fix is right and now test-pinned.
- precondition→throw in `generatePrediction` (`LoopAlgorithm.swift:150-166`) is
  right for the watch — misaligned handover → recoverable error, not a crash.
