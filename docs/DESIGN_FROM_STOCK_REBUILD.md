# Design: Rebuilding the Watch-Standalone App From Stock

_2026-07-17. Status: DESIGN for Jeremy's review — no code changes made. Baseline: branch
`g7-build-next` (the working "crude version", on-body validated), workspace
`LoopWorkspace-prediction`. Companion docs: `SAFETY_PARADIGM.md` (governing principles),
`DESIGN_G7_FULL_LOOP.md` (current architecture), adversarial-review findings 2026-07
(70 verified findings)._

## 0. Why rebuild, and what the evidence says

The 136-agent adversarial review of `c41e8ff6..g7-build-next` produced **70 verified findings
(5 critical, 24 high, 28 medium, 13 low)**. Their distribution is the argument:

| Area | Findings | What it is |
|---|---|---|
| `Loop/Managers/` (phone loan/reconcile side) | 19 | hand-rolled protocol v1: grant/hand-back/journal-hash dedup |
| `PodSDK/Sources/` | 17 | almost all in `Facade/PodController.swift` — the hand-rolled pump-manager substitute |
| `WatchApp Extension/G7/` | 15 | bespoke transport + **duplicated, partial** EGV parsing |
| `WatchApp Extension/Managers/` | 14 | second dosing pipeline beside LoopKit + loan coordinator |
| misc (ExtensionDelegate, view models, xcconfig) | 5 | |

Where the crude version **reused stock**, it held up: the vendored OmniBLE comms core
(`PodCommsSession`/`PodState`/`MessageTransport`, near-verbatim upstream, 115 vendored stock
tests) produced essentially no findings; the algorithm path
(`LoopAlgorithm.generateRecommendation`, real LoopKit) likewise. Where it **diverged**, defects
clustered: 3 of the 5 criticals live in `PodController.swift` — precisely because the facade
dropped OmniBLE's uncertain-delivery machinery (`PendingCommand`, `unacknowledgedCommand`
resolution, `UnfinalizedDose` → dose-store flow) and replaced it with journal guesses. The
fourth and fifth criticals are protocol-v1 races (`WatchDataManager.swift:684/:759`).

**Thesis, confirmed:** defect density tracks distance from upstream. So the rebuild is an
*assembly* problem — stock components compiled for watchOS, plus exactly **one** novel module
(the loan/handoff protocol v2), small and heavily tested. This is also just `SAFETY_PARADIGM`
P3 ("speak only stock dialect") promoted from the pod wire protocol to the whole codebase.

The crude version stays on the wrist as the working fallback throughout (§4).

---

## 1. Module map

### 1.1 Summary table

| # | Module | Classification | Source of truth | Delta to make it work on the watch |
|---|---|---|---|---|
| 1 | LoopKit (stores, algorithm, DoseMath, protocols) | **stock-unchanged** (fork already exists) | `LoopKit/` checkout, target **`LoopKit-watchOS`** | ~0 code. Target-membership verification for `DoseStore`/`PersistenceController`; the fork's 4 existing commits |
| 2 | OmniBLE pump driver, **including `OmniBLEPumpManager`** | **stock-ported** | `OmniBLE/` checkout (new target `OmniBLE-watchOS`) | ~1 file of `#if os(iOS)` guards + 2–3 import edits (≈20 lines); watch host glue ≈300–500 LOC |
| 3 | G7 CGMManager | **stock-ported** (manager + parsing) wrapping **proven custom transport** | `G7SensorKit/` core + watch `G7Client.swift` | transport-injection seam in `G7CGMManager` ≈50–100 lines; adapter ≈150–300 LOC |
| 4 | Dosing loop (watch LoopDataManager equivalent) | **stock-shaped** (same policy code paths as phone) | phone `LoopDataManager` structure, LoopKit `DoseMath` | ≈400–700 LOC of host code, zero algorithm code |
| 5 | Loan/handoff protocol **v2** | **NOVEL — the only one** | this doc, §2 | ≈1,000–1,500 LOC both sides + the heaviest test suite in the tree |
| 6 | Watch UI / complication / keepalive / crypto libs | carry over | current tree | crash/robustness fixes from the findings list |

What gets **deleted** in exchange (see §3.2): `PodController.swift` (1,195),
`PodLoanJournal.swift` (323), `PodLoanInsulinMath.swift` (276), the `OmniBLEShim` LoopKit
stand-in, `G7GlucoseManager.swift` (77) + G7Client's inline EGV parser, the hand-applied
clamps in `WatchAutoLoop`, and the whole-journal-hash reconciliation in `WatchDataManager`.
Net: roughly 3–4k LOC of bespoke safety-critical code replaced by stock code that already has
tests and field history, plus ~2–3k LOC of new-but-mostly-mechanical host/protocol code.

### 1.2 LoopKit on watchOS — already true, finish the job

**Verified:** the `WatchApp Extension` target *today* links `LoopKit.framework` (built by
LoopKit's native **`LoopKit-watchOS`** target — `SDKROOT=watchos`, deployment 6.1, with a
`Shared-watchOS` scheme; this is upstream structure, not our invention), plus
`LoopCore.framework`, `HealthKit`, `CoreBluetooth`, `ClockKit`, and the `OmniBLECore` SPM
product (pbxproj frameworks phase `43A9437B`). It does **not** link LoopKitUI, and
`LoopAlgorithm` is not a separate package — the algorithm types live inside this LoopKit
vintage and the fork (`prediction-watchos`, 4 commits) added them to the watchOS target and
implemented `generateRecommendation` (upstream had a stub).

