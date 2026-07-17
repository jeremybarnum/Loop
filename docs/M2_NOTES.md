# M2 Notes — Stock Pod Driver on the Wrist (watch-from-stock rebuild)

_2026-07-17. Milestone M2 (the risk gate) of `DESIGN_FROM_STOCK_REBUILD.md` §4, executed
against the PURE upstream tree (LoopWorkspace dev 3.14.3). Scope this pass: the compile
gate only — the full stock pod-driver core, including the pump manager and its
uncertain-delivery machinery, building as a watchOS framework. The bench-pod
kill-mid-bolus acceptance drill and the `PumpManagerDelegate` watch host are follow-on
M2 work (they need the M3+ watch app wiring to exist)._

## 1. Reality vs. the design doc: there is no OmniBLE in this vintage

The design doc (written against the `g7-build-next` tree) prescribes an `OmniBLE-watchOS`
target in the OmniBLE submodule. **This stock tree has no OmniBLE submodule.** Upstream
dev 3.14.3 replaced OmniBLE + OmniKit with loopandlearn's unified **OmnipodKit**
(submodule `OmnipodKit/`, checkout `08c4efe`), which merges Dash (BLE) and Eros
(RileyLink) support into one kit:

- The pump manager is `OmniPumpManager` / `OmniPumpManagerState`
  (`OmnipodKit/PumpManager/`), directly descended from `OmniBLEPumpManager` (its header
  says so). All the machinery whose absence caused the prototype's critical cluster is
  here: `PendingCommand.swift`, `UnfinalizedDose.swift`, `PodState` persistence,
  `recoverUnacknowledgedCommand`, `PodDoseProgressEstimator`.
- **`OmniPumpManager` subclasses `RileyLinkPumpManager`** (for Eros) and imports
  RileyLinkKit/RileyLinkBLEKit unconditionally, with Eros branches woven through it.
  Guarding out RileyLink would have meant forking the class hierarchy — the opposite of
  minimal-diff. The cheaper, stock-faithful move: **compile RileyLinkKit and
  RileyLinkBLEKit for watchOS too** (they are small — 30 sources total, CoreBluetooth +
  Foundation + LoopKit only, and CoreBluetooth exists on watchOS).

Consequence: M2 touched **three** submodules (OmnipodKit, RileyLinkKit, LoopKit), not
one. Every change is on a `watch-from-stock` branch in its submodule.

## 2. New targets (project-file work, no source semantics)

| Project | New target | Product | Mirrors |
|---|---|---|---|
| `OmnipodKit.xcodeproj` | **`OmnipodKit-watchOS`** | `OmnipodKit.framework` (watchos) | `LoopKit-watchOS` precedent: same product name, `SDKROOT=watchos`, `SUPPORTED_PLATFORMS="watchos watchsimulator"`, `TARGETED_DEVICE_FAMILY=4`, `APPLICATION_EXTENSION_API_ONLY=YES`, `WATCHOS_DEPLOYMENT_TARGET=8.0` |
| `RileyLinkKit.xcodeproj` | **`RileyLinkBLEKit-watchOS`** | `RileyLinkBLEKit.framework` (watchos) | same pattern |
| `RileyLinkKit.xcodeproj` | **`RileyLinkKit-watchOS`** | `RileyLinkKit.framework` (watchos), depends on `RileyLinkBLEKit-watchOS` | same pattern |

Linkage: `OmnipodKit-watchOS` links `LoopKit.framework`, `RileyLinkKit.framework`,
`RileyLinkBLEKit.framework` (all resolved to the watchOS-built products by workspace
implicit dependencies — the same name-based mechanism the WatchApp Extension already
uses for LoopKit) plus the `CryptoSwift` SPM product (its manifest supports watchOS;
the predicted `.bytes`/`.bytesArray` toolchain collision did **not** occur with
Xcode 26.6). NOT linked: LoopKitUI, RileyLinkKitUI, SlideButton (UI-only).

**Included sources** (via the Xcode-16 synchronized folder, minus exceptions): all of
`Bluetooth/`, `OmnipodCommon/`, `PumpManager/`, `Eros/`, and the non-UI `Common/`
helpers. Eros compiles for watchOS for free once RileyLinkBLEKit does — cheaper to keep
than to carve out, and it keeps the diff smaller.

**Excluded from the watchOS target** (file-by-file exception list; folder-level
exceptions are silently ignored by the build system, a gotcha worth remembering):

- `PumpManagerUI/` entirely (60 files, incl. `PodKeepAliveView.swift` — see §3),
- `Services/O5AppAttestService.swift` (DeviceCheck app-attest; referenced only by
  PumpManagerUI views; also avoids a watchOS-9 deployment floor),
- `Resources/blank.wav`, `Resources/heartbeat.wav` (audio-keepalive assets),
- UIKit/SwiftUI UI helpers in `Common/`: `UIColor.swift`, `UIDevice.swift`,
  `NibLoadable.swift`, `Image.swift`, `FrameworkLocalText.swift`,
- `Info.plist` (same exception as the iOS target).

