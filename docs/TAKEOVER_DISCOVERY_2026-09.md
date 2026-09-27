# Takeover discovery — why a watch takeover can "never hear the pod" (2026-09-24 → 09-26)

Bench: the bench rig (Apple Watch SE 3, water-filled DASH pod 0x17a6219a, iPhone, builds 3006
and the prod-123-diag diagnostic build). Field: the production user's 2026-09-24 failures on
build 123. Claims are tagged **MEASURED** (on tape, cited), **UNVERIFIED** (believed, no arm yet)
or **DEAD** (tested and refuted).

## 1. The failure

A Sport Mode takeover runs a 14-read ladder (~111 s) and ends `TAKEOVER FAILED — pod NEVER
HEARD`: the watch's scan for the pod's service (0x4024) reports nothing at all, while the phone,
which has just released the pod, re-links it within seconds after the failure.

- **Field, 2026-09-24 12:50–13:09 (MEASURED, production user, build 123):** three grants (e23,
  e25, e26) heard zero pod adverts. The other attempts in that stretch were collateral (a phone
  out of reach, an offline start confirmed after the phone had re-linked the pod, an epoch
  collision, two "pod still returning" denials).
- **Bench, 2026-09-26 (MEASURED):** reproduced three times (e132, e137, e139), each with the
  phone's advert listener hearing the pod throughout (e137 and e139: 11 of 11 ten-second
  windows). The pod was advertising and in reach; the watch did not find it.

## 2. The mechanism (MEASURED)

**With the watch screen off, a takeover cannot discover a DASH pod.** Two facts combine:

1. **watchOS runs third-party scans passive while the screen is off.** The watch's bluetoothd
   logs `screen? 0` and `Starting passive scan` for our "start active ThirdPartyApp scan"
   requests, every one, for as long as the screen is off; `screen? 1` flips it to `Starting
   active scan` within milliseconds of the screen coming on (captures 2026-09-26 12:08 and
   14:35, e132, e134, e137). The duty cycle stays high (30 ms of every 40 ms) — the scan is
   running, just passive. There is no public CoreBluetooth option to request an active scan;
   duplicate reporting is foreground-only; Apple's background scanning is passive.
2. **A DASH pod carries its service IDs only in its scan response.** Packet trace (Bluetooth
   logging profile, `logs/Bluetooth/bluetoothd-hci-*.pklg`, decoded with tshark): the pod's
   legacy connectable advert (extended type `…13`) holds only flags (AD 0x01) and manufacturer
   data (AD 0xFF). The complete 16-bit service list (AD 0x03: `4024 2470 000a 17a6 219a 0859
   9821 0032 363f` — the nine IDs `PodAdvertisement` parses, the pod address in the 4th/5th)
   travels only in the scan response (type `…18`). A passive scan never requests it, so a
   0x4024-filtered scan can never match with the screen off. The trace holds exactly four
   0x4024 reports — the four screen-on discoveries — and zero reports from the pod during
   e137's 109 s screen-off window.

**Corroboration (MEASURED):**
- Every `[SCAN] ad seen` on record — 30 across both watches' logs before 09-26, 7 more on
  09-26 — happened with the app on screen. None with it off.
- 2026-09-26 tally, e132–e141: 7 of 7 screen-on discoveries (0.1–0.75 s after the scan began,
  or 0.10 / 0.61 / 4.4 s after a wrist raise); 0 discoveries in ~470 s of screen-off scanning.
- The phone was a natural experiment on the same pod at the same time (12:08 capture): its
  listener scanned passive 11:39:27→11:40:00 and heard nothing; another client pushed the
  phone's radio to active at 11:40:00.60 and the pod appeared 1.4 s later, then in 7 of 9
  windows.
- The wildcard probe (unfiltered, 10 s) heard 0 devices in all six screen-off runs and 4
  devices (one of them this pod) in the one that ran as the wrist came up — the radio is not
  deaf.
- Mid-loan reclaims work with the wrist down (reconnect ~0.6–1 s, no `ad seen` line): they
  connect by the watch's known handle, which the controller completes off the pod's
  connectable advert without any discovery.

**Why results look inconsistent:** the takeover scan starts 1.6–2.9 s after Start is tapped
(request → grant → pump rebuild) and a screen-on scan finds the pod 0.1–0.8 s later. A user who
taps and drops the wrist races that window: if the first advert beats the screen going off the
takeover succeeds (and the rest completes wrist-down); if not, nothing is heard until the screen
comes back on.

## 3. What is ruled out (DEAD)

- **RF reach / body shadowing as the bench cause:** pod on the far side of the body read −92 dBm
  and was found in 1.1 s with the screen on; the bench failures had the phone hearing the pod
  at −57…−78 throughout.
- **A deaf watch radio:** screen-on wildcard hears devices; screen-on scans find the pod in
  under a second; the daemon never paused the scan.
- **The phone re-grabbing the pod:** the interlock census reads `whileLoaned=none` on every
  failed loan, field and bench.
- **Bluetooth toggle as the remedy:** e133 succeeded 30 s after e132 with no toggle. The
  failure message that asked for one has been replaced.

## 4. The production user's 2026-09-24 case

