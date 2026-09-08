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
  When the phone keeps collecting there is no minute cadence and no recovery.
  **ESTABLISHED 09-05 23:26→23:37 (sniffer, phone BT off, watch BT off, our app quit — nobody
  asking, the Mac's scanner the only scanner on the air):** the sensor called at 23:27:38,
  :28, :29, :30, :32, :33, :34, :35, :36 (3 s each) and ran its grid bursts at 23:26:38 and
  23:31:38 for the full ~25 s. The minute cadence is the SENSOR's own behaviour when the phone
  is absent; it does not depend on any watch asking. A watch Bluetooth toggle
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

**Framing correction (Jeremy, 09-05 night):** do not presume D2W fails in normal use — it
works for many people walking without their phones. The tally was fed by two specific failed
links, and the suspects for producing them are things only OUR loan adds: both 762s fell
inside our pod reclaim link (20:46:55→20:47:13), and both of today's wedges began at the burst
after a read that was followed by a pod cycle. The sitting run had pod cycles too and no
762s, so the pod link is not sufficient alone; walking adds radio timing under motion and/or
the sensor advertising again ~20 s after the read (sniffer deaf then). First test = isolate
OUR contribution: walk with the soak (app awake, no loan, no pod), phone away, sysdiagnose
within an hour of any wedge; clean soak + wedging loan → the post-read pod link is the
suspect and the fix candidate is ours and small (extend the quiet window through the sensor's
post-read period). A Dexcom-alone walk is a control of last resort, not the first arm.

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

**Built 09-05 23:00 (Jeremy: "this feels like a harmless change"): the pod radio policy** —
one Radio Lab row, `Pod radio: quietGate / slots / off`, replacing the "pod waits for G7
session end" and "quiet window" rows (`G7Lab.podRadioPolicy`, default `quietGate` = the
previous behaviour, so nothing changes untouched). `slots` = the pod may use the radio only at
+70…+110, +130…+170, +190…+230 and +250…+280 s after the burst — everywhere the sensor has
never been seen active across 2,600 captured frames, with 10 s of margin either side of the
burst+tail (0→~25 s) and of the phone-absent calls (+60/+120/+180/+240). Anchored to the last
direct read and carried through misses on the sensor's grid; the pre-burst bracket stays on;
WatchConnectivity sends and log hops still key on the bracket alone. Cost: the dose lands
~70 s after the reading instead of ~13 s. Pure policy (`PodRadioSlotPolicy`) + 7 tests.
Readout for whether it helps: a loan walk under `slots`, phone away, then the sysdiagnose —
the daemon's `getNumDisconnectionsBySignalQuality` count must stay put where it used to rise.

## 3e. SECOND INSTANCE, SITTING STILL — watch sysdiagnose taken 23:16 (log 22:55→23:17)

Ride-only OFF, scan-while-pending ON, E1 soak, no loan, no pod, phone BT off, sitting at the
table for the RSSI survey. The daemon's tally, step by step:

