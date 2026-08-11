# What survives on the watch — force-quit vs new build vs delete

The rule is simple: **force-quit and TestFlight update both KEEP the app's
container; only DELETING the watch app wipes it.** So every persisted item below
survives both a swipe-kill and a build install — and all of it is gone only if you
delete-and-reinstall the app.

## Persisted watch state (UserDefaults + one file)

| Item | Key / location | Survives force-quit | Survives new build | Survives delete |
|---|---|---|---|---|
| **Sensor ID** (warmup identity) | `g7.lastKnownSensorIDv1` | ✅ | ✅ | ❌ |
| **Pairing code / PIN** | `g7.sensorCodeV1` | ✅ | ✅ | ❌ |
| **BLE bond handle** (fast reconnect) | `savedPeripheralKey` | ✅ | ✅ | ❌ |
| **Prewarm-pending flag** | `pendingPrewarmKey` | ✅ | ✅ | ❌ |
| Prewarm fail counter | `prewarmFailKey` | ✅ | ✅ | ❌ |
| Acquisition mode | `reconnectModeV2` | ✅ | ✅ | ❌ |
| Role / auth bytes | `roleByteDefaultV2`, `authEndByte` | ✅ | ✅ | ❌ |
| **Loan phase / epoch / pod raw state** | `PodLoanWatchController.*` | ✅ | ✅ | ❌ |
| **Loan journal** (undrained records) | file in AppSupport | ✅ | ✅ | ❌ |

In-memory only (lost on ANY relaunch, rebuilt from the above): the live
`CBPeripheral` handle, handshakeActive, the active pod BLE session, the in-flight
takeover ladder, and `handbackRequested`.

## The sensor warmup specifically

The three things the warmup needs — **sensor ID, pairing code, and the BLE bond** —
all persist across a build install. So installing a new build does **not** force a
cold re-bond: the first Sport Mode after an update takes the fast targeted-connect
path, not a from-scratch J-PAKE. A warmup only re-runs from scratch if you (a)
delete the app, or (b) the sensor ID changes (new sensor → `pendingPrewarm` re-arms,
which is the intended path).

## Your mid-session build install — the clean procedure

You've been reclaiming the pod + force-quitting the watch before installing. On
**build 125+ you don't need to.** A relaunch during an active loan (which is exactly
what a build install is) now:
1. detects the interrupted `.active` loan at launch,
2. shows a "Session Ended" alert on the watch,
3. sends a released hand-back to the phone → the **phone auto-reclaims the pod**,
4. leaves the sensor bond intact so the next Sport Mode is fast.

So the consistent flow going forward is just: **install the build, let the watch
relaunch, confirm the phone shows it reclaimed the pod ("Pod on Watch" clears), then
Start a fresh Sport Mode.** No manual reclaim, no force-quit. (On ≤124 the manual
reclaim WAS needed — that's the source of the old confusion.) If anything ever does
look stuck, the recovery paths are the real ones: the phone's escape hatch (long-press
the on-loan notification → Reclaim Pod), the normal hand-back, or an app relaunch.

(`debugReset` on the diagnostic screen used to be recommended here as "the hard nuke
back to idle". It was removed 2026-08-11: in an ACTIVE loan it abandoned the loan
rather than resetting it — pod orphaned on its last command, phone still believing the
watch held it, staged-but-unacked doses stranded under a cleared epoch. Reach for the
phone's escape hatch instead; it takes the pod back properly.)

## When to test the new-sensor / warmup protocol

The warmup-from-a-new-sensor path (code arrives → `pendingPrewarm` arms → bounded
bond scan) is a **separate** test from the acquisition-cadence work and shouldn't be
mixed into it — one variable at a time. Test it deliberately when you actually change
sensors, or force it on the bench via the diagnostic panel's **Prewarm G7 Now** after
clearing the bond (or with the FAKE sensor tool). Don't run it during the 126
predictive-scan cadence test — a mid-soak re-bond would muddy the cadence readout.
Queue it for its own session once the cadence question is settled.
