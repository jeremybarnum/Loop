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

## Not yet ruled (do not decide without Jeremy)

The eight reserved decisions in DESIGN_FROM_STOCK_REBUILD.md's risk
register, plus the four TODO(M5-ruling) sites in
"WatchApp Extension/StockLoop/WatchLoopManager.swift" (:89 pump connection,
:486 automatic-bolus strategy, :494 max-temp derivation, :534 manual-bolus
recency-denial UX), plus layer-2/3 implementation details (provenance tag
schema, allocation order, residual-notice wording).
