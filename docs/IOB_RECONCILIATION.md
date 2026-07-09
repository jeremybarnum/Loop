# Watch-Loan IOB Reconciliation (DIST-3)

How the phone's insulin accounting stays correct when the watch drives the pod
("Show Mode"). Referenced from `PodHandbackUserInfo.swift` and
`WatchDataManager.reconcileWatchLoan`. Built and hardware-validated 2026-07-08
(branch `watch-reconciliation`).

## The problem

During a loan, the watch commands the pod directly; the phone is away (Bluetooth
off) and its DoseStore records nothing. Without reconciliation, watch boluses are
invisible to Loop after hand-back — the phone's IOB is **understated**, so Loop
recommends more insulin on top of insulin it doesn't know about. Stacking → hypo.
That is the dangerous direction, and closing it is Phase B (this document).
The reverse direction (watch suspends/reduces basal; phone's IOB overstated →
under-dosing → transient highs) is annoying but safe, and is deferred (Phase C).

## Design

**Journal events are primary; the pod's odometer audits them.**

1. The watch records every action in the loan journal
   (`OmniBLECore.PodLoanJournal`) with real timestamps, and notes the pod's
   cumulative-delivered odometer (`insulinDelivered` from status responses) at
   takeover and on each command. `handBack()` freshens the odometer with a final
   `getStatus`, then **snapshots** the encoded journal so retries resend
   byte-identical data.
2. On hand-back, the phone (`WatchDataManager.reconcileWatchLoan`):
   - decodes the journal with a **mirror type** (the phone deliberately does not
     link OmniBLECore; the JSON shape is pinned by
     `PodSDK/Tests/OmniBLECoreTests/PodLoanJournalWireFormatTests.swift`),
   - enters each journal **bolus at its real timestamp** via
     `LoopDataManager.addManuallyEnteredDoses` (correct decay; renders as
     "Logged Insulin Dose" in Event History; one DoseStore write → one loop
     recompute),
   - computes the audit: `remainder = podDeliveredDelta − journal boluses −
     expected scheduled basal` (override-aware schedule, truncated to the loan
     window, **net of the journal's suspend windows**),
   - enters a positive remainder in **[0.05 U, 5 U] timed at hand-back** —
     zero decay elapsed means IOB is maximally overstated, so Loop doses *less*:
     errors land on the safe side. Negative remainders are logged, not entered
     (Phase C). Remainders above 5 U trip a sanity cap (odometer corruption).

## Safety properties

- **Duplicate hand-backs cannot double-enter.** The DoseStore does NOT dedupe
  manually-entered doses (verified in LoopKit source), so the only defense is
  ours: SHA-256 of the raw journal bytes, persisted in app-group defaults,
  checked before any dose entry. The watch-side payload snapshot keeps retry
  bytes identical; the wire-format test pins encoding determinism.
- **Crash ordering errs safe.** Doses are written first; the hash is persisted
  only on confirmed success. A crash in between → the retry double-enters →
  IOB overstated → Loop under-doses (safe). The reverse order could silently
  LOSE doses (hypo risk).
- **Corrupt journals are bounded.** Per-event bolus cap 1.05 U (the watch's own
  maxBolusUnits + slack); undecodable journals fall back to Phase-1 behavior
  (summary displayed; user records manually via Non-Pump Insulin) without
  consuming the hash.
- **Journal loss is survivable.** The journal is in-memory on the watch; if the
  watch app dies mid-loan, the odometer delta still captures total delivery and
  enters it timed-late (Phase-B degradation: right amount, conservative timing).
- **Reboot-proof.** The hash and the pre-loan `dosingEnabled` capture live in
  app-group UserDefaults (the latter fixed an adjacent bug: a phone reboot
  mid-loan used to leave closed loop silently off after hand-back).

## Known limits (Phase B)

- Negative net delivery (suspends, temps below schedule) is not written back;
  Loop's IOB is overstated for a few hours after such sessions → possible
  transient highs. Phase C: retroactive suspend/temp-basal records.
- The odometer freshness depends on the final pre-hand-back `getStatus`
  (best-effort); a stale read understates the remainder — bounded at minutes of
  basal.
- `basalProfileApplyingOverrideHistory` evaluates overrides relative to now; for
  a just-ended short loan this matches, but a long-expired override could skew
  the expectation slightly. Audit-only impact.
- Insulin type is the pump's type at hand-back (pod swap mid-loan out of scope).

## Validation record (2026-07-08, Pi emulator + real watch/phone)

| Session | Audit line | Result |
|---|---|---|
| 1.0 U bolus | `podDelta=1.00 boluses=1.00 expectedBasal=0.02 remainder=-0.02` | 1 dose at bolus time ✓ |
| 0.3 + 0.85 U boluses | `podDelta=1.15 boluses=1.15 expectedBasal=0.02 remainder=-0.02` | 2 doses at their times ✓ |
| 0.4 U bolus + 1.0 U/hr temp, 10 min | `podDelta=0.40 boluses=0.40 expectedBasal=0.18 remainder=-0.18` | 1 dose; negative clamp ✓ (odometer stale — pre-freshen watch build) |

Field capture the same night: a hand-back whose ack was lost left the watch in
Show Mode; it later commanded a temp while the phone owned the pod (the
single-writer ping-pong DESIGN-GAP-1 addresses), and its old-build fresh
re-encode produced different journal bytes on retry — benign that night (no
boluses), and exactly the hole the payload snapshot closes.
