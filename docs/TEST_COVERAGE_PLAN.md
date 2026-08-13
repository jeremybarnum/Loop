# Test coverage plan — the net under the Loop-idiomatic refactor

**Status: APPROVED (Jeremy 2026-08-10). GATE CLEARED and EXECUTION STARTED 2026-08-11.**
The G7 gate passed on build 264 (adoption in one ride, sensor identity persisted across
relaunch, clean loop cycles, carbs + bolus field-tested). Item 3 still waits on Jeremy's
rewrite-target list.

## Execution log (2026-08-11, overnight)

| Item | State | Notes |
|---|---|---|
| 1. Ship-script test gate | **DONE** | In `Scripts/testflight.sh`, exit 67 on failure. Sabotage-verified. |
| 2. Clock + defaults injection | **DONE** | 38+20 clock sites, 11 defaults sites, 3 seams. Pure mechanical commit. |
| 3. Characterization | BLOCKED | Needs Jeremy's rewrite-target list. |
| 4. Sabotage check | **DONE for what exists** | Ran against the gate, the reconciler, and the new §16 tests. Findings below. |
| 5. Two-sided contract test | **DONE** | `LoanTwoSidedContractTests` (5 tests). 5 of 6 §16 items closed, 1 partial, 1 blocked — see the 2026-08-12 correction. |
| 6. Fault variants | **DONE** | Folded into `LoanTwoSidedContractTests` (3 more tests, 8 total). |

### Corrections to this plan, found by executing it

**Item 5's premise was false.** The plan says "LoopTests already compiles the watch-side
files into the iOS test host (that is how the books harness works)." It does not.
`PodLoanWatchController` and `WatchLoopManager` are members of the **`WatchApp Extension`
target only**; `LoopTests` cannot see them. `LoanBooksHarnessTests` works because
`LoanProtocolV2` is in BOTH targets and the harness hand-rolls its own driver.

Consequence: a genuine two-sided test needs one of
(a) adding the watch files to `LoopTests`;
(b) a watchOS unit-test target (clean, but new infrastructure); or
(c) keep testing the phone + protocol halves and hand-roll the watch half, as the books
    harness already does.

### Item 5 resolution (2026-08-12)

Built as **(c) plus one extraction**, after MEASURING option (a) rather than guessing at it.

The measurement corrects this plan's own earlier reasoning. The claim was that the watch
files are "`WCSession`/`SportLog`/watch-alert coupled, so this cascades and may not compile
for iOS". The coupling is real but that is the wrong account of it:
`PodLoanWatchController` touches WatchKit in exactly **2** places (haptics) and
`WatchLoopManager` in **none**. What actually blocks (a) is the `WatchLoopManager` stored
property and its transitive closure, which reaches `ExtensionDelegate`,
`ChartHUDController`, `HUDInterfaceController` and `WKExtension`. So (a) is genuinely out —
for a different reason than recorded, and worth correcting because "it won't compile for
iOS" invites someone to try to fix the wrong thing.

What was built:

1. **The seq-gap cursor cap MOVED** from `PodLoanWatchController.handleAck` into
   `LoanEventJournal.applyAck(committedCursor:withholding:)`. The journal imports only
   Foundation + os.log and is already in both targets, so the cap became executable from
   LoopTests. This was not a workaround dressed as a refactor: the controller was reaching
   through `unackedEvents()` to recompute a seq→ID mapping the journal already owns. It also
   fixed a test that could not fail — the old
   `testCursorIsAWatermarkSoAGapMustBeCappedByTheCaller` computed `min(later.seq,
   withheld.seq - 1)` in its own body and asserted on its own arithmetic.

2. **`LoanTwoSidedContractTests`** — real `PodLoanPhoneController`, real `LoanEventJournal`,
   real wire encode/decode on every hop, joined by a fake transport with a controllable
   ack-drop fault. The watch's PHASE MACHINE is modeled (deliberately small); everything
   else is production code. Five tests: full round trip, exactly-once under a lost ack, the
   cap × dedup composition, revoke mid-loan, and the #102 stale-epoch offer.

The composition test is the point of the file. The watch's cursor cap and the phone's ID
dedup are each correct under their own tests and could still lose or double-book insulin
between them: drop the cap and the withheld dose is buried forever; drop the dedup and
everything above the gap is booked twice. Both failures are silent, and both are insulin.

Sabotage-verified in both directions (item 4 discipline): deleting the cap reddens 2 journal
tests; deleting the phone's ID dedup reddens 3 two-sided tests while leaving revoke and
stale-epoch green — the tests discriminate rather than all firing on everything.

**What this still does NOT cover, stated plainly:** the watch's phase transitions —
`cancelHandback`, the finalize gates, the `.handingBack`/`.revoked` guards. §16's
cancel-mid-drain stays blocked and revoke-during-drain is covered only on the phone side.
The honest unblock is (b), a watchOS unit-test target: a new PBXNativeTarget, scheme wiring,
and a second destination in the ship gate. Sized, not built — hand-editing a new native
target into the pbxproj is not something to do alongside other work.

**Sabotage findings (item 4), all real:**
- The gate I wrote failed *silently*: under `set -e` a non-matching diagnostic grep aborted
  the failure block before `exit 67`. Every such grep now ends in `|| true`.
