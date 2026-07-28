# Sport Mode — Pre-Release Checklist (Path 1)

**Purpose.** The go/no-go list to finish on `watch-from-stock` before Caitlin (a real
T1D user) tests it on-wrist. This is insulin dosing on a real person, so the bar is
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
  - Relay the phone's EGVs over the existing WCSession loan channel — fresher + more
    deterministic than reading phone BG from HealthKit on the watch (HK watch-sync lag
    would undercut the point). Supersedes the original "read from HealthKit" framing.
  - Both sources write the watch glucose store; SELECTION is stock's most-recent-fresh-
    wins via the ported fresh/aging/stale gate (#48) — NOT source-stateful. A stale phone
    sample automatically loses to a fresh direct sample, so once the phone is out of range
    nothing "waits" for it (Jeremy's key constraint).
  - Phone-preferred DEDUP: before writing a direct sample, suppress it ONLY if a *fresh*
    phone sample already covers that ~5-min EGV window; never suppress a direct read when
    the phone sample is absent or stale. Keeps ~one sample/window → single provenance for
    the momentum gate (`hasSingleProvenance` is still stock; only the failover transition
    briefly mixes → momentum 0 for ~1-2 cycles, conservative, accepted).
  - Build-time prereq to verify: the phone keeps reading its G7 during a loan so it has
    fresh EGVs to relay (coexistence, #32/B2).

## Tier C — The everyday flows she'll actually use

- **C1. Carb + bolus during a loan.** (#30 + #47 + #49)
  #30: carb-entry glitches (stock COB blank, Continue button clipped).
  #47: recommended bolus is blank during a loan (wire the stock flow to the WATCH's
  prediction). #49: carbs never travel phone→watch (grant carries insulin history but
  no carb history — no COB).
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
- Remove the ladybug / FAKE_NEW_SENSOR test tool (#62)

## Path 2 (after first test proves out)

- Merge Caitlin's branch customizations (March2026 G7-direct foundation).
