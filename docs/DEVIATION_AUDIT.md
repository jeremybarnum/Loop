# Deviation audit — the watch port vs stock Loop

**Purpose.** Answer, mechanically rather than by impression, the question behind the refactor:
*how far has the watch port drifted from stock, and is every deviation conscious?* Started
2026-08-12. Phase 1 (`WatchLoopManager`, quantitative) is complete; phases 2 and 3 are not.

**Baseline.** The phone's `Loop/Managers/LoopDataManager.swift` is upstream through
`7bf62f56` (Bastiaan Verhaar, 2025-11-22) with exactly two of our commits on top
(`85c65e78` loan instrumentation, `0b4a5f51` the hand-back item-1 work). It is therefore a
clean stock reference, and the two known deltas are accounted for.

---

## Headline: the dosing policy is NOT bloated. The file is.

The impression that started this audit was "`WatchLoopManager` is 3,406 lines against stock
`LoopDataManager`'s 2,699 — 26% bigger while doing less." **The first half is true and the
second half is false, and the conclusion drawn from it was wrong.**

Measured, counting code lines only (blank and comment lines excluded):

| path | stock | ours | ratio |
|---|---:|---:|---:|
| The 10 mirrored policy methods | 382 | 347 | **0.91x** |
| Loop entry + effect refresh (`loop` + `loopInternal` + `update(for:)` vs `loop` + `updateCachedEffects`) | 219 | 154 | **0.70x** |

The dosing math and its orchestration are **leaner than stock**, not fatter. Per method:

| method | stock code | ours code | ratio |
|---|---:|---:|---:|
| `predictGlucose` | 111 | 65 | 0.59x |
| `updatePredictedGlucoseAndRecommendedDose` | 152 | 90 | 0.59x |
| `clearCachedInsulinEffects` | 5 | 5 | 1.00x |
| `isBasalRateScheduleOverriden` | 6 | 6 | 1.00x |
| `enactRecommendedAutomaticDose` | 24 | 29 | 1.21x |
| `computeRetrospectiveGlucoseEffect` | 16 | 20 | 1.25x |
| `recommendManualBolus` | 30 | 40 | 1.33x |
| `updateRetrospectiveGlucoseEffect` | 25 | 37 | 1.48x |

Nothing here is alarming. The two 0.59x entries are ours being smaller because the watch has
no potential-bolus/potential-carb arms — a real scope reduction, correctly reflected.

**A measurement trap worth recording, because it produced a wrong number first.** Stock splits
`loop()` (a 12-line lock wrapper) from `loopInternal()` (25 lines), and does its effect refresh
in `update(for:)` (182 lines). Comparing our merged `loop()` against stock's `loop()` alone
gives 4.25x and looks damning; including `update(for:)` gives 0.70x and reverses it. Any
name-matched comparison against this file must account for stock's wrapper split.

## So where do the extra 700 lines go?

`WatchLoopManager`'s 84 functions span 2,213 lines. By responsibility:

| category | funcs | lines | share |
|---|---:|---:|---:|
| other watch plumbing | 21 | 718 | 32.4% |
| **mirrored stock policy** | 10 | 572 | 25.8% |
| **instrumentation / diagnostics** | 20 | 420 | 19.0% |
| loan / ledger | 19 | 213 | 9.6% |
| glance / HUD | 6 | 210 | 9.5% |
| bench & test tools | 2 | 62 | 2.8% |
| alert plumbing | 6 | 18 | 0.8% |

The file is bigger than stock's `LoopDataManager` because **it does more things**, not because
the policy is fatter. On the phone those responsibilities live in separate classes:
CGM ingestion in `DeviceDataManager`, alerts in the alert manager, and glance/HUD does not
exist at all. Only 10 of 84 methods share a name with stock — the rest are either mirrors of
*other* stock classes or genuinely novel.

## The two findings that are real

**1. STRUCTURAL — `WatchLoopManager` is a God object.** It absorbs stock's `LoopDataManager`
+ `DeviceDataManager`'s CGM duties + the glance/HUD builder + the loan/ledger surface. That is
the refactor target, and it is a **split-by-responsibility job, not a rewrite-the-math job** —
which is a much smaller and much safer change than "refactor the dosing code", and it needs a
different kind of test net (the seams between the new types, not the policy).

**2. COMMENT DENSITY — 8.8x stock.** Across the 10 mirrored methods: stock carries 19 comment
lines, ours carries 167. This is the one place the "bloat" instinct is quantitatively correct,
and it is about prose, not code.

Proposed standard, to be applied file by file: **a comment earns its place if it would stop
someone reverting the line** — it records a decision, a defeat, or a measured fact. Narration
of what the code plainly does goes. Project-internal shorthand (`WS1`, `R22`, `C5`, `E4`,
"layer 1/2", "the ladder") is expanded on first use in code, or the narrative moves to docs;
today none of it is resolvable without the rulings register open.

## Also visible, with a ruling already attached

- **Instrumentation is 19% of the file (420 lines).** Much of it earned its keep — the
  prediction breakdown and IOB decomposition found real bugs. Some is stale. Worth a pass
  under the standing preference for MORE diagnostics, i.e. prune the dead, keep the live.
- **Bench tools (62 lines)** — `e5FireRandomTempIfEnabled`, `simIngestPhoneGlucose`. Already
  tracked for pre-production removal (#62, #79).
- **E4 machinery** — default OFF under R31, deletion gated by #96 on one long OFF run.

---

## Not yet done

- **Phase 2: semantic diff of the 10 mirrored methods.** The line counts say the shapes match;
  they do NOT say the behavior matches. Each mirrored method still needs a read-through against
  its stock counterpart, classifying every delta as *conscious and justified*, *conscious but
  stale*, or *drift*. This is where a dropped stock call of the `ensureCurrentPumpData` class
  (#44) would surface.
- **Phase 3: `PodLoanWatchController`** — 2,475 lines, no stock ancestor, no direct tests. A
  different question: not "does this match stock" but "is this the simplest state machine that
  satisfies the rulings."
