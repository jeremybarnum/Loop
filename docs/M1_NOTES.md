# M1 Notes — Stores on the Wrist (watch-from-stock rebuild)

_2026-07-17. Milestone M1 of `DESIGN_FROM_STOCK_REBUILD.md` §4, executed against the PURE
upstream tree (LoopWorkspace dev 3.14.3, Loop submodule branch `watch-from-stock`, LoopKit
at upstream `7f327027` — no fork code)._

## 1. Linkage inventory — what the stock WatchApp Extension links today

From `Loop.xcodeproj/project.pbxproj`, target `43A9437D` ("WatchApp Extension"),
Frameworks phase `43A9437B`:

| Linked | Built by | Notes |
|---|---|---|
| `LoopKit.framework` | LoopKit.xcodeproj target **`LoopKit-watchOS`** (`A9E67580`, SDKROOT=watchos) | also embedded |
| `LoopCore.framework` | Loop.xcodeproj target **`LoopCore-watchOS`** (`43D9001A`) | also embedded |
| `HealthKit.framework` | SDK | |
| `ClockKit.framework` | SDK | |
| `CoreBluetooth.framework` | SDK | |

Not linked: LoopKitUI (iOS-only, not needed), no SPM products on the watch target in this
stock vintage (the fork's `OmniBLECore` reference does not exist here). The extension has
87 compile sources of its own.

## 2. Store availability in `LoopKit-watchOS` (LoopKit at `7f327027`)

The watchOS framework target compiles 139 sources (iOS target: 182). Verified present in
the `LoopKit-watchOS` Sources phase (`A9E67581`):

- `DoseStore.swift`, `InsulinDeliveryStore.swift`, `PersistenceController.swift`
- `GlucoseStore.swift`, `CarbStore.swift`, `HealthKitSampleStore.swift`
- `InsulinMath.swift`, `CarbMath.swift`, `InsulinModelProvider.swift`,
  `ExponentialInsulinModelPreset.swift`, and the CoreData model classes all three stores need

Verified absent from the watchOS target (iOS-only in this vintage) — none needed for M1:

- `DoseMath.swift` (lives in the 43-file iOS-only set together with the `LoopAlgorithm*`
  files, `DosingDecisionStore`, `SettingsStore`, `Guardrail*`, etc.). This becomes M4's
  concern (the dosing loop), matching the design doc's note that the fork added algorithm
  files to the watchOS target — upstream has not.

## 3. What stock already does, and what M1 added

**Already true in stock** (`WatchApp Extension/Managers/LoopDataManager.swift:64-78`): the
watch extension constructs a `PersistenceController.controllerInLocalDirectory()` (LoopCore
helper, documents directory, no app group) and real LoopKit `CarbStore` + `GlucoseStore`
against it, in no-HealthKit mode (`healthKitSampleStore` defaulted to nil).

**The M1 gap was DoseStore only.** No target-membership or linkage change was required
anywhere — not in LoopKit.xcodeproj (stores already in `LoopKit-watchOS`), not in the
WatchApp Extension frameworks phase (LoopKit already linked+embedded).

**Added:** `WatchApp Extension/StoreBringup.swift` — clearly-marked M1 scaffolding, an
uninvoked `StoreBringup.makeStores()` that constructs `DoseStore` + `GlucoseStore` +
`CarbStore` against a local `PersistenceController` with `healthKitSampleStore: nil`
(HealthKit off pending the owner ruling, per design doc §1.2). Compile-time proof only:
no UI, no call sites, zero behavior change to the stock app. It is deleted when the real
watch device manager (M2+) takes ownership of the stores. Plus the corresponding
project-file wiring (file reference `2FFA80B7`, build file `719E8520` in Sources phase
`43A9437A`).

DoseStore construction mirrors the phone (`DeviceDataManager.swift:315`):
`PresetInsulinModelProvider(defaultRapidActingModel: nil)`,
`longestEffectDuration = ExponentialInsulinModelPreset.rapidActingAdult.effectDuration`,
nil basal/sensitivity schedules (settings plumbing is a later milestone; missing settings
deny dosing — no fabricated defaults).

## 4. Build verification (Xcode 26.6 / 17F113, derived data `../.dd-fromstock`, CODE_SIGNING_ALLOWED=NO)

- `-scheme LoopWorkspace -destination 'generic/platform=iOS'` — BUILD SUCCEEDED (phone side unbroken)
- `-scheme WatchApp -destination 'generic/platform=watchOS'` — BUILD SUCCEEDED (DoseStore + stores instantiate in the watch extension)

## 5. Deviations from the design doc's M1 prescription

- The M1 milestone text also names a debug screen showing DoseStore-computed IOB and the
  20-vector acceptance check. Those require the fork's test vectors and a UI change; this
  pass delivers the store/linkage substrate only (per the rebuild task's M1 scope:
  linkage verified + stores instantiable, compile-time proof, no UI). IOB display and the
  vector check remain open M1 acceptance items.
- App-group vs local storage: chose **local directory**, the smallest stock-faithful step —
  it is exactly what the stock watch extension already does for its two existing stores
  (watchOS has no companion sharing the container, so an app group buys nothing here).
- `DoseMath.swift`/`LoopAlgorithm*` were deliberately NOT added to `LoopKit-watchOS`:
  M1 is stores only; touching LoopKit's project file before M4 needs it would be an
  unforced fork-drift risk on an otherwise pristine upstream submodule.
