# Design: New-Sensor Workflow + Sport Mode CGM-Connection UX

Status: **proposed / not yet built.** Branch context: `g7-reader-coldstart`.
Author trail: Jeremy + Claude, 2026-07-16.

This spec DEFINES a workflow that does not exist yet. Read the "Current reality"
section first — an earlier recollection that this was "built but untested" is wrong.

---

## 1. Current reality (verified 2026-07-16)

What EXISTS:
- **The G7 reader** (`G7Client`), started **unconditionally at app launch**
  (`ExtensionDelegate.applicationDidFinishLaunching` → `g7.start()`), NOT gated on
  Sport Mode. This is a bench artifact; production should gate it to Sport Mode
  (running it in normal phone-centric mode is redundant with the phone's relay and
  costs battery).
- **The Sport Mode activation UI** (`WatchPodControlView`): two progress bars — pod
  connection + "G7 Direct" — driven by `sensorConfirmed`. This is the natural HOME for
  the countdown below. Its sensor half has **never been validated on-device** (the
  reader kept failing until the cold-start fix on this branch).
- **The cold-start fix** (this branch, `7bc3ede6`): on a post-crash/relaunch cold
  start, restore the persisted bonded identifier and run a targeted `connect()` in
  PARALLEL with a scan. Converts the failing "background scan" reacquire into the
  proven "named" path.
- **A phone-side new-sensor SIGNAL (verified — the key enabler).** The phone DOES know
  when a new sensor starts. `G7CGMManager.sensor(_:didDiscoverNewSensor:activatedAt:)`
  fires on a new sensor: it logs it (`logDeviceCommunication`), persists `sensorID` (the
  sensor name, e.g. `DXCMp5`) + `activatedAt` into `G7CGMManagerState`, and emits a
  first-class `PersistedCgmEvent(type: .sensorStart, deviceIdentifier: name…)` up to the
  `CGMManagerDelegate` — Loop's `DeviceDataManager`. There's also a public `G7StateObserver`
  interface (`addStateObserver`) and `sensorName` / `sensorActivatedAt` / `lifecycleState`
  accessors. **Loop receives this event today; it just doesn't act on it for our workflow.**

What does NOT exist:
- **Per-sensor pairing code.** The code is HARDCODED to `3102` (`G7Client.pin`). Nothing
  reads or writes it — no entry UI, no phone hand-off. It works today only because the
  current sensor's code is 3102. **A real new sensor (different code) fails auth
  outright** (`aesVerifyFailed`). This is the gating gap.
- **Any handling of `aesVerifyFailed`** beyond throwing it.
- **A phone→watch relay of the sensor ID / activation / code**, and any hook on the
  `.sensorStart` event (the signal arrives at `DeviceDataManager` but is unused for this).
- **A CGM-connection countdown** — nothing predicts or surfaces the expected connect time.

