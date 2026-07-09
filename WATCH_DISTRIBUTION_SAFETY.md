# Watch Show Mode — distribution-safety TODO

Choices that are **acceptable for the current single-user deployment** (Jeremy/Caitlin,
one device, controlled by Jeremy) but would need hardening **before this is distributed
to other users**. Tagged as we make them, per Jeremy's request. None of these block the
current single-user use.

The recurring theme: single-user relies on the user knowing their own BG and dosing;
distribution can't. Most fixes hinge on the Phase-2 "BG on the watch" work.

---

## DIST-1: Bolus has no BG gate
The watch correction bolus (crown dial, cap 1.0 U) delivers with **no glucose check** —
no "fresh, in-range BG required" gate. Fine when the user knows their BG; unsafe as a
general feature (could stack a correction onto an already-low BG).
- **Before distribution:** require a fresh, in-range CGM reading on the watch (the
  G7-collector / Phase-2 BG-on-watch work) before allowing a correction bolus; block on
  stale/absent BG. Consider a per-user max instead of a flat 1.0 U.
- **Lever:** `WatchPodLoanCoordinator.maxBolusUnits` (currently 1.0 U).

## DIST-2: Basal is absolute and can exceed scheduled (permanent over-temp possible)
The basal dial sets an **absolute** rate 0–1.0 U/hr (not a % of scheduled), chosen for
simplicity (no need to know the scheduled rate on the watch). If the user's scheduled
basal is below 1.0 U/hr (likely), the **top of the dial is a permanent (3h) basal
*increase*** — the "high temp / extra insulin" case, which trends toward hypo. The 3h
auto-revert + the 1.0 cap bound the worst case, but it is not zero-risk.
- **Before distribution:** either (a) make it reduction-only by capping the dial at the
  scheduled rate — the phone can supply it in the loan grant (confirmed reachable via
  `WatchDataManager` → `basalRateScheduleApplyingOverrideHistory`); or (b) BG-gate any
  rate above scheduled; or (c) lower the absolute cap to a safe floor.
- **Lever:** `WatchPodLoanCoordinator.maxTempBasalRate` (currently 1.0 U/hr) — trivial to lower.

## DIST-3: No automatic dose reconciliation into IOB
**STATUS: Phase B BUILT + hardware-validated 2026-07-08** (branch
`watch-reconciliation`; design + validation record in `docs/IOB_RECONCILIATION.md`).
Watch boluses now enter the phone's DoseStore at their real timestamps on hand-back,
audited against the pod's delivered-odometer, guarded against duplicate hand-backs.
- **Remaining before distribution (Phase C):** negative net delivery (suspends / temps
  below schedule) is not written back — IOB is overstated for a few hours after such
  sessions (safe direction, transient highs). Retroactive suspend/temp records close it.

## DIST-4: Single-writer / phone pod release (also a core safety gap, tracked elsewhere)
The phone doesn't release the pod's BLE connection during a loan, so it can reclaim the
pod mid-loan. See **DESIGN-GAP-1** in `WATCH_LOAN_TESTING_BUGS.md`. This is a safety
prerequisite even for single-user (the single-writer property), not just distribution —
listed here for completeness so the distribution checklist is whole.