| time | what the daemon logged | tally |
|---|---|---|
| 22:56:54 | normal read + close (719); re-armed at −100 | 0 |
| 23:01:41→50 | read (Dexcom's link), close 719; **re-armed 2 s later, into the sensor's post-read tail** | 0 |
| 23:02:02 | link formed on the tail and collapsed before encryption (762) | 1 |
| 23:06:51 | read, close 719, re-arm into the tail | 1 |
| 23:06:54, 23:07:01, 23:07:06 | three collapses on the tail (762 ×3) | 4 |
| 23:11:51 | read, close 719, re-arm | 4 |
| 23:13:40 | the +120 s minute call: link formed, collapsed (762) | **5 → threshold 0→1, minRSSI −70** |
| 23:16 | no connection (2 cancels) — the wedge Jeremy reported | |

Sniffer view of 23:01: seventeen `CONNECT_IND`s from the watch inside the burst's 28 s,
mostly unanswered — that is the re-armed auto-connection hammering the tail. **So the tally
is fed with no walking, no pod, no loan: whatever makes the watch's initiator sample the air
during the sensor's tail (+10…+25 s) or its minute calls produces collapsed links.** Tonight
that was our STOCK re-arm (2 s after the close) plus scan-while-pending (the controller
listening continuously); the ride-only sitting run earlier (no request, no scan of ours) went
60 min with the count frozen at 3; walking supplies the same sampling through the daemon's
scan-parameter churn. The threshold of 5 is now seen twice. Every arm position in the RSSI
survey sat at or below the gate (see the daemon's readings above), so once the gate is up no
wrist position reads.

**Fix levers this instance sharpens (none built beyond 172):** (a) never re-arm our request
into the tail — the re-arm knob's `delay30`/`lateArm` modes (168) exist for exactly this, and
`lateArm` (arm ~30 s before the next burst) avoids the tail AND the minute calls; (b) keep
scan-while-pending OFF (it is the default; tonight's survey had it ON); (c) ride-only still
leaves Dexcom's re-subscribe (+12 s) to feed the tally at the initiator's Low duty — slower,
not zero; (d) detect-and-tell.

**Failsafe, RULED 09-05 night (Jeremy), not built:** a message on the WATCH for the corner
cases — two missed windows with the app awake and the sensor known to be calling — telling
the wearer to turn **the watch's** Bluetooth off and on (watch Settings → Bluetooth). It must
say WATCH explicitly: most users will otherwise assume the phone, and the phone's Bluetooth
does nothing for this. Some of today's instances were test artifacts (stock re-arm and
scan-while-pending switched on for a survey; cold-start joins after installs and a reboot),
which is exactly why the failsafe has to exist: the corner cases will not all be foreseen.

**Candidate practice, to debate (Jeremy, 09-05 night): toggle the WATCH's Bluetooth right
after the loan is established**, so a walk starts with the daemon's tally reset. What it
does: removes the six-hour carry-over (the afternoon walk began with the count already at 3).
What it does not do: stop the count rising during the walk (0→5 in 12 min in the worst
configuration; unmeasured under ride-only while walking). Cost: drops the pod, sensor and
phone links (all recover) and is a manual ritual in the watch's Settings — last resort, not
best practice. Unknown: whether a toggle zeroes the count like the reboot did or only lowers
the threshold state — measure with toggle → sysdiagnose → count before weighing it.

**Remaining discriminator (not built):** "keepalive only" — our G7 client fully off (no
adoption, no connection-event registration, no scan) while the app is held awake, phone
away, ≥90 min. Mute → being awake beside Dexcom's bond is enough and the fix is not in our
radio code; clean → the standing connection-event registration is the ingredient.

## 3f. BASE-CASE LOAN WALK, NO WEDGE — 09-06 00:15→00:53 (build 172) — with the 01:28 sysdiagnose

Settings (watch log): ride-only ON (recycled 00:04:22), scan-while-pending OFF, re-arm stock,
pod radio `slots` (set 00:09:15). Phone BT off and watch Wi-Fi off after the first read; the
phone came back ~00:53:30. Watch BT had been toggled at 23:38 (count presumed zeroed — the
sysdiagnose taken before the loan ended will say).

**Result (FACT):** loan e304, 39 min, 9 cycles. Every window read on the wrist: 00:16 (join),
00:21, 00:26 (join), 00:31, 00:36 (join), 00:41 all `HIT`; the watch log ends 00:45:23, and the
phone's checkpoint cadence (#8 3.8 min, #9 6.2 min, last at 00:52:5x) shows the watch dosing
every window through 00:51. Zero `MISS`. Reclaim VERIFIED +5 s; loan residual +0.10 U, every
window verdict within ±0.05. Jeremy: "I couldn't reproduce the wedge."

**Contrast with 20:42 (§3c), which DID wedge under the same watch switches** (the 20:52 MISS
line reads `scanWhilePending=false rearm=stock ride=true`): the differences are the pod policy
(quietGate → slots, only half-applied — next paragraph), the starting count (3 at 20:42, from
the day; tonight presumably 0 after the 23:38 toggle — UNVERIFIED until the sysdiagnose), and
whatever the walk itself was (duration/route not yet reported).

**Slots gap found in the log (FACT, mechanism read from the code):** the hold alternated.
Refresh reclaims were deferred 70 s at 00:21, 00:31, 00:41 (`DEFERRED pod reclaim — air
closed (slots)`, released +70.9/71.1/71.0 s). At 00:26:42 and 00:36:43 the pod went on the air
at +0.05 s (`no reclaim (pump data 222s fresh)` → dose → `E4: reclaim starting`, pod scan
00:26:42.155, dose, release 00:27:03) — inside the sensor's tail, with Dexcom's link still up
until +9 s. Why: the 70 s hold pushes the refresh to +74 s, so at the next read the pump data
is ~226 s old, under the 4-min refresh threshold (`WatchLoopManager.swift:1505`); the cycle
skips the refresh and the ENACT path calls `reclaimPodForDose` directly
(`PodLoanWatchController.swift:1541`), which passes through no quiet/slot gate. Only the
refresh path runs `deferPodRadioWhileG7AcquisitionResolves`. Under quietGate the refresh ran
every cycle (pump age ~290 s), so the gate applied every cycle and the gap was invisible.
Fix (NOT BUILT, Jeremy's call): route the enact reclaim through `afterG7QuietWindow` under
`slots` (the manual bolus already does, `WatchLoopManager.swift:3158`).

**What it argues (INFERENCE):** four ungated pod contentions at +0 s plus Dexcom's re-subscribes
into the tail (00:21: 10 requests from the watch's address over 21:41→22:07 after the read
landed at 21:43 and the link dropped at 21:51) did not produce a wedge in 39 min. If the
sysdiagnose shows the count stayed low through those, the pod is not sufficient and the
tail re-subscribe alone is a slow feeder — consistent with the 60-min frozen count in §3a.

**Air (sniffer, laptop carried part of the time so partly deaf):** minute calls with requests
at 00:34 (×4), 00:38 (×3), 00:40 (×1), 00:49 (×3) — under ride-only these are the shared
request (Dexcom's) re-issued by the daemon, refused by the sensor. 00:53:39: a request from a
fresh address at the +120 s minute call, and the phone read the sensor at 00:53:41 (phone BT
back ~00:53:30) — the phone accepted at a minute call again (second observation, cf. 15:50:39).

**Watch sysdiagnose taken 01:28:05 (bluetoothd log 23:20→01:28) — the answers (FACT unless marked):**

- **The 23:38 watch-BT toggle zeroed the tally.** First query after it, 00:13:41: `count 0`, and the
  disconnection history held one entry (that moment's 719). The five 23:02→23:13 collapses were
  well inside the 5.8-h window and are gone. A watch BT off/on resets the count; a reboot did the
  same on 09-05 21:08.
- **Count series (sensor B484E4A3):** 0 at 00:13:41 · 0 at 00:21:51 · **1 at 00:21:55** · **2 at
  00:26:56** · **3 at 00:27:07** · 3 at every query from 00:31:50 through 01:26:53 (twelve
  queries, an hour, count frozen). Threshold state `0 → 0` at every query; every accept-list add
  carried `minRSSI=-100`. No gate, no wedge — consistent with 8/8 reads.
- **All three counted collapses are reason 762 in the sensor's tail, each ~4 s after Dexcom's
  watch app re-subscribed** (`com.dexcom.g7app.watchkitapp` `CBMsgIdConnectPeripheral` 35–50 ms
  after every 719 close: 00:21:51.548, 00:26:52.045, 00:31:50.547, …). 00:21:51.5 close → 762 at
  00:21:55.39; 00:26:52.0 close → 762 at 00:26:56.18 and again 00:27:07.46 (the retry).
  The daemon's text: "Outgoing LE Connection complete … status 0" then "_GATT_LE_DisconnectedCB
  … STATUS 762", "was successful but already disconnected", "Connection failed to device,
  Retrying", `encrypted:0`.
- **762 decoded (INFERENCE, strong):** the daemon's reason = 700 + HCI error code — 719 = 0x13
  Remote User Terminated (every normal close), 722 = 0x16 Terminated by Local Host (every pod
  release we initiate), 702 = 0x02 Unknown Connection Identifier (after a cancel). So 762 = 0x3E
  **"Connection Failed to be Established"**: the sensor answered the CONNECT_IND at the link
  layer and then went silent (or was not heard back) before the link was up. That is precisely a
  signal-quality outcome, which is why Apple's tally is named
  `getNumDisconnectionsBySignalQuality` and why its remedy is an RSSI floor.
- **The pod is not necessary:** at 00:21:55 the pod was off the air (reclaim deferred to 00:22:53).
  At 00:26:56/00:27:07 the pod link was up/just closed (00:26:42→00:27:00, the ungated dose
  reclaim). At 00:36 and 00:46 the pod was on the air at +0 s the same way and nothing counted.
- **Nothing of ours stood on the bond.** Our session (`…LoopWatch-central-797-178`) sent
  `CBMsgIdConnectPeripheral` at every burst (00:21:42.357, 00:26:41.509, 00:31:39.652, …) — that
  is the ride-only JOIN, a connect on a link already up, satisfied instantly, gone with the close.
  After each close we only re-register for connection events (00:21:53.6, 00:26:54.1, …). Every
  accept-list add for the sensor was Dexcom's re-subscribe.
- **Unanswered CONNECT_INDs at the minute calls do not count.** The sniffer saw the watch request
  at 00:34 (×4), 00:38 (×3), 00:40, 00:49 (×3); the daemon has no HCI outcome at any of them.
  The chip keeps initiating silently; only a link that the sensor answers and then loses reaches
  the host as a 762.
- **What differed in 00:21→00:27 vs 00:31→01:27 (OPEN — two candidates, one question for Jeremy):**
  (a) *arm swinging* — RF at establishment is exactly what 0x3E measures; if the swinging was
  00:20→00:28, this is it. (b) *the phone had just left* — the sensor's post-read advertising ran
  29 s at 00:21 (sniffer healthy, 245 packets) but ~7 s from 00:31 on, i.e. it stopped looking
  for a second central; a long tail gives Dexcom's +12 s re-subscribe something to connect to.
  Jeremy's walk timing decides which; the 20:47 pair (walking, phone gone 90 min) argues (a).

## 3g. MORNING LOAN WALK — 09-06 08:29→10:27 (build 172): 15 hits, then a 30-min WEDGE — with the 09:26 and 10:55 sysdiagnoses

Loan e305, 118 min, 41 cycles, 10.45 U (boluses 3.70 @08:50:02, 1.45 @09:01:31, 1.00 @09:04:30,
0.70 @09:07:55 (held 90 s by `slots` across the 09:06:41 burst), 1.65 @09:09:31, then 0.10–0.50 U
09:12→09:21). Phone away 08:32→09:25 and 09:32→10:27. Sniffer: laptop left behind 09:40→10:27
(1–2 packets/min) — no air for the mute.

**Windows (FACT):** HIT 08:31→09:41 (15 straight). **MISS 09:46, 09:51, 09:56, 10:01, 10:06** —
direct reads 09:41:41 → 10:11:42, a 30-min drought (glance `bgAge=1592s` at 10:08, `CYCLE VERDICT
… lastCompletedAge=1799s` at 10:11:47; no pod contact 09:44→10:11 because no glucose). Healed
on its own at 10:11 (no toggle, no recycle; join at 10:11:42.287, backfill 6/7). Then HIT 10:11,
10:16, 10:21, 10:26. Jeremy's impression was "G7 solid the whole time"; the log says otherwise.

**Pod policy was `off` from 09:08:44** (four taps on the cycler: off → quietGate → slots → off).
So the mute happened with no pod gating and no quiet bracket; the boluses 09:09→09:21 and every
dose reclaim went on the air at +0 s. Whether the tally reached 5, and from what, is the
question for the 10:27 sysdiagnose.

**The yellow (08:38, FACT):** not `slots` timing as such. The 08:36:41 deferral fired 94.5 s late
because the app was suspended (`runtime GAP 51s — app was NOT executing`); the pod handshake then
failed once (EAP AKA challenge, pod dropped after 7 s), reconnected, and the temp-basal command at
08:38:31 got no answer before the +12 s release → `enact FAILED incorrectResponse`,
`lastCompletedAge=427s`; the next cycle completed at 08:41:47 (`601s`). Four app suspensions of
50–92 s during the loan (08:38, 08:43, 09:05, 09:19).

**09:26 sysdiagnose (bluetoothd 07:30→09:27) + the walk-1 air, laptop carried (FACT):**

| window | sensor advertising after the burst | watch CONNECT_INDs | count |
|---|---|---|---|
| 08:31 (phone still near) | 7 s | 2 | 0 |
| **08:36** (phone gone ~4 min) | **29 s** (36:39.8→37:08.4) | **17** | **1** — 762 at 08:36:56.9, 4.5 s after Dexcom's re-subscribe (08:36:52.444), pod OFF the air (deferred) |
| **08:41** | **29 s** (41:39.8→42:08.9) | **23** | **2** — 762 at 08:41:55.4, 4.4 s after the re-subscribe (08:41:50.941), pod link UP (ungated dose reclaim) |
| 08:46 → 09:26 (nine windows, walking until ~09:08, then the bolus barrage under pod=off) | 7–8 s each; minute calls from 08:47 on | 1 at each burst, 4–8 at minute calls (unanswered) | 2, unchanged through 09:26:57 |

The count at 07:56:54 was 0: last night's three 762s (00:21→00:27) had aged out of the 5.8-h
window (the history still lists them). No gate change; every sensor add `minRSSI=-100`.

**THE FEEDER, ON THE AIR (FACT, two sessions):** in the first ~10 minutes after the phone leaves,
the sensor advertises ~29 s after each read instead of ~7 s and makes no minute calls — it is
still looking for its second central. Dexcom's watch app re-subscribes 40 ms after every close;
the chip fires 16–23 CONNECT_INDs into that long tail; the sensor ignores almost all of them and
one registers as a link-layer connection that fails to establish (762 = 0x3E) — one count per
long-tail window, occasionally two (the 00:27:07 retry). Once the sensor switches to
phone-absent mode (short tails + minute calls) the re-subscribe finds nothing to connect to and
the minute-call CONNECT_INDs go unanswered and uncounted. Same shape both nights: last night
00:21/00:26 (phone left ~00:18), this morning 08:36/08:41 (phone left ~08:32); nothing after,
walking or sitting, pod gated or not, boluses or not.

**So a phone departure costs 2–3 counts, and the window is 5.8 h.** Last night: toggle at 23:38
(0), one departure (+3), no wedge. This morning: 0 at 07:56 by rollover, departure 1 at 08:32
(→2), home 09:25→09:32, departure 2 (→ predicted 4–5) → wedge from 09:46. Yesterday 20:47's
pair (phone gone 90 min) does not fit this shape and stays attributed to walking RF; both feed
the same counter.

**PREDICTION for the 10:27 sysdiagnose, written before reading it:** count 2 at 09:31 → 3 at
~09:36:5x → 4 at ~09:41:5x → 5 by 09:46:41 (a retry pair somewhere), `updateLeConnectionRSSIThresholdState 0→1`,
sensor re-added with `minRSSI=-70`, MISS from 09:46; then something at ~10:11 that let the join
happen (state 1→0, or a burst heard above −70).

**Corollary (INFERENCE, testable):** Dexcom's app alone accrues the same counts — the request is
theirs and the daemon's tally is per device. The control is now well-defined and cheap: our app
quit, two phone departures inside 6 h, read the tally. This is a mechanism prediction, not a
presumption that D2W is broken.

**10:55 watch sysdiagnose (bluetoothd 09:00→10:57) — THE PREDICTION HELD (FACT):**

| time | count | event |
|---|---|---|
| 09:01:50 → 09:31:51 | 2 | seven windows incl. the whole bolus barrage under pod=off; phone back 09:25→09:32 |
| 09:37:05.8 | **3** | 762, 11.5 s after the 09:36:54 close (first window after the phone left ~09:32) |
| 09:41:57.0 | **4** | 762, 4.2 s after the 09:41:52 close |
| 09:42:07.7 | **5** | 762 on the retry → `updateLeConnectionRSSIThresholdState 0 → 1` → sensor re-added with **`minRSSI=-70`** |
| 09:42:08 → 10:11:40 | 5 | NO HCI event for the sensor at all: five bursts (09:46…10:06) never heard above −70. Dexcom's app re-issued its connect at 09:53:07 and 10:01:22 — coalesced into the pending entry, no new add, the −70 stayed |
| 10:11:41.7 | 5 | a burst heard at ≥ −70 → connected → read → close 10:11:51 → Dexcom re-subscribes → add at **−100** ("requested in connectOptions") although state is still 1 (`from 1 to 1`) |
| 10:16 → 10:56 | 5 | every add −100, reads normal, state 1 |

**How the gate actually acts (FACT from the lines):** the −70 floor is written by the daemon's own
RETRY path after a 762 when the state is 1 (09:42:07: "Retrying" → options `minRSSI=-70`). An
app-initiated connect writes the app's requested floor (Dexcom asks −100; our join asks 0). So
the wedge = a −70 entry parked in the controller until something replaces it, and only a
successful connection lets an app replace it. That is why it self-heals on one strong burst
(10:11:41, 29 min in) and why a BT toggle/reboot fixes it at once (daemon restart: state and
count gone — no `1 → 0` transition exists in any of the six captures). Consequence: **state 1
and count 5 persist ~5.8 h after the last 762**; the next 762 retry in that time re-arms −70
immediately — one phone departure this afternoon before ~14:30 wedges on its first long-tail
window.

**The three floors (FACT from all six captures):** −100 is what Dexcom's app REQUESTS on every
connect ("requested in connectOptions"); 0 is our app requesting nothing; −70 is the daemon's own
penalty, written only by its retry-after-failure path once the count is 5 (the same retry writes
−100 under 5). Only two events write the chip's entry: a fresh app request when nothing is
pending (app's floor) and a daemon retry (judgment floor). A request while one is pending writes
nothing — Dexcom's two mid-wedge re-requests and every one of our stock-mode requests two
seconds behind Dexcom's changed nothing. So nothing can overwrite a parked −70 except a
completed connection followed by Dexcom's fresh request. Not a lever for us.

**Correction on minute calls:** in the stock-mode flood the fifth 762 (23:13:40) came at the
+120 s minute call, not in a tail — with our stock re-arm + scan-while-pending scanning at that
moment. Under ride-only, four minute calls with CONNECT_INDs counted nothing. Minute calls CAN
count when our scan is up; that contribution is gone in the base case.

**Placement (Jeremy, 09-06):** the back of the upper arm is the G7's approved site, so the
tricep/wrist geometry is the standard D2W geometry — the "abdomen users heal faster" reconciliation
is withdrawn. If D2W alone accrues 2–3 per departure, ordinary users with two departures in 6 h
get the same 30-min gap; either that goes unnoticed or our presence (keepalive = the only named
candidate) is necessary. The sitting control (§4) decides; held at ~even odds.

**BANKED, not pursued (Jeremy 09-06: "a distraction for now"):** the dead-man ladder was ARMED at
08:29:26 (20/40 min timeSensitive rungs, OS-scheduled notifications) and NO rung reached the
wrist during the 09:41→10:11 drought (`lastCompletedAge=1799s`). The rungs are re-armed on every
completed loop, so either the last re-arm at 09:41:47 did not schedule, or delivery was
suppressed. Needs its own look before the failsafe message work.

**The 3.70 U bolus (08:50:02→08:52:30) crossed the 08:51:41 burst with the pod link DOWN**: the
link releases 12 s after the command (08:50:21) and the pod delivers on its own. A bolus does
not hold the radio across the grid; only a command within ~12 s of the burst does.

## 3h. "D2W-ALONE" SITTING CONTROL — 09-06 11:21→12:34 — CONTAMINATED, but two findings

Recipe: watch-BT toggle (daemon restart ~11:21:42, count 0), our app force-quit (unregistered
11:39:45), phone BT off 11:46, on 11:58, off 12:09, watch sysdiagnose 12:34. Sniffer beside him.

**Contamination (FACT):** watchOS relaunched our app in the background at 11:45:24 (new pid 530,
`running-active-NotVisible` → suspended a second later). On that launch the un-adopted G7 manager
did what stock does: RetrieveConnectedPeripherals, RegisterForConnectionEvents, and a SCAN that
stayed registered 11:45:24→12:06:43 (`canScanNow … allowed:1` ×842; refused "cannot scan in
background" only 13×). It issued a real ConnectPeripheral at 12:02:32, took the 12:06:42 link
itself (discover/notify at 12:06:43), then at 12:09:21 cancelled, re-registered and scanned again.
So all three 762s happened with our scan or request live. NOT a D2W-alone arm. **Relauncher identified
(system log, FACT): WatchConnectivity.** 11:45:23.432 `wcd`: the phone's Loop app pushed an
ApplicationContext (528 B) → `dasd` scheduled
`com.apple.watchconnectivity.com.StockSportMode.Loop.LoopWatch`, launch reason
`wkpendingdata` → Carousel bootstrapped the app `background-utility` with
`CSLHandleBackgroundWCSessionAction`. Not the complication (his face carries Dexcom's), not
CoreBluetooth restoration (the daemon tracks only Dexcom's app for that), not workout recovery
(the keepalive had ended 10:27:39). Our background-task handler logs via os_log, so the launch is
invisible in our own file. Any WC send from the phone app — application context, dormant grant,
snapshot request — relaunches the watch app whenever the phone is reachable.

**Counts anyway (FACT):** 0 (11:21:58) → 1 (11:46:55, 762) → 2 (11:51:53, 762) → 2 through the
phone-back phase and 12:11 (a 28-s tail with 27 CONNECT_INDs, no 762) → 3 (12:16:56, 762) → 3 at
12:31:50. No gate, every add −100. Two departures = +2 and +1. Air: 11:46 27 s/11 req, 11:51
~19 s (sniffer weak), 11:56 9 s + minute call; 12:11 28 s/27 req, 12:16 28 s/14 req, 12:21 63 s/0 req.

**The 12:21 miss was NOT the gate (FACT):** no −70 anywhere; no HCI event for the sensor at 12:21.
The watch was cycling system sleep (`PowerManagement event: systemWillSleep` ×6 and
`kIOMessageSystemHasPoweredOn` ×5 inside 12:21, `enableSystemWakesForUpdate returned (null)`), and
the pending connection did not wake it for that burst. Every other connect in this arm carried
`wakeEvent:1` (the chip woke the system) and came 1.8–8.8 s into the burst, with 1.5-s sessions at
12:26/12:31 — versus +0.1–0.5 s and 10–12-s sessions under the loan's keepalive. So without our
keepalive the watch sleeps between bursts and can miss one outright; the keepalive is a benefit
on that axis, not a cost.

**Clean control recipe:** force-quit the PHONE Loop app first (it is the WC sender; the pod keeps
its scheduled basal on its own — bench pod), then force-quit the watch app, then the three
phases; confirm afterward that the daemon log has no `StockSportMode` session registration.

## 3i. THIRD CONTROL, 09-06 13:16→14:27 — D2W ACCRUES ALONE, BUT THE −70 NEEDS A LATE FAILURE

Recipe: watch-BT toggle (daemon restart 13:16), phone off 13:17, on 13:35, off 13:44, on ~14:08,
off ~14:18, watch sysdiagnose 14:27. Phone Loop app force-quit; watch app force-quit — **but
relaunched again at 13:39:47 by WatchConnectivity** (four minutes after the phone came back;
queued sends), scanned 13:39→14:08, connected itself 13:47/14:08/14:16. Not near the sniffer.

**Count series (FACT):** 3 → **0 at 13:16:52 (toggle)** → 1 (13:16:55) → 2 (13:17:05) [the toggle's
own transition: the sensor lost the watch and went looking] → 3 (13:21:56, departure 1) → 3
through the phone-back phase → 4 (13:46:57) → **5 (13:51:59, state 0→1)** → 6 (14:21:53) →
7 (14:26:57). **Every accept-list write −100, including the three retries at state 1. No wedge;
every burst 13:56→14:26 connected.** So the counter accrues with or without our app at the same
~2 per departure (plus 2 for the toggle itself), and reaching 5 is not sufficient for the gate.

**What decides −70 vs −100 at state 1 (FACT, 6 of 6):** the retry's floor is −70 only when the
failure falls AFTER the daemon's 6-s fast connection scan has expired
(`shouldEnableFastConnectionScan:0 … reached:1`, scan state Low): 20:47:06 (+15.6 s after
Dexcom's subscribe), 23:13:40 (+108.6 s, a minute call), 09:42:07 (+14.8 s). Retries at state 1
inside the fast scan wrote −100: 13:51:59 (+5.6 s), 14:21:53 (+4.1 s), 14:26:57 (+4.0 s). Reads
as a power policy: in low-duty scanning, a device with a bad history is only worth strong bursts.

**Where our app comes in (INFERENCE, the best fit):** late failures (after +6 s) have occurred only
with our app running — 00:27:07, 09:37:05, 09:42:07, 20:47:06, 23:13:40 — and never in the clean
arm's seven retries (all +3.5→5.6 s). Two candidate mechanisms, both ours: (a) the keepalive keeps
the watch awake, so the low-duty scan keeps attempting through the 29-s tail (the clean arm's
watch cycled system sleep between bursts); (b) our ride-only re-registration for connection
events ~2 s after every close churns the pending request. Either way the counter is Dexcom's and
the sensor's; the −70 needs a failure the sleeping D2W watch does not make.

**The awake mechanism, in the daemon's words (FACT):** during the loan arms the watch logged ZERO
system-sleep events (09:30→09:45, 00:20→00:30 — the keepalive holds it). In the clean arm it
slept 5× per minute; at 13:52:03, four seconds after the 13:51:59 retry, `LeObserver Power :
We're going to sleep!`, then asleep 13:52:13→13:52:37 — the rest of the 29-s tail. A sleeping
watch makes no low-duty attempts, so no late failure, so no −70. That is why D2W alone accrues
counts but never wedges here, and why every wedge had our keepalive under it.

**The pod is NOT exonerated for late failures (correction):** it was cleared for the COUNT (early
failures happen without it), but the late failures line up with the pod on the air in the tail:
pod-in-tail long-tail windows 00:26 ✓, 08:41 ✗, 09:36 ✓, 09:41 ✓, 20:46 ✓ (4/5 late failures);
awake windows with the pod deferred 00:21 ✗, 08:36 ✗ (0/2); asleep windows 0/6. The pod's own
release does not re-trigger the connecting list (00:27:00 "skipping processConnectingList"), so if
the pod matters it is as radio contention during the late attempts, on top of the awake state.
23:13:40 (late, no pod, our stock scan running, app foreground) says awake-plus-our-radio-activity
is enough without the pod.

**Discriminating tests (no build needed for the first two):**
- **A — awake, no pod:** E1 soak, keepalive on, ride-only, no loan, two or three departures. Late
  failures and a −70 → awake suffices; pod cleared.
- **P — awake + pod in every tail:** loan with pod policy `off`, same departures. Late failures
  only here and not in A → the pod's radio time in the tail is required on top of awake.
- Registration deferral (a build) is third; 00:21/08:36 had the re-registration and no late
  failure, so it is the weakest candidate.
## 3j. ARM A — awake (keepalive soak), ride-only, NO loan, NO pod: WEDGED on the first departure

09-06 15:01 E1 soak started (count 7 / state 1 carried from §3i, deliberately not toggled), phone
off ~15:02, sitting by the sniffer. Our app was un-adopted after the morning's churn (diagnostic
"sensor none"; Recycle tapped ~15:17). Air: 15:06 taken in 5 s; **15:11 a 25-s tail with no request
seen; 15:16 62 s of advertising and nobody connected** — the parked-entry signature. Jeremy at
15:23: "Dexcom is wedged." Prediction for the sysdiagnose: a 762 late in the 15:11 tail (after the
fast scan), retry written at −70 (state 1), 15:16 and 15:21 with no HCI event.

**15:21 sysdiagnose (FACT):** count 7 → 8 at 15:06:57 (762 at +4.6 s after Dexcom's 15:06:53
re-subscribe, written −100) → **9 at 15:07:03.7 (762 at +10.6 s, after the fast scan) → written
−70**. No HCI event for the sensor from 15:08 to 15:23: 15:11, 15:16, 15:21 unheard. Our app's
join set "minimum RSSI level 0" on the device at 15:06:44 during the link; our app was awake on
the keepalive (zero system-sleep events 15:00→15:22). The prediction held line for line.

**Touch-heal (Jeremy, 15:41):** watch held on the sensor across the 15:41 burst → connected → D2W
back to direct. A heal, as predicted, not a reset (count 9, state 1 remain).

**What our app was doing in that tail (FACT):** at the 15:06:53 close the un-adopted manager
cancelled, re-registered and started a SCAN (15:06:53.112, again 15:06:55.178); the late 762
came at 15:07:03.7 with that scan up. So every late failure on record had our radio activity in
the tail alongside the awake watch: a scan (23:13:40, 15:07:03) or the pod link (00:27:07,
09:37:05, 09:42:07, 20:47:06). The two awake windows with neither (00:21, 08:36: registration
only, pod deferred) had no late failure; the six sleeping windows had none. Best current model:
**awake + our own scan or connection on the chip during the sensor's tail → a late attempt → the
−70 at state 1.** Registration alone has not produced one.

**Verdict:** the pod and the loan are not needed. An awake watch with our app running is enough
to turn a state-1 count into the −70. Remaining split: awake *per se* (any workout would do it —
then D2W runners are exposed) versus our app's radio activity while awake (registration, scan,
recycle). Cheapest discriminator, no build: **Arm W — both our apps quit, Apple's Workout app
running an Outdoor Walk (keeps the watch awake), three departures.** A wedge there is a pure
D2W-plus-workout wedge; none there confirms it is our scan/pod activity in the tail — and then
the fixes are ours: (1) no acquisition scan within ~40 s after a sensor close; (2) hold the pod
off the air for the whole tail (the `slots` dose-reclaim gap, hold ≥40 s); (3) registration may
stay. Plus the toggle-before-outing ritual and the touch-heal for the field.

**Next-build note (Jeremy, 09-06 16:20):** put the actual BG value and its reading time on the
diagnostic screen beside the connection state, so a missed window can be told from Dexcom's app
holding the previous value across one grid point.

## 3k. ARM A′ — adopted, ride-only, keepalive, no loan/pod, 16:03→16:31: WEDGED AGAIN, and the watch log names the activity

Recycle 15:59, adopted and reading at 16:01 (join). Phone off 16:03, arm kept straight. Keepalive
soak running (15:59:28 →). Judgment 1 carried (count 9).

**Watch log (FACT):** 16:06:42 "Sensor connected" (join) but NO reading delivered; 16:06:51 the
sensor closed → stock G7SensorKit: `Sensor disconnected: suspectedEndOfSession=true` →
**`Forgetting existing sensor and starting scan for new sensor`** → our scan was up through the
16:06 tail (late request seen at 16:06:59) and the 16:11 tail (`ad DISCOVERED (trigger c)` at
16:11:40 → our own connect → read 123 → close 16:11:53 → 11 requests 16:11:54→16:12:05 on the
air) until `adopted from the air — scan stopped` at 16:16:40. Then MISS 16:16, MISS 16:21 (arm
straight), a read at 16:26:42 (arm), touch-heal across 16:31. Phone log: phone absent 16:03→16:28.

**16:28 sysdiagnose (FACT):** count 10 (15:51) → 11 at 16:06:57 (+5.7 s, −100) → **12 at 16:07:03
(+11.5 s, after the fast scan) → −70** → 13 at 16:11:57 (+4 s, −100) → **14 at 16:12:04 (+11 s)
→ −70** → 16:16 and 16:21 with no HCI event → 16:26:42 a connection with the entry still at −70
(arm position) → close → Dexcom's re-subscribe rewrote −100. The two late failures sit exactly
where our scan was up. The 15:41 touch-heal also cost one early 762 (count 10) before it
connected. Count 14, state 1 at 16:29; the last entries age out ~22:00.

**A heal lever we did not know we had (INFERENCE, strong):** at 16:11:40.79 our scan heard the
sensor at −79, our session called connect, and the link formed 0.8 s later with the entry still
parked at −70 and no accept-list write in between. The chip's own initiator would not have taken
a −79 burst (16:16 and 16:21 went unheard at that level). A direct connect to a peripheral just
seen in an active scan is not subject to the parked floor. So an in-app heal exists: on a
detected wedge, scan across ONE burst (T−5 s → T+5 s), connect directly, read, stop — and never
let that scan run into the tail, which is what caused the write in the first place.

**So A′ did not test "registration only" either.** The stock forget-and-scan fired on a
disconnect-without-read — the #104 signal problem (a bare disconnect read as end-of-session) —
and put our scan into two consecutive tails. Every wedge on record now has our scan or our pod
link in the tail: 20:47 pod · 23:13 scan · 09:42 pod · 15:07 scan · 16:1x scan.

**The fix list, unchanged and sharper:** (1) on the watch, never forget-and-scan on a
disconnect-without-read under ride-only (keep the identity, wait for Dexcom's next link);
(2) no acquisition scan within ~40 s of a sensor close; (3) pod off the air for the whole tail
(the `slots` dose-reclaim gap). Registration-only stays untested and least likely.

## 5. THE MECHANISM, COMPLETE — and the preregistered build (written 09-06 17:10, before building)

### 5a. Facts (read from bluetoothd's own log, six watch captures, 09-05 21:15 → 09-06 16:28)
1. bluetoothd keeps one accept-list entry per device, shared by every app that wants it, and a
   per-device tally `getNumDisconnectionsBySignalQuality` over a 20 864-s (5.8-h) window.
2. Only reason 762 counts: 700 + HCI 0x3E "connection failed to be established" — the chip sent
   a CONNECT_IND, the link did not come up. Normal closes (719) and our own releases (722) do not.
3. 762s happen when a connect request is pending while the sensor is in its LONG tail: for ~10
   min after the phone leaves, the sensor advertises ~29 s after each read (7 s otherwise, 63 s
   when nobody takes the burst) and makes no minute calls. Dexcom's watch app re-subscribes
   40 ms after every close; the daemon runs a 6-s full-duty "fast connection scan"; the chip fires
   16–27 CONNECT_INDs into the tail; one or two book as 762. ≈ 2 per departure, +2 for a watch-BT
   toggle (the sensor treats the watch's disappearance the same way). Unanswered CONNECT_INDs at
   minute calls do not count. Accrual is identical with our app quit (0→7 across 13:16→14:27).
4. At count 5 the judgment flips (`updateLeConnectionRSSIThresholdState 0→1`). It has never been
   seen going back to 0; a toggle or reboot restarts the daemon and zeroes everything.
5. The −70 is written only by the daemon's RETRY after a failure, only at state 1, and only when
   that failure came AFTER the 6-s fast scan expired (6/6: −70 at +15.6, +108.6, +14.8, +11.5,
   +11 s; −100 at +4.0, +4.1, +5.6 s). An app's own request writes the app's floor (Dexcom −100).
   A request while one is pending writes nothing. The −70 entry stays until a burst ≥ −70 (or a
   direct connect from a scan hit — 16:11:41 at −79) forms a link and Dexcom's next request
   rewrites −100. Count and judgment survive the heal; the next late failure re-arms −70 at once.
6. Late failures (after +6 s) have occurred only with our app running, and in every case with
   our scan or our pod link on the chip during the tail: 20:47 pod · 23:13 scan · 00:27 pod ·
   09:37 pod · 09:42 pod · 15:07 scan · 16:07 scan · 16:12 scan. Awake windows with only the
   registration (00:21, 08:36): none. Sleeping D2W-alone windows (13:2x→14:26): none — the watch
   goes to sleep 4 s after the retry and stays asleep through the tail.
7. Our scans in those tails came from stock G7SensorKit's forget-and-scan: `G7Sensor.swift:245`
   flags a REMOTE disconnect while `pendingAuth` as `suspectedEndOfSession`, and
   `G7CGMManager.sensorDisconnected` (:358) answers with `scanForNewSensor()` — identity wiped,
   scan started, two seconds after the close. Under ride-only a join that the sensor closes
   before auth completes trips it every time (16:06:51, 15:06:53). Our pod links in those tails
   came from the dose reclaim at +0 s, which the `slots` gate does not cover (§3f).

### 5b. Inferences (labelled)
- The tally is a power policy: in low-duty scanning, don't chase a device with a bad history
  unless it is loud. Strong.
- Awake + our own radio activity in the tail → late attempt → 762 → −70. Correlational (8/8 vs
  0/2 vs 0/6); never tested with a clean awake-and-idle arm because the code itself contaminated
  every attempt. The build is that arm.
- D2W alone does not wedge in practice because the sleeping watch cannot fail late. Consistent
  with the absence of field reports; not proven.

### 5c. What we build (build 173) — two changes, nothing else
1. **No scan under ride-only.** `sensorDisconnected(suspectedEndOfSession:)`: when ride-only is on
   and a sensor is adopted, keep the identity and do not scan (log it). And
   `managerQueue_scanForPeripheral` under ride-only: register for connection events (service
   UUIDs — already how adoption-from-the-air works, 16:16:40) and never call `scanForPeripherals`.
   Net effect: under ride-only our app never scans, adopted or not.
2. **Pod off the air for the whole tail.** Route the enact-path `reclaimPodForDose` through the
   same `afterG7QuietWindow` gate as the refresh (the §3f gap), and make `slots` the default pod
   policy. Net effect: no pod link earlier than +70 s after a read.
Held in reserve, NOT built: the single-burst scan-and-connect heal; detect-and-tell; the failsafe
message. Jeremy: "in theory we shouldn't need it and it may do more harm than good."

### 5d. Preregistered expectations for build 173 (loan or E1, ride-only, slots, three departures,
judgment carried at 1 — no toggle)
- Early 762s still accrue, ~2 per departure (the sensor's and Dexcom's, untouched).
- **No 762 later than 6 s after a re-subscribe in any tail. No −70 write. No wedge.**
- Daemon: no `CBMsgIdScan` from our session; no pod link earlier than +70 s after any read.
- If a late 762 / −70 appears with none of our activity in that tail → awake alone suffices →
  Arm W (our apps quit, Apple Workout running) decides Dexcom's exposure, and our mitigation
  falls back to the toggle ritual + touch-heal + failsafe.
- The ride-only join keeps every window (reads at +0.1–0.5 s as today).

## 3l. RUN 1 on build 173 — ride-only, NO scan of ours, pod policy `off`: WEDGED after one departure

09-06 17:21 loan, phone off 17:27, judgment carried at 1 (count 15). 17:40:48 sysdiagnose.

**Daemon (FACT):** 17:31:43 join (our sess301 connect on Dexcom's link) · **17:31:45.0 our pod
reclaim: scan-adopt SCAN on the pod service 00004024 + connect; pod link up 17:31:45.6** ·
17:31:53.4 sensor close (719) · Dexcom re-subscribe · 17:31:55.6 our registration (no scan of
ours for the sensor anywhere in the capture — build 173 held) · **762 at 17:31:57.4 (+4 s,
−100) · 762 at 17:32:04.7 (+11.2 s, after the fast scan) → −70** · pod released 17:32:04.5 ·
17:36 no HCI event (the miss on the wrist) · 17:41:41 connection (touch-heal) → −100 rewrite.
Count 15 → 17. Air: 17:31 tail 29 s with 11 CONNECT_INDs 17:31:53→17:32:03; 17:36 25 s, none.

**Verdict:** with our G7 scan gone, the pod reclaim alone in the tail — its own scan on the pod
service plus the link, +1 s to +19 s after the read — still produced the late failure and the
−70. The pod gating is earned. Note the reclaim IS a scan on the chip: "no scan under ride-only"
removed the G7 scan only. Run 2 = the same recipe with pod policy `slots` (build 173/174 holds
every reclaim, scan included, to +70 s); expectation: no late 762, no −70, no wedge.

## 3m. RUN 2 on build 173 — ride-only, pod `slots`: WEDGED anyway (18:31/18:36) — preregistered before the capture

Phone off 18:00, on ~18:14, off 18:22; wedge noticed at the 18:31 miss, Dexcom confirmed; capture
taken ~18:40 with phone BT on, then touch-heal. Loop was red throughout: on 173 the `slots` hold
sat inside the reclaim closure, so every automatic dose cycle timed out at 25 s ("pod not
reconnected — automatic dose SKIPPED") and ran `releasePodAfterDose` — **at +25 s after the
read, i.e. ~+13 s after the close, in the late zone.** The deferred reclaim still fired at +70 s
(scan-adopt scan + link ~+71→+90 s, outside the tail).

**Written 18:45, before reading the daemon:**
1. The −70 write sits in a long-tail window after the 18:22 departure (18:26 or 18:31), on a 762
   later than +6 s after Dexcom's re-subscribe.
2. No `CBMsgIdScan` for the sensor from our session anywhere (173's no-scan holds).
3. What of ours was on the chip in that tail — ranked: **(a) the skipped-dose path's
   `releasePodAfterDose` at ~+25 s: a pod-session `CBMsgIdCancelPeripheralConnection` / pod
   disconnect in the late zone** (my expectation); (b) the registration at +2 s only — then
   awake + registration suffices and the residual is real; (c) the +70 s pod reclaim inside the
   tail — should not be, the tail ends at +29 s.
4. If (a): 175 (the cycle-level hold) already removes it, since a held cycle never reaches the
   enactor's timeout; the acceptance run of 175 then decides. If (b): Arm W (our apps quit, Apple
   Workout awake) and a build that defers the post-close registration to T−20 s.

**Watch log, read 18:50 (FACT) — the pod WAS in the tail, carried over from the previous cycle:**
on 173 under `slots` the deferred reclaim fires at +70 s and connects the pod, but the enactor
had already timed out at +25 s and run its release BEFORE that connect, so nothing releases
the link afterwards — it stays up through the next read and its whole tail until the next
cycle's timeout-release at +38 s. 18:21:42 read → close 18:21:56 → pod link up throughout →
released 18:22:20; reclaim 18:22:56 → link up → drop/reconnect 18:26:00 → **18:26:45 read →
close 18:26:52 → pod link up through the whole tail → released 18:27:22** → 18:31 unheard.
So run 2 was not a pod-held arm at all; the hold moved the link INTO the next tail. Prediction
3 revised before the capture: the −70 write is in the 18:26 tail with the pod link up at the
close (the 174 `[tail]` line would read "pod link +0.0→+30 s"); our session did join +
registration only, no scan. 175's cycle-level hold releases the pod at ~+95 s (reclaim at +70,
dose, release +12 s), so the next tail is clean — run 3 on 175 is the acceptance arm.

**18:38 sysdiagnose (FACT) — the revised prediction held:** count 19 → **20 at 18:26:57 (762 at
+5 s after the 18:26:52 close, −100) → 21 at 18:27:08 (762 at +16 s, after the fast scan) →
−70**. Pod link (64:00:9C) up 18:26:01 → 18:27:22 — through the read, the close and the whole
tail; 18:31 with no HCI event. Our sensor session (301): join 18:26:44, registration 18:26:55,
nothing else; no `CBMsgIdScan` for the sensor anywhere. The 18:21 tail had the pod link up too
(18:20:57→18:22:20) and no late failure — a 1-in-5 miss like 08:41. Earlier: 18:01:56 and
18:06:56 early 762s (the first departure's long tails). Also visible: the pod's own link drops
(719) every ~3 min with our immediate reconnect (18:16:00, 18:20:57, 18:26:00, 18:31:00) — the
173 tangle kept a link that was never released.

**Run 3 preregistered (build 175, ride-only, `slots`, judgment carried, three departures):**
every `[tail]` line reads CLEAN in the long-tail windows (reclaim at +70 s, release ~+95 s, no
link at the next close); early 762s still accrue; no 762 after +6 s; no −70; no wedge; no
skipped doses and no yellow. A late 762 with a CLEAN tail line is the residual (awake +
registration) and sends us to Arm W.

## 3n. RUN 3 on build 175 — ride-only, `slots` with the cycle-level hold: NO WEDGE — ACCEPTANCE PASSED

Loan 18:51→19:49 (8 cycles in 59 min, every automatic dose enacted — the 173 skips are gone).
Phone off 18:54, on 19:02, off 19:12, on 19:24, off 19:34; judgment carried (count 21).
**Every `[tail]` line CLEAN — eleven windows 18:52→19:47, "nothing of ours on the radio for
40 s".** One window (19:31, phone present) was covered by the phone relay with a direct-G7 gap
— a join that did not happen, not a gate event (the tails either side are clean and 19:36 read
direct with the phone gone). Air where audible: requests only inside the fast scan.

**19:48 sysdiagnose (FACT) — the preregistration held in full:** six 762s, one per long-tail
window, at +4.8, +4.5, +5.0, +4.6, +4.3 and +4.1 s after Dexcom's re-subscribe (18:56:58,
19:01:58, 19:16:53, 19:21:53, 19:36:56, 19:42:00) — every one inside the fast scan, every one
written −100 with the judgment at state 1 the whole hour. **No failure after +6 s. No −70. No
wedge.** Count 22 → 24 → 21 → 23 as old entries aged out and new ones came in. Zero sensor
scans from our session. Eleven CLEAN tail lines on our side, six early failures on the daemon's:
the counter is Dexcom's and the sensor's, the −70 was ours, and 175 removes it.

**Acceptance: PASSED.** Pod held out of the tail (reclaim at +70 s, release ~+95 s), no scan of
ours under ride-only, every dose enacted. Cost: an automatic dose or bolus requested in the
first 70 s after a read waits until +70 s; the hold could be trimmed to 40 s later.

## 6. PORT MANIFEST for next-dev (`SportMode-next-dev`) — by content, not by SHA

Jeremy 2026-09-06: "next dev might be nuanced given that pod comms are different." The port's
G7SensorKit (`SportMode-next-dev`, 44 commits ahead / 28 behind `g7-unproven-drop`) has no
`G7RidePolicy` at all; its watch pod reclaim is its own design. So this is a content port for a
port-line session with bench time, not a cherry-pick.

**G7 side (shared module; port the behaviour into the port's G7BluetoothManager):**
1. Ride-only: while a sensor is adopted, no connect request of ours on the bond; register for
   connection events (service UUIDs) and JOIN Dexcom's link on `.peerConnected` for the adopted
   peripheral (connect() on a link already up completes at once). The join must pass "the link
   is up" from the caller, not read `CBPeripheral.state` (per-app; the 170 loop).
2. Never scan under ride-only, adopted or not — adoption from the air via the connection-event
   registration works (16:16:40). No forget-and-scan on a remote disconnect while auth is
   pending (`G7Sensor.pendingAuth && wasRemoteDisconnect`): keep the identity, wait for the next
   link. Default ON on watchOS only.
3. Census hooks: sensor closed, scan started — for the per-window `[tail]` line.

**Pod side (principle; the port's reclaim mechanics are its own):** nothing of ours on the chip
— no scan, no connection, no cancel — from the sensor's close (+9…+16 s after the read) to the
end of its long tail (~+29 s after the burst). The Caitlin line holds every reclaim to +40 s
after the read (build 177; 70 s in 175/176), and holds the CYCLE, not the reclaim inside the
enactor's 25-s wait (the 173 tangle: a held reclaim inside a timed-out enactor left the link up
through the next tail). Optional: 20 s outside the 15-min window after a phone-reachability
change / loan start / launch (`tailHoldAdaptive`, off by default until one more run).

**Instrument:** the `[tail]` line (40 s after each close: our pod link / scan offsets, late zone
+6→+29 s TOUCHED/clear, phone reachability, transition state) — the pod-isolation instrument.

**Acceptance on the port, preregistered:** ride-only, hold on, three phone departures with the
daemon's judgment carried at 1 (or after a toggle, five early failures first): early 762s only
(+4…+6 s), no failure after +6 s, no −70, no wedge, no skipped doses; sysdiagnose recipe in
memory `sysdiagnose-folder`.

## 3o. ADAPTIVE-HOLD WALK, 09-06 22:08→22:38 (build 177, switch ON from 22:10): no wedge — and the adaptive spec is WITHDRAWN

Loan 21:07→22:57, 22 cycles. Phone present until ~22:08, absent 22:11→22:36 (phone log: no
phone-G7 reads; watch: no relay), back 22:39. Nine windows 22:01→22:46 all HIT; no skipped doses.

**Two errors in the adaptive spec, both visible in the `[tail]` lines:**
1. **Wrong reference frame.** The 20-s steady hold is measured from the READ; the late failures
   are +11…+16 s after the CLOSE, i.e. +23…+28 s after the burst (16:07:03, 18:27:08, 09:42:07,
   17:32:04). With the close at +9…+12 s, a 20-s hold puts the pod link at close+13…+21 s —
   inside the failure zone: 22:12 "pod link +20.5→+37.4 s", 22:17 "+16.3→+35.0", 22:22
   "+20.9→+37.5", 22:27 "+13.7→+31.0", all TOUCHED. The closes also vary more than assumed
   (0.4 s after the read at 22:11, 22:21, 22:37; 15 s at 22:41), which a burst-relative constant
   cannot track. The 40-s hold clears close+24 s in the worst observed case and stays.
2. **Invalid proxy.** `WCSession.isReachable` stayed true from 22:08 through 22:27 (Wi-Fi) while
   the phone's sensor link was gone the whole time, so the app called it "transition over" and
   used the short hold exactly during the long-tail windows. Reachability then flapped
   22:27→22:44 at the edge of range, re-arming transitions at random. The only honest signal
   of the sensor's two-central state would be the phone's own reads, which the watch cannot
   see in real time.

No wedge occurred (state 1 probably still carried; four long-tail windows with the pod link
at close+13…+21 s) — luck or a narrower failure zone than the tail marker assumes; not
evidence of safety. **The switch stays OFF and the adaptive code is withdrawn** (delete in the
next cleanup). Recalibrate the `[tail]` late-zone marker to close+6→+20 s (the tail ends
~+19 s after the close; failures ended by +16).

## 7. THE POD-SIDE DESIGN, FROM THE COMPLETE PICTURE (written 09-06 23:30; to test 09-07)

**What a wedge needs, and which parts are ours.** (1) The judgment at state 1 — five failed
establishments inside 5.8 h. Fed by Dexcom's re-subscribe into the sensor's long tails, ~2 per
phone departure and ~2 per watch-BT toggle; not ours to prevent. Assume state 1 from the second
outing until the next toggle or reboot. (2) A failed establishment AFTER the 6-s fast scan. The
chip only attempts late while the sensor is advertising after close+6 s: the LONG TAIL (to
~close+19 s; only in the ~10 min after the phone leaves) and, in phone-absent mode, the MINUTE
CALLS (3-s spurts at burst+60/120/180/240). (3) Something that makes the attempt fail: in the
tail, our scan or our pod link on the chip (8/8 wedges; 0/2 awake-registration-only; 0/6
asleep). At minute calls, nothing on record under ride-only (4 calls with CONNECT_INDs, no
booking); the one minute-call booking ever (23:13:40) had our stock SCAN running. Whether the
POD on the air across a minute call books a failure is UNTESTED — not part of the root cause
as observed, but not cleared either.

**Design: hold only when the sensor can be advertising after the fast scan.**
- *Two-central windows* (the phone's own read reached the watch as a relay for this window,
  `INGEST src=phone-relay` just before the direct read): the sensor makes 7-s tails and no
  minute calls. Release the pod at close+3 s; no blackouts. Bolus delay ≤ ~12 s, only in the
  first ~12 s after a read (~4 % of the cycle). Evidence: ~10 steady windows with the pod at
  +0 s and no failure (08:46→09:06, 00:31→00:51).
- *Absent/transition windows* (no relay for this window): hold to close+25 s (fallback read+40
  if no close is seen). Minute-call blackouts (110–130, 170–190, 230–250) kept until T1 says
  otherwise; the pre-burst lead trimmed to 290–300 pending T3.
- The relay is the honest sensor-state signal: it proves the phone's Dexcom app connected this
  window. `WCSession.isReachable` is not (§3o). No relay → the safe hold, automatically, which
  is exactly the transition.

**Costs, per 300-s cycle:** phone present ~4 % of the cycle, ≤12 s; phone absent 12 % (the
tail hold) + 27 % (blackouts) = 39 % until T1, 12 % after if T1 is clean.

**Tests (judgment carried at 1, sysdiagnose + watch log each):**
- **T1 — pod at the minute calls.** Departure run, phone away, blackouts OFF (test policy), the
  reclaim at +40…+60 s straddling the +60 call, plus 2–3 manual boluses timed into +115…+125 and
  +175…+185. Prediction: no 762 at any minute call (60/40). Clean → blackouts retired.
- **T2 — two-central short hold at home.** Phone present two hours, relay-gated close+3 s
  release. Prediction: no late failure, tails 7 s in the `[tail]` lines.
- **T3 — composite acceptance.** Three departures under the full design: no late 762, no −70,
  bolus lag read off the `[quiet]` lines.
Build the policy as one switchable `PodRadioPolicy` case (`relayGated`) with the blackout set
as a second switch, so T1/T2/T3 run on one build.

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

## 7a. T1 RESULT — 09-07 11:05→11:38, build 178: pod radio at minute calls counts NOTHING; the departure feeder did not fire (unexplained)

**Setup.** Loan from 11:00:30 (direct G7 at 11:02). Radio Lab: pod `slots`, Minute-call
blackouts OFF, ride-only ON. Phone Bluetooth OFF 11:05:00→11:38:30 with the phone physically
next to the watch (on the Mac's USB); watch Wi-Fi ON. Sensor bursts on the :42 grid. nRF sniffer
in advertising mode on the sensor; a lossy live bluetoothd tap through the phone (see 7b);
watch sysdiagnose pressed 11:42:30. Ten manual boluses timed 1:55/2:55 after reads
(11:08:40, 11:09:45, 11:13:40, 11:14:40, 11:18:40, 11:19:40, ~11:23:50, 11:28:40, 11:29:40,
~11:34:00, 11:34:45) plus the loop's own pod link ~+45 s after every read.

**Preregistered before the archive was read (11:44):** (A) count 2 → 4..5 from the two
long-tail windows, minute-call requests not counted; ≥8 would mean they are. (B) −70 only if
the count reached 5 inside the 11:06 tail. (C) judgment 0→1 only if the count reached 5.

**Result (archive, bluetoothd, 10:50→11:43):**

| what | result |
|---|---|
| tally, every evaluation 10:52→11:41:54 | **count 2, unchanged** (the two morning 708s) |
| judgment | 0 throughout |
| −70 writes | none; every add carried Dexcom's −100 |
| sensor links | 11 of 11 windows connected (11:01…11:41), every close 719, link ages 2–12 s |
| watch `CONNECT_IND`s at minute calls (sniffer) | 13 (11:17, :18, :19, :22, :23, :25, :28, :29, :34, :35, :37, :38, :39), **6 with a pod link up in the same second** (11:18:43, 11:19:44, 11:22:43, 11:28:42, 11:29:43, 11:34:44) — **none counted** |
| long-tail windows after the departure | 11:06 (27-s tail, 7 requests) and 11:11 (29-s tail, 2 requests, last at +28 s) — **no 762 from either** |
| watch reads | every window (Jeremy: loop never changed colour, Dexcom fine) |
| the bolus Jeremy thought had failed (11:18:40) | delivered: watch log "MANUAL BOLUS 0.10 U — enacting" 11:18:45.0, "delivering … done in 4s" 11:18:46.4, phone checkpoint #9 accepted 11:18:46.7; pod connect RSSI −60, handshake 1.58 s, inside the 11:18:42 minute call |

(A) was wrong in the direction that matters: the count did not move at all. The 13
minute-call requests, six of them colliding with pod links, added nothing — **pod radio at
minute calls is harmless to the tally**, which is what T1 was built to test. (B) and (C) held
trivially.

**The unexplained part is the feeder.** Every earlier departure, including yesterday's phone-
and watch-Bluetooth toggles at home with nobody walking anywhere, cost ~2 early 762s inside
the first two long-tail windows (§5a; run 3 on 175 accrued six that way in 45 minutes). Today's
toggle put the sensor into phone-absent mode exactly as before (27–29-s tails, minute calls from
11:17, Dexcom re-subscribing after every close, the controller's requests going into the tails)
and **none of them failed.** No theory is offered for that here; it is the same procedure as run
3 with a different outcome, and the things that differed are listed as candidates to test, not
explanations: build 178 vs 175; the phone on the Mac's USB with two watch-log relay sessions open
through it the whole time; whatever state the sensor was in at 11:05 (it had been in two-central
mode all morning); sampling. Two windows are a small sample of a ~1-per-window event.

**Instrument facts established the same morning (7b):**
- **Reason 708 counts** (supervision timeout of an established link), not only 762: the count
  went 0→1 on a 708 at 08:26:55 and 1→2 on another at 09:26:57, both at home with the phone
  near. §5a's "only 762" is corrected to "762 or 708".
- **The judgment reset to 0 overnight without an evaluation.** State 1 at 23:06 (count ≥ 9);
  the first evaluation of the morning, 08:21:59, printed `from 0 to 0`, so the stored state was
  already 0. Nothing in the log clears it; the store is purged before 23:48, so a daemon restart
  vs the 02:00 charger sleep cycles is undecidable. Practical: a night on the charger clears it.
- **The watch's live log CAN be streamed to the Mac through the phone's USB link**
  (pymobiledevice3: companion proxy → forwarded lockdown → pair → os_trace_relay, each service
  port forwarded through the proxy), no root, no Files — **but bluetoothd arrives for only 8–20 s
  of every 60**, in bursts, regardless of screen, loan or a fresh session; Console.app rides the
  same relay and has the same holes. `log collect --device-udid <watch>` needs root and then
  fails "Device not configured"; the proxy's archive pull streams the whole store at 72 KB/s
  (~1 h) and a size cap yields nothing. **Sysdiagnose stays the record; stream and sniffer are
  taps.**
- **The sniffer catches about one `CONNECT_IND` in three.** `requests=0` on a burst is not
  evidence the watch did not connect: the 11:16:42 burst showed no request on the air and the
  archive shows the watch connected at 11:16:44.5. Read the sniffer for tails and minute calls,
  the archive for links.

**Standing after T1:** the pod-side design in §7 is not contradicted, and the blackouts are
not needed for the tally. The count feeder did not fire today and that is unexplained; T3
(three departures on 178, sysdiagnose after) is the next sample of it, and T2 (`relayGated` at
home) stays as designed.

## 7b. T1b — 09-07 12:16→12:47: the same toggles with the phone unplugged and watch Wi-Fi off — the feeder fires 4/4, preregistration held

**Setup.** E1 (keepalive only, no loan, no pod), ride-only. Phone **unplugged** from the Mac (no
watch-log relay sessions), watch **Wi-Fi OFF**. Two phone-Bluetooth departures: 12:16:00→12:27:00
and 12:33:00→12:43:00, the phone taking one burst (12:31:42, 7-s tail) between them. Sniffer
throughout; sysdiagnose 12:48:00. Preregistered at 12:15 and restated at 12:48: count 2 → ~4 →
~6, judgment 0→1 at the first re-add after 5, no −70 unless a late failure at state 1, every 762
preceded by a completed connection 5–8 ms earlier.

| what | result |
|---|---|
| tails (sniffer) | 12:16 32 s / 21 requests · 12:21 28 s / 20 · 12:26 8 s (extended phase over, minute call at 12:27:42) · 12:36 31 s / 21 · 12:41 30 s / 18 |
| count | 2 → 3 (12:17:02.7) → 4 (12:21:59.2) → 5 (12:37:02.4) → 6 (12:41:58.8) — **one per tail window, 4 of 4**, each 4.5 s after Dexcom's re-subscribe |
| shape | each: `Outgoing LE Connection complete` then `reason 762` 9 ms later, `Connection failed, Retrying`, re-add |
| judgment | **0 → 1 at 12:37:02**, the re-add right after the third failure; 1 through 12:47 |
| floor | none — all four failures early (inside the 6-s fast scan); the tail requests after +6 s were ignored, as at 11:06/11:11 |
| reads | every window, phone-present tails 7 s at 12:31 and 12:46 |

**Held on all four points.** And it gives the morning a controlled partner: the same
procedure (phone-Bluetooth departure, nobody moving) produced **0 failures in 2 tail windows at
11:06/11:11** with the phone on the Mac's USB, watch Wi-Fi on and two log-relay sessions open
through the phone, and **4 failures in 4 tail windows at 12:16–12:41** with the phone unplugged,
Wi-Fi off, no sessions. The failures are the sensor answering the request and the link dying
at once; the silent case is the sensor not answering at all. Which of the three changed
conditions matters, and why the sensor's answer depends on any of them, is not known. It is a
candidate to split (one change at a time), not a cause.

**Standing at 12:48:** the watch is at **state 1 with count 6**; the first late-tail failure
from here writes −70. That is the "judgment carried" precondition the §7 tests were written
for, so T2 or a rerun of T1 this afternoon would be the strict arm. The count's oldest entry
(12:17) ages out at ~18:05; whether the state follows the count down has never been observed —
only the overnight reset (7a).

## 7c. T1c — 09-07 13:13→13:47: a wedge on purpose at state 1, healed by touch, then the pod on minute calls at state 1

**Setup.** State 1 carried from 7b (count 6). Loan, phone Bluetooth off 13:13:00 (phone unplugged,
watch Wi-Fi off), ride-only, blackouts off. Pod radio was still `slots` during the first tail (the
13:16:57 bolus waited out the hold), `off` from 13:19, `slots` again after the heal. Sniffer
throughout; watch sysdiagnose 13:46:24.

| when | archive |
|---|---|
| 13:16:42 burst | watch read at :48.8, close :50.3; Dexcom re-subscribed with −100 |
| 13:16:54.38 | early 762 (+4 s, in the fast scan) → count 7 |
| **13:17:06.62** | **late 762 (+16 s, after the fast scan) → count 8; the daemon's retry re-added the sensor with `option RSSI:-70`** |
| 13:21:42, 13:26:42 | bursts on the air 25 s each, **zero watch requests** — parked; no link in the archive |
| 13:27:19 | Dexcom's own new request while the −70 entry was pending: wrote nothing |
| 13:27:42 minute call | watch held on the sensor → link 13:27:43.7 (close-range burst clears −70) → close :45.2 → Dexcom re-subscribe → add with −100 → **healed** |
| 13:31→13:46 | every burst connected (Dexcom); our client failed to ride 13:31 and 13:36 — app-side, see below |
| 13:38:42, 13:39:42, 13:43:42, 13:44:42 | minute calls with a pod link up and the watch's requests in the same seconds, **at state 1**: count flat at 8, no −70 |

**What this settles.**
1. **The wedge does not need the pod.** The late failure that wrote −70 came with the pod held
   off the radio by `slots`. State 1 plus a late failure in an extended-phase tail is sufficient.
   The 175 hold removes one way of adding a late failure; it does not remove the wedge.
2. **The floor is written as the accept-list option on the retry, not as a "Setting minimum
   RSSI level" line.** Earlier greps that looked only for the latter would miss it. `Adding
   device … with option RSSI:-70` is the line.
3. **Minute calls are harmless at state 1 too.** Four pod-on-call collisions with the daemon
   armed: nothing counted, nothing written. T1's "judgment carried" arm is now done.
4. **The exposure is the extended phase only.** Both counted failures and the −70 came inside
   the long tails of the first ten minutes after the phone stopped collecting; the minute-call
   phase produced nothing all day at either state. Pod and reclaim restrictions, if any, belong
   in those tails and nowhere else.
5. **Touch-heal works at a minute call**, which carries no reading: Dexcom's app reports healthy
   on a stale value until the next five-minute burst.

**App-side, recorded, no code (Jeremy's call: these scenarios are extreme).** Our client's join at
the 13:28 minute call was left pending when the call closed; it resolved onto the 13:31:42 link as
it was closing (connected/disconnected 22 ms apart, "auth subscribe FAILED … NO SERVICES"); the next
join at 13:36:44 connected but never authenticated in 12 s; the lab recycle did not clear it;
force-quit did (13:41:44 auth in 0.2 s). The force-quit ended loan 310; the seize made 311; the
phone, back at 13:45:41, dropped 311's checkpoint batches while reconciling 310 and then
reconciled 311 with zero checkpoints, R32 WARN −0.40 U — probably phantom, unverified.

## 7d. BUILD 179 — one hold, the extended phase only; the wedge hint; the lab trimmed (written 09-07 15:25, before the field test)

**Jeremy's rule (09-07 14:45):** "my goal is to simply not make it any worse than Dexcom … detect
phone absence going into 10 minute mode. During that mode, avoid bolus collisions. Outside of that
mode, pod is unrestricted." No scan-hit heal. No new alert. No code for the app-side observations
in 7c. Fewer lab buttons.

**What changed.**
1. `PodRadioPolicy` (quietGate / slots / relayGated / off), the minute-call blackouts and the
   two-central close+3 hold are gone. One rule in `PodRadioSlotPolicy`: the sensor is in its
   **extended phase** when THIS window has no phone relay and a relay landed within 12.5 min
   (two windows, three when the departure cut one short — the third burst is already short).
   In that phase the pod is held from the burst to close+25 s (capped burst+40, read-relative 40
   until the close is seen) and for the 20-s lead before the next burst. Outside it — phone
   present, steady phone-absent, a loan that began with the phone already away, a relaunch —
   **nothing is held**: the pre-burst bracket keeps deferring WatchConnectivity sends and log
   hops around the burst, but the pod path ignores it. The session-end gate of `quietGate` is
   retired. Bench switch `G7Lab.podRadioHoldOff` removes every hold; nothing on the wrist sets it.
2. **The wedge hint.** On the glance, under a stale number, when two or more consecutive expected
   bursts had no read and the phone has not relayed for two windows, the provenance line reads
   "G7 silent 12 min · try toggling watch Bluetooth" (minutes live). No alert; it names the watch.
3. **Radio Lab:** ride-only, WC silence and the E1 soak remain; the pod-radio cycler, the blackouts
   row, "Log WC backlog" and "Recycle G7 connect" are gone; a read-only "pod hold: none /
   extended-phase / off" line shows what the rule is doing. Log lines carry the same word:
   `[tail] … hold extended-phase`, `[g7-window] … hold=none`, `[quiet] DEFERRED … (extended-phase)`.
4. Tests: `PodRadioSlotPolicyTests` rewritten for the rule (extended-phase detection, the hold,
   the open minute calls, nothing held outside, 40-s cap, no anchor no hold, bench switch off by
   default); `WedgeHintTests` (two misses + phone away + stale → the line; one miss, a relaying
   phone, or a fresh number → nothing).

**Two review fixes before shipping (15:45).** (a) The relay stamp that the rule keys on was set
when a relayed reading was STORED (178) — and the store drops the relay whenever the watch's own
direct read beat it, the common case near the phone, so phone-present windows often left no stamp
and a departure then looked like steady phone-absent: no extended phase, no hold. It is now
stamped on ARRIVAL of a new relayed reading, before the fill-a-gap skip (the same lesson as the
direct-G7 provenance stamp, OPTION C). (b) The pod deferral polls the hold every ≤5 s instead of
sleeping through it, ceiling 100 s, so a hold that ends early — this window's relay landing a few
seconds after the direct read — releases the dose at once instead of 40 s later.

**Preregistered field test (T4, the T1b procedure on 179):** phone unplugged, watch Wi-Fi off,
loan, two phone-Bluetooth departures with a window in between, boluses tapped at +15 s of the
first two bursts after each departure and at +15 s of two later windows, sysdiagnose after.
- Watch log: `[quiet] DEFERRED manual bolus … (extended-phase)` ONLY for the taps in the first two
  windows after each departure, released by +40 s; the later taps enact at once (no DEFERRED);
  `[tail]` lines say `hold extended-phase` in those windows and `hold none` everywhere else,
  including every phone-present window.
- Archive: the count moves by the daemon's own tail failures only (~+2 per departure, as 7b);
  no −70 unless the daemon's own late failure lands at state 1 — and if it does, the glance
  shows the hint by the second missed burst.
- Air: the pod link never inside a long tail before +40 s; on the minute calls freely.

## 7e. T4 — the 179 walk, 16:08→18:00: wedged at 16:22 by our pod in a tail the rule had released — the relay clock is wrong

**Setup.** Loan 16:08 with the phone at home; Jeremy walked out ~16:13–16:15 (the watch's WC
"reachable" went away by 16:17). State 1 carried from the afternoon, count 7. Carbs 29 g + 4 U
bolus at 16:22:00; a 0.15 U bolus at 16:27:05 to provoke. Watch sysdiagnose 18:16.

| when | archive / watch log |
|---|---|
| 16:11, 16:16 | held as extended phase (`DEFERRED dose cycle / pod reclaim (extended-phase)`), pod on the air only after +40 s |
| 16:17:03 | early 762 (+6 s after the re-subscribe), count 8 — pod held, the daemon's own |
| 16:21 | the rule's clock expired (12.5 min after the last "relay", 16:08) → `hold none` → loop reclaim at read+2 s, the 4 U bolus rode the link: **pod on the air 16:21:48.5→16:22:15.0** |
| 16:22:03 | early 762 (+4.6 s), count 9 |
| **16:22:13.147** | **late 762, +15 s after the 16:21:58 re-subscribe (fast scan ended 16:22:04), count 10 → retry re-add `option RSSI:-70`** — with our pod link up |
| 16:26, 16:31 | missed; the glance hint showed; Jeremy toggled the watch's Bluetooth |
| 16:34:46 | count 0, state 0 — daemon restart; Dexcom link 16:34:44 at a minute call; clean to the hand-back |

**Cause.** The relay is Loop-on-the-phone's reading, not Dexcom-on-the-phone's connection to the
sensor. Loop-phone had ZERO G7 readings from 16:07 to 18:00 while sitting at home (an anomaly of its
own, unexplained), so the watch's last "relay" was the stale sample in the grant context at 16:08,
and the rule's ten minutes ran 16:08→16:20:30. The sensor's ten minutes began when Jeremy walked
out of the phone's range, ~16:14, so its long tails were 16:16 and 16:21. The rule released the
pod one tail early, and that tail took the late failure. Two flaws: (1) the relay cannot time the
sensor's extended phase — it stops when Loop-phone stops, which can be hours before or after the
phone's Dexcom app does; (2) the stamp counted a stale sample.

**Decision (19:55, Jeremy): 179 stands, nothing changes.** With Loop-phone relaying normally the
last fresh relay marks the last window the phone collected, the sensor's extended phase begins at the
next burst, and the 12.5-min clock covers exactly those two windows (T5, §7f, showed it: 19:01 and
19:06 held, 19:11 free, the phone-present window released in 5.5 s). The walk failed only because the
relay stopped six minutes before the phone did, which needs Loop-phone silent while the phone still
collects — the post-install anomaly, seen twice today, recovered on its own both times, not diagnosed.
**Leave the stale grant-context stamp alone:** it makes the clock start at the loan grant, i.e. "hold
the tails for twelve minutes after a loan starts", which is right since loans mostly start at
departures; it is what held 16:11 and 16:16. A fresh-only stamp would remove that and must not go in
by itself. The hold-all and widened-clock variants were written, tested green and discarded.

**Held from T4:** the hint's first field test worked; the toggle healed (daemon restart, count 0);
17 phone-absent windows after the heal read cleanly with the pod at read+1…2 s in every one (short
bursts, minute-call mode, `hold none`) — consistent with T1/T1c, no failure counted from any of them.

## 7f. T5 — 09-07 18:54→19:38: watch Wi-Fi ON, phone unplugged, one departure — the feeder fires 2/2; Wi-Fi is not the variable

Loan with the phone beside the watch, watch Wi-Fi on, phone unplugged from the Mac (no watch-log relay
sessions), phone Bluetooth off ~18:58→19:13, sniffer on, sysdiagnose 19:17. Air: 19:01 tail 29 s with
16 watch requests, 19:06 tail 28 s with 17 — the extended phase in full. Archive: 762 at 19:02:01.4
(+4.6 s after the re-subscribe) and 19:06:59.5 (+4.2 s), count 0 → 2, one early failure per tail,
state 0, no −70. Same as 7b (4/4). So the morning's 0/2 (7a) was not the watch's Wi-Fi; what remains
of that comparison is the phone on the Mac's USB with two watch-log relay sessions open, or chance.

Build 179 on this run: the 18:56 window was held for 5.5 s until the relay landed after the direct read
(the polling release), the 19:01 and 19:06 tails were held with the pod at burst+40 — after the sensor
had gone quiet on the air both times (close+15 and close+11) — and 19:11 was free on minute calls.
Reachability reported "phone away" at 18:57 with the phone a metre away and relaying: not a presence
signal, even at home.

## 6b. PORT MANIFEST ADDENDUM for next-dev — what changed after §6 (written 09-07 20:05; the state to port is build 179)

§6 still stands for the G7 side. Everything below supersedes §6's pod side and adds what the
09-07 tests settled (§7a–7f). Port by content; the port's pod reclaim is its own.

**Facts the port's design must respect (all archive-verified, 09-07):**
1. The tally counts reason 762 AND 708 (supervision timeout of an established link). Window
   20,864 s; threshold 5; the state was seen to clear only on a daemon restart (watch-Bluetooth
   toggle) and overnight on the charger.
2. The −70 is written as the accept-list option on the daemon's retry after a LATE failure at
   state 1 (`Adding device … with option RSSI:-70`); there is no "Setting minimum RSSI level -70"
   line. Late = after the 6-s fast scan that follows Dexcom's re-subscribe, i.e. only inside the
   sensor's 27–32-s tails, which exist only in the first two windows after the phone stops
   collecting (the extended phase). Steady phone-absent windows are 3-s minute calls.
3. **The wedge needs no pod:** 13:17:06 wrote −70 with the pod held. The pod hold removes our
   contribution to late failures; it cannot remove the wedge. Every earlier "late failures only
   with our radio" fact is thereby narrowed to "more often with".
4. **Minute calls are harmless:** 17 pod links deliberately on the +60/+120/+180/+240 calls, 13 at
   state 0 and 4 at state 1, counted nothing. Blackouts retired.
5. Phone-present windows (7-s two-central tail) have never produced a late failure. No hold there.
6. The count feeder is the daemon's own: one early 762 per long tail, ~2 per departure, with the
   Loop app absent too. One morning (phone on the Mac's USB with log-relay sessions open) it was
   0/2 — cause unknown; watch Wi-Fi ruled out (§7f).

**Pod side, final (build 179, §7d–7e, decision §7e):** ONE hold. A window is "extended phase"
when it has no phone relay and a relay landed within the last 12.5 min. In it: hold the pod
(reclaims, takeover ladder, manual boluses) from the burst to close+25 s, capped burst+40 s
(read-relative 40 until the close is seen), plus the 20-s lead before the next burst. Outside it:
nothing held. The pre-burst bracket keeps deferring only WatchConnectivity sends and log hops.
The deferral polls the hold every ≤5 s (ceiling 100 s) instead of sleeping through it, so a
phone-present window whose relay trails the direct read releases in seconds. The relay is stamped
on ARRIVAL of a new relayed reading (before any dedup/skip), and the grant context's sample counts
even when stale — that is load-bearing: it starts the clock at the loan grant, i.e. "hold the
tails for 12 min after a loan starts". Do not add a freshness check by itself. Four-way policy,
blackouts, two-central hold and the session-end gate are gone; bench key `G7Lab.podRadioHoldOff`.
Cost per departure: ≤3 windows with a bolus delayed ≤40 s if tapped inside the tail.

**Post-install stall: REFUTED 09-07 22:0x.** Build 180 (identical code to 179) was installed and the
phone app deliberately NOT opened: it was background-launched at 21:59:17 and delivered its first
reading at 22:06:45, then every window, relaying to the watch throughout. So the two-hour silence
after the 179 install (§7e) is a genuine one-off, unexplained and unreproduced; there is no
install-time rule and no user guidance needed.

**Known hole, accepted (§7e):** the relay is Loop-phone's reading, not Dexcom-phone's
connection. If Loop-phone is silent while the phone still collects (seen twice on 09-07 after a
TestFlight install, recovered untouched, not diagnosed), the clock starts early and a departure's
second tail can be unheld — the 179 walk wedge. Alternatives (hold every no-relay tail at ~12 %
of every phone-absent cycle; a 20-min clock fed also by loan start and reachability loss) were
built, tested and discarded by Jeremy's call: the relay clock is right whenever Loop-phone works.

**The glance hint (build 179):** under a stale number, when ≥2 consecutive expected bursts had no
read and no relay for two windows: "G7 silent N min · try toggling watch Bluetooth". No alert. It
names the WATCH (ruling). Field-tested 09-07 16:26: shown, toggle healed (count 0, state 0).

**Lab:** ride-only, WC silence, E1 soak, a read-only "pod hold: none / extended-phase / off" line.

**Observations recorded, NOT to be worked (Jeremy: "these scenarios are extreme"):** a join at a
minute call leaves a pending connect that resolves onto the next burst's dying link ("auth
subscribe FAILED … NO SERVICES") and poisons the client until force-quit (§7c); the phone drops
a seized epoch's checkpoint batches while still reconciling the force-quit-ended loan, then
reconciles with zero checkpoints (R32 WARN −0.40, probably phantom); Loop-phone's G7 delivery
stalled twice after the 179 install.

**Acceptance on the port (T4, preregistered §7d):** phone unplugged, watch Wi-Fi off, loan, two
phone-Bluetooth departures with a phone-present window between, boluses tapped at +15 s of the
first two bursts after each departure and at +15 s of two later windows, sysdiagnose after.
Expected: the early taps deferred ≤40 s and released; the later taps enact at once; `[tail]` says
hold in the first two windows after each departure and none elsewhere; the count moves only by
the daemon's ~2 per departure; no −70 unless the daemon's own late failure at state 1.

**Tools that travel:** the sniffer recipe (`ops/g7sniff/README.md`); the sysdiagnose extract +
`log show` recipe; and in this session's scratch, `bt-report.sh <bt.log> HH:MM HH:MM` (tally /
judgment / floor writes / links / adds / history from an extract) and `air.sh <pcap> HH:MM`.
Live watch-log streaming through the phone (pymobiledevice3 companion proxy) works but drops
most of bluetoothd; a stored-log pull runs at 72 KB/s; neither replaces sysdiagnose.

## 6c. UI-BATCH DELTA for next-dev (checked 09-08 against trees/port-nextdev @ f68174e6)

Not part of the mute fix; a separate batch of small watch-UI changes that landed on the Caitlin
line in builds 174–176 and never travelled. Jeremy noticed the first one on next-dev. Checked
item by item against the port; PRESENT/MISSING as of f68174e6:

| item | Caitlin commit | port |
|---|---|---|
| Loop-tap haptic: `WKInterfaceDevice.current().play(.click)` first line of `onLoopTap()` | 8d95e80c | **MISSING** (the port has the End/Cancel haptics at GlanceView.swift 324/426, not this one) |
| Land on the glance: `landedOnGlance` in ExtensionDelegate, first activation of a process calls `becomeCurrentPage()` | 8d95e80c | **MISSING** — and the port is SwiftUI-navigation, not WatchKit pages, so this needs its own mechanism or may be moot |
| Repaint while inactive: mirror observer armed by `armMirrorObserver()` and NOT torn down in `stopRefreshing()` (only the 2-s tick stops), plus `refreshGlanceData()` after every direct-G7 and phone-relay ingest | 8d95e80c | **MISSING** (port has 1 `refreshGlanceData` call site) |
| Ring palette parity: stock ring assets `.renderingMode(.template)` + `ringColor` from the phone's palette (fresh #0AB443, aging #E9C244, stale #FF453A) | 4700cbbc | **MISSING** |
| Override chip as icon + numbers rather than the preset name (symbol, insulin %, target midpoint) | 4700cbbc | **MISSING** |
| Stuck listening screen offers "Re-acquire Sensor" as a button, force-quit demoted to the footer | dc038d6c | **MISSING** |
| Diagnostic screen: BG value + reading time (`CGMHealth.bgLine`, `row("bg", …)`) | a5bcfa3b | **MISSING** |
| Keepalive probe re-pointed on every `acquire` | a5bcfa3b | PRESENT |
| `TailExposure.notePodLink` routing, wedge hint | mute fix | PRESENT |

All of these are cosmetic or diagnostic; none touches dosing. The haptic is one line.

## 8. IN-APP DETECTION of the daemon's counted failures — what we can see without a sysdiagnose (checked 09-08, nothing built)

Question (Jeremy, 09-08): can the app detect the disconnections that feed bluetoothd's tally,
without pulling a sysdiagnose? Answer is split, and the split is mechanical.

**Reason 708 (supervision timeout): VISIBLE, exactly, and already in our log.** A 708 kills a link
we are riding, so it arrives as our own CoreBluetooth callback. Watch log 2026-09-07:

    08:26:55.495 [g7-ble] didDisconnect DXCMbv error=The connection has timed out unexpectedly. [CBErrorDomain#6]

The archive (sysd13) records `reason 708` for that sensor at 08:26:55.480 — 15 ms apart, the same
event. Across the uploaded watch logs: 17 `CBErrorDomain#6` lines on 8 distinct occasions, against
1,220 `CBErrorDomain#7` ("The specified device has disconnected from us"), which is the sensor
ending a read normally and is NOT counted. **Code 6 is a tally point; code 7 is not.** We log both
today and interpret neither.

**Reason 762 (failed to establish): INVISIBLE.** Checked our log at five archive-confirmed 762s
(13:16:54.38, 13:17:06.62, 16:17:03.14, 16:22:03.03, 16:22:13.14): zero lines from us at four of
them; the two at 16:22:03 are an unrelated `[timer]` line. Not a throttling artifact —
`DeviceLogThrottle` collapses only identical consecutive lines inside 2 s, and the nearest
preceding line at each instant is 4–16 s earlier with different text. Mechanically: a 762 is a
link that never became usable, belonging to DEXCOM's connect request; CoreBluetooth delivers a
connection event only for links that come up. Compare 13:16:49 (the successful read, in our log as
`connection-event CONNECT` + `didConnect`) with 13:16:54 and 13:17:06 (nothing).

**What could be built (NOT built; Jeremy's call):**
1. Count `CBError.connectionTimeout` (code 6) disconnects, decayed over the daemon's 20,864-s
   window. Exact, free, already logged — only the counting and the label are missing.
2. Estimate the 762s from their cause, which we CAN see: no relay this window → the sensor is in
   its long tails → the daemon fails ~once per tail. Calibration from 09-07: T1b 4 tails → 4
   failures; T5 2 → 2; T1c 1 → 2; T4 2 → 3. So 1–1.5 per no-relay window for the first two after
   the relay stops; report as a lower bound, never as a measurement.
3. Sum, flag at 5, surface on the diagnostic screen plus one line per window in the log. On both
   of 09-07's wedges this estimate would have been signalling danger beforehand.
4. Free calibration: whenever a sysdiagnose IS taken, compare the estimate to the archive.

**Not available:** the daemon's tables are private; nothing in-app makes this exact. The one
observable that would CONFIRM a parked floor without a sysdiagnose is a brief scan after a missed
window, outside the tail (sensor advertising + no link = parked). That is a radio change in the
direction §7 spent a week removing, so it needs preregistration, not a quiet addition.
