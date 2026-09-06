# The G7 mute — investigation record and current model (2026-09-02 → 09-05)

Bench: Jeremy's rig (water pod, real sensor DXCMbv, watch SE 3 cellular, build 160→169).
Every claim is tagged MEASURED (on tape, cite the arm), UNVERIFIED (believed, no arm yet) or
DEAD (tested and refuted). Supersedes the "open question" in `G7_DIRECT_FIELD_RECORD.md` §5
and extends `G7_WATCH_CONNECTION_MODEL.md`, whose one law (runtime or nothing) still holds and
is a *different* failure from the one described here.

## 0. The phenomenon (MEASURED)

- **Definition.** Consecutive 5-minute windows with no direct reading on the watch while the
  sensor keeps bursting on its grid (Mac passive scanner, `ops/g7scan-ctl.sh`, date-stamped
  since 09-03). Typical run 20–40 min; 45 min (overnight 09-05), 70 min with no recovery
  (apartment walk 09-04).
- **Shared fate.** Dexcom's direct-to-watch goes dark on the same burst and returns on the same
  burst, every instance (Jeremy by eye + the connection-event census, which sees any app's
  links). Dexcom's app declares "Direct to Watch not working — stay close to your phone" within
  one window. Our tape never shows the two apps out of step inside a mute.
- **Per-window signature.** Our own scan hears the sensor's advertisement (rssi −77…−86) and
  no connect callback follows; our pending connect ages untouched; zero connection events from
  any app. The watch is not deaf. It is not connecting.
- **Recovery.** On the sensor's one-minute cadence (short bursts, 0.3–2.8 s) — which is NOT
  "distress because nobody collects": on 09-05 15:13→15:22 (sniffer, host-clock stamps) the
  sensor ran the minute cadence while Dexcom's watch app read every window, with the PHONE in
  a Faraday case. Read together with the apartment arm (phone collecting, watch muted, no
  minute bursts, no recovery over 14 windows): the minute cadence appears when the PHONE — a
  specific bonded collector — is absent, and it is what gives a muted watch its extra chances.
  When the phone keeps collecting there is no minute cadence and no recovery. A watch Bluetooth toggle
  ended one mute at the next burst (09-05 13:05; N=1, the mute was one window old — repeat
  after ≥3 missed windows before treating as proven).
