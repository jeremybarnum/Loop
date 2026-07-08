# OmniBLECore Port Notes

Portable core of the OmniBLE Omnipod DASH driver, extracted from
`LoopWorkspace/OmniBLE/OmniBLE/` into a standalone SwiftPM package targeting
macOS 13+, iOS 15+, and watchOS 8+. The source workspace was treated as strictly
read-only; every file here was copied out and only then modified.

## Status summary

| Deliverable | Result |
|---|---|
| `Package.swift` + targets | Done. `OmniBLECore` library, `LoopKit` shim target, `OmniBLECoreTests`. |
| `swift build` (macOS) | **Succeeds.** |
| `swift test` (macOS) | **115 tests, 0 failures**, across 20 XCTest suites. |
| watchOS compile check | **`** BUILD SUCCEEDED **`** for `generic/platform=watchOS` (arm64_32 + armv7k). |

Toolchain used: Xcode 26.1.1, Swift 6.2.1, macOS arm64.
CryptoSwift resolved to **1.10.0** (workspace pinned 1.7.1; crypto outputs are
version-independent and the captured-pod vector tests confirm correctness).

Package language mode is set to `.v5` (`swiftLanguageMode(.v5)`) on all three
targets — this is legacy code and not the place to adopt Swift 6 strict
concurrency; tools-version is 6.0 (required for the `swiftLanguageMode` API).

## Layout

```
PodSDK/
  Package.swift
  Sources/
    OmniBLECore/            # the driver core (copied, structure preserved)
      Bluetooth/            # pairing, session (EAP-AKA/Milenage), EnDecrypt, packets, CoreBluetooth transport
      OmnipodCommon/        # message blocks, Pod, BasalSchedule, CRC16, UnfinalizedDose, alerts
      PumpManager/          # PodComms, PodCommsSession (public API), MessageTransport, PodState, PodAdvertisement
      Common/               # LocalizedString, OSLog, Data, TimeZone, TimeInterval, NumberFormatter, HKUnit, CryptoSwiftCompat
    LoopKitShim/            # minimal LoopKit stand-in (module NAME is "LoopKit", see below)
  Tests/OmniBLECoreTests/   # all 20 ported XCTest suites
  _excluded/                # files intentionally NOT built (see below); kept for reference, git-ignored
```

## The "LoopKit" shim target

The shim target's directory is `Sources/LoopKitShim` but its **module name is
`LoopKit`**. This lets the ~30 copied driver files keep their `import LoopKit`
lines completely unmodified. The shim provides only the handful of LoopKit types
the portable core actually touches.

Files copied **verbatim** from `LoopWorkspace/LoopKit/LoopKit/`:

| Shim file | Source | Why needed |
|---|---|---|
| `InsulinType.swift` | `InsulinKit/InsulinType.swift` | `DoseEntry`, `PodCommsSession`, `UnfinalizedDose` |
| `DoseUnit.swift` | `InsulinKit/DoseUnit.swift` | `DoseEntry` |
| `DoseEntry.swift` | `InsulinKit/DoseEntry.swift` | `UnfinalizedDose` -> `DoseEntry` conversions |
| `Alert.swift` | `Alert.swift` | `AlertSlot`, `PumpManagerAlert`, `PodCommsSession` |
| `AnyCodableEquatable.swift` | `AnyCodableEquatable.swift` | `Alert.Metadata` |

Files copied **and modified**:

| Shim file | Modification |
|---|---|
| `DoseType.swift` | Removed the `PumpEventType` compatibility extension (`init?(pumpEventType:)` / `var pumpEventType`). `PumpEventType` pulls in `ReplaceableComponent` and is unused by the driver core. |

Hand-written shim glue (`ShimSupport.swift`) — the small pieces the copied
LoopKit files depend on, so those files compile unchanged:

| Symbol | Notes |
|---|---|
| `func LocalizedString(_:tableName:value:comment:)` | Trivial pass-through (returns `value ?? key`); localization tables aren't shipped in the shim. Used by the shim's own `InsulinType`/`DoseType`. Note the driver core has its own `Common/LocalizedString.swift`, used inside `OmniBLECore`. |
| `protocol TimelineValue` | Minimal version of LoopKit's (from `SampleValue.swift`); `DoseEntry` conforms. |
| `extension TimeInterval { minutes; hours }` | From LoopKit `Extensions/TimeInterval.swift`. Kept **internal** so it does not collide with `OmniBLECore`'s own `TimeInterval` extension when that module imports the shim. |
| `extension HKUnit { internationalUnitsPerHour }` | From LoopKit `Extensions/HKUnit.swift`; used by `DoseEntry`. |
| `extension NumberFormatter { string(from: Double) }` | Used by `DoseEntry.formatted`. |
| `class QuantityFormatter` | Minimal stand-in used **only** for alert body text in `PumpManagerAlert`. Formats an `HKQuantity` to a decimal string + unit. Not a byte-for-byte match to LoopKit's formatter; no test depends on it. |

