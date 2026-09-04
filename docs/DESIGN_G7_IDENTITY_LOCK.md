# G7 identity lock — the live client never un-adopts a sensor that is in life

Status: DESIGN ONLY (2026-09-03 evening). Not built. Jeremy's call on scope and line.
Touches the G7 stack on Caitlin's line (G7SensorKit `g7-unproven-drop` + the watch extension).

## 1. The failure this fixes (tape of 2026-09-03, Jeremy's rig, build 162)

The watch connects to sensors other than its own for exactly one reason: the live G7
client's `sensorID` is nil. The connect policy (`G7Sensor.swift:258`) is already the
rule we want when a name is present — match → connect, mismatch → ignore. Promiscuous
`.connect` fires only in the nil state (stock's pairing mode: connect to anything,
let authentication decide).

Our watch enters the nil state constantly:

| how | where | today |
|---|---|---|
| stock end-of-session guess after a loan closes (disconnect with auth pending → `scanForNewSensor`) | `G7Sensor.swift:246`, `G7CGMManager.swift:358` | 09:39:50, 18:36:47 |
| the block screen's Reconnect / Re-acquire button (`scanForNewSensor`) | `GlanceController.rescanForSensor` | 18:40:40, 19:12:02, 20:10:41 |
| the sensor-switch override (`switchToSightedSensor` → `requestSensorRescan` → nil) | `WatchLoopManager.swift` | not today |
| fresh install (no identity at all) | — | 18:36 install carried the identity; not this case |

#104 keeps the identity ON DISK through the first case, but nothing re-seeds the live
client from it, so the two disagree until the next process launch. Consequences seen
today, all from that disagreement:

- **Direct path dead for 9 h while idle.** 09:32→18:36: 0 direct reads, 56 Dexcom
  connects observed, 86 auth-subscribe failures, 0 proven. In the nil state the client
  can only JOIN Dexcom's short link (trigger b, `.connect` branch, a fresh
  `G7PeripheralManager` per event) and that join has never completed discovery
  (`NO SERVICES (discovery incomplete)` / timeout). Invisible because the phone relays.
- **Foreign connects.** 18:40:26 Caitlin's DXCMRV advertised; the nil-state policy said
  connect; the watch held her sensor 13 s until it dropped us (18:40:39). At 20:40:24,
  adopted again, the same advertisement was correctly ignored.
- **Wrong-sensor block at the next Start.** Two foreign sightings + own silence > 45 min
  (it was 9 h, because of the dead path) → `sensorReadiness = .wrongSensor` → Start
  replaced by "No direct connection… Is Dexcom showing BG?" → its Reconnect button
  performs the forget that caused the state. 0-for-3 tonight. The 8/30 ranking
  (re-acquire 2-for-2) was measured on a FRESH INSTALL with no identity; it does not
  transfer to the identity-present case.
- **Force-quit "works"** because launch does the one thing nothing else does: restore
  the identity into the live client and connect on OUR OWN scan hit (20:31:31 launch →
  ad heard 2 s → own connect → auth OK → reading in 5 s).

Not fixed by this design (separate problems, separate docs): the pending-connect mute
(adopted client, `G7_WATCH_CONNECTION_MODEL.md`), the pod-scan-blind ladder of 20:31:43.

## 2. Principle

The persisted identity is the truth. The live client mirrors it. The live `sensorID`
is nil in exactly three situations: no identity exists (day one), the identity is past
its life (10 d 12 h, the existing escape), or the user / the switch rule has explicitly
chosen a DIFFERENT sensor — in which case it becomes that sensor's name at once, never
"anything".

## 3. Changes

### A. Soft re-adopt on forget (the core change)
In the `#104` branch of the rawState handler (`WatchLoopManager.swift:~3730`): when the
manager reports `sensorID == nil` and the stored identity is within life, do not merely
keep the disk copy — push it back into the live client:

```
cgmManager.readopt(sensorID: storedID, activatedAt: activated)   // new, G7CGMManager
```

