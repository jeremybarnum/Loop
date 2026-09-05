# G7 on the watch — the connection model

2026-08-22. Companion to next-dev's `POD_CONNECTION_MODEL.md`, same discipline: every claim is
tagged MEASURED (from field logs), CODE (read from source, cited), or UNVERIFIED (believed,
provenance weak). Written after two days of chasing "why is there no direct G7" through three
different causes.

## The one law that explains everything observed

**Direct G7 delivers readings ONLY while the app has runtime — foreground, or the workout
keepalive. There are zero exceptions in any log we hold.** (MEASURED)

| log | readings with runtime | readings while suspended |
|---|---|---|
| Caitlin, full history to 2026-08-22 | 9 | **0** |
| Jeremy build 226 | 81 fg + 4 keepalive | **0** |
| Jeremy build 268 | 45 | **0** |
| Jeremy build 256 | 48 | **0** |

The four "background" readings on build 226 all had `keepalive=running` — they are loan
readings, not counterexamples. The dichotomy that matters is **runtime vs suspended**, not
foreground vs background.

Corollary that cost us a day: "the G7 client runs continuously" is true of the CODE and false
of the PROCESS. The client is always *armed*; it only *executes* when something grants runtime.
An idle watch in normal wear is suspended nearly all the time, so "always-on acquisition before
a loan" mostly does not happen. The connect events still appear in the log — the OS delivers
them — but the authentication handshake that follows needs our code to run, and it cannot.

## What failure looks like when suspended (MEASURED)

The sensor connects on its ~5-minute cadence either way (the OS holds the link briefly).
What fails is the handshake:

    didConnect DXCMu0
    [cgm] error —: Sensor error Error enabling notification for authentication: unknownCharacteristic