## Files modified in OmniBLECore (each carries an in-file `// Modified from ...` comment)

| File | Change |
|---|---|
| `Bluetooth/BluetoothManager.swift` | Wrapped `CBCentralManagerOptionRestoreIdentifierKey` init and the `willRestoreState` delegate method in `#if os(iOS)` — CoreBluetooth state restoration is iOS-only. On watchOS the manager is created with `options: nil`. |
| `Bluetooth/PeripheralManager+OmniBLE.swift` | Added explicit `import Foundation` / `import CoreBluetooth`. The original file had **no** imports and relied on the Xcode module umbrella; SwiftPM requires per-file imports. |
| `Bluetooth/EnDecrypt/EnDecrypt.swift` | `Data.bytes` (CryptoSwift) -> `.bytesArray` (see below). |
| `Bluetooth/Pair/KeyExchange.swift` | Same `.bytes` -> `.bytesArray`. |
| `Bluetooth/Session/Milenage.swift` | Same `.bytes` -> `.bytesArray`. |
| `PumpManager/PodComms.swift` | Removed vestigial `import UIKit` (unused, unavailable on watchOS). |
| `OmnipodCommon/BeepPreference.swift` | Removed unused `import SwiftUI` (only a commented-out `@Environment` referenced it). |
| `OmnipodCommon/UnfinalizedDose.swift` | Removed `extension NewPumpEvent { init(_:) }`. `NewPumpEvent` is a LoopKit persistence type used only by `OmniBLEPumpManager`, not by the portable core. The `DoseEntry(_:)` conversion is retained. |

### The `.bytes` / `RawSpan` collision

On the Swift 6.2 / recent-SDK toolchain, `Foundation.Data` gained a
`var bytes: RawSpan` property that now **shadows** CryptoSwift's
`Data.bytes -> [UInt8]` extension, breaking the AES/CMAC/CCM call sites. Fix:
added `Common/CryptoSwiftCompat.swift` defining `Data.bytesArray -> [UInt8]`,
and rewrote the 13 crypto call sites (in EnDecrypt, KeyExchange, Milenage) from
`.bytes` to `.bytesArray`. This is a naming workaround only; the byte values are
identical, which the EnDecrypt/KeyExchange/Milenage vector tests confirm.

## Files intentionally excluded (moved to `_excluded/`, not compiled)

| File | Reason |
|---|---|
| `PumpManager/OmniBLEPumpManagerState.swift` | Conforms to LoopKit's `PumpManager` protocol surface (`RawRepresentable` state for the app-facing manager). Not referenced by any other core file; only `OmniBLEPumpManager` (which the brief said not to port) uses it. |
| `OmnipodCommon/PodDoseProgressEstimator.swift` | Subclasses LoopKit's `DoseProgressTimerEstimator` and references `DoseProgress` / `PumpManager`. UI progress estimation, not protocol logic; unreferenced elsewhere in the core. |
| `OmnipodCommon/BasalSchedule+LoopKit.swift` | Bridge extension converting to LoopKit's `RepeatingScheduleValue` / `BasalRateSchedule`. Only used by the pump-manager layer; `BasalSchedule.swift` itself (the protocol-relevant type) is retained and fully tested. |

Also **not** ported, per the brief: `OmniBLEPumpManager.swift`, everything under
`PumpManagerUI/`, `OmniBLEParser/`, `OmniBLEPlugin/`, and the UI-only `Common/`
helpers (`UIColor`, `Image`, `NibLoadable`, `IdentifiableClass`,
`FrameworkLocalText`, `Bundle`) — none were needed to build or to pass the tests.

## Tests

All 21 source test files were ported (20 XCTest suites + `TestUtilities.swift`
helper). The only change was retargeting `@testable import OmniBLE` ->
`@testable import OmniBLECore`. **Nothing was skipped.**

Suites (all passing):

- **Crypto / pairing vectors (highest value):** `KeyExchangeTest`,
  `EnDecryptTest`, `MilenageTests` logic is exercised via `KeyExchangeTest`/session vectors.
- **Packet framing vectors:** `PayloadJoinerTest`, `PayloadSplitterTest`,
  `PayloadSplitJoinTests`, `MessagePacketTests`, `StringLengthPrefixEncodingTests`.
