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
