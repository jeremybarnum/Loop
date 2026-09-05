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

## 2. The model (what the exclusions leave)

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
  The plugin only follows from Wireshark's toolbar, so `scratchpad/g7follow2.py` drives the
  SnifferAPI directly (scan → follow(address) → pcap, re-arming after a quiet link).
- The library's derived packet timestamps drift by up to two minutes across a capture; stamp
  packets with the host clock at receipt (g7follow2 does) or nothing lines up with the watch log.
- UNVERIFIED (09-05 15:15, 15:22): with the phone in a Faraday case, paired `CONNECT_IND`s
  ~1 s apart from rotating Apple-style addresses reached the sniffer at −67…−74 dBm at the
  MINUTE bursts, three master polls each, never a reply from the sensor. Best reading: the
  caged phone leaking, too weak for the sensor to hear — not the watch, whose Dexcom app read
  every window. Confirm from the watch log's `[g7-window]` lines for those minutes before
  citing; if the watch did read at 15:22:39, this sniffer is missing the sensor's half of a
  connection and its "no reply" is worthless.

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
