# Handover: Watch Prediction + Standalone Closed Loop

**For:** an agent converging / continuing this work.
**Date:** 2026-07-12. **Status:** sim-validated, NOT merged, NOT on hardware.
**One-line:** a phone-free Apple Watch mode that runs the real Loop algorithm
against a manually-entered (later: streamed) BG, shows a prediction + dosing
recommendation, and can close the loop to enact temp basals on a loaned Omnipod.

---

## 1. Repos, branches, latest commits

**Canonical location:** `/Users/jeremybarnum/Downloads/Loop/March2026/LoopWorkspace-prediction/`
— a full local clone of LoopWorkspace (all 21 submodules). **All the work is
here; the original `LoopWorkspace/` repos are ~35 commits behind.**

| Repo | Branch | Tip | Mainline base | Ahead |
|---|---|---|---|---|
| Superproject `LoopWorkspace-prediction` | `prediction-workspace` | `daf0991` ⚠️ STALE | — | — |
| `Loop` submodule | `prediction` | `798edf8a` | `e129d6cf` (show-mode) | 38 |
| `LoopKit` submodule | `prediction-watchos` | `641f8ed1` | `d261da98` | 4 |
| all other submodules | mainline | unchanged | — | 0 |

### Convergence gotchas
- **Superproject pin is stale.** `daf0991` pins `Loop@ef26b9de` + `LoopKit@c97bd056`
  (mid-session). Real tips are `Loop@798edf8a` + `LoopKit@641f8ed1`. Re-pin
  (`git add Loop LoopKit && git commit`) or read submodule tips directly.
- **Original repos are behind.** `LoopWorkspace/Loop`'s `prediction` is at
  `ef26b9de`; `LoopWorkspace/LoopKit`'s `prediction-watchos` at `c97bd056`. The
  clone's submodule origins point at `LoopWorkspace/.git/modules/{name}` (local),
  so to converge, fetch from the clone's submodule working paths, e.g.
  `git fetch /Users/.../LoopWorkspace-prediction/Loop prediction`.
- The `jb` remote in the original repos also has `prediction` / `watch-prediction`
  branches — verify tips before assuming they match the clone.

### LoopKit commits (upstream-relevant, not just watch)
- `720ba2ab` add LoopAlgorithm files to the **LoopKit-watchOS** target
- `6e018f62` **fix target-range Codable decode bug** (upper bound was built from
  `minValue`, collapsing the correction range to a point) + convert
  `generatePrediction` crash-preconditions to thrown `AlgorithmError`
- `c97bd056` implement `LoopAlgorithm.generateRecommendation` (was a stubbed-out
  TODO by Pete)
- `641f8ed1` algorithm + scenario tests (`LoopKitTests/LoopAlgorithmTests.swift`)

---

## 2. Build / run

**Open** `LoopWorkspace-prediction/LoopWorkspace.xcworkspace`, scheme
**LoopWorkspace** — a standard Loop build. Can be open at the same time as the
main `LoopWorkspace/` window (no shared files — that's why the clone exists;
the earlier worktree+scratch-workspace approach caused Xcode "already opened"
conflicts and is DELETED).

