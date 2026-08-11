# Known residuals — loan protocol v2 (non-blocking)

Findings from the adversarial verification of the takeover BLE fix
(2026-07-18, three-lens verify: mechanism/completeness/regression, all SOUND).
None block the primary takeover, loan, or hand-back paths. Recorded so they
don't get lost; revisit opportunistically or when a symptom matches.

1. **LATENT — stale pump snapshot after crash-reset.** The relaunch reset path
   (PodLoanWatchController ~:97) returns to idle without `teardownPump()`,
   leaving the persisted pump snapshot (`Keys.pumpRawValue`) in UserDefaults
   with `podConnectionReleased=false` + a watch-local bleIdentifier. No code
   reads it back today; any future reader would resurrect a pod-bidding
   snapshot. Fix when a reader is introduced: clear the key in the reset path.

2. **DESIGN-ACCEPTED — silent idle after relaunch mid-loan, pre-dose.** Watch
   relaunch during an ACTIVE loan with zero journal events resets the watch to
   idle while the phone stays LOANED (deliberately not timer-healed); the pod
   runs its last programmed state until the user intervenes or the 6h reminder
   fires. Mid-takeover the phone's T1 auto-reclaims at ~5 min, so only the
   post-takeover pre-dose window has this shape.

3. **FRAGILITY — teardown by deallocation.** `teardownPump` relies on dealloc
   to stop an old attempt's armed, scanning central (no explicit disarm/stop
   API on BluetoothManager). Works because all back-references are weak; any
   future strong retention of OmniPumpManager would leave a still-armed
   central that could steal the pod from a second takeover attempt. If touched:
   add an explicit `endLoanTakeover()` (clear armed id + stopScan) and call it
   from teardown.

4. **RESIDUAL — EAP-AKA failure with link up burns the retry budget.** If
   session establishment fails while the BLE link stays up, the error is
   swallowed (`needsSessionEstablishment` stays true) but configuration is not
   re-attempted until the pod disconnects; takeover reads then fail on the
   encrypted transport for the rest of the 14×3s window. Rare (fresh LTK from
   the grant); symptom would be "adopted + connected but takeover still fails".

5. **RESIDUAL — hand-back ack-loss window.** Phone acks, reclaims, becomes
   OWNER while the watch still holds the pod until the ack lands; a stalled
   WCSession leaves the phone's pending connect uncompleted and its 90s
   re-audit no-ops. Self-heals: the watch resends the offer every 15s and the
   phone re-acks idempotently.

6. **MINOR — transient contention on phone BT restart mid-loan.** The
   poweredOn handler's unconditional reconnect loop briefly connects to the
   released pod; `updateConnections` cancels it in the same callback (empty
   autoConnectIDs). Transient by construction.

7. **COSMETIC — no idleNote after crash-reset.** The relaunch reset to idle
   doesn't set `lastIdleNote`, so after a crash mid-takeover the glance shows
   unexplained idle. One-liner when convenient.

## From the loan-bolus verify (2026-07-18, both lenses SOUND; deferred items)

8. **MINOR — annul lost if hand-back drains mid-bolus.** A manual bolus's
   `.assumed` journal event can be offered/acked and the journal ended before
   the BLE completion classifies it; a certain FAILURE then can't annul (the
   journal mutate guard no-ops) and the phone keeps an assumed bolus that never
   delivered — over-counted IOB, conservative direction. Narrow (hand-back
   started while a bolus command is in flight). Fix shape: gate hand-back on
   in-flight enactments, or re-open classification for just-ended epochs.

9. **MINOR — bolus dial max is stock-fed, enforcement is grant-fed.** The dial
   caps from the stock watch settings (or 10U default) while `enactManualBolus`
   enforces the granted frozen `maximumBolus`; a mismatch means dial-then-deny
   (safe direction, poor UX). Align the dial to the granted snapshot in the UI
   pass.

10. **MINOR — hand-back window refusal is watch-silent.** Between the watch
    leaving `.active` and the phone reaching `.owner`, a watch bolus takes the
    stock relay path; the phone refuses loudly but replies success-shaped, so
    the watch flow looks fine. The refusal notification mirrors to the watch
    via the OS; still, the in-flow experience misleads for that window.

11. **COSMETIC — WatchLoopManager.pumpManager/settings cross-queue writes.**
    Written on the loan-controller queue, read on dataAccessQueue, no
    synchronization; settings are written once pre-.active so exposure is
    negligible, but the pattern is technically racy.

## From the WS1 verify rounds 4-5 (2026-07-19; all REAL findings fixed)

12. **MINOR — finalize completion-loss stall.** If the pod-ops completion in
    finalizeHandback is lost, finalOfferSent sticks false and the close waits;
    bounded by the phone escape-hatch revoke and relaunch reset — same exposure
    class as the pre-WS1 offer path.
13. **MINOR — committedIDs cleared at grant vs late stale drains.** A stale-
    epoch drain after an epoch bump could theoretically re-commit; unreachable
    under transferUserInfo FIFO except via debugReset, and store-level
    syncIdentifier dedup backstops it. Pre-existing semantics.
14. **MINOR — legacy single-phase hand-back keeps the old in-flight window.**
    Old-phone loans (capability flag absent) finalize without a drain gate;
    conservative direction, settled by the R22 odometer audit — unchanged
    pre-WS1 behavior.
15. **COSMETIC — crash-relaunch into recoveredDrain keeps a delivered
    repeating blackout notification firing until the drain completes.**
16. **TEST DEBT — WS1 surface untested.** PARTIALLY BURNED DOWN 2026-08-11
    (coverage plan item 5):
    - DONE released-flag decode (absent key) — `LoanProtocolV2Tests.testLegacy\
      OfferWithoutReleasedKeyDecodesAsNil` strips the key from the encoded JSON
      (Swift `released: nil` is a different wire shape), plus `PodLoanPhone\
      ControllerTests.testLegacyOfferWithoutReleasedKeyFinalizesTheLoan` for the
      consequence.
    - DONE finalize-on-empty-drain — `testFinalOfferWithNoEventsStillAcksAnd\
      ReturnsToOwner`.
    - ALREADY COVERED interim no-state-change commit — `testInterimDrainAcks\
      OpenTempButDefersWriteToFinal` asserts state stays `.loaned`.
    - BLOCKED cancel mid-drain, revoke-during-drain, seq-gap cursor cap — all
      three are WATCH-side, and `PodLoanWatchController`/`WatchLoopManager`/
      `LoanEventJournal` are in the `WatchApp Extension` target only, so
      `LoopTests` cannot reach them. See TEST_COVERAGE_PLAN.md "Corrections"
      for the three unblocking options. The cursor cap itself IS implemented
      (`handleAck` caps below the lowest withheld seq); this is debt against
      working code.
    The five verify rounds stand in for the blocked three until written.