The one thing the phone still does NOT know: the **4-digit code itself**. G7SensorKit reads
glucose without it (lower-privilege path than the watch's authenticated handshake). So the
phone knows a new sensor *started* and its *ID/activation* — the user still types the code
once per sensor; we just do it at the right moment and place.

---

## 2. The connection model (the physics this UX must respect)

- The G7 produces a reading every **5 minutes** and *advertises* ("chirps") for a few
  seconds around each 5-minute mark, then hangs up (~3s) — "connect-per-reading." The
  post-read disconnect is NORMAL, every cycle; do not treat it as failure.
- Two ways to catch a chirp:
  - **Named / targeted connect** — a standing "wake me for THIS address" order to the
    Bluetooth controller. NOT throttled. Empirically 15/15. Requires a durable
    identifier, which only becomes stable **after the first bond** (the G7 rotates its
    address; only the bond's IRK resolves rotations to one identifier).
  - **Scan** — sweep for any G7. **Throttled in the background** by watchOS (Apple
    policy; the always-on exemption is a CGM-maker entitlement we cannot get). Catches
    the chirp reliably only in the **foreground** (continuous radio).
- **Phase is knowable for free.** In normal use the phone has been receiving readings
  every 5 min via the official channel and relaying timestamped glucose to the watch
  (WatchContext / WCSession). Those timestamps reveal the **phase of the 5-min grid**.
  So at Sport Mode start we can compute the next chirp time — collapsing the a-priori
  `Uniform(0, 5 min)` wait (mean 2.5 min) down to a near-deterministic countdown.
  - Precision caveat: depends on the granularity of the glucose timestamps the watch
    actually holds. Second-resolution → "~10:05:10 ±10–15s jitter"; if snapped to the
    minute/5-min mark → a coarser but still useful window. **VERIFY against the watch's
    glucose store when building.** (`activatedAt` from the phone is a fallback phase
    anchor — the grid is set at activation.)
  - The predictive scheduler already predicts the grid (`predictive 300s grid, lead
    45s`) but self-calibrates from the watch's OWN reads. The new piece is **seeding the
    phase from the phone's history** so it's known *immediately* at Sport Mode start.

Expected connect time, per case:
- **Known sensor** (bonded before, phase from phone history): named path catches the
  predicted chirp → wait ≈ residual, **high-confidence countdown**.
- **First-ever sensor** (no bond yet): must scan to discover. Foreground → fast (~75–85s
  in logs). The predicted chirp time is a **best case**; a missed chirp costs +5 min.

---

## 3. Component A — Per-sensor pairing code (the prerequisite)

Each G7 has a unique 4-digit code (printed on the applicator/box). We cannot hardcode it,
the phone never learns it, and it can't be derived from a scan. So the user must type it
once per sensor — the design decision is *where and when*.

### PRIMARY: phone-driven, triggered by the phone's `.sensorStart` event

Ruling (2026-07-16): make this the primary path — it is strictly better than a watch prompt
now that we've verified the phone gets a precise new-sensor signal (§1).

1. **Hook the new-sensor event on the phone** — in `DeviceDataManager` (the
   `CGMManagerDelegate`) catch the `.sensorStart` `PersistedCgmEvent`, or subscribe to the
   G7's `G7StateObserver`. Both carry the new `sensorID` + `activatedAt`.
2. **Prompt on the phone** (exactly when the sensor is added). Draft copy — refine:
   > "Please input the sensor code from the Dexcom applicator to enable Sport Mode on the
   > watch."
   - **MUST use the phone's native NUMERIC keypad** (`keyboardType = .numberPad`, or a
     `UIAlertController` text field set to `.numberPad`). Big keys, the standard phone
     number pad — NOT a custom in-app tiny picker/wheel. (Jeremy: hates tiny in-app number
     entry.) 4 digits, digits-only, with a clear/backspace.
3. **Store the code keyed by sensor ID** on the phone, and **relay to the watch** over
   WatchConnectivity — bundle the `code` + `sensorID` + `activatedAt` (the watch needs the
   ID/activation anyway for known-vs-first-time detection and phase seeding).
4. The watch stores the code per sensor; its next authenticated handshake uses the right
   code → bonds → saves the durable identifier → "known" thereafter.

Why phone-primary: the phone has a real keyboard, *knows* precisely when a new sensor
starts, and is where the user already is when adding a sensor. The code is a low-sensitivity
4-digit pairing PIN; relaying it phone→watch over the existing encrypted WC channel is fine
(store it in the app group / keychain, keep it out of plaintext logs).

### FALLBACK: watch just-in-time prompt

If the watch tries to connect and the stored code is missing or wrong (`aesVerifyFailed`),
prompt on the watch (Digital Crown / keypad, reusing `G7Client.pin`). Covers the phone never
prompting (older phone, a race, or code entered before this feature existed) or a mistyped
code. Retry copy: *"That code didn't match — check the code on the sensor or in the Dexcom
app and try again."*

This is the backbone: without a per-sensor code, a new sensor cannot connect at all.

---

## 4. Component B — Two-screen activation UX with a CGM countdown

Extend the existing `WatchPodControlView` (which already shows pod + "G7 Direct"):

- **Screen 1 — Pod.** The pod-connection / sovereignty half (already built).
- **Screen 2 — CGM.** Replace the bare "waiting" state with an honest, phase-driven status:
  - Compute the next expected chirp from the phone's recent glucose timestamps at the
    moment Sport Mode starts.
  - Show a **countdown**: *"Sensor: reading expected in ~3 min (10:05)."* Update live.
  - When a read lands, snap to the confirmed ✓ (existing `sensorConfirmed`).
- **Arm the reader to the prediction.** Since we know the chirp time, arm the named connect
  just before it — the countdown is not just informational, it's what the reader times
  itself to. Keep the app **foreground** through the predicted chirp (the countdown screen
  naturally does this, which is also what keeps a first-ever scan unthrottled).

---

## 5. Component C — Known vs first-time messaging

Detect which case we're in and set expectations honestly. Detection is now clean: the phone
relays the current `sensorID`; the watch checks whether it holds a durable bonded identifier
for that ID.

| Case | Detection | Copy |
|---|---|---|
| **Known sensor** | watch holds a bonded identifier for the phone-relayed sensor ID | "Reconnecting — glucose expected ~10:05." (near-promise; named path) |
| **First-time on this sensor** | no identifier for this sensor ID | "First-time setup for this sensor — expect glucose around 10:05, but first connections can take a few minutes. We'll alert you if it doesn't land." |

The first-time path relies on Component A having supplied the code (phone-primary, watch
fallback).

---

## 6. Component D (optional, now cheap) — Pre-warm the bond on new-sensor detection

The durable name needs only ONE foreground bond, and the phone now has the exact trigger
(the `.sensorStart` event). On new-sensor detection, after collecting the code (§3), the
phone can nudge: *"New sensor — open the watch near it once to pair."* The watch does a
single foreground handshake (it already has the code) → bonds → saves the identifier. Then
even the FIRST Sport Mode on that sensor is a "known" sensor: fast named path, confident
countdown, no first-time uncertainty at the moment the user actually wants to go phone-free.

---

## 6b. Component E — Test hooks: fake a new sensor WITHOUT burning one

Real G7 sensors are expensive and single-use, so we can't activate one per test iteration.
The workflow must be exercisable in software, reserving **one** real new-sensor run for the
final check. The key realization is that there are two layers, and only one of them actually
needs a real sensor:

- **Plumbing** — event → phone prompt (keypad) → store code → relay to watch → watch stores
  code per sensor ID → known/first-time detection → countdown. **Fully fakeable.** This is
  the bulk of the new code.
- **The authenticated handshake with a DIFFERENT code** — needs a real sensor (a real BLE
  device with a real, different code). But it's the *same* J-PAKE handshake already proven
  with the current sensor; the only new variable is "does a different 4-digit code bond." So
  it's a **single** final validation, not something to repeat.

Hooks — all behind a `FAKE_NEW_SENSOR` compile flag (and/or `#if DEBUG`), so they compile
OUT of release builds but are one flag away for regression (prefer a flag over commenting
out, per Jeremy — commented-out code rots):

1. **Phone: "Simulate new sensor"** — fabricate a `.sensorStart` `PersistedCgmEvent` with a
   synthetic `sensorID` + `activatedAt` and feed it through the SAME `DeviceDataManager`
   handler the real event uses. Exercises the phone prompt (keypad), code storage, and the
   watch relay end-to-end. Assert the watch receives `code + sensorID + activatedAt`.

2. **Watch: "Forget this sensor"** ← the star hook. Clear the persisted bonded identifier +
   stored code for the CURRENT (real) sensor. The watch then treats the real sensor as
   first-time on the next attempt, so the ENTIRE first-time path — code prompt/relay →
   handshake → bond → save identifier → countdown → "known" — runs against the **real**
   sensor, repeatably, for free. Crucially this exercises the REAL handshake and bond, not a
   mock. The one thing it can't vary is the code value (the real sensor's is fixed) — which
   is exactly what the single real-new-sensor test covers.