- **CLI build (isolated, never touches Xcode's DerivedData):**
  `xcodebuild -workspace LoopWorkspace.xcworkspace -scheme LoopWorkspace -destination generic/platform=iOS -configuration Debug -derivedDataPath ../.dd-cli-clone build`
- **Sim iteration rule:** watch-code changes need the **WatchApp scheme** run
  explicitly at the watch sim — a phone-scheme install does NOT reliably
  propagate the watch app. Verify the installed build via the appex dylib mtime
  when in doubt.
- Same bundle ID as mainline builds → last install wins on any sim/device.
- Sim exercises the **demo pod path** (`WatchPodLoanCoordinator.isSimulatorDemo`,
  `demoJournal`) — no real BLE. Closing the loop on the sim records demo temps;
  it does not touch a real pod.

---

## 3. Architecture (mirrors Loop's structure deliberately)

Everything under `Loop/WatchApp Extension/`. The design principle Jeremy
enforced: **reuse Loop's code/concepts; expose deliberate simplifications; do
not reinvent.** Each watch piece maps to a phone analog:

| Phone (canonical Loop) | Watch analog | Role |
|---|---|---|
| `LoopDataManager` | **`WatchPredictionStore`** | single source; observes glucose/carb/journal/settings/phase, recomputes ONE prediction, posts `didUpdate` (display) + `didLoopTick` (loop) |
| `LoopAlgorithm.generateRecommendation` | **`WatchPredictionEngine`** | assembles `LoopPredictionInput` from synced schedules + journal + manual BG; runs the real algorithm; returns `WatchPredictionOutput` (+ `CorrectionMath` teaching view) |
| `DoseEnactor` + `enactRecommendedAutomaticDose` + `loop()` | **`WatchAutoLoop`** | open/closed policy; consumes the store; `loopCycle` enacts on `didLoopTick` |
| `PumpManager.enactTempBasal(unitsPerHour:for:)` | **`WatchPodLoanCoordinator.enactTempBasal(unitsPerHour:for:)`** | the pod interface for the loaned Omnipod (journal, proof caps, loud failure) |
| `DoseStore` | the **loan journal** (`PodLoanJournal`, OmniBLECore) + `journalDidChangeNotification` | the watch has no LoopKit DoseStore for loan doses |
| `settings.didSet → notify(.preferences)` | `LoopDataManager.didUpdateContextNotification` (watch-side manager) | settings-change recompute |

### Key design facts
- **Effects config = `[.insulin, .carbs]`** (no momentum/RC) — this is EXACTLY
  what Loop's `predictGlucoseFromManualGlucose` uses; verified against the phone.
  When streaming BG lands, switch effects on the newest sample's `wasUserEntered`
  flag (manual → insulin+carbs; CGM stream → full effects incl momentum/RC).
- **Open loop = advisory** (recommendation shown, nothing enacted, like the phone).
  **Closed loop (`isClosed`) = enact.** Per-session, always starts open; closing
  is a crown-confirm ceremony (`BolusConfirmationView`).
- **Temp semantics (Loop-faithful):** duration is a parameter from the
  recommendation (30 min, not the manual path's 3h); `duration 0` = cancel/revert
  to schedule; `rate 0` + duration = bounded zero temp (Loop's "suspend"). The
  manual `setBasalRate` (3h, 0→indefinite suspend) is left as-is for rider hold —
  a deliberate split.
- **Feedback-oscillation fix (critical):** enactment fires ONLY on `didLoopTick`
  (new glucose + 5-min heartbeat = Loop's `loop()` triggers). Dose/carb/settings
  recomputes post `didUpdate` (display) only. Without this, an enacted dose's
  own journal write instantly re-triggered the loop with zero elapsed time and it
  oscillated temp⇄cancel. Do not route enactment onto `didUpdate`.
- **Lenient staleness:** BG older than `inputDataRecencyInterval` (15 min) → no
  new temps; the active one expires on the pod's clock. Matches the phone (which
  collects `glucoseTooOld` and skips enactment without cancelling).

---

## 4. Design rulings (source of truth: `docs/WATCH_STANDALONE_UI_AUTOLOOP.md`)

1. Manual BG entry: tap the BG number on the HUD.
2. No graphs on the watch — trend arrows only.
3. Closed-loop staleness: lenient (above).
4. Dose caps: therapy-settings max, temp-only, NO auto-bolus. *(See review item
   #1/#4 — the IOB clamp is currently dropped, so "same as phone" isn't exact.)*
5. Manual vs streamed BG must follow the Loop idiom (researched; citations in
   the doc's "Manual vs. streamed BG" section).
6. Stay Loop-idiomatic; mark deliberate deviations in comments.

---

## 5. Open items (source of truth: `docs/PREDICTION_CODE_REVIEW_2026-07-12.md`)

**Discuss-first (enacted insulin can differ from Loop or from the screen):**
1. **Missing IOB clamp** — phone bounds auto temps by max-basal AND
   `additionalActiveInsulinClamp` (maxBolus×2 − IOB); watch omits it. HIGH.
2. **Manual-suspend override** — watch `loopCycle` has no `pumpSuspended` check;
   phone refuses to auto-dose while suspended. HIGH.
3. **Display/enact cap mismatch** — screen shows therapy-max-bounded rate; enact
   re-caps at the proof limit (1.0 intended), so "would set 2.50" → pod gets 1.00.
4. **What the real temp cap should be** — 1.0 proof cap contradicts ruling #4;
   decide if 1.0 is the loop ceiling or just the manual-dial ceiling.

**Other:** three independent `WatchPredictionEngine` instances (entry/detail
screens) re-introduce cross-surface drift the store was built to kill — route
through the store. Enactment marked done before success (no in-prediction
retry). Full list in the review doc.

**Pre-person checklist:** revert `TEMP-TEST-CAP` (`WatchPodLoanCoordinator`
`maxTempBasalRate` 3.0 → 1.0); resolve the 4 items above; real-device closed
loop needs Jeremy's explicit go (standing rule — ask before any device-mutating
or dosing action).

**Not built yet:** parity fixture test (phone live-path vs `generatePrediction`
on identical inputs — the thing that upgrades "plausible" to "provably the
phone's math"); provenance-based effect switch for streaming BG; Siri voice
entry (cellular watch).

---

## 6. What's validated vs not
- **Validated on paired sims:** manual BG → eventual BG + correction range +
  temp recommendation; IOB/COB cross-checked against the phone HUD; closed-loop
  enactment cadence (no oscillation); the correction-math derivation vs DoseMath.
- **NOT validated:** end-to-end dynamic carb absorption with real sparse entries
  (the scenario tests pin the algorithm synthetically, not the watch flow);
  anything on hardware; the real loan-grant dose-history payload (sim fakes the
  grant, so it uses the pull path instead).
