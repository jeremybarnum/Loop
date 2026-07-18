# Part E — Loan Protocol v2 Bench Drills (D1–D23)

_2026-07-17. Companion to `DESIGN_LOAN_PROTOCOL_V2.md` §9 (the failure matrix these
drill) and `RELEASE_TEST_SCRIPT.md` Parts A–C. Every drill runs against the REAL
bench pod (M-rule: emulator runs count for nothing). On-body is a separate, per-build
authorization (risk-register #8) — nothing here goes on a person._

## Setup (once)

- **Hardware:** bench DASH pod (saline/air), phone with the from-stock build, watch
  with the from-stock build (install via the devicectl recipe; Jeremy's go-ahead per
  install). Phone and watch paired; pod paired to the PHONE as normal.
- **Surfaces:** watch → swipe past the chart to the **LOAN v2 BENCH** page
  (phase/epoch/mode/pump/odometer/fault/seq/unacked/uncertain + Request Loan / Hand
  Back / Read Status). Phone → the silent **"Pod Is On the Watch"** notification
  (long-press → **Reclaim Pod** = the escape hatch), plus the R8 alarms.
- **Logs:**
  - **Watch (on the wrist, no Mac needed):** Diagnostics page → **Logs** shows the
    unified on-device log (G7 transport + M5 loan protocol/loop via SportLog, newest
    first) with a **Share log** button (AirDrop / Messages / Mail to yourself). This
    is the primary path for a TestFlight build — its container isn't reachable via
    devicectl. Key event tags: `[loan]`, `[verdict]`, `[radio]`, `[loop]`.
  - **Phone:** Console.app or `idevicesyslog`, subsystem `com.loopkit.Loop`,
    categories PodLoanPhoneController / LoanReconciler.
  - **Either device, live:** Console.app on the Mac, subsystem `com.loopkit.Loop`
    (SportLog mirrors to the system log too).
- **G7 pre-warm (do BEFORE drill day):** when a sensor starts, the phone prompts for
  its 4-digit code and relays it to the watch; tap the watch's "New sensor"
  notification once so the pre-warm bonds it while slow is costless. With the bond
  warm, loan-start readings land within one 5-min window and authenticate instantly;
  without it, the first loan reading pays the full slow first-connection.
- **Watch HealthKit permission (first launch):** allow the workout/Health prompt on
  the watch — the background keepalive is an HKWorkoutSession and cannot run without
  it (the loop would die on wrist-down, and D16's stall watchdog would fire).
- **Reset between drills:** hand back cleanly (D-baseline below) or delete/reinstall
  both apps; check the bench page shows `idle` and the phone has no loan
  notifications before starting the next drill.
- **CUTTING THE WATCH↔PHONE LINK — do it right.** WatchConnectivity rides BOTH
  Bluetooth and Wi-Fi (bench-proven 2026-07-09: grant + hand-back completed with BT
  off, over home Wi-Fi), and iOS Airplane Mode leaves Bluetooth ON. So:
  - **PHONE-UNREACHABLE (phone stays alive):** Airplane Mode ON (kills Wi-Fi) **plus**
    Settings → Bluetooth → Off. Settings-level, not Control Center — CC only
    disconnects accessories; the radio stays up. Restore both to reconnect.
  - **PHONE-GONE:** power the phone off entirely. Cleanest; use wherever the phone
    doesn't need to be running timers.
  - **WATCH-UNREACHABLE:** watchOS Airplane Mode kills both radios (unlike iOS), or
    power the watch off. Note watch Airplane Mode also drops the watch's pod and G7
    links — fine where the drill wants the watch dark, wrong if it should keep looping.

**Already unit-tested (no bench required, but cheap to confirm live):** the epoch
race core (D22), offer-redelivery idempotency (row 10), stale-epoch drain (rows
13/14), deny-on-missing-settings, commit-then-ack ordering — `LoopTests`
`PodLoanPhoneControllerTests` + `LoanProtocolV2Tests`, 19/19 green 2026-07-17.

## D-baseline — the happy path (run first, and after any code change)

1. Phone looping normally on the bench pod. Watch bench page: `idle`.
2. Watch: **Request Loan**. Expect ≤~30 s: phone pauses dosing (Closed Loop toggles
   off), watch page → `takingOver` → `active`, pump `constructed`, odometer shows a
   number, phone posts the silent on-loan notification.
3. Let one loop cycle run (needs G7 on the watch or accept `pausedStale`).
4. Watch: **Hand Back**. Expect: page → `handingBack` → `idle`, phone notification
   clears, Closed Loop restores to its pre-loan state, Event History shows any loan
   doses with `loanv2-` sync identifiers.
5. ~90 s after close: log line `Post-reclaim re-audit: delivered X, expected Y…`
   with remainder ≤ 0.05 U and no notice.

**Pass:** all of the above; no alarm fired (R8: healthy operation is silent).

## The drills

| D# | Procedure | Pass criteria |
|---|---|---|
| **D1** LoanRequest lost | Make the phone unreachable (Airplane Mode + Settings-BT-off) BEFORE tapping Request Loan. | Watch shows `requested` then returns to `idle` on timeout; no side effects on the phone when it returns. |
| **D2** Grant lost | Request; kill the WATCH app the instant the phone pauses dosing (before takeover). | Phone T1 fires at 5 min: StatusQuery, then auto-reclaim + "Watch Loan Failed" alert; dosing restored; relaunched watch stays `idle` (late grant self-rejects on expiry). |
| **D3** Takeover fails | Put the pod out of BLE range of the watch; Request. | Watch sends TakeoverFailed ("pod unreachable at takeover"), full teardown to `idle`; phone reclaims + alert; no zombie bidder (pod reconnects to phone). |
| **D4** TakeoverComplete lost | Hard: needs WC interruption exactly post-takeover. Approximate: phone-unreachable (Airplane Mode + Settings-BT-off) during `takingOver`, restore both before T1 expires. | Phone's pre-reclaim StatusQuery gets a holdsPod report → transitions LOANED without reclaiming (query-before-reclaim). |
| **D5** Watch app killed mid-loan | Establish loan, enact once, force-quit the watch app, relaunch. | "Session Ended" alert; bench page `recoveredDrain`; records drain as a recovered hand-back once the phone acks; pod NOT resurrected by the watch. |
| **D6** Killed mid-command | During a bolus/temp enact, force-quit the watch app mid-BLE. | On relaunch: stock recovery classifies via seq; the dose lands with correct provenance in the drain; phone record matches pod truth (check odometer vs Event History). |
| **D7** Watch battery death | Let the watch die (or power off) mid-loan. | NO phone alarm before 6 h (R8 — no heartbeat). Escape hatch works: long-press → Reclaim Pod → RECLAIM_PENDING, dosing stays blocked, 1 h reminder arms, records-pending audit notice ~90 s after reclaim. |
| **D8** Phone off mid-loan | Power the phone OFF for 30+ min during an active loan (the product premise). | Watch loops unaffected; DoseRecordBatches queue; on phone return everything drains; no duplicate entries (check `loanv2-` sync IDs unique). |
| **D9** HandbackOffer lost | Phone-unreachable (Airplane Mode + Settings-BT-off); tap Hand Back on the watch. | Watch stays `handingBack`, resending every 15 s; pod stays with the watch (release only after ack). Restore both radios → single ack → clean close. |
| **D10** HandbackAck lost | Hard to force cleanly; the unit test covers the logic. Live approximation: flap the phone-unreachable recipe (both radios) around hand-back. | Eventual single clean close; Event History shows each dose once. |
| **D11** Store write fails | Not force-able without code; covered by review + the no-ack-on-error path. Skip live. | — |
| **D12** Escape hatch, watch alive | Active loan, both devices up: long-press phone notification → Reclaim Pod. | Watch gets Revoke → `revoked`, zero further pod commands, drains records; phone RECLAIM_PENDING → RECONCILING → OWNER only after drain; a running loop temp is canceled at reclaim; a bounded suspend is NOT. |
| **D13** Revoke lost | Escape-hatch reclaim while the watch is dark (watch Airplane Mode — on watchOS it kills both radios — or watch powered off). | Phone stays RECLAIM_PENDING (dosing blocked, 1 h reminder). When the watch returns: parked revoke re-sends on reachability; watch drains; stale-epoch traffic acked-as-stale. |
| **D14** Stale hand-back vs new loan | Unit-tested. Live: complete a loan, start a second, then force the watch to re-send an old offer (needs WC redelivery luck — best-effort). | Ack says stale; loan 2 untouched. |
| **D15** Version skew | Needs a mixed build; defer until a v3 exists. Protocol path unit-tested (undecodable → Nack). | — |
| **D16** Keepalive death | Kill the workout session mid-loan (or let watchOS do it). | Dead-man notification fires; pod safe (bounded temp runs out); loop resumes on relaunch via recovered path. |
| **D17** WC redelivery after reinstall | Reinstall the watch app mid-loan (dev install over it). | Queued userInfo redelivers; no assertion, no duplicate entries (epoch/ID idempotency); recovered drain proceeds. |
| **D18** DST mid-loan | Bench: set the phone's region to a timezone crossing DST during the loan window (or simulate by schedule inspection). | Temps/suspends unaffected (duration-based); any schedule assertion uses the grant timezone; reconciler's expected-insulin uses the frozen schedule. |
| **D19** Recovered journal, uncanceled temp | Kill the watch with a long temp running; escape-hatch reclaim; let records drain on relaunch. | Phone ends the orphan loop temp and records the truncation; a suspend window surfaces as suspended-until, never "back on schedule". |
| **D20** Negative remainder, exact fingerprint | Requires inducing an uncertain bolus (kill watch mid-bolus-send so the pod never gets it, with the record made under max-exposure), then dead-watch drain. | Reconciler annuls exactly the phantom event (log: annulledEventIDs); no residual notice; IOB correct. |
| **D21** Layer-3 residual | Induce a shortfall with no assumed candidates (e.g. suspend the pod out-of-band via a second controller — or accept this as fault-injection-only). | The RULED notice verbatim; records untouched. |
| **D22** Epoch race | Unit-tested green. Live spot-check = D14. | — |
| **D23** Phone-fed picker | UI-phase drill (the picker doesn't exist yet). Placeholder: kill the G7 transport mid-loan with the phone present; today expect `pausedStale` mode + no dosing (R9), which IS the ruled default behavior. | Loop pauses, no silent source switch; mode visible on the bench page. |

## Recording results

Append one line per drill to this file's log section below: date, D#, pass/fail,
notes (log excerpts for failures). A failed drill blocks on-body (design doc M5
acceptance) until fixed and re-run.

### Drill log

_(empty — first bench session pending)_
