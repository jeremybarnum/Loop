# E4 — Time-separating the pod and G7 radios (the 2026-07-21 breakthrough)

## The finding, in one line

Holding the Omnipod BLE connection while reading the G7 starves G7 acquisition
under watchOS's tight per-app Bluetooth-connection budget. Releasing the pod
between doses ("orphaning" it) gives G7 the radio and recovers ~standalone
catch rate.

## The evidence (catch rate = % of 5-min windows caught on-time)

| Condition | On-time | Notes |
|---|---|---|
| No pod at all (E1, standalone diagnostic) | **94%** | pod connection absent entirely |
| **Pod orphaned, deferred release (E4 v2, build 140)** | **100%** (8/8) | the fix, open loop |
| Pod held, closed loop (overnight b136) | 77% | commands keep the connection warm |
| Pod held, open loop (Cell 1a) | ~20% | idle-drop reconnect churn is worst |

Ranking: **cleanly-gone (94-100%) > warm-held (77%) > idle-churning (20%)**.
The middle state (a held connection that idle-drops and auto-reconnects) is the
worst; a stably-warm connection is better; no connection is best.

## Mechanism (confirmed by the E4-v1 break)

- watchOS caps BLE at ~2 connections per app (Apple-staff-cited; the exact
  number is less important than the ceiling). The watch holds the pod AND wants
  the G7 → contention. On iOS (phone Loop) the same pod+G7 pair coexists fine
  because iOS allows more concurrent connections; the watch is where it breaks.
- `cancelPeripheralConnection` is nonblocking and does NOT guarantee teardown;
  on watchOS it can leave a peripheral stuck `.disconnecting`, which still
  consumes the slot AND poisons the shared budget — the same incomplete-teardown
  demon behind the ordinary missed windows.
- **E4 v1 (build 139) proved this by breaking it**: releasing the pod AT takeover
  (cancelling a freshly-established connection) left it stuck `.disconnecting` and
  put G7 into a "connects-but-can't-read" loop for 16 minutes — a pathology never
  seen in any non-E4 session.
- **E4 v2 (build 140) fixed it**: DEFER the release +90s so a SETTLED, idle
  connection is cancelled, which tears down cleanly. 100% catch followed.

## Two facts that make orphaning safe

1. The pod is designed to run autonomously — it disconnects itself ~3 min after
   the last command (its nominal behavior) and runs its last basal/temp until a
   controller returns. Orphaning is the pod's native mode, not an abuse.
2. Stock phone Loop already runs "connected-with-churn" (~60% pod uptime, default
   keep-alive off) — our watch holding it persistently is the deviation, not the
   norm.

## Stage 2 — closed-loop dose choreography (build 141, flag-gated, UNTESTED on pod)

Flag: `g7.e4ReleasePod` (diagnostic toggle, default OFF → dosing path is the
tagged baseline). When on:

- **Takeover:** after ACTIVE + first read, defer-release the pod +90s (v2).
- **Each dose** (`WatchDoseEnactor.enact` automatic; `enactManualBolus` manual):
  1. `reclaimPodForDose` — `reclaimConnection()` + bounded `podLoanReadStatus`
     probe (idempotent — the takeover ladder's own mechanism, so no double-dose),
     ≤ ~16s.
  2. on connect → enact.
  3. `releasePodAfterDose` — re-release after a **+12s settle** (v1 lesson).
- **Safety:** bounded wait runs on `dosingQueue` (never blocks the loop cycle);
  an automatic dose that can't reconnect is SKIPPED (pod runs baseline, retry
  next cycle); a MANUAL bolus that can't reconnect FAILS LOUDLY. Timing puts the
  dose in the ~4.5-min quiet gap between G7 windows.

## Home closed-loop test protocol (new pod required)

1. Install 141. Enable E4 on the diagnostic screen. Start a session. **Close the loop.**
2. Verify from the log:
   - G7 catch stays ~94-100% (reads on the 5-min grid).
   - Each cycle: `E4: reclaiming pod to dose` → `pod reconnected for dose` →
     temp-basal enact → `pod re-released after dose (+12s settle)`.
   - No missed or double doses; recreates stay ~0.
   - Manual bolus reconnects & delivers (or fails loudly — never silent).
   - Hand-back still clean.
3. Watch for: a reclaim eating into a G7 window (dose should land in the gap),
   and the reconnect-fail skip rate.
4. Then: replicate the open-loop 100%; then the R29 dosing-limit simulation
   (Jeremy is not diabetic — max-temp/high-BG paths need a synthetic T1D profile).

## Return points (tags)
- `b136-77pct-overnight` — the working baseline (77%), safe fallback.
- `e4-validated-140` — the open-loop breakthrough (100%).
- (next) tag Stage 2 once field-verified closed-loop.
