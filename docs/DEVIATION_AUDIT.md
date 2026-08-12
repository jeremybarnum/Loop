# Deviation audit — the watch port vs stock Loop

**Purpose.** Answer, mechanically rather than by impression, the question behind the refactor:
*how far has the watch port drifted from stock, and is every deviation conscious?* Started
2026-08-12. Phase 1 (quantitative) and phase 2 (semantic, dosing surface) are complete;
phase 3 (`PodLoanWatchController`) is not.

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

- **Phase 2 — DONE, see below.** No dosing defects found.
- **Phase 3: `PodLoanWatchController`** — 2,475 lines, no stock ancestor, no direct tests. A
  different question: not "does this match stock" but "is this the simplest state machine that
  satisfies the rulings."

---

# Phase 2 — semantic diff of the mirrored methods (2026-08-12)

**Result: no dosing defects. Zero dropped stock calls of the #44 class on the mirrored
surface.** Every candidate resolves as conscious, justified, or structurally moot — each for
a reason that was verified in the source, not inferred from a comment.

## Method

Rather than read 10 methods hoping to notice an omission, extract the set of called
identifiers from each stock method and its watch counterpart and diff them. Calls present in
stock and absent in ours are exactly the #44 failure shape (the `ensureCurrentPumpData` bug:
a stock call the port silently dropped). That produced 54 raw candidates across 7 method
pairs; triaging away type names, logging, and phone-only persistence (`StoredDosingDecision`,
`appendError`/`appendWarning`, `finishLoop`, notification `post`) left five worth verifying.

## The five, and how each resolves

**1. Dosing application factor — MOOT (verified).** Stock has `ConstantApplicationFactor\
Strategy`, `GlucoseBasedApplicationFactorStrategy`, `calculateDosingFactor`, and
`timeBasedDoseApplicationFactor` (`min(1, timeSinceLastLoop/5min)`); the watch has none of
them. This looked like the most dangerous finding available — a missing partial-application
factor means delivering the full recommendation where stock delivers a fraction.

It is moot, and the proof is at `LoopDataManager:1882`: `partialApplicationFactor` is passed
**only** to `recommendedAutomaticDose(...)`, the `.automaticBolus` branch. The `.tempBasalOnly`
branch immediately below takes no factor at all. The watch refuses `automaticBolus` outright
(`WatchLoopManager:2284-2292`, R16 — it returns a `configurationError` so a phone-pushed
setting is surfaced rather than silently downgraded), so it only ever runs the temp-basal
path, where stock applies no factor either.

Note `timeBasedDoseApplicationFactor` was NOT in the first candidate list — the initial grep
searched `calculateDosingFactor|ApplicationFactorStrategy|dosingFactor` and this identifier
matches none of them. It surfaced only when reading stock's `loopInternal()` for an unrelated
reason. A call-set diff finds dropped *calls*; it does not find dropped *multiplications*.

**2. Recency guards — PRESENT (verified, not trusted).** `glucoseTooOld`,
`invalidFutureGlucose` and `pumpDataTooOld` are thrown at `WatchLoopManager:1932/1936/1952`,
inside `predictGlucose`. Stock throws them at two sites — `predictGlucose` (:1282) and
`recommendBolusValidatingDataRecency` (:1542) — so the watch has one guard where stock has
two, and a comment in `recommendManualBolus` asserts the shared path covers it.

That assertion was checked rather than believed: `recommendManualBolus` does call
`try self.predictGlucose(...)`, so the guard fires on the manual path. Equivalent coverage,
one site instead of two.

**3. Suspend insulin-delivery effect — ABSORBED BY THE LEDGER (verified).** Stock maintains
`suspendInsulinDeliveryEffect` (:392), refreshes it (:1182), computes it (:1667-1716) and
appends it to the prediction (:1387). The watch has no equivalent, which initially reads as a
missing effect that would make the forecast run low.

