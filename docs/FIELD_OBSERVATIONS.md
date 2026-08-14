# Field observations ledger — things seen in logs, not yet fully explained

Standing practice (Jeremy, 2026-07-20): when a log shows something I don't fully
understand, record WHAT was seen and WHEN here — with a hypothesis if one exists —
rather than forcing an explanation. Items get resolved (with the answer) or asked
about explicitly. Never silently dropped.

## Open

- **OBS-10 (2026-08-11 ~22:20, build 269 loan): relay-first ingests while D2W is live —
  Jeremy: "it seems as if it's getting the BGs from the phone even while D2W is live.
  I hope this is not a regression."** NOT new in 269: build 268 logs from the same evening
  show the identical pattern at 19:11:49, 19:16:47, 19:26:48, 19:31:48 and 21:56:52 —
  `INGEST src=phone-relay … (direct-G7 gap)` followed 1-9 s later by the DIRECT read
  arriving and being deduped (`#83 dedup … same sensor stamp`). So: same physical sample,
  direct link demonstrably alive in the same window, relay simply winning the race when
  the watch's BLE connect lands late against the grid (direct age drifting 7-20 s vs the
  relay's ~4-5 s). Phone-absent posture unaffected (no phone → no race).
  WHAT WOULD BE REAL: direct reads stopping entirely — no didRead, no dedup line. Check
  the ratio of src=direct-G7 stored=1 vs src=phone-relay + dedup across the next pushed
  loan; a drift toward 100% relay-first is worth understanding (connect-timing drift
  across the session?), but it is a race outcome, not a coverage loss.

- **OBS-9 (2026-08-11 19:12-19:34): THE LOG MIRROR CAN STALL WHILE THE WATCH IS FINE.
  Do not read the iCloud file cadence as proof of app execution.** Cost: a wrong
  safety-class diagnosis, stated confidently, corrected only when Jeremy pushed the log
  by hand.
  What I saw: `g7watch-latest.log` frozen at 19:11:49 for 20+ minutes, and — the part
  that convinced me — the per-snapshot files in the iCloud container stopping dead at
  `g7watch-20260811-191201.log` when they had been arriving every 2-3 min. I reasoned
  that if the app were merely backgrounded the snapshots would still be GENERATED and
  arrive in a burst, so no new files meant no execution. I called it a reproduction of
  #85 under Theatre Mode alone.
  What was true: the watch ran ~8 consecutive clean cycles across the whole window
  (19:16:54, 19:21:53, 19:26:54 all `computed=ok`, two temps ACCEPTED) and shipped
  snapshots at 19:15:11, 19:20:12, 19:25:12, 19:30:11 — dead on cadence. The
  phone->iCloud->Mac leg stopped delivering; nothing upstream was wrong.
  THE RULE: the file cadence in the Mac's container measures DELIVERY TO ME, not
  execution on the wrist. It is an instrument, and instruments fail. Before concluding
  the app stopped, get the log by another route (Jeremy can push it from the watch) —
  and treat "no alerts fired" as evidence AGAINST an app failure, not as a second
  failure. Both dead-men were silent here because nothing was wrong.
  Sibling lesson, same day, opposite direction: the hand-back residual (see the item-1
  validation) was an instrument error that invented a discrepancy. This was an
  instrument error that invented an outage.

- **OBS-6 (2026-08-11 18:14, build 268, epoch 10): takeoverComplete rides the QUEUED
  channel, so the phone can be minutes behind the truth about its own pod.**
  The watch had the pod at 18:14:22.463 ("ACTIVE — pod taken after 2 read(s) in 10.2s")
  and told the phone one millisecond later — on the opportunistic channel:
  `18:14:22.464 [wc] send podLoanV2 — session 2, reachable true, path queued`.
  `LoanMessage.isInteractiveHandshake` returns FALSE for `.takeoverComplete`
  (LoanProtocolV2.swift), so it goes by transferUserInfo, which iOS drains when it feels
  like it.
  PROOF it actually lagged, from this same loan: the phone's new #108 probe fired —
  "grant unconfirmed after 20s — asking the watch whether it arrived". That probe only
  runs while `state == .grantOffered`, so twenty seconds after the grant the phone still
  did not know a takeover that had completed at +10 s.
  This is odd company for the message to keep: the `isInteractiveHandshake` doc block
  says the immediate channel is for "everything the user is watching a spinner through,
  at the start and the end", and takeoverComplete is the end of the start. Consequence
  is UI and state-machine lag, not therapy — the watch is dosing correctly throughout.
  Filed as #109. Note the accident: #108's probe was built for a LOST grant and caught a
  merely SLOW confirmation instead, cutting the phone's blind window from the 5-minute
  T1 to 20 s on its first loan in the field.

- **OBS-8 — RESOLVED 2026-08-13. One behavior change + one logging fix. ZERO alert risk,
  ZERO dosing change.** Original text below. Jeremy: "that seems sloppy" — it was, and one
  of its two worries was unfounded. Calling both fixes "cosmetic" (as this entry first did)
  was wrong: skipping the idle cycle changes what the watch DOES, so it is written up as a
  deliberate divergence, not a cosmetic tidy-up.

  THE WATCHDOG WORRY IS UNFOUNDED, and this is the part worth keeping. `watchdog=HELD`
  reads as "the dead-man is armed and nobody is refreshing it", i.e. a spurious
  loop-stopped alert waiting to fire. It is not: `LoopStallWatchdog.disarm()` runs at
  every loan end (StockLoopSession, the `onLoanActiveChanged(false)` branch, reached from
  both close paths). Nothing is armed. `HELD` in those lines is the per-cycle verdict
  reporting "this cycle did not refresh it" about a dead-man that no longer exists —
  a misleading label on a disarmed thing, not a live hazard.

  WHAT WAS ACTUALLY WRONG, both now fixed:
  1. The cycle ran at all. The G7 keeps delivering after hand-back, and every reading drove
     `updateCachedEffects` + the full prediction to conclude "no pod" — forever, once per
     reading, on battery. Now `checkPumpDataAndLoop` returns early when `pumpManager` is nil
     and says so ONCE per transition. This DELIBERATELY diverges from stock (LoopDataManager
     :571 loops without a pump): on the phone, no pump is an error state worth surfacing every
     cycle; on the wrist between loans it is the normal resting state, because the phone owns
     the pod and is looping.

     VERIFIED, not assumed — the first draft of this entry asserted it, and the comment on
     `refreshPredictionForGlance` says the glance reads CACHED IOB/eventual that only a
     completed cycle refreshes, which looked like a direct contradiction. It is not:
     (a) `GlanceController.idleState` builds the idle screen entirely from the phone-fed
     `WatchContext` — BG, trend, "phone loop active" — and sets no eventual and no IOB, so
     that cached-IOB warning applies to the ACTIVE builder, not the idle one;
     (b) no live-loan window has a nil pod handle — the only two `loopManager.pumpManager =
     nil` sites are drain-complete ("loop dosing stops now") and revoke, both AFTER dosing
     has stopped, so the only cycles skipped are idle ones;
     (c) the next loan re-primes explicitly (grant sets `pumpManager` then calls
     `checkPumpDataAndLoop`; takeover calls `refreshPredictionForGlance`), so nothing
     depended on idle cycles keeping state warm.
     What DOES freeze between loans is the DOSING panel's cached IOB — correct, since the
     watch is not dosing.
  2. `computed=FAILED` was a lie. `pumpManagerUnconnected` is raised by the ENACT stage but is
     not wrapped as `.enactFailed`, so the verdict logic classified an enact refusal as a
     compute failure — a cycle whose prediction was perfect printed FAILED. The verdict now
     distinguishes the stages, so FAILED again means what it says.

  A log line that cries wolf is not a cosmetic problem, which is why this was worth the time:
  #98 built the CYCLE VERDICT line precisely so "did this cycle dose?" had a greppable answer,
  and a healthy watch printing FAILED every five minutes was training us to ignore it.

  ORIGINAL (2026-08-11 18:51, build 268, epoch 10): the watch keeps running loop cycles
  AFTER hand-back and logging FAILED verdicts. 43 s after the loan closed:
  `18:51:52 [loop] CYCLE VERDICT computed=FAILED enact=not-attempted(pumpManagerUnconnected)
  watchdog=HELD lastCompletedAge=296s`. The refusal to enact is CORRECT — `pumpManager`
  is nil'd at hand-back and the watch must not dose. But the G7 keeps delivering, each
  reading triggers a cycle, and each cycle books a FAILED verdict. Two things to check:
  the log noise (every 5 min after every loan, forever), and `watchdog=HELD` — whether
  the stall watchdog stays armed for a device that has legitimately stopped dosing, and
  can therefore fire a spurious alert post-loan. Not investigated yet.

## Resolved 2026-08-11 — #85 Focus modes are a NON-ISSUE

Jeremy: "Theatre mode and Focus modes are a nonissue."

Two arms run on build 268, both clean:
- Theatre Mode alone, ~36 min: cycles every 5 min, all computed=ok.
- Theatre Mode + Do Not Disturb, 70 min (18:55->20:04): cycles at 19:36:52, 19:41:56,
  19:46:51, 19:51:53, 19:56:54, 20:01:54 — every one computed=ok, watchdog=refreshed,
  and `lastCompletedAge` pinned at ~300 s throughout, which is the number that proves no
  cycle was skipped. Snapshots every 5 min. Both well past the ~35 min at which the
  2026-08-08 event died.

WHAT THE 08-08 EVENT PROBABLY WAS, since it was not this: it happened on build 255, and
#94 (the Code=11 connect storm behind the freezes) and #95 (carb-save -> glance ->
main-thread wedge -> watchdog kill) have both been fixed since. Either is a better
mechanistic account of a 7-hour dead app than a Focus mode. The Focus-mode correlation
was what got noticed at the time, not what caused it.

METHOD NOTE worth keeping: the first attempt to test this produced a WRONG conclusion
(see OBS-9) because the iCloud mirror stalled and I read the frozen file as a suspended
app. The arm-2 result above stands on a hand-pushed log, not the mirror.

## Resolved 2026-08-11 — OBS-7, the bolus that looked stuck

Jeremy: "the UI seems got stuck for quite a while on the bolusing, but it did complete."
The log answered it exactly, and it is not a defect:

```
18:18:29.862 [bolus-ui] flow open · ON LOAN · dial max 3.00 U (grant)
18:18:31.722 [bolus-ui] REC carb 15g (watch-local): 2.10 U
18:18:43.983 [loan] MANUAL BOLUS queued 4s behind the dosing queue (automatic cycle in flight)
18:18:43.983 [loan] MANUAL BOLUS 1.10 U — enacting on the watch pump
18:18:45.396 [loan] MANUAL BOLUS delivering 1.10 U — estimated done in 44s
```

1.10 U at the pod's hardware rate (`secondsPerBolusPulse` 2 x `pulseSize` 0.05 =
1.5 U/min) is 44 s, plus 4 s waiting behind an in-flight automatic cycle. ~48 s of
entirely legitimate waiting, and the hypothesis recorded before the data arrived was
right on the mechanism and the arithmetic.

THE ACTUAL FINDING IS A UX ONE. The app COMPUTED "estimated done in 44s" and wrote it
to the log — but Jeremy, watching the screen, read the wait as stuck. The information
that would have made it legible existed and was not on the wrist. A determinate bar or
a "≈44s" label turns "is this broken?" into "it's working". Filed with the UI
subtleties (#93 class), not as a bug.

## Closed without a root cause (2026-08-11, Jeremy's call)

All three were observed in the July 119-129 build era and none has recurred across
the many builds since — a stretch that included the connect-storm backoff (#94), the
E4-default-OFF ruling (R31), the automatic link policy and persisted sensor identity
(#101/#104), and the acquisition gate. They are being retired as no-longer-actionable
rather than as explained: nobody found the mechanism, the code they were observed
against has largely been replaced, and re-deriving them from logs that old would tell
us about a system we no longer run.

Per the standing practice at the top of this file, this is the "asked about
explicitly" path, not a silent drop. **If any of these patterns appears again it comes
back as a NEW observation with current-build evidence** — do not treat these entries
as prior art establishing that the behavior is benign.

The retired text, kept verbatim so a recurrence can be compared against it:


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

- **(2026-08-05, build 228): manual bolus during a loan WORKS — phone fully unreachable.**
  First confirmed watch-local manual bolus with `reachable false` on every line (phone BT off
  deliberately, which also removes any chance of a hand-back flipping the phase):
  ```
  08:20:21  [bolus-ui] flow open · ON LOAN
  08:20:56  [radio] reclaim waited 24.0s for the G7 handshake, then proceeded
  08:20:56  E4: reclaim starting — released=yes, idle 282s
  08:21:00  E4: pod reconnected for dose (after 2 read(s))
  08:21:00  MANUAL BOLUS 0.20 U — enacting on the watch pump
  08:21:01  MANUAL BOLUS delivering
  ```
  Anatomy of the ~15s the user perceives: **24s waiting on the G7 radio arbiter**, 4s reclaiming
  the pod from a cold 282s orphan, 1.3s delivering. The pod is NOT the bottleneck — the radio
  arbiter is, by 6x.

  This settles the three earlier failures (227 00:07:51 ×2, 228 00:18:44): all were End
  cancelling an in-flight bolus via `attemptReclaimRead`'s `guard phase == .active`
  (PodLoanWatchController.swift:900/:921). Bolusing during a loan is not broken. What is broken
  is that `CarbAndBolusFlowViewModel` auto-dismisses the flow after 1s and then shows NOTHING for
  the next ~15s while the radio arbiter waits — so the user reasonably reads it as hung and taps
  End, silently destroying their own dose. Fix set: (1) don't discard an in-flight bolus on End,
  (2) surface "delivering", (3) stop blaming the pod for a user-initiated abort.

- **(2026-08-05): an uncertain command blocks hand-back for up to 85s, silently.**
  Field: watch showed "records syncing" while the phone still showed "Pod on Watch" — looked hung,
  self-healed in 73s. Chain: `08:26:04 enacting temp 0.35 U/hr` → `08:26:11 temp enact FAILED —
  communication(...)` (sent, response lost ⇒ genuinely uncertain) → verdict chase opens on the
  5/20/60s ladder → End at 08:26:31 drains but `pendingUncertainEventID` blocks the record from
  streaming → four offers go out carrying `ev=0`, phone re-acks the same cursor → `08:27:41
  [verdict] chase exhausted` at exactly +85s → record streams → `08:27:44` ack, pod released.
  The state machine is CORRECT (the exhaust path exists precisely so "a WS1 drain isn't blocked
  behind a dead chase", PodLoanWatchController.swift:1805) and waiting is right when a dose is
  genuinely uncertain. The defect is silence: neither screen says a lost command is being
  confirmed or that it can take 90s. An accidental Cancel mid-sequence was incidental, not causal.
  Open ruling: collapse the chase when a hand-back is pending, since the exhaust comment itself
  says the .assumed record stands and the R22 hand-back audit settles it anyway.

- **(2026-08-05, build 234): takeover failures — four hypotheses ruled OUT, one piece of evidence still missing.**
  4 failures in 6 takeovers, every one identical: 14 reads, ~113.5s, `lastFail=CBErrorDomain#11`
  (connectionLimitReached) on all 12 trail entries, with `held[devices=1(conn 0/ing 0/dis 1)]` —
  our own pod central holding a peripheral but nothing connected.

  RULED OUT, each on data rather than argument:
  - *G7 contention* — on failures `pod takeover holds the radio — G7 standing down` fires and then
    NOTHING for 114s: no mid-flight handshake, no yield, no attempt. On successes the G7 releases
    within 6-8s. The G7 is not holding the slot.
  - *Aggressive retry* (Jeremy's own suggestion) — no correlation. Gaps after the phone's last
    reclaim: 388s FAILED, 352s FAILED, 75s OK in 8.6s (fastest of the day), 68s FAILED, 148s OK.
    The two longest waits both failed.
  - *App/screen state* — the trail tags each attempt `@active` or `@inactive`. A single failing run
    (15:16) contains both. Overall 120 active / 204 inactive across failures.
  - *Stale peripheral handle* — that was the G7 ladder's refuted theory, but same class: the pod's
    identifier is stable and scan-adopt finds it (held[devices=1] proves discovery succeeded).

  WHERE IT FAILS, precisely: not discovery — CONNECT. Crude's takeover
  (PodController.takeOverExternalPod) scanned with a 25s deadline and failed at *discovery*
  ("pod addr not found in scan within timeout"). From-stock finds the pod and cannot connect to it.
  Different failure, different subsystem.

  TWO CANDIDATES LEFT, and the watch log cannot separate them:
  1. The phone never actually released. `GRANT +3s — pod BLE released=true` reports
     `state.podConnectionReleased`, a flag set synchronously — never an observed disconnect.
     NOTE crude's phone side is the SAME shape (releaseConnection with no verification,
     WatchDataManager :676), so this is not by itself the from-stock regression.
  2. We exhausted our own connection slots. From-stock does `pump rebuilt` on every takeover —
     a fresh OmniPumpManager -> BlePodComms -> BluetoothManager -> CBCentralManager each time.
     Crude reused ONE PodController and swapped podComms inside it. Abandoned centrals would be
     exactly the "elsewhere" that peripheralCensus is blind to. CAVEAT: a count-of-centrals-vs-
     outcome test on 227/228 showed no correlation, so this candidate already survived one
     failed test and must not be treated as the answer.

  DECIDING EVIDENCE (not yet obtained): the PHONE's os_log during a failed takeover — either a
  sysdiagnose taken within a minute of the failure, or (better) `log stream` with the phone
  cabled to the Mac, which lets a takeover be watched live. That shows whether the phone's
  CoreBluetooth actually issues the disconnect at grant. Until then both candidates stand.

  Also: the takeover failure MESSAGE is wrong and a rewrite is deliberately POSTPONED until the
  cause is known (Jeremy). It says the pod may be far away or asleep and that it "didn't answer" —
  but the pod is on the body, awake, and talking to the phone. What failed is the handover.
  His wording: "Sport Mode initiation failed. Phone still controls pod. Try again after 30 seconds."

- **(2026-08-05, build 234): #47 field-validated.** Jeremy confirmed on the wrist: prediction graph
  populated on the stock watch screen, recommendation present on the standalone bolus screen,
  auto-return to the glance after carb/bolus. The single fix — refusing the phone's context during
  a loan and publishing the watch's own — lit up all of them, as predicted. Two items partially
  land: the pod bolusing status on the glance works but "needs work" (UX refinement pending), and
  the recommendation on the CARB screen does not work at all, because that path is architecturally
  different (see below).

- **(2026-08-05): the carb→bolus recommendation still asks the PHONE, and that is the remaining gap.**
  Two screens, two data paths, only one fixed:
  - *standalone bolus* reads `activeContext.recommendedBolusDose` — #47 now fills it from the
    watch's own `recommendManualBolus`. WORKS.
  - *carb→bolus* calls `sendPotentialCarbEntryMessage` (CarbAndBolusFlowViewModel :208), which asks
    the PHONE "what would you bolus for these carbs?" and applies the phone's whole reply context.
    Wrong twice over during a loan: the phone cannot answer when out of range (sport mode's entire
    premise), and when it can, it computes from ITS IOB/COB — blind to everything the watch has
    dosed since takeover. Worse, the reply calls `updateContext` with a phone-authored context,
    which #47's gate now refuses, so on 234 the path is doubly dead.
  The fix is the Stage-2 work Jeremy scoped early: compute the potential-entry recommendation
  locally on the watch. The watch already has `recommendManualBolus`; the difference is layering
  one unsaved carb entry onto the carb effect before predicting. Jeremy 2026-08-05: this is the
  MORE common user action than a standalone bolus, so it matters more than its position implies.

  UI note (verified, no work needed): both screens render the same `BolusInput` view — "REC: N U"
  in insulin colour under the dial, and `handleNewBolusRecommendation` (:336) pre-fills the dial
  when the user has not started dialling. Sport mode uses stock's flow unmodified; only the data
  source differs. So a fix at the data layer lights the whole screen with no view work.

## 2026-08-11 — first-connection-after-install vs steady-state (Jeremy, build 267)

Jeremy: "I do wonder whether potential users will need to have their expectations
managed about the first connection after install versus later ones."

The two sessions four minutes apart that prompted it:
- Start tapped ~4 s after the 267 install: the GRANT was lost in transit (the reply
  raced the relaunched app's WCSession activation — #108), the request timed out at
  25 s, and the retry was correctly DENIED ("pod still returning"). Felt sluggish;
  needed a second Start.
- After a force-quit and a settled relaunch: grant 15:06:24 → pod taken in 13.5 s →
  R33's own temp ACCEPTED at 15:06:40 → first direct-G7 reading 15:06:46. Sixteen
  seconds from grant to dosing, glucose at twenty-two, because the persisted sensor
  identity (#101/#104) skipped the acquisition lottery.

The product point: a real user's FIRST experience compounds every cold path at once —
no persisted sensor (acquisition can take minutes against D2W's ride windows),
HealthKit prompts, WCSession's first activation — exactly when their expectations are
least anchored. Steady state is seconds. R24 already rules the connect UX (determinate
takeover bar + G7 ETA); what it does not cover is FIRST-RUN framing — one-time copy in
the spirit of "first connection can take a few minutes; after that it's seconds".
Parked as a pre-production UX item alongside R27's deferred list, not scheduled.

## 2026-08-11 — the watch cannot talk to the pod at hand-back (epoch 9, build 267)

A clean 17-minute loan — 4 cycles, no enact failures, no stalls — that nonetheless
showed the whole end-of-loan problem in three consecutive log lines:

```
15:22:06.978 [loan] E4: pod re-released after dose (+12s settle) — state connected -> disconnected (+3s)
15:23:36.514 [loan] HAND-BACK requested — draining 4 events; still in control (WS1)
15:23:37.131 [loan] hand-back: temp CANCEL FAILED — … PodCommsError.podNotConnected
```

The cancel was attempted 1 ms after it was logged as starting. That is not a failed
round-trip; it is the absence of a link to make one on. Eighty-nine seconds earlier the
watch had deliberately released the pod after its last dose, which is the design.

The 245 ms to the final offer says the odometer freshen failed the same way, and the
audit duly printed `fresh=N` — as it has at every hand-back on record. **One cause, two
symptoms**: at hand-back the watch cannot command the pod and cannot read it, because by
then it is not connected to it. No watch-side fix reaches this. A hand-back essentially
never coincides with a dose window.

Both jobs moved to the phone, onto the reclaim round-trip it was already performing and
already throwing away (#42's chase). See R33's hand-back half and
`PodLoanPhoneController.finishPendingHandbackAudit`.

The audit that ran: `delivered=0.400 expected=0.450 residual=-0.050 (tol 0.05)`, exactly
one pulse, at the tolerance floor, negative (we booked marginally more than the pod
delivered — the conservative direction). This is the first audit computed with #107's
pulse model, and one pulse is the smallest discrepancy the model can express: it is the
boundary pulse, ambiguous by construction. But note it was measured against an endpoint
~90 s stale, so the number is only as good as its bracket — which is precisely what the
change above fixes. The next loan's `reconcile[AUTHORITATIVE]` line carries a
`vs watch endpoint` delta that says how much this mattered.

Also seen, and probably a false alarm in my own instrumentation:
`[cob-diff] REPLACE 3 entries · phoneCOB=12.0 g · watch COB(post)=14.85 g ·
Δ(post−phone)=+2.83 g ⚠ residual (wipe failed?)`. `phoneCOB` is
`grant.predictionSnapshot?.cobGrams` — a snapshot, and the sibling `[iob-diff]` line on
the same grant reports `phoneIOBAge=98s`. So this compares a fresh watch COB against a
98-second-old phone COB, over 41 g of actively absorbing carbs, with the watch value
additionally being a pre-settle static read (the comment at the call site already says
so). The ⚠ threshold of 2.0 g does not account for snapshot age. Not chased; noted so
the next reader does not chase it either.

## 2026-08-11 — #108 fixed: the lost hand-over now takes ~20 s to detect, not 5m15s

The failure Jeremy hit installing 267 (Start tapped ~4 s after install): the phone agrees
to the loan, stops its own dosing, releases the pod's BLE link — it must, the pod talks to
one device at a time — and then the grant is lost in transit. Nobody holds the pod. It
keeps delivering its last program autonomously, so there is no hazard, but no loop is
adjusting anything on either device.

Recovery was `armT1`: wait 5 minutes, ask the watch, wait 15 more seconds, reclaim. A
message lost in the first second cost 5m15s, and a re-Start inside that window is
correctly refused ("pod still returning"), which reads as the app being stuck. Jeremy
force-quit rather than wait.

WHAT THE FIX HAD TO CREATE FIRST. The plan was "ask early, act only on a definitive no."
But there was no definitive no to act on: `handleStatusQuery` opened with
`guard let current = epoch, query.epoch == current else { return }` — a watch that never
received the grant has no epoch, so it answered **nothing**. The single case the phone most
needed to hear about was the one case the protocol was silent in.

So the watch now answers, with `StatusReport.knowsGrant` (optional; nil = an older build
that could not say). Two guards before it claims ignorance, because a wrong "no" makes the
phone snatch the pod back mid-takeover:
  - `phase != .active` — never claim ignorance while actually holding the pod
  - `epoch < query.epoch` — only when we are BEHIND the phone; a query for an epoch older
    than ours is a stale message and still gets silence

The phone probes once at 20 s and acts on `knowsGrant == false` only. Written `== false`
and not `!= true` on purpose: nil is "could not answer", and must fall through to the
unchanged 5-minute timer. Silence is still not a denial.

Note the asymmetry that made this cheap: being generous with a TIMER and being slow to ask
a QUESTION had been conflated. Only the timer needed to be generous.

Not yet field-proven — reproducing it needs an install-then-immediately-Start, which is
exactly the sequence that produced it once.

## 2026-08-11 (build 269) — e15 is the loan the item-1 redesign was built for

Three loans on 269, all clean, but only the third one is interesting.

```
e13  reconcile[provisional]:   delivered=0.950 expected=0.950 residual=-0.000
     reconcile[AUTHORITATIVE]: delivered=0.950 expected=0.950 residual=-0.000 · vs watch endpoint +0.000
e14  reconcile[provisional]:   delivered=0.000 expected=0.000 residual=+0.000
     reconcile[AUTHORITATIVE]: delivered=0.000 expected=0.000 residual=+0.000 · vs watch endpoint +0.000
e15  reconcile[provisional]:   delivered=0.300 expected=0.800 residual=-0.500
     reconcile[AUTHORITATIVE]: delivered=0.800 expected=0.800 residual=+0.000 · vs watch endpoint +0.500
```

e15's two lines disagree by half a unit, and the provisional one is wrong. At drain time
the watch's last odometer read was `fresh=N` — stale, as it is at every hand-back, for the
reason documented above (no link to read the pod on). The phone's own read, +3 s after the
reclaim round-trip, saw the full 0.800.

**Had the provisional number been the verdict, R32(b) would have fired.** −0.500 sits
exactly at `warnNegativeResidual`, so the loan would have ended with a "we may have booked
more than the pod delivered" warning on a hand-back that was in fact perfect. The residual
bank would have recorded −0.500 as its worst sample, and the n=10 threshold review would
have been calibrated against an artifact of measurement lag.

This is the second occurrence (the first was `-0.050`, one pulse, at the tolerance floor —
same direction, small enough to look like quantization). The direction is not random: a
stale endpoint can only ever *undercount* delivery, so the provisional number is
**biased negative**, and the bias scales with how much was delivered late in the loan. e13
and e14 agree to +0.000 only because neither had a dose near the end.

The bank stores the authoritative value, so it is uncontaminated: n=5, mean −0.040, worst
|0.200|. Keep it that way — if the provisional line is ever promoted to a verdict, this
entry is the counterexample.

Also on e15, and not a defect: `[override] SKIPPED (already applied) 🕺 crashy`. The phone
already had that override on, so the resume had nothing to do. Worth knowing the line is
the healthy path, not a dropped write.

## 2026-08-12 — R35 and #112 both VALIDATED in the field (build 270)

Two rulings closed by two loans. Recorded because both were open on my side longer than the
evidence warranted, and the second one had a decisive probe I did not think to ask for first.

**R35 (config-only DoseStore, no fallback) — e22, 3 cycles, 13 min.** The ledger was the only
insulin book and dosing ran off it end to end:

```
[ledger] seeded — 123 doses (122 finished + 1 live)
insulin books rebuilt from grant — 122 records (ledger seed, R35)
[iob-diff] phoneIOB=0.99 seedIOB=0.99 cycle1=0.99 · Δ(seed−phone)=-0.00[wire] · Δ(cycle1−seed)=+0.00[reconcile]
[iob-decomp] @SEED-IN Σnet=0.885U n=123 … @CYCLE1 Σnet=0.885U n=123
```

Three cycles dosed off ledger IOB (0.99→3.00 U/hr, 1.18→2.90, 1.26→1.80, all ACCEPTED), ZERO
ledger refusals in 289 lines, clean hand-back, and the phone's authoritative reconcile came in
at `delivered=0.400 expected=0.400 residual=-0.000`. The seed matched the phone to 0.00 at the
wire and to 0.00 across the first cycle — the two seams where a second book would have shown.

**#112 (override applies to the ledger's BASAL BASELINE, not just ISF) — the following loan.**
The probe is one field. `[iob-decomp]`'s `sched=` reads from
`basalRateScheduleApplyingOverrideHistory`, so under an override it must show the SCALED rate:

```
[override] APPLIED 🕺 crashy · insulin needs 52% (basal x0.52, ISF x1.92, CR x1.92)
sched=0.36  × 199 rows        (0.70 × 0.52 = 0.364 ✓)
sched=0.70  × 1054 rows       (pre-override history, correctly raw)
```

BOTH values in one log, split exactly at the override boundary. Unfixed, every row reads 0.70.

**Why this one needed the specific probe.** #112's bug was invisible in the headline numbers:
ISF was ALREADY override-applied, so eventual-BG and the recommendation looked right the whole
time — only the temp-netting baseline was raw, which moves IOB subtly. "Looks reasonable" is
precisely the symptom the unfixed code produced, which is why the decomp field, not the
dosing line, is the thing to read.

Also of note: the -0.60 `[iob-diff]` wire leg seen on build 270 earlier has NOT recurred —
both of these loans show -0.00. It has no reproduction and no explanation; leaving it recorded
rather than chased.

## 2026-08-12 (e27, MIXED BUILDS 270/271) — R32 review due; a phone-side write pile-up

Jeremy ran this loan with different builds on the watch and phone, so attribute carefully.
Two findings survive that caveat, and one does not.

**1. R32 THRESHOLD REVIEW IS DUE — the mechanism fired as designed.**

```
residual bank: n=11 mean=-0.036 worst=|0.200| min=-0.200 max=+0.000
** R32 THRESHOLD REVIEW DUE — 11 authoritative samples banked; the ±0.50 U bounds were set with none **
```

All 11 samples lie in [−0.200, 0.000] — not one positive. The ±0.50 U bounds are ~2.5x the
worst observed.

**Do NOT simply tighten to the observed range.** The residual is quantization-driven (#107:
~0.5 pulse ≈ 0.025 U per temp replacement), so its scale is a function of HOW MANY temps a
loan replaced, not a constant. Every banked sample is a short bench loan (1-21 min, 1-11
cycles); an overnight loan runs ~140 cycles. A fixed bound tuned on these is simultaneously
too loose for a 3-cycle loan and a false-alarm generator for a long one. The right shape is a
threshold that scales with cycle count, with a floor. That is a design decision, not an
arithmetic one.

**2. THE PHONE STARTS ONE WRITE PER DUPLICATE OFFER — no in-flight guard.**

The watch sent THREE offers on its normal ~15 s cadence (20:41:14, :29, :44). The phone logged
TWELVE receipts and started a Core Data write for every one:

```
write DONE 19313ms · 18444ms · 13385ms · 12968ms · 12387ms · 12286ms · 10213ms · 8074ms · 7948ms · 7931ms · 3019ms
```

Eleven concurrent writes for the SAME single-dose offer, 3-19 seconds each, all completing in a
400 ms burst. It self-amplifies: slow writes → no ack → the watch resends → more writes.

The 4x receipt amplification is NOT attributable with mixed builds in play. The phone's
response to it is, and it is version-independent: whatever produces duplicate offers —
redelivery, resend, version skew — the commit path should collapse them rather than launch a
write per copy. Correctness held throughout (cursor 1, one dose committed, dedup intact), so
this is latency and robustness, not lost or doubled insulin.

**SEVERITY CORRECTION (2026-08-12 23:30 — see #119 below).** "Latency, not insulin" was true
of THIS loan only because its offer happened to carry doses and no carb. Doses survive a
pile-up via raw-dedup at the store; CARBS HAVE NO STORE IDENTITY, so the identical storm with
a carb aboard multiplies it once per copy. Three hours after this entry was written, exactly
that happened: 12 phantom copies of one confirmed 10 g entry, 120.7 g of COB, max basal. The
pile-up was never merely a latency bug — it was a data-poisoning bug whose trigger had not
yet carried a carb.

Deliberately NOT fixed in the build this was found in: an in-flight guard on the dose-commit
path is a concurrency change that deserves a test, not a late edit on top of an otherwise
clean build.

FIXED the same night as #118, in the following build: one commit in flight at a time;
duplicates coalesce (latest per epoch, a final never displaced by an interim) and replay
after the completion; a force-reclaim arriving mid-write defers behind it — closing the
adjacent #66-family hazard where it re-committed identity-less carbs. Three two-sided tests;
sabotage-verified (guard removed: four writes for four copies, and the carb doubles). One
consequence worth knowing when reading logs: duplicate offers can now MERGE, so N delivered
copies may produce fewer than N acks — the watch's resend loop converges regardless.

**3. FIRST `fresh=Y` ON RECORD — and it confirms the staleness diagnosis.**

`reconcile[provisional]` and `reconcile[AUTHORITATIVE]` agreed EXACTLY (both −0.150), with
`vs watch endpoint +0.000`. Every prior loan was `fresh=N`, and those are the ones where the
two diverged (e15's −0.500 vs +0.000). Direct evidence that the provisional/authoritative gap
is a measurement-staleness artifact rather than a disagreement about delivery — exactly as the
2026-08-11 entry predicted, now with the positive case.

## #119 (2026-08-12 22:19, build 272 phone): 12 phantom carb copies — the #118 pile-up with a carb aboard

Jeremy's report: a G7 outage with the phone off; phone cycled off/on twice; ~10 duplicated
carb entries appeared. His worry: "carbs are supposed to require confirmation." Both logs in
hand, the chain is complete, count-for-count:

1. **21:33** — e29 granted. **21:35:25** — ONE 10 g carb entered on the wrist, confirmed
   once, journaled `seq 1, event E291453B`.
2. **Phone off.** The watch (in `recoveredDrain` after its own relaunch) offered every ~15 s:
   `hand-back offer attempt 1 … 12`, every send `reachable false, path queued` — **twelve
   copies of the e29 offer queued in WCSession**, each carrying the same carb event.
3. **22:19:31** — phone reachable; iOS flushed the whole queue into the freshly woken
   build-272 phone. Pre-#118, each copy computed its carb set from `committedIDs` BEFORE any
   completion had updated it → **each committed the carb**. `CarbStore.addCarbEntry` mints a
   fresh syncIdentifier per add, so: 12 entries, 12 UUIDs, all `10 g @ 21:35:17`. (This is
   also why the duplicates LOOK like independent entries — the identities are minted at
   commit, not carried from the wrist.)
4. **The poison propagated.** The 22:27 e30 grant seeded the watch with the phone's carb
   history: `phoneCOB=120.7 g`, `eventual 1150` — and the watch dosed **max basal 3.55 U/hr
   for ~7 minutes** (≈0.4 U above schedule; IOB clamp headroom 5.1 — the clamp was nowhere
   near binding) until Jeremy deleted the 12 duplicates on the wrist at ~22:34, at which
   point eventual collapsed 1086 → 89 within a minute.
5. **Cleanup held end-to-end:** the 12 delete records rode the e30 drain at 23:21 and the
   phone applied all 12 (the R30 delete flow, working under exactly the load it was built
   for). Both books ended clean.

**On the confirmation worry — no bypass.** One entry was confirmed once. The duplication is
transport-level re-commit of that confirmed event; nothing skipped a confirmation screen.
That is materially better than a UI bypass, but the OUTCOME still matters: phantom COB drives
dosing in the aggressive direction, bounded only by maxBasal and the IOB clamp.

**Status: CLOSED BY #118**, which shipped ~90 minutes after this incident occurred. With the
guard, the flushed queue coalesces behind one write and replays as no-ops; the pile-up test
now carries a carb and asserts it stays exactly one (`testDuplicateOffersDuringASlowWrite\
CollapseToOneCommit`). The fix is PHONE-side — the incident build (272) does not have it;
the build uploaded at 21:54 does.

**Defense-in-depth candidate, documented not built:** carry the watch's carb event identity
into the phone's carb commit as a dedupe key, so no future concurrency hole can multiply
carbs. Needs thought about the CarbStore surface (stock mints identity per add, by design);
parked rather than rushed — #118 closes the known mechanism, and R-series discipline says no
new safety machinery without a ruling.

## 2026-08-13 02:13 (e36, build 274) — OBS-9: force-reclaim resumes CLOSED LOOP without ever asking the pod

Jeremy's deliberate safety test, and the most valuable one run so far: start a loan, power the
phone OFF, deliver a 1 U manual bolus on the watch, power the WATCH off, power the phone back
on, then force-reclaim from the phone WHILE THE WATCH IS STILL OFF. Bench rig — water pod, not
on his body.

Expected (his): the phone notices an odometer discrepancy and throws an error.
Observed: no error he could see, and yet the phone came back with the RIGHT IOB.

**Where the right IOB came from — NOT the odometer.** Odometer-derived IOB injection is still
gone, as ruled: `PodLoanPhoneController` :113 ("no odometer insulin is injected", removed
2026-07-27) and :1179 ("stock never injects odometer-derived IOB"). `forceReclaimToOwner`
builds its reconciler input with `odometer: nil` (:1521) under the comment "reconcile staged
events records-only (no odometer)".

**RESOLVED 2026-08-13 by a clean re-run (e37): TIMELINE (b). There is NO bolus injection — the
phone does not get the dose until the watch comes back.** Jeremy re-ran the test controlling the
overlap ("I must have done something wrong before... As you expected, there is no bolus
injection"). The first run must have had a window where both devices were awake; this one does
not, and it is unambiguous in the logs.

THE PROOF, the exact line called for above:

    watch 02:29:03.146  MANUAL BOLUS 1.05 U — enacting on the watch pump
    watch 02:29:04.397  [handback] stream: 2 event(s)      <- enqueued, phone off, cannot land
    watch 02:29:04.519  [glance] RENDER iob=4.95           <- was 4.11 before the bolus
    ...watch dark from ~02:35:37...
    watch 02:36:33.712  REVOKED — phone reclaimed the pod, draining records
    watch 02:36:33.716  [phone] reclaim VERIFIED — pod round-trip complete +44s
    phone 02:36:34.024  e37 offer RX ev=2 released=final state=owner
    phone 02:36:34.046  e37 write START 1 dose(s) (final=true)      <- THE BOLUS, ARRIVING NOW

`state=owner` with the FIRST offer writing `1 dose(s)` is decisive: the phone had already
force-reclaimed and was looping, and the bolus reached it only when the watch was powered back
on. Under timeline (a) this line would have read `0 dose(s)`, exactly as the 02:17:31 excerpt
from the earlier run did.

The exposure window here was about 45 seconds — the relayed `reclaim VERIFIED +44s` at
02:36:33.716 puts the phone's reclaim at roughly 02:35:49, and the dose landed at 02:36:34 —
because Jeremy powered the watch straight back on. THAT IS THE ARTIFACT OF THE TEST, NOT THE
BOUND. In the scenario this actually models — a watch battery dying mid-session, which Jeremy
rightly calls "a pretty common situation" — the window runs until the watch is charged and
booted. Hours, not seconds, with the phone closed-loop dosing the whole time while
under-counting IOB by the full undelivered amount.

Second field judgement from the same run: **the warning is too quiet.** The "Sport Mode Reset"
notice is an ordinary notification, easily missed — he found it in Notification Center after the
fact, four minutes old, and only because he went looking.

=== TOMORROW'S AGENDA (Jeremy, deferred deliberately — do not build tonight) ===

1. LOUDER, MORE VISIBLE WARNING for this exact scenario: forced reclaim + no streaming + watch
   unreachable. Ordinary `issueNotice` is not enough. Candidates: the `.timeSensitive` treatment
   LoopStallWatchdog already uses, a persistent on-screen state rather than a one-shot banner,
   and/or letting R32's open-loop carry the message (an open loop is self-announcing).

2. FORCED INJECTION — Jeremy: "I'm pretty tempted to simply inject the odometer gap as a recent
   bolus in this scenario. It's conservative and correct."

   IMPORTANT PRECEDENT, and it favours him: this is not a new idea proposed against a standing
   ruling, it is the standing ruling's own re-enable condition being met. The 2026-07-27
   odometer ruling turned injection OFF and said re-enable "if/when the reconciliation warning
   is redesigned with a proper threshold". R32(c) (2026-08-13) just set that threshold from data
   (±0.20 U, n=13). The precondition is satisfied, so R32's "odometer-derived IOB injection
   remains OFF and unruled" is ripe for revision rather than an obstacle.

   Design questions to settle before building:
   - WHEN to date the injected dose. The gap accrued across the whole loan; booking it all as a
     bolus at reclaim time front-loads IOB. That errs toward MORE apparent IOB and therefore
     LESS dosing — conservative in the same direction as the injection itself — but it misshapes
     the curve, and #107's pulse arithmetic already supports a better-founded split.
   - WHAT the gap actually is. `expected` must be the pulse-quantized figure (#107), or basal
     the phone never knew about masquerades as unattributed bolus.
   - INTERACTION WITH THE RETURNING WATCH, which this run proves is real and not theoretical.
     The watch DOES come back and its offer DOES commit in `.owner` — that is literally the
     `write START 1 dose(s)` above. So an injected dose must carry identity the real record
     dedups against, or the same insulin lands twice: the #119 failure mode with insulin in
     place of carbs. `NewPumpEvent.raw` is the existing lever, and the pod-minted syncIdentifier
     is what the real record will arrive carrying.

3. THE OPPOSITE DIRECTION — odometer says LESS than the books. Jeremy: "maybe it doesn't matter,
   although we should think about how that odometer error will carry forward." Nothing can be
   un-injected; the books carry phantom IOB, the loop runs cautious, and it decays within DIA.
   The open question is whether an uncorrected negative gap persists into later loans' baselines
   rather than washing out — worth tracing before assuming it is self-limiting.

=== original analysis follows (kept as the reasoning trail) ===

CAUSE NOT YET ESTABLISHED — and the first answer written here was wrong. It said "the staged
event replay", i.e. that the watch had streamed the bolus to the phone and force-reclaim wrote
it. Jeremy immediately challenged the premise: he ran the test so the phone and watch were
never awake at the same time after the handoff, and streaming requires exactly that. He is
right that the explanation needs it, and checking the guard makes it worse for that theory —
`handleBatch` (:986) accepts a batch only while `state == .loaned || .reclaimPending`, so once
force-reclaim sets `.owner` every streamed batch is DISCARDED. Post-reclaim streaming cannot be
the source either.

Two candidate timelines remain, and they have very different safety meanings:

(a) The events were staged BEFORE the phone powered off (the loan ran from 02:02:18, so temp
    basals and possibly more were streamed in that window), `staged` is persisted across the
    reboot, and force-reclaim wrote them at 02:13. Benign — the books were complete when the
    loop resumed.

(b) The phone held NOTHING for the bolus at 02:13, and the records only landed when the watch
    was powered back on at ~02:17:30 and flushed its queued offer. In that case the phone ran
    CLOSED LOOP from 02:13 to 02:17:30 under-counting IOB by a full unit — dosing on top of
    insulin that was really there. The hypothetical failure in the finding below would then be
    something that actually happened in this test, not a thought experiment.

The available phone log CANNOT distinguish them: it begins at 02:17:31.034, already `.owner`,
and its first write says `0 dose(s)` for an offer carrying `ev=3`. Under (a) those 3 were
committed at 02:13; under (b) they were committed by an earlier offer in the same wake-up
burst, a fraction of a second before the excerpt starts. Both produce identical lines here.

THE DECIDING ARTIFACT is a `write START 3 dose(s)` line and its timestamp — 02:13 means (a),
02:17:30 means (b) — which needs the phone log covering 02:02 to 02:17. Also note the
notification only proves force-reclaim had SOME non-empty staged set, not that the BOLUS was
in it; early-loan temp basals satisfy `if !events.isEmpty` just as well.

**The error DID fire; it just is not phrased as one.** The "Sport Mode Reset — A previous watch
loan was ended without a clean hand-back; its records were saved" notification is
`deps.issueNotice` at :1572, and it sits INSIDE `if !events.isEmpty`. So its presence is proof
the staged path ran with a non-empty set. Jeremy saw it in Notification Center, 4 minutes old.

Corroborating arithmetic, all three independent: watch `[glance] RENDER iob=3.52` at 02:02:38
and `[bolus-ui] flow open · ON LOAN` at 02:02:44 (the watch log ends 02:02:47, right as he
opened the dial — the mirror stopped when the watch went off, so the delivery itself is not in
any log we have); phone screenshot 02:17 showing IOB 4.3 U, i.e. 3.52 + 1.0 decayed over ~15
min; and the phone log at 02:17:31 already `state=owner`, writing `0 dose(s)` for the returning
watch's final offer at cursor 3 — nothing left to commit because it had all landed at 02:13.

**THE FINDING. R32 never ran, and on this path it structurally cannot.** Force-reclaim writes
its books and then calls `setAutomaticDosingPaused(false)` (:1578) — closed loop resumes —
having never compared those books against the pod. The odometer is RIGHT THERE: `reclaimConnection()`
is called on the next line (:1575), so the phone has the pod link back. R32's machinery exists,
was just tightened to ±0.20 U, and is bypassed entirely here because the input carries no odometer.

Why that matters, in the dangerous direction: this path trusts that the stream kept up. It did
this time. If the watch had died with a delivered-but-unstreamed dose, the phone would resume
closed-loop dosing UNDER-counting IOB — and under-counted IOB means dosing on top of insulin
that is really there, i.e. stacking toward a hypo. That is precisely the failure R32(b)'s
positive branch exists to stop, and precisely the case where the pod's own odometer would have
caught it, because the pod always knows what it delivered.

Note the test did not prove the path safe. Under timeline (b) it actively demonstrated the
failure. The 4-minute window between the force-reclaim at 02:13 and the watch's return at
02:17 is exactly the interval in which the phone was looping on unverified books.

PROPOSED (needs a ruling — this is a safety behavior change, not a bug fix): after force-reclaim
writes the staged events, read the pod odometer and run the SAME `applyReconciliationVerdict`
against expected-from-staged-events. Over-delivery beyond +0.20 U → R32 OPEN LOOP, which is the
already-ruled remedy for exactly this uncertainty. Under-delivery → warn, per the existing
asymmetry. The alternative reading is that force-reclaim should open the loop unconditionally,
since "the watch vanished mid-loan" is the definition of an unclean hand-back — R32's own text
says the loop goes open when a hand-back "cannot be established as complete", and this one
cannot be, however good the records look.

## 2026-08-13 21:16-21:20 (e49, build 278) — THE BATCH FIELD-VALIDATED in one genuine dead-watch run

The first dead-watch run on 278 was the real thing: the watch took the loan at 10% battery and
died mid-session with a 1.00 U bolus and a 10 g carb aboard, phone off. Every fix in the batch
executed on its first field opportunity, phone log timestamps:

    21:16:43  SALVAGE — 2 dose(s): 0.000 U bolus + 2 rate record(s) (0.460 U gross programmed)
    21:16:45  reconcile[FORCE-RECLAIM] delivered=1.050 expected=0.150 residual=+0.900 · odometer +2s
    21:16:45  R37 OPEN LOOP · gap BOOKED 0.90 U — ONCE (e42/e44 printed it twice)
    (no residual-bank line — the +0.900 stayed OUT of the R32 calibration set)
    21:20:03  watch returns · write 3 dose(s) · backfill 5 loan-window dose(s) (e44 boundary) · ACK
    21:20:03  gap RETIRED — 3 real dose(s): 1.00 U bolus + 2 rate record(s) (0.72 U gross
              programmed, pre-truncation) + 1 carb; the 0.90 U estimate replaced
    21:20:05  duplicate offer (WC redelivery) → write 0 dose(s), backfill re-ran in 6 ms, re-ACK
              — the upsert's idempotency proven under real transport redelivery

The arithmetic closes: pod measured 1.050 U in the phone-absent window; the salvage expected
0.150; the placeholder banked the 0.900 gap; the journal's real records (1.00 bolus + temp
pulses) replace it and the books land on the odometer. The e44 failure mode — books 0.600 vs
pod 0.850, temps silently dropped at the boundary — did not recur: the backfill line is it
being prevented, live. The salvage line's bolus/rate split answered "was the bolus in the
set?" at a glance (no), which is precisely what OBS-9 built it for.

R37's hold also showed its shape: dosing stopped from the 21:16:45 verdict until the user
re-enables — the 3.3-minute watch-dead window ran with the loop OPEN, no dosing on unverified
books.

Remaining boxes, both passive: the phone-vs-watch Eventually agreement (A2's screen proof —
no log line by design) and the next loan's SEED-IN dump, which will enumerate the healed rows.
B6 separately confirmed: the 277-era session and both 278 sessions survived as stamped
archives — the first phone-log history this project has ever retained across a relaunch.

## 2026-08-13 evening — the dead-watch review: three defects found, batch fixed, two earlier
## readings corrected

The full-day review of loans e41-e47 (three parallel forensic/trace agents, adversarial
verification, then implementation) closed out the dead-watch test campaign. What it found,
beyond what OBS-9/R37 already recorded:

**1. e44's retirement UNDER-counted — journal temps silently lost at commit (fixed: the
backfill upsert).** DoseStore's HealthKit sync drops any basal-shaped dose starting before
`getLastImmutableBasalEndDate` (boluses have an escape clause). After a force-reclaim the
salvage write and the phone's own resumed records move that boundary past the loan window, so
the returning watch's temps commit as pump events but never reach the delivery store, IOB, or
dosing. e44: books 0.600 U vs pod 0.850 — and the 0.85 placeholder R37 deleted was MORE
accurate than the records that replaced it. The commit path now re-reconciles the full loan
and upserts through `syncDoseEntries` (identity-keyed, boundary-immune), with the store's
truncation and delivered-units resolution restated locally so backfilled rows are
indistinguishable from clean-path rows.

**2. The phone's stale prediction was ICE-memo staleness, and it REACHED DOSING (fixed: the
reservoir-idiom prune).** `insulinCounteractionEffects` is an append-only memo of
observed-minus-insulin-modeled velocity. Stock invalidates it for back-dated glucose and
reservoir rewrites; back-dated DOSE writes — which every hand-back commits 30 minutes of —
never pruned it. Carbs are downstream of ICE (re-attributed wholesale on every carb change,
which is why Jeremy's "carb edits are the common case and stock must handle them" was exactly
right — they need no ICE invalidation at all), so the poisoned memo inflated COB and the
prediction until relaunch. `insulinHistoryRewritten(startingAt:)` now restates the reservoir
prune (keep bins through doseStart+10 min, the model-delay window) at every back-dated dose
write: offer commit, backfill, gap retirement, salvage.

**CORRECTION to the earlier "quiescence" reading: the engine did NOT stand down at 15:11.**
The 15:17 grant seed shows a SECOND max-rate temp (3.55 U/hr) issued at 15:11:47 — the 11-min
continuation-interval re-issue slot — running until the takeover pulled the pod at ~15:17:51.
Its ~0.36 U IS the "unexplained 0.3-0.4 U odometer gap" from the earlier entry: explained,
booked late because the mutable segment was still live when the pod left. Consequence, stated
plainly: the 14:51:44 automatic temp WAS computed on the poisoned prediction (there is no
separate render cache — the engine and the UI read the same LoopDataManager state), and the
engine max-temped for ~26 minutes (~1.5 U gross, vs a correct-books recommendation of
roughly zero) until an external event stopped it. Water pod; on a body this would have been
the anti-conservative direction twice over (under-counted IOB from defect 1 stacking with
inflated COB from defect 2).

**3. Assorted, same batch:** stock LoopKit's `addDoses` fired its completion twice per success
(the duplicate "gap BOOKED" lines; latent false "NOT in the books — dose by hand" alarm on an
HK sync failure) — single-fire now, with the old test tolerance turned into a tripwire. The
retire/salvage lines summed gross programmed temp content as if delivered (e44's impossible
"1.53 U" — historic logs before this date carry that overstatement; read them as gross
programmed). The R32 residual bank was banking force-reclaim gaps (+0.800/+0.850) into the
clean-hand-back calibration set — handback-only now, contaminants purged one-shot. The phone
log mirror destroyed its previous session at every launch (twice on this date; the second
destruction hid the second temp above) — stamped archives now, keep 20.

Validation: the ICE tests pin the statelessness contract mechanically (T3: pruned-and-
recomputed == cold rebuild — the force-quit heal, as an assertion); the backfill tests
reproduce the e44 signature and assert the healed books row by row.

## 2026-08-13 — the 19-second post-wake write EXPLAINED: it is a HealthKit sync, not Core Data

Twice measured (e27 19.3 s, e31 18,989 ms), both on a freshly-woken phone, and recorded twice
as "the amplifier, unexplained". It is not a slow database. `DoseStore.addPumpEvents` calls
its completion from inside `syncPumpEventsToInsulinDeliveryStore` — AFTER the Core Data save,
after `getLastImmutableBasalEndDate`, and after `savePumpEventsToInsulinDeliveryStore` has
pushed the doses into the InsulinDeliveryStore, which on this phone is backed by HealthKit
(`healthKitSampleStore: insulinHealthStore`, DeviceDataManager :318).

So the thing we timed as "the write" is really Core Data + a full HealthKit round-trip, and
HealthKit on a just-unlocked phone is cold and protected-data-gated. That is where the ~19 s
lives, and it explains why the number is so stable across incidents and so absent from
steady-state loans (85 ms and 18 ms in the same e31 log, once warm).

CONSEQUENCE FOR THE PROTOCOL, worth stating plainly: the hand-back ack is gated on a
HealthKit write. The phone cannot ack until insulin has reached the health database, so a
cold HealthKit stalls the loan's close by exactly that long — and before #118 that stall was
the window every duplicate offer piled into. Nothing here is wrong (records-before-ack is
the design, a897d22c), but the ack latency is a HEALTHKIT property, not a database one, and
future timing analysis should read it that way.

NOT CHANGED. Acking earlier — say, after the Core Data save but before the HealthKit sync —
would decouple loan liveness from HealthKit warmth, and would also weaken the guarantee the
ack exists to make ("records are committed"). That is a ruling-shaped tradeoff, not a fix to
make at 1 a.m.; #118 and #120 already removed the harm it was causing.

## 2026-08-13 00:16 (e31, build 273 both devices) — #118 FIELD-VALIDATED in the e27 shape

The exact scenario that produced e27's eleven concurrent writes recurred on the fixed build:
a 19-second Core Data write (18,989 ms — same magnitude as e27's 19.3 s) with EIGHT copies of
the same offer arriving during it. Result this time:

```
write START 1 dose(s)
offer COALESCED behind the in-flight write (#118) — 1 waiting   (x7, all merging into one slot)
write DONE 18989ms → ACK cursor 2
write START 0 dose(s)     <- the single merged replay
write DONE 18ms → ACK
```

One write instead of eight, the merged replay a no-op, ack flowing, loan clean. A second
smaller coalesce at 00:17:07 (offer during an 85 ms write) was caught the same way.
Reconcile: provisional == authoritative == +0.000 exact. Residual bank n=13 — R32 review
still due, and the answer is still "scale with cycle count", not a new constant.

Also observed, benign and self-healing: a KEEPALIVE START RACE at takeover. The screen
dropped between the Start tap and the grant arriving, so the HKWorkoutSession start hit
HealthKit Code 14 ("cannot start a workout session while in the background"). The takeover
proceeded on ordinary background grace, and the existing retry-on-foreground path healed it
17 s later at wrist-raise (fresh session, holders intact); soak keepalive then held for the
whole loan. Residual exposure is narrow — Start tapped and the wrist never raised during the
takeover — which is the known #88 territory, not new machinery. Recorded so Code 14 in a
future log reads as "the race" and not as a broken keepalive.

The #113 channel instrumentation is live in the field (41 `RX … ch=` lines this loan,
`RX grant ch=urgent` among them) — a future wedge now self-diagnoses. And the corrected seed
line renders as intended: "124 seeded doses: 122 finished; 2 live — delivery tracked from
pod state (#72)".

## 2026-08-13 00:13 (build 273, e31) — #113 recurred, and the instrumentation caught it: a SECOND variant, self-healing

The hand-back wedge came back on its first hard-exercise night after the channel-tagged RX
instrumentation shipped — and the tags did their job. This is not the 2026-08-11 wedge.

**Timeline.** Hand-back requested 00:13:05, phone reachable. Every urgent offer send failed
LOUDLY — `urgent send FAILED (Unknown WatchConnectivity error.)` on each 15 s resend — and
fell back to the queued path. **Zero `RX` lines of any kind on the watch from 00:13:05 to
00:16:20**: no acks (urgent) and no diags (queued). Both directions were dead. At 00:15:10 the
timeout fired with the new escalation: `** 8 offers, phone REACHABLE throughout, zero acks —
transport wedge (#113) **`.

Then at **00:16:26 the entire queued backlog flushed in one burst** — the phone's own diag
echoes show it receiving all eight queued offers within ~500 ms and #118's coalescing eating
the storm (`offer COALESCED behind the in-flight write` repeatedly, exactly as designed).
Acks arrived `ch=urgent` at 00:16:44 — the urgent channel had recovered too. The second
hand-back attempt drained 0 events (everything already committed under the first), and the
loan CLOSED at 00:17:13. A stale duplicate ack after close was loudly ignored
(`ack IGNORED ev=31 — ours ev=nil`), which is the guard added the same day doing its job.

**So #113 is two distinct failures wearing the same "no acks" face:**

| | Variant A (2026-08-11) | Variant B (this) |
|---|---|---|
| watch→phone | WORKED — phone logged and acked 8 offers | DEAD — urgent errored, queued sat undelivered |
| phone→watch | dead until the WATCH app restarted | dead ~3.4 min, then the queue flushed |
| urgent send errors on the watch | none observed | `Unknown WatchConnectivity error` on every attempt |
| recovery | force-quit the watch app | **self-healed**, no restart |
| insulin | none lost (idempotency) | none lost (idempotency + #118 coalescing) |

**The discriminator for the wrist, next time:** if the watch's own urgent sends are ERRORING,
it is variant B — wait a minute or two, the session is re-establishing, and "restart the watch
app" is premature advice. If the sends succeed silently and no acks come back, it is variant A
and the restart is the known recovery. The current escalation message fired 76 seconds before
a self-heal here, so it should learn this distinction: track whether any urgent send in the
current hand-back drain returned an error, and soften the advice when one did. Not yet built —
held because a ship was staging at the time.

Also in this log, smaller but real:

- **#118 field-validated under storm conditions** — the coalescing absorbed an 8-offer
  redelivery burst arriving within one second, plus the routine duplicate at e33.
- **e33 reconcile was perfect at n=15**: `delivered=2.300 expected=2.300` on an 11-cycle loan,
  provisional AND authoritative agreeing at −0.000. The bank now reads n=15, mean −0.030,
  worst |0.200| — the numbers behind the R32(c) tightening.
- **The `[cob-diff]` ⚠ fired with a 1-second-old snapshot** (`phoneCOB=13.9 g, watch 18.21 g,
  Δ +4.28 g, snapshot age 1s`). The standing explanation for these warnings — snapshot age
  over actively-absorbing carbs — cannot cover a 1 s old snapshot. 53 g of entries transferred
  with identical identities, so the delta is MODEL disagreement (the phone's dynamic ICE
  absorption vs the watch's read at seed time), not data loss. Still probably instrument
  rather than defect, but the old explanation is now insufficient and this line is the
  counterexample.
- **Takeovers: 26.6 s / 9.1 s / 7.2 s.** The slow one started backgrounded with the keepalive
  refused (HK error 14) and recovered at the first wrist-raise — the known self-heal, visible
  end to end.

## 2026-08-13 01:52 (build 274, e34/e35) — R35 + #112 VALIDATED IN THE FIELD

The deferred validation finally ran. e35 was started with an override active, and the dosing
math shows both scales applied:

```
[override] APPLIED 🕺 crashy · insulin needs 52% (basal x0.52, ISF x1.92, CR x1.92)
[settings] granted @now — ISF 70 mg/dL/U · basal 0.70 U/hr        <- the RAW schedule
[dosemath] ... running 1.30 U/hr · scheduled 0.36 · ISF 135       <- what dosing actually used
```

0.70 × 0.52 = 0.364 → `scheduled 0.36`. 70 × 1.92 = 134.4 → `ISF 135`. **Both the basal
baseline and the ISF are override-applied in the same cycle**, which is exactly what #112
fixed — temps had been netting against the RAW basal while ISF was already scaled — and what
R35's ledger-only dosing requires. Eight cycles across two loans, every verdict `computed=ok`,
and no ledger refusal anywhere in the log: the no-fallback rule never had to fire because the
ledger was always there.

Both reconciles were exact: e34 `delivered=0.300 expected=0.300 residual=-0.000`, e35
`0.300/0.300 residual=+0.000`. Bank now n=17, mean −0.026, worst |0.200|.

## Same night — a failed manual bolus, classified correctly and INDEPENDENTLY PROVEN

01:54:13 a 0.10 U manual bolus failed with a BLE write timeout — the textbook uncertain
shape, since a timed-out write cannot by itself tell you whether the pod received it. The
watch told the user flatly "Bolus Not Delivered — 0.10 U did not deliver".

That assertion is stronger than a write timeout alone can justify, so it is worth recording
WHY it was safe. `loanDidEnact` does not guess: past the `unfinalizedBolus` certain-refusal
check it asks the pump manager whether a pending command exists
(`podLoanPendingCommandKind != nil`). It was nil — OmnipodKit knew the bytes never went out —
so the enact was classified a certain failure and the journal entry ANNULLED rather than
booked as an assumed max-exposure dose. No chase, no phantom insulin.

**The odometer then proved it independently.** Had the 0.10 U actually delivered, the
hand-back audit would have read `delivered=0.400 expected=0.300 residual=+0.100`. It read
0.300/0.300, −0.000. Two mechanisms built for different reasons — #99's certainty
classification and the item-1 authoritative odometer read — agreeing on a real event.

Note the direction: annulling an uncertain bolus is the AGGRESSIVE choice (unbooked insulin
under-counts IOB and permits more dosing later), and it is only safe because the pending-command
check is real evidence rather than an assumption. If OmnipodKit ever reports no pending command
for a write that DID land, this is where phantom-free becomes insulin-blind. Worth remembering
if a residual ever comes back positive and unexplained.

Smaller, in the same window:

- **`[cob-diff]` ⚠ fired twice more at snapshot ages 3 s and 1 s** (Δ +4.86 g, +5.40 g).
  Third and fourth occurrences where the snapshot-age explanation cannot apply. Same
  conclusion as 08-13 00:13: model disagreement, not data loss — but the warning threshold is
  now demonstrably mis-tuned and should either account for absorption-model divergence or
  stop claiming "wipe failed?".
- **e34 took 56.9 s / 8 reads to take over**, e35 12.5 s / 2. The slow one is the same
  fixed-cadence-polling-before-discovery shape recorded on 08-12: reads fire on an 8 s ladder
  while the pod is still `no-peripheral`, and the event is what actually ends the wait.
- **One `CYCLE VERDICT computed=FAILED enact=not-attempted(pumpManagerUnconnected)`** at
  01:56:47, during e35's takeover, following a `[CONFIG] configure FAILED (discoverServices
  timeout)`. Recovered 7 s later. Cosmetic if the OBS-8 verdict-classification fix is not in
  274; worth confirming it does not survive into the next build.

## 2026-08-13 02:40 — CORRECTION: the slow takeover is not a polling problem, and phase 5 is cancelled

Earlier tonight I wrote that e34's 56.9 s takeover was "the same fixed-cadence-polling-before-
discovery shape ... reads fire on an 8 s ladder while the pod is still `no-peripheral`, and the
event is what actually ends the wait." The first half of that is wrong, and it was about to
justify refactoring the most safety-critical path in the app.

**The takeover has been event-driven since #86.** `takeoverRetryAction` runs the next read the
moment `podLoanOnSessionEstablished` fires; the 8 s timer is a labelled backstop, not a
metronome. The field data says it works:

```
e37   7.2s  2 reads  driver=event      e34  56.9s  8 reads  driver=event
e36   6.8s  2 reads  driver=event      e33   7.2s  2 reads  driver=event
e35  12.5s  2 reads  driver=backstop   e32   9.1s  2 reads  driver=event
                                       e31  26.6s  4 reads  driver=event
```

Five of seven finish in ≤12.5 s and six of seven end on the event. Slow takeover is a 2-of-7
outlier, not the shape of the thing.

**What e34's 49 s actually was.** The scan was running the entire time:

```
01:52:36.300  [SCAN] start — service 0x4024 · reason takeover(0x17358635)
              ... 49 s, no advertisement ...
01:53:25.858  [SCAN] ad seen: pod 0x17358635 rssi -73 — MATCHES takeover target
01:53:25.867  Pod failed to connect — CBErrorDomain Code=11 "maximum number of connections"
              held[devices=1(conn 0/ing 0/dis 1/other 0) auto=1]
01:53:27.140  Pod connected
```

The wait was for the POD to advertise. Reads landing at +9.7/+18.5/+26.7/+34.7/+42.7 s were
observing "still nothing" against a scan that had been live since +0.3 s. A faster ladder would
have produced more `no-peripheral` lines and not one second of improvement. Then the first
advertisement hit `CBErrorDomain#11` — the already-recorded BLE-slot exhaustion where our own
pending connect holds the slot — costing another 1.3 s.

So the two outliers have two different causes, neither of them cadence:
- **e34 (56.9 s)** — pod advertisement timing, which is the pod's clock, plus CBError#11.
- **e31 (26.6 s)** — the only one with a local cause: `keepalive FAILED` at reads 1-2 with the
  app backgrounded, and discovery made no progress until the workout session came up at ~17 s.
  Worth a look on its own terms; it is NOT what happened in e34, which was foreground and
  keepalive-clean throughout (the hypothesis was tested against e34 and refuted).

**Phase 5 is cancelled as a refactor.** There is no cadence bug to fix, the mechanism is
already the one a refactor would have introduced, and touching it would spend risk on the
takeover path against a premise the logs contradict. It also runs straight into two standing
rulings — never shorten connect budgets below one ad window, and G7 connectivity outranks
takeover reliability. The remaining real items are CBError#11 (known, unfixed, tracked
separately) and e31's keepalive start-up gap.

Method note for next time: the aggregate that produced this was nearly a lie too. A first pass
grepped each rotated log file for its first takeover and reported twenty rows — twenty copies of
the same epoch, because the logs are rotating snapshots of one stream. Deduplicating by EPOCH is
what turned it into evidence.

## 2026-08-13 03:25 (build 275, e38) — the post-dose-release double-arm is EVERY steady-state cycle

The first loan with timer instrumentation, still running. Nine `post-dose-release` armings so far,
and the pattern is not occasional:

```
02:48:19  armed            02:56:55  armed        03:06:49  armed
02:48:53  armed            02:56:57  armed  <--   03:06:52  armed  <--
02:51:52  armed            03:01:49  armed        03:11:53  armed
                           03:01:52  armed  <--   03:11:55  armed  <--
```

Three singles while the loan settles, then **six consecutive cycles that each arm TWO releases
about 2.4 s apart, and fire both**. It is not a coincidence of timing — it is what steady state
looks like. The loop runs every five minutes, so every cycle finds the pump data ~5 min stale,
reclaims once to refresh status, then reclaims again to dose. Two reclaims, two calls to
`releasePodAfterDose`, two independent 12 s timers, because that function was the only one-shot
timer in the file with no cancel-before-rearm.

Both fire. The second is a no-op only because the first already released the link and
`isConnectionReleased` bails it out — visible in the log as a second `fired` with no matching
`E4: pod re-released` line after it. So the redundant release has been running once per cycle,
every cycle, for as long as E4 has existed, and was invisible until the timers started logging.

The hazard was never the second release itself; it is that a reclaim landing inside that ~2 s gap
would leave both of the stale timer's guards (`phase == .active`, `isConnectionReleased == false`)
satisfied, and it would drop the BLE link out from under a live dose. Once per cycle is a lot of
chances.

Fixed for the next build by cancel-before-rearm; the epoch scoping added the same night does NOT
cover it, since both timers belong to epoch 38.

Also caught, and only visible because of the lateness field: `03:12:06 fired post-dose-release
+12s late 1.0s`. One second, harmless, but it is the first measured lateness of the run and the
signature to watch — a deferred release firing minutes late is what poisons the BLE stack.

Loan health meanwhile: 8 cycles, all `computed=ok enact=ok`, zero ledger refusals, takeover 8.5 s
on 2 reads.

## 2026-08-13 04:05 — the [cob-diff] ⚠ EXPLAINED: it never measured the wipe

Five write-ups have called this warning unexplained. It is a category error in the check, and
the data separates cleanly on the one variable nobody had plotted — how far into absorption the
newest carb was:

```
Δ = +0.01 g      newest carb   1 min old      (clean)
Δ = +0.00 g      newest carb  90 min old      (clean)
Δ = -0.52 g      newest carb 148 min old      (clean)
Δ = +5.40 g ⚠    newest carb   3 min old
Δ = +4.99 g ⚠    newest carb   5 min old
Δ = +7.32 g ⚠    newest carb   8 min old
Δ = +4.86 g ⚠    newest carb  21 min old
Δ = +4.28 g ⚠    newest carb  51 min old
```

Perfect separation, 8 for 8, on absorption phase — and NO separation on entry count (9 entries
clean, 8 entries dirty), on snapshot age (1-3 s throughout, both verdicts), or on whether an
override was active (02:27:00 applied an override and the very next diff was clean).

The mechanism was written in the code's own comment all along: "`post` is a pre-settle read
(static absorption) so a small +Δ vs the phone's dynamic COB is expected". The watch reports
STATIC absorption; the phone reports DYNAMIC, fitted to observed glucose. Those two must agree
when nothing has absorbed yet (a 1-minute-old carb is entirely on board under either model) and
when everything has (both read ~0 at 90+ min), and must diverge in between. The fixed 2 g
threshold simply doesn't scale with the amount of carb in flight, so at realistic loads the
⚠ fires on healthy behavior.

**The check never tested its own claim.** "Wipe failed?" is a statement about the ENTRY SET, and
the line inferred it from a computed COB. I initially thought the log's entry manifest proved the
store was correct — it does not: `manifest` is built from `carbs`, the list we SEND, so it says
nothing about what landed.

Fixed by reading the store back after the replace and comparing sync identities: residual,
missing and duplicate counts, with a distinct "wipe UNVERIFIED" if the read-back itself fails,
because unverified is not clean. Δ stays in the line — it is worth seeing — labelled
"(static vs dynamic)".

The general lesson is the one already in the file two lines above the bug: a false alarm in the
instrumentation is worse than none, because it teaches you to skip the line. This one had taught
me to skip it five times.

## 2026-08-13 12:10 — CORRECTION to the cob-diff explanation: it is NOT a static-vs-dynamic split

The 04:05 entry above explains the Δ pattern correctly and its fix (verify the wipe by reading
the entry set back) is right. Its MECHANISM is stated wrong, and the wrong version is the kind
that misleads a future reader into hunting a bug that does not exist.

It said: "The watch reports STATIC absorption; the phone reports DYNAMIC." Read naturally, that
says the two platforms run different COB algorithms — that the watch is on a legacy non-DCA
path. Jeremy read it that way and asked why anything computes COB without dynamic absorption.
Fair question, and the answer is: nothing does.

Verified against source, every production COB call passes effect velocities and takes the
dynamic path:

```
WatchLoopManager.swift:703    carbStore.carbsOnBoard(at:effectVelocities: velocities)     watch glance
WatchLoopManager.swift:749    carbStore.carbsOnBoard(at:effectVelocities: ICE)            watch HUD publish
LoopDataManager.swift:1142    carbStore.carbsOnBoard(at:effectVelocities: ICE)            phone dosing
BolusEntryViewModel:635 / ManualEntryDoseViewModel:308                                    phone entry UI
```

The only call in the repo that omits velocities — and so reaches LoopKit's genuinely static
branch — is `LoopTests/WatchStoreEffectsTests.swift:304`, which is test-only and unreachable
from shipping code.

**What actually produces the Δ.** Dynamic absorption contains its own per-entry fallback
(`CarbStatus.swift:56`): with no observed timeline for an entry yet, it returns the modelled
curve for THAT ENTRY. The cob-diff read runs immediately after the carb replace, before any
cycle has extended the watch's `insulinCounteractionEffects` over the just-seeded carbs, so
they take the fallback. The phone's figure is cached from a completed cycle with observation
behind it. Read the phone at the same instant and it prints the same number. Same algorithm,
different observation maturity — a freshness artifact, not an algorithm choice.

**There WAS a real non-DCA bug, and it is fixed.** The port originally omitted effect
velocities entirely, so watch COB was genuinely static while `carbEffect` was dynamic —
`WatchLoopManager.swift:685-692` documents it, found in the 2026-07-22 stock-call audit, field
symptom "15 g entered on the wrist moved eventual correctly while COB read a hard 0". Current
code passes them. So Jeremy's instinct was right about the class of bug; it had simply already
been caught.

Dosing never depended on this either way: the watch doses off
`carbStore.getGlucoseEffects(...effectVelocities:)` (`WatchLoopManager.swift:1796`), not off
`carbsOnBoard`. COB here is display plus this diff check.

Log label and code comments corrected to say "observation freshness, not a model split".