3. **Watch: "Force wrong code once"** — inject a bad code so the handshake throws
   `aesVerifyFailed`, to exercise the FALLBACK watch prompt + retry, then succeed on the
   correct code.

4. **Phone: sensor-ID override** (optional) — report a synthetic `sensorID` so the
   known/first-time detection sees a "different" sensor with no physical change.

Coverage: #1 = phone plumbing; #2 = full watch first-time path *including the real handshake*
(free, repeatable); #3 = fallback prompt; #4 = detection logic. **Real new sensor (once):**
only the "a genuinely different code bonds" case. Wrap the real-sensor checklist in the test
plan so we spend at most one sensor confirming it.

---

## 7. Dependencies & sequencing

1. **Cold-start fix** (this branch) — DONE, needs on-device validation (force-quit test).
2. **Test hooks (E)** — build these ALONGSIDE Component A, not after, so A is exercisable
   without burning sensors from day one. Especially the "Forget this sensor" watch hook.
3. **Component A (per-sensor code)** — the prerequisite; nothing new-sensor works without
   it. Build the phone-primary path: hook `.sensorStart` in `DeviceDataManager` → phone
   prompt (numeric keypad) → relay code+ID+activation to the watch; add the watch fallback
   prompt. Iterate against the fake hooks; spend ONE real new sensor on the final check.
4. **Phase/countdown plumbing (B)** — verify glucose-timestamp granularity, seed the
   scheduler from phone history, surface the countdown.
5. **Messaging (C)** — cheap once A + B exist.
6. **Pre-warm (D)** — optional polish.

Also fold in (separate, pre-existing): **gate the reader to Sport Mode** for production,
instead of the always-on bench behavior.

---

## 8. Open questions to verify before/while building

- **Glucose-timestamp granularity** on the watch (sets countdown precision). §2.
- **Service-filtered scan**: does the G7 advertise its service UUID *discoverably* (vs
  only in service data)? If yes, `scanForPeripherals(withServices: [G7 service])` beats
  the current `nil` scan in the background. Check the nRF sniffer captures.
- **`.sensorStart` timing**: confirm the phone's event fires promptly when a new sensor is
  activated in the Dexcom app (i.e. as soon as Loop's G7CGMManager first reads the new
  sensor), not only after a long delay — that sets how "at the right moment" the phone
  prompt is. (The signal exists; the open item is exactly *when* it lands.)
- **Code relay storage**: store the per-sensor code in the app group / keychain, keyed by
  sensor ID; keep it out of the log file. Low-sensitivity PIN, but not in plaintext logs.
- **`aesVerifyFailed` vs other failures**: make sure the watch-fallback code prompt fires
  only on a genuine wrong-code, not on a dropped-chunk/transient decrypt error.
