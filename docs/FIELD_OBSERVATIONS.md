# Field observations ledger — things seen in logs, not yet fully explained

Standing practice (Jeremy, 2026-07-20): when a log shows something I don't fully
understand, record WHAT was seen and WHEN here — with a hypothesis if one exists —
rather than forcing an explanation. Items get resolved (with the answer) or asked
about explicitly. Never silently dropped.

## Open

- **OBS-1 (2026-07-19 22:39): epoch 21 takeover vanished without a verdict.**
  GRANT epoch 21 received 22:39:36; the log shows NEITHER "ACTIVE" nor "TAKEOVER
  FAILED" for it before the next REQUEST at 22:41:00 (epoch 22, which succeeded in
  6s). Something drops a takeover silently — every takeover should end in exactly
  one verdict line. Radio-stack audit dimension 3 is tracing the code path; if the
  mechanism is a user-initiated re-request superseding the ladder, the fix is a
  "superseded by epoch N" log line, not a behavior change.

- **OBS-2 (2026-07-20 11:32): one missed G7 window inside an otherwise perfect run.**
  Post-recovery rhythm was on-grid (11:22, 11:27, then 11:37, 11:42, 11:47, 11:52)
  but the ~11:32 window produced no pending-connect fire; a fallback scan timed out
  at 11:34:45 ("no G7 found"), and the next arm caught 11:37 (fired after 147s).
  Hypothesis: sensor skipped/shifted one advertising burst (it does this
  occasionally — the standalone reader showed the same ~1-in-N misses) — OR the
  pending connect was quietly dead and the scan+rearm rescued it. Single miss with
  clean self-recovery; watch for the pattern rate across future logs before
  treating as a defect.

- **OBS-5 (2026-07-20 ~17:45): SECOND "Brief Sensor Issue" of the day, again after
  heavy watch connect churn.** Morning event (~10:40–11:05) followed the poisoned-
  session churn; this one follows 127's five-window miss spiral (16:42–17:03,
  repeated connect/cancel cycles) and a slow 129 takeover. Hypothesis to WATCH, not
  conclude: G7 firmware may enter a protective/quiet state after repeated
  failed/aborted connection attempts. Counter-evidence: overnight 119 churned for
  hours with no sensor issue, and the sensor also read low (51–59 mg/dL) today —
  could equally be a struggling sensor day (compression, EOL drift). If the
  churn→issue pattern repeats on a healthy sensor, consider gentler retry behavior.
  Practical rule meanwhile: a sensor-issue window makes acquisition-cadence data
  UNINTERPRETABLE — don't count such sessions for or against a build.

## Resolved

