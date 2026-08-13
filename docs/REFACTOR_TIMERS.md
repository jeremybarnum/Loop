# Timer work — plan, outcomes, and two phases declined on evidence

The watch loan controller schedules 14 delayed actions. Before this work they were bare
`queue.asyncAfter` calls: invisible in the log, untestable without burning real seconds, and
each carrying its own hand-written staleness guard. This is what was done, what was declined,
and why.

Status as of 2026-08-13 03:00. Phases 0, 1, 2 and 4 are landed and green. Phases 3 and 5 are
**declined on evidence** — the reasoning is below, and both are reversible decisions if the
evidence changes.

---

## Phase 0 — the scheduling seam (landed, 02537e2f)

Every delayed execution in `PodLoanWatchController` now crosses one function:

```swift
private func schedule(after delay: TimeInterval, label: String,
                      epochScoped: Bool = false, execute work: DispatchWorkItem)
```

`var scheduler` lets a test substitute a virtual clock. `nil` (production) preserves the exact
prior behavior — same queue, same deadline arithmetic — and the `DispatchWorkItem` crosses
intact, so cancellation works identically in both worlds.

The determinism trick that makes tests instant: every `schedule` call site already runs ON the
controller's serial queue, so a test scheduler that fires the work item INLINE executes it on
the correct queue with no races. Firing inline is a virtual jump past the deadline. Tests that
would take 25 real seconds take 3 ms.

## Phase 1 — every timer says what it did (landed, 3ad6c5d5)

`armed` / `fired` / `skipped` / `REFUSED`, each with lateness and the epoch it was armed under.
Lateness is the suspension signature — a deferred release firing minutes late is what poisons
the BLE stack — and it was previously inferable only from clustered timestamps.

## Phase 2 — the characterization net (landed, 8690bef3)

Seven tests recording what the timers DO today, so the refactors that follow have something to
contradict. The seam's LABEL crosses to the scheduler, which is what makes the assertions about
behavior rather than arithmetic: "a request arms exactly `[request-timeout@25s]`" is a claim
that survives; "a request arms one timer" is not.

Sabotage-verified — four deliberate breaks, each caught by the specific test that should catch
it. A characterization test that cannot go red is decoration.

One test is a harness self-check: what the recorder captures must be the seam's WRAPPER, not
the raw body. Without it, a seam that stopped wrapping would leave every other test here
passing while testing nothing.

## Phase 4 — epoch-scoped refusal (landed, ab0c3f42)

The seam captured the arming epoch and logged loudly when a firing crossed one, then called
`work.perform()` anyway. The audit of all 14 sites found the codebase in better shape than
expected:

| timer | delay | already guarded? |
|---|---|---|
| `takeover-budget` | 90 s | yes — `epoch == grantEpoch` |
| `takeover-read` | 8 s | yes — in `fireRetry` |
| `deferred-release-retry` | 10 s | yes — inherits by recursion |
| `verdict-chase` | 5/20/60 s | yes — identity on `pendingUncertainEventID` |
| **`post-dose-release`** | **12 s** | **NO — `.active` only** |

`post-dose-release` drops the pod's BLE link and guards only on `.active` — but a LATER loan is
also `.active`. A hand-back and re-grant inside 12 s would let loan N tear the link out from
under loan N+1. The margin is thin rather than theoretical: e34 ended 01:56:31 with e35 active
by 01:56:54, and fast takeovers that session ran 6.8-7.2 s.

**Enforcement is opt-in, and that is the load-bearing decision.** Blanket scoping would have
broken the request timeout, armed while `epoch` is still nil, which is the path that rescues a
hung request — and the hand-back resend, which exists to keep pushing records after its loan
ends.

**Deliberately unscoped: `release-verify` and `post-dose-verify`.** They only OBSERVE, and what
they observe is the `DISCONNECTING` wedge signature — a property of the BLE peripheral, not of
the loan. A wedged peripheral is wedged whichever loan is running, so scoping them would
suppress a real signal instead of preventing a real action. A test pins that so a later "just
scope them all" edit has to argue with it.

---

## Phase 5 — event-driven takeover: DECLINED, premise refuted

The plan was to replace "fixed-cadence polling" during takeover with event-driven completion,
motivated by e34's 56.9 s takeover.

**It is already event-driven, and has been since #86.** `takeoverRetryAction` runs the next
read the moment `podLoanOnSessionEstablished` fires; the 8 s timer is a labelled backstop, not
a metronome. The field data agrees — 5 of 7 takeovers finish in ≤12.5 s and 6 of 7 end on the
event.

e34's 49 s was the SCAN running from +0.3 s with no pod advertisement until +49 s. The reads at
+9.7/+18.5/+26.7/+34.7/+42.7 s were observing "still nothing". A faster ladder produces more
`no-peripheral` lines and zero improvement. Full evidence in FIELD_OBSERVATIONS.md
(2026-08-13 02:40).

Residual real items, both tracked elsewhere: `CBErrorDomain#11` BLE-slot exhaustion, and e31's
keepalive start-up gap (the only outlier with a local cause — and a hypothesis explicitly
tested against e34 and refuted, since e34 was foreground and keepalive-clean throughout).

## Phase 3 — extract `RetryLadder` / `DeferredAction`: DECLINED, recommend not building

The premise was that two shapes recur and should be declared once. Reading them, they don't.

| | `takeover-read` | `reclaim-read` | `verdict-chase` |
|---|---|---|---|
| spacing | 8 s + event short-circuit | fixed 2 s | exponential [5, 20, 60] |
| guard | epoch + phase | phase | event identity |
| exhaustion | teardown → idle | `completion(false)` | assumed record stands |
| result | none | `(Bool) -> Void` | 3-way verdict switch |

A unifying `RetryLadder` needs a config struct with six-plus fields and three different
completion shapes. That is harder to read than three explicit ladders, and it puts all three
safety-critical paths behind one piece of shared machinery where a single bug reaches all three
at once. It also cuts against two of the three stated goals of this refactor — minimum
deviation from stock, and code the Loop community finds idiomatic. A bespoke generic
retry framework is more deviation, not less.

The `DeferredAction` half is already done: **phase 0's seam IS that abstraction.** Every
one-shot deferred action is now a single `schedule(after:label:)` line. What remains different
between the ladders is essential complexity, not duplication.

**Recommendation: do not build it.** Reversible — if a fourth ladder appears and shares a shape
with an existing one, extract at that point, with two real call sites to design against rather
than three that disagree.

---

## What the seam unlocked, which matters more than the abstractions

`LogSink.shared.handler` is a process-wide sink that `SportLog.event` already writes through. A
test can install it and assert on what the controller SAID. That is what made phase 4 testable
at all: with no pump manager the timer body early-returns anyway, so "refused because the epoch
moved" and "ran and did nothing" are otherwise byte-identical from outside — the same
indistinguishability that let #113 survive two occurrences.

Combined with `scheduler` (virtual time), `now` (virtual clock) and `defaults` (scratch
suite), the controller is now testable without a pod, a phone, a radio, or real seconds.
17 watch tests run in 6 seconds.