It is structural. `SessionInsulinLedger:123-124` states the enactor models suspends as
**0 U/hr temps**, and `PodLoanWatchController:2075` confirms it — a zero-rate dose with a
duration is recorded as `.suspend` kind but delivered as a temp. Because the ledger nets temps
against the basal schedule (the whole subject of #112), a 0 U/hr temp already expresses the
withheld basal as negative delivery. Stock needs a separate effect precisely because its
DoseStore insulin effect is ABSOLUTE and a true pump suspend leaves no dose to net against;
the watch's book is basal-relative by construction and never issues a true suspend.

**4. `roundBasalRate` / `roundBolusVolume` — PRESENT.** Not dropped, just spelled differently:
the watch builds `rateRounder` (:2267) and `volumeRounder` (:2430) closures and passes them
into the same DoseMath entry points (:2309, :2442).

**5. `trustedTimeOffset` — MOOT, with a cosmetic residue.** Stock uses it at exactly one site
(`LoopDataManager:899`) to repair a `lastLoopCompleted` stranded in the future after a clock
jump, because a future value would otherwise block looping. The watch keeps
`lastLoopCompleted` (:1050) but only for the glance and diagnostics — it does not gate looping
on it. So the omission cannot stop the watch dosing. The residue is display-only: after a
forward clock jump the glance would show a nonsense "last loop" age until real time catches
up. Not worth a fix; recorded so it is not rediscovered as a bug.

## What phase 2 does and does not license

It licenses: *the mirrored dosing surface has not silently lost a stock behavior.* Combined
with phase 1's finding that the same surface is 0.91x stock's size, the dosing core is in good
shape and is **not** where a refactor should start.

It does not license any claim about the other 74 methods, about `PodLoanWatchController`, or
about behavior under concurrency. And note the method's own blind spot, demonstrated by
finding #1: a call-set diff cannot see a dropped arithmetic factor, only a dropped call. The
remaining phase-3 work needs reading, not grepping.

---

# Phase 3 — `PodLoanWatchController` (2026-08-12, PARTIAL)

2,476 lines, 74 functions, no stock ancestor, no direct tests. The question here is not "does
this match stock" but "is this the simplest state machine that satisfies the rulings."

## No cross-loan state leak (checked, negative result)

The controller carries **28 assignable instance vars across 6 phases** (`idle`, `requested`,
`takingOver`, `active`, `handingBack`, `revoked`). That is a large state space, and this
project has already been bitten twice by state surviving a loan boundary — the Round-3 fix
("chase/in-flight residue must not cross loan boundaries") and the `lastRevokedEpoch`
split-brain guard. So: which vars are never cleared when a loan ends?

Mechanically, 18 are not reset on any loan-ENDING path. Checking the risky ones individually,
they are all reset at loan START instead:

| var | reset at | why it would have mattered |
|---|---|---|
| `finalOfferSent` | `:490` (handleGrant) | a stale `true` would let a duplicate interim ack close the NEXT loan early — the Round-2 bug shape |
| `phoneSupportsInterimHandback` | `:484` (from the grant) | a phone downgrade would go undetected |
| `handbackResendCount` | `:1360` (hand-back start) | the resend ladder would start mid-way |
| `pendingInterruptedTakeoverEpoch` | `:1712` (on drain) | a stale relaunch-recovery epoch |

`chaseWorkItem`/`resendWorkItem` appear in the mechanical list only because they are
`.cancel()`ed rather than reassigned.

**So the invariant is: loan-scoped state is INITIALIZED AT GRANT, not cleared at close.** That
is legitimate and it is applied consistently. It is worth writing down because it is invisible
in the code — nothing names it — and the natural instinct (mine, an hour ago) is to look for
cleanup at the close path and conclude it is missing. Its one structural weakness: any path
that reads loan state WITHOUT a preceding grant sees defaults rather than stale values, which
is why `drainRecoveredIfNeeded` exists for the relaunch case.

## Where the accidental complexity actually is

| signal | count |
|---|---:|
| `queue.asyncAfter` | 14 |
| `DispatchWorkItem` | 9 |
| phases | 6 |
| assignable instance vars | 28 |

Two functions dominate: `attemptTakeoverRead` (226 lines, `:656`) and `handleGrant` (207
lines, `:397`). Next are `finalizeHandback` (91) and `sendHandbackOffer` (75).

**23 concurrent timing primitives in one class is the complexity, not the line count.** Every
watchdog, ladder rung, resend, chase, and backstop is an independent scheduled closure mutating
shared state on one queue. That is the part no test currently reaches (the phase machine is
untestable from `LoopTests`, per phase 1), and it is where the remaining WS1 debt lives
(cancel-mid-drain, revoke-during-drain).

## Not done

The design half — "is this the simplest state machine that satisfies the rulings" — needs
reading and judgment, not measurement, and it should be an ADVERSARIAL review rather than the
author's own. `/code-review ultra` is the right instrument. The two 200-line functions and the
timer set are where to point it.