- **OBS-4 (2026-07-20, build 126): predictive/scan acquisition gives ZERO reads.**
  A/B flip of reconnectMode → OFF (scan-then-connect) to fix the missed-window
  cadence backfired completely — no G7 for a whole session. Log: scan discovers
  'DXCMp5' connectable=yes every cycle, but the connect issued ~2s later (after the
  candidate-collection window) lands AFTER the ~6s advertising burst closes, rides
  401s at state=1, and wedges. The G7 is connectable ONLY during its burst → the
  connect must be ARMED in advance (pending-connect). Reverted in build 127;
  reconnectMode stays ON permanently. The real cadence fix is the 400s watchdog
  re-arming a pending connect instead of falling to the wedge-prone scan (task #15).

- **OBS-3 (2026-07-19 22:37 + 22:40): prewarm pending at loan request time on an
  already-bonded sensor.** Two prewarm 360s scans started during the loan-request
  sequence — exactly the G7 activity that starved takeover epochs 19/25 (→ R26).
  Resolved: build 119 predates the same-sensor re-relay guard (added in 92c5a743,
  shipped 120/121 — the task-#18 fix). On 119, the request-time code relay of the
  SAME sensor re-armed a prewarm and cleared the bond; current builds early-return
  on same-sensor re-relays, and R26 contains any legitimately-armed prewarm during
  a takeover anyway. Two independent fixes now cover this failure.

- **(2026-07-19 22:47–23:44): six consecutive 400s pending-connect timeouts while
  connectable ads were flowing (RSSI −71..−86), peripheral stuck state 3 between
  attempts.** Resolved: this was build 119 — the poisoned-BLE-session failure mode,
  before the 121 self-heal existed. On 121 the same signature (stuck state 3 >5s)
  triggered "RECREATING Bluetooth central" at 11:17:32 and the very next armed
  connect fired (11:22:27) → readings resumed. The self-heal is field-validated.

- **(2026-07-20 ~10:40–11:05): long stale period on watch AND phone.** Resolved:
  the Dexcom app itself reported "Brief Sensor Issue" and the phone's own chart
  had the same gap — a sensor-side EGV outage, not an acquisition failure. Note
  the recovery readings were 51/55 mg/dL: a sensor outage can mask a low, which
  is what the 20-min SensorBlackoutAlert (R25b) exists for.

- **(2026-08-04): "Reclaiming…" persists 60–100 s on the phone pill.** Bimodal:
  `reclaim VERIFIED` lands at +2/4/6/7 s on the fast runs and +59/68/87/99/101 s on
  the slow ones. Ruled out by measurement, not argument:
  - *Ack starvation* — refuted. The phone's ack of the final offer is 0.3–6 s and
    the watch reports CLOSED 0.9–7.2 s after End. Both sides finish the protocol
    fast; the delay is entirely downstream.
  - *App suspension on the watch* — refuted by Jeremy: the tests were wrist-up with
    the Loop app foregrounded on the phone.

  Root cause: the watch never actually dropped the pod's BLE link. `teardownPump()`
  nil'd the delegate, nil'd the pump manager, and trusted ARC to unwind
  BlePodComms → BluetoothManager → CBCentralManager. Nothing called
  `cancelPeripheralConnection`, nothing removed the pod from `autoConnectIDs`, so
  one lingering reference kept the pod CONNECTED — and a connected pod does not
  advertise, so the phone's standing connect could not land however aggressive it
  is. The tell Jeremy found: tapping into pump status during "Reclaiming…" showed
  data minutes old, from *before* the loan.

  Confirmed as a from-stock regression against crude, which released explicitly:
  `PodController.releasePod()` → `podComms?.forgetPod()` →
  `bluetoothManager.disconnectFromDevice(...)`. from-stock's teardown had no
  equivalent — which is exactly why Jeremy remembered crude not having this.
  E4 has released explicitly all along (every five minutes, logging a clean
  `state connected -> disconnected (+3s)`); only the hand-back path was missing it.

  Fix: `teardownPump()` now calls `podLoanOrphanConnection()` first — the disconnect
  + `cancelLoanScan` WITHOUT the C5 record-close, since `finalizeHandback` has
  already closed the temp and `ledgerClear()` supersedes it. `releaseConnection()`
  now logs which branch it took, because a release that finds no `bleIdentifier` is
  a silent no-op.

- **(2026-08-05, build 228): hand-back BLE release CONFIRMED; residual is bench-only.**
  Three loans on 228, teardown fired every time (0.01-0.02s):
  | epoch | loan | E4 released | reclaim |
  |---|---|---|---|
  | 192 | 174s | yes | 4s (control — the realistic case) |
  | 191 | 36s | **no** | **4s** (227 gave 59-186s in this regime) |
  | 193 | 9.9s | no | no `reclaim VERIFIED` within 25s |

  191 is the result: the explicit release converts the short-loan case. 193 shows the
  teardown is NECESSARY but not SUFFICIENT — it handed back 39s after the previous verified
  read, the freshest the phone's pump data can be, which points at the C3 staleness gate
  (`chaseReclaimVerification` -> `ensureCurrentPumpData` skips the read under 6 min).
  UNSETTLED: 192 handed back 3.1 min after its prior read — inside the window, so C3 predicts
  it should also have stalled, and it verified in 4s. One fitting case, one contradicting.
  Jeremy's call: sub-90s loans are a bench artifact (real workouts are 20-60 min), so this is
  low priority.

- **(2026-08-05): the pump pill can go quiet while the bolus gate is still live.**
  Two predicates that must agree, don't: `isReclaimSettling` (drives the sweep,
  PodLoanPhoneController.swift:283) has a 5-minute ceiling; `isReclaimSettlingOnly` (drives
  the #71 bolus gate, :164) has NO ceiling. Past 5 minutes unverified the pill reads
  "returned" while carb/bolus entry is still refused. Jeremy's criterion (2026-08-05): a mixed
  chart state is fine "as long as the pump pill doesn't indicate the return is complete" —
  which this violates. NOTE: a proposed one-line fix (sweep on
  `isPodLoanReclaiming || isPodSettlingAfterReclaim`) is a NO-OP — `isPodLoanReclaiming`
  already covers both phases. STILL UNEXPLAINED: at 00:23, ~25s into epoch 193's settle, the
  pill showed no sweep at all, well inside the 5-minute ceiling. Diagnose before fixing.

- **(2026-08-05): "Pod on Watch" renders two different ways — a bug, not a mode.**
  `presentStatusHighlight()` (PumpStatusHUDView) removes basalRateHUD + pumpManagerProvidedHUD
  so the highlight REPLACES them, but it early-returns when the highlight is already in the
  stack. `configurePumpManagerHUDViews()` re-adds the pod icon (StatusTableViewController:1822)
  and only then calls `presentStatusHighlight` (:1826) — which returns early, leaving the icon
  visible. `.PumpManagerChanged` fires on every loan transition, so which variant you see is
  just whether a highlight was already up at the last reconfigure.

- **(2026-08-05): End cancels an in-flight manual bolus and blames the pod.**
  `attemptReclaimRead` guards `phase == .active` (PodLoanWatchController.swift:900, :921);
  hand-back flips the phase, the ladder aborts, and the user sees
  "MANUAL BOLUS FAILED — E4 pod reconnect timed out (pod unreachable)". Seen 3x (227 00:07:51
  twice, 228 00:18:44), each within ~0.5s of a hand-back, with NO `E4: reclaim read N/14`
  lines — every other route to `completion(false)` logs one, so it was the phase guard. No
  insulin was delivered (fail-loud worked); the diagnosis is what's wrong. OPEN: never yet
  observed a manual bolus that was allowed to finish, so "End kills it" vs "bolusing during a
  loan is broken" is undecided — needs one bolus on a >90s loan with End untouched.
