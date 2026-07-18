# M4 Notes — One Loop, Stock-Shaped (watch-from-stock rebuild)

_2026-07-17. Milestone M4 of `DESIGN_FROM_STOCK_REBUILD.md` §1.5/§4: the watch closed loop
assembled end-to-end from stock components — LoopKit algorithm sources compiled for watchOS,
the M2 pod-driver frameworks linked into the extension, the M3 CGM stack delegate-wired into
LoopKit stores, and a WatchLoopManager that mirrors the PHONE's stock LoopDataManager policy
paths in miniature. Construction + compile proof only: the enact seam is typed against the
stock `PumpManager` protocol but connected to nothing, the assembly entry point is uninvoked,
and zero behavior claims are made. The design doc's M4 acceptance items (advisory open-loop
comparison, churn/oscillation checks) are behavioral and move to the hardware phase._

## 1. LoopKit: DoseMath + LoopAlgorithm into `LoopKit-watchOS` (the upstreamable list)

Project-file-only, exactly the class of change M2 made for `PumpManager.swift` — zero source
edits, all 12 files compile for watchOS untouched. The list is identical to the prediction
fork's commit `720ba2ab` ("Add LoopAlgorithm (12 files) to LoopKit-watchOS target"), which
proved the same set on the same-vintage codebase; the file-reference IDs matched upstream's,
so the fork's build-file entries were mirrored verbatim:

