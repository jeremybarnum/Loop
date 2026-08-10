# Test coverage plan — the net under the Loop-idiomatic refactor

**Status: APPROVED (Jeremy 2026-08-10), execution GATED.** Do not start until the
fresh-sensor G7 check passes (see "The gate" at the bottom). Jeremy is reading the Sport Mode
code and will produce a list of files he wants rewritten; item 3 is scoped to that list.

**Why this exists.** Coverage is inverted relative to risk. The loan state machine —
`PodLoanWatchController.swift` (2,398 loc) and `WatchLoopManager.swift` (3,225 loc) — has no
dedicated test file; `GlanceController.swift` (1,436 loc) has zero tests. Meanwhile
`LoanReconciler` (367 loc) and the protocol models are well covered. Every bug that cost a
release this week (carb-delete authorship ×2, phantom IOB, stranded bid, dead-man deviation,
enact-vs-reclaim race) lived in the untested middle; the one store-level test written after
the fact failed in 0.02 s and named the cause three field releases had missed. The refactor
must not proceed over that hole.

Current inventory: 389 test funcs in LoopTests, ~79 Sport-Mode-specific
(`LoanProtocolV2Tests` 22, `LoanBooksHarnessTests` 21, `WatchStoreEffectsTests` 20,
`PodLoanPhoneControllerTests` 16, `WatchDosingLimitsTests`). The phone controller is testable
because it has a `Deps` struct of ~18 injected closures; the watch controller reaches for the
world directly — **39 bare `Date()` calls and 11 `UserDefaults.standard`** — which is what
makes its timing behavior (watchdog windows, bolus thresholds, resend cadence, recency gates)
untestable today.

---

## The items, in execution order

### 1. Ship-script test gate (~minutes) — do first
`Scripts/testflight.sh` runs the Sport-Mode suite and **refuses to archive on failure**:

```
xcodebuild -workspace LoopWorkspace.xcworkspace -scheme LoopWorkspace \
  -destination 'platform=iOS Simulator,id=BE1EB8F5-C98F-472D-B910-858C3F2F9632' \
  -derivedDataPath ../.dd-sim ONLY_ACTIVE_ARCH=YES test \
  -only-testing:LoopTests/LoanProtocolV2Tests \
  -only-testing:LoopTests/LoanBooksHarnessTests \
  -only-testing:LoopTests/WatchStoreEffectsTests \
  -only-testing:LoopTests/PodLoanPhoneControllerTests \
  -only-testing:LoopTests/WatchDosingLimitsTests
```

Insert before the ARCHIVE step; `set -euo pipefail` already aborts on failure. Rationale: we
commit locally and do not push, so GitHub CI would test stale code — the ship script is the
one choke point every build passes through. (Deliberately NOT GitHub Actions; see Cuts.)

### 2. Clock + UserDefaults injection (~1 hour) — PURE MECHANICAL COMMIT
In `PodLoanWatchController` (and `WatchLoopManager` where timing matters):
`var now: () -> Date = Date.init`, every `Date()` → `now()`; same pattern for a
`defaults` seam. This mirrors stock idiom exactly (`LoopDataManager.now()`,
`CarbStore.test_currentDate`) — the refactor goal and the testability goal are the same
change here.

**Discipline (non-negotiable): this commit contains NOTHING else.** It is a 39-site edit to
the most safety-critical file in the project performed *before* the net exists; that is
acceptable only because every hunk is `Date()` → `now()`, identical by construction and
compiler-checked. No opportunistic cleanups, no renames, no "while I'm here." Review it as a
diff where every hunk looks the same.

### 3. Characterization tests, SCOPED to the refactor targets
For each file on Jeremy's rewrite list (and only those), pin current behavior through the
public surface. **Characterization records what the code DOES, not what it should do** —
correct-and-frozen beats correct-and-unverifiable during a refactor. Suspected-wrong behavior
gets pinned too; fixing it is a separate commit after the refactor, so "moved" and "changed"
never share a diff.

**Assertion surface — this determines whether the net is worth anything:**
- PIN: phase transitions, journal event sequences (kind/seq/amount), store contents after
  operations, sent-message semantic fields, dose decisions (rate × duration), `GlanceUIState`
  outputs.
