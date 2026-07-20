# Radio-stack audit — findings + triage (2026-07-20)

Source: 5-dimension reviewer sweep over the watch radio arbitration + G7/pod
acquisition state machines, each finding dual-adversarially verified. The audit
independently rediscovered OBS-1 (the epoch-21/27 "no verdict" mystery) AND
surfaced the dual-controller critical whose precondition the same field session
then demonstrated (epoch 27 ran 23 min on a 5-min grant).

Status legend: [DONE] shipped · [NEXT] queued · [ ] not started.

## FIELD-CONFIRMED

- [DONE] **CRITICAL — takeover ladder had no lease re-check.** grant.expiresAt was
  validated once at intake; the ladder (attemptTakeoverRead) was bounded only by
  attempt count, so a mid-ladder app suspend (field epoch 27: 23 min) could flip
  .active on a long-expired grant while the phone T1-reclaimed → two controllers on
  one pod. FIX: re-check Date() < grant.expiresAt each iteration, abort before
  honoring a successful read.
- [DONE] **HIGH — relaunch mid-ladder silently dropped the takeover (= OBS-1).**
  init() reset .takingOver→.idle with no verdict to the phone (stranded in
  .grantOffered) or the user. FIX: stash epoch, send takeoverFailed from
  drainRecoveredIfNeeded once `send` is wired; legible idle note.
- [DONE] **HIGH (audit #4) — relaunch during .active with empty journal abandoned a
  live loan.** Phone stuck .loaned, nobody looping. FIX: route .active/handingBack/
  revoked/recoveredDrain at relaunch to a recovered drain + Session Ended alert.

## HIGH — not yet applied

- [NEXT] **Epoch guard amnesia.** epoch reset to nil at every clean close/init, so a
  stale-but-unexpired queued grant (WCSession can hold transferUserInfo minutes) is
  accepted, hijacks a fresh request, real grant dropped "wrong phase" → crossed
  epochs. FIX: persist a high-water epoch that survives close; reject grant.epoch
  <= highWater even from .idle.
- [NEXT] **My build-124 publishHUDContext fires the CarbAndBolusFlowViewModel
  observer.** Synthesized context has recommendedBolusDose=nil; mid-flow it nils
  recommendedBolusAmount and (carbEntry cfg w/ a carbEntryUnderConsideration) triggers
  a phone recompute that hangs when the phone is unreachable. Window: loop cycle
  (~5min) fires while the bolus/carb sheet is open. FIX: mark the loan-HUD post
  (userInfo flag) and have the bolus VM bail on it, or refresh HUD rows via a
  loan-specific path.
- [NEXT] **Loop-stall dead-man refreshed BEFORE enact** → enact-stage starvation
  (radio defer, pod unreachable, stuck busy flag) never alarms. FIX: refresh after
  successful enact, or split liveness vs enact-success watchdogs.

## MEDIUM

- [NEXT] **Finish R26.** poweredOn resume → beginAcquire, and the 400s reconnect /
  330s cold-reacquire watchdog fallbacks → beginScan() all run mid-hold without
  consulting podTakeoverHold. Hold-gate those three sites (defer/re-arm, never cancel
  the armed connect → REG-2 & poisoned-session safe).
- [ ] Handback finalize DESIGN-5 temp-cancel doesn't consult the radio arbiter nor
  retry → a G7 handshake at handback time silently fails the temp-cancel.
- [ ] Fix B defers the automatic enact against the TAIL of the very handshake that
  produced the triggering reading (flag cleared only after queryDeviceList).
- [ ] didUpdateContextNotification posts twice per cycle (+latched 3rd) [build 124] →
  doubles complication reloadTimeline budget over multi-hour sessions.
- [ ] mirrorLogToICloud concurrent global-queue blocks [build 123] → after a queued-
  transfer flush, iCloud latest.log can end up stale/missing; pruned-before-mirror
  logs never reach iCloud. FIX: serialize on a dedicated queue.
- [ ] Grant intake writes loopManager.settings (struct) + pumpManager from the loan
  queue while dataAccessQueue reads them unsynchronized → torn-read risk.
- [ ] Stale/expired grant cancels the 25s request timeout BEFORE validation → stuck
  "requesting…" forever, Start untappable.

## LOW (batch)
- _handshakeActive leaks true through stop()/startSoak-preempt/CancellationError.
- Hold doesn't stand down settle-wait/candidate-connect stage; didConnect mid-hold
  launches a full handshake.
- Radio-busy check consumes a verdict-chase ladder attempt w/o pod contact.
- Same-second stamped-filename collision drops newer archive copy [build 123].
- Stamp DateFormatter lacks en_US_POSIX → 12h locale corrupts filename + prune could
  delete NEWEST [build 123].
- Loan-queue R26 wiring mutates G7Client @Published (autoRepeat) off-main.
- connect() hold-deferral wedges an already-armed prewarm; one-shot connect dropped.
- handleGrant journal.begin failure guard-return strands phase at .requested.
- teardownPump during in-flight status read leaves old BLE stack auto-reconnect-bidding.
