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

What does NOT exist:
- **Per-sensor pairing code.** The code is HARDCODED to `3102` (`G7Client.pin`). Nothing
  reads or writes it — no entry UI, no phone hand-off. It works today only because the
  current sensor's code is 3102. **A real new sensor (different code) fails auth
  outright** (`aesVerifyFailed`). This is the gating gap.
- **Any handling of `aesVerifyFailed`** beyond throwing it — the chosen "Option 3"
  just-in-time code prompt was never built.
- **Sensor-change detection** — nothing reacts to a new sensor ID / activation.
- **A CGM-connection countdown** — nothing predicts or surfaces the expected connect time.

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
    glucose store when building.**
  - The predictive scheduler already predicts the grid (`predictive 300s grid, lead
    45s`) but self-calibrates from the watch's OWN reads. The new piece is **seeding the
    phase from the phone's history** so it's known *immediately* at Sport Mode start.

Expected connect time, per case:
- **Known sensor** (bonded before, phase from phone history): named path catches the
  predicted chirp → wait ≈ residual, **high-confidence countdown**.
- **First-ever sensor** (no bond yet): must scan to discover. Foreground → fast (~75–85s
  in logs). The predicted chirp time is a **best case**; a missed chirp costs +5 min.

---

## 3. Component A — Per-sensor pairing code (the prerequisite, "Option 3")

Each G7 has a unique 4-digit code. We cannot hardcode it, cannot read it from the phone
(G7SensorKit stores no code; it rides the OS bond), and cannot derive it from a scan.
Jeremy chose the **watch just-in-time prompt** among the three options.

Design:
1. Store the working code **keyed by sensor** (persist to disk; key by the phone-reported
   sensor ID when available, else "current").
2. **Detect a new sensor** two ways (whichever fires first):
   - The phone reports a new sensor ID / activation date (relay it to the watch), OR
   - The handshake throws `aesVerifyFailed` (the stored code doesn't match this sensor).
3. On detection, surface a watch prompt: *"New sensor — enter its 4-digit code"* (Digital
   Crown / keypad entry). Reuse the existing editable `G7Client.pin` field as the sink.
4. Persist the entered code (per sensor) and **retry the handshake** immediately.
5. On success, the durable identifier is bonded + saved → the sensor becomes "known" for
   all future (named) reconnects.

Failure copy: if the entered code also fails, *"That code didn't match — check the code on
the sensor or in the Dexcom app and try again."*

This is the backbone: without it, a new sensor cannot connect at all.

---

## 4. Component B — Two-screen activation UX with a CGM countdown

Extend the existing `WatchPodControlView` (which already shows pod + "G7 Direct"):

- **Screen 1 — Pod.** The pod-connection / sovereignty half (already built).
- **Screen 2 — CGM.** Replace the bare "waiting" state with an honest, phase-driven
  status:
  - Compute the next expected chirp from the phone's recent glucose timestamps at the
    moment Sport Mode starts.
  - Show a **countdown**: *"Sensor: reading expected in ~3 min (10:05)."* Update live.
  - When a read lands, snap to the confirmed ✓ (existing `sensorConfirmed`).
- **Arm the reader to the prediction.** Since we know the chirp time, arm the named
  connect just before it — the countdown is not just informational, it's what the reader
  times itself to. Keep the app **foreground** through the predicted chirp (the countdown
  screen naturally does this, which is also what keeps a first-ever scan unthrottled).

---

## 5. Component C — Known vs first-time messaging

Detect which case we're in (do we hold a durable identifier for the *current* sensor ID?)
and set expectations honestly:

| Case | Detection | Copy |
|---|---|---|
| **Known sensor** | persisted identifier matches current sensor ID | "Reconnecting — glucose expected ~10:05." (near-promise; named path) |
| **First-time on this sensor** | no identifier for this sensor ID | "First-time setup for this sensor — expect glucose around 10:05, but first connections can take a few minutes. We'll alert you if it doesn't land." |

The first-time path should also trigger Component A's code prompt if the stored code
fails.

---

## 6. Component D (optional) — Pre-warm the bond on new-sensor detection

The durable name needs only ONE foreground bond. When the phone reports a *new* sensor
ID, optionally prompt: *"New sensor — open the watch near it once to pair."* Do a single
foreground handshake (code prompt + bond + save identifier). Then even the FIRST Sport
Mode on that sensor is a "known" sensor: fast named path, confident countdown, no
first-time uncertainty at the moment the user actually wants to go phone-free.

---

## 7. Dependencies & sequencing

1. **Cold-start fix** (this branch) — DONE, needs on-device validation (force-quit test).
2. **Component A (per-sensor code)** — the prerequisite; nothing new-sensor works without
   it. Build + test first with an actual new sensor.
3. **Phase/countdown plumbing (B)** — verify glucose-timestamp granularity, seed the
   scheduler from phone history, surface the countdown.
4. **Messaging (C)** — cheap once A + B exist.
5. **Pre-warm (D)** — optional polish.

Also fold in (separate, pre-existing): **gate the reader to Sport Mode** for production,
instead of the always-on bench behavior.

---

## 8. Open questions to verify before/while building

- **Glucose-timestamp granularity** on the watch (sets countdown precision). §2.
- **Service-filtered scan**: does the G7 advertise its service UUID *discoverably* (vs
  only in service data)? If yes, `scanForPeripherals(withServices: [G7 service])` beats
  the current `nil` scan in the background. Check the nRF sniffer captures.
- **Sensor-ID relay**: confirm the phone can relay the current sensor ID / activation to
  the watch (for keying the per-sensor code and known/first-time detection).
- **`aesVerifyFailed` vs other failures**: make sure the code-prompt trigger fires only on
  a genuine wrong-code, not on a dropped-chunk/transient decrypt error.