Shared scheme `OmnipodKit-watchOS` added (buildImplicitDependencies=YES), so the gate-A
invocation is a one-liner via the workspace.

## 3. Upstream source files touched — the complete inventory

**10 `#if os(iOS)` guard sites in 4 files. Zero deletions, zero import edits, zero
behavior change on iOS** (every guard keeps the original code compiling exactly as
before on iOS).

| # | File | Sites | What is guarded and why |
|---|---|---|---|
| 1 | `OmnipodKit/PumpManager/OmniPumpManager.swift` | 5 | (a) `finishInit` Dash block: `UIApplication` background/foreground observers + `podKeepAliveSetup()` (UIApplication does not exist on watchOS; keepalive lives in excluded PumpManagerUI). (b) `backgroundTask` property + `appMovedToBackground/Foreground` (the `BackgroundTask` class is defined in excluded `PodKeepAliveView.swift`). (c) pairing-path keepalive auto-enable block (`Storage` also lives in PodKeepAliveView). (d) `iPhoneWithPossibleInPlayIssues` body (`UIDevice.modelName`; watchOS branch returns `false` — a watch host is never an affected iPhone). (e) `reservoirLevelHighlightState` property (its type is declared inside excluded `OmniSettingsViewModel.swift`; only UI consumes it). |
| 2 | `OmnipodKit/PumpManager/PodCommsSession.swift` | 1 | the `gotPodResponse()` keepalive notification call (free function defined in excluded `PodKeepAliveView.swift`). |
| 3 | `OmnipodKit/Bluetooth/BluetoothManager.swift` | 2 | `CBCentralManagerOptionRestoreIdentifierKey` init option (watchOS: `options: nil`) and the `willRestoreState` delegate method — CoreBluetooth state restoration is iOS-only, exactly as the design doc predicted. |
| 4 | `RileyLinkBLEKit/RileyLinkBluetoothDeviceProvider.swift` | 2 | same two state-restoration sites, RileyLink stack. |

Plus one **project-only** LoopKit change (no source touched):
`LoopKit/DeviceManager/PumpManager.swift` added to the `LoopKit-watchOS` Sources phase.
Upstream's watchOS target (139 of 182 sources) omits the whole `PumpManager` protocol
family (`PumpManager`, `PumpManagerDelegate`, `PumpManagerResult`,
`PumpManagerStatusObserver`) — nothing pump-shaped ever ran on upstream's watch. The
file imports only Foundation + HealthKit and compiled cleanly. This is the same
target-membership class of change the design doc lists as upstreamable (§6), and the
M3+ watch host needs `PumpManagerDelegate` from it.

Notable non-events: `BeepPreference.swift`'s SwiftUI import, `RileyLinkListDataSource`'s
SwiftUI, `OmniPumpManager`'s Combine/UserNotifications/HealthKit/CryptoKit imports, the
whole `Bluetooth/Pair` + `EnDecrypt` crypto stack, and all of Eros — all compile for
watchOS untouched.

## 4. Build verification (Xcode 26.6 / 17F113, derived data `../.dd-fromstock`)

- **Gate A (new watchOS port):**
  `xcodebuild -workspace LoopWorkspace.xcworkspace -scheme OmnipodKit-watchOS
  -configuration Debug -destination 'generic/platform=watchOS'
  -derivedDataPath ../.dd-fromstock CODE_SIGNING_ALLOWED=NO build`
  → `** BUILD SUCCEEDED **`, exit 0. Products: `OmnipodKit.framework`,
  `RileyLinkKit.framework`, `RileyLinkBLEKit.framework` for watchos; symbol check
  confirms `OmniPumpManager`, `PendingCommand`, `UnfinalizedDose` in the watch binary.
- **Gate B (untouched iOS side):**
  `xcodebuild -workspace LoopWorkspace.xcworkspace -scheme LoopWorkspace
  -configuration Debug -destination 'generic/platform=iOS'
  -derivedDataPath ../.dd-fromstock CODE_SIGNING_ALLOWED=NO build`
  → `** BUILD SUCCEEDED **`, exit 0.

## 5. Open M2 items (not this pass)

- The **kill-mid-bolus bench drill** (the milestone's acceptance criterion) — needs the
  watch host (`PumpManagerDelegate` implementation, `rawState` persistence, DoseStore
  routing) which is M3+ integration; the design doc's M2 decision gate is answered on
  the compile question, which was the risk being retired.
- The new framework is **not** linked into the WatchApp Extension (per plan).
- `WATCHOS_DEPLOYMENT_TARGET=8.0` chosen for the new targets (iOS side is 15.1 ≈
  watchOS 8; the WatchApp Extension itself is 7.1 — if M3 links the framework there,
  either raise the extension or lower the frameworks; the only 9.0+ API,
  DeviceCheck, is in the excluded Services file).
- Keepalive semantics on watchOS: the guards disable loopandlearn's iPhone audio
  keepalive wholesale. The watch has its own keepalive strategy (`WorkoutKeepalive` +
  armed-connect) per the design doc §5.1; nothing needed from the driver here, but
  M3's host should confirm reconnect behavior on a bench pod.
