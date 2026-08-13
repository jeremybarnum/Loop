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
  the phone was on closed loop, I want to loop closed… for Caitlin's purposes,
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
  settings) MUST be validated by SIMULATION with a Caitlin-like glucose
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