The em-dash matters: it means the manager holds NO adopted sensor in memory. 86 of these in one
night (2026-08-21 22:23 → 08:41), while the same watch produced clean readings within seconds
whenever the wearer raised her wrist and interacted. Same signature as the three-day
stale-identity outage, DIFFERENT cause — check which sensor name appears (or doesn't) before
assuming either.

## The stack (CODE)

The watch runs the SAME G7SensorKit the phone runs — one submodule, one `G7CGMManager`, one
`G7BluetoothManager`. `StockLoopStack.assemble` constructs `G7CGMManager(rawState:)` exactly as
the phone's DeviceDataManager does. Fork additions on top (all in G7BluetoothManager.swift):
the radio census sink, the `sensorSighted` name feed, and the acquisition-trigger labels below.
There is no watch-specific radio code path to suspect when behaviour differs from the phone —
the difference is always the platform's runtime policy, not the code.

## What we ride, and what riding buys (CODE + MEASURED)

D2W enrollment (done once, in Dexcom's own watch app) creates the BLE **bond**. Our client
piggybacks that bond — proven 2026-08-06: a no-crypto binary got `bonded=1 auth=1` and real
glucose. Riding buys **DATA, not RUNTIME** (WorkoutKeepalive.swift header): Dexcom's app has
entitlements that grant it background BLE privileges, and entitlements are not inheritable by a
co-resident app. That asymmetry — same bond, different runtime rights — is the entire reason
Dexcom-on-the-watch works with the wrist down and we do not.

## watchOS app states, precisely (CODE — ExtensionDelegate.swift:88-130)

| state | meaning | our log marker | our code runs? |
|---|---|---|---|
| active | frontmost, wrist up, screen on | `[app] ACTIVE (wrist up, frontmost)` | yes |
| inactive | still frontmost, wrist down / dimmed | `[app] RESIGN ACTIVE` | yes (briefly-ish) |
| background | another app frontmost, or screen off | `[app] BACKGROUND` | seconds only |
| suspended | backgrounded and out of grace | (nothing — by definition) | **no** |

Two traps, both already paid for:
- RESIGN ACTIVE is NOT backgrounding. Wrist-down keeps the app frontmost-inactive and timers
  still fire. The old log said "BACKGROUND" for both and erased the distinction (fixed 2026-07-22).
- **watchOS has NO CoreBluetooth state restoration** (WorkoutKeepalive.swift header). A
  suspended app cannot be woken by a BLE event, ever. On iOS it can. This single platform
  difference is why the phone's G7 works backgrounded and the watch's cannot.

## Runtime sources (CODE)

1. **Foreground/inactive** — free, but only while the wearer engages.
2. **HKWorkoutSession keepalive** — the only self-service background runtime on watchOS.
   Refcounted by reason: `soak` (whole loan), `takeover`, `handback`. **All three are
   loan-lifecycle holders — nothing holds it outside a loan**, which is a deliberate battery
   choice (~5%/hour when held). Hence the law above.

## Acquisition triggers a/b/c (CODE — G7BluetoothManager.swift:191)

    (a) retrieveConnectedPeripherals at scan start — riding a link D2W already holds
    (b) connectionEventDidOccur — the OS reporting D2W (or anyone) connecting to a sensor
    (c) advertisement scan — the only path that needs active scanning

(a) and (b) are the piggyback: they exploit the sensor being connected to SOMETHING to skip
discovery. (c) is the cold path. All three still need runtime to complete authentication.

## Connection budgets

- **The sensor serves three display devices: phone app, direct-to-watch, and the receiver.**
  That is Dexcom's own documented topology (Jeremy, 2026-09-05 — not a community number).
  What remains UNVERIFIED is whether three is a hard ceiling in the sensor or just the supported
  set. MEASURED: the sensor counts DEVICES, not apps — every app on one device shares that
  device's single link and bond — and a Pi as a third radio beside the phone and the watch was
  served for 7 h (July 2026). Today's setup uses two: the phone and the watch.
- **~2 BLE links per app on watchOS.** UNVERIFIED — attributed to a WWDC session in prior
  discussions, but nobody in this project has re-located the primary source. Treat as folklore
  with supporting evidence, not spec. Empirical anchors: (1) hold-for-loan starved the G7 with
  CBError 11 and was rejected for exactly that ([[hold-for-loan-rejected]]); (2) 34 × "maximum
  number of connections" on Caitlin's watch 2026-08-20/21 with NO pod activity at all — so
  slot exhaustion can occur from G7-side churn alone (stale-identity reconnect loop).
- **App-level vs system-level: UNKNOWN.** The Caitlin datum (limit hit with zero pod links)
  weakly favours system-level or per-app-with-leak. Discriminator not yet designed.

## Design consequences

1. **Any "is direct G7 healthy?" check evaluated OUTSIDE runtime is meaningless.** The shipped
   Start gate (build 110) asks for a direct reading in the last 15 min — a window in which the
   suspended app could not have produced one. Chicken-and-egg: the loan grants the runtime the
   gate demands proof of. Slated for rework.
2. **During a loan, direct G7 genuinely works** — keepalive soak grants runtime, MEASURED on
   both watches. The product premise survives; the pre-loan expectation was the error.
3. **#104's false forgets are this same mechanism** — suspension kills auth mid-handshake and
   stock reads it as end-of-session. One law, three symptoms.
4. Post-loan, the watch goes back to sleep and relay resumes. That is the DESIGN, not a bug —
   but nothing currently tells the wearer which regime they are in.

## Open questions

- Can trigger (a)/(b) piggyback ever complete auth in the few seconds of background grace after
  a connection event? (Would explain rare stray readings if any turn up.)
- Where exactly is the 2-link budget enforced? Needs the discriminator.
- Does Dexcom's D2W hold its link continuously or duty-cycle it? Bears on slot arithmetic.

## 2026-09-05 addendum — a second law, and a correction

The law above (runtime or nothing) still holds for the IDLE watch. A second, different failure
is now measured and recorded in `G7_MUTE_INVESTIGATION_2026-09.md`: **with runtime present**,
a pending connect of ours on the sensor bond beside Dexcom's puts the watch's Bluetooth stack
into a state where neither app gets the link for 20–40 min ("the mute"). Dexcom alone is clean;
our parked request — even from an asleep app — is the necessary ingredient. Read that document
before touching `G7BluetoothManager`'s arming or re-arm code.

Correction to a claim made in passing this week: Dexcom's D2W reads DIRECT whether or not the
phone is nearby (the phone icon is its fallback when direct fails). The 09-03 afternoon tape has
56 Dexcom-initiated connections with the phone present. Do not describe D2W as "phone-fed when
the phone is near".
