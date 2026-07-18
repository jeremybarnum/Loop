# Crude-branch takeover screen — extracted rebuild spec

Source: LoopWorkspace-prediction `WatchApp Extension/Views/WatchPodControlView.swift`
(`untetherSection`, lines ~226-289) + `Managers/WatchPodLoanCoordinator.swift` +
`Managers/WatchPredictionStore.swift`. Extracted 2026-07-18 for the R24 UI pass —
Jeremy: "the old takeover UI in other branch was very elegant." Rebuild in the
glance's design language (true-black, #BF663A accent), not verbatim.

## Layout (VStack, spacing 8)
1. Header: "Sport Mode" (.headline).
2. **Pod row** — `connectionRow`: label "Pod" (caption semibold) · status text
   (caption2; green when done) · green `checkmark.circle.fill` when done ·
   determinate capsule bar below (height 6, track white 14%, fill green;
   ~11s calibration, +0.2/11 per 0.2s tick, capped 0.95; snaps full + ✓ on
   active). Status strings: "Requesting…" / "Connecting…" / "Connected".
3. On activation the screen HOLDS (doesn't auto-dismiss): full-width **"OK"**
   button + caption2 "OK to leave your phone" — the untether-safe moment.
4. **Glucose row** — same `connectionRow` but NO bar (expectation, not a gate):
   "Reading directly" + ✓ once a direct read lands (read ≥ activation shown, or
   within 60s), else "in ~N min" (5-min grid, rounded up, clamped 1–5,
   "~5 min" fallback with no sample).

## Failure / edge states
- Stall (takeoverStalled): bar replaced by "Pod isn't responding" + "It's still
  trying in the background. Keep trying, or cancel, wait a few seconds, and
  start again." + buttons "Keep Trying" (arrow.clockwise) / "Cancel".
- Failure (not active, retry keys): Pod row status "Couldn't reach pod",
  empty bar, buttons "Try Again" / "Cancel".
- Denied: "Couldn't start Sport Mode" headline + reason + "Try again".
- Done: green ✓ "Watch tethered", or (revoked) blue iphone icon + "Reclaimed by
  iPhone" + "Sport Mode was ended from your iPhone. Insulin records were sent
  back."; then live summary + "Start Sport Mode" button.
- Handing back: ProgressView + "Ending Sport Mode…".

## Reconciliation notes for the fromstock glance (R24)
- Keep: determinate pod bar (ours: 10s, accent fill, 95% cap — equivalent),
  G7 ETA line (ours is min:sec precise; crude was ~N min coarse — keep min:sec
  steady-state, "G7 by ~clock" for first connect per field data).
- ADD from crude: two-row checklist legibility (Pod / Glucose as labeled rows
  with ✓ confirmation), the post-activation HOLD with "OK to leave your phone"
  (the crown-ceremony slot), "Reading directly ✓" confirmation, stall/retry
  affordances (Keep Trying / Cancel / Try Again) instead of silent idleNote.
- Functionality reconciliation (regressions found 2026-07-18, fixed in code):
  watch bolus routes LOCALLY during a loan; loop open/close pill made visibly
  tappable (bordered) — a proper control belongs in this UI pass.
