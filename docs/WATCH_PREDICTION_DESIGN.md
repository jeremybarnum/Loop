# Show Mode Watch Prediction: Design Decision Memo

**To:** Jeremy
**Re:** Whether — and how — to compute glucose predictions (and eventually dose) on the watch during phone-free Show Mode sessions
**Inputs:** Four research reports — algorithm dependencies, watch data inventory, CGM-on-watch feasibility, community precedent
**Date:** 2026-07-10

---

## 1. The gating fact: live BG on the watch

Everything downstream hinges on one question: **can a third-party watch app get a fresh glucose number every 5 minutes with the phone in the truck?** The answer today is *probably yes, but the one link that matters is unverified*.

What's established:

- **Dexcom G7 Direct to Watch is real and phone-free.** The sensor holds up to 3 independent BLE channels (phone, watch, receiver/AID). Direct to Watch coexists with phone Loop. Mid-sensor, the official Dexcom watch app shows BG, trend, graph, and fires alerts with no phone present. iPhone is needed only per-sensor pairing (every 10 days) — a pre-show checklist item, not a session constraint.
- **But the data is trapped.** Dexcom's HealthKit write happens on the *phone*, with a documented 3-hour delay, and Dexcom explicitly states Direct to Watch can't share real-time data with partner apps. No evidence the Dexcom watch app writes to watch-local HealthKit at all.
- **The plausible escape hatch is exactly how Loop reads the G7 today.** G7SensorKit is a passive observer: it never pairs; it connects to the same peripheral, waits to *observe* the official app's authenticated session, then receives glucoseTx every 5 minutes. This works on iOS because the OS multiplexes all apps onto one physical BLE link. **The unverified link: whether watchOS does the same multiplexing, letting a ported G7SensorKit ride alongside the Dexcom watch app's authenticated session.** Nobody has publicly tried it. DiaBLE proves a watch CB central can talk to a G7 in foreground; GlucoWatch ships watch-direct Libre. The spike is cheap (see §5).
- **Runtime and radio constraints fit — barely.** DIY builds cannot get Dexcom's restricted background-BLE entitlements. The one legitimate multi-hour execution vehicle is an **HKWorkoutSession** (an equestrian competition is honestly a workout), which keeps the app alive with BLE connected. watchOS caps concurrent peripherals at 2: pod + G7 fits *exactly*, zero headroom. The G7 disconnects after each 5-min delivery and must be re-acquired — fine with workout runtime, but screen-off reconnect behavior needs empirical confirmation.

**Verdict:** Live BG is *feasible-unproven*. Until the passive-observation spike succeeds, no option can loop autonomously; with manual entry (rider reads Dexcom watch app, taps the number in), Option C works today. Design accordingly: build so the BG source is pluggable — manual now, streaming if the spike lands.

---

## 2. The design fork

### First, kill the premise

The "full port is impossible because there's no HealthKit on the watch" premise is **refuted on every leg**, three independent ways:

1. **HealthKit exists on watchOS** (2.0+, ~7 days local store). Loop's watch extension already instantiates HKHealthStore.
2. **The algorithm doesn't need stores at all.** This fork carries `LoopAlgorithm.generatePrediction(input:)` — a pure static function (glucose + doses + carbs + settings in; predicted curve + effect timelines out), fully Codable input, zero callers in the app (dead code from Pete's 2023 refactor). All the math underneath the live phone path (InsulinMath, CarbMath, GlucoseMath, DoseMath) is pure value-type extensions.
3. **The stores don't need HealthKit either.** CarbStore/GlucoseStore/DoseStore all take `healthKitSampleStore: nil` and run on CoreData — and the watch extension *already runs* CarbStore (24h) and GlucoseStore (4h) locally.

LoopKit already builds for watchOS (139 files, all the math). The full algorithm is **~12 missing files, all importing only Foundation + HealthKit-types — a target-membership change, not a rewrite.** The real gaps are data logistics: 16h of dose history has no phone→watch transport (glucose and carb backfills exist; dose does not), carb-ratio and insulin-model settings aren't in the LoopSettings sync (two raw keys), and the watch glucose cache is 4h vs the 10h the full algorithm wants.

### Option A — Real algorithm on the watch, fed WC-shipped histories

Run `generatePrediction` (and later the dosing math in DoseMath, also pure) on the watch against histories shipped over WatchConnectivity before untethering, extended in-session by the pod-loan journal (doses) and live BG.

