# Sport Mode — Watch UI Design (decided 2026-07-17)

_Companions: mockups artifact (link in owner memory / claude.ai artifacts:
"Sport Mode watch UI mockups"), RULINGS.md R23, DESIGN_LOAN_PROTOCOL_V2.md
(the picker/mode semantics these screens render). Stance: stock FLOWS stay
(bolus/carb crown ceremonies, confirmation semantics — R14); Sport Mode owns
its SURFACES. UI cannot dose; every dosing path remains the ruled, tested code._

## Page map (during a loan)

1. **Glance** (new) — the sport surface and wrist-raise LANDING page during a
   loan. Its idle state (no loan) is the activation on-ramp. Outside a loan,
   stock landing behavior (incl. startOnChartPage) is untouched.
2. **Actions** — stock main HUD, untouched. No stock button is repurposed;
   pre-meal keeps its stock role (a shortcut re-purpose stays possible later).
3. **Chart** — stock, KEPT but demoted. Reasons: R14-free to keep; the most
   battery-expensive surface (live SpriteKit scene); its data source is
   phone-pushed context that goes stale during phone-away sport. Removal in
   sport mode is decided by bench/session usage data, not taste.
4. **Diagnostics** (new, feature-flagged) — the bench page evolved: monospaced
   phase/epoch/odometer/cursor/chase/G7-grid truth + bench controls. On in
   bench builds; one toggle from not existing. (Variant D's content lives
   here, not on the face.)

## The Glance screen (layout A — "number-first")

- **BG number + trend arrow**: dominant, ~88pt, tabular numerals. The number
  owns the screen; there is deliberately NO room for a fourth rail cell.
- **Color rule (decided)**: monochrome (white) while IN range; **amber above
  the high threshold, red below the low** — color appears exactly when it is
  the information (R14 in pixels). Thresholds from therapy settings, not
  invented constants (R1 spirit).
- **Eventual BG**: small line under the number ("eventually 128"). Dims/drops
  under the same staleness rules as everything else; empty when the algorithm
  cannot produce one — never a held-over prediction.
- **Bottom rail, exactly three cells**: IOB (U) · COB (g) · TEMP (U/h).
- **Status line**: left = loop state as form + words (ring-dot aging with the
  WATCH's own loop per R21 + "CLOSED · 2m"); right = SPORT tag in saddle
  brown #BF663A (the identity accent, R21).
- **True black background** (OLED: black pixels are off). All-screen design
  must remain legible in always-on dimming.

## Honest states (safety design, not decoration)

- **Stale glucose** (R9/§6a): number dims to grey, arrow drops, explicit age
  line ("9 min ago — no direct G7"), status shows PAUSED (no new temps).
  A stale reading must NEVER look fresh. Tap while stale → mid-session picker.
- **Suspended** (R3/R4): primary state, not an alarm — "insulin off · resumes
  H:MM" countdown makes the bounded duration visible.
- **Idle / activation** (R18/§6a): phone-fed BG shown DIMMED and labeled
  "via iPhone" (provenance always visible), one "Start Sport Mode" button →
  sovereignty checks → crown-confirm ceremony (the per-session closed-loop
  opt-in, kept). The R20 picker presents here on check failure; options are
  shown only when real (phone-fed only if the phone is reachable + pushing).
- **Open/close the loop from the watch** (2026-07-18, Jeremy — "like we did
  before, valuable as users gain confidence"): each loan starts OPEN
  (advisory — the loop computes and drives the glance display but does NOT
  enact). The loop-status pill on the glance screen is the toggle: tapping
  OPEN→CLOSED gets a confirm ("The watch will start adjusting your basal…"),
  CLOSED→OPEN is immediate (fail-safe, the stop-dosing direction — same
  friction asymmetry as suspend/resume). The watch flag is AND-ed with the
  phone's frozen `dosingEnabled`, so the watch can only ever be MORE
  conservative; when the phone disallows dosing the pill reads "OPEN · phone"
  and can't be closed. Reset to OPEN on every new loan (no silent carry-over
  of a closed loop between sessions).

## Connect / onboarding flow (R24, 2026-07-18)

Return to the crude build's proven pattern — Jeremy: the old onboarding "was
very good and working perfectly," happy to iterate presentation but the core
concept is settled.

- **Pod takeover: determinate ~10s progress bar.** On the proven branch the
  pod connected within 10 seconds, every time. The bar states that
  expectation and visibly meets it. Not a spinner; the user should see it
  fill and finish.
- **G7: predicted-connection ETA.** The transmitter wakes on a known ~5-min
  cadence, so the wait is *predictable* — show a countdown to the expected
  reading rather than an open-ended wait.
- The current indeterminate "requesting…" state (resolves or fails with no
  progress feedback) is a regression from that pattern and gets replaced.
- **Sequencing:** built after the takeover BLE fix restores the ~10s pod
  connect — the bar depends on the connect actually being that fast.

## Decision record

| # | Decision | Outcome |
|---|---|---|
| 1 | Glance layout | **A — number-first** (B too dense, C loses temp slot — its ring may return as a visual refinement of A's status dot, D belongs in Diagnostics) |
| 2 | Eventual BG on the face | **Yes, small**, with staleness honesty |
| 3 | Activation | **Idle glance page + crown ceremony**; no stock-button hijack |
| 4 | Chart | **Keep, demote to page 3**; usage data decides removal |
| 5 | Landing during loan | **Glance** |
| 6 | Diagnostics | **Feature-flagged**; on in bench builds |
| 7 | BG color | **Color only out of range** (white in range, amber high, red low) |
