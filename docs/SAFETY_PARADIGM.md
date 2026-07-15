# Safety Paradigm — Watch Pod-Loan Architecture

**Status: DRAFT for Jeremy's review — intended home: `docs/SAFETY_PARADIGM.md`**
**Scope: all 110 inventoried measures (41 watch, 40 facade/PodSDK, 29 phone) graded against the incident evidence base, branch `loan-revoke`, as of 2026-07-10.**

---

## 0. Immediate blockers (before any real-person use — which the tree says is today)

These are not architecture; they are open safety debts standing at HEAD:

1. **TEMP-TEST-CAP is still 3.0 U/hr** in both `PodProofKit.swift:236-240` and `WatchPodLoanCoordinator.swift:214`. This is a deliberate, flagged test weakening of an independent hard cap. Revert both to 1.0 together.
2. **TEMP-TEST-BEEPS is still `true`** (`PodProofKit.swift:229-230`). Revert.
3. **The heaviest new machinery is unvalidated**: the DESIGN-6 revoke apparatus (4-scenario bench script written, never run) and the DESIGN-5 hand-back temp cancel (validation pending). Run both scripts before the pod goes on a person.

---

## 1. The Principles

The candidate principles largely validate. Two refinements: the single-writer principle needs an "at least one" half (orphan prevention is a distinct failure mode with its own incident, B1), and a seventh principle — *stock dialect only* — must be carved out, because it explains the largest facade measure family and the single most expensive incident (BUG-6, dead pod #2). One process rule governs admission of measures.

**P1 — Exactly one accountable controller, enforced in software.** At most one device commands the pod at any instant, and at least one device can always reach it (or a path back exists); neither half may rest on radio state or human ritual. *Rationale:* the real pod arbitrates nothing — it is last-connector-wins with a ~2 s reclaim by the persistent bidder (OQ-1, DESIGN-3, observed 2026-07-09 19:51:44), and ritual-based exclusivity failed observably (DESIGN-GAP-1).

**P2 — The pod's own autonomy is the ultimate backstop.** Designs lean on the pod's native behaviors — temps expire, the stored schedule persists, faults halt delivery — so the worst dangling state is self-limiting. *Rationale:* every controller in this system can die (observed: watch app kill, phone SIGSEGV, faulted pod); only the pod is always present.

**P3 — Speak only stock dialect to the pod.** Every command sequence sent must be one stock OmniBLE emits; anything else has unknown real-pod semantics and proven terminal downside. *Rationale:* one non-stock sequence (temp-over-temp without cancel-first) faulted real pod #2 permanently (BUG-6, fault 049), and the emulator will never catch the next one — it accepted overlapping temps for three days.

**P4 — The journal is the sole truth for watch-delivered insulin.** It is persisted on every mutation, byte-stable, idempotently delivered (hash-deduped), independently audited by the pod odometer, and data-first: a recovered journal is delivered, never resurrected into a session. Corollary: the phone must never automate dosing against a record it knows is incomplete. *Rationale:* 0.85 U of delivered insulin vanished from all records when the journal existed only in memory (2026-07-10); understated IOB fails in the hypo direction.

**P5 — No silent failure, no unverifiable claim.** The human is the outermost safety loop; every command failure surfaces loudly, and every display asserts only what the device can verify — or says it doesn't know. *Rationale:* a 0.9 U bolus failed with zero indication anywhere (BUG-5, observed on real pod); the "On Watch" badge asserted possession the phone could not verify (DESIGN-2).

**P6 — Independent hard caps bound the blast radius of all bugs above them.** Dose ceilings and deliberate-commit gestures are enforced at every layer independently, assuming everything above is buggy. *Rationale:* caps are the only measure that defends against *unknown* defects; stock Loop's guardrail pattern, deliberately layered (watch 1.0 U → facade 1.0 U → phone 1.05 U).

**P7 — A control transfer leaves the pod in the state the receiving controller believes.** Hand-back cancels watch temps, resume programs the *real* schedule, release never destroys pairing, the odometer is freshened before snapshot, grants are validated before takeover. *Rationale:* a leftover 0.10 U/hr watch temp was invisible to the phone, which displayed "normal" against a 3.7 U/hr schedule (DESIGN-5, demonstrated live 2026-07-10).

**M — Evidence before machinery (process rule).** A measure is admitted only against an observed incident, a code-proven mechanism, or a stock precedent. Speculative measures must be trivial in complexity, labeled as speculative, and carry a validation-or-removal date. The emulator alone neither justifies nor acquits anything: it lied in five confirmed ways (overlapping temps accepted → killed pod #2; same-controllerId crash; post-loan wedge OQ-4; 60 s vs 11 s idle-drop; basal rates discarded).

---

## 2. The Map

Every measure, mapped. Grades: **OBS** observed-incident, **CODE** code-proven, **STOCK** stock-precedent, **SPEC** speculative-race, **ART** possibly-test-artifact. Tags: [W] watch, [F] facade, [P] phone.

### P1 — Exactly one accountable controller

| Measure | Grade | Note |
|---|---|---|
| [W] Phase machine (7-state, gates on every entry) | CODE | Load-bearing core; a gap in it was BUG-1 |
| [W] busy-flag serialization | STOCK | Intra-device single-writer on one BLE session |
| [W] armedAt staleness anchor | CODE | Late revoke delivery is certain-by-design (queued channel) |
| [W] lastRequestAt anchor | SPEC | DESIGN-6 hardening; never observed |
| [W] lastRevokeAt grant-resurrection guard | SPEC | Never observed; consequence class (ping-pong) is |
| [W] wasRevokedByPhone takeover guard | SPEC | Same family |
| [W] DESIGN-6 revoke handling (idempotent, zero post-revoke pod commands) | OBS | DESIGN-3 real-pod reclaim; **validation pending** |
| [W] Auto-request gate (never re-borrow after revoke) | CODE | |
| [W] UI busy/phase disables | CODE | Deliberate second layer over coordinator guards |
| [W] App-scope coordinator ownership | OBS | B1 orphaning; "at least one" half of P1 |
| [F] abandonLoanAsRevoked | OBS | Strict single-writer discipline |
| [F] releasePod non-destructive | CODE | "At least one": pod stays reclaimable (also P7) |
| [P] Release-before-grant + capability denial | OBS | The formal handoff — heaviest P1 machinery |
| [P] Loan-revoke send (queued) | CODE | **Validation pending** |
| [P] Parked revoke (pre-activation fallback) | SPEC | Narrow window, never observed |
| [P] Escape-hatch reclaim alert | CODE | "At least one": dead-watch recovery path |
| [P] Escape hatch keyed on persisted flag | OBS | Live-verified post-crash |
| [P] PumpConnectionLendable protocol | OBS | |
| [P] releaseConnection/rearmConnection | OBS | |
| [P] podConnectionReleased persisted, honored at init | CODE | Relaunch-mid-loan is real (crash observed) |
| [P] BluetoothManager materialize+scan | OBS | Reclaim must actually work (Signal Loss incident) |

### P2 — Pod autonomy backstop

| Measure | Grade | Note |
|---|---|---|
| [W] Fixed 3 h auto-expiring temp, no duration UI | CODE | Leans on pod-native revert |
| [W] Best-effort non-blocking pod steps at hand-back | OBS | BUG-6: journal delivered despite faulted pod (also P4) |
| [P] Reclaim relies on standing connect + EAP SQN resync | OBS | Leans on stock/pod self-heal; manual poll deleted |

### P3 — Stock dialect only

| Measure | Grade | Note |
|---|---|---|
| [F] Safe-cancel before every temp program | OBS | BUG-6 — strongest-evidenced measure in the tree |
| [F] Bolusing guard / [F] Suspended guard | STOCK | Stock mirrors, part of BUG-6 fix |
| [F] Rate snap + negative clamp / [F] duration validation | CODE | Latent API holes, not UI-reachable; 7 tests |
| [W] Rate snap + zero→suspend diversion | CODE | Duplicated at dial — deliberate |
| [W] Suspend-vs-zero routing, Resume-not-CancelTemp | CODE | Stock pod semantics |
| [F] Resume getStatus freshen | SPEC | Triple-redundant — see §3 |
| [F] Suspend passthrough (audited, no machinery) | STOCK | Evidence of review, not accretion |
| [F] noSeqGetStatus on takeover | STOCK | |
| [F] Fresh PodComms per takeover | CODE | Stock relaunch idiom |
| [F] notPaired guards | CODE | |
| [F] Setup sequencing + low-reservoir at pairing | STOCK | **Non-loan scope, hardware-unverified — quarantine** |
| [F] Vendored stock suites (115 tests) | STOCK | Foundational; already caught a Swift 6.2 hazard |
| [F] PodProofKitGuardTests (7) | OBS | BUG-6 lineage |

### P4 — Journal sole truth

| Measure | Grade | Note |
|---|---|---|
| [F] Loan journal (capture + display) | OBS | Core purpose |
| [F] journaling() success-only | OBS | Verified under real failure |
| [F] Persistence on every mutation | OBS | 0.85 U incident |
| [F] Ack-gated persistence clear | OBS | |
| [W] Recovered-journal persistence + auto-handback (3 triggers) | OBS | Data-first; never resumes sessions |
| [W] Byte-stable hand-back snapshot | CODE | Retry path live-exercised, no duplicate |
| [W] Snapshot invalidation on new command | CODE | |
| [W] Pod released only after phone ack | CODE | Also P1 "at least one" |
| [W] handedBackAt at last-event time | CODE | |
| [W] Journal byte-stability on abandon / [F] no-closing-event | SPEC | Observed ancestor: 2026-07-08 different-bytes retry |
| [W] Pre-loan recovery drain / [F] orphan slot | SPEC | See §2b and §3 — heaviest speculative machinery |
| [W] pendingRevokeAt parking | SPEC | Three drain sites — see §2b |
| [W] Odometer freshen + failure instrumentation | OBS | OQ-5 |
| [F] Odometer cross-check + clamp | OBS | OQ-5 cuts both ways: proved value, exposed blindness |
| [F] Insulin model exact port + vectors / net-basal segments / midnight wrap / 20 vector tests | CODE/OBS | −0.36 U watch-phone agreement on real pod |
| [F] Wire-format pinning tests / [F] journal+orphan tests (13) | CODE/OBS | Test-as-safety-layer |
| [P] SHA-256 duplicate guard | OBS | Only dedupe anywhere — DoseStore doesn't |
| [P] Write-doses-first ordering | SPEC | Err-safe direction; crash-at-hand-back is real |
| [P] Undecodable-journal fallback | CODE | Version skew is a real deployment path |
| [P] Bolus-primary real-timestamp reconciliation | CODE | Core; real-pod validated |
| [P] Odometer audit (0.05 U threshold) | OBS | **Counter-evidence: blind 2 of 3 sessions (OQ-5)** |
| [P] Suspend-window err-safe semantics | CODE | Every ambiguity overstates IOB |
| [P] Mirror decode types (no OmniBLECore link) | CODE | Deliberate decoupling |
| [P] Auto-dosing pause at grant / restore at hand-back | OBS | The TRAP CELL's only structural defense |
| [P] Persisted dosingEnabled + first-grant-only capture | CODE/OBS | Live test caught the clobber |

### P5 — No silent failure, no unverifiable claim

| Measure | Grade | Note |
|---|---|---|
| [W] BUG-5 loud CommandFailure machinery | OBS | Validated under real fault storm |
| [W] Reachability prechecks / [W] end-gate alert | OBS | **Both carry stale BT-off-era copy — fix** |
| [W] HUD truth display / ChartHUD reconfig / active-temp honest hints | CODE | Staleness-by-construction honesty |
| [W] ActionHUD carbs-disable | CODE | The willActivate half is ART — cheap, keep |
| [W] Insulin-model conservative fallback | CODE | Dark path; consequence currently nil |
| [F] Three-way DeliveryCommandResult | STOCK | **Known gap: unacked-but-delivered bolus unjournaled** |
| [F] Takeover 30 s timeout + single fulfillment | CODE | No silent hang |
| [F] Main-thread preconditions / [F] stateLock | CODE | Mechanics preventing silent hang / torn state |
| [F] Reservoir sentinel→nil | STOCK | |
| [F] Model labeling + predict() display-only constraints | SPEC | **Comment-only, no mechanism** — fine while dark |
| [P] Pod Not Connected truth precedence + 8-min gate | CODE | DESIGN-2; complexity explicitly parked |
| [P] DiagnosticLog arity hardening + vararg pre-format | OBS | SIGSEGV; instrumentation must never harm the flow |
| [P] Settings-transfer skip logging | ART | Diagnostics only, zero weight |

### P6 — Hard caps / dose-error containment

| Measure | Grade | Note |
|---|---|---|
| [W] maxBolus 1.0 / [F] bolus cap 1.0 / [P] 1.05 journal cap | STOCK/SPEC | Deliberate three-layer defense in depth |
| [W]+[F] temp rate caps (paired) | STOCK | **Both at test value 3.0 — revert**; convention-only coupling |
| [W] Crown-to-confirm + dial clamps | STOCK | |
| [P] 5 U odometer sanity cap | SPEC | Interaction with test cap vanishes on revert |
| [P] Expired-bolus 30 s guard | STOCK | Upstream, predates project |

### P7 — Truthful transfers

| Measure | Grade | Note |
|---|---|---|
| [W] DESIGN-5 leftover-temp cancel at hand-back | OBS | **Validation pending** |
| [F] Resume programs the real schedule | CODE | Real-pod validated |
| [W] Grant decode + key completeness (two layers) | CODE | Second layer possibly accidental redundancy |
| [P] Loan-grant identity guards | CODE | Unit-tested |

### M / mechanics / UX (serve no dosing-safety principle — and that's fine)

| Measure | Grade | Disposition |
|---|---|---|
| [W] Simulator demo isolation (~110 lines) | CODE | Correct, but shrink — see §2b |
| [F] Padded-advertisement flag | ART | Quarantined test-rig accommodation; keep, labeled |
| [F] 5 s re-advertise wait | ART | Removal candidate — §3 |
| [F] establishSession manual path | ART | Removal candidate — §3 |
| [P] Shadow-all basal logging | CODE | Serves M itself (evidence-gathering); needs a sunset gate |
| [W] reset()/Start, Try Again on .armed, spinner, auto-return dropFirst | OBS/CODE | UX-necessity, incident-backed; not safety machinery, not removal candidates |

### 2a. Measures serving no principle (removal candidates)

- **[F] establishSession manual path** — motivated by the emulator's 60 s idle-drop, later proven an artifact (real pod: ~11 s supervision timeout, and PodComms auto-reconnects). Remove after one real-pod confirmation.
- **[F] 5 s re-advertise wait** — timing tuned to the emulator inside a test-rig-only self-handoff flow. Remove with the sandbox flow, or measure on real pod and shrink.
- **Stale UI copy ×2** ("Make sure your iPhone's Bluetooth is off"; "iPhone Bluetooth Is Off") — worse than useless: they now *violate P5* by asserting a false cause in the post-handoff world. Fix the copy; keep the guards (both well-evidenced).
- **[P] Settings-transfer skip logging** — simulator-quirk diagnostics; keep or delete freely.
- **TEMP-TEST-CAP / TEMP-TEST-BEEPS** — not measures but standing anti-measures. Revert (blockers, §0).

### 2b. Disproportionate complexity (simpler form named)

- **[F] Orphan slot** (two-slot state machine, preference-ordered read/clear, live-session gating) protects insulin records — the crown jewel — but against a window the code's own comment calls deliberately narrow, and the pre-loan drain already runs on every takeover. *Simpler form:* make the drain blocking — a new takeover may not persist over an undelivered journal; if drain delivery fails, refuse the loan with a loud error (P5). One guard replaces a state machine.
- **[W] pendingRevokeAt parking** — three drain sites that must all stay maintained; forgetting one strands a revoke silently. *Simpler form:* funnel every `busy→false` transition through one setter whose `didSet` drains. Three sites become one.
- **[W] Simulator demo isolation** — ~110 lines of parallel fake state for sim review. Compile-time-safe but a pure maintenance surface. *Simpler form:* a static mock phase, or delete the demo.
- **[W/F] Staleness anchors (armedAt, lastRequestAt, lastRevokeAt) + resurrection guards** — five point-fixes for one underlying problem (messages from a dead loan generation). *Simpler form:* the loan epoch — see Verdict.
- **[P] Shadow-all basal** — heavy but *principled* (it is M made executable: gather real-pod evidence before flipping behavior). Keep, but give it an explicit evidence quota or decision date so it cannot become permanent dead weight.
- **[W] DESIGN-6 apparatus overall** — heavy and incident-rooted (DESIGN-3), but it is the largest not-yet-validated machinery in the tree. Not a simplification candidate; a *validation* obligation.

### 2c. Redundant overlaps — deliberate or accident?

| Overlap | Verdict |
|---|---|
| Bolus caps ×3 (1.0/1.0/1.05) | **Deliberate** defense in depth. Keep. |
| Temp caps ×2, "must move together" by convention | Deliberate, but the coupling is fragile — the test-cap episode proved it. *Fix:* one constant exported by PodSDK, consumed by the watch. |
| Rate snap ×3 (dial, coordinator, facade) | Deliberate, trivial. Keep. |
| busy guards ×2 (coordinator + UI) | Deliberate, documented as such. Keep. |
| Grant validation ×3 (phone identity guards, watch :292, watch :430) | Watch's second layer looks **accidental**. Verify one watch layer suffices; cheap either way. |
| Resume getStatus freshen vs vendored anti-0x31 cancel vs formal handoff | **Triple coverage of one mode** the audit itself judged already-safe. Deliberate belt-and-suspenders per the log — see §3. |
| Reachability precheck + end-gate alert | Different entry points, same mode. Acceptable. |

### 2d. Gaps — modes the principles demand covered, with nothing covering them

1. **P4: unacked-bolus-that-delivered is never journaled** (facade three-way handling, honestly flagged in-code). Its only backstop is the odometer audit — which OQ-5 showed blind on 2 of 3 real-pod sessions. Two weaknesses compound into one real hole, in the hypo direction. *The OQ-5 fix (freshen retry + raw logging) is specified and unbuilt. Build it.*
2. **P1 "at least one": DESIGN-4** — Wi-Fi hand-back with phone BT off orphans the pod; the proposed phone-side "turn on Bluetooth" nag was never built. Narrowed by the handoff (BT stays on) but the cell exists.
3. **P4/P5: the trap-cell residue** — a loan never ended + phone reclaim leaves the phone looking healthy while holding none of the watch doses. Automation is safe (dosing paused), but nothing warns a *human* doser. Journal streaming was noted, not built; a cheap interim: a persistent "watch doses not yet reconciled" banner while `isConnectionReleased` was ever set without a received journal.
4. **P5: comment-only constraints** (predict() must-not-gate-dosing; bolus-only labeling) have no enforcement. Acceptable while the code ships dark; must gain a mechanism before any BG display exists.
5. **P6: no cumulative bound.** Caps limit single doses; nothing bounds repeated 1.0 U boluses across a loan. Crown-confirm and serialization slow it, but a per-loan cumulative ceiling would be one comparison in the coordinator.
6. **M: the validation ledger is in deficit** — DESIGN-6 unrun, DESIGN-5 pending, test caps unreverted, on the planned real-use date. This is the paradigm's own rule being violated.

---

## 3. The Fictional-Problem Audit

16 SPEC + 5 ART measures. Grouped by what would settle them.

**The DESIGN-6 race family** — grant/takeover resurrection guards, byte-stability on abandon, pre-loan overwrite, lastRequestAt, pendingRevokeAt, post-cancel/freshen guards, parked revoke.
*Demonstrate real:* the already-written 4-scenario bench script, plus one addition: inject a revoke during a long-running command (instrumented delay hook in the facade) and during a delayed grant reply (airplane-mode flap). One afternoon on the bench.
*Keep vs remove:* keep-cost is near zero for the trivial guards, and two members have observed ancestors (byte instability = the 2026-07-08 different-bytes retry; overwrite stakes = the 0.85 U loss). The real costs are pendingRevokeAt's three drain sites and the orphan slot's state machine.
*Recommendation:* **keep the trivial guards; run the script; apply the two §2b simplifications (drain funnel, blocking drain)**. If the epoch change (Verdict) lands, delete lastRequestAt/lastRevokeAt/armedAt outright — subsumed.

**[F] Resume getStatus freshen** — the post-BUG-6 audit itself found resume safe on every watch-reachable path; this defends a dual-controller interleaving the formal handoff exists to prevent. Triple redundancy.
*Demonstrate real:* suspend from watch, resume from the phone (second controller), resume from watch with the freshen disabled; watch for 0x31. **The experiment risks a bench pod** — this fault class already cost pod #2.
*Keep vs remove:* keep-cost is one radio round-trip per resume; disproof-cost is potentially a pod.
*Recommendation:* **keep** — the rare speculative measure where keeping is strictly cheaper than testing. Label it belt-and-suspenders in code so it never breeds imitators.

**[P] Write-first ordering, 1.05 U cap, 5 U sanity cap** — reasoned bounds, zero mass, and the ordering isn't machinery at all, just a chosen sequence. *Recommendation:* **keep all three**; no experiment justified. Note the 5 U/3.0-cap interaction self-resolves on revert.

**[F] Model-fallback labeling + predict() constraint** — human-factors hazards for code that ships dark. *Recommendation:* keep as comments now; **convert to mechanism (type or assertion) as a precondition of any BG-display work**, not before.

**Possibly-test-artifact tier:**
- **establishSession manual path** — *experiment:* real pod, let BLE idle-drop, command; if PodComms auto-reconnect suffices (evidence says it does), **remove**.
- **5 s re-advertise wait** — *experiment:* real-pod handoff with the delay at 0; measure failures. **Remove or shrink**; retire with the sandbox self-handoff flow.
- **ActionHUD willActivate observer** — cost is one redundant `update()`. Not worth an experiment. **Keep.**
- **Padded-advertisement flag** — artifact by definition, self-neutralizing on real pods. **Keep, quarantined.**
- **Settings-skip logging** — **indifferent; delete if touching the file.**

The audit's honest headline: the speculative tier is real but *thin* — nearly all trivial-complexity, most with observed consequence-classes, and concentrated in one cluster (DESIGN-6) that guards the project's crown jewel. Only two measures exist purely because the emulator misled (establishSession, 5 s wait), and both are deletable. The record also shows the opposite discipline working: OQ-3's phantom ritual was run to ground with a controlled experiment before any code responded; OQ-4's wedge got zero machinery; BUG-2 was correctly WON'T-FIXed; DESIGN-2's richer detection was parked with written reasoning.

---

## 4. Verdict

**The architecture is principled with a reactive fringe — closer to principled than the worry suggests.** The numbers: 34 of 110 measures trace to observed incidents, and — decisively — *the mass is distributed correctly*: every heavy piece of machinery (formal handoff, journal persistence, safe-cancel, loud failures, DESIGN-5 cancel, reconciliation) sits on a real incident or crash, while the speculative tier is almost entirely trivial-complexity guards. The one heavy speculative structure (orphan slot) has a named simpler form. The reactive residue is small and enumerable: two emulator accommodations, two stale copy strings, one accidental validation layer, two unreverted test weakenings, and an unrun validation script.

**The single change that would most improve logical clarity: a loan epoch.** Thread one monotonic loan-generation integer through grant, revoke, journal, and hand-back, with one rule: *any message naming an epoch older than the current one is dead on arrival.* This replaces the three timestamp staleness anchors, both resurrection guards, and the revoke-targeting logic — six point-fixes for six imagined interleavings — with a single invariant that makes the entire class of stale-message races impossible by construction rather than guarded case by case. It converts the DESIGN-6 patchwork, the part of the tree that most looks like "measures randomly applied to fictional problems," into one sentence of first principles: **messages belong to loans; dead loans cannot speak.**

Second-order, adopt rule M explicitly: every speculative measure gets a label and a validation-or-removal date, and nothing graded emulator-only ever counts as validated. The record shows this discipline already operating informally — OQ-3, OQ-4, BUG-2, DESIGN-2 are its proofs — it just isn't yet written down. This memo is where it gets written down.

---
*Traceability: all measure names, locations, grades, and incident citations in this memo are drawn verbatim from the four inventories (watch, facade, phone, incident evidence base) compiled 2026-07-10 against WATCH_LOAN_TESTING_BUGS.md, docs/WATCH_INSULIN_MODEL.md, docs/IOB_RECONCILIATION.md, WatchPodSandbox/docs/LIVE_TEST_FINDINGS.md, and git history on branch `loan-revoke`.*