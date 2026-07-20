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

## Resolved

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
