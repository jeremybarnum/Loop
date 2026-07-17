# M5 inputs — decisions and designs carried in from the safety chat (2026-07-17)

This file freezes the context the M5 design session needs from the g7-build-next
safety work, so the session can run without that chat's history. Companions:
`DESIGN_FROM_STOCK_REBUILD.md` (charter, milestone plan, the eight owner-reserved
rulings in its risk register), `M1_NOTES.md`–`M4_NOTES.md`, and the adversarial
review report (artifact link in the owner's memory; 70 verified findings).

## 1. The negative-remainder three-layer policy (RULED)

Jeremy's ruling: **layer 1 on g7-build-next now (done — see §2); layers 2–3 in
protocol v2 (M5).**

Background: at hand-back the pod's delivered-odometer is compared against the
journal + schedule. A NEGATIVE remainder (records claim more than the pod
delivered) has four causes: a max-exposure assumption that turned out false
(the designed main source), an interrupted bolus recorded at commanded size,
a pod fault/occlusion, or a stale-odometer artifact on the crashed-watch path.
Policy is a one-way valve: positive remainders enter IOB (timed at hand-back,
zero decay — deliberately conservative); negative remainders are never
auto-subtracted from arbitrary records.

- **Layer 1 — resolve in-loan (ask the pod)**: after any uncertain command,
  chase the next status read and consume the pod's own verdict
  (`lastProgrammingMessageSeqNum` equality with the lost command's
  messageNumber — the session's `recoverUnacknowledgedCommand` logic — plus
  delivery-status flags corroborating DELIVERED only). Refuted assumptions are
  annulled within minutes; confirmed skipped-reductions (a real zero-temp the
  max-exposure rule declined to record) are recorded retroactively. Key facts:
  the pod is pull-only; the odometer is ONE cumulative number, no timestamps,
  no event log; a confirmed bolus cannot produce a negative remainder (its
  success response carries the incremented odometer), so only assumption-tagged
  entries can ever be implicated.
- **Layer 2 — allocate at hand-back (provenance) — M5 SCOPE**: journal entries
  carry a confirmed-vs-assumed provenance tag (wire-format change → v2). A
  negative remainder may reduce ONLY assumption-tagged entries, exact-size
  match preferred, never a confirmed entry, never below zero. This covers the
  one case layer 1 cannot: the watch died before any post-uncertainty contact.
- **Layer 3 — surface the residual — M5 SCOPE**: any negative remainder beyond
  what assumptions can absorb points at pod fault / occlusion / artifact → user
  notice, never subtraction. v2 also adds a phone-side post-reclaim pod read
  (the phone asks the pod the same forensic questions), shrinking the
  dead-watch blind window.

Worked examples that drove the ruling (2 h loan, 1.0 U/hr schedule): phantom
1 U bolus (early: layer 1 kills it at the next 5-min contact + tells the user
to re-bolus; late: the hand-back's own fresh read resolves it); phantom high
temp (same); C′ — a REAL zero-temp the conservative rule refused to record
produces a negative remainder with no phantom entry anywhere, which is why
arithmetic-only allocation is unsafe and pod-first resolution is layered above
provenance allocation.

## 2. Layer-1 prior art to port (g7-build-next commits)

Port these semantics into the v2 protocol rather than reinventing:
- `d27a40c7` layer 1: UncertainCommandRecord (kind, date, seq, removable event
  IDs, skipped kind), coordinator-driven 5s/20s/60s quiet status chase,
  invalidation on any new programming command (seq evidence destroyed →
  conservative records stand), verdict = seq match OR delivered-only
  corroboration (a rate-0 temp IS a running temp), annulment via
  `PodLoanJournal.removeEvents(withIDs:)`, refuted-bolus loud alert,
  refuted-resume restores Suspended-until truth.
- `ad280327` C1/C2/C10: intent-before-transmission pending slot
  (fold-at-recovery under max-exposure), direction-aware uncertain journaling
  (record as applied ONLY when "applied" models MORE insulin), plumbing-cancel
  recording when a temp change dies after its committed safe-cancel.
- `af742c7a` C7: per-event UUIDs + cursor-style incremental reconcile
  (phone half of the v2 cursor design; grown-resend enters only new content).
- `1e6cbf9d` C8 watchdogs, `17172fa7` C6 reclaim-keeps-dosing-paused,
  `ffcebb77` C11 orphan-temp accounting + phone schedule-assert at reclaim,
  `4f92bed3` C9 no-fabricated-schedule resume, `1b7278a5` stock-parity
  duration UI, `eb8f6c3` (OmniBLE fork, pod-loan branch) C5 handover
  truncation + PODLOAN ringfence.

## 3. Standing principles binding M5

- **PODLOAN ringfence** (Jeremy, adopted): hardware-module deviations live in
  ONE `+Feature` extension file per module; unavoidable out-of-file touches get
  a `// PODLOAN` marker; audit = read one file + run one grep.
- **Max-exposure direction rule**: whenever delivery state is ambiguous, the
  records must model the MORE-insulin interpretation (IOB never understated).
- **The pod is the source of truth for delivery**; the odometer audit is the
  backstop, journals are the primary record, assumptions are always tagged and
  eventually reconciled against pod evidence.
- Explain-first protocol: every design decision that touches dosing semantics
  is presented to Jeremy in non-technical terms and ruled on before code.

## 4. The M5 agenda

1. Walk the eight owner-reserved rulings (design doc risk register) one at a
   time, plus M4's four `TODO(M5-ruling)` sites in
   `WatchApp Extension/StockLoop/WatchLoopManager.swift` (:89 pump connection,
   :486 automaticBolus strategy, :494 max-temp derivation, :534 manual-bolus
   recency-denial UX).
2. Specify loan protocol v2: loan epochs ("dead loans cannot speak"),
   per-event IDs + cursor acks end-to-end, two-phase grant with watchdogs both
   sides, reclaim-blocks-dosing, provenance tags (layer 2), residual surfacing
   (layer 3), phone-side post-reclaim pod re-audit, pod fault/occlusion alert
   surfacing on the watch (review critic gap), version-negotiated messages,
   grant-boundary temp truncation (C5 semantics), DST/timezone handling
   (schedule frozen at grant — critic gap), the 19-row failure matrix with
   each row becoming a bench drill.
3. Implement against the M4 skeleton (`StockLoopStack`, the unconnected
   PumpManager seam), compile-gated, ringfenced, no device installs without
   Jeremy's explicit go-ahead.