- **The grid.** 275 bursts over 50 h: spacing 300.00 s ± 1.2 s, phase drifting +4 s/day
  (Jeremy's ":x1:35 / :x6:35"). The next burst is known to a second or two from the last read.

## 1. Exclusion table — every arm, what it showed, what it killed

| arm (date) | what was on the bond / running | result | kills |
|---|---|---|---|
| Dexcom alone, 90 min (09-05 11:14→12:38; our app had no request: `peripheral=none`, suspended) | Dexcom's request only, phone BT off, watch Wi-Fi off, Dexcom complication on the face | **clean, every glance** | "the OS + an unreachable phone do it alone" |
| Backgrounded (09-05 12:42→13:40) | Dexcom's + OUR pending request, our app ASLEEP, no keepalive, no loan, no pod | **INCONCLUSIVE**: Dexcom stale by eye at ~13:02 (one window), watch BT toggled 13:05, reading at 13:06. Our tape is blind here by construction (an asleep app only runs on wrist-up; its MISS lines mean "we did not read", true either way); the 13:22 wake delivered 16 queued connection events for 12:56→13:22, so links did come up in that span. A one-window stale has recovered on its own before. | nothing on its own; the pod/loan/transport exclusions come from E1, which was awake |
| E1 soak (09-05 09:36→11:13) | ours + Dexcom's, our app AWAKE (keepalive), no loan, no pod | **mute 10:11→10:36; second mute from 11:01 with the phone REACHABLE** | pod, loan, transport; "phone must be unreachable" |
| Quiet window (build 165, 09-05 overnight, 81 windows) | loan; bracket −20 s…+40 s around every burst, 0 deferred actions | first-window miss + 9-window mute with the air provably silent | contention from our app at the burst |
| WC silence A/B/A (club 09-04, 23 windows) | loan; transport suppressed (the OS kept 21 transfers "in flight" anyway) | 15/15 hits with 50 files queued; 35-min mute with the switch OFF | the WatchConnectivity backlog |
| Scan-while-pending ON (09-03/04) | loan; app scan armed beside the pending connect | ads heard, no connect (23:51, 00:21, 00:31, 00:38) | "Mechanism 1" scan-arm stall as the cause |
| Force-quit mid-mute (09-04 00:36) | our process gone; Dexcom alone | Dexcom stayed dark; both back at 00:41 | anything in our live process |
| Fresh process mid-mute (09-04 00:38) | new central, connect() issued on a heard ad | no connect | per-process state |
| Recycle (cancel + fresh request) | 4 trials | 2 hits (23:37, 23:41), 2 misses (23:51, 00:31) | request age alone |
| Pod correlation (all windows 09-03→05) | pod scan/connect within ±40 s of each burst | no pattern; one first miss with the pod at −1 s (apartment 20:26), the rest with the pod idle | pod timing as THE cause (one contributing instance stands) |
| Wrist state (E1) | wrist up/down at each burst | hits wrist-down, a miss wrist-up | wrist state |
| Phone reachability | apartment walk, phone in pocket, `reachable=true` 3 h | 20 hits then 14-miss mute, no recovery | "unreachable phone required" |
| Sensor slots | Pi as a 3rd bonded reader 7 h (July); the sensor closes every session itself (`CBErrorDomain#7`) | served 3 clients; we never hold a link | sensor-side slot exhaustion |

**Still standing on the clean side, unexplained by the model below:** every multi-hour clean
run with our request parked was with Jeremy ASLEEP (overnights: 46/46 phone present/off,
34/34 phone present, 8/8 silence-on phone away, 64 straight hits 09-05). Every mute happened
with a human awake. The Dexcom-alone control was awake and clean, so "awake" is not
sufficient; "awake + our request" is what has muted, "asleep + our request" has not. UNVERIFIED
whether that is causal (the watch's own activity when worn awake) or a coincidence of
sampling (nights are long and quiet).

## 2. The model (what the exclusions leave) — SUPERSEDED 09-05 night by §3d

Everything below §2 was written before the watch sysdiagnose. Read §3d first: the mechanism
is bluetoothd's per-device signal-quality tally raising a −70 dBm gate on the shared
auto-connection. Items 1–3 here are kept as the history of how the exclusions were reached;
where they conflict with §3d, §3d wins ("our request is the ingredient" is DEAD — see §3b/§3d).


1. **Necessary ingredient (MEASURED):** our AWAKE client with its pending connect on the sensor
   bond beside Dexcom's. Dexcom's request alone is fine for 90 minutes; add our awake client
   (E1: no pod, no loan) and both go dark within the hour. Whether our request from an ASLEEP
   app is enough is UNTESTED (the backgrounded arm was inconclusive, see the table); every
   long clean run had exactly that configuration overnight.
   NOTE (Jeremy, 09-05): two readers on one bond is the NORMAL stock arrangement — on the
   phone, Loop's G7SensorKit rides the Dexcom iPhone app's bond the same way, with the same
   code and the same 2 s re-arm, and the phone collected straight through the 70-min apartment
   mute. The sensor's slot limit is per device, not per app: two apps on one device share one
   physical link (the second connect completes on the existing link — the "join" mechanism).
   So neither "a second reader" nor slot arithmetic is the difference; whatever watchOS does
   with a parked request beside another app's is. Do not describe this as a platform
   difference in the arrangement.
2. **Location (MEASURED):** below both apps, in the watch's Bluetooth stack. It survives our
   process being killed and a fresh process cannot get through it; a radio toggle clears it
   (N=1). The OS holds one connect entry per peripheral address for the whole watch; when that
   entry is parked or half-formed, every app on the bond waits together.
3. **Mechanism (UNVERIFIED, two candidates):**
   - the stack parks the entry after some trigger and does not act on advertisements it is
     receiving (our scan hears them) until an external event resets it;
   - a connection half-forms at the link layer (the controller answers a burst, the host never
     completes it), and the entry is held until that zombie times out.
   The re-issue of our request 2 s after every sensor drop, while the sensor is still tearing
   down, is the leading candidate trigger (in E1 every connection of the night was initiated by
   us, never by Dexcom). The first-miss cause varies (one pod collision on tape); what sustains
   the mute is the parked entry.
4. **What it is NOT (DEAD):** pod radio, loan protocol, WatchConnectivity backlog, quiet
   bracket, scan arming, our runtime, request age alone, phone reachability, wrist state,
   sensor slots, sensor health, RF environment (the Mac hears every burst).

## 3. Instruments in hand

`[g7-window] HIT/MISS` per expected burst with the radio snapshot (`pendingConnect`,
`scanning`, `rearm=`, `ride=`), `[quiet] OPEN/CLOSE/DEFERRED`, connection-event attribution
(`ours` / `OTHER APP`), `[g7-drought]` on the loan pulse, the Mac scanner (grid + bursts +
marks), Dexcom's watch app by eye, and the Radio Lab switches: scan-while-pending, watchdog,
pod-wait, quiet window, WC silence, **re-arm mode** (stock 2 s / 30 s / late-arm, build 168),
**ride-only** (no request of ours while adopted, build 169), the E1 soak (167), the manual
recycle, and the watch's own Bluetooth toggle. Off-watch: the Nordic nRF sniffer — the only
instrument that can show whether the watch transmits `CONNECT_IND` during a mute. Working
setup as of 09-05 (an afternoon of traps):
- The dongle enumerates as `/dev/cu.usbmodem1101`; the extcap interface is
  `/dev/cu.usbmodem1101-4.6`. The plugin in `~/.config/wireshark/extcap` must run under its
  own venv (`~/.config/wireshark/snifferenv`); put that venv's `bin` FIRST on `PATH` when
  running tshark, or the `.py` copy runs under Homebrew's Python without pyserial and reports
  "no such device" (the interface then shows as `…-None`).
- The sensor advertises in plain LEGACY mode with a STATIC random address:
  `f9:55:62:8d:5e:56` for DXCMbv (from the Pi's HCI trace, `btmon`). It does not use extended
  or coded advertising — a stray `ADV_EXT_IND` at −82 dBm sent me down that hole for an hour.
- Scan mode hops channels and misses `CONNECT_IND`; FOLLOW mode on the address is required.
  The plugin only follows from Wireshark's toolbar, so `~/Downloads/Loop/ops/g7sniff/g7follow.py`
  (README beside it) drives the SnifferAPI directly (scan → follow(address) → pcap, re-arming
  after a quiet link).
- The library's derived packet timestamps drift by up to two minutes across a capture; stamp
  packets with the host clock at receipt (g7follow2 does) or nothing lines up with the watch log.
- **The sniffer catches a `CONNECT_IND` only about one time in three.** It listens on one of
  the three advertising channels per advertising event; the request lands on whichever
  channel the initiator heard. 09-05 15:21:40: the watch log shows a join onto Dexcom's link
  (`didConnect`), the sniffer saw 118 advertisements in that burst and no request at all. A
  request SEEN is strong evidence; a request NOT seen is weak. Never write "nobody asked"
  from this instrument alone.
- MEASURED (09-05 15:22→15:26, sniffer + watch log): the sensor IGNORES connection requests
  at its minute bursts and accepts them at the five-minute burst. Same requester (the watch,
  our own stock-path request after a forget) → 15:22:39, 15:23:37 ×3, 15:25:38: three master
  polls each, no reply; 15:26:37.85: full link in 0.7 s (version, features, encryption).
  The reference picture of a good connection is `scratchpad/sniff/follow2.pcap` frames from
  15:26:37.868.
- MEASURED (09-05 15:21): a ride-only join can connect and get nothing — `didConnect`
  15:21:40.0, no discovery/auth lines, sensor drop at 15:21:48.3 (`#7`), stock forget. Cause
  not on the tape. First failed join in 14 ride-only windows.
- **Ride-only hole (found 09-05 15:21):** after any failed join, stock forgets the sensor and
  the DISCOVERY path (`handleDiscoveredPeripheral` → `.makeActive` → `connect()`) issues our
  own request again until the next successful read; the switch only gates the
  retrieve-known path. Between 15:21:48 and 15:26:39 the arm was stock, not ride-only. Fix:
  when ride-only is on and the persisted identity is known, the discovery path must register
  for connection events and wait, not connect. Built as 170 — and **170 broke the join**:
  the gate asked the CBPeripheral whether it was connected, but each app holds its own handle
  and ours reads `.disconnected` until WE connect, so the join never issued its connect(),
  re-registered, the OS re-fired CONNECT, and it looped (965 repeats; zero direct reads from
  the 16:19 install to 16:47, the watch on phone relay the whole time). 171 passes
  `viaLinkUp` from the connection-event and system-connected callers instead. Lesson for
  anything touching the join: the only proof is a direct read at the first burst after
  install — check the tape before walking out the door.
  Corollary found at 17:01: flipping ride-only OFF does not re-arm — re-arm runs only after
  a disconnect or at launch — so an app that is adopted with no request and no scan stays
  stuck between both behaviours (17:01: link-up notice, "no pending connect of ours", no
  join). Recycle cured it in one burst (17:05:46 → read at 17:06:40). The Radio Lab now
  recycles on either flip (committed for the next build).
  **171 verified on wrist 17:16:38→40:** sensor sighted → "adopted from the air, no request
  of ours" (one line) → Dexcom's link up → join → auth OK → read; zero suppressed repeats
  since launch. The walk-away loan test runs on 171.

## 3a. Q1 first result — ride-only E1, 09-05 14:08→15:51 (build 169, the switch alone)

| | |
|---|---|
| windows under ride-only (from 14:11:49) | 19 |
| read | 18 (every one on Dexcom's link, `pendingConnect=never`) |
| missed | 1 — 15:21, a join that connected and got no data; single window |
| mutes | **0** |
| phone absent | 14:41→15:51 (microwave two rooms away; Wi-Fi trickle, no BLE) |
| stock E1 the same morning | mute at ~35 min, again at 11:01 |

Caveats: one run; the phone was present for the first 32 min; Caitlin's devices were in the
room from ~15:30 (window results come from the watch log and are unaffected; the air's
requester addresses are unattributable after that); 169 still had the discovery-path hole
(§3), which reverted the arm to stock for 15:21:48→15:26:39 — closed in 170.

**The phone's return (MEASURED, phone log + sniffer):** the phone reconnected at 15:50:39 —
a MINUTE-burst time, 243 s after the last grid reading, with a 15-reading backfill — so the
sensor admits the phone at the minute bursts it refuses the watch at. The minute cadence
stopped with the phone home: the sniffer, which had seen the sensor advertise every minute
from 15:13 to 15:48, saw it only at the grid bursts (15:51, 15:56, both answered) through
15:58. Rule as it now stands: **the one-minute advertising is
the sensor looking for the PHONE; it starts when the phone stops collecting, admits only the
phone, and stops when the phone is back.** A missing watch does not start it.

## 3b. Q1 second result — ride-only LOAN, walk-away, 09-05 17:12→18:31 (build 171) — **MUTED**

| | |
|---|---|
| 17:21:40 | read (join on Dexcom's link, no request of ours) |
| 17:26:43 → 18:06:43 | **10 consecutive misses, 45 min**; `pendingConnect=never` on every verdict; no scan; app awake (soak keepalive, timers on schedule); Dexcom's watch app dark the whole time (Jeremy) |
| pod | present (in his pocket: connect RSSI −77 at 17:21:52, −73 at 18:12:02) but IDLE from 17:22:09 to 18:12:00 — no glucose → no loop cycle → no reclaim; quiet window closed around every burst with 0 pod actions deferred |
| ~18:10 | watch Bluetooth toggled (Settings; app suspended 62 s) → Dexcom read at the first burst after (18:11:43) → toggle cure **N=2**, this time on a 10-window mute |
| 18:11:12 | force-quit + relaunch; 18:11:45 join → auth on a 6 s link → NO SERVICES (third failed join of the day: 15:21, 17:11, 18:11); seize 18:11:59 → loan re-taken (epoch 301) |
| 18:16 → 18:31 | reads on Dexcom's link, joins clean; home 18:30, retro-ack + keep protocol OK on the phone |

**What this kills:** "our pending request is the ingredient". The mute ran 45 minutes with no
request of ours on the bond, no scan of ours, and the pod radio idle. Ride-only is NOT the
fix. What survives: the mute is a watch-stack state both apps suffer; a radio toggle clears
it (2/2); it has happened with our app AWAKE every time and never (yet) with our app
suspended (Dexcom-alone control: 90 min clean).

**The ride-only E1 soak (§3a) versus this loan — what differed:** loan/pod (idle at bursts,
present), walking versus sitting at the desk, the Mac's active scanner beside the sensor
during the soak and absent here (it sends SCAN_REQs at every burst), 103 min versus a mute
at window 2. One run each; the soak's single miss at 15:21 may have been a mute that
happened to clear at the next window.

**Instruments on the walk: none.** The laptop stayed home; the sniffer heard 4 packets per
10 min from 17:20 and the Mac scanner went nearly deaf at the same time (2–23 lines per
10 min against ~270 before) and has not heard the sensor since — the scanner needs a
restart before the next arm. There is still no air record of a mute.

**Apartment reproduction attempt, 09-05 19:12→20:4x (build 171, ride-only loan): NO wedge.**
Everything alive at the start, one good read, then phone Bluetooth OFF and (intended) watch
Wi-Fi off at 19:19; sitting in the dining room, later "fake motion" at the table; Caitlin's
devices in and out of range; pod on him. Reads at EVERY window from 19:16 through 20:11 (12/12 on
Dexcom's link, no request of ours). 19:36 has no verdict line because the window monitor's
timer was lost while the app was suspended (`GAP 52s — app was NOT executing` at 19:33:52,
despite the soak keepalive) — the read itself landed at 19:36:39.9 when the connection event
woke the app. Two such suspensions during a keepalive-held loan (19:20, 19:33) are worth
knowing about but are not the wedge. Full tape (uploaded 20:42): **18/18 direct reads 19:16→20:41, zero misses** — the "one miss"
seen by eye was a glance showing a stale age, not a missed window. Wrist-wake counts 1–14 per
10 min while sitting, rising to 19 per 10 min during the fake-motion stretch (20:30s), against
~25 in the 11 min before the walk's wedge; still no wedge. Phone-side dosing audit: 14 checkpoints accepted, every residual ≤ 0.05 U.

Sniffer, advertising-only follow, beside him the whole time: at MINUTE bursts a wrist-distance
requester sent 4 requests in 2 s (20:15) and 9 in 3 s (20:18), all ignored — the first look at
the retry behaviour when the sensor refuses a device. Attribution is impossible while
Caitlin's un-adopted watch is in range (it tries any DXCM it sights). Calibration: the 20:26
grid burst, ten seconds of advertising with no request captured, was a clean read — burst
length and "no request seen" mean nothing; only the tape decides HIT/MISS.

**What separates the wedges from the clean runs after tonight:** every wedge on record came
during real walking with the watch handled often (today's walk, the apartment walk 09-04, the
club); every clean multi-hour run was still or lightly handled (overnights, the desk soak,
tonight). Not the app, not the switch, not the pod, not the phone's state, not Wi-Fi. The
watch's own wake path in our code touches nothing radio-related (checked: WC activation,
ensureKeepalive, a glance refresh). Next reproduction: real walking — pace the apartment 20–30
min with the loan and instruments in range, or repeat the outdoor walk with the laptop in a
bag — and take the watch sysdiagnose (Bluetooth logging profile installed 09-05 ~19:05 on
watch and phone) when a wedge is three windows old, BEFORE any toggle.

## 3c. THE FIRST WEDGE ON THE AIR — 09-05 20:46→21:04 (build 171, ride-only loan, indoor walking)

Indoor walking from 20:42 (watch Wi-Fi off, phone BT off, laptop carried then set down
beside him). Our app missed 20:46 and 20:51 (seen live: no BG by ~20:54); Dexcom's app
dropped at 20:56. Instruments were deaf 20:44→20:53 (laptop carried against the body — both
its radios go silent; leave it on a table) and 21:00→21:02, so 20:46, 20:51 and 21:01 are
lost; **20:56 is captured in full:**

- **The sensor advertised for 25 s** (20:56:38.48→20:57:03.49, 316 frames on the sniffer,
  19 on the Mac scanner). Sensor-side wedge EXCLUDED. A healthy burst ends within ~7 s.
- **Two nearby scanners sent it ~50 scan requests** during those 25 s (−43…−56 dBm at the
  dongle — arm's reach). The watch's radio hears the sensor and actively scans it.
- **Nobody sent a CONNECT_IND.** Not the watch, not anyone. At the minute bursts that
  followed (20:57, 20:58, 20:59, 21:02→21:05, 3 s each) likewise: scans, no requests — where
  before the wedge a watch hammered minute bursts with 4–9 requests each.
- **The watch's own tape (flushed 21:07):** last good read 20:46:41 (a join on Dexcom's link);
  pod reclaim cycle 20:46:54→20:47:16 (dose program sent, link released), then the pod idle
  for the rest; misses at 20:51, 20:56, 21:01 with `pendingConnect=never`, `scanning=false`,
  and NOT ONE connection event delivered by the OS in those 15 minutes — so from inside the
  watch no link to the sensor ever came up, while from outside the sensor advertised and the
  watch scanned it. App awake throughout (quiet-window timers on schedule), wrist wakes 22 in
  the five minutes before the first miss (12 in the five before that). The first miss (20:51)
  came at the second burst after walking began at 20:42 — the same onset as the outdoor walk
  (17:21 read, 17:26 miss, walking from ~17:20).
- **Reset:** crown+side held too long → force RESTART at 21:04 (not a sysdiagnose). First
  burst after boot, 21:06:39: 2 frames on the sniffer, 4 on the Mac — an instant connect.
  Reboot cure N=1, toggle cure N=2.

**Reading:** during a wedge the watch's Bluetooth stack still scans the sensor (SCAN_REQ) but
never initiates (no CONNECT_IND) — Dexcom's standing request and, in stock mode, ours are
both parked below the app layer; a radio reset (toggle or reboot) is what frees the
initiator. Sensor, pod, phone state, Wi-Fi, our request and our code are all excluded for
this instance. Onset conditions: 4 min of real walking with the watch handled; sitting and
fake motion never produced it (90 min, 18/18, the same evening).

## 3d. THE MECHANISM, IN bluetoothd's OWN WORDS — watch sysdiagnose taken 21:15 (log archive covers 17:00→21:16)

`logs/Bluetooth/*.pklg` only cover the post-reboot minutes (21:03→21:16) and the host issues
no scans, so the radio trace is a healthy reference only. The unified log archive
(`system_logs.logarchive`, read with `/usr/bin/log show --archive … --predicate 'process ==
"bluetoothd"'` — NOT the zsh builtin `log`) covers the wedge itself. What it says:

1. **One auto-connection per device, shared by every app.** Dexcom's app and ours are
   "interested in" device B484E4A3… (DXCMbv); bluetoothd keeps ONE entry for it on the
   controller's connection filter-accept list and runs "auto connection for 1 devices" with a
   connection scan (Low: 30 ms per 300 ms). Every app-level request rides that entry. That is
   the shared fate, mechanically.
2. **A per-device "signal-quality disconnection" tally with a 20,864 s (5.8 h) window.** The
   sensor's normal end-of-read close (`reason 719, encrypted:1`) does NOT count — 13 of them
   17:00→20:46 left the count at 3. A link that comes up and dies before encryption
   (`"successful but already disconnected"`, `reason 762, encrypted:0`, `"Connection failed
   to device SENSOR, Retrying"`) DOES count. Two of those at 20:47:01 and 20:47:06 took the
   count 3→4→5.
3. **At count 5 the daemon flips `updateLeConnectionRSSIThresholdState … from 0 to 1`** and
   re-adds the sensor to the accept list with **`minRSSI=-70`** (every healthy add, 19:36,
   19:41, 19:46, 20:41, 20:46, 21:07, 21:08, 21:11, was `minRSSI=-100`). From 20:47:06 the
   controller ignores every advertisement from the sensor weaker than −70 dBm. That is the
   wedge: the sensor calls in the clear, the watch's scanner even sends it scan requests, and
   the initiator never answers because the gate says the signal is too weak.
4. **What the 762s are:** the daemon's auto-connection latching onto one of the sensor's calls
   that are not for the watch (the one-minute calls for the absent phone, or the post-read
   tail): the link forms and the sensor kills it before encryption — exactly the
   `CONNECT_IND → three master polls → no reply` the sniffer saw at minute bursts all day.
   Each such refusal is booked by bluetoothd as a signal-quality failure of the DEVICE.
5. **Reset:** the reboot at 21:04 zeroed the count (`count 0` at 21:08:42, `minRSSI=-100`).
   A Bluetooth toggle presumably does the same (cure N=2). Whether a strong-signal success
   resets the state, or the window simply ages events out, is what makes some mutes
   self-clear in 20–45 min — not established.

**Why walking, why phone-away, why never asleep — in this light:**
- phone absent → the sensor calls every minute and refuses the watch → material for 762s;
- walking → the daemon cancels/re-issues the pending connection every few seconds (scan
  parameter flaps, some following our app's foreground/background updates) → many fresh
  initiator windows → a higher chance of catching a refused call → 762s accumulate; sitting
  the same evening produced 13 × 719 and zero 762s;
- the gate BINDS at ordinary wrist-to-sensor distance: the only two sensor RSSI readings the
  daemon logged are −69 (20:46:54) and −75 (21:07:38). Once up, the gate stops the reads
  whether walking or sitting. The sitting run 19:36→20:36 was clean with the tally at 3 and
  the gate DOWN (−100) at every add — so walking's role is in PRODUCING the two 762s, not
  (only) in weakening the signal;
- asleep: no minute calls' refusals get caught (no churn), no RSSI swing, and the phone is
  usually near.

**Adversarial checks run (09-05 night):** the archive keeps bluetoothd's debug-level lines
only from ~19:30 (≈1.75 h before the capture); the afternoon wedge 17:26→18:06 is NOT in
it (24 lines), so the mechanism is established for ONE wedge, tonight's. The threshold "5" is
read off a single 4→5 transition. Why the sensor was advertising at 20:47:01 and 20:47:06
(off its :38 minute grid, 20 s after the read, during our pod reclaim cycle) is unknown — the
sniffer was deaf then; both 762s fell inside the pod link (20:46:55→20:47:13), which puts the
pod back on the list as a possible FIRST-cause contributor, not as the sustainer. The
self-clearing of earlier mutes (20–45 min) is not explained by a 5.8 h window. Take the next
wedge's sysdiagnose within an hour of onset or the detail is gone.

**Excluded by this capture:** cellular coexistence (`No CoexRequested` throughout), the
sensor, the pod, Wi-Fi, our request (ride-only, `pendingConnect=never`), our code.

**What this means for a fix (NOT built — Jeremy's call):** the gate is bluetoothd's, per
device, fed by every app's requests, and Dexcom's standing request alone can fill it. So
nothing in our radio code can prevent it outright. Levers that exist: (a) keep no standing
request of ours and issue none near the minute calls (phase-locked connect around the
five-minute burst only) so we never add 762s; (b) minimise our churn of the daemon's
connection-scan parameters (scan restarts, connection-event re-registration, state churn);
(c) detect the gate (two missed windows with the sensor known to be calling) and tell the
wearer the only known cures: Bluetooth toggle or restart; (d) test Dexcom-alone walking
phone-away — if that wedges too, this is D2W's own limit and Dexcom's "stay close to your
phone" is describing exactly this.

**Remaining discriminator (not built):** "keepalive only" — our G7 client fully off (no
adoption, no connection-event registration, no scan) while the app is held awake, phone
away, ≥90 min. Mute → being awake beside Dexcom's bond is enough and the fix is not in our
radio code; clean → the standing connection-event registration is the ingredient.

## 4. Next tests, top-down, each with its predictions

**Q1 — Is it the existence of our request, its timing, or its order?** (the fix question)
- *Ride-only E1*, phone away, awake, ≥90 min. Clean → existence: our request must not sit on
  the bond; ride-only is the fix. Mute → our connection-event registration or mere co-residence
  matters, and the remaining difference from the control is only that (surprising, and worth a
  second run).
- *Late-arm E1*, same conditions. Clean while stock mutes → order/timing; a request that is
  young and second-in-line is safe.
- *Delay-30 E1*. Clean → the 2-second re-issue into the sensor's teardown is the trigger.

**Q2 — Where is the parked state?** (the mechanism question)
- *Toggle replication:* at the next mute, wait for three missed windows, then Settings →
  Bluetooth off/on, no app touched. Next-burst recovery → watch stack, proven.
- *Sniffer during an E1 mute:* no `CONNECT_IND` from the watch → the host is not asking
  (parked entry); `CONNECT_IND` answered then torn down → half-formed link; either result is
  the first mechanism-level fact.

**Q3 — Is "awake" causal?** *E1 overnight* (asleep, phone away, our request parked, stock
re-arm). Eight hours clean → asleep protects and the watch's own awake-time activity is part
of the trigger; a mute → the overnight runs were luck of sampling.

Order by information per hour: Q1 ride-only (also the candidate fix), then Q1 late-arm, then
Q3 overnight (free), sniffer and toggle as they become available. One variable per arm.