The watch already runs LoopKit's `GlucoseStore` and `CarbStore` in production (G7 EGVs and
carb entries flow through them). LoopKit has **zero UIKit imports** in the core and exactly
one `#if os(watchOS)` today (`AlertSoundPlayer.swift`); HealthKit (76 files) is
watchOS-available.

**The one addition:** run a real **`DoseStore`** on the watch. `DoseStore.swift`,
`PersistenceController.swift`, `InsulinMath.swift`, `DoseMath.swift` each appear in 4 targets'
compile lists in `LoopKit.xcodeproj` — almost certainly including `LoopKit-watchOS` (Glucose/
Carb stores at the same count demonstrably are). Milestone M1 verifies this and adds any
missing files to the target. This kills the parallel IOB world: `PodLoanInsulinMath` (an exact
hand-port of `ExponentialInsulinModel.percentEffectRemaining`) and the journal-as-DoseStore
substitute both retire, and watch IOB comes from the same `InsulinMath` the phone uses.

Open owner decision: HealthKit writes from the watch store (off by default — run the stores in
the no-HealthKit mode LoopKit's own tests use — to avoid double-writing samples the phone will
also write after reconciliation).

### 1.3 OmniBLE — real target, not a re-vendor (the central call)

**Assessment of the two options:**

*What the port already proved.* `PodSDK/PORT_NOTES.md` + a fresh diff audit show the vendored
comms core is near-verbatim upstream: `MessageTransport.swift` byte-identical,
`PodCommsSession.swift`/`PodState.swift` 2-line import swaps, `PodComms.swift` 26 lines. It
compiles and passes 115 tests for `generic/platform=watchOS`. The **only genuine watchOS
blocker in ~14.7k LOC of core** is CoreBluetooth state restoration
(`CBCentralManagerOptionRestoreIdentifierKey` at `Bluetooth/BluetoothManager.swift:128` and
`willRestoreState` at `:330` — iOS-only), plus a vestigial `import UIKit` in `PodComms.swift`,
an unused `import SwiftUI` in `BeepPreference.swift`, and the CryptoSwift `.bytes` →
`.bytesArray` toolchain collision (13 call sites).

