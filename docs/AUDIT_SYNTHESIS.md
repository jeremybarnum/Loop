# Crude-vs-fromstock audit — party post-mortem and the synthesis plan

2026-07-18 overnight. Inputs: the full evening field log (builds 113/116), the
prediction branch (LoopWorkspace-prediction, Loop g7-build-next / OmniBLE
pod-loan) as ground truth, and fromstock history. Four readers + max-effort
synthesis; hypothesis-driven. This file is the condensed record; the raw
workflow output lives in the session transcript.

## What actually happened at the party (evidence-ranked)

**M1 — The 97-minute "ownership unclear / can't bolus" limbo is REG-1, a
fromstock-only hole.** `beginHandback` has no reachability guard, kills dosing
at entry (`pumpManager = nil`), and the phase machine has NO way back to
active — the only exits need the phone. `isLoanActive` goes false, so watch
boluses reroute to the released phone relay and die. The crude coordinator
triple-guarded this (reachability check up front; failure reverts to
"Still in control on your watch"). The 21:10 clean close was the queued
channel finally delivering — the protocol worked; the phase/dosing lockout
around it is the bug.

**M2 — The three strong-RSSI discoveries (19:18/-84, 20:32/-80, 20:57/-73)
were killed by the 15-second connect watchdog added that morning (REG-2).**
The G7 advertises a ~6s connectable burst every ~5 min; a connect that misses
the burst tail cannot complete for ~5 min, so a 15s budget guarantees
cancellation. Crude had no such timer — armed connects rode to the next
window (the field record's own "fired after 143s/290s" proves the pattern).

**M3 — No insulin automation all evening**: loans start OPEN by R23 ruling,
AND every in-loan cycle died on the missing basal schedule (REG-3, fixed in
builds 114/116) — even advisory output was dead at the party.

**M4 — "Readings initially then none" is honest provenance showing a real
outage.** With the phone's radios off there was no relay to mask anything in
either design — but crude's OWN docs record the trap: "the G7 reader was dead
for 3.5h while the loop ran happily on phone-pushed BG."

**The open mystery — the 18:37–21:11 targeted-path deafness.** From 18:27:50
the warm pending-connect path went permanently deaf (~30 windows, zero fires)
while active scans still heard the sensor occasionally (catch-rate math says
the sensor chirped normally all evening). Overnight log archaeology settled
one candidate: **no identifier rotation** (all discoveries show the same
CD6E27A4 handle; no stale-handle drops logged). Remaining candidates, ranked:
sensor bond/advertising-posture change ~18 min after the phone's slot lapsed
(timing hypothesis: last read 18:27 ≈ phone-off 18:10 + 18-min slot hold);
watchOS background duty-cycling of the passive connect; radio contention
(weakest — deafness began an hour before the WC retry storm). Experiments
E1–E3 below discriminate.

## Hypothesis verdicts

- **H1 (crude reliability partly relay-masked): CONFIRMED** — crude's watch
  loop consumed phone-relayed BG invisibly into the same store it dosed from;
  its own docs record a 3.5h dead reader that nobody noticed.
- **H2 (15s watchdog kills next-window fires): CONFIRMED** as the killer of
  the three catches; partial as blackout root cause.
- **H3 (crude had a lightweight fast-reconnect): REFUTED** — full
  J-PAKE+certs+PoP every connection in BOTH branches, deliberately (the
  bond shortcut left the link unencrypted and the sensor dropped it).
- **H4 (sensor slot/state behavior): OPEN, leading candidate** for the
  targeted deafness; 0xEA evidence insufficient (replies only exist after
  successful reads).
- **H5 (handback limbo): CONFIRMED fromstock regression** — crude guarded it.
- **H6 (standing pod connection degrades G7): REFUTED on premise** — same
  connection model in both branches; crude went 15/15 with it.

## Regressions

- **REG-1 (CRITICAL)**: unreachable hand-back limbo. Fix = WS1.
- **REG-2 (HIGH)**: 15s connect watchdog. Fixed overnight (graduated:
  heartbeat while pending, cancel only at 400s).
- **REG-3 (CRITICAL)**: grant settings missing schedules. Fixed (114/116);
  residual = grant-time validation (WS4a).
- **REG-4 (HIGH)**: reconnectMode fresh-defaults-off. Fixed (113).
- **REG-5 (LOW)**: dead legacy EGV gate + misleading log line. Cleanup.
- **REG-6 (TRIVIAL)**: stale coldReacquire comment.
- **Non-regressions (do not "fix")**: full handshake per connection; ladder
  constants 20/300/15/45/400/330; standing pod auto-connect; loans start
  OPEN; direct-only dosing store (R18).

## The synthesis plan (workstreams)

- **WS1 — Hand-back robustness** (Jeremy decision, recommended: two-phase
  stay-active drain): beginHandback keeps phase .active + dosing live, sets
  handbackRequested, drains via the existing resend/cursor machinery (which
  already re-snapshots unacked events per retry — the phase flip was never
  necessary), Cancel exposed, teardown only on fully-drained ack. Fallback:
  crude-parity reachability guard.
- **WS2 — Watchdog redesign + instrumentation**: DONE overnight (heartbeat +
  400s bound; discovery logs now include connectable flag + peripheral state;
  archaeology eliminated identity rotation).
- **WS3 — Blackout root-cause experiments** (need Jeremy/hardware):
  E1 Pi sniffer with phone off ≥45 min (does the sensor keep undirected
  connectable advertising past the slot lapse?); E2 home repro of the party
  sequence watching the ~18-min mark; E3 one session measuring whether a
  ridden connect completes at the next burst (the overnight build IS this
  experiment); E4 0xEA byte-dump diffs across phone on/off/lapsed.
- **WS4 — Functionality completion**: (a) grant-time config validation
  (deny with reason, not per-cycle death); (b) 20-min no-direct-BG
  notification watchdog during loans; (c) lastDirectGlucoseAge into
  StatusReport; (d) R20 picker (after the above).
- **WS5 — UI rebuild** (with Jeremy): the crude takeover checklist
  (UI_TAKEOVER_SPEC_CRUDE.md) in the glance design language; loop button
  (landed overnight); connect flow.

## Decisions for Jeremy (each with recommendation)

1. WS1 semantics: two-phase stay-active drain (recommended) or crude-parity
   refuse-when-unreachable?
2. During a pending drain: closed-loop dosing continues (recommended) or
   manual-only?
3. Watchdog: accept the overnight graduated form; run E3 once to confirm?
   (recommended yes)
4. Root-cause investment: run E1+E2 before the next real outing?
   (recommended yes — the deafness is the unexplained half)
5. Sensor-blackout alert: 20-min notification-only watchdog? (recommended yes)
6. Grant-time validation: deny-at-grant on incomplete config? (recommended yes)
7. Branch succession: unchanged — fromstock stays prospective mainline; both
   critical failures were fromstock-local with small fixes; crude's perceived
   reliability was partly relay-masked (H1).
8. R20 degraded-mode picker: after WS1–WS3 (recommended).
