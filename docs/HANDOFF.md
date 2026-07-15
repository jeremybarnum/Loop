# Handoff — Loop Show-Mode "state visibility" work

_Last updated 2026-07-12._

**Workspace:** `/Users/jeremybarnum/Downloads/Loop/March2026/LoopWorkspace` (`LoopWorkspace.xcworkspace`)
**Branch (Loop submodule):** `fix-loan-grant-crashflag`, base commit `e129d6cf`
**Sibling submodules:** `LoopKit` and `OmniBLE` both on `formal-handoff` (do not change)

## What this is

"Show Mode" = an Apple Watch borrows control of the Omnipod DASH pod from the phone (phone-free dosing). This branch adds **state visibility** so each device is honest about who controls the pod. **Bench pod only (not on a person).** Full design in [`DESIGN_STATE_VISIBILITY.md`](DESIGN_STATE_VISIBILITY.md) + [`RELEASE_TEST_FINDINGS_2026-07-11.md`](RELEASE_TEST_FINDINGS_2026-07-11.md).

## Committed (validated on device except where noted)

| Commit | What |
|---|---|
| `b57a032a` | **3a** — watch horse button tints amber on pod-link loss |
| `0b133a1e` | watch takeover progress bar + step text |
| `b2ed9ad2` | CrashRecovery false-alert suppression (partial, loan-only) |
| `3d4e3440` | Info.plist: drop `healthkit` capability (kills ITMS-90863/90984 warnings) |
| `674e1b13` | **3b-v1** — phone pod tile shows "Pod Not Connected" the instant the pod is released (keyed on `PumpConnectionLendable.isConnectionReleased`, not 8-min staleness) |

## Uncommitted in the working tree = **3b-v2** (held for Jeremy's wording sign-off)

Phone POLLS the watch over WatchConnectivity for its Show-Mode status; the watch is **answer-only** (no watch timer/push, negligible battery). Tile shows **On Watch** / **Watch Lost Pod** / **Pod Not Connected**. Files:

- `Common/Models/PodLoanGrantUserInfo.swift` — new `WatchLoanStatusRequestUserInfo` (phone→watch) + `WatchLoanStatusUserInfo` reply (`hp` holdsPod, `pc` podConnected). Appended to a shared dual-target file to avoid pbxproj surgery.
- `WatchApp Extension/ExtensionDelegate.swift` — `session(_:didReceiveMessage:replyHandler:)` replies `holdsPod = coordinator.phase == .active`, `podConnected`.
- `Loop/Managers/DeviceDataManager.swift` — `struct WatchLoanReport{watchHoldsPod,podConnected,lastHeard}` + `var lastWatchLoanReport`; cleared in `reclaimPodFromWatch`.
- `Loop/Managers/WatchDataManager.swift` — poll driver: 30s foreground `Timer` + immediate poll on grant / `didBecomeActive` / each loop (`updateWatch`) / **`sessionReachabilityDidChange`**; `sendMessage` guarded on `isReachable`; self-gates on `isConnectionReleased`.
- `Loop/Extensions/DeviceDataManager+DeviceStatus.swift` — tile reads `lastWatchLoanReport` within a 5-min grace → `OnWatchStatusHighlight` (`.normalPump`) / `WatchLostPodStatusHighlight` (`.warning`) / else `PodNotConnectedStatusHighlight`.
- `Loop/Localizable.xcstrings` — auto-added strings. `Package.resolved` — benign SPM lockfile (CryptoSwift pin). `docs/*` — untracked writeups.

**Status:** compile-clean; **v2 confirmed working on device** — "On Watch" appeared (took ~2 min under uncontrolled conditions: watch BT off + pod far → reachability-settle delay). The `sessionReachabilityDidChange` poll hook was added to cut that to seconds.

## Open task (resume here)

1. **Phone:** rebuild from Xcode (picks up v2 + the reachability hook). **Watch:** already **v81** installed — no watch rebuild.
2. **Clean test:** watch BT **on**, pod **near**, phone foreground → "On Watch" should appear in seconds.
3. **Loss path:** watch BT off / pod out of range → confirm **"Watch Lost Pod"** → **"Pod Not Connected"** after the ~5-min grace.
4. Get Jeremy's sign-off on wording ("On Watch", "Watch Lost Pod"), **then commit v2**.

## Build / test pipeline

- **Compile-check (no build):**
  ```
  xcodebuild -workspace LoopWorkspace.xcworkspace -scheme Loop \
    -destination 'generic/platform=iOS' \
    build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 2>&1 | grep -iE '\.swift.*error:'
  ```
  Ignore the `Loop Status Extension: clang: … linker command failed` artifact (no-signing device build).
- **Watch install** (Xcode→watch deploy is broken — Apple regression): build the `WatchApp` scheme into `../.dd-cli-clone` with `CURRENT_PROJECT_VERSION=<N>` (bump above the installed 81), then:
  ```
  xcrun devicectl device install app --device 6B08E296-8194-5C07-9F82-8E9BE26EA5FB \
    ../.dd-cli-clone/Build/Products/Debug-watchos/WatchApp.app --timeout 300
  ```
  Requires watch **BT on** (install relays via the paired iPhone). `RemotePairingError 1001` = retry; `CoreDeviceError 3002` / `installcoordination` = BT off. **Force-quit + reopen the watch app after install** (old instance can keep running).
- **Phone logs:** `rm -rf /private/tmp/loop_phone.logarchive && sudo /usr/bin/log collect --device-name "JB iPhone 17" --last 10m --output /private/tmp/loop_phone.logarchive` (Jeremy runs sudo), then `/usr/bin/log show <archive> --predicate 'process == "Loop"'`. Note: `log` is a zsh builtin — always use the full path `/usr/bin/log`.

## Hard constraints

- **Never push to `origin`** on Loop/LoopKit/OmniBLE — push to `jb` forks only. **Commit only when Jeremy asks.**
- **Wording changes need Jeremy's on-device approval before commit.**
- **Any device-mutating action (install / launch / uninstall) needs Jeremy's explicit go-ahead each time.**
- Treat repos as read-only outside this branch; do **not** touch the `Loop-prediction` / `LoopKit-prediction` worktrees (separate prediction-port work).
- Don't guess Loop internals — state what the code shows.

## Also known but not on this branch

- **BT-toggle "phone seizes the pod" hole:** confirmed in code (`OmniBLE BluetoothManager.centralManagerDidUpdateState(.poweredOn)` un-gated reconnect) but **NOT reproducible live** (3 clean toggles → 0 seizures). Optional defense-in-depth fix: gate that loop on `autoConnectIDs.contains`. Not a blocker.
- **Finding ① (higher-stakes, still open):** escape-hatch `reclaimPodFromWatch` resumes closed-loop dosing with the watch's insulin unreconciled → blind IOB. See findings doc.
- **3c (still open):** surface the `lastWatchLoanSummary` ⚠️ abnormal-hand-back marker (currently stored, never displayed).
