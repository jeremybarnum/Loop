# production-merge → next-dev port ledger

A running list of changes made on `production-merge` that the next-dev port needs to **assess**,
not necessarily to copy. Some are fixes that should follow; some are decisions that may be made
differently on a newer base; a couple are deliberate non-changes recorded so nobody re-litigates
them from scratch.

**Both lines can read this.** It lives in the Loop repo on `production-merge`. From the next-dev
clone, without checking anything out:

```
git fetch origin && git show origin/production-merge:docs/NEXT_DEV_PORT_LEDGER.md
```

**Keep it current.** Anything landed on `production-merge` that touches shared behaviour goes here
when it lands, not later. An entry costs a minute; rediscovering a decision costs an afternoon.

Status vocabulary: **SHIPPED** (on production-merge now) · **PENDING** (ruled, not built) ·
**OPEN** (needs a ruling) · **NON-CHANGE** (considered and deliberately not done).

---

## SHIPPED — predicted-low warnings on the wrist

Loop `e44ac193`, superproject `15d8feb`. Ruled option A: the watch computes all three predictions
rather than a reduced set.

The watch owns the predicted-low warning whenever it owns the pod, and the phone stands down.
That is not tidiness: during a loan the phone's books lack every dose the watch has enacted since
the grant, so a phone-side warning is wrong in BOTH directions — it over-warns while the wrist is
low-temping, and under-warns after a wrist bolus.

- `WatchApp Extension/StockLoop/WatchLowGlucoseWarning.swift` — evaluator: metrics, the 8-cell
  truth table, rescue carbs, message builder, gating. Pure, injectable clock, table-tested.
- `WatchApp Extension/StockLoop/WatchDiagnosticLog.swift` — watchOS shim so the phone's
  `ObservedAbsorptionManager` / `ObservedAbsorptionSettings` compile into the watch target
  **unmodified**. One shared copy of the absorption algorithm, no wrist fork.
- `WatchLoopManager` — additive only. `predictGlucose()` (the dosing path) is untouched; the
  warning curves come from a separate read-only mirror, the same idiom already used for the
  leave-one-out counterfactuals. Evaluation runs LAST in the cycle, after the enact returns, so it
  cannot add latency ahead of a pod command.
- `LoanGrant.lowBGWarningSettings` (optional; nil = phone said nothing = wrist stays silent) and
  `HandbackOffer.lastLowBGWarningAt` (snooze anchor home again, only ever moved forward).
- Phone stands down via `LoopDataManager.podOnLoanProvider`, the same predicate the Loop Failure
  ladder already uses.

**For next-dev to assess:** whether the phone/watch stand-down seam still holds on the new base,
and whether the warning belongs in the algorithm package rather than bolted to the watch loop.

## SHIPPED — night low-BG warnings had never fired

The gate read `com.loopkit.Loop.nightwarningEnabled`; the Alert Management toggle writes
`com.loopkit.Loop.nightLowBGNotificationsEnabled`. Nothing in the app ever wrote the former, and
`bool(forKey:)` answers false for an unwritten key — so the overnight branch was closed no matter
how the switch read. Now reads the accessor the toggle writes.

**Default flipped to OFF.** No build had ever delivered an overnight warning; defaulting it on
would have turned a bug fix into a run of 22:30–06:30 alerts nobody opted into.

**For next-dev:** if this feature is ported at all, carry the fix, not the typo.

## SHIPPED — fourth warning class removed from both devices

`considerEditingCarbsUpToAvoidUnnecessarySuspend` could never fire. It required the
observed-absorption prediction NOT to cross, and the "P2 does not cross, no warning needed" guard
returns before the truth table is consulted. Making it reachable would have needed its own timing
anchor (there is no P2 crossing to measure from) and its own snooze, or the advisory would eat a
real low warning. Removed rather than resurrected — it was the only class not about a low.

**For next-dev:** do not "restore" it from an older base. The tests pin the resulting silence.

## PENDING — automaticBolus is refused every cycle (task #133)

Field-confirmed on the first live T1D run. A user on `automaticDosingStrategy = .automaticBolus`
gets `configurationError(...)` on EVERY cycle: the watch holds the pod and never doses, and the raw
Swift error renders verbatim on the wrist.

**Ruled:** not supporting automaticBolus on the watch for now. The strategy goes to
`tempBasalOnly` for the loan and is automaticBolus again when the pod returns.

**Recommended implementation:** override the strategy only in the GRANT SNAPSHOT; do not flip the
phone's stored setting. Nothing on the phone changes, so there is no restore step that can fail —
and a restore that never runs (relaunch mid-loan, force reclaim, dead watch, app killed) would
leave the user silently on tempBasalOnly permanently, which is a lasting therapy change from a
bookkeeping miss.

**For next-dev:** the newer base may support automatic bolus on the watch outright, which would
make this moot. Assess before porting the workaround.

## PENDING — carb deleted on the watch did not reach the phone (task #134)

Entry deleted on the wrist, still present on the phone. No harm in the observed case (the entry
was ~22 h old, past the carb horizon, and both devices agreed on COB), but the delete did not
propagate. Leading hypothesis: the entry predated the loan window, so the tombstone path did not
scope to it. Untraced — the uploaded logs end ~90 s before the delete.

**For next-dev:** carb identity and delete propagation is fork surface (`R36`/#120 wired carb
identity into the store; the LoopKit fork carries `deleteCarbEntrySkippingAuthorshipCheck`). Any
new base needs the same question asked, not the same patch applied.

## OPEN — the loop dead-man never arms when the watch never completes a cycle

`LoopStallWatchdog.refresh()` fires only on a COMPLETED cycle. A loan whose cycles all fail
therefore never arms the alert whose entire purpose is "the watch is holding the pod and is not
looping." Structurally silent in exactly the failure it exists for. Independent of the
automaticBolus ruling and worth fixing on whichever base survives.

## NON-CHANGE — absorptionTimeOverrun stays at 1.5

Jeremy has historically run 1.0. That change lives on commit `86bc2325` in the LoopKit fork,
reachable only from six old branches (`2.07_working`, `notification2.0`, `notifications2.0`,
`notify_2.05`, `notify_2.06`, `workingMay1`) and it never came forward into this lineage.

It is NOT a carb-model preference in isolation: the overrun sets
`maxAbsorptionTime = declaredTime × overrun`, which feeds the observed-absorption ratio, which
feeds the low-BG warning's P2 and P3. Changing it changes which warning class fires and what
rescue-carb number it quotes. If it is ever set back to 1.0, do it as its own build so the wrist
warnings are evaluated against one absorption model at a time.

## Structural note — the LoopKit fork is load-bearing

Not optional for either line. Beyond the carb-model question, the fork carries:
`PumpConnectionLendable` and `isConnectionReady` (the whole lend/reclaim capability),
`CarbStore.addCarbEntry(_:syncIdentifier:)`, `deleteCarbEntrySkippingAuthorshipCheck` plus the
second-authorship-gate fix, `linearMomentumEffect(requireContinuous:)`, the notification
infrastructure the low-BG and pre-bolus features depend on, therapy settings profiles, and the
target-membership commits that put DoseMath, LoopAlgorithm and PumpManager into `LoopKit-watchOS`
at all. Strip the fork and the watch app does not compile, never mind dose.