**Largely explained (UNVERIFIED in detail).** The described behaviour — tap Start, lower the
wrist, walk around, check, tap again — maximises screen-off time, and every screen-off moment of
those attempts could not discover the pod. The pod sat on the far side of the body, her weakest
position. What the mechanism alone does not explain: her screen-on stretches at the start of e23
(~4 s), e25 (~13 s) and e26 (~15 s) also found nothing, where the bench finds the pod in under a
second. Leading explanation: active discovery is a two-way exchange (scan request, scan
response) and fails far more often than passive listening at a marginal link — the weakest body
position, possibly a weaker watch radio. To test with the diagnostic build on her watch:
time-to-`ad seen` and RSSI with the wrist held up at her real pod position; the same pair
measurement on the bench watch; and a sysdiagnose with the Bluetooth logging profile after any
failure, which will show whether her screen-on scans ran active and whether any scan response
arrived.

## 5. The fix (version A, built on the production line 2026-09-26)

**Connect by saved handle; discover only on first contact.**

- **Saved handle (OmnipodKit, watchOS).** The first time a takeover finds a pod, the watch keeps
  its own CoreBluetooth handle for that pod's address (`PodLoan.watchPodHandle`, one pod at a
  time). Every later takeover of that pod retrieves the handle and connects directly — no
  discovery, so the screen state does not matter — with the 0x4024 scan still armed as a
  backstop. A handle the system no longer knows falls back to the scan. Log lines: `[HANDLE]`.
- **First contact (watch).** With no saved handle for the granted pod, the glance says "First
  Sport Mode on this pod — keep your wrist up until the pod is found", switches to "Pod found —
  you can lower your wrist" the moment the pod is reached (advert heard or handle connect
  landed; only discovery needs the screen), and taps the wrist — at 8 s and 30 s, at most twice
  — if the takeover is still unfound with the screen off ("Raise your wrist to finish
  connecting").
- **Failure message.** "The watch never found the pod. Tap Start and keep your wrist up until it
  says the pod is found."
- **Before the tap (prod-123-diag, 2026-09-26).** The watch records the current pod's address
  from every dormant grant and grant; when it holds no handle for that address, the Start screen
  says so under the button. A saved handle the watch no longer knows at takeover (e.g. after a
  restart) switches the takeover screen to the wrist-up prompt at once
  (`podLoanOnDiscoveryNeeded`). The idle screen cannot see that case in advance.

**Alternatives considered:** a phone-led "introduce the pod to the watch" step at pod setup
(removes the first-contact prompt, but changes the phone's pod-setup flow, which stays stock —
only if A proves annoying); opportunistic learning of the handle whenever the pod is heard
(free but unreliable — the pod advertises only in the phone's brief reconnect gaps); a standing
watch connect to the pod (**rejected** — it would take the pod whenever the phone's link blips);
wrist-up prompts alone with no saved handle (relies on the user every time). Deferred: starting
the takeover scan at Start from the dormant grant's pod address, which would shorten the
first-contact screen-on window by ~1.5 s.

**To verify on the bench (UNVERIFIED until run):** the saved handle survives hours, app
relaunches and a watch reboot; the pod's radio address is stable for its life (it was identical
all day 09-26); a handle connect issued while the phone still holds the pod lands ~1 s after the
release, screen off. Tests: End, wait an hour, Start with the wrist dropped immediately (×5);
repeat after a watch reboot and the next day; on a pod change, the first-contact prompt appears
exactly once.

**Next-dev already has the core of this.** Since 08-20 its watch caches its own handle per pod
address (OmnipodKit `PodLoanBleIdentifierCache`), and each grant dials it with
`podLoanBeginTakeover(discover: false)` — no scan at all, deliberately no scan backstop (a 09-16
field lookup race). Only its FIRST contact with a pod discovers, so the first-contact prompt is the
part that still applies there. (An earlier version of this line said next-dev discovers every
takeover; it read only the uncalled `retrieveAndConnectKnownPod`. Corrected 2026-09-27.)

## 6. Instrumentation added on the way (prod-123-diag and 3006)

- Watch: the no-advert wildcard probe (`[SCAN] wildcard probe`), and `scan=`, `ads pod= target=`,
  `probes[...]` on every takeover read; `[bt]` watch Bluetooth off/on from launch.
- Phone: `PodAdvertListener` — `[advert]` lines naming each pod heard from the grant's release
  until the watch confirms or fails the takeover (kill switch `PodLoan.podAdvertListenerDisabled`).
  A background phone scans passive too, so "not heard" proves little; "heard" proves the pod
  was advertising.

## 7. Reading a capture (recipe)

1. Install Apple's Bluetooth logging profile on the watch (it expires after four days — check
   `logs/MCState/Shared/MCProfileEvents.plist` in the newest capture before assuming it).
2. Take the watch sysdiagnose within ~2 h of the event (bluetoothd default logging retention).
3. Daemon log: `/usr/bin/log show --archive <watch>/system_logs.logarchive --predicate 'process
   == "bluetoothd"' --info --debug --start … --end …`, then grep `Starting (active|passive)
   scan|screen\? [01]|ThirdPartyApp`.
4. Packets: `tshark -r logs/Bluetooth/bluetoothd-hci-*.pklg -Y 'btcommon.eir_ad.entry.uuid_16 ==
   0x4024' -T fields -e frame.time -e bthci_evt.le_ext_advts_event_type -e bthci_evt.bd_addr -e
   bthci_evt.rssi`. The trace clock reads four hours behind local (UTC labelled local).