- **Message encode/decode vectors:** `MessageTests`, `BolusTests`,
  `TempBasalTests`, `BasalScheduleTests`, `ZeroBasalScheduleTests`,
  `StatusTests`, `PodInfoTests`, `AcknowledgeAlertsTests`, `CRC16Tests`,
  `HexConversionTests`.
- **State / session:** `PodStateTests`, `PodCommsSessionTests`, `OmnipodTests`.

`swift test` -> `Executed 115 tests, with 0 failures`.

## watchOS build

```
xcodebuild -scheme OmniBLECore -destination 'generic/platform=watchOS' build
=> ** BUILD SUCCEEDED **
```

Compiles for all watchOS archs (arm64_32, armv7k) plus the CryptoSwift and
LoopKit-shim dependencies. The only platform-specific concession was the
`#if os(iOS)` guard around CoreBluetooth state restoration in
`BluetoothManager.swift`; the rest of the CoreBluetooth central transport is
available on watchOS as-is.

## Facade additions (WatchProof radio-proof app)

`Sources/OmniBLECore/Facade/PodProofKit.swift` (new file, 2026-07-02) — a small
public facade for the `WatchProof/` app: `PodProofController` (start/stop
display-only scanning with decoded advertisements, `connectAndPair`,
`establishSession`, `getStatus`, `suspend`, `resume`, `bolus(units:)` capped at
1.0 U, `completeSetup` (prime → basal → cannula), `deactivate`) plus public
value types `PodProofDiscoveredPod`, `PodProofStatus`, `PodProofLogEvent`,
`PodProofPhase`, `PodProofError`. Every operation emits timestamped log events
via `onLog`; protocol traffic is traced via the internal `MessageLogger` hooks.

**Access-level changes to existing code: NONE.** The facade lives inside the
`OmniBLECore` module, so it reaches the internal machinery
(`PodComms.pairAndSetupPod` / `runSession`, `BluetoothManager`,
`PodAdvertisement`, `MessageLogger`, `configureAlerts`, `createControllerId`)
without widening any existing symbol. `PodComms.runSession` etc. remain
`internal`.

Caveats (also in `WatchProof/README.md`): nothing in the facade's BLE path has
run against real hardware or the emulator yet (simulator has no Bluetooth);
pod state is held in memory only (no persistence across app launches); the
low-reservoir alert is configured immediately after pairing, earlier than the
upstream driver does it (upstream configures it during `insertCannula`).

## Next steps (toward a watch app target)

1. A watch app would add `OmniBLECore` as a package dependency and
   `import OmniBLECore`. The public driving surface is `PodComms` (BLE +
   session lifecycle) and `PodCommsSession` (commands).
2. `PodComms.runSession(withName:)` is currently `internal`; expose it (and
   `pairAndSetupPod` / auto-connect entry points) as `public`, or add a thin
   public facade, before an external app module can drive it.
3. Persist/restore `PodState` (Codable) yourself — the excluded
   `OmniBLEPumpManagerState` used to own that; a watch app needs its own small
   store.
4. Provide an `AlertIssuer` (from the shim's `Alert` API) if you want pod alerts
   surfaced on the watch.

### Sketch: driving `PodCommsSession` from a watch app

```swift
import OmniBLECore

// podComms: PodComms is created after BLE discovery + pairing; it owns podState.
// Commands run inside a session established over the connected peripheral.
podComms.runSession(withName: "Watch bolus") { result in
    switch result {
    case .success(let session):                       // session: PodCommsSession
        do {
            // Read pod status
            let status = try session.getStatus()
            print("reservoir:", status.reservoirLevel as Any, "active:", status.deliveryStatus)

            // Deliver a 2.0 U bolus with confirmation beeps
            let bolusResult = session.bolus(units: 2.0, acknowledgementBeep: true, completionBeep: true)
            if case .certainFailure(let err) = bolusResult { print("bolus failed:", err) }

            // Suspend delivery for 30 min, then resume on the saved schedule
            _ = session.suspendDelivery(suspendReminder: .minutes(30), silent: false)
            _ = try session.resumeBasal(schedule: basalSchedule, scheduleOffset: tzOffset)
        } catch {
            print("command error:", error)
        }
    case .failure(let error):
        print("session error:", error)                 // e.g. .podNotConnected, .noPodPaired
    }
}
```

Key `PodCommsSession` entry points (all `public`): `getStatus(...)`,
`bolus(units:...)`, `setTempBasal(rate:duration:...)`,
`cancelDelivery(deliveryType:...)`, `suspendDelivery(suspendReminder:silent:...)`,
`resumeBasal(schedule:scheduleOffset:...)`, `setTime(timeZone:basalSchedule:date:...)`,
`acknowledgeAlerts(alerts:...)`, `deactivatePod()`.