- **Effort: moderate, and smaller than it sounds.** (a) Add ~12 files to the LoopKit-watchOS Sources phase; (b) a `DoseBackfillRequestUserInfo` copying the carb-backfill pattern verbatim (DoseEntry is Codable); (c) two LoopSettings raw keys (carbRatio, insulin model/DIA — insulin *type* already arrives via the loan grant); (d) widen glucose backfill 6h→10h or run degraded; (e) bridge journal events → `[DoseEntry]` for the in-session tail (the watch extension links both OmniBLECore and LoopKit, so this bridge is legal); (f) reconstruct absolute basal/ISF/target timelines from the synced daily schedules.
- **Failure modes.** Two known landmines in the code: the `LoopAlgorithmSettings` Codable decode bug (target-range max decoded from minValue — JSON round-trip collapses the correction range; must fix before shipping settings that way) and a hard `precondition` crash if basal history doesn't cover the dose range (misaligned handover inputs = crash, not error — wrap it). Subtler: the phone's live loop uses the LoopDataManager path, *not* `generatePrediction` — parity between the two implementations on identical inputs is asserted-plausible, not proven. And carbs eaten mid-session won't be entered, so dynamic carb absorption runs on pre-show entries only.
- **Staleness over 1–3h: the whole point — it doesn't go stale.** With live BG every 5 min, momentum, ICE, and retrospective correction all recompute from fresh data; the journal supplies in-session doses. Fidelity approaches the phone's. Without live BG, Option A is pointless — it degenerates to Option B with extra steps.
- **Community reaction: the most defensible option** — it's the reference algorithm, not a homebrew simplification, and the community's documented criticisms target *silent divergence* and *opacity*, not location of compute. The audit burden is proving fidelity (fixture-based parity tests, which `printFixture()` makes nearly free). Honest labeling required: this fork's LoopAlgorithm module diverges from upstream's later standalone package, so don't claim upstream equivalence.

### Option B — Carry-forward: phone's last prediction/effect vectors + journal IOB delta + live BG

- **Effort: low.** The phone's full predicted curve *already ships* to the watch every loop cycle (`WatchContext.predictedGlucose`, Int16-quantized); IOB/COB scalars too. Show Mode merely suppresses display. Missing: the separate effect vectors (private LoopDataManager state — new WatchContext fields to re-anchor on fresh BG) and a "frozen at handover" semantic (loan grant is the natural carrier). The journal already computes true net IOB (bolus decay + basal-deviation vs schedule, LoopKit-exact exponential model).
- **Failure modes.** The carried prediction embeds assumptions (carb absorption trajectory, RC trend) that expire fast: momentum is a 15-min construct, standard RC a 30-min one. Re-anchoring a 90-minute-old effect decomposition onto a fresh BG is not the Loop algorithm — it's an unvalidated hybrid *nobody has ever run*, which is worse for auditability than being honestly crude. The fork's own comment calls the pre-untether prediction "actively misleading" — correct then, correct now.
- **Staleness over 1–3h: poor and monotonically degrading.** Useful for perhaps 30–60 min; by hour 2–3 during exercise (which itself shifts sensitivity) the carried vectors are noise. The one durable piece is IOB decay — which the journal already does without any carried vectors.
- **Community reaction:** dosing on stale inputs is a named failure class. As a *display* it's fine; as a loop input it draws exactly the fire the OpenAPS design exists to prevent.
- **The decisive observation:** `algorithmEffectsOptions` lets Option A natively disable carbs/RC/momentum. **Option B's "crude loop" is Option A run with effects switched off, minus the carried-vector hazard.** B is not a distinct architecture worth building; it's a configuration of A. Build A, run it degraded.

### Option C — On-demand prediction only, no dosing

- **Effort: near-zero.** `predict(currentBG:isf:)` (eventualBG = BG − IOB×ISF) is already written, test-pinned, and deliberately dark — no caller, and the synced ISF has no watch-side reader yet. Lighting it up with manually-entered BG is a UI task.
- **Failure modes:** essentially none that dose insulin. Wrong ISF or fat-fingered BG produces a wrong *number on a screen*, backstopped by Dexcom's own on-watch alerts. Header already says "Display-only; MUST NOT gate dosing" — keep it.
- **Staleness:** immaterial — each prediction is computed on demand from a fresh (human-bridged) BG and live journal IOB.
- **Community reaction:** unimpeachable, and matches the AAPS Objectives norm (open-loop before closed-loop, capability unlocked in stages).

---

## 3. Safety rails

**Common to all options** (mapping one-to-one onto the OpenAPS Reference Design — the strongest rhetorical asset available):

1. **No autobolus/SMB from the loop, ever.** Watch boluses remain manual, behind the existing 1.0 U hard cap.
2. **Low temp cap.** Revert the 3.0 U/hr TEMP-TEST-CAP to 1.0 U/hr before any real-person use (flagged in two code comments; schedule it now). OpenAPS canon: sized so any error is "easily counteracted with fast-acting carbohydrates."
3. **Pod temp auto-expiry as the dead-man's switch.** Fixed 3h duration, pod reverts to schedule if the watch dies — this is literally the reference design's fail-safe, and it already exists.
4. **Staleness fallback → schedule.** BG older than N minutes (suggest 15): cancel any loop-set temp (or let it expire) and stop recommending. Conservative on missing data, per canon.
5. **Journal audit trail + assume-delivered reconciliation.** Already built; phone-side reconciliation errs toward overstating IOB — exactly the double-dosing failure class iAPS documentation warns about.
6. **Session bounding via HKWorkoutSession** — workout end = Show Mode end, doubling as the runtime vehicle.
7. **Dexcom's own on-watch alerts** as an independent low/high safety net under everything.
8. **Honest labeling, open source:** "a bounded temp-basal assistant for 1–3h sessions," never "Loop on your watch."

