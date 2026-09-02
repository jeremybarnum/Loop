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
- **R2 — Handoff keeps the running temp.** ~~At loan grant the phone does NOT
  cancel its running temp (pod keeps executing it until the watch's first
  command supersedes); the phone's RECORD of that temp closes at the
  handover stamp (C5), and the grant→first-enact gap is covered by the
  odometer audit.~~
  **OVERTURNED 2026-08-11 by R33 — see below.**

- **R33 — Clean boundary: each controller asserts its own program**
  (2026-08-11, Jeremy: "what about simply canceling any running temp as part of
  takeover, running a fresh loop/prediction at takeover, and enacting a new temp?
  we don't lose more than 5 minutes of dosing and it clarifies things" — and
  "I think we should do it on handback, as well").

  NO PROGRAM CROSSES THE BOUNDARY. At takeover the watch immediately runs a full
  cycle and enacts its own temp, superseding whatever the phone had running.
  Supersedes R2.

  Why R2 fell: its own text delegated the grant→first-enact gap to "the odometer
  audit" — and on 2026-08-11 that audit was found never to have printed a usable
  number (it compared the whole-loan odometer delta against a single drain's
  doses, so a clean loan read as 6.000 U missing). The ruling was resting on a
  net that was not reporting.

  What the inherited temp actually cost: it is the shared root of #72 (unbooked
  post-takeover tail), #76 (re-arm copy divergence), the C5 record-close that
  silently truncated the running temp at every release, and a systematic audit
  bias — `expectedInsulin` predicts the SCHEDULE across any window it has no
  journal segment for, so an inherited 0.90 U/hr against a 0.70 schedule accrues
  ~0.20 U/hr of unexplained delivery, about two pulses on a 27-minute tail, i.e.
  bias sitting on top of a one-pulse tolerance. Two controllers sharing one
  program is the defect; a clean boundary removes it instead of accounting
  around it.

  Cost, measured: none in delivery — the new temp supersedes the old in the same
  command, so there is no gap. One extra pod command inside a BLE session we are
  already holding. The takeover prediction is trustworthy at that instant: field
  2026-08-11 reconciled IOB to the phone within 0.05 U and eventual BG within
  12 mg/dL, because the grant seeds the phone's own history and snapshot.

  Implementation: a full `loop()` at takeover rather than a bespoke enact, so it
  inherits every existing gate (inherited closed-loop mode, glucose recency,
  pump-data freshness, DoseMath limits, IOB clamp), logs a normal CYCLE VERDICT,
  and mints a JOURNAL EVENT — which is the point: the loan's first program is
  ours, streamed to the phone, and inside the audit.

  HAND-BACK HALF (amended and BUILT 2026-08-11): the automatic temp is CANCELLED at
  hand-back; the pod reverts to the user's schedule; the phone sets the new rate on
  its next reading. The phone does NOT get an off-cycle dosing trigger.

  WHICH DEVICE CANCELS — corrected the same day, by the field. The first build put
  the cancel on the watch. It cannot be there. Between dose windows the watch has
  deliberately released the pod's BLE link, so at hand-back its cancel fails in
  about a millisecond with `podNotConnected` — 15:23:37.130 "cancelling our temp
  (1.75 U/hr…)", 15:23:37.131 "CANCEL FAILED". There was no round-trip to fail;
  there was no link. The same missing link is why the watch's odometer freshen also
  fails and why every hand-back audit on record printed `fresh=N`. One cause, both
  symptoms — and it is a cause no watch-side fix can reach, because the released
  link is the design.

  So the PHONE cancels, on its verified reclaim round-trip (~seconds after
  hand-back), via `LoopDataManager.cancelTempBasalAfterPodReturn` — the same bare
  `.cancel` idiom, just issued by the device that is actually holding the pod. The
  principle is untouched: no automatic program outlives the controller that set it.
  Only the enforcing device moved to the one that can enforce it.

  This is also strictly better therapy across the boundary. The pod keeps running
  the watch's last automatic rate — a real recommendation from real CGM data,
  minutes old — until the phone can reach it, instead of dropping to schedule at an
  instant when nobody can command anything. Continuous, not gapped.

  And the same round-trip supplies the audit's end reading, which is the deeper
  point: the phone was already talking to the pod there (#42's reclaim chase) and
  throwing the odometer away. See `PodLoanPhoneController.finishPendingHandbackAudit`
  — one conversation, both jobs, no new machinery.

  My first reading of this was wrong twice over and Jeremy pushed back on both.
  I claimed stock never acts between readings — it does: `LoopDataManager
  .cancelActiveTempBasal` enacts a bare `.cancel` outside `loop()` for
  `automaticDosingDisabled`, `unreliableCGMData` and `maximumBasalRateChanged`.
  And I claimed cancelling leaves the pod "uncontrolled" — it does not; reverting
  to the user's own scheduled basal is precisely the fallback stock chooses
  whenever it is unsure.

  The principle the Loop authors were actually being stingy about, and which we
  now adopt explicitly: OFF-CYCLE, ONLY EVER MOVE TOWARD LESS INTERVENTION.
  Cancelling is always safe (it falls back to the user's own schedule); SETTING a
  new therapeutic rate requires a fresh prediction from fresh CGM data, which only
  the reading cycle provides. Hence the deliberate asymmetry between the halves:
  at TAKEOVER the watch REPLACES the program (safe, because it computes a fresh
  recommendation from freshly seeded data at that instant); at HAND-BACK the watch
  CANCELS it (safe, because cancelling always is). Neither side ever sets a rate
  without current data behind it.

  THE BUG THIS EXPOSED: the cancel already existed (DESIGN-5 in finalizeHandback)
  but had been DEAD CODE since E4 became the default. It was gated on
  `manager.status.basalDeliveryState == .tempBasal`, and E4 orphans the pod link
  between doses, so by hand-back that state reads nil even though the pod is still
  delivering — the condition #50 was opened for. Field 2026-08-11, both hand-backs:
  zero pod commands between "drain complete — finalizing hand-back" and the pod
  release, 0.5 s apart. Every loan's last temp has been running on after the pod
  went home. Fixing the gate was necessary but not sufficient: with the gate fixed
  the cancel fired and then failed on the dead link (above), which is how the real
  cause surfaced. Two layers, found one after the other, same afternoon.

  Note for the next reader: the phone's cancel is deliberately NOT gated on
  `basalDeliveryState == .tempBasal`. That gate is exactly what made the watch's
  version dead code, and after a loan the phone's cached delivery state describes
  the world before the loan. A redundant cancel costs one round-trip on a link we
  already hold and moves toward less intervention; a skipped one leaves someone
  else's temp running. The cached state is logged at each cancel so we can decide
  later, from data, whether a guard would have been safe.
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

  **R21(b) — Ring freshness = loop-completion age ONLY (2026-08-30; supersedes the
  2026-07-24 "ring = BG recency" refinement).** Phone parity, adopted from the port
  line's 2026-08-24 ruling after three clean field days there: fresh ≤6 min, aging
  ≤16 min, exactly the phone's LoopCompletionFreshness model, with loop recency
  inherited across loan boundaries in both directions. The BG-recency semantics made
  the ring amber on CGM staleness while the loop itself was healthy — Jeremy's own
  field observation ("no looping after 9 minutes on the phone would definitely
  produce amber") is what forced the reversal. BG staleness keeps its own surfaces
  (the reading's display-staleness handling); the ring stops moonlighting as a CGM
  indicator. Implementation lands with the notification stock-parity port.

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

- **R23 OVERTURNED (loop mode only) — the wrist follows the phone** (2026-08-04,
  Jeremy): "I'm confident enough in the system now that when the loan starts, if
  the phone was on closed loop, I want to loop closed… for the production user's purposes,
  following the phone will be more intuitive." So: **if phone closed, watch
  closed; if phone open, watch open — and the same on the way back, the loop
  inherits the watch state.** This supersedes BOTH R23's "each loan starts
  OPEN/advisory… reset OPEN each loan" and the R23 AMENDMENT's removal of any
  phone influence on the wrist's mode. Everything else in R23/R24 stands — the
  pill still toggles, close is still crown-confirmed, open is still immediate.
  Explicitly provisional: "Maybe, if we release this more broadly, we could go
  back to always open." The reason is intuitiveness for a second user, NOT a
  change of confidence in the fail-safe.

  Wire: `LoanGrant.phoneClosedLoopEnabled` (outbound, frozen at grant like the
  therapy settings) and `HandbackOffer.watchClosedLoopEnabled` (return). Both
  optional — nil from an older counterpart falls back to the PREVIOUS behavior
  (start OPEN / restore the pre-loan capture), so build skew degrades to the old
  rule rather than to an unintended closed loop. The return value is written into
  the same persisted key the reclaim already restores from, so it inherits the
  relaunch-survival and the "missing capture defaults to OPEN" fail-safe.

  KNOWN CONSEQUENCE, accepted: because the phone now inherits the wrist, a
  session that ended OPEN on the watch leaves the phone in open loop after the
  pod comes home — including if the watch opened itself. Flagged at ruling time
  and chosen anyway for symmetry; the inheritance is logged on both sides
  (`[loop] … inherited from the phone at grant`, `[phone] loop mode INHERITED
  from the wrist`) so it is never silent.

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

- **R27 — Deferred UI rulings, parked at LOW priority** (2026-07-20, Jeremy:
  "keep these in low priority todo list", tasks #21/#22 — ruled, not yet
  scheduled): (a) While the pod is on the watch, the PHONE must not display
  anything that "cannot be right unless you know whether insulin or carbs
  have been delivered on the watch": prediction, IOB, COB. Historical carbs,
  insulin-delivered history, and live BG history stay. (b) Confirmation
  inversion on the watch: starting Sport Mode needs NO confirmation
  ("pointless"); CLOSING THE LOOP gets one, ideally the Digital Crown
  confirm pattern — the friction belongs on the dosing decision (R23
  confidence model), not on the low-stakes start.

- **R28 — Phased hardening roadmap; prediction freeze** (2026-07-20, Jeremy:
  "definitely don't make any changes to the prediction flows at this point —
  we're just gathering data"): the path to a locked-down system is strictly
  ordered, and prediction/dosing internals are FROZEN except as each step
  explicitly requires:
  STEP 1 — lock down the Dexcom BG read to the greatest possible certainty,
  probably including coexistence with Dexcom direct-to-watch (tasks #15/#32).
  STEP 2 — close the loop; confirm a REASONABLE prediction is generated and
  triggers temp basals, and that nothing crashes. Reasonableness, not
  correctness, is the bar here.
  STEP 3 — verify the prediction is CORRECT given its inputs, using the
  logged internals ([predict] per-cycle decomposition, build 134).
  THEN — complete lockdown of the functioning internals, and only then
  iterate the UI, with certainty that no key building block is touched.
  Instrumentation (logging) is always allowed; behavior changes to
  prediction/dosing flows require naming which STEP demands them.

- **R29 — Dosing-limit validation needs simulation; Jeremy is not diabetic**
  (2026-07-20): Jeremy's on-body BG range is narrow (~50–100 mg/dL all day) —
  euglycemia never exercises the high-BG dosing paths. Max temp basal,
  suspend threshold, high-BG corrections, and clamp behavior (R1/R16 frozen
  settings) MUST be validated by SIMULATION with a production-like glucose
  profile (T1D ranges, e.g. 180–300 mg/dL excursions) driving the watch loop
  against a bench pod — never inferred from Jeremy's field sessions. Field
  sessions validate acquisition/plumbing; simulation validates dosing limits.

- **R30 — Carb deletion on the watch: sport mode only, any row, no ceremony**
  (2026-08-08, Jeremy: "in regular mode it's read only. Which makes sense
  because the premise is you have the phone and that's where you should do
  editing. But in sport mode you are presumably only with the watch... no
  crown ceremony for deletion - it's the safe direction").

  The stock watch already ships the screen — `CarbEntryListController`, reached
  by tapping active carbs on the chart HUD, rendering time + grams per row with
  no graph and no per-row absorption. Sport mode reuses it with different
  wiring, the same pattern as every other screen.

  Three parts, all ruled:
  1. **SCOPE: every row is deletable**, including carbs the PHONE created before
     the loan. One rule, nothing to explain. Extends the authority the wrist
     already has over overrides (`.overrideChange`) rather than inventing a new
     class. The rejected alternative — watch-entered carbs only — would need
     provenance markers to explain why one row swipes and another does not,
     which is exactly the extra information this screen exists to avoid.
  2. **AVAILABILITY: sport mode only.** Regular mode stays READ-ONLY and
     unchanged, because in regular mode the premise is that you have the phone,
     and editing belongs there. No new non-loan delete transport.
  3. **CEREMONY: none.** Swipe reveals Delete, tap deletes. Deleting carbs
     lowers COB, which lowers predicted glucose, which makes the loop dose
     LESS — the conservative direction — and it is recoverable by re-entering
     the carb. That is categorically different from carb ENTRY, whose crown
     ceremony (R23-adjacent) exists because a mis-entered carb was
     unrecoverable on both devices. Landing this ruling weakens that premise,
     so the carb crown ceremony becomes revisitable.

  IMPLIED, NOT OPTIONAL: deletion must propagate to the phone. `ingestGrantCarbs`
  makes the watch an authoritative mirror at every takeover, so a loan-local
  delete would be RESURRECTED at the next grant — the user deletes it, watches
  it vanish, and it returns still driving dosing. Deletion therefore rides the
  loan journal as a new `.carbDeleted` event carrying the syncIdentifier,
  ordered by seq exactly like `.overrideChange`, inheriting the per-loan seq,
  commit cursor, resend-until-ack and hand-back drain. #89.

- **R31 — E4 retired as default; machinery deletion gated on one long OFF run**
  (2026-08-08, Jeremy: "Okay make the change and ship it", on the A/B analysis).

  The A/B (build 257, epochs 265-267, same evening/bench): G7 capture — the metric
  E4 exists to protect, and the metric that outranks takeover (standing rule) —
  was PERFECT in both arms: 8/8 five-minute windows E4-ON, 4/4 E4-OFF, read ages
  3-7 s, zero sensor errors, and the pod and G7 links were verifiably simultaneous
  in the OFF arm. E4-ON's measured costs in the same log: 5-6 s of scan+connect
  radio per cycle placed exactly INSIDE the G7 window (backwards relative to its
  own intent), the night's only enact failure (21:47:42 — a cancel-temp enacted
  while the reclaim it triggered was still scanning; a failure class only E4
  creates), an ~10 s tax on every manual bolus, and marginally slower takeovers.

  Measured OFF steady state: the DASH pod drops an idle link exactly 2:55 after
  the last command, every time; the standing auto-connect re-lands it in
  1.3-2.1 s (4/4) — which also field-verifies the #97 re-arm fix in its natural
  habitat. The July evidence FOR E4 (157's 44/44 overnight) predates the fixes
  that removed its rationale: #31 window-aware comms, #54 scan-adopt, #94
  Code=11 backoff, R26, and the #97 standing-connect re-arm.

  Ruled: default `g7.e4ReleasePod` = false. The toggle stays. Deleting the E4
  machinery (reclaim ladder, deferred-release timer, e4ReclaimPodForDose seams)
  waits for one LONG OFF session — overnight or a full sport session — clean on
  G7 coverage. Caveats owned: the OFF arm was 20 minutes, one evening, bench
  topology at pod RSSI -81; on-body signal is stronger, favouring OFF further.

  **AMENDED 2026-08-10/11 (#101 phase 2, Jeremy: "let's make sure we understand
  what's actually going on with E4 and implement it coherently not as a toggle
  in the diagnostic screen").** The A/B above measured only STEADY STATE — both
  arms are indeed equivalent there. What it could not see is ACQUISITION, and
  there the two arms fail in opposite ways, proven the same evening by the toggle
  experiment plus the build-263 radio census:

  - OFF (held pod link) starves the acquisition scan: 0 adoptions across ~130
    minutes of held-link windows; adoption within 7-10 minutes of each of the
    two releases. A session that never adopts never reaches the steady state
    the A/B measured.
  - ON collides by construction while un-adopted: the per-cycle reclaim fires
    ~100 ms after the relay reading — the same grid instant the D2W ride
    appears — and the pod scan kills the G7 connect mid-establishment (census
    23:31:48). Post-adoption the collision is harmless because the DIRECT read
    triggers the cycle and has already completed (23:36/23:41/23:46 coexistence).

  Ruled (supersedes "default false; the toggle stays"): the toggle is REMOVED.
  Link policy is automatic — orphan between doses with per-cycle reclaim (the
  most-validated rhythm: E5 84/84, 157 44/44, 263 3/3), the reclaim gated on
  G7 acquisition state while un-adopted, and G7 sensor identity persisted
  across launches so the un-adopted phase is once per sensor, not once per
  relaunch. The "one long OFF run" deletion gate is moot; the E4 machinery is
  now simply the link policy's implementation.

- **R32 — Uncertain hand-back ⇒ the phone loop goes OPEN, plus a loud warning**
  (2026-08-11, Jeremy: "when the redelivery is uncertain, the phone loop should go
  open… that plus a loud failure warning", confirmed on request).

  When a hand-back cannot be established as complete — records not committed, or
  committed but failing their reconciliation against the pod — the phone does NOT
  resume closed-loop dosing. It goes OPEN: glucose still displays, manual control is
  unaffected, and the algorithm enacts nothing automatically. The user is told
  loudly and once (not once per retry — see #102's alarm-fatigue finding: 10-12
  identical warnings for a single benign-to-dosing bug).

  Rationale, in Jeremy's terms: your blood sugar is what it is, but your IOB and your
  carbs might be wrong, so do it the field-fashion way — look, decide, dose by hand.
  This is the standard response to uncertain delivery (an occluded pod, a lost pump
  session), so it is stock-shaped rather than invented, and it is strictly
  conservative: the failure mode of going open is under-treatment you can see and
  correct, not silent over-delivery.

  Note this is a DIFFERENT state from the common case, where a hand-back simply has
  not finished: there the watch still holds the pod and keeps dosing, so there is no
  therapy gap and no open-loop decision to make (field 2026-08-11: 57 clean watch
  cycles while the phone was wedged). R32 governs the case where the pod has come
  home and the books are untrustworthy.

  Supersedes nothing, but it is the safety half of the reconciliation redesign that
  the 2026-07-27 odometer ruling ("re-enable if/when the reconciliation warning is
  redesigned with a proper threshold") left open. Odometer-derived IOB injection
  remains OFF and unruled; going open is what we do instead of guessing.

  **R32(b) BUILT 2026-08-11 — sign-aware, with deliberately loose bounds.**

  Until this build the answer to "what happens when the odometer disagrees?" was:
  nothing. The residual was logged and no code read it. R32 was ruled but only its
  first trigger (records not committed) was wired.

  The two directions are not the same failure and do not get the same response:

  - POSITIVE (pod delivered MORE than our books) beyond **+0.20 U** → the loop goes
    OPEN, loudly. There is insulin in the body the algorithm cannot see, so closed
    loop would dose on top of it. That is stacking; the remedy is to stop the machine.
  - NEGATIVE (pod delivered LESS than our books) beyond **−0.20 U** → warn, keep
    looping. The books carry phantom IOB, so the algorithm believes more insulin is
    working than there is and doses LESS. The error is self-limiting, decays out
    within DIA, and R22's annulment already retires the identifiable cases. Opening
    the loop here would worsen the actual failure — under-treatment — which makes
    this the one direction where R32's remedy is the wrong medicine. (Jeremy
    approved the asymmetry when it was proposed; it is a refinement of R32's
    unconditional text, recorded here so the divergence is deliberate and visible.)

  **R32(c) TIGHTENED 2026-08-13 — ±0.5 U → ±0.20 U, from the bank.** (Jeremy: "make
  it warn and open loop asymmetrically as we discussed when the difference is more
  than .20 units".) The ±0.5 U above was loose ON PURPOSE — ten pulses, chosen when
  every residual available had been measured against the watch's stale endpoint, i.e.
  against the wrong interval, so tightening from it would have been fitting to
  known-bad numbers. `finishPendingHandbackAudit` fixed the interval, the bank filled
  with clean phone-read samples, and the review the log had been demanding is now done.

  The distribution it was set from: **n=13, mean −0.031, worst |0.200|, min −0.200,
  max +0.000.**

  What that distribution says, and it is the whole reason this is a safe change: the
  residual is systematically NEGATIVE. Every one of the thirteen samples is at or below
  zero, and the open-loop direction has never once been observed. So the bound that can
  stop the machine is being tightened into territory the field has never entered — it
  costs nothing in false trips against the measured data while catching a real
  over-delivery six pulses sooner than before. 0.20 U is still four pulses, well clear
  of the quantization artifact #107 measured at roughly half a pulse per temp
  replacement.

  The negative bound is the one that now sits ON the data: the worst banked sample is
  exactly −0.200, so a loan marginally worse than anything yet seen will warn. Deliberate.
  That direction never opens the loop, so a trip costs a notice rather than a therapy gap,
  and under-delivery is exactly where early visibility is wanted while the distribution
  fills in. If routine loans start warning, that is information — either the books are
  drifting or the bound wants to be −0.25.

  Note what was NOT built: the cycle-count-scaled threshold sketched during the review.
  A flat bound is what was ruled, and the data supports it — the residual does not visibly
  grow with loan length across the banked samples (28-, 54- and 56-minute loans all land
  inside ±0.20). Revisit only if a multi-hour session shows accumulation; the samples are
  short-loan-heavy, which is this ruling's main evidentiary weakness.

  **The self-reminding mechanism, re-armed.** `bankResidual` persists every authoritative
  residual and prints `residual bank: n=… mean=… worst=…` at each hand-back. It used to
  count to ten and then print `** R32 THRESHOLD REVIEW DUE — … the ±0.50 U bounds were set
  with none **` at every hand-back until someone acted. Someone has now acted, so that text
  would print a falsehood forever — the same cry-wolf failure OBS-8 was about. It now states
  the bounds' provenance and counts toward a RE-review at 40 samples, which is the ring
  capacity, so it trips exactly when the entire window is fresh evidence gathered under the
  tightened bounds. The reminder stays in the log rather than in this file because a doc only
  reminds you if you re-read it.

  Implementation note: opening the loop deliberately does NOT go through
  `setAutomaticDosingPaused(true)`. That call pairs with a `(false)` at the next
  loan's end which would silently re-close the loop — one loud warning followed by
  the machine quietly resuming, which is worse than never warning at all. The
  dependency clears the pre-loan capture first, so only the user's own settings
  change re-closes the loop.

  **R32(d) — Odometer reconciliation: bands and verdict scope (CLOSED 2026-08-27,
  supersedes the 2026-08-13 provisional bounds and the 2026-08-26 deferral).**
  Ratified on the port line 2026-08-27; confirmed by Jeremy for this register
  2026-08-30. Text as ratified:

  The reconciliation verdict is WINDOW-SCOPED: every audit — clean hand-back or forced
  reclaim — judges [last checkpoint → end], where a checkpoint is any mid-loan odometer
  reading reconciled against a complete record set (LoanOdometerSnapshot.asOf on streamed
  batches and interim offers). A contactless loan has no checkpoints, so its forced reclaim
  degenerates to the whole-loan window: the emergency case is unchanged by construction.

  Bands, ratified tight: window verdict ±0.20 U both signs (positive → open loop + book gap
  dose at reclaim; negative → warn only; urgency symmetric per 2026-08-24). Checkpoint
  acceptance uses the SAME ±0.20 — one number, one meaning: a window the final verdict would
  bless also checkpoints. A window outside the band is CARRIED, never retired; residuals
  quantize to milli-units before comparison (the band boundary turns on the pulse grid, not
  float representation — e223/e225 both tripped at nominal equality).

  Evidence: field noise floor across ~90 windows (e227, e232) — worst |0.10|, overwhelmingly
  0.000; real-signal test — a 1.5 U unsynced bolus read +1.500 exactly and its gap dose was
  retired by the watch's real record on return (e227); payoff case — e232's 8h37m loan
  accumulated −0.450 whole-loan drift (−0.05 U/h truncation bias) across 77 accepted windows
  and closed silent, where the whole-loan band had false-opened e222 (+0.35/9h) and e223
  (+0.200/3.1h).

  Consequences: the whole-loan residual is diagnostics only — banked for trend, tripwire
  logged (never acted) beyond 0.5 U. The IOB/decay-weighted residual proposal is closed
  unbuilt: windows make timing known at ~5-minute granularity, leaving decay-weighting
  nothing to correct. The re-review nag retires; future band review, if any, reads the
  worst-window-per-loan series banked from this ruling forward. Safety propagation: the
  checkpoint design + bands must reach the pure and Caitlin lines with the port.

- **R34 — The D2W piggyback closed two lines of inquiry. Do not reopen them.**
  (2026-08-11, Jeremy: "#38 and #39 can both be retired. They've been rendered
  irrelevant by the D2W piggyback.")

  Both are natural ideas that a fresh reader will re-propose. They were good ideas
  against the OLD architecture, in which the watch ran its own G7 session with its
  own crypto. It doesn't; it rides the Dexcom watch app's session.

  RETIRED — **Juggluco on Android Wear as a precedent** (was #38). Its whole value
  was answering "is our ~77% catch rate a G7-sensor ceiling or a watchOS-specific
  one?" by comparing against the only other standalone direct-G7-from-watch
  implementation. We no longer run a standalone session, so the comparison is
  against an architecture we abandoned — and the piggyback handed us a far better
  control anyway: Dexcom's own watch app, same OS, same watch, same wrist, running
  live. Ask what D2W shows before theorizing (that rule predates this and is why
  the experiment is redundant, not merely stale).

  RETIRED — **HealthKit as a redundant glucose source** (was #39). It was always
  phone-present-only, i.e. useless for the countryside case that motivates the
  whole project, and the piggyback subsumes the redundancy it offered since the
  Dexcom watch app is on the wrist by construction. If it is ever revisited, the
  firewall from the original note still stands: display and cross-check only, never
  silently feeding the dosing glucose store (single-writer invariant).

- **R35 — The watch DoseStore is CONFIG ONLY. No dose data, and no dosing fallback.**
  (2026-08-11, Jeremy: "for dose store the answer is stop pretending. Use it for
  settings or whatever and that's it. No fallback at all.")

  The watch keeps a LoopKit DoseStore solely as a carrier for configuration the stock
  math needs — basal schedule and its override-applied variant, ISF and its
  override-applied variant, insulin model provider, longest effect duration. It is NOT
  a book of record, NOT seeded with dose history, and NOT a dosing source of any kind.
  `SessionInsulinLedger` is the only insulin book on the watch.

  NO FALLBACK is the operative half. Today the cutover is guarded by three conditions
  (flag on, ledger non-nil, override-ISF accessor non-nil) and any miss SILENTLY reverts
  that cycle's insulin effects and IOB to the store — with no marker on the log line to
  say so. A dosing path that can change its source of truth without announcing it is
  worse than one that refuses. So: **if the ledger is unavailable, the watch does not
  dose.** It fails the cycle loudly, the same shape as any other missing-data refusal.

  Why the store was never worth trusting for this anyway (#111, verified 2026-08-11):
  the watch's PersistenceController runs `isReadOnly = true` — the appex heuristic from
  LoopCore misclassifies the watch extension, which is the OWNER process, not an iOS
  sidecar — so every save silently no-ops and the store's dose rows have never reached
  SQLite. They are pending inserts in one long-lived context, invisible to the
  NSBatchDeleteRequest purges, which is why #110's wipe leak was unclearable. We were
  falling back to a book that does not persist.

  Consequences, all deletions: the wipe-then-seed apparatus, the wipe-audit and its
  force-repurge, and the seed identity machinery all go. #110 and #111 stop being bugs
  to fix and become code to remove.

  THE SECOND BOOK MOVES, it does not disappear. The value of `[ledger-diff]` was never
  the DoseStore — it was having two independently-derived numbers that must agree. That
  role now belongs to the POD'S OWN ODOMETER via the hand-back audit, which is a
  physical pulse count rather than a derived shadow, and which became trustworthy on
  2026-08-11 when the phone started reading it first-hand (item 1). A better instrument
  replaced a worse one; the principle is unchanged.

  Load-bearing detail not to lose in the deletion: `doseStore.lastAddedPumpData` is
  currently the pump-data recency clock that gates dosing (`pumpDataTooOld`) and the
  per-cycle reclaim cadence. It must be owned directly rather than read off the store.

- **R36 — Delivered carbs carry their wire identity INTO the store; the store
  inserts-if-absent.** (2026-08-13, Jeremy: "if the idea is that when something is generated
  externally and the transmission is uncertain and lossy, then the events need unique IDs …
  there's essentially no difference in terms of safety risk between doing that with insulin
  and doing that with carbs. And actually I would argue it's riskier with carbs.")

  The principle: a record authored on one device and delivered over an at-least-once
  transport must carry a source-minted identity end to end, with dedup enforced ATOMICALLY
  at the sink store — not by caller sequencing, which is a race one layer down (#118's
  lesson). Insulin always had this (pod-minted `raw`, DoseStore upserts on it); carbs did
  not, because stock's CarbStore is an authoring surface that mints identity per add — and
  #119 (twelve phantom copies, 120.7 g COB, max basal) is what that asymmetry costs. The
  risk asymmetry runs the WRONG way: phantom carbs drive OVER-delivery, phantom insulin
  records drive under-delivery.

  Implementation: `CarbStore.addCarbEntry(_:syncIdentifier:)` in LoopKit — additive,
  insert-if-absent on (provenance, syncIdentifier), lookup and insert in one operation on
  the store's queue. INSERT-IF-ABSENT and never upsert: a late replay must lose to any
  later local edit of the same entry. The identity is the watch journal event UUID, minted
  once at authoring, unchanged across every resend. The store already practiced this
  pattern privately for HealthKit ingestion; this exposes it for the loan.

  This ruling also RELAXES the LoopKit-modification bias, deliberately and narrowly:
  additive, contained ingestion surfaces on our LoopKit branch are acceptable when the
  alternative is caller-side machinery that cannot be made atomic. Behavioral changes to
  existing LoopKit surfaces remain out.

## Not yet ruled (do not decide without Jeremy)

- Risk-register #8: any on-body session of any milestone build — per-build,
  per-event authorization; never assumed.
- The :89 pump-connection TODO is not a ruling — it unblocks mechanically
  when loan-protocol-v2 exists (its ruling dependencies R16 are
  discharged); the v2 spec itself requires Jeremy's sign-off.

- **R37 — The dead-watch reclaim: audit, hold-open, escalate, and book the gap**
  (2026-08-13, Jeremy, from the watch-battery-dies field test; supplies the ruling
  OBS-9 deferred as #120/#121).

  When a loan ends by force-reclaim — the watch unreachable, dead, or lost — the phone
  does NOT resume automatic dosing on whatever records happened to stream. It runs the
  same odometer audit a clean hand-back gets, holds dosing until the verdict, and then:

  - **Clean (|residual| ≤ 0.20 U):** automatic dosing resumes, one log line, no alarm.
  - **Positive beyond +0.20 U** (the pod delivered insulin the records cannot explain —
    the typical dead-watch case): the loop OPENS and stays open, the alert rides the
    urgent channel (time-sensitive + foreground banner), and the gap is BOOKED as a
    bolus timestamped at the reclaim — zero decay, maximum IOB, the conservative
    direction. Booking is code-configurable
    (`PodLoanPhoneController.bookUnattributedInsulinOnForceReclaim`, default true);
    turning it off keeps the open + alert.
  - **Negative beyond −0.20 U:** warn urgently, keep looping — R32(b)'s asymmetry,
    unchanged: phantom IOB under-doses and decays out, and opening would worsen the
    real failure.
  - **Unverifiable** (no baseline, no odometer in the read, or the pod unreachable
    through the settle window): treated as dirty, never as clean. Open + urgent alert.
    "Cannot verify" must never quietly become "assume fine".

  Decided as a SUBCATEGORY of R32(b), not a separate protocol (Jeremy delegated the
  choice): a dead watch is the limiting case of incomplete books — "if I'm being told
  nothing, I treat that as zero insulin delivered" — and the same bounds, bank and sign
  asymmetry apply. The baseline that makes it possible is banked at LOAN START from
  takeoverComplete's post-takeover odometer, while the watch is still alive to send it.

  **The watch's return replaces the estimate, without asking.** Its journal re-offers
  the unstreamed events; the real doses commit with their true timestamps, real carbs
  commit through R36's insert-if-absent identity (carbs are never invented — no
  source), and the placeholder retires by its deterministic syncIdentifier
  (PODLOAN-ODOGAP-e<epoch>) in the same completion — real records first, then the
  delete, so the transition never passes through neither. No approval gate, argued and
  accepted: the records are ground truth already validated in aggregate by the odometer,
  suppressing truth would contradict loop-is-stateless, and the IOB change at return is
  always DOWNWARD (the placeholder was booked at zero decay), so auto-apply only removes
  conservatism. The user gets a disclosure notice with the numbers instead of a prompt.
  Retirement is keyed on persisted state (restart-safe, stale-offer-safe for a watch
  that returns after a newer loan), and a failed delete is loud and retried — silent
  failure there is a double-counted IOB.

  Also under this ruling: ANY alert that opens the loop — R32(b)'s regular hand-back
  verdict included — now rides the urgent channel. An alert that stops automatic dosing
  must never be a quiet list entry.

- **R42 — Carbs are insulin on a delay: carb writes get dosing-path scrutiny, and carb
  uncertainty resolves toward ABSENCE** (2026-08-15, Jeremy, reflecting on the phantom-carb
  pile-up: "I feel like the project should have had a governing principle that applied extra
  scrutiny to that… accidentally recording carbs, on closed loop, eventually becomes the same
  thing, albeit more slowly.")

  On a closed loop a carb record IS a dosing command with hours of latency, and its danger
  direction is INVERTED relative to insulin. A phantom insulin record overstates IOB and makes
  the loop UNDER-dose — the safe side. A phantom carb record overstates COB, so the loop doses
  more AND defends less against lows, across the whole absorption tail, which outlasts
  insulin's decay. Thirty phantom grams at 1:10 is roughly a 3 U dosing error delivered
  stealthily over hours, with no single event for the user to notice.

  Therefore:
  - Every carb-writing path carries the same identity, idempotence, and review discipline as
    dose enactment. Reviewing a carb path as if it were bookkeeping is the mistake.
  - No machine path may originate, duplicate, or RE-originate a carb. A deleted carb that
    comes back is a machine-authored add, whatever the mechanism — the earlier delete-
    propagation defects are violations of THIS rule, not merely sync bugs.
  - Carbs exist only by explicit user action, exactly once.
  - Where insulin uncertainty resolves toward PRESENCE (book the assumed dose, maximum IOB),
    carb uncertainty resolves toward ABSENCE.
  - Software may PROMPT for a suspected meal — stock's missed-meal notification is the model,
    and it only ever offers to log — but it may never book one.

  Review test for any new code: if this path misfired, could a carb row exist that no human
  typed, including a deleted one returning? If yes, it is a dosing path; review it as one.
  Tests must assert delete-stays-deleted across at least two grant cycles, since a
  resurrection only appears on the re-seed.

- **R41 — Loop mode INHERITANCE reaffirmed: it travels with the pod, both directions, no change**
  (2026-08-14, Jeremy, on a challenge — the alternative was considered and rejected.)

  Closed on the phone at grant means closed on the wrist; closed on the wrist at hand-back
  means closed on the phone — and identically for open. The ONLY exceptions are the force-
  reclaim path and a large insulin discrepancy, whose verdicts open the loop loudly.

  Context, so this is not re-proposed: a field test read as "phone reclaim opens the loop,
  watch End doesn't." The code was already symmetric — both directions inherit the last mode —
  and the variable was the wrist's own state: the user had opened the wrist loop during that
  session's testing, and inheritance carried it home faithfully. (A "loans start OPEN" default
  was cited during the discussion; that rule is DEAD on the device path — it survives only in
  the simulator fake-flow driver. The real grant inherits the phone's mode.) The alternative
  (restore the phone's pre-loan mode at normal end, dropping inheritance) was considered and
  rejected. The user's last loop mode is the loop mode, wherever the pod happens to be.

- **R40 — The dead branch forces immediately, and every reclaim gets one short determinate bar**
  (2026-08-14, Jeremy, superseding R39's two-attempt wait on the dead branch — his own ruling,
  overturned on his own evidence and framing.)

  THE SETTLE'S SLOW MODE WAS A BUG, NOT PHYSICS. The bimodal distribution R39's bar was built
  for (70 of 91 settles in 1-11 s, 21 in 24-190 s, nothing between) was diagnosed the same day:
  the verification call skips the radio whenever the pump manager judges its data fresh (under
  6 minutes) and returns the stale lastSync forever; 77 such calls in ~150 ms each over one
  169 s settle, no radio involved. With the forced-read backoff in place, every settle on the
  fixed build finished in 1-3 s with zero stale reads — six samples: one forced, two phone-tap,
  three watch-End — and end-to-end tap-to-verified ran 3.2-7.1 s, phone-tap and watch-End
  indistinguishable.

  THE RULING, in three parts:

  1. **Watch present: one 10 s determinate settle bar.** No two-stage re-baseline — the stage
     boundary was calibrated to a distribution the bug produced. Overruns hold at the 0.95 cap
     with seconds ticking, under the unchanged 5-minute ceiling. Known and accepted: one
     afternoon of clean samples is evidence, not proof; a reclaim during an in-flight G7
     acquisition is unsampled; the rare WCSession transport stall (~80 s once in 20) would hold
     the bar at cap until the live ladder's 25 s force resolves it. Wrong-is-fine covers all
     three — the cap-and-hold is the designed degradation.

  2. **Watch absent: no wait at all.** The dead branch sends its revoke fire-and-forget and
     forces immediately — tap to done in seconds instead of 20-plus. Jeremy's framing, which is
     the honest justification: the realistic force-reclaim is a LOST watch or a DEAD BATTERY,
     where nothing can answer; and the scenario that looks risky — a live watch in a bag —
     cannot normally reach the dead branch, because an alive watch's 300 s log pulse (keepalive
     holds the app awake; 283-302 s across 134 gaps) keeps it inside the liveness window and on
     the live branch. The guard was always the pulse discriminator, never the wait. The
     eight-for-eight unanswered dead-branch revokes are consistent but near-tautological (the
     bench tests had the watch off by design) and are NOT the load-bearing argument. The revoke
     still goes out: a returning watch consumes it from the queue, which arms the split-brain
     guard and drives the booked-gap retirement — validated three times in the field the same
     day. The force still defers behind an in-flight commit.

  3. **Forced settle: a 15 s bar**, looser than the ordinary one because the clean forced
     sample is n=1 (+1 s); the prior +45/+66/+70 s forced settles all carried the stale-read
     signature of the bug. Tighten when the data says so.

  Deleted with the wait: the dead branch's "Reaching watch…" / "Watch silent…" labels (no wait
  left to label), the dead→live ladder promotion (no window left to promote in — a watch that
  wakes after the force follows the ordinary returning-watch path), and the slow-mode settle
  phase and its "Link slow…" copy. Reachability-triggered revoke resends still count against
  the live ladder's two-attempt budget.

- **R39 — The reclaim button tells the truth about time: two branches, two attempts, no flat wait**
  (2026-08-13, Jeremy: "I'm skeptical of the need for the 45 second wait. Seems pedantic. I
  think it's step 1 - check if watch visible. If yes, assume quick reclaim with a predictable
  progress bar. If no, display something appropriate and try a couple of times before force
  reclaiming, again with predictable timeline." Retry count ruled at TWO attempts.)

  Reclaim Now sent a revoke and then waited a FLAT 45 SECONDS before force-reclaiming,
  regardless of whether the watch was alive. With a dead watch the user watched an
  indeterminate sweep for the full 45 s — measured in the simulator: tap 22:38:08, verdict
  22:38:53. The wait was not a liveness probe. It was a DRAIN window, sized for the worst case
  and charged to every case.

  **The two regimes are separable BEFORE the wait starts, and the separator is the loan pulse,
  not reachability.** The watch transfers its log every 300 s while a loan is active —
  metronomic: n=134 gaps since 2026-08-08, range 283.1-301.4 s, ZERO excursions past 302 s. Age
  of last watch contact therefore separates the six field revokes with enormous margin: the one
  live revoke had a 6.5-SECOND-old pulse; the five dead ones had silences of 5.5, 6.1, 12.1,
  14.8 and 21.2 MINUTES. Reachability alone would not do this — `isReachable` in this codebase
  is a CHANNEL SELECTOR (urgent vs queued), never a liveness verdict, and it reads false for a
  healthy watch whose app is merely backgrounded. It is admissible only as a positive signal:
  reachable NOW proves alive, but not-reachable proves nothing.

  **The branch, on tap:**

  - **LIVE** (last contact younger than 330 s — one pulse period plus margin — OR reachable
    now): expect a fast drain. Deadline 10 s, one retry, force at 25 s.
  - **DEAD** (older, and not reachable): say so immediately and stop pretending. Deadline 8 s,
    one retry, force at 20 s.

  Both branches are TWO ATTEMPTS before forcing, per the ruling. The retry exists for the watch
  that is merely asleep and wakes; it is not a hope that a dead watch will answer.

  **Why 10 s covers the live case.** The drain is two urgent WatchConnectivity round trips plus
  one Core Data commit, with NO pod round-trip on the critical path: the single field revoke
  drained 9 doses in 2.32 s, and 20 current-era hand-backs (same machinery, same transport) put
  trigger-to-final-ack at p50 1.0 s. 10 s covers 16/20 outright; the retry captures 19/20. The
  20th was an 80 s WatchConnectivity transport failure — not a drain problem, and deliberately
  surrendered to the force path rather than charged to everyone as a longer deadline.

  **What the user is promised.** Whatever the branch, the pod round-trip is additive after the
  drain: 3-9 s, p50 4 s, n=20/20 current era. So the honest live-case promise is ~5-15 s, and
  the honest dead-case promise is ~20 s plus the pod. Both are determinate; both are stated on
  screen. `DeviceStatusHUDView.setActivityFill` already exists and is public, and
  `reclaimPhase1Progress` already computes a fraction with ZERO consumers — the determinate bar
  is mostly a matter of publishing a phase and a real deadline instead of the hardcoded 25 s.

  **What shortening the wait costs, stated plainly.** Reclaiming earlier makes it likelier that
  a returning watch finds a NEWER loan already started, which makes its offer stale — and a
  stale offer skips the e44 backfill by design, so its temps can vanish at the delivery-store
  boundary again. Also lost on any early reclaim: the wrist's final loop-mode inheritance, and
  one R32 calibration sample (force-reclaim residuals are not banked, by R32(c)). These are the
  reason the LIVE branch stays generous enough for a real drain to finish rather than being
  tuned to the p50.

  **What made this safe to do at all** is that late-arriving records now land: the e44 backfill
  upserts by store identity past the boundary, and it runs on the returning-watch offer path
  regardless of loan state. Before that fix, shortening this wait would have been trading a
  cosmetic annoyance for lost insulin records.

  Two corrections this ruling makes to the record: the source comment calling this "the 45 s
  reachability timeout", and the test that repeats the phrase, are both wrong — nothing read
  reachability to decide that timer. It fired on `state == .reclaimPending` and nothing else.

- **R38 — A comment must stand on its own where it sits**
  (2026-08-13, Jeremy: "to the greatest possible extent, I'm trying to keep the code
  standalone reasonable, which I know lives in tension with having the comments not be
  too verbose").

  A reader must be able to understand a piece of code without leaving the file. No comment
  may lean on a reference the reader cannot resolve in front of them:

  - **`#NNN` task numbers — removed.** They look like stock's `#123` but are not. Stock's
    resolve to public GitHub issues; ours resolve to a backlog that exists only in chat
    history, so the same syntax that informs an upstream reader informs nobody here.
  - **`R-NN` ruling numbers — also removed from code**, which is the sharper half of this
    rule. Being resolvable *in-repo* is not good enough: one directory away is still a hop,
    and the citation goes stale the moment a ruling is amended. State the constraint, not
    its docket number.
  - **`TODO` / `FIXME` stay.** Stock uses them, they carry their whole meaning inline, and
    they are a convention a Loop developer already reads fluently.

  The transformation, where a reference is removed:

  - If the reference DECORATED an otherwise complete explanation, delete it and stop. This
    is most of them — e.g. `// MARK: - Glance surface (R23; display only — no dosing paths
    read this)` already says what R23 requires, so the token is pure subtraction.
  - If the reference WAS the explanation (`// #101: unconditional now`), replace it with one
    sentence stating the constraint — what must hold and why the code is shaped that way.
    Not the incident, not the date, not who said it.

  Where a ruling's force is partly that it WAS ruled — R35's refusal to fall back, R32's
  sign asymmetry — keep the imperative and drop the citation: write the prohibition
  ("never substitute the raw schedule; refuse instead") so a future reader knows not to
  casually undo it without needing to look up why.

  **Runtime log strings are out of scope.** A `#NNN` inside a `SportLog.event(...)` body is
  a field-diagnostic breadcrumb that appears in logs we grep; changing it alters observable
  output and is not a comment edit. Left alone deliberately.

  On the tension Jeremy names: **standalone wins, brevity is the constraint rather than the
  goal.** A comment that is long because the thing is genuinely subtle is correct; a comment
  that is long because it recounts how we found out is not. The test is whether a competent
  reader who has never seen this project's history can act on it.

  Note the irony and its limit: this is a ruling saying not to cite rulings. RULINGS.md
  remains the register of DECISIONS — it is where a future session looks before
  re-litigating something settled. It simply stops being a dependency for reading the code.

- **R40 — The seize family: phoneless loan start + watch wake-resume** (designed with
  the port session 2026-08-30; three core rulings ratified there, two arms ruled here
  the same day. Built CAITLIN-BRANCH-FIRST by Jeremy's explicit call — a deliberate,
  feature-specific inversion of the next-dev-leads policy.)

  FRAMING: a DORMANT GRANT, not a new protocol. The phone continuously re-issues the
  grant to the watch (on pod change, settings change, and checkpoint) carrying FULL
  RECORDS — Jeremy ruled the checkpoint-only distinction not meaningful; carbs/COB/
  overrides are needed for dosing, not just IOB safety. Seize = the watch activating
  the dormant grant offline. Wake-resume = the same ladder pointed at the watch's own
  persisted active-loan state. Reunion = an ordinary hand-back offer for a loan the
  phone never granted, retro-acknowledged (capability-gated). Crypto rides the static
  DASH LTK + the AUTS/SQN resync path the contactless force-reclaim already exercises.

  R40(a) — AUTHORITY: the pod belongs to whoever is with the body. On any detected
  conflict during a seized loan, the phone yields. Always.

  R40(b) — ENTRY GATE: seize is never a first-class button. The user asks for a loan;
  the watch tries the normal grant request first with a short timeout; only on
  no-answer does it offer the offline path behind a deliberate confirm. Reachability
  warnings are ADVISORY, never blocking (signals lie both ways on the watch).

  R40(c) — RESIDUAL RISK ACCEPTED: a false separation can have both sides dosing for
  the blackout. Records merge correctly at reunion (distinct identities); the exposure
  is mid-blackout IOB blindness bounded by the 6 h insulin horizon and caught by the
  reunion audit. Accepted explicitly.

  R40(d) — STALENESS: NO CAP, NO TIER (ruled 2026-08-30; a warn tier was ruled first
  and REVERSED by Jeremy the same hour: "I don't think we should cap stale
  credentials"). The seize confirm always shows the grant's age ("Last synced with
  phone N ago — settings and history from then") and that informed consent is the
  entire contract — no thresholds, never a refusal. Context: settings already freeze
  mid-loan on this line (R22 note: changes apply at the next grant), so a stale
  dormant grant is the same freeze with a longer tail, and settings-change is itself
  a refresh trigger.

  R40(e) — AUTO-RESUME CAP (ruled 2026-08-30, against the gates-suffice
  recommendation — Jeremy's rationale, recorded verbatim in intent: wake-resume is
  EXCEPTIONAL functionality and must not become the routine mechanism for super-long
  phoneless loans; the cap enforces that posture): a CLEAN wake fingerprint (own SQN, odometer fully explained by the
  watch's own program) auto-resumes with a notification only within a threshold
  (initially 6 h — the insulin horizon — tunable); beyond it, even clean fingerprints
  degrade to offer-to-resume behind a deliberate confirm. Ambiguous fingerprints
  (SQN-jump-only, truncated journal tail, pod near expiry) always offer rather than
  auto-resume; force-reclaim fingerprints stand down to viewer and alert.

  PHONE MIRROR: after any pod blackout beyond M minutes with a dormant grant
  outstanding, the phone's first pod contact is a STATUS READ ONLY, and ownership must
  resolve via WCSession before it enacts. Blackout posture: pod and watch both dark
  with a dormant grant outstanding → quiet hold (no aggressive pod retries, no
  loop-failure alarm cascade). Tripwires: unexplained odometer delta, a running temp
  the phone never enacted, SQN jump on reconnect.

  R40(f) — REUNION PROMPT (ruled 2026-08-31, overruling the auto-hand-back
  recommendation; the auto version was built overnight and REPLACED the same morning on
  Jeremy's call. His rationale, near-verbatim: he is "starting to rethink how
  exceptional the seize should be", and reachability is not presence — the "phone
  could be lost in the house but still on WiFi"): when the phone becomes reachable
  during a seized loan (30 s debounce; one prompt per reachability transition), the
  watch PROMPTS — wrist alert plus an active-screen choice, Hand Back / Keep — and
  NEVER auto-ends the loan. Hand Back runs the ordinary hand-back (WS1 drain, token on
  the offer, retro-ack); Keep continues the seized loan until the next transition or a
  manual End. Consequence, accepted explicitly: the dual-controller window
  (field 2026-08-30: the returned phone dosed AS OWNER while the watch held the loan)
  now stays open for as long as the prompt sits unanswered — the PHONE MIRROR above is
  therefore the load-bearing safety mechanism, not a belt, and rises accordingly in the
  build order. Kill switch: PodLoanWatchController.seizeAutoHandbackDisabled (gates the
  prompt).

  CONFIRMED KEPT 2026-08-31 after field-testing BOTH answers (Keep 2026-08-30, Hand
  Back 2026-08-31 — retro-ack, clean drain, honest books in 14 s): "I think it's fine
  to keep phone is back prompt." The silent-reunion reconsideration is CLOSED; do not
  re-ask. The kill switch stays as a bench lever only.

  PHONE MIRROR — OPERATIONAL SPEC (2026-08-31, Jeremy's "minimum deviation" paradigm,
  designed off the canonical-scenarios table; this makes the 2026-08-30 MIRROR
  paragraph buildable):

  THE INSIGHT: a discovered seizure is the granted-loan-with-dead-watch scenario with
  one missing bit of knowledge, and the pod supplies that bit. The pod's counters are
  a flight recorder — odometer, running-temp identity, EAP/SQN session counters.
  CLEAN = fully explained by the phone's own command history; DIRTY at .owner =
  definitive proof a second controller drove during the gap. The pod says WHETHER,
  WC says WHO, the human says WHAT NOW, and M only says when to believe the pod.

  DETECTION: state == .owner AND books dirty AND dormant credential outstanding AND
  watch absent (no WC, no recent loan pulse). Structural gating, not tuning: a
  watchless user, or a watch user who never loans, grows no credential — their phone
  stays bit-for-bit stock. Consider capability decay (drop the credential after weeks
  of no watch contact) so lapsed users regress to stock too.

  M: not a UX dial — the trust threshold beyond which an unexplained pod delta means
  FOREIGN rather than the phone's own lost-ack settling (below it, the existing
  uncertain-command chase owns discrepancies). Default 10 min, tunable. No scenario's
  user experience depends on its value.

  POSTURE ON DETECTION: enter the posture the phone would already be in had it
  granted the loan — implemented presentation-level ONLY (a yieldingToInferredLoan
  flag on .owner; the state machine never fakes .loaned: the retro-ack door
  deliberately requires .owner, and the watch's real epoch is unknown). Pill reads
  Pod on Watch — technically true. No dosing. The loop-not-running sweep engages with
  the posture. No new alarm policy: whatever the granted case does about a silent
  watch, this does (currently: no automatic silence alarm — the paused reminder was
  retired 2026-08-15 — the sweep, and the user's pill).

  EXITS — all inherited verbatim, nothing new:
  - Pill tap -> reclaimNow(): revoke + .reclaimPending + the reclaim ladder (pulse
    discriminator, 330 s liveness window; live branch resend +10 s / force +25 s;
    DEAD BRANCH FORCES NOW, the 2026-08-14 field ruling), the §5.3.3 schedule audit,
    gap booking with e44 store-identity dedup, the placeholder bolus + standing
    reminder ladder for unexplained delivery, R33 temp cancel on verified reclaim.
  - Watch revives -> recoveredDrain offer with the reunion token -> retro-ack (the
    .owner door, kept open by the flag-not-state choice) -> real records replace the
    gap fill by identity.
  - WC heals with the loan live -> that is row 6: the R40(f) wrist prompt resolves
    it; the phone keeps yielding meanwhile, pill unchanged.

  DECIDED ALONG THE WAY (2026-08-31): clean books never wait on WC — the recorder
  already answered, so shower/charger/walking-the-house gaps stay invisible; row 8
  (WC wedge, watch alive) is NOT a design driver (Jeremy: the wedge gets solved
  directly) — the posture covers it as a byproduct; the one-way-valve special state
  was REJECTED for consistency (yielding carries exactly the granted case's risk
  profile; any future suspend-authority-while-yielded lands on the granted case
  first, applied to both); manual phone bolus while yielding behaves exactly as
  during any loan; auto-takeover is barred by R40(a) — the phone takes the pod on
  explicit user command only, and auto-resume-after-quiet was dropped with the rest
  of the row-8 machinery.

  GHOST-REQUEST WEDGE + REFUSALS ANSWER (field 2026-08-31 21:16-21:26, fixed same
  night). Every seize BEGINS with a normal loan request, and with the phone dark that
  request rides the queued channel — a delayed detonator that delivers at reunion. The
  90 s request TTL (built for the 2026-08-30 power-on detonation) cannot cover a fast
  reunion: the tape's copy was ~67 s old, passed, and the phone GRANTED e276 against
  the live seized e277 — then parked on "Handing over…" forever, because the wedge had
  three silences stacked: the watch's wrong-phase grant refusal says nothing, its
  stale-revoke refusal says nothing (the phone's ladder read that as "no reply" and
  force-stole a dosing pod), and its #108 answer policy deliberately went quiet for a
  query OLDER than its loan. Meanwhile all three mirror detectors sat structurally
  blind — evidence recorded, engage gated to .owner.

  The rule that fixes the class: A REFUSAL NAMES WHAT IT REFUSED FOR. While holding a
  live loan, a stale grant, stale revoke, or stale status query is answered with the
  existing holdsPod status report (no new message kind); and the phone ACTS on that
  report outside .owner — at .grantOffered it abandons the ghost into the yield
  posture (T1 cancelled with the wait it timed; the burned epoch adopts forward via
  retro-ack exactly as tape proved), and at .reclaimPending it re-aims the ladder's
  remaining revoke at the epoch the watch says it holds. The pill-tap revoke aims at
  fresh foreign evidence from the start (supersededByLiveLoan-gated, so stale evidence
  cannot mis-aim), and the retro-ack door admits .reclaimPending — a reclaim is the
  phone ENDING a loan, not a state a duplicated credential could stomp — so the aimed
  drain lands without a force. The detonator itself is also defused at the source:
  the watch cancels still-queued request transfers at request-timeout and again at
  seize confirm (the #120 offer-superseder idiom, request-kind twin).