- A failing test can surface as "the test runner hung before establishing connection"
  (~343-381 s vs 6 s green) rather than as an assertion. The gate now distinguishes the two
  and says which, because a flake that reads as a code failure gets the gate switched off.
- Removing `LoanReconciler`'s final-handback clamp — the line implicated in the 2026-08-11
  hand-back wedge — is caught by the FULL suite (3 failures) but NOT by
  `LoanBooksHarnessTests` + `PodLoanPhoneControllerTests` alone. Scope the gate to all five
  suites, never a subset.
- The suite has a real shared-state flake (`testDuplicateBolusTwinDetection`, tracked
  separately). Test isolation is a prerequisite for trusting the gate, not a nicety.

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

### 6. Fault variants — DONE 2026-08-12

Folded into `LoanTwoSidedContractTests` as the plan asks, with no fault-injection framework:
the only machinery is a droppable-ack counter on the fake transport.

- **certain refusal (#99)** — an assumed bolus is refuted by the pod. Two mechanisms have to
  line up and the test needs both: withholding keeps the unclassified command off the wire,
  annulment then removes it and tombstones the ID. Without withholding the phone would already
  have committed it and there IS no unwind on the phone — the commit filter skips tombstoned
  events, it does not delete written doses.
- **unreachable phone (#35)** — three redeliveries with the ack dropped, then a fourth that
  lands: one bolus, one temp, one carb after four deliveries.
- **force-reclaim then re-offer (#66)** — the unreachable-watch scenario #66 has been waiting
  on, end to end.
- **uncertain command** and **mid-operation cancel (revoke)** were already covered by item 5's
  tests 3 and 4.

A note on how the #66 test was nearly worthless. The first version drove it through an OFFER,
which commits immediately and records the IDs at :1215 — so sabotaging the actual #66 fix (the
`committedIDs.formUnion` in `forceReclaimToOwner`) left it GREEN. Records only reach that fix
if they were STAGED and never committed, which means the streaming path. Rebuilt on
`doseRecordBatch`, the sabotage now reddens it with "the re-offer must not re-book the carb
(got 2)". The lesson is the item-4 lesson again: a test nobody has tried to break is a test
whose coverage is unknown.

### 6-original. Fault variants, folded into the existing harness (incremental)
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

**Updated 2026-08-13: a watchOS test target now exists, and this section was written before it.**
`WatchAppTests` runs in the watch extension's own host on a watchOS simulator, so some of what
was field-only is now reachable — notably notification ARMING, which `WatchdogArmingTests` covers
for all three dead-man alerts (intervals, replace-not-stack, independent identifiers). The
scheduling seam plus `LogSink.shared.handler` also make the loan controller's timers and its own
log assertable. See REFACTOR_TIMERS.md.

What remains genuinely FIELD-ONLY: app suspension, keepalive survival, notification DELIVERY (as
opposed to arming), real WCSession semantics against a live phone, and all radio timing. The
overnight of 2026-08-09 proved the dead-man in the field better than any test could, and that is
still true of delivery.

Consequence for the refactor, revised: **logic may be rewritten under the net. Code that touches
the watchOS runtime — keepalive, WCSession activation, notification delivery — is MOVED, not
rewritten.** Notification arming has moved out of that category: it is now covered.

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

## #103 is NOT closed (2026-08-12) — reduced, not eliminated

The unlink fix was real: removing the synchronous `removeItem` from the tearDowns of
`LoanBooksHarnessTests`, `LoanOverrideTests` and `WatchStoreEffectsTests` removed the
`Failed to stat path …/Model.sqlite` noise from the logs entirely, and three consecutive
gate runs went green. **That was not enough evidence, and the claim that #103 was fixed was
premature.** Against a flake that fires roughly 1 run in 5, three green runs is a coin
landing heads three times.

It reproduced on the 8-suite gate with a DIFFERENT test and a different suite:

```
WatchStoreEffectsTests.testLedgerMatchesDoseStoreIOB
  XCTAssertEqualWithAccuracy failed: ("1.8260779112853762") is not equal to ("0.0")
```

Same signature as always: **the store answers with zero rows.** What is now known about it,
and worth writing down because it rules things out:

- The read SUCCEEDED. `iob(_:at:)` initializes to `-1.0` and assigns only on `.success`, so
  0.0 is not a failed query — `insulinOnBoard` genuinely computed zero.
- The write reported NO error: the test's `XCTAssertNil(error)` on `addPumpEvents` passed in
  the same run.
- It is not the async-init race for WRITES. `PersistenceController.initializeStack` attaches
  the coordinator inside `managedObjectContext.perform`, so every later context block is
  serialized behind it. A write cannot outrun the store attaching.

So the mechanism is still unknown, and the two obvious hypotheses are eliminated. Do not
close this again on green runs alone; closing it needs the mechanism.

Rate, measured today: 1 failure in 6 runs of the 8-suite gate (113 tests), versus roughly
2 in 5 before the unlink fix.

**Operational consequence, which is the part that matters.** This failure produces a real
assertion, so the ship gate's retry logic does NOT absorb it: that retry only fires when a
run produces zero assertion failures (the "runner never started" environment flake). A ~17%
chance of refusing to archive a good build is a gate that will get switched off — the exact
outcome the sabotage findings above warn about. Either the mechanism gets found, or the
gate needs an explicit, logged retry-on-this-signature.