**Option-specific:** A — fixture-based parity tests against the phone before any output is trusted; wrap the basal-coverage `precondition` into a recoverable error; fix the target-range decode bug; validate input windows at handover and refuse (fall back to C) if incomplete. B — hard display ceiling on carried-prediction age (~45 min), never a dosing input. C — keep the MUST-NOT-GATE-DOSING contract in code, not just comments.

---

## 4. Recommendation

**Build Option A as the architecture; ship Option C as the first product; treat Option B as a configuration flag, not a design.** The research removed A's supposed blocker — the math is pure, Codable, and one target-membership change from compiling on watchOS — so there is no reason to invest in a bespoke crude hybrid (B) whose staleness behavior is its defining property. The only genuine gate is live BG, and that resolves with a cheap spike, not a design choice.

**Staged path** (each stage useful standalone, per the AAPS graduated-objectives precedent):

- **Stage 0 (now):** Light up Option C — manual BG entry → journal `predict()` → eventualBG display. Zero new risk; immediately useful at the barn.
- **Stage 1:** BG spike. If passive observation works on watchOS → streaming BG; if not, C remains, and revisit HealthKit/manual paths.
- **Stage 2:** Algorithm on watch, *prediction display only*, run degraded (momentum + insulin effects; carbs/RC per data availability). Log everything; compare against phone retrospectively after handback.
- **Stage 3:** Capped temp-basal recommendations, open-loop (rider confirms each).
- **Stage 4:** Closed temp-only loop within a workout session, 1.0 U/hr cap, all rails on. Only after Stages 2–3 have session logs demonstrating sane behavior.

**First three concrete implementation steps:**

1. **The BG spike (gates everything; ~a day of work).** A bare watchOS app under an HKWorkoutSession that scans `DXCM*`, connects, subscribes to auth + control characteristics next to a live Direct to Watch session, and logs whether it observes the authenticated session and receives glucoseTx. Same session, run the two 10-minute side experiments: wear G7 + watch, leave the phone home, (a) query the watch-local HealthKit store for glucose samples, (b) confirm pod + G7 coexist at the 2-connection cap.
2. **Compile the algorithm for the watch.** Add the ~12 LoopAlgorithm files to the LoopKit-watchOS Sources phase; build; then a parity unit test feeding a phone-captured `printFixture()` snapshot to `generatePrediction` and diffing against the phone's live-path output. Fix the `LoopAlgorithmSettings` target-range decode bug and wrap the basal-coverage precondition while in there.
3. **Dose-history transport + settings gaps.** `DoseBackfillRequestUserInfo` mirroring the carb-backfill pattern (16h of DoseEntry, binary plist — measure payload vs the ~65 KB WC lore); add `carbRatioSchedule` and insulin-model raw keys to LoopSettings sync; write the journal-events→`[DoseEntry]` bridge; trigger carb + glucose + dose backfill automatically in the loan-grant flow.

---

## 5. Open unknowns and the experiments that resolve them

| Unknown | Experiment |
|---|---|
| watchOS BLE link-sharing lets a third-party app observe Dexcom watch app's G7 session | The Step-1 spike — no public precedent either way |
| Dexcom watch app writes BG to watch-local HealthKit phone-free | Wear G7 + watch, leave phone, run an HK glucose query on-watch (10 min) |
| Pod + G7 coexist at the 2-peripheral cap; screen-off G7 re-acquisition without restricted entitlements works | Same spike session, screen down, watch for missed 5-min deliveries |
| The 12 algorithm files compile for watchOS unmodified (DoseMath only spot-read) | Step 2 build |
| Phone live-path vs `generatePrediction` parity (different implementations) | Step 2 fixture diff test |
| WC payload size for 16h doses + 10h glucose in one reply | Instrument Step 3; chunk if needed |
| HealthKit phone→watch sync latency for Loop-written samples (possible free history channel) | Timestamped write on phone, poll on watch — informs whether WC backfill can ever be replaced |
| Battery drain: pod + G7 + workout for 3h on her watch model | Field-test during a Stage 2 session |
| Loop Zulipchat prior discussion of watch looping / safety framing | Direct search with an account before publicizing |

**Bottom line:** the premise that blocked Option A is dead; the community's safety canon maps onto rails already in the code; the only real gate is a one-day BLE spike. Do the spike, ship C in the meantime, and let A grow into the loop in stages.