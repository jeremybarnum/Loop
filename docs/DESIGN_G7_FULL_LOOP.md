# Design: G7 Full Loop — the phone-free watch runs stock Loop

_2026-07-15. Branch `g7-glucose-source`. Status: first phone-free closed-loop night run in progress
(watch reads G7 directly at 100% capture via pending-connect, injects EGVs into the glucose store,
loop closed, phone off). This doc consolidates the design reframe, the failure-mode audit, the
observability plan, the module plan, and the master to-do list. Every file:line below was verified
by a read-only code audit on this branch (2026-07-15)._

## 1. Governing ruling — "full Loop, no compromises"

The prediction branch was architected around **sporadic manual BG**: a synthetic anchor sample, a
restricted effects set (no momentum/RC), lenient staleness, tap-to-enter as the primary input.
The G7 direct reader removes the premise: the watch now has a **full 5-minute CGM heartbeat**
(validated: 13/13 windows, median gap 5m00s, pending-connect reacquire) **plus full pod control**.

**Ruling: the watch runs Loop's standard algorithm with (near-)zero modifications.** The manual
model is legacy; manual entry survives only as the fallback input that stock Loop already supports
natively (`wasUserEntered: true`). "Deactivating carbs" is moot — carbs already flow on the watch
(entry UI → `carbStore` → engine input) and stay fully active.

### The delta is small, and mostly deletions (verified sites)

| # | Change | Where | Note |
|---|--------|-------|------|
| 1 | **Delete the synthetic re-anchor** | `WatchPredictionEngine.swift:326-330` | Mandatory, not stylistic: the fabricated `StoredGlucoseSample(wasUserEntered:true)` carries default provenance `com.LoopKit.Loop` (≠ the store's watch-bundle provenance) and re-stamps the newest value at wall-clock `Date()` on every background refresh — both break momentum/ICE pairing. Pass the stored series verbatim; `LoopAlgorithm.generatePrediction` anchors on `glucoseHistory.last` itself. |
| 2 | **Remove the effects restriction** | `WatchPredictionEngine.swift:298` | Delete the `algorithmEffectsOptions: [.insulin, .carbs]` argument. `LoopAlgorithmSettings`'s default is already `.all` = insulin+carbs+momentum+retrospection (`LoopKit/LoopAlgorithm/LoopAlgorithmSettings.swift:40`). The full port is a deletion. |
| 3 | **Refresh runs off the stored series** | `WatchPredictionStore.swift:170` | Today refresh re-enters `predict(manualBG: newest.quantity, storeEntry:false)` — i.e. re-anchors through the manual path. Give the engine a `predict(fromStore:)` that takes the series directly (also fixes `PredictionView.swift:204-218`, the second consumer). |
| 4 | **Manual entry demotes to fallback** | `HUDInterfaceController.swift:247`, `ChartHUDController.swift:409`, `PredictionView.swift:22-126` (BGEntryView) | Keep the dial; it stores `wasUserEntered:true` and stock Loop handles the provenance natively. Relabel "(tap to enter)" → shows live G7 BG + freshness; dial becomes "manual override/fallback". |
| 5 | **No other algorithm change** | — | Staleness is already stock (15-min `inputDataRecencyInterval`, `LoopCoreConstants.swift:14`); enactment is already duration-parameterized straight from `generateRecommendation` (`WatchAutoLoop.swift:213-224`); the pod layer validates/expires temps like stock. |

Engine header comment (`WatchPredictionEngine.swift:9-12`) documents the old rationale ("momentum
needs a dense recent BG series… neither exists when the anchor is a single typed-in value") — now
satisfied by the G7 stream; update it when doing #1/#2.

## 2. Dosing correctness — P0 before anything beyond bench

Carried from `PREDICTION_CODE_REVIEW_2026-07-12.md` plus new audit findings:

1. **IOB clamp missing** — phone bounds auto-temps by `additionalActiveInsulinClamp` (maxBolus×2 − IOB); watch omits it.
2. **No `pumpSuspended` check** in `loopCycle` — phone refuses to auto-dose while suspended.
3. **TEMP-TEST-CAP** — revert `maxTempBasalRate` 3.0 → 1.0 (`WatchPodLoanCoordinator.swift:250-254`), resolve the display/enact cap mismatch, and decide the real ceiling.
4. **Unacknowledged commands reported as certain failure** — `.unacknowledged` collapses to failure (`PodProofKit.swift:625-626, 672-673, 692-693`) and the alert hard-codes "No change was made to the pod." (`WatchPodLoanCoordinator.swift:645`) — potentially FALSE: the pod may be delivering while journal+IOB exclude it. Model uncertain delivery like stock Loop. **Top safety gap (esp. bolus).**
5. **Untimed manual suspend** is the one pod state outside the temp-expiry safety net (`PodProofKit.swift:570-585`): watch death while suspended = zero basal indefinitely. Make manual suspend a bounded zero-temp (as the loop's own suspend already is) or add an auto-resume reminder.
6. **G7 EGV gating** — injection currently ignores the sensor state byte and applies no plausibility bounds (`G7Client.swift:919-933` → `G7GlucoseManager.swift:34-54`): warmup/ending readings would enter as full-effect CGM samples. Gate on state 0x06 (in-session), bound the value, and mind timestamping (late reacquires are stamped `Date()` at read, not EGV time).

## 3. Failure-mode status (audit 2026-07-15)

Safety spine: **a loop temp is bounded (~30 min) and the pod reverts to the stored schedule on
expiry** — so most failures degrade to "loop pauses, basal resumes". The loop already stops issuing
temps on stale BG (`WatchAutoLoop.swift:215`) without cancelling the running one (deliberate,
Loop-faithful).

| Mode | Today | Gap | Severity |
|------|-------|-----|----------|
| G7 signal loss / stale BG | Loop pauses at 15 min; HUD "Closed · paused — BG Xm old"; header dashes at 30 min | **Passive only — no haptic/notification when a closed loop silently pauses.** G7 reader health (`statusText`, `lastReadDate`, gap stats) rendered **nowhere**; complication still shows phone-context data (face lies in Show Mode) | continuity |
| Pod comms failure on enact | Failure haptic + loud alert; journal excludes failed cmds; amber horse on link loss | (a) `guard !busy` **silently drops** a closed-loop enact (`WatchPodLoanCoordinator.swift:619`); (b) unacked→"certain failure" (see P0#4); (c) loud alert needs the UI up | safety-critical corner (unacked) |
| Watch reboot / app kill | Relaunch reruns `g7.start()` (`ExtensionDelegate.swift:99`); loan grant persists to journal; **closed-loop resets to OPEN by design** (`WatchAutoLoop.swift:91-94`) | Nothing auto-relaunches; HKWorkoutSession doesn't survive reboot; no "session ended, loop is open" alert; manual-suspend corner (P0#5) | continuity + suspend corner |
| BT off / permission denied | Reader schedules retries; loop pauses via staleness | **Plausible wedge**: connect() parked while BT off never times out; `.poweredOn` recovery gated on `peripheral == nil` but `finishAttempt` never nils it (`G7Client.swift:535-560, 650`) → reader can stall until relaunch. Bench-test + fix | continuity |
| Watch battery death | Pod finishes last temp → schedule; phone shows "Pod Is On Loan" warning; escape-hatch reclaim exists | Manual-suspend corner; no low-battery pre-emptive hand-back/cancel | continuity |
| Phone reclaims (escape hatch) | Journal-hash-idempotent reconciliation on hand-back is solid | **Blind-IOB window** on reclaim-without-journal (known finding ①, `DeviceDataManager.swift:242-247`); unreachable watch keeps enacting into failures with no "revoked" inference | safety-critical (bench-bounded) |
| Sensor session ends/expires | Degrades into staleness path; reader polls forever | Indistinguishable from RF loss; **pairing PIN hardcoded `3102`** (`G7Client.swift:314-315`, no UI) — a replacement sensor fails silently forever; plus P0#6 state-byte gap | continuity |

## 4. Observability & communications

**Reality tonight:** the only phone-free-retrievable record is `Documents/g7watch.log` — and only
the G7 BLE layer writes to it. Loop *decisions* (AutoLoop/Engine) go to OSLog only (effectively
tethered-only retrieval), and `G7GlucoseManager` logs **nothing** (and ignores `addGlucoseSamples`
errors). The dosing record of record arrives retroactively via the existing hand-back
reconciliation (journal → phone → Nightscout, idempotent, real timestamps) — that chain is solid.

Plan (ranked):

1. **[S] Unified on-watch file log + port the WatchLink export bridge.** Route loop decisions
   (AutoLoop verdicts, engine inputs/outputs summary, G7GlucoseManager injections + errors) into
   the same file log; add `session(_:didFinish:)`/file-receive to the **existing** WCSession
   delegate (`ExtensionDelegate.swift:264` + `WatchDataManager.swift:468`) — do NOT add a second
   delegate. ~60 lines, field-proven in the old app; works on TestFlight builds where `devicectl
   copy` doesn't.
2. **[free] Keep the hand-back reconciliation as the dosing backbone** (already works; fails
   silently on an undecodable journal — add surfacing).
3. **[M] Direct watch→Nightscout.** `NightscoutKit` declares `.watchOS(.v6)` with zero deps —
   link it into the extension and post `entries` (EGVs) + `devicestatus` (loop state) each 5-min
   tick; the WorkoutKeepalive already provides runtime. Credentials sync from the phone via
   application context. **Dedupe rule:** watch posts entries/devicestatus only; treatments stay
   phone-side via reconciliation (distinct syncIdentifier namespaces if that changes). Two tiers:
   Tier-1 debug (the log bridge), Tier-2 **feature** — live remote monitoring, e.g. a child running
   phone-free while parents watch Nightscout. Watch WiFi works with phone off; cellular covers
   away-from-home.
4. ~~CloudKit log shipping~~ — dominated by 1 and 3.

## 5. G7DirectKit module (Phase 2 packaging)

**Shape: local SPM package `Loop/G7DirectKit`, cloned from the `PodSDK` (OmniBLECore) precedent**
(`XCLocalSwiftPackageReference`, `Loop.xcodeproj/project.pbxproj:5091`, linked at `:1502`). The
G7SensorKit-style xcodeproj subproject exists to serve the iOS `.loopplugin` runtime-discovery
architecture, which has **no watchOS counterpart** — don't imitate it.

Verified facts:
- **Blocker + fix (empirically tested):** SPM does *not* synthesize a Clang module from a
  static-lib xcframework's `Headers/` — `import g7auth` fails as-is. Dropping a 4-line
  `module.modulemap` (`module g7auth { header "g7auth.h"; export * }`) into **both** slices'
  Headers dirs makes it build, link, and run.
- **Bonus fix:** today's `OTHER_LDFLAGS` hardcodes the *device* `.a` paths in Debug+Release, so
  **watch-simulator builds can't link**; SPM binaryTargets do per-platform slice selection and fix
  this for free.
- **LoopKit coupling:** only `G7GlucoseManager.swift` imports LoopKit; LoopKit is not
  package-consumable (its Package.swift is marked non-working) → the bridge **stays in the appex**
  (OmniBLEShim precedent). `G7Client.swift`/`WorkoutKeepalive.swift` are package-pure; a facade
  file with `@_exported import g7auth` keeps G7Client byte-identical.
- **Name:** `G7DirectKit` is collision-free (G7SensorKit/-UI/-Plugin and CGMBLEKit-watchOS are
  taken); C module name `g7auth` is unique.

Migration steps (full detail in the audit): Package.swift (watchOS .v7, tools 5.9+/PodSDK style) →
`git mv` xcframeworks into `G7DirectKit/Binaries/` + modulemaps → move the two pure sources →
`linkedLibrary("c++")` → add the local-package reference + product dependency to the extension →
**clean the old plumbing** (HEADER_SEARCH_PATHS, the `.a`+`-lc++`/`-ObjC` LDFLAGS in both configs,
the `#import "g7auth.h"` bridging-header line, the orphaned `G7watchOS-Bridging-Header.h`) →
verify device **and** simulator builds + live EGV injection.

## 6. Master to-do list (consolidated, ranked)

**P0 — dosing correctness (before anything beyond bench)**
1. IOB clamp in the watch enact path (§2.1)
2. `pumpSuspended` check in `loopCycle` (§2.2)
3. Revert TEMP-TEST-CAP → 1.0; unify display/enact caps; decide the real ceiling (§2.3)
4. Uncertain-delivery modeling for unacked pod commands (§2.4)
5. Bounded manual suspend (§2.5)
6. EGV state-byte + plausibility gating in `G7GlucoseManager` (§2.6)

**P1 — full-Loop convergence + status honesty**
7. Delete the synthetic re-anchor (§1.1) and the effects restriction (§1.2)
8. `predict(fromStore:)` refresh path (§1.3)
9. Manual entry → fallback UI; HUD shows live G7 BG + freshness (§1.4)
10. Surface G7 reader health in the app + haptic when a closed loop pauses on stale BG (§3.1)
11. Complication shows watch-local BG in Show Mode (§3.1)
12. Per-sensor pairing-PIN UI (§3.7)
13. Reader wedge fix (BT off→on `peripheral` clearing) + surface the silent busy-drop enact (§3.2/3.4)
14. "Session ended — loop is open" alert after relaunch (§3.3)

**P2 — observability & comms**
15. Unified file log (loop decisions + G7GlucoseManager) + WatchLink export bridge port (§4.1)
16. G7GlucoseManager error logging (it currently ignores injection failures) (§4)
17. Watch→Nightscout direct uploads, entries + devicestatus (Tier-2 feature) (§4.3)

**P3 — structure & product**
18. G7DirectKit SPM package (§5)
19. **Pod beeps: VERIFY-ONLY (ruling 2026-07-15 — no watch-side setting).** Audited: watch-issued
    commands are already silent (OmniBLECore beep flags all default false; the facade never sets
    them; cancels use `.noBeepCancel`), and the pod's standing beep config (confidence reminders)
    is phone-programmed (`BeepConfigCommand`) and persists through the loan. The phone's
    "Silence Pod"/"Confidence Reminders" setting IS the single control — set it before granting.
    Remaining: one bench verification (silence on phone → loan → watch temp → confirm silent).
20. Blind-IOB reclaim reconciliation (finding ①) + adopt leftover watch temp on reclaim (§3.6)
21. ~~Fold in 3b-v2 phone-side status tiles~~ **LANDED 2026-07-15** (cherry-picked from
    `3b-v2-wip`, clean): phone polls the watch for Show-Mode status → pump tile shows
    **"On Watch" / "Watch Lost Pod" / "Pod Not Connected"**. Wording APPROVED by Jeremy 2026-07-15 — final.
25. **Install-over-Show-Mode behavior** — building to the watch mid-session kills the app
    (= the reboot/kill failure mode §3.3: workout keepalive dies, closed loop resets to open,
    loan grant survives via the persisted journal, pod runs its last temp to expiry). Verify on
    bench + decide if the installer path needs a "session was interrupted" alert. (Parked 2026-07-15)
26. **Loop open/close UX** — replace (or complement) the open/closed status line with tapping
    the loop indicator itself to enter the open/close ceremony. (Parked 2026-07-15)
27. **Carb entry in Show Mode** — the watch carb UI exists; enable it during sessions (engine
    already consumes carbEntries; "no reason not to support it at the rate we're going").
    (Parked 2026-07-15)
22. 3c: surface the abnormal-hand-back ⚠ marker
23. "Loop Crashed" false alert on phone restart (old-work list)
24. Rebrand Show Mode → Sport Mode (bundle already `com.SportMode`; app display name stays "Loop")

**Parked/validated** — pending-connect reacquire (SOLVED, 100% capture); coexistence role 0x01
(proven); D2W entitlements (unreachable, by design); HealthKit relay (dead, 3h delay).

## 6a. Ruling (Jeremy, 2026-07-15): Show Mode validity = DUAL sovereignty

A valid Show Mode session has TWO independent properties, and the UX must verify **both**:
1. **Pod sovereignty** — the watch holds the loan and has a live pod link.
2. **CGM sovereignty** — the watch is reading the G7 **directly** (affirmative proof: a fresh
   EGV via the watch's own radio — NOT a fresh sample in the glucose store, which the phone
   may have pushed).

Rationale — observed 2026-07-15: the G7 reader was dead for 3.5h while the loop ran happily on
phone-pushed BG. **The phone silently feeding BG is a trap**: the user leaves the phone behind
believing they have glucose, and doesn't. Provenance matters: watch-direct samples
(`syncIdentifier "g7-…"` / `G7Client.lastReadDate`) are the sovereignty signal; store freshness
is not.

Design:
- **Two separate status indicators** in Show Mode: pod link (exists — horse/podConnected) and
  **CGM-direct** (new: age of last *direct* G7 read, e.g. "G7 ✓ 2m" / "G7 — no direct read").
- **Activation gate**: entering Show Mode runs a sovereignty check — pod session up AND a
  direct G7 read within a timeout (~6 min ≈ one advertising interval + margin). On timeout,
  prompt: continue **without pod control** (CGM-viewer mode) or **without direct CGM**
  (phone-fed loop — explicitly labeled), or abort. Degraded modes are legitimate but must be
  CHOSEN, never silent.
- Dosing inputs unchanged: the loop may still consume phone-pushed samples when present (more
  data, same sensor); sovereignty is a *readiness/UX* concept, surfaced separately.
- Later: extend the status push payload (v2) with the CGM-direct flag so the PHONE tile can
  also show both properties.

## 6b. Bench validations (2026-07-15, live)

Watch-death arc, all devices nearby: Show Mode active → phone tile **"On Watch"** ✓ (update
felt slow — possibly pre-latest build, retest before logging as an issue) → watch battery died →
tile transitioned to the disconnected state ✓ (§3.5 surfacing works) → watch revived on charger →
**Show Mode not running** ✓ (per-session reset by design, §3.3) → phone **escape-hatch reclaim**
worked ✓ (§3.6). Open follow-ups from the arc: retest tile latency on the latest build; the
revived watch's journal hand-back (no doses this time — verify with doses on bench).

**Parked (2026-07-15): pump-agnosticism.** Show Mode currently presumes Omnipod (the loan is
OmniBLE/PodSDK-specific), but Loop supports other pumps. The phone side already has a protocol
seam (`PumpConnectionLendable`); the correct system-shape is: Show Mode offered only when the
active pump conforms, watch-side drivers per lendable pump. Low priority — design thought, not
work. (P3#28)

## 7. Morning-after triage for tonight's run

1. Pull `g7watch.log` (`devicectl device copy from --domain-type appDataContainer` — dev build, should work) → run `G7Watch/tools/soak_analyze.py` for capture %.
2. Loop decisions: not in the file log yet (P2#15) — read Nightscout after phone reconnect
   (hand-back reconciliation posts the dosing record retroactively) + the on-watch journal screen.
3. Battery: watch was on charger — treat power data as non-representative; the un-throttled
   conditions make it a *best-case* capture datapoint, not a battery datapoint.
