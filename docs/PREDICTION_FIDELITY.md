# Watch (Sport Mode) glucose-prediction fidelity vs stock Loop

A2 verify-and-document pass, 2026-07-28. Compares the WATCH's dosing-prediction path to
stock Loop's phone path, line-by-line. Findings gathered by an Explore agent, then
spot-verified against source (the #46 wiring, the stale comment, and the #47 gap were each
re-read by hand). Path keys: **W** = `Loop/WatchApp Extension/StockLoop/WatchLoopManager.swift`,
**P** = `Loop/Loop/Managers/LoopDataManager.swift`.

## Effect inventory (what the watch feeds `predictGlucose`)

Watch `predictGlucose(includingPendingInsulin:)` (W:1105) assembles exactly four effects,
unconditionally — no `PredictionInputEffect` gating, no `.suspend`, no
`includingPositiveVelocityAndRC` arm:

| Effect | Watch site | Source |
|---|---|---|
| Carb / COB | W:1145 | `carbStore.getGlucoseEffects` (W:1001, cached in updateCachedEffects) |
| Insulin / IOB (pending-aware) | W:1149 | `doseStore.getGlucoseEffects` (W:956; pending variant basalDosingEnd:nil W:970) |
| Momentum | W:1153 | `linearMomentumEffect(requireContinuous: false)` W:931, 25-min window W:775/925 |
| Retrospective correction | W:1157 | `retrospectiveCorrection.computeEffect` W:1079 |
| Combine | W:1159 | `LoopMath.predictGlucose` (same primitive as phone P:1358) |

Consumed by the automatic loop at W:1234 → `recommendedTempBasal` W:1272.

## Stock comparison

Stock's automatic loop predicts with `PredictionInputEffect.all` = `[.carbs, .insulin,
.momentum, .retrospection]` (RC on by default), i.e. the **same four**. Carb, insulin,
counteraction, IOB, and the RC math are computed the same way (RC math identical; watch
guard-throws on nil schedules where the phone force-unwraps). The only genuine algorithmic
divergence is momentum, and it is intentional.

## Divergence verdicts

| Claim | Verdict | Notes |
|---|---|---|
| **Momentum = 25-min window + relaxed continuity** | **Confirmed, intentional** | Sport Mode change (W:775/918-924, GlucoseMath.swift:84-92). Stock is 15-min + `requireContinuous:true`. All other gates (≥3 samples, single provenance, no calibrations, 4 mg/dL/min cap) unchanged. |
| **#46 — watch hardcodes Standard RC, ignores the phone's Integral toggle** | **REFUTED — already wired** | Grant carries it (LoanProtocolV2:304), phone populates from `UserDefaults.integralRetrospectiveCorrectionEnabled` (PodLoanPhoneController:460), watch applies at takeover (PodLoanWatchController:389 → WatchLoopManager.setIntegralRetrospectiveCorrection, W:450). Frozen-at-grant (set once), not live-re-read — functionally equivalent for a loan; degrades to Standard only if an old phone sends `nil`. |
| **#47 — recommended bolus not wired to the watch's prediction** | **CONFIRMED — real gap** | The carb/bolus UI reads the phone's `recommendedBolusDose` (CarbAndBolusFlowViewModel:57/98) or round-trips to the phone (:137/:163). The watch's own prediction-based `recommendManualBolus` (W:1337) has NO UI callers — dead code w.r.t. the flow. So during a loan the recommendation is nil/stale/hangs (see RADIO_STACK_AUDIT.md:34-40). Delivery IS loan-aware; only the recommendation is not. |
| **Watch `predictGlucose` signature differs from stock** | **Confirmed, immaterial for the automatic path** | Watch has one param (`includingPendingInsulin`); stock adds `using inputs`, `potentialBolus`, `potentialCarbEntry`, `includingPositiveVelocityAndRC`. The automatic loop uses neither the potential-entry arms nor velocity/RC suppression, so no divergence there — but #47, if built, needs the watch `predictGlucose` extended to express a potential carb/bolus. |

## Open items surfaced

1. **Stale comment (cleanup)** — W:1088-1090 claims the watch "may not track the phone's
   Integral toggle — a real prediction divergence." Inaccurate since the 389/460 wiring.
   The instrumentation itself (logs Integral vs Standard, W:1091) is correct; only the
   comment misleads. → fix the comment.
2. **Ordering caveat (verify, low-risk)** — `setIntegralRetrospectiveCorrection` is dispatched
   async onto `dataAccessQueue` at takeover (W:451). Correctness relies on it enqueuing before
   the first prediction on that serial queue. The serial-queue design intends this, but a hard
   ordering guarantee was not proven. Worst case at a race: the first cycle uses Standard, then
   corrects — bounded and self-healing.
3. **#46 ticket** — retire/close: already implemented and committed. #45 (counterfactual
   contribution breakdown) is separate and still open as instrumentation, not a divergence.
4. **#47** — deferred (Jeremy 2026-07-28). The fix has a clear shape: wire the flow to the
   watch's existing `recommendManualBolus` (W:1337), extending `predictGlucose` to accept a
   potential carb/bolus.