| File | Why the loop policy needs it |
|---|---|
| `LoopAlgorithm/DoseMath.swift` | `recommendedTempBasal` / `recommendedAutomaticDose` / `recommendedManualBolus` — the recommendation entry points, incl. `additionalActiveInsulinClamp` and `ifNecessary` continuation |
| `LoopAlgorithm/LoopAlgorithm.swift` | `generatePrediction` (upstream's `generateRecommendation` is still a stub in this vintage) |
| `LoopAlgorithm/LoopAlgorithmInput.swift` | input struct for the above |
| `LoopAlgorithm/LoopAlgorithmSettings.swift` | settings struct for the above |
| `LoopAlgorithm/LoopPredictionInput.swift` | prediction input struct |
| `LoopAlgorithm/LoopPredictionOutput.swift` | prediction output struct |
| `LoopAlgorithm/GlucosePredictionAlgorithm.swift` | the algorithm protocol |
| `InsulinKit/ManualBolusRecommendation.swift` | `ManualBolusRecommendation` + `BolusRecommendationNotice` (DoseMath return type) |
| `InsulinKit/AutomaticDoseRecommendation.swift` | `AutomaticDoseRecommendation` (DoseMath return type) |
| `RetrospectiveCorrection/RetrospectiveCorrection.swift` | the RC protocol |
| `RetrospectiveCorrection/StandardRetrospectiveCorrection.swift` | the default RC (what the watch runs) |
| `RetrospectiveCorrection/IntegralRetrospectiveCorrection.swift` | IRC (referenced by `LoopAlgorithm.generatePrediction`; phone-togglable) |

Upstream PR candidate together with M2's `PumpManager.swift` addition (design doc §6).

## 2. SDKROOT audit (the M3 §7 landmine) — result: nothing to pin

Audited every target in `OmnipodKit.xcodeproj` and `RileyLinkKit.xcodeproj` before linking
(M3's instruction). **No target uses `SDKROOT = auto`.** The stock iOS framework targets
(`OmnipodKit`, `RileyLinkBLEKit`, `RileyLinkKit`, `RileyLinkKitUI`) leave SDKROOT unset at
the target level and inherit the **project-level `SDKROOT = iphoneos`** — the same resolved
pin LoopKit's iOS target has, and not the specializable literal `auto` that made XCBuild
hijack G7SensorKit's implicit dependency in M3. (G7SensorKit remains the only kit that
carried target-level `auto`; its PODLOAN pin from M3 stands.)

Confirmed empirically, not just by inspection — the iOS-gate build graph resolves every
extension edge to the watch targets:

```
➜ Implicit dependency on target 'G7SensorKit-watchOS'    ... via file 'G7SensorKit.framework'
➜ Implicit dependency on target 'OmnipodKit-watchOS'     ... via file 'OmnipodKit.framework'
➜ Implicit dependency on target 'RileyLinkKit-watchOS'   ... via file 'RileyLinkKit.framework'
➜ Implicit dependency on target 'RileyLinkBLEKit-watchOS' ... via file 'RileyLinkBLEKit.framework'
```

Consequently the OmnipodKit and RileyLinkKit submodules have **no M4 commits** — their M2
state was already correct. The phantom-SwiftCharts audit (M3 §9) came up clean.

## 3. Pod-driver frameworks linked into the WatchApp Extension

`Loop.xcodeproj` (WatchApp Extension target `43A9437D`): `OmnipodKit.framework`,
`RileyLinkKit.framework`, `RileyLinkBLEKit.framework` added to the Frameworks phase
(`43A9437B`) and Embed Frameworks phase (`43C667D7`), the exact pattern M3 used for
`G7SensorKit.framework` (BUILT_PRODUCTS_DIR refs, name-based implicit dependency onto the
watchOS targets). The three watch framework targets were also added to the **LoopWorkspace
scheme's** build action (superproject file), mirroring the `LoopKit-watchOS` /
`G7SensorKit-watchOS` entries. Verified in the built product: all three embedded in the
appex `Frameworks/` and linked by the extension binary (`otool -L`).

The `OmniPumpManager` (with its `PendingCommand`/`UnfinalizedDose`/
`recoverUnacknowledgedCommand` machinery, M2) is thereby available to watch app code as a
`PumpManager` — which is precisely the type the M4 enact seam is written against.

## 4. The loop assembly (`WatchApp Extension/StockLoop/`)

App code, not a hardware module — no PODLOAN markers needed; kept in clearly-named new files.

```
G7Client (proven transport: J-PAKE via libg7auth, connect-per-reading scheduler)
    │ raw EGV frames / connection events
    ▼
G7ClientTransportAdapter (M3, stock G7SensorDelegate seam)
    ▼
G7CGMManager (stock G7SensorKit-watchOS: parse, dedup, reliability gating, clamping)
    │ CGMManagerDelegate (delegateQueue = WatchLoopManager.deviceQueue)
    ▼
WatchLoopManager (StockLoop/WatchLoopManager.swift, 801 lines incl. citations)
    │ GlucoseStore ── CarbStore ── DoseStore   (LoopKit, real persistence — M1)
    │ recency gating: LoopCoreConstants.inputDataRecencyInterval / futureGlucoseDataInterval
    │ effects: same store calls as phone update(for:) — momentum, insulin ±pending,
    │          counteraction, dynamic carb absorption, IOB, retrospective correction
    │ prediction: LoopMath.predictGlucose + extend-to-model-duration tail
    │ recommendation: DoseMath.recommendedTempBasal with additionalActiveInsulinClamp
    │          (= maxBolus×2 − IOB) INSIDE the call; rateRounder from the pump manager
    ▼
PumpManager enact seam (WatchDoseEnactor) ──── UNCONNECTED in M4 (pumpManager == nil)
```

`StockLoopStack.assemble()` (StockLoop/StockLoopStack.swift, 125 lines) constructs and wires
the whole graph; **it has no call sites** — M4 proves assembly, not dosing. M5 integration
gives it an owner in the app lifecycle.

### Phone patterns mirrored (file: `Loop/Managers/LoopDataManager.swift` @ this tree)

| Phone | Watch mirror | Notes |
|---|---|---|
| `loop()` / `loopInternal()` | `WatchLoopManager.loop()` | dataAccessQueue confinement kept |
| `update(for: .loop)` effect refresh (:963) | `updateCachedEffects()` | same store entry points, same DispatchGroup shape, same cache-invalidation couplings (counteraction → carbEffect) |
| `updateRetrospectiveGlucoseEffect()` (:1578) | same name | identical math; guard-throw where the phone force-unwraps settings (nil = normal pre-push state on the watch → deny, not crash) |
| `predictGlucose(using:)` (:1228) | `predictGlucose(includingPendingInsulin:)` | same recency gates, same `LoopMath.predictGlucose`, same tail-extension; the potential-bolus/-carb arms await the meal flow |
| `updatePredictedGlucoseAndRecommendedDose(with:)` (:1695) | same name | same config-denial list, same `automaticDosingIOBLimit = maxBolus × 2.0` and `iobHeadroom`, same `recommendedTempBasal(... additionalActiveInsulinClamp: iobHeadroom ...)` call (:1858 parity) — the clamp lives INSIDE DoseMath, never post-hoc (the crude version's "silent algorithm fork" finding does not return) |
| `recommendBolusValidatingDataRecency` (:1500) + `recommendManualBolus` (:1537) | `recommendManualBolus(completion:)` | recency-validated, `pendingInsulin: 0` with prediction-includes-pending, no fabricated glucose placeholder |
| `enactRecommendedAutomaticDose()` (:1894) | same name | same 5-min freshness gate, same `pumpSuspended` gate; nil pump manager → explicit `.pumpManagerUnconnected`, never a silent success |
| `DoseEnactor.enact(recommendation:with:)` | `WatchDoseEnactor` | same temp-basal-then-bolus sequencing over stock `PumpManager` methods |
| `DeviceDataManager.cgmManager(_:hasNew:)` (:1001) + `processCGMReadingResult` (:580) | `CGMManagerDelegate` extension | samples → `GlucoseStore.addGlucoseSamples` first, then the same 4.2-minute loop-trigger gate |
| private `TemporaryScheduleOverride.isBasalRateScheduleOverriden` (:2362) | same, mirrored | phone helper is `private` in LoopDataManager.swift |

### Deliberate mirror deviations (all deny-or-default-safe, none policy forks)

- `WatchLoopError` mirrors the phone's `LoopError` cases; the phone file is target-bound to
  `StoredDosingDecision` plumbing that has no watch counterpart yet.
- RC implementation fixed to `StandardRetrospectiveCorrection` (the phone's IRC toggle is a
  phone-local UserDefaults not pushed to the watch); both RC classes compile for watchOS.
- Prediction inputs fixed to the phone's compile-time default (all four effects,
  `LoopConstants.retrospectiveCorrectionEnabled == true`); no override-history application
  yet (`…ApplyingOverrideHistory` is phone-side machinery — M5 decides whether overrides
  ride the settings push).
- No `StoredDosingDecision`/`DosingDecisionStore` on the watch (iOS-only in this LoopKit
  vintage; deliberately NOT added to the watch target — the 12-file list stays minimal).

## 5. Scaffolding retired (purpose absorbed)

- **`WatchApp Extension/StoreBringup.swift` (M1) — deleted.** Store construction moved
  verbatim into `StockLoopStack.makeStores()`, including the no-HealthKit mode and the
  not-while-stock-LoopDataManager-is-live caveat (store unification is an M5 item).
- **`G7TransportBringup` enum (M3, bottom of `G7ClientTransportAdapter.swift`) — deleted.**
  `StockLoopStack.assemble()` builds the same stack and additionally wires the delegate.
  The adapter class itself is unchanged apart from comment updates pointing at the new owner.

## 6. Build verification (Xcode 26.6 / 17F113, derived data `../.dd-fromstock`, CODE_SIGNING_ALLOWED=NO)

- `-scheme LoopWorkspace -destination 'generic/platform=iOS'` — `** BUILD SUCCEEDED **`, exit 0.
- `-scheme WatchApp -destination 'generic/platform=watchOS'` — `** BUILD SUCCEEDED **`, exit 0.
- Symbol checks: `recommendedTempBasal`/`recommendedAutomaticDose`/`recommendedManualBolus`
  exported by the watchos `LoopKit.framework`; `WatchLoopManager` in the extension binary;
  OmnipodKit/RileyLinkKit/RileyLinkBLEKit/G7SensorKit in `otool -L` and the appex
  `Frameworks/` directory.
- Two compile fixes surfaced by the gates, both watch-side app code: LoopCore's legacy
  single-parameter `Result<T>` shadows `Swift.Result` inside the extension (qualified), and
  the phone's `isBasalRateScheduleOverriden` helper is `private` to LoopDataManager.swift
  (mirrored with citation).

## 7. TODO(M5-ruling) inventory (all in `StockLoop/WatchLoopManager.swift`)

| Site | Ruling it waits on (design doc §5.3) |
|---|---|
| `pumpManager` property doc | connecting a live pump manager is gated on loan protocol v2 and rulings **#1** (bolus-cap layering / per-loan ceiling) and **#2** (max-temp derivation) |
| `.automaticBolus` strategy arm | ruling **#1** — until ruled, the strategy DENIES dosing (explicit configuration error; no silent fallback to tempBasalOnly) |
| `maxBasalRate` argument in the tempBasalOnly arm | ruling **#2** — max-temp derives from therapy max-basal + its pod-proof-limit companion in the stock-driver world |
| `recommendManualBolus` presentation | ruling **#4** — what replaces the placeholder UX when recency denies; this method supplies policy only |

## 8. Open items for M5

- **Ownership + start**: `StockLoopStack.assemble()` is uninvoked. App-lifecycle ownership,
  transport start (`startSoak`/`prewarmIfPending`), per-session closed-loop opt-in (crown
  ceremony), and the enact-only-on-fresh-reading cadence verification (crude-version
  requirement, design doc §1.5) all land with integration.
- **Settings plumbing**: phone-pushed `LoopSettingsUserInfo` → `WatchLoopManager.settings`
  (today it holds an empty-deny default); decide whether override history rides along.
- **Store unification**: one `PersistenceController` shared with (or replacing) the stock
  watch `LoopDataManager`'s stores — until then `assemble()` must not run beside it.
- **Pump host glue** (M2 open item): `PumpManagerDelegate` implementation — `rawState`
  persistence on `pumpManagerDidUpdateState`, `hasNewPumpEvents` → watch DoseStore,
  `PumpManagerAlert` surfacing — then the kill-mid-bolus bench drill (M2's acceptance).
- **Alert path**: `issueAlert`/PersistedAlertStore conformances are log-only stubs; pod
  fault/occlusion and CGM alerts need the watch notification path (design doc §1.3).
- **G7 cleanups carried from M3 §9**: retire `G7Client`'s inline EGV parser + `onEGV`
  (defined but consumer-less in this tree — verified); own/neuter stock
  `scanForNewSensor()` on failed-sensor states (the inject-under-`G7Sensor` upstreamable
  seam); apply the review's transport fixes (BLE slice `:1360`, IUO peripheral `:1133`,
  superseded handshake tasks `:1093`, sensor-swap `:1017`, hardcoded PIN, `FAKE_NEW_SENSOR`).
- **CGM state/event persistence**: `cgmManagerDidUpdateState` and `PersistedCgmEvent`
  routing are log-only; decide the watch-side persistence story (no CgmEventStore on watch).
- **Behavioral acceptance (design doc M4 criteria)**: advisory open-loop comparison against
  the phone on the same glucose stream, no cancel+set churn (rateRounder in effect),
  IOB-clamp-effective synthetic scenario, oscillation-free cadence — all need hardware
  sessions (owner-gated, ruling #8).

## Resolved-by-architecture: safety-branch review findings H2 + M12

The g7-build-next safety branch carries two findings that this stock-shaped
loop dissolves for free — recorded here so the rebuild reviewer treats them as
closed, not re-opened:

- **M12 (missing rateRounder)** — the crude `WatchPredictionEngine` calls
  `generateRecommendation` with no `rateRounder`, so `DoseMath.ifNecessary`'s
  `matchesRate` never equals the pod's rounded running temp → it would emit a
  fresh temp command every cycle. `WatchLoopManager` passes the pump-grid
  rateRounder into the recommendation call (M4_NOTES §"IOB clamp"/line ~95), so
  `ifNecessary` works: an unchanged temp continues instead of re-commanding.
- **H2 (anchor-latch strands a busy-dropped enact)** — the crude
  `WatchAutoLoop` bolted a per-reading `lastEnactedAnchorDate` latch on as a
  substitute for the broken `ifNecessary` dedup (see M12); because the latch was
  claimed before the pod accepted the command, a busy-drop stranded the reading
  for ~5 min. The stock-shaped loop has **no latch**: `ifNecessary` re-derives
  against the actual running temp every cycle, which is self-healing — a
  dropped enact simply doesn't match next cycle and is re-sent, and the pump
  manager serializes commands rather than silently dropping on busy. Do NOT port
  the anchor latch; deleting it IS the fix. (The safety branch has an interim
  set-latch-on-accept patch; this tree supersedes it.)

## Two stock launch-crash fixes carried on this branch (upstream candidates)

Building the watch feature SURFACED two latent crashes in base Loop's launch
sequence — not bugs this project authored (the code is byte-identical to
upstream/dev), but ones our always-on watch app exposes by relaunching Loop
BEFORE first unlock on every boot (BLE state-restoration + WatchConnectivity).
Both are the same shape: an async launch callback touches an IUO manager that
is only assigned in launchManagers(), which a pre-first-unlock launch defers.

- **Fix #1 — resetLoopManager**: resumeLaunch() → askUserToConfirmLoopReset()
  force-unwrapped the nil `resetLoopManager`. Optional-chained
  (LoopAppManager.swift askUserToConfirmLoopReset).
- **Fix #2 — settingsManager**: registerForRemoteNotifications() ran in
  initialize() (pre-unlock); the async push-token callback
  (remoteNotificationRegistrationDidFinish) force-unwrapped the nil
  `settingsManager`. Moved the registration into launchManagers() after
  settingsManager is wired.

Both are marked `STOCK LAUNCH-CRASH FIX` in-code (deliberately NOT PODLOAN —
they are not part of the watch module) and are UPSTREAM CANDIDATES: they fix
real base-Loop crashes any pre-unlock relaunch can hit. Jeremy will submit the
PRs when ready (separate from this project). The honest demonstration framing:
"this watch project found and fixed two latent stock launch crashes."
