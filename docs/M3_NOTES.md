# M3 Notes — Stock CGM Manager over the Proven Transport (watch-from-stock rebuild)

_2026-07-17. Milestone M3 of `DESIGN_FROM_STOCK_REBUILD.md` §1.4/§4: a stock-shaped G7 CGM —
stock G7SensorKit parsing (verbatim) + stock `G7CGMManager` (transport-agnostic) driven
through the `G7SensorDelegate` seam by the fork's proven direct-BLE transport (`G7Client`:
J-PAKE via libg7auth + connect-per-reading scheduler + `WorkoutKeepalive`). Compile-
construction proof only: no UI, no dosing, zero behavior change to the stock watch app.
This milestone was executed in two sessions — the first was interrupted mid-milestone by an
app restart; this file records the assessment of its partial work and the completion._

## 1. Partial-work assessment (interrupted session) — kept vs. reset

| Piece | State found | Verdict | Why |
|---|---|---|---|
| Loop `410434d9` "M3: import the proven G7 direct-BLE transport" (donor files + xcframeworks + bridging/LDFLAGS/EXCLUDED_ARCHS wiring + link/embed G7SensorKit.framework + deployment 7.1→8.0) | committed | **KEEP** | Donor provenance verified byte-for-byte (§4). Wiring replicates the donor. Deployment call re-validated after a detour (§6). |
| G7SensorKit `a842294` (BLE restoration guards + `activationDate` → public) | committed | **KEEP guards / SUPERSEDE access change** | Guards are the M2 recipe, correct. The access-level edit predates the ringfence rule adopted mid-milestone; Swift allows the same seam in an extension file, so the stock file is reverted to verbatim upstream and the seam moved (§5). Superseding commit, not history rewrite. |
| G7SensorKit `707ee54` (G7SensorKit-watchOS target, 23 sources, shared scheme) | committed | **KEEP** | Sound M2-pattern target work; compiles standalone. One defect found downstream (not in the target itself): the **stock iOS target's `SDKROOT = auto`** hijacks the extension's implicit dependency (§7). |
| G7SensorKit `bc33eb9` (`G7GlucoseMessage.init(data:)` → public) | committed | **SUPERSEDE** | Same ringfence reasoning; replaced by a delegating `init?(transportData:)` in the seam file (§5). Stock file back to verbatim. |
| Loop uncommitted: `G7Client.swift` hooks (`onRawEGV`, `onConnectionChange` + 3 call sites) | uncommitted | **KEEP (finished)** | Coherent, marked, minimal — exactly the transport tap the adapter needs. Committed as part of the adapter commit. |
| Loop uncommitted: pbxproj adapter wiring + untracked `G7ClientTransportAdapter.swift` (158 LOC) | uncommitted | **KEEP (finished)** | Complete, well-reasoned adapter at the `G7SensorDelegate` seam. Only change made: retargeted to the ringfenced seam API (`setActivationDate(_:)`, `init?(transportData:)`). |

Nothing was reset/discarded. The two access-level commits stay in history; the superseding
ringfence commit records the reason.

## 2. What M3 built

```
G7Client (proven transport, verbatim donor + 2 hooks)
  onRawEGV(Data)                 full 0x4E control-notification frame
  onConnectionChange(Bool,name)
        │  serial adapter queue
        ▼
G7ClientTransportAdapter (Loop, WatchApp Extension, 159 LOC)
  G7GlucoseMessage(transportData:)   stock parse: trend/predicted/sequence/age/
        │                            algorithm state/display-only bit
        ▼  stock G7SensorDelegate calls (public protocol surface)
G7CGMManager (stock, G7SensorKit-watchOS framework)
  dedup, reliability gating, [40,400] clamp-with-condition, sensor lifecycle,
  .sensorStart events, RawRepresentable persistence
        ▼
CGMManagerDelegate  →  (M4) watch device manager → GlucoseStore → loop
```

`G7TransportBringup.makeStack()` (bottom of the adapter file) is the M3 bring-up entry
point, mirroring M1's `StoreBringup`: uninvoked, compile-construction proof only, deleted
when the M4 watch device manager takes ownership.

Adapter design points (from the interrupted session, verified against stock source):
- activation date derived per-reading exactly as stock `G7Sensor.handleGlucoseMessage`
  (`Date() - messageTimestamp`, `G7Sensor.swift:133`).
- discovery offered via `sensor(_:didDiscoverNewSensor:activatedAt:)` when
  `manager.sensorName` differs; no fabricated identity — no name, no sample.
- disconnects always mapped `suspectedEndOfSession: false`: under connect-per-reading the
  hang-up after every EGV is by design, and `true` would start the stock passive scanner.

## 3. Linkage decisions

- WatchApp Extension links + embeds `G7SensorKit.framework`, resolved to the
  **G7SensorKit-watchOS** product by the same name-based implicit-dependency mechanism as
  LoopKit — which required two fixes (§7): the stock iOS target's `SDKROOT` pinned
  (PODLOAN) and a `G7SensorKit-watchOS` entry added to the **LoopWorkspace scheme**
  (superproject file), mirroring the `LoopKit-watchOS` entry upstream already has there.
- Static libs (`libg7auth-watchos`, `openssl-watchos` xcframeworks) linked via
  per-SDK `OTHER_LDFLAGS` + `HEADER_SEARCH_PATHS` + extension bridging-header import,
  replicated from the donor project. `EXCLUDED_ARCHS = armv7k` on both watch targets
  (the libs carry arm64/arm64_32 only).
- ld warnings (accepted): the static libs were built for watchOS 9.0, linked at 8.0 —
  810 "object file was built for newer 'watchOS' version" warnings, harmless; hardware
  target is watchOS 26.5.

## 4. Donor provenance (verified this session)

All from `LoopWorkspace-prediction` (on-body proven, 100% capture soaks):
- `WatchApp Extension/G7/G7Client.swift` — committed copy diffed **byte-identical** to donor.
- `WatchApp Extension/G7/WorkoutKeepalive.swift` — byte-identical.
- `G7Frameworks/` (both xcframeworks) — `diff -rq` clean, byte-identical.

**G7Client deltas vs. donor (the complete list):** two callback properties
(`onRawEGV: ((Data) -> Void)?`, `onConnectionChange: ((Bool, String?) -> Void)?`) and three
call sites (didConnect, didDisconnect, readEGV post-`gotEGV`), all commented
`M3 (watch-from-stock)`. `onRawEGV` fires with the complete frame BEFORE the legacy inline
parse/plausibility gate — state gating is the stock manager's job in this stack. The
legacy inline parser and `onEGV` remain untouched (still used by the crude UI path; they
retire with the M4 rewiring).

## 5. Ringfence inventory (PODLOAN) — G7SensorKit module

Rule applied (adopted since the original M3 launch): stock-module modifications live in ONE
dedicated extension file where Swift allows; unavoidable out-of-file touches carry a
`PODLOAN` marker. Audit: `grep -rn PODLOAN` in the submodule.

- **`G7SensorKit/G7SensorKit+WatchTransportSeam.swift`** (new, the ringfence file;
  member of the watchOS target ONLY, so the iOS framework builds from stock sources
  alone): `G7Sensor.setActivationDate(_:)` and `G7GlucoseMessage.init?(transportData:)`
  — the entire transport seam. Replaces the two committed access-level edits;
  `G7Sensor.swift` and `G7GlucoseMessage.swift` are back to **verbatim upstream**.
- **`G7SensorKit/G7CGMManager/G7BluetoothManager.swift`** — 2 marked `#if os(iOS)` sites
  (CoreBluetooth state restoration: restore-identifier option, `willRestoreState`).
  Unavoidably in-file (inside stock method bodies). iOS compiles byte-identical code.
- **`G7SensorKit.xcodeproj/project.pbxproj`** — marked `SDKROOT = iphoneos` pin (was
  `auto`) on the stock iOS framework target's two configs (§7); effective iOS SDK
  unchanged. Plus our own additions (watchOS target/scheme/seam-file membership), which
  are not stock modifications.

Every other file in the module is verbatim upstream (base `0c87905`).

## 6. Deployment-target resolution (the M2 flag)

Resolved: **project-level `WATCHOS_DEPLOYMENT_TARGET` 7.1 → 8.0 in Loop.xcodeproj**
(as the interrupted session committed), matching the M2 watch frameworks and the iOS 15.1
floor. Verified both ways this session: with the §7 fix in place the gates pass at 8.0
**and** at 7.1 (Swift concurrency back-deploys, so even stock 7.1 compiles G7Client) —
the mid-session build failures that briefly implicated the deployment target were
actually §7's dependency hijack. 8.0 kept: it is the committed choice and M4's
OmnipodKit/RileyLink watchOS frameworks already sit at 8.0.

## 7. Build-graph defect found: `SDKROOT = auto` hijacks implicit dependencies

Symptom: LoopWorkspace-scheme iOS builds failed with 66x
`module map file '.../GeneratedModuleMaps-watchos/SwiftCharts.modulemap' not found` in the
WatchApp Extension — a package the watch side never references.

Root cause: the stock iOS `G7SensorKit` framework target uses `SDKROOT = auto`
(LoopKit's iOS target pins `iphoneos`). To XCBuild, `auto` marks the target
platform-specializable, so the extension's name-based implicit dependency on
`G7SensorKit.framework` resolved to the **iOS** target (graph:
"Implicit dependency on target 'G7SensorKit'…") instead of `G7SensorKit-watchOS`,
dragging the iOS-side dependency closure — and its SwiftCharts package modulemap flags —
into the watchos build description, where nothing generates that modulemap. Deployment
target and scheme membership were ruled out experimentally (the flag persisted at 7.1 and
8.0 while the edge was hijacked, and vanished at both once fixed).

Fix (two parts):
1. PODLOAN pin `SDKROOT = iphoneos` on the stock iOS target's two configs (no effective
   change on iOS — `SUPPORTED_PLATFORMS` already pins iphoneos there).
2. `G7SensorKit-watchOS` added to the LoopWorkspace scheme's build action (superproject),
   mirroring upstream's own `LoopKit-watchOS` entry. (Not isolated as strictly necessary
   once the pin is in, but it is the upstream precedent shape.)

After the fix the graph reads
"Implicit dependency on target 'G7SensorKit-watchOS' … via file 'G7SensorKit.framework'".
**M4 note:** OmnipodKit/RileyLinkKit targets also use `SDKROOT = auto` in places — when M4
links those frameworks into the extension, audit for the same hijack before debugging
phantom package errors.

## 8. Build verification (Xcode 26.6 / 17F113, derived data `../.dd-fromstock`, CODE_SIGNING_ALLOWED=NO)

- `-scheme LoopWorkspace -destination 'generic/platform=iOS'` — `** BUILD SUCCEEDED **`, exit 0.
- `-scheme WatchApp -destination 'generic/platform=watchOS'` — `** BUILD SUCCEEDED **`, exit 0.
- Standalone gate: `-scheme G7SensorKit-watchOS -destination 'generic/platform=watchOS'` —
  `** BUILD SUCCEEDED **`, exit 0.
- Symbol check: `setActivationDate` / `transportData` present in the watchos
  `G7SensorKit.framework` binary.

## 9. Open items for M4

- Wire the stack: real watch device manager becomes `cgmManagerDelegate`, owns
  `G7TransportBringup`'s role, routes `NewGlucoseSample`s into the watch `GlucoseStore`;
  delete the bring-up enum; retire `G7Client`'s inline parser + `onEGV` path and the crude
  UI's direct consumption.
- `sensor.resumeScanning()` / `scanForNewSensor()`: stock `didRead` still calls
  `scanForNewSensor()` on failed-sensor/session-ended states, which would start the
  passive scanner. Harmless while uninvoked; M4 must neuter or own it (the
  inject-under-G7Sensor upstreamable seam, design doc §6).
- Concurrency: `G7Sensor.activationDate` is stock-confined to the BLE manager queue; the
  adapter's serial queue is the only writer while the passive listener is idle. Revisit if
  the stock sensor is ever started alongside the transport.
- G7Client transport fixes from the review (BLE slice crashes `:1360`, IUO peripheral
  `:1133`, superseded handshake tasks `:1093`, sensor-swap `:1017`, hardcoded PIN,
  `FAKE_NEW_SENSOR`) — deliberately NOT applied in M3 (verbatim import first); they are
  direct patches on a kept asset, scheduled with the M4 rewiring.
- Overnight soak + capture-parity acceptance (`soak_analyze.py` vs M0 baseline), fabricated
  display-only/below-40 frames — needs the M4 wiring to observe output.
- SwiftCharts phantom-flag audit when linking the M2 frameworks (§7).
