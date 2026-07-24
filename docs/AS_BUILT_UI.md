# AS-BUILT UI MAP — Sport Mode surface

**Purpose.** A *ground-truth* map of what the UI actually does today, verified against
code with `file:line` anchors. This is deliberately distinct from the intent docs
(`RULINGS.md`, `DESIGN_SPORT_UI.md`): those capture **decisions**, which the code has
drifted from. When they disagree, **the code is what ships** — and the `## Drift & gaps`
section at the bottom lists every place they currently disagree.

**How to trust / maintain this.** Every claim cites a `file:line`. Spot-check by opening
the anchor. When you change a control, update the matching row here in the same commit.
Last reconciled against code: **2026-07-24** (build ~b107, post diagnostics-declutter).

---

## Watch page order (swipe left/right)

Page-based nav, storyboard-driven. Chain from `Interface.storyboard`
(`initialViewController="rNf-Mh-tID"`; `relationship="nextPage"` segues at lines 171 → 279 → 418):

| # | Controller | Origin | Contents |
|---|---|---|---|
| 1 | `ActionHUDController` (initial) | **STOCK** | Loop status HUD + 2×2 action grid: **Carbs · Bolus · Pre-Meal · Preset** |
| 2 | `ChartHUDController` | **STOCK** | Glucose chart HUD |
| 3 | `GlanceController` (`GlanceView`) | **CUSTOM** | Sport Mode glance (number-first) |
| 4 | `LoanDebugController` (`LoanDebugView`) | **CUSTOM** | Diagnostics / bench page |

During a loan, `StockLoopSession` auto-lands the user on page 3 via
`GlanceController.current?.becomeCurrentPage()` (`StockLoopSession.swift:96`).

The stock **Carbs/Bolus** flow is `CarbAndBolusFlowController` (a modal, not a page).

---

## Page 3 — Glance (the Sport screen)  ·  `GlanceController.swift`

Phases (`GlanceUIState.Phase`): `idle · starting · active · handingBack · draining`.
State is built by pure static funcs (`idleState`, `startingState`, `activeState`) so
previews/tests drive it; the `GlanceDemoView` gallery (DEBUG, reachable from the
diagnostics page) renders all of them. **Reworked 2026-07-24 (version C).** Anchored on
symbol names, not line numbers (the rework shifted them).

### Layout by phase
- **Top status line** (`statusLine`): loop **ring** on the left (active only — it IS the
  loop control); on the right, `statusRight` = the **End Sport Mode** chip (active) or the
  `SPORT bNNN` build tag (every other phase).
- **idle** (`idleCenter`): centered **Start Sport Mode** button (calm blue), small dimmed
  `iPhone NNN →` BG line above it. No 64pt number.
- **starting** (`startingCenter`): same calm layout — small `iPhone` BG line + the R24
  connect hero (`startingBlock`: stage + determinate blue pod bar + G7 ETA).
- **active** (`standardCenter` + rail): 64pt BG number + arrow, then `eventually NNN` /
  stale-age line / G7-ETA, then the IOB/COB/TEMP rail. **No body button.**
- **handingBack / draining** (`bottomBlock`): spinner + honest note.

### Control inventory (what each control ACTUALLY does)

| Control | Where | Action |
|---|---|---|
| Loop **ring** (stock `loop_<fresh\|aging\|stale\|unknown>_<closed\|open>`, `loopAssetName`) | top-left, active | **Tap toggles the loop** — open immediate (fail-safe); close → `confirmingClose` alert (**interim**; the crown ceremony is the pending #22 polish). Solid=closed, gapped=open; color = **BG recency** (`loopFreshness`, fresh<7m / aging<15m / stale), honest open OR closed. |
| **Start Sport Mode** | idle body (centered) | `startSportMode` → `requestLoan`. **One tap, unconfirmed** (#22). |
| **End Sport Mode** chip | top-right, active | `endSportMode` → `beginHandback` — R25 two-phase stay-active hand-back (dosing continues while records drain). |
| **Cancel Ending** chip | top-right, active if `handbackPending` | `cancelHandback`. |
| pod bar + G7 ETA | starting center | Display only (R24). |

`beginHandback` is now wired to the top-right End chip — **no longer orphaned.** Suspend
special-casing was removed (it was unreachable — `manualSuspendEnd` is never set); a
0 U/hr withhold shows naturally as **TEMP 0.00** in the rail.

---

## How a Sport session STARTS and ENDS today (ground truth)

- **Start:** watch glance idle → **Start Sport Mode** (one tap, `requestLoan`). Only entry point.
- **End — from the WATCH:** active glance **top-right End Sport Mode chip** → `beginHandback`
  (R25 two-phase stay-active; cancelable via the Cancel Ending chip). Wired 2026-07-24.
- **End — from the PHONE:** tap the pump status tile → **"Pod Is on the Watch → Reclaim
  Now"** → `reclaimPodLoanFromWatch()` (`StatusTableViewController.swift:1805` →
  `DeviceDataManager.swift:834`).
- **End — automatic:** phone T1 timeout / revoke / relaunch-recovery → `forceReclaimToOwner`
  (`PodLoanPhoneController.swift:653`).

---

## Page 4 — Diagnostics  ·  `LoanDebugController.swift`  (post-declutter 2026-07-24)

Readouts + a minimal button set (bench-only; the "real" UI is these Sport screens):
- **DOSING** — `closed? · BG · eventual · COB/IOB · recommend · running · last loop · [err]` (`:50`)
- **LOAN v2 BENCH** — readout + **Read Status** (live pod BLE ping, `debugReadStatus :993`) · **Reset (debug)** (force controller→idle, local only, `debugReset :1003`)
- **G7 IDENTITY** — readout + **Prewarm G7 Now** (`forcePrewarmNow`)
- **Logs** · **Glance demo** (DEBUG)

Removed 2026-07-24 (plumbing intact, git-revertable): experiment toggles E1/E2/E4/FakeBG/E5,
and the Request Loan / Hand Back buttons.

---

## Phone-side Sport touchpoints  ·  `Loop/Loop`

- **Pump tile tap during a loan** → reclaim prompt (above). `pumpStatusTapped` gates on
  `isPodLoanedToWatch` (`StatusTableViewController.swift:1805`).
- **Loan state machine** `PodLoanPhoneController.swift:27`: `owner · grantOffered · loaned ·
  reconciling · reclaimPending`. Tile shows "Pod on Watch" / "Reclaiming…" (`isReclaimInProgress :81`).
- **E4 production default** (2026-07-24): `g7.e4ReleasePod` now registers a `true` default;
  FakeGlucose + E5 forced off at launch (`StockLoopSession.swift` init).

---

## Resolved 2026-07-24 (were drifts; now reconciled in code)

1. **Loop toggle placement — RESOLVED.** The 2026-07-24 rework makes the loop **ring**
   the tap control (per the `RULINGS.md` "the loop pill toggles" intent). The old
   display-only pill + full-width body button are gone.
2. **Watch-side End — RESOLVED.** `beginHandback` is wired to the top-right End Sport Mode
   chip (R25 two-phase hand-back). Watch-side session-end now exists.

## Open items / still-pending polish

1. **Crown ceremony for loop-close (#22).** Ruled and intended, but not yet built — the
   ring's *close* currently uses the interim `confirmingClose` alert. Open is immediate.
2. **Two ambers.** The stock loop-ring amber (`loop_aging_*`) and the palette's
   `glanceWarn` (number-high / stale-age text) are different ambers; align `glanceWarn`
   to the ring for consistency.
3. **`DESIGN_SPORT_UI.md` / `RULINGS.md` not yet updated** for the 2026-07-24 rework
   (ring-as-control, BG-recency freshness, top-right End chip, calm-blue identity, suspend
   removal). Fold into RULINGS as a new/amended entry so intent tracks the as-built.