*What the vendoring cost.* What got dropped is exactly where the criticals came from: the
~3.1k LOC app layer — `OmniBLEPumpManager.swift` (2,702), `OmniBLEPumpManagerState.swift`
(337), `PodDoseProgressEstimator`, `BasalSchedule+LoopKit` — is where upstream implements
`PodState` persistence, `PendingCommand` recovery
(`PodCommsSession.recoverUnacknowledgedCommand` at `:1024` exists in the vendored copy but its
verdict is **discarded** by the facade — review finding), and finalized-dose reporting
(`store(doses:)` → `pumpManager(_:hasNewPumpEvents:...)` at `OmniBLEPumpManager.swift:2506`).
The facade re-implemented that surface from scratch and got the uncertain-delivery policy
backwards. Additionally, the re-vendor is already drifting: `PORT_NOTES.md` is stale (the shim
module was renamed `OmniBLEShim` and the driver's `import LoopKit` lines *were* rewritten),
and the "stock" OmniBLE checkout itself carries four locally-edited files (the
`releaseConnection`/`rearmConnection` loan prototype). Copies rot; targets diff.

**Decision: compile the real OmniBLE for watchOS.** Add a framework target
**`OmniBLE-watchOS`** to `OmniBLE.xcodeproj`, mirroring the `LoopKit-watchOS` precedent,
depending on `LoopKit-watchOS`:

- **Included:** all of `Bluetooth/`, `OmnipodCommon/`, `PumpManager/` — **including
  `OmniBLEPumpManager.swift` + `OmniBLEPumpManagerState.swift`**. Their imports (HealthKit,
  UserNotifications, CryptoKit) are all watchOS-available; no UIKit, no LoopKitUI anywhere in
  the core. Compilation on watchOS is *assessed-likely, not yet proven* — M2 proves it, with
  a named fallback (below).
- **Excluded:** `PumpManagerUI/` (6.2k LOC), UI `Common/` helpers (`UIColor`, `Image`,
  `NibLoadable`, …), `OmniBLEParser`, `OmniBLEPlugin`.
- **Code deltas (the whole list):** `#if os(iOS)` around the two state-restoration sites
  (watchOS: `options: nil`); delete the two vestigial imports; `.bytesArray` compat if the
  toolchain still requires it. Roughly 20 lines, all upstreamable (§6).
- The watch app then implements **`PumpManagerDelegate`** in its device manager (the host glue,
  ≈300–500 LOC): persist `rawState` on `pumpManagerDidUpdateState` (this is what makes
  intent-before-transmission automatic — `PodState.unacknowledgedCommand` and
  `unfinalizedDoses` hit disk before the BLE round-trip completes), route
  `hasNewPumpEvents` into the watch `DoseStore`, surface `PumpManagerAlert`s (pod fault /
  occlusion) through the watch alert path.
- **PodSDK retires.** The facade, shim, vendored copies, and vendored test suites go; the
  real `OmniBLETests` run against the real target. Loan-specific logic moves to module 5.

*Fallback if M2 fails* (e.g. `OmniBLEPumpManager`'s runtime assumptions fight watchOS in ways
guards can't fix): keep the PodSDK package but port `OmniBLEPumpManager` +
`OmniBLEPumpManagerState` into it against the real `LoopKit-watchOS` (dropping the shim), so
upstream *semantics* are preserved even if the packaging isn't. This is strictly a fallback:
it re-opens the copy-drift problem the review documented.

Pairing/activation stays phone-side (unchanged from crude): the watch receives an
already-activated pod via the loan. The facade's setup/prime/cannula paths were already
quarantined as hardware-unverified in `SAFETY_PARADIGM` §P3 — they don't move to the watch.

### 1.4 G7 CGMManager — stock manager and parsing over the proven transport

**Verified split of stock `G7SensorKit` (~2.5k LOC core):**

- **Pure parsing/state, zero CoreBluetooth, reusable verbatim (~800 LOC):**
  `G7GlucoseMessage.swift`, `G7BackfillMessage.swift`, `ExtendedVersionMessage.swift`,
  `AlgorithmState.swift` (26-state enum with `hasReliableGlucose`), `AlgorithmError.swift`,
  `AuthChallengeRxMessage.swift`, `SensorMessage.swift`, `G7Opcode.swift`,
  `GlucoseLimits.swift`, `G7CGMManagerState.swift`, `Common/*`. The watch's inline parser in
  `G7Client.readEGV` (`:1248–1313`) uses the **identical byte offsets** but is a strict
  subset — it drops trend (byte 15), predicted (16–17), sequence, backfill, and the
  display-only/calibration bit (byte 18 & 0x10), the last of which is a review finding
  (calibration-shifted readings entering as dosable samples). Adopting the stock structs
  closes that class wholesale.
- **`G7CGMManager.swift` (516 LOC): ~90% transport-agnostic.** Its CGMManager conformance,
  delegate fan-out (`cgmManager(_:hasNew:)`), `NewGlucoseSample` mapping with clamping,
  sensor lifecycle (`sensorExpiresAt`/warmup/session-end), and `RawRepresentable` persistence
  don't touch CoreBluetooth. It drives everything off **`G7SensorDelegate`**
  (`G7Sensor.swift:15–35`) — a clean seam whose only CB-typed method
  (`shouldConnectPeripheral(_: CBPeripheral)`) the custom transport doesn't need.
- **Replaced, not ported:** stock's passive-listener BLE stack (`G7BluetoothManager` 449,
  `G7PeripheralManager` 581, the CB guts of `G7Sensor` 353). Stock G7SensorKit performs **no
  authentication** — it eavesdrops on a sensor the Dexcom app paired. Our watch is phone-free;
  the **active J-PAKE handshake via `libg7auth` is the whole reason `G7Client` exists** and it
  stays, together with the connect-per-reading predictive scheduler
  (`finishAttempt`/`scheduleAutoRepeat`, `autoRepeatInterval=300`, `scanLeadTime=45`,
  pending-connect reacquire — the machinery that got 100% capture) and `WorkoutKeepalive`.

**Construction:** a new `G7CGMManager` instance whose transport is injected — small delta in
`G7CGMManager`/`G7Sensor` to accept a transport behind the existing `G7SensorDelegate`
contract (≈50–100 lines, upstreamable as a seam), plus a **`G7ClientSensorAdapter`**
(≈150–300 LOC) that owns `G7Client`, feeds raw notification bytes into stock
`G7GlucoseMessage(data:)`, and calls `delegate.sensor(_:didRead:)`. The bespoke
`G7GlucoseManager` store-injection path deletes; readings now flow
CGMManager → `CGMManagerDelegate` → watch device manager → `GlucoseStore`, with stock
provenance, dedup, and state gating (subsumes the hand-rolled 0x06/[40,400] gate; the
below-40 handling follows stock's clamp-with-condition, fixing the severe-hypo finding at
`G7Client.swift:1301`).

`G7Client` itself keeps its role but takes the review's transport fixes as direct patches
(they're bugs in an asset we keep, not architecture): unchecked BLE slice crashes (`:1360`),
IUO `peripheral` crash after BT toggle (`:1133`), un-cancelled superseded handshake tasks
(`:1093`), sensor-swap candidate selection (`:1017`), plus the bench-fence cleanups (hardcoded
PIN `3102`, `FAKE_NEW_SENSOR` in Release — already on the pre-production checklist).

Packaging per `DESIGN_G7_FULL_LOOP.md` §5: local SPM package **`G7DirectKit`** with the two
xcframeworks as `binaryTarget`s + the 4-line modulemaps (also fixes watch-simulator linking).
Stock parsing files come in either via a `G7SensorKit-watchOS` target (preferred, same
pattern as OmniBLE) or by file-reference into the package if a target is disproportionate.

### 1.5 The dosing loop — stock-shaped, one policy source

Keep the crude version's *shape* (it deliberately mirrors the phone:
`WatchPredictionStore` ↔ LoopDataManager, `WatchAutoLoop` ↔ `loop()`/DoseEnactor) but remove
the places where policy was **re-implemented beside** the stock call instead of **inside** it:

- `generateRecommendation` gets the full argument surface the phone passes
  (`LoopDataManager.swift:2003` parity): the IOB clamp goes back inside
  `DoseMath.recommendedTempBasal` via `additionalActiveInsulinClamp` instead of the
  hand-applied copy at `WatchAutoLoop.swift:339–347` (review: "silent algorithm fork"), and a
  **`rateRounder`** is passed so `ifNecessary` continuation works and the loop stops issuing
  a cancel+set pair every reading (review `WatchPredictionEngine.swift:398` — also a radio
  and battery win).
- Manual/meal bolus goes through the stock recency-validated path
  (`recommendBolusValidatingDataRecency` semantics): glucose staleness gates and no fabricated
  100 mg/dL placeholder (review `CarbAndBolusFlowViewModel.swift:136`), and enact-result
  surfaced before the success haptic (review `:246` — the silently-dropped crown-confirmed
  bolus).
- Enactment goes to **`OmniBLEPumpManager.enactTempBasal`/`enactBolus`** — the same
  PumpManager protocol methods the phone calls — instead of
  `WatchPodLoanCoordinator.enactTempBasal`. Pulse-grid snapping, cancel-before-program
  (BUG-6), busy handling, and uncertain-delivery classification all come from stock.
- Keep, as explicit requirements carried from the crude version: enact only on
  `didLoopTick` (the oscillation fix), `pumpSuspended` gate, stale-BG pause with haptic,
  bounded (3 h zero-temp) manual suspend, per-session closed-loop opt-in via crown ceremony.
- Failed/busy-dropped enacts must clear the cycle anchor so the next reading retries
  (review `WatchAutoLoop.swift:311`).

Settings continue to be pushed from the phone (`LoopSettingsUserInfo` → persisted
`LoopSettings`); the grant additionally snapshots them (§2), and **no hardcoded fallback caps
ever substitute for missing settings — missing settings deny dosing** (review findings on the
1.0/3.0 invented caps).

---

## 2. Loan/handoff protocol v2 — the one novel module

### 2.1 Requirements traced to findings

| Requirement | Findings it retires |
|---|---|
| **Loan epoch**: phone-minted monotonic generation on every message; older-epoch messages are dead on arrival (acked-as-stale so senders stop retrying, never acted on) | stale hand-back re-enabling dosing during a new loan (critical `WatchDataManager.swift:759`); revoke/new-loan race (bench B4); replaces the armedAt/lastRequestAt/lastRevokeAt anchor patchwork (`SAFETY_PARADIGM` §4 verdict, adopted) |
| **Per-event stable IDs + cursor acks** (event UUID minted at intent time; ack = highest contiguous committed event; dedup by ID) | whole-journal-hash dedup defeated by journal growth (`:864`); non-idempotent carb reconciliation (`:994`); empty hand-back never acked → split-brain (`:948`) |
| **Intent-before-transmission, resolution from the session layer**: dose records derive from the watch `DoseStore`, fed by stock `PodState`/`PendingCommand` persistence and `recoverUnacknowledgedCommand` verdicts | all three PodController criticals (`:364`, `:352`, `:721`) and the uncertain-resume/discarded-verdict/commanded-vs-delivered highs (`:367`, `:641`, `:672`) — **by construction**, since module 2 preserves upstream semantics |
| **Watchdogs + alarms on both sides** | no phone-side loan timeout (`:704`); grant races an in-flight enact (critical `:684`); keepalive death silently suspends the loop (`:103`) |
| **Grant-time boundary truncation** of the phone's running temp, recorded in both ledgers | untruncated boundary temp (`:1024`) |
| **Version-negotiated, never-silently-discarded messages** | undecodable journal acked and discarded (`:825`) |
| **Escape-hatch reclaim blocks dosing until reconciliation or explicit override** | reclaim re-enables dosing on blind IOB (`:292`); trap-cell residue (`SAFETY_PARADIGM` §2d-3) |
| **Pod fault/occlusion surfaced on the watch** | free via stock `PumpManagerAlert`s; v1 had no channel |
| **Recovered journal cancels the last running temp** | pod executing an uncanceled 3 h command after recovery truncation (`:946`, `:957`); suspend windows become first-class events (`:138`) |
| **Grant denied on incomplete identity; no silent fallbacks** | controllerId-0 substitution (`PodLoanIdentity.swift:48`) |

### 2.2 Messages (all versioned Codable structs in `Common/Models/`, compiled into both targets — one source file, no hand-maintained mirror decoder)

Every message carries `{protocolVersion, epoch}` (epoch absent only in `LoanRequest`).
Undecodable payload → `ProtocolNack{seenVersion}` + loud surfacing on both devices; never
ack-and-drop.

1. **`LoanRequest`** (watch→phone): watch build + protocol version.
2. **`LoanGrant`** (phone→watch): new epoch; pod identity/keys (LTK, controllerId, podId,
   address, message number — v1's `ltk/cid/pid/addr/mn`, now with completeness enforced);
   **full stock `PodState` raw snapshot** (richer than v1: includes `unfinalizedDoses` and any
   `unacknowledgedCommand`, so the watch's `OmniBLEPumpManager` resumes exactly where the
   phone's left off); therapy-settings snapshot (basal/ISF/CR/targets, maxBasal, maxBolus,
   insulin type); 16 h dose history (v1 `dh`, kept); **boundary record**: the phone truncates
   its own running temp at grant time and includes the truncated `DoseEntry`, so both ledgers
   agree on the cut. Grant is refused (not defaulted) if any element is missing. Before
   sending, the phone completes or cancels any in-flight enact (critical `:684`) and pauses
   automatic dosing.
3. **`TakeoverComplete`** (watch→phone): epoch + first pod status. Only now does the phone
   commit `LOANED`. **`TakeoverFailed`** likewise, and the watch tears down its `PodComms`
   completely on failure/timeout (zombie-bidder finding `:1009`).
4. **`DoseRecordBatch`** (watch→phone, during loan, best-effort streaming over
   `transferUserInfo`): dose + carb events with `{eventID (UUID), seq, payload}`. Addresses
   the trap cell — the phone accumulates the record even if the watch later dies.
5. **`HandbackOffer`** (watch→phone): epoch, `handedBackAt`, final pod status + odometer,
   all not-yet-acked events (same IDs on every retry; the snapshot-for-byte-stability rule is
   subsumed by ID-stability).
6. **`HandbackAck`** (phone→watch): epoch + committed cursor. Sent **only after the DoseStore
   write commits** (keeps `a897d22c`). Empty hand-backs ack cursor 0.
7. **`Revoke`** (phone→watch): epoch. Idempotent; parked-until-activation delivery kept
   from v1.
8. **`StatusQuery`/`StatusReport`**: the existing 3b-v2 phone-polls-watch mechanism, extended
   with the CGM-direct sovereignty flag (ruling §6a) and last-event seq (so the phone's
   watchdog can detect a stalled stream).

### 2.3 State machines

**Phone** (persisted; `podLoanedToWatch` becomes derived-from-persisted-state, fixing the
volatile-flag relaunch findings `:480`/`:697`):

```
OWNER ──grant sent──▶ GRANT_OFFERED ──TakeoverComplete──▶ LOANED
  ▲                        │ timeout T1 (~60 s) or TakeoverFailed
  │                        ▼
  │◀────────────── auto-reclaim + loud alert
  │
  │◀── RECONCILING ◀── HandbackOffer / recovered journal / drained stream
  │        │ write fails → stay, alarm, no ack
  │
  └── RECLAIM_PENDING (escape hatch: pod reclaimed, temp canceled to schedule,
        automatic dosing BLOCKED + persistent banner) ──journal drains──▶ RECONCILING
        └─ user explicit override ("records missing — resume anyway") ──▶ OWNER
```

Automatic dosing is enabled **only** in `OWNER` with no unreconciled loan. The dosing pause
and all loan-gated alarm suppressions key off the persisted state.

**Watch**:

```
IDLE ──request──▶ REQUESTED ──grant──▶ TAKING_OVER ──pod session up──▶ ACTIVE
                     │ denied/timeout        │ fail: teardown + TakeoverFailed → IDLE
                     ▼                       
                   IDLE
ACTIVE ──user hand-back──▶ HANDING_BACK (cancel leftover temp [DESIGN-5], freshen odometer,
                            send HandbackOffer, resend until Ack)
        ──ack──▶ release pod (only after ack — kept from v1) ──▶ IDLE
ANY ──Revoke(epoch match)──▶ REVOKED: stop dosing, zero post-revoke pod commands (DESIGN-6),
                            drain records via HandbackOffer(recovered), ──▶ IDLE
RELAUNCH with persisted state: never resurrect the session (data-first, kept);
    drain persisted DoseStore-pending events as recovered hand-back.
```

### 2.4 Failure matrix

Every row is also a bench-drill in M5. "Pod safe" = pod autonomy backstop (P2): last program
bounded (≤30 min loop temp / ≤3 h manual temp or bounded suspend), then stored schedule.

| # | Interruption | Detection | Recovery | Invariant held |
|---|---|---|---|---|
| 1 | `LoanRequest` lost | watch request timeout | watch → IDLE, user retries | no side effects yet |
| 2 | `LoanGrant` lost (phone released pod, watch never got keys) | phone T1 expires without `TakeoverComplete` | phone auto-reclaims + alert; a late-arriving grant on the watch is rejected by its embedded expiry | at least one controller (P1) |
| 3 | Takeover fails (pod unreachable) | `TakeoverFailed` or T1 | watch tears down PodComms fully; phone reclaims | no zombie bidder |
| 4 | `TakeoverComplete` lost | phone T1; watch is ACTIVE | phone `StatusQuery` before reclaiming — if watch reports ACTIVE with current epoch, transition to LOANED (query-before-reclaim rule) | exactly one controller |
| 5 | Watch app killed mid-loan | relaunch with persisted state | per-session policy kept: loop reopens; records drain as recovered hand-back; "session ended" alert (P1#14) | journal-loss-proof (P4) |
| 6 | Watch killed mid-pod-command | stock `PodState.unacknowledgedCommand` persisted pre-flight | stock recovery on next session resolves delivered/failed via seq number; dose lands in DoseStore → drains | no vanished dose (v1 critical `:352`) |
| 7 | Watch battery death | phone watchdog: no `StatusReport`/stream for T2 → warning | pod safe; escape hatch → RECLAIM_PENDING (dosing blocked) | blind-IOB dosing impossible |
| 8 | Phone off during loan (normal) | n/a — the product premise | `transferUserInfo` queues records; reconcile on return | phone-free dosing + deferred reconcile |
| 9 | `HandbackOffer` lost | watch resend loop (HANDING_BACK) | same event IDs on retry; watch keeps pod until ack | no orphaned pod, no dup |
| 10 | `HandbackAck` lost | watch resends offer | phone: events already committed → ack same cursor; ID-dedup absorbs it, **even if the journal grew** (v1 hole `:864`) | exactly-once accounting |
| 11 | Phone DoseStore write fails | reconcile error | no ack; dosing stays blocked; alarm after N retries | never dose on known-incomplete records |
| 12 | Escape-hatch reclaim, watch alive | watch gets Revoke | watch: REVOKED, drains; phone: dosing blocked until reconciled or explicit override; running temp canceled at reclaim | single writer + no blind IOB (`:292`) |
| 13 | Revoke lost / watch unreachable | phone stays RECLAIM_PENDING | revoke re-queued (parked-revoke kept); watch's next contact at stale epoch gets stale-ack → drains | dead loans cannot speak |
| 14 | Stale hand-back after a new loan | epoch mismatch | ack-as-stale, ignore; new loan untouched (v1 critical `:759`) | epoch invariant |
| 15 | Version skew | decode failure | `ProtocolNack` + loud alert both sides; dosing stays blocked phone-side; nothing discarded (`:825`) | no silent data loss |
| 16 | `WorkoutKeepalive` dies mid-session | dead-man `UNUserNotification` armed each cycle, canceled by the next; fires if the process is suspended (`:103`) | user alerted; pod safe; loop resumes on relaunch | no silent loop suspension |
| 17 | WC userInfo redelivery after reinstall | stale epoch / known IDs | ignored idempotently; no assertions on unknown payloads (`:1088`) | idempotency |
| 18 | Empty hand-back | normal path | ack cursor 0 (`:948`) | no split-brain |
| 19 | Recovered journal shows uncanceled temp/suspend | phone inspects last event on recovered path | phone cancels the running temp at reclaim, records the truncation; suspend state surfaced, never "back on schedule" (`:946`, `:957`, `:138`) | truthful transfer (P7) |

### 2.5 What v2 keeps from v1 verbatim

Release-pod-only-after-ack; ack-only-after-commit (`a897d22c`); bounded-suspend preservation
across hand-back (`46f16d01`); DESIGN-5 leftover-temp cancel at hand-back; data-first
recovered-journal delivery (never resurrect a session); parked revoke; write-doses-first
ordering; the odometer as **audit** (not source), including the freshen-before-snapshot step
and the OQ-5 freshen-retry fix; `PumpConnectionLendable` / `releaseConnection` /
`rearmConnection` on the phone; pre-grant identity validation (now deny-on-missing);
deterministic per-event syncIdentifiers on the phone write (evolving the
`watchloan-<hash8>-<seq>` scheme to per-event IDs). Carb reconciliation additionally becomes
merge-not-replace on the phone (`setSyncCarbObjects` replace-all finding, `LoopDataManager.swift:131`).

---

## 3. Carry-over and deliberate drops

### 3.1 Carries over verbatim (proven assets)

- `G7Frameworks/libg7auth-watchos.xcframework` + `openssl-watchos.xcframework` (+ the
  modulemap fix), the entire handshake/crypto path in `G7Client`, the predictive
  connect-per-reading scheduler, pre-warm/bonding flow, sensor-code plumbing (with a real
  per-sensor PIN UI replacing the hardcoded default), `WorkoutKeepalive.swift`.
- Phone-side: escape-hatch UX, status tiles (3b-v2 "On Watch"/"Watch Lost Pod"), boot-crash
  fix `e4e347f2`, `PodLoanIdentityTests`.
- Watch UI: HUD/chart/complication surfaces, crown-confirm ceremonies, carb entry flow
  (re-pointed at the new managers).
- Docs: `SAFETY_PARADIGM.md` stays the governing document — §5.1 maps its principles onto the
  new architecture. `RELEASE_TEST_SCRIPT.md` and `WATCH_LOAN_TESTING_BUGS.md` become the
  regression base. `IOB_RECONCILIATION.md` / `WATCH_INSULIN_MODEL.md` become historical.
- Tests: `DoseMathTests`, LoopKit fork's `LoopAlgorithmTests` scenario suite, real
  `OmniBLETests` (replacing the vendored copies), `G7SensorKitTests` (newly applicable),
  the `PodLoanInsulinMath` 20-vector suite repurposed once as an M1 acceptance check.

### 3.2 Deliberately dropped

- **`PodSDK/Sources/OmniBLECore/Facade/`** — `PodController.swift` (1,195),
  `PodLoanJournal.swift` (323), `PodLoanInsulinMath.swift` (276) — and the
  `OmniBLEShim`/LoopKitShim. The single largest findings cluster.
- The **journal as a data structure** (wire-format tests, SHA-256 whole-journal dedup, mirror
  decoder in `WatchDataManager`) — replaced by DoseStore-derived per-event records (§2).
- `G7GlucoseManager.swift` and `G7Client`'s inline EGV parsing — replaced by stock
  parsing + CGMManager.
- Hand-applied policy in `WatchAutoLoop` (IOB clamp copy, cap plumbing) — moved inside the
  stock calls.
- The parallel logging subsystem (free `log()`/`fileLog()`, unbounded `g7watch.log`,
  synchronous main-thread copies — findings `:43`, `ExtensionDelegate:206`) — replaced by
  OSLog + one rotated file log with the WatchLink export bridge (P2#15).
- Simulator-demo branches woven through dosing methods (~110 lines) — either a clean mock
  pump/CGM layer (LoopKit's MockKit pattern) or nothing.
- Bench anti-measures from Release builds: `FAKE_NEW_SENSOR` compile condition, hardcoded PIN,
  `TEMP-TEST-BEEPS` constant, `authEndByte` experiment residue (pre-production checklist).
- The raw string-keyed UserDefaults sprawl, notification-as-wire-format relays, and the
  four timer/debounce idioms — normalized in passing, not preserved.

---

## 4. Build and validation plan

Working model: new branch (`from-stock-rebuild`) in the consolidated superproject; the crude
version (`g7-build-next`, watch build 73) remains the installable fallback at every step —
same bundle ID means last-install-wins, so "fallback" = reinstall the tagged crude build via
the `devicectl` recipe. Jeremy archives/builds; Claude compile-checks (standing rule).
Each milestone ends with something runnable on hardware.

- **M0 — freeze the baseline.** Tag the crude build + record current release-test results and
  G7 capture stats as the comparison base. No code.
- **M1 — stores on the wrist.** Verify/complete `LoopKit-watchOS` target membership for
  `DoseStore`/`PersistenceController`/`InsulinMath`/`DoseMath`; stand up a watch `DoseStore`
  (HealthKit off pending ruling). **Testable:** a debug screen showing DoseStore-computed IOB;
  acceptance = agreement with the `PodLoanInsulinMath` 20-vector suite and with the phone's
  IOB for identical dose sets.
- **M2 — stock pod driver on the wrist (the risk gate).** `OmniBLE-watchOS` target compiles;
  watch host implements `PumpManagerDelegate`; bench pod: grant transfers `PodState` →
  stock `OmniBLEPumpManager` executes bolus/temp/suspend/resume. **Acceptance:** the
  kill-mid-bolus drill — force-quit during a bolus, relaunch, verify `PendingCommand`
  recovery classifies it and the dose lands in the watch DoseStore (the exact scenario that
  is a v1 critical). *Decision gate:* if the stock manager fights watchOS, fall back to
  porting it into PodSDK against real LoopKit (§1.3) — decide here, not later.
- **M3 — stock CGM manager.** `G7DirectKit` + adapter + stock parsing; readings flow through
  `CGMManagerDelegate`. **Testable:** overnight soak; acceptance = capture % parity with M0
  baseline (`soak_analyze.py`), display-only-bit and below-40 handling verified against
  fabricated frames.
- **M4 — one loop.** Stock-shaped loop wired end-to-end, **open-loop advisory first**:
  recommendations logged and compared against the phone's for the same glucose stream; then
  bench-pod closed loop. Acceptance: no cancel+set churn (rateRounder), IOB clamp effective in
  a synthetic high-IOB scenario, oscillation-free cadence.
- **M5 — loan protocol v2.** Both sides, v1 retired (version negotiation covers mixed builds
  during the switch). **Acceptance:** `RELEASE_TEST_SCRIPT.md` Parts A–C plus a new Part E:
  every row of the §2.4 failure matrix as a bench drill; the epoch race (B4) also as unit
  tests. On-body only after the full bench pass, with crude reinstall as the abort path.
- **M6 — the gate.** Re-run the **adversarial review harness** (same configuration as 2026-07)
  against the rebuilt tree; triage to zero criticals/highs or explicit owner acceptance.
  Full release script including Part D pre-person checks, plus the pre-production checklist
  (strip `FAKE_NEW_SENSOR`, test triggers, build-number display). Success criterion for the
  whole project: the new review's findings concentrate in the one novel module or below the
  crude version's floor — the thesis, tested twice.

---

## 5. Risk register

### 5.1 watchOS constraints that shaped the crude version — and how the stock-shaped design keeps the adaptations

| Constraint | Crude-version adaptation | Preserved how |
|---|---|---|
| No CoreBluetooth state restoration on watchOS | connect-per-reading G7 scheduler; armed-connect for the pod; everything runs under `HKWorkoutSession` runtime | Kept verbatim (transport layer + keepalive carry over). OmniBLE's restoration usage is `#if os(iOS)`-guarded; the watch host owns reconnect policy. **Residual risk:** `OmniBLEPumpManager`'s internal timers/status polling assume a long-lived iOS process — M2 verifies and, if needed, the host disables periodic polling in favor of command-driven status (a configuration, not a fork). |
| Process death is normal (background kills, installs, reboots) | journal persisted on every mutation; per-session loop opt-in | Stronger: stock `pumpManagerDidUpdateState` persists `PodState` (incl. in-flight commands) by design; DoseStore is durable; protocol v2 is relaunch-idempotent (epoch + IDs). Per-session closed-loop opt-in kept. |
| Battery (~28–32%/hr in sport sessions, display-dominated) | display levers; radio kept minimal | The rebuild must not add radio or CPU: rateRounder fix *removes* a per-reading cancel+set pair; CoreData writes per 5-min cycle are trivial. M3/M4 soaks compare battery against M0 baseline; regression blocks the milestone. |
| WatchConnectivity semantics (queued userInfo survives reinstall and redelivers; reachability flaps) | ad-hoc guards | Epoch + event-ID idempotency makes redelivery harmless by construction; no assertions on unknown payloads. |
| HealthKit workout session can't survive reboot; nothing auto-relaunches | "session ended" alert; pod autonomy backstop | Kept, plus the dead-man notification (§2.4 row 16). |

### 5.2 Second-system risks

- **Losing battle-tested behavior that lives in the crude code, not in docs.** Mitigation:
  `SAFETY_PARADIGM`'s measure inventory + `WATCH_LOAN_TESTING_BUGS.md` become an acceptance
  checklist; every OBS-graded measure must name its enforcement point in the new architecture
  before M5 closes (e.g. BUG-6 cancel-first → stock `PodCommsSession`; DESIGN-5 → watch
  HANDING_BACK state; 0.85 U journal-loss → DoseStore durability + streaming).
- **`OmniBLEPumpManager` porting turns into a fork.** 2.7k LOC of iOS-app assumptions is the
  single biggest unknown. Mitigation: M2 is early, cheap to fail, and has a named fallback;
  the delta against upstream is tracked as a patch that must stay reviewable.
- **Scope creep in the novel module.** The v1 coordinator grew to 1,155 lines with seven
  timers. Rule: protocol v2's state machines are the spec above; anything not in the failure
  matrix needs a new row (and a drill) before code.
- **Two worlds during transition.** Until M5, the crude build is the only on-body build.
  `g7-build-next` goes maintenance-only (safety fixes; no features) to avoid divergence.
- **Emulator trust.** The paradigm's M-rule stands: emulator-only validation counts for
  nothing; every M2/M5 acceptance is real-pod bench.

### 5.3 Owner rulings required (do not proceed unsupervised) vs. free to proceed

**Needs Jeremy's ruling — dosing semantics:**
1. Bolus-cap layering values (watch 1.0 / driver 1.0 / phone 1.05) and whether a **per-loan
   cumulative ceiling** is added (`SAFETY_PARADIGM` §2d-5).
2. Confirmation that max-temp derives from therapy max-basal (2026-07-15 ruling) and its
   pod-proof-limit companion in the stock-driver world.
3. Manual-suspend semantics (bounded 3 h zero-temp) and its hand-back/reclaim presentation.
4. Manual-bolus recency gate behavior on the watch (what replaces the placeholder UX).
5. Whether phone-pushed BG remains a dosing input during a loan (single-source-of-truth
   question deferred from the safety-review list) — sovereignty display alone vs. gating.
6. Watch DoseStore → HealthKit writes on/off; watch→Nightscout scope (P2#17).
7. Degraded-mode picker semantics (P1#15b) and the Sport-Mode identity/freshness-color UI.
8. Any on-body session of any milestone build.

**Free to proceed:** target/packaging work, `#if os` guards, the G7 adapter and parsing swap,
DoseStore host plumbing, protocol v2 implementation *per this spec*, all bench drills on the
bench pod, crash/robustness fixes from the findings list, test suites, log unification.

---

## 6. Upstreamable pieces

- **LoopKit:** `generateRecommendation` implementation (`c97bd056` — upstream's is a stub),
  the target-range Codable decode fix (`6e018f62`), LoopAlgorithm files in the
  `LoopKit-watchOS` target (`720ba2ab`), plus any store files added to the watchOS target in
  M1. Straightforward PR material.
- **OmniBLE:** the watchOS compile guards (state restoration `#if os(iOS)`, import hygiene,
  `.bytesArray` compat) and the `OmniBLE-watchOS` target itself — small, low-controversy.
  The `PumpConnectionLendable` / `releaseConnection` / `rearmConnection` seam is a coherent
  RFC on its own (generic "second controller borrows the pump" support), independent of our
  watch specifics.
- **Loop:** the boot-time nil-safe `askUserToConfirmLoopReset` crash fix (`e4e347f2`) —
  already identified as an upstream bug.
- **G7SensorKit:** the transport-injection seam behind `G7SensorDelegate` (makes the sensor
  logic testable and transport-agnostic upstream). The active-handshake transport itself
  (libg7auth) stays vendored here.
- **Not upstreamable:** the loan protocol (product-specific), the G7 J-PAKE assets
  (provenance), Sport Mode UI.

---

*Traceability: linkage facts from `Loop.xcodeproj/project.pbxproj` (WatchApp Extension
frameworks phase `43A9437B`, SPM refs `5107–5144`, G7 LDFLAGS `4576–4636`); OmniBLE/LoopKit
portability from the 2026-07-17 read-only audits of `OmniBLE/`, `LoopKit/`,
`PodSDK/PORT_NOTES.md` (noting its two stale claims); G7 reuse split from the G7SensorKit
audit; findings from the 2026-07 adversarial-review merged set (70 kept). File:line cites are
against `g7-build-next` at `e4e347f2`.*