- NEVER PIN: log strings, internal call ordering, private structure, exact timestamps.
  Those are what the refactor changes; if the suite breaks spuriously and gets re-recorded
  to pass, it validates nothing while feeling like protection.

For the glance: no snapshot tests. The state builders are already `static + pure`
(`GlanceController.swift`, "State builders" MARK) — assert on their outputs, especially the
honest-state rules (stale never renders fresh, provenance visible, transient precedence).

### 4. Sabotage check (~minutes per area) — verify the net catches anything
After characterizing an area, plant one deliberate bug (flip a guard, drop a journal event,
skip a wipe), confirm at least one test goes RED, revert. A characterization test that passes
both before and after a planted bug is decoration. This is the standing failure mode of
AI-written tests; check the author's work.

### 5. Two-sided contract test (the one genuinely new build)
Watch controller and phone controller in one process, joined by a fake transport (the watch's
`send` closure and the phone's `Deps` are both already seams): grant → seed → journal →
drain → phone commit → ack, asserting both ends' books. Burn down the **already-enumerated**
WS1 test-debt list — `KNOWN_RESIDUALS.md` item 16: released-flag decode (absent key), interim
no-state-change commit, finalize-on-empty-drain, cancel mid-drain, revoke-during-drain,
seq-gap cursor cap — rather than inventing scenarios. Feasible today: LoopTests already
compiles the watch-side files into the iOS test host (that is how the books harness works).

### 6. Fault variants, folded into the existing harness (incremental)
Parameterize existing scenarios with the failure taxonomy that has actually occurred:
timeout, certain refusal (`unfinalizedBolus`), uncertain command, unreachable phone,
mid-operation cancel. No generic fault-injection framework. Continue the standing practice —
**every field incident becomes a harness test while the log is fresh** (this is what
`LoanBooksHarnessTests` is; its header describes exactly this method). That practice IS the
log-replay idea at 5% of the cost.

---

## Refactor shipping discipline (applies once execution starts)
- Behavior-preserving refactors ship as their OWN TestFlight builds — never bundled with
  features or fixes. A pure-refactor build that misbehaves on the wrist bisects itself.
- "Moved" and "changed" never share a commit.
- The suite runs green before every archive (item 1 enforces this).

## What the net does NOT cover — and the rule that follows
Everything in LoopTests runs the watch files in an iOS test host. It tests logic, not the
watchOS runtime: app suspension, keepalive survival, pre-scheduled notification delivery,
real WCSession semantics, and all radio timing remain FIELD-ONLY (the overnight of 2026-08-09
proved the dead-man there better than any test could). Consequence for the refactor:
**logic may be rewritten under the net; code that touches the watchOS runtime — keepalive,
notification arming, WCSession activation — is MOVED, not rewritten**, because nothing below
the wrist can detect a break in it.

## Cut, deliberately (do not resurrect without a new reason)
- **Log-replay infrastructure** — input-reconstruction from prose logs is real machinery that
  can itself be wrong, replaying an oracle that includes the old code's bugs. The distilled-
  incident harness is the efficient form.
- **UI snapshot tests** — brittle across Xcode/device variants; glance layout bugs are
  instantly visible on the wrist; the safety-relevant part is the pure state builders (item 3).
- **GitHub Actions CI** — we don't push; it would test stale code. Revisit only if pushing
  becomes part of the flow.
- **Coverage-percentage targets** — coverage is a map of the unvisited, never a goal
  (Goodhart). Run `-enableCodeCoverage YES` for the map if useful; set no number.

---

## The gate
Execution starts only after the fresh G7 sensor confirms **no regression on direct-G7**:
a loan on build 261 with the new sensor showing direct reads landing in ≥ the A/B benchmark
(8/8 five-minute windows, ages < 10 s, phone BT on). While at it, the #15 experiment if
desired: BT off/on/off ~30 min each — direct-G7 tracking the toggle is a structural finding,
independent of this plan. If 261 regresses on a healthy sensor, that investigation preempts
this plan.

*Anchors verified 2026-08-10: Date()/UserDefaults counts via grep on PodLoanWatchController;
Deps struct at PodLoanPhoneController.swift:44-; state-builders MARK in GlanceController;
WS1 debt list in KNOWN_RESIDUALS.md §16; incident-replay method in LoanBooksHarnessTests
header. Line numbers drift; the names are the stable anchors.*
