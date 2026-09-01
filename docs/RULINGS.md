# Rulings register — SportMode-next-dev (the port line)

This line deliberately carried no docs until 2026-09-01: its algorithm and architecture
diverge from pure, so pure's register (Loop/docs/RULINGS.md on `SportMode`) stays the
home of R1–R39 and is NOT duplicated here. This file begins with R40 because the seize
family is the first feature whose rulings govern code CARRIED BY THIS LINE — the text
below is verbatim from her line's register (reclaim-lean-bench-pm), where the feature
was built and field-proven first (a ratified inversion of next-dev-leads). Line-local
references inside it (R22, WS1, #108, #120, e44, §5.3.3) resolve on that line.

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
