# Rulings register — Jeremy's dosing/design decisions (authoritative)

Every ruling Jeremy has made across the project's sessions, so no chat
re-litigates a settled question. If a question is answered here, it is
SETTLED; present a change as a proposal against the existing ruling, not as
an open question. Companion: `DESIGN_M5_INPUTS.md` (detail on R6/R7),
`DESIGN_FROM_STOCK_REBUILD.md` risk register (the questions NOT yet ruled).

## Settled rulings

- **R1 — No watch-specific caps.** All dosing limits derive from the phone's
  therapy settings (maximumBolus, maximumBasalRatePerHour), synced to the
  watch and enforced end-to-end (recommendation → UI → pod-command proof
  limits). Watch-local fallback caps exist ONLY for the pre-settings-sync
  window and should deny/block rather than invent numbers. Ruled when the
  original bench caps were removed ("remove any sport-mode specific caps.
  Use phone therapy settings for all safety").
- **R2 — Handoff keeps the running temp.** At loan grant the phone does NOT
  cancel its running temp (pod keeps executing it until the watch's first
  command supersedes); the phone's RECORD of that temp closes at the
  handover stamp (C5), and the grant→first-enact gap is covered by the
  odometer audit.
- **R3 — Suspend is a bounded rate-0 temp.** Never an untimed
  suspendDelivery: the pod itself auto-resumes at expiry, so a dead watch
  can never strand delivery off (P0#5).
- **R4 — Durations are user-chosen, stock-parity.** Manual temp: rate AND
  duration pickers over Pod.supportedTempBasalDurations (30-min grid,
  30 min–12 h, default 30 min). Suspend: stock's four options
  (30 m/1 h/1 h30/2 h). No invented fixed holds (the 3-hour hold is dead).
- **R5 — Max-exposure direction rule.** When delivery state is ambiguous the
  records model the MORE-insulin interpretation, per command semantics
  (bolus/resume: record; below-schedule temp: don't) so IOB is never
  understated. Direction-aware, not blanket.
- **R6 — Negative odometer remainder: one-way valve + three layers.**
  Positive remainders enter IOB (timed late = conservative); negative are
  never subtracted from arbitrary records. Layer 1 (pod-verdict resolution
  of uncertain commands) ships on the safety branch; layer 2 (provenance-
  tagged allocation) and layer 3 (residual surfacing + phone post-reclaim
  pod re-audit) are protocol-v2 scope. See DESIGN_M5_INPUTS.md §1.
- **R7 — Escape-hatch reclaim keeps dosing paused** until the watch journal
  arrives and reconciles; manually re-enabling Closed Loop in settings is
  the explicit user override (C6).
- **R8 — No phone-side heartbeat watchdog for loans.** Healthy Sport Mode =
  phone out of range for hours; a heartbeat monitor would false-alarm every
  session and train dismissal. Phone-side alarms are exactly: start-
  confirmation watchdog (5 min, cancelled by the watch's holdsPod push),
  loan-duration reminder (6 h), paused-dosing-after-reclaim reminder (1 h).
- **R9 — No dosing math from stale glucose, anywhere.** The stock 15-min
  inputDataRecencyInterval gates the auto-loop AND the manual/meal bolus
  recommendation; no placeholder BG values, ever (C12). Corollary (lenient
  staleness): a stale anchor stops NEW temps; an already-running bounded
  temp runs out on the pod's own clock rather than being panic-cancelled.
- **R10 — Resume never fabricates a schedule.** Resuming the bounded suspend
  = cancel the temp (the pod's STORED schedule — programmed by the phone —
  is the truth). Reprogramming the basal table requires the real synced
  schedule in its grant-captured timezone or the command refuses loudly;
  the flat-0.5 proof fallback is dead in the dosing path (C9).
- **R11 — PODLOAN ringfence.** Hardware-module deviations live in ONE
  +Feature extension file per module; unavoidable out-of-file touches carry
  a "// PODLOAN" marker; audit = read one file + one grep.
- **R12 — The pod is the source of truth for delivery.** The journal is the
  primary record, assumptions are tagged and reconciled against pod
  evidence (seq-number verdicts), the odometer audit is the backstop.
- **R13 — Explain-first protocol.** Every dosing-semantics decision is
  presented to Jeremy in plain terms with a recommendation and ruled on
  BEFORE code. One at a time.
- **R14 — Philosophy frame (Pete Schwamb per Jeremy).** Algorithm purity:
  no behavior-shaping heuristics without LoopAlgorithm counterparts
  (conservative safety BOUNDS are acceptable; behavior-shaping constants
  are not). Minimize the mental burden: no alarms on healthy operation, no
  rituals for failure states that can self-heal, stock UI semantics
  wherever stock is right.
- **R15 — Insulin curve follows the pump's insulin type** exactly as the
  phone selects it (PresetInsulinModelProvider mapping), never a hardcoded
  default (fixed 0f9e23ca).

- **R16 — From-stock watch caps: R1 confirmed; strategy is temps-only**
  (M5 session, 2026-07-17). No per-loan cumulative bolus ceiling ("no cap,
  for now"); the automatic-bolus dosing strategy is DENIED on the watch —
  temp basals only, every bolus human-confirmed. Resolves the :486 and :494
  TODO(M5-ruling) sites: current WatchLoopManager code (therapy-settings-
  only, deny-on-missing) is the ruled behavior.
- **R17 — Manual-bolus recency denial shows an explicit notice** (M5,
  2026-07-17). "No recent glucose — no recommendation" in the
  recommendation slot — "can't recommend" never masquerades as
  "recommend 0 U". The dial stays usable for a manual bolus under therapy
  maxBolus and carbs still log (C12 semantics). No confirmation
  interstitial. Resolves the :534 site.
- **R18 — Glucose input gating: chosen, never silent** (M5, 2026-07-17;
  completes DESIGN_G7_FULL_LOOP.md §6a, which ruled sovereignty
  display/readiness and deferred inputs). During a loan, dosing consumes
  only the watch's own direct-G7 stream by default; a stale direct stream
  pauses NEW dosing per R9's lenient rule. Phone-fed dosing exists only as
  the picker's explicitly chosen, labeled degraded mode — offered only when
  the phone is genuinely reachable and pushing fresh readings. StatusReport
  carries the sovereignty flag + dosing mode.
- **R19 — Watch HealthKit writes OFF; watch→Nightscout out of v2** (M5,
  2026-07-17). The phone is the single Health writer, after
  reconciliation; the watch stores run in LoopKit's no-HealthKit mode.
  CHALLENGE REVIEW COMPLETED same day, verdict: UPHELD, decisive
  mechanism code-verified — this vintage's phone observes other-app
  insulin/glucose from HealthKit BY DEFAULT (FeatureFlags.swift:140-157)
  and its HK-ingestion paths dedupe by HK UUID only (GlucoseStore
  :488-506, InsulinDeliveryStore :604-627), so a watch that writes HK
  guarantees duplicate phone cache rows; mixed provenance then silently
  zeroes glucose momentum (GlucoseMath.swift:92-100) in exactly the
  post-session windows that matter, and remote uploads/totals double.
  IOB itself survives (syncIdentifier union). FLIP CONDITION recorded:
  if a bench test proves cross-source syncIdentifier dedup with
  syncVersion precedence (watch v0 / phone v1) AND deletion propagation
  to anchored queries, HK-on-watch becomes a defensible durability
  upgrade (total-watch-loss is the one case the protocol can't cover) —
  the bench script lives in the challenge report; revisit only with that
  evidence. Nightscout: the phone remains the sole uploader; live
  remote-following during phone-away sessions is future scope, not v2.
- **R20 — Degraded-mode picker semantics** (M5, 2026-07-17). At
  activation: CGM-viewer (first-class: direct-G7 display, loop open, pod
  stays with phone) / phone-fed (offered ONLY when actually available,
  per R18) / abort. Mid-session CGM death: continue phone-fed (if real) /
  stay paused / hand back. Degraded modes are never silent (§6a) and
  options are never shown when they'd be lies.
- **R21 — The loan ring is live, not frozen** (M5, 2026-07-17; supersedes
  the crude build's constant saddle-brown ring). The watch now genuinely
  loops, so the ring shows stock freshness semantics of the WATCH's own
  loop during a loan; saddle-brown (#BF663A) becomes the Sport-Mode accent
  (tint/icon). CGM-viewer mode shows stock's open-loop glyph. The crude
  frozen ring was correct THEN (freshness meant phone-loop staleness);
  the premise changed.

- **R22 — Negative-remainder allocation: fingerprints only** (M5,
  2026-07-17; the R6 layer-2/3 detail). Layer 2 acts ONLY on fingerprint
  matches: exact-size annulment of a single `.assumed` event (within one
  0.05 U pulse; tie → the event closest to the failure) and retroactive
  recording of a flagged `.assumed(.skippedReduction)` window the
  remainder fits inside (the C′ case). Never `.confirmed`, never below
  zero. EVERY ambiguous remainder touches no record and surfaces whole as
  the layer-3 notice — IOB left overstated is the safe direction;
  newest-first partial reduction was proposed and REJECTED (a wrong
  reduction understates IOB in exactly the least-understood scenarios).
  Notice wording ruled verbatim (the shorter form): "The pod delivered
  X.XX U less than the watch session recorded. Records were not changed.
  Possible causes: pod fault, occlusion, or an interrupted command. Check
  the pod and review the session in Event History." — persistent phone
  notification + banner until acknowledged + Event History line.
  Mid-loan settings freeze also APPROVED same day (settings changes take
  effect at the next grant; the watch doses on the grant snapshot in its
  captured timezone).

- **R23 — Sport Mode watch UI** (2026-07-17): stock FLOWS stay, Sport Mode
  owns its SURFACES. Page map during a loan: Glance (new, landing) /
  Actions (stock, untouched — no pre-meal hijack) / Chart (kept, demoted) /
  Diagnostics (new, feature-flagged). Glance = layout "A number-first":
  dominant BG+arrow, eventual-BG small line, three-cell rail (IOB/COB/temp),
  R21 live ring-dot + saddle-brown SPORT tag, true-black OLED background.
  BG color ONLY out of range (white in range, amber high, red low —
  thresholds from therapy settings). Honest states: stale never looks fresh
  (dim + age + arrow drops), suspended shows the R4 auto-resume countdown,
  activation = idle glance page + crown ceremony, R20 picker lives there.
  Open/close the loop from the glance screen (2026-07-18): each loan starts
  OPEN/advisory; the loop pill toggles — close is confirmed, open is
  immediate (fail-safe); AND-ed with the phone's frozen dosingEnabled (watch
  can only be more conservative); reset OPEN each loan. Full record:
  docs/DESIGN_SPORT_UI.md.

- **R23 AMENDMENT — watch sovereignty over loop mode** (2026-07-18, Jeremy):
  "The watch should be understood as autonomous once it's in sport mode."
  The phone's OWN loop mode does NOT gate the wrist's per-session close —
  the old AND with the grant's frozen `dosingEnabled` is removed. Therapy
  settings (frozen in the grant) remain the only dosing limits (R1/R16).
  Companion UX principle, general: **no dead controls** — a control that
  can't act right now stays tappable and explains why ("no BG yet", "no
  pod"), and closing without BG is not refused: it ARMS, and the stale
  gate keeps it paused until readings flow.

- **R24 — Sport Mode connect/onboarding UX** (2026-07-18): return to the
  crude build's proven pattern — it "was very good and working perfectly"
  (Jeremy). Pod takeover: a DETERMINATE ~10-second progress bar (the pod
  reliably connected within 10s on the proven branch; the bar sets and
  meets that expectation). G7: a PREDICTED-connection countdown/ETA (the
  G7 transmits on a known ~5-min cadence, so the wait is predictable —
  show it). The current indeterminate "requesting…" spinner that either
  resolves or fails silently is a regression from that pattern. Happy to
  iterate the presentation, but the core concept is settled. Sequencing:
  implement AFTER the takeover BLE fix restores the ~10s pod connect —
  the progress bar depends on the connect actually being fast.

- **R25 — Hand-back, blackout alert, grant validation** (2026-07-19, Jeremy:
  "do all your recommendations"): (a) hand-back is TWO-PHASE STAY-ACTIVE —
  requesting it keeps the watch fully in control (dosing, boluses, G7 loop)
  while the journal drains via interim offers; ownership transfers only when
  the drain is acked; user can Cancel until finalize. Closed-loop dosing
  CONTINUES during the drain ("end Sport Mode" = ownership transfer, not
  therapy stop). (b) Sensor-blackout dead-man: no direct G7 for 20 min during
  a loan → notification + haptic, repeating while it persists;
  notification-only, no automatic actions. (c) Grant-time validation: an
  incomplete therapy snapshot DENIES the loan with the missing field named —
  never a silent per-cycle configurationError. Root-cause experiments E1/E2
  SKIPPED by Jeremy (no time); E3 rides normal 117+ use. Branch succession
  unchanged; R20 picker deferred until after WS1-WS3.

- **R26 — Takeover radio priority; pod-first flow** (2026-07-20, Jeremy: "the
  right flow is pod connects, which should be reliable, and gives the feedback
  on when the BG is expected. Then the BG connects when it connects, and at
  that point closing loop becomes an option"): the pod TAKEOVER outranks the
  G7 on the single watch radio. During the bounded ~40s takeover ladder the
  G7 client stands down (active scans stop, new attempts/pre-warms defer; a
  mid-flight handshake finishes; armed pending connects stay armed). Evidence
  2026-07-20 logs: takeover epochs 19 and 25 failed entirely inside G7
  scan/handshake windows ("couldn't reach pod" with the pod adjacent); epoch
  26's pod reads succeeded the moment the G7 handshake ended. The rest of the
  flow was already ruled and stands: loan starts OPEN (R23), G7 ETA feedback
  (R24), closing the loop unlocks when direct BG flows. Complement of Fix B
  (BG wins over routine loop pod commands) — priority is contextual: the
  user-initiated takeover is the one pod operation that outranks BG.

## Not yet ruled (do not decide without Jeremy)

- Risk-register #8: any on-body session of any milestone build — per-build,
  per-event authorization; never assumed.
- The :89 pump-connection TODO is not a ruling — it unblocks mechanically
  when loan-protocol-v2 exists (its ruling dependencies R16 are
  discharged); the v2 spec itself requires Jeremy's sign-off.
