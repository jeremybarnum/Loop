# Sport Mode — Pre-Release Checklist (Path 1)

**Purpose.** The go/no-go list to finish on `SportMode` (the working branch across the
superproject and all submodule forks; historical pointers `stock-cgm-piggyback` /
`watch-from-stock` are frozen) before Caitlin (a real T1D user) tests it on-wrist. This is insulin dosing on a real person, so the bar is
correctness and honest failure signalling — not feature completeness.

**Scope note.** Path 1 = ship-to-Caitlin readiness (this doc). Path 2 (deferred) =
merge Caitlin's branch customizations (the March2026 G7-direct foundation) — after the
first test proves out.

**Last updated.** 2026-07-24, after the build-158 hardware session (new-sensor BLE-bond
finding). Task IDs reference the session task list.

---

## Recommended cut line for the *first* test

Non-negotiable before she wears it: **Tier A (safety/correctness)** and **Tier B1/B3
(new-sensor pairing + honest status)** plus **D1 (one clean overnight)**. Tier C (carb/
bolus flows) and B2/B4 (coexistence hardening / BG fallback) can trail into the first
supervised session *if* that session is short and watched. Jeremy sets the final line.

---

## Tier A — Safety & correctness (hard gate — this is insulin)

- **A1. Safety audit — dropped stock calls + silent non-dosing.** (#44 + #41)
  Systematic sweep of the watch loop / dosing / loan path for (a) more dropped stock
  calls like the `ensureCurrentPumpData` bug, and (b) any path that can silently
  not-dose. Every skipped cycle must be loud (on-wrist + log). *This is the big
  multi-agent audit — run as a Workflow on Jeremy's go.*
- **A2. Prediction correctness on the watch.** (#45 + #46)
  Port/verify stock `PredictionInputEffect` + `predictGlucose(using:)`; the watch
  currently hardcodes `StandardRetrospectiveCorrection` and ignores the phone's
  Integral-RC toggle (#46). Dosing off a divergent prediction is the worst failure
  mode — verify the watch's dose math matches the phone's for the same inputs.
- **A3. Hand-back reliability — the pod must return to the phone.** (#35 + #42)
  #35: phone silently ignored 28 hand-back offers (needs phone-side diagnosis).
  #42: rapid hand-back → re-takeover races the phone's un-released pod BLE. If ending
  Sport Mode doesn't reliably return the pod, that's a safety problem, not a UX one.

## Tier B — Sensor reliability & honest status (the cluster that bit us 2026-07-24)

- **B1. New-sensor onboarding: surface the watch BLE pairing-accept step.** (#63)
  Each new G7 needs the watch to establish its OWN SMP bond → a watchOS "Bluetooth
  Pairing Request" prompt the user must accept on the wrist. Until accepted, every read
  fails `CBATTError 15 "Encryption is insufficient"` and the watch silently gets no
  readings (only the 20-min SensorBlackoutAlert signals it). Surface prominently in the
  new-sensor flow + document. **Hard blocker — recurs on every sensor change.**
- **B2. G7 ↔ phone coexistence hardening.** (#32 + #15 + #31)
  Reduce the encryption-drop/contention so the watch reliably reads while the phone
  shares the sensor (#32 coexistence test; #15 slow acquisition + silent post-connect;
  #31 window-aware pod comms — defer steady-state pod commands around the CGM window).
- **B3. Honest phone-side status during a loan.** (#21 + #26)
  #21: suppress the phone's stale prediction/IOB/COB while the pod is on the watch.
  #26: replace the false "Loop not looping" alerts (don't just mute them). She *will*
  glance at the phone — it must not lie or cry wolf.
- **B4. Phone-present BG fallback — IN the first-test cut line (Jeremy 2026-07-27).** (#39)
  The watch loop consumes BOTH phone-relayed BG and its own direct-G7 BG, so a
  watch-can't-read loop falls back to the phone instead of going dark (direct mitigation
  for the 2026-07-24 failure). Agreed design 2026-07-27:
  - Reuse the STOCK WatchContext glucose the phone already sends every cycle (value/date/
    trend/syncID via WatchDataManager.createWatchContext → ExtensionDelegate.updateContext)
    — NO new relay. Today that BG lands in `activeContext` (complication / glance HUD /
    recommended-bolus DISPLAY only) and never reaches the dosing store; our loop doses only
    from the direct-G7 store (processCGMReadingResult → glucoseStore.addGlucoseSamples). The
    WatchContext→dosing-store bridge already exists and is proven: `simIngestPhoneGlucose()`
    writes it to the real glucoseStore + invalidates momentum (#51) + triggers the loop, but
    is `#if targetEnvironment(simulator)` (task #61 harness). #39 = promote that ingest to
    device, gated to an active loan. (Supersedes BOTH the original "read from HealthKit" and
    my earlier "new WCSession relay" framings — the transport is stock and already flowing.)
  - Both sources write the watch glucose store; SELECTION is stock's most-recent-fresh-
    wins via the ported fresh/aging/stale gate (#48) — NOT source-stateful. A stale phone
    sample automatically loses to a fresh direct sample, so once the phone is out of range
    nothing "waits" for it (Jeremy's key constraint).
  - **BUILT (device) 2026-07-28.** WatchLoopManager observes `LoopDataManager.didUpdateContext
    Notification`; during a loan (pumpManager set) it routes the phone's `context.newGlucoseSample`
    into the DOSING store (`ingestPhoneGlucoseFromContext`). Key simplification (Jeremy's syncId
    insight, verified in source): the relayed sample carries the phone's REAL G7 syncIdentifier
    (`WatchContext.newGlucoseSample`), and the watch's direct read builds its sample with the SAME
    G7SensorKit code (`G7ClientTransportAdapter` → `G7CGMManager`, from the same sensor-clock id) —
    so an overlapping grid point AUTO-DEDUPS in the store by syncId. No preference/failover state:
    a date pre-check (skip if the store already has ≥ this date) means a fresh direct read always
    wins and phone BG fills only gaps. Mixed provenance zeroes momentum briefly at the boundary
    (accepted). A syncId is logged on ingest; empirical syncId-match confirmation is captured at #32
    (phone real G7 + watch direct G7). Device-only (`#if !targetEnvironment(simulator)`; the sim
    keeps its #61 timer path).

- **Pre-test observation (Jeremy 2026-07-28 — MEASURE before test release):** takeover and
  hand-back appear more reliable with Loop in the FOREGROUND (watchOS suspends a backgrounded
  app, interrupting BLE/WCSession work). Quantify foreground-vs-background success before release;
  may motivate a "keep foreground during takeover/hand-back" nudge.
  - Phone-preferred DEDUP: before writing a direct sample, suppress it ONLY if a *fresh*
    phone sample already covers that ~5-min EGV window; never suppress a direct read when
    the phone sample is absent or stale. Keeps ~one sample/window → single provenance for
    the momentum gate (`hasSingleProvenance` is still stock; only the failover transition
    briefly mixes → momentum 0 for ~1-2 cycles, conservative, accepted).
  - Build-time prereq to verify: the phone keeps reading its G7 during a loan so it has
    fresh EGVs to relay (coexistence, #32/B2).

## Tier C — The everyday flows she'll actually use

- **C1. Carb + bolus during a loan.** ✅ CLEARED 2026-08-11 (Jeremy: "that flow has been
  proven multiple times and is fine"). #47 (blank recommended bolus — wired to the
  WATCH's prediction) and #49 (carbs never travelled phone→watch) were fixed and
  field-run; #30's cosmetic glitches (stock COB blank, Continue button clipped) and #27's
  deferred flow nuances are retired on the field verdict rather than a code change —
  repeated real use is the evidence.
  Still open in this family, and NOT covered by that verdict: **#66**, the phone-side
  carb-duplicate fix, which is built but has never met its scenario (carbs entered while
  the watch is unreachable). Different failure, different path, still needs its test.
- **C2. Loop-close crown ceremony.** (#22, partial)
  Start-unconfirmed is done; the deliberate crown-confirmed close is still pending
  (interim confirm-alert works as a stopgap).

## Tier D — Validation & housekeeping (do last, right before handoff)

- **D1. One fresh clean overnight on the latest build (158+).** Reclaim reliability +
  zero silent failures. Build 157 was 44/44, but the glance rework + wrong-code work
  sits on top of that and hasn't had a clean run.
- **D2. Docs/rulings sync.** Fold the glance rework into `RULINGS.md`; align the two
  ambers (glanceWarn vs stock ring); keep `AS_BUILT_UI.md` current.
- **D3. Document the G7 warmup/prewarm decision.** (#59)
- **D4. Log-pipeline infra.** Fix the phone→iCloud Shortcut so her sessions reach the
  Mac automatically (2026-07-24: watch→phone loan-pulse worked; phone→iCloud hop did
  not — manual upload was needed). Optional: add an idle-state log pulse for pre-loan/
  warmup visibility.
- **D5. Per-phone notification settings (user-only; no API can set these).** On each
  phone that runs the app, in Settings → Notifications → Loop: **Banner Style →
  Persistent** (default Temporary auto-dismisses; a dosing banner should stay until
  read — Jeremy set this on his phone 2026-08-14 and it must be repeated on Caitlin's),
  and leave Time Sensitive notifications ON (the in-app permissions checker already
  nags if they're off, but only after the fact). Banner style is invisible to the app,
  so nothing can nag for it — this checklist line is the only guard.

---

## Deferred (post-first-test)

- Cellular-aware / fully-offline field posture (#24)
- Make scan-adopt the primary E4 reclaim (#54)
- Watch insulin auditability — delivery-page edit/delete (#52)
- Complications: field-test BG complication (#34)
- Simulator flow mode — drive UI without CoreBluetooth (#61)
- Sever OmnipodKit→RileyLink dependency (#56)
- Sim harness: dosing-limit + BT-contention-under-load (#33)
- Juggluco/Android-Wear precedent capture (#38)
- Wrong-code Phase 2: watch→phone code sync (so a bad code fully recovers)

## Pre-production only (not first-test blockers)

- Remove the watch build tag (#58)
- ~~Remove the ladybug / FAKE_NEW_SENSOR test tool~~ (#62) — DONE 2026-08-14. The hooks
  themselves went out with the J-PAKE reader; only the compile condition was still named
  in `LoopConfigOverride.xcconfig`, and that file is now stock (see below).

## Path 2 (after first test proves out)

- Merge Caitlin's branch customizations (March2026 G7-direct foundation).

---

## Signing config — what is committed, and what stays local

`LoopConfigOverride.xcconfig` is committed **byte-identical to stock**: no team id, no bundle
identifier, no extra compile conditions. A receiver clones and fills in their own team, exactly
as they would for any DIY Loop build. Nothing personal to this build sits in the repos.

Locally, that file carries two uncommitted lines — and they belong together:

    MAIN_APP_BUNDLE_IDENTIFIER = com.StockSportMode
    LOOP_DEVELOPMENT_TEAM = 687ZSJ6WD3

The team id alone is not enough. Without the bundle identifier the build falls back to stock's
`com.${DEVELOPMENT_TEAM}.loopkit`, which is a *different* app: it installs alongside the
TestFlight build instead of replacing it, and both then appear on the watch — the duplicate-Loop
confusion seen on 2026-08-14. Keep them together or remove them together.

Do not "fix" this by moving the values into the optional `#include?` one directory above the
checkout. Sibling clones resolve that include to the same file, so a test clone meant to prove
the clean-receiver experience would silently inherit these values and prove nothing.