`readopt` sets `state.sensorID/activatedAt` (no `extendedVersion` reset), zeroes the
auth-failure streak, and asks the sensor to `scanForPeripheral` for that name — the same
path launch takes (`G7 state RESTORED` → trigger c scan → `.makeActive` on the match).
Log: `[cgm] G7 identity RE-SEEDED from persisted state — <id> (stock forgot it; #104b)`.

Guard: never re-adopt mid-session on a peripheral that is currently connected (the
existing "never trigger on an adopted sensor mid-session" rule); the forget only fires
after a disconnect, so this is a debounce (≥ 2 s after the disconnect), not a new gate.

### B. Reconnect / Re-acquire becomes re-adopt
`GlanceController.rescanForSensor` calls A (targeted) instead of `scanForNewSensor`
(promiscuous). A true forget stays available ONLY behind the bench Diagnostics
"Forget Sensor" button. The `.unproven` "stuck" screen (streak ≥ 3) keeps its button,
also routed to A when an identity exists, to the old forget when none does (day one).

### C. Sensor switch is targeted, not promiscuous
`switchToSightedSensor` currently removes the identity and rescans for anything. Change:
adopt the SIGHTED name directly (`readopt(sensorID: name, activatedAt: nil)` — the
activation date lands with the first reading, as it does today). Authentication still
gates: a neighbour's sensor fails auth and is dropped, and the OLD identity is
restored (A) if the new one fails to authenticate within one transmit window. The
detector itself stays observe-only: names are in the advertisements and in the OS
connection events; no connect is needed to count a sighting.

### D. Readiness verdict logging
`sensorReadiness` transitions and every sighting increment go to SportLog:
`[readiness] ready → wrongSensor (foreign DXCMRV ×2 over 13s, own silent 9h04m)`.
Tonight the verdict had to be inferred from the absence of a Start tap.

### E. Day one stays as is
With no identity, the client is promiscuous by necessity. The stale-wrapper join
failure (`g7-cold-acquisition-pathology`) remains open and is NOT in scope here; day
one users get the existing streak counter and the old re-acquire.

## 4. What this does and does not claim

- Does: removes every foreign connect after day one; keeps the direct path alive across
  loan closes (today's 9 h gap becomes ≤ 1 window); makes the block screen's remedy the
  one that actually works; keeps Caitlin's 8/21 sensor-change case covered (the
  detector is unchanged, only its action is targeted).
- Does not: change the mute. The mute happens in the ADOPTED state on a pending connect.
- Exposure both ways: our nil-state connects to her sensor and hers to ours are the same
  bug; this closes both once shipped on both wrists.

## 5. Tests before any wrist

- Unit (`WatchAppTests`): rawState nil with identity in life → `readopt` called once,
  not per state change; identity past life → cleared (existing); `.wrongSensor` needs
  own-silence AND ≥ 2 sightings (existing) and its action adopts the sighted name;
  readiness transition lines emitted.
- Sim: bench "fake forget" → within one tick the live `sensorID` equals the persisted
  one; no `.connect` decision is ever returned while an identity exists (policy test).
- Bench (Jeremy's rig): close a loan, then count direct reads over the next 3 windows
  (today: 0 over 9 h). Caitlin's sensor in the room must produce sightings and zero
  connects.

## 6. Instrumentation to land with it (holes tonight exposed)

- Start-tap mark into SportLog (RuntimeStateLog.mark is memory-only).
- Takeover-failure report on the urgent WC path (tonight it queued; the phone sat in
  grant-offered with the pod released for 4 min).
- Phone logs its pod link actually dropping after a grant (`didDisconnect`), not just
  "released".
- Port the wildcard scan probe (`pod-enact-failure-is-discovery-side`, 8/20) so a
  pod-blind ladder says deaf vs rejected.

## 7. Ship order

Jeremy's line first, one day of loans with Caitlin's sensor in the room; then hers.
