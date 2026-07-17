# Loan Protocol v2 — Specification (M5)

_2026-07-17. Status: DRAFT for Jeremy's sign-off — no protocol code written yet._
_Companions: `DESIGN_FROM_STOCK_REBUILD.md` §2 (requirements traced to findings),
`DESIGN_M5_INPUTS.md` (layers ruling + prior art), `RULINGS.md` (authoritative register;
this spec cites rulings as R-numbers), `M4_NOTES.md` (the loop skeleton this integrates
with). Prior art commits referenced live on `g7-build-next` (LoopWorkspace-prediction)._

## 0. What changed since the design doc's §2 sketch

The §2 sketch predates the rulings register and five of today's M5 rulings. Deltas:

| Sketch said | This spec says | Why |
|---|---|---|
| Phone "completes or cancels any in-flight enact" then truncates its running temp at grant | Phone completes/cancels the in-flight *enact call*; the pod **keeps executing** the running temp; only the phone's **record** of it closes at the handover stamp | R2 (handoff keeps the running temp; C5 is record-truncation, not a pod command) |
| Phone watchdog on stalled record stream (row 7, T2) | **No heartbeat watchdog.** Phone alarms are exactly: start-confirmation (5 min), loan-duration reminder (6 h), paused-dosing-after-reclaim reminder (1 h) | R8 (healthy Sport Mode = phone away for hours; heartbeats train dismissal) |
| T1 ≈ 60 s grant timeout | T1 = **5 min** start-confirmation watchdog, cancelled by the watch's holdsPod push | R8 |
| Dose events opaque `{eventID, seq, payload}` | Events additionally carry a **provenance tag** (confirmed vs assumed) | R6 layer 2 |
| — | Suspend rides the protocol as a **bounded rate-0 temp** with duration; hand-back does NOT cancel it | R3/R4, `46f16d01` |
| — | StatusReport carries the **CGM-sovereignty flag and dosing mode** | Ruling #5/#7 (2026-07-17) |

## 1. Concepts

### 1.1 Loan epoch — "dead loans cannot speak"

A phone-minted, persisted, strictly-monotonic integer. Every message except
`LoanRequest` carries `{protocolVersion, epoch}`. A message whose epoch is older than
the phone's current epoch is **acked-as-stale** (so the sender stops retrying) and never
acted on. The epoch replaces v1's armedAt/lastRequestAt/lastRevokeAt anchor patchwork
and kills the stale-hand-back-during-new-loan critical (`WatchDataManager.swift:759`)
and the revoke/new-loan race (bench B4) by construction.

### 1.2 Per-event IDs and the cursor

Every journal-worthy event (bolus, temp start, suspend, resume, carb, plumbing-cancel,
truncation record) gets a UUID **minted at intent time** — before transmission to the
pod — plus a monotonic per-loan sequence number. Acks are cursor-style: "highest
contiguous committed seq". Retries reuse the same IDs; dedup is by ID, so redelivery,
journal growth between retries, and WC's survive-reinstall redelivery are all harmless.
This carries `af742c7a` (C7 incremental reconcile) to both sides.

### 1.3 Provenance tags (R6 layer 2 — wire-format change that forces v2)

```swift
enum EventProvenance: Codable {
    case confirmed                    // pod-acknowledged (response consumed) or
                                      // verdict-confirmed by layer-1 resolution
    case assumed(UncertainKind)       // max-exposure assumption, no pod verdict yet
    // UncertainKind: .bolusUncertain, .tempUncertain, .resumeUncertain,
    //                .skippedReduction (a real zero/low temp declined under max-exposure)
}
```

- Layer-1 (ported `d27a40c7` semantics): after any uncertain command the watch chases a
  status read (5 s/20 s/60 s quiet), consumes the pod's verdict
  (`lastProgrammingMessageSeqNum` match, delivered-only corroboration), and either
  **annuls** the assumed event (removed + tombstoned so the phone unwinds it too) or
  **upgrades it to `.confirmed`**. Any new programming command invalidates pending
  verdict evidence → the conservative record stands, stays `.assumed`.
- Only `.assumed` events are ever candidates for negative-remainder allocation (§5.3).
  A `.confirmed` event can never be reduced — a confirmed bolus's success response
  carries the incremented odometer, so it cannot be implicated in a negative remainder.

### 1.4 The odometer audit (R12)

The pod's cumulative-delivered counter is the **audit**, never the source: freshen with
a final status read before snapshot (OQ-5 retry: one retry on a 0.00 delta, log raw
values), compare against journal + expected schedule, one-way valve per R6: positive
remainder → IOB timed at hand-back (zero decay elapsed — conservative); negative
remainder → §5.3 layers, never blind subtraction.

## 2. Messages

All versioned Codable structs in `Common/Models/` compiled into both targets — one
source file, no hand-maintained mirror decoder (v1's mirror in `WatchDataManager` is a
review finding). Undecodable payload → `ProtocolNack{seenVersion}` + loud surfacing both
sides; **never ack-and-drop** (`:825`).

1. **`LoanRequest`** (watch→phone): watch build, supported protocol versions.
2. **`LoanGrant`** (phone→watch): `epoch`; `expiresAt` (a late grant self-rejects);
   pod identity/keys (LTK, controllerId, podId, address, message number — **complete or
   the grant is refused**, `PodLoanIdentity` deny-on-missing); **full stock `PodState`
   raw snapshot** (includes `unfinalizedDoses` and any `unacknowledgedCommand`, so the
   watch's `OmniPumpManager` resumes exactly where the phone's left off);
   **therapy-settings snapshot** (basal schedule, ISF, CR, targets, suspend threshold,
   maxBasal, maxBolus, insulin type — R1: these are the ONLY dosing limits; missing ⇒
   grant refused, never defaulted) + the snapshot's **timezone** (§8); 16 h dose
   history; **boundary record** per R2: the phone does NOT cancel its running temp —
   it closes its own record at the handover stamp and includes the truncated
   `DoseEntry` so both ledgers agree on the cut, while the pod keeps executing the
   temp until the watch's first command or natural expiry (the grant→first-enact gap
   is covered by the odometer audit).
   Before sending, the phone completes or abandons any in-flight enact call (critical
   `:684`) and pauses automatic dosing.
3. **`TakeoverComplete`** (watch→phone): epoch + first pod status. Only now does the
   phone commit `LOANED` (cancels the T1 alarm — this is the "holdsPod push" of R8).
   **`TakeoverFailed`** likewise; the watch tears down its `PodComms` completely on
   failure/timeout (zombie-bidder `:1009`).
4. **`DoseRecordBatch`** (watch→phone, during loan, best-effort `transferUserInfo`):
   events `{id, seq, provenance, payload}` streamed as they commit locally, plus
   **tombstones** for layer-1 annulments of already-streamed events. Addresses the trap
   cell: the phone accumulates the record even if the watch later dies. No delivery
   guarantee is assumed; the cursor makes redelivery/loss harmless.
5. **`HandbackOffer`** (watch→phone): epoch, `handedBackAt`, final pod status +
   freshened odometer pair, all not-yet-acked events (same IDs every retry).
6. **`HandbackAck`** (phone→watch): epoch + committed cursor. Sent **only after the
   phone's DoseStore write commits** (keeps `a897d22c`). Empty hand-back acks cursor 0
   (`:948`).
7. **`Revoke`** (phone→watch): epoch. Idempotent; parked-until-activation delivery kept
   from v1.
8. **`StatusQuery`/`StatusReport`** (phone↔watch): extends 3b-v2 polling with:
   dosing **mode** (`closedDirect` / `closedPhoneFed` / `cgmViewer` / `pausedStale` /
   `suspended`), **CGM-direct sovereignty** (age of last direct read — ruling #5),
   last committed event seq, and any **pod fault** (§6).
9. **`ProtocolNack`** (either): `{seenVersion, supportedVersions}` + loud alert both
   sides; phone-side dosing stays blocked if it fires during reconciliation.

## 3. State machines

### 3.1 Phone (persisted; `podLoanedToWatch` becomes derived state — fixes `:480`/`:697`)

```
OWNER ──grant sent──▶ GRANT_OFFERED ──TakeoverComplete──▶ LOANED
  ▲                        │ T1 = 5 min without TakeoverComplete, or TakeoverFailed
  │                        ▼
  │◀────────────── auto-reclaim + loud alert (query-before-reclaim: StatusQuery first;
  │                 a watch reporting ACTIVE at current epoch flips us to LOANED instead)
  │
  │◀── RECONCILING ◀── HandbackOffer / recovered journal / drained stream
  │        │ DoseStore write fails → stay, alarm, NO ack (row 11)
  │
  └── RECLAIM_PENDING (escape hatch: pod reclaimed, running LOOP temp canceled to
        schedule — a bounded rate-0 suspend temp is NOT canceled (46f16d01) — automatic
        dosing BLOCKED + persistent banner, R7) ──records drain──▶ RECONCILING
        └─ explicit user override = re-enabling Closed Loop in settings (R7) ──▶ OWNER
```

Automatic dosing is enabled **only** in `OWNER` with no unreconciled loan.

**Phone alarms — the complete list (R8, no additions without a new ruling):**
- **T1 start-confirmation** (5 min): armed at grant send, cancelled by
  `TakeoverComplete`.
- **Loan-duration reminder** (6 h): "the pod has been on loan for 6 hours."
- **Paused-dosing reminder** (1 h, repeating): armed whenever RECLAIM_PENDING /
  RECONCILING leaves automatic dosing blocked.
There is deliberately **no heartbeat monitor** on the record stream or StatusReports.

### 3.2 Watch

```
IDLE ──request──▶ REQUESTED ──grant──▶ TAKING_OVER ──pod session up──▶ ACTIVE
                     │ denied/timeout/expiry           │ fail: full PodComms teardown
                     ▼                                 ▼ + TakeoverFailed
                   IDLE                              IDLE
ACTIVE ──user hand-back──▶ HANDING_BACK:
    cancel leftover LOOP temp (DESIGN-5); preserve a running bounded suspend (46f16d01);
    freshen odometer (OQ-5 retry); send HandbackOffer; resend until Ack
  ──ack──▶ release pod (only after ack — kept from v1) ──▶ IDLE
ANY ──Revoke(epoch match)──▶ REVOKED: stop dosing, zero post-revoke pod commands
    (DESIGN-6), drain records via HandbackOffer(recovered) ──▶ IDLE
RELAUNCH with persisted state: never resurrect the pod session (data-first, kept);
    drain persisted pending events as recovered hand-back; "session ended" alert (P1#14).
```

**Watch-side timers:** grant-response timeout in REQUESTED; bounded takeover UX per the
2026-07-15 pod-side ruling (~30–45 s → one auto-retry → "Pod not responding — Keep
trying / Cancel", never an indefinite spinner); the layer-1 5 s/20 s/60 s status chase
after any uncertain command; the dead-man `UNUserNotification` re-armed each loop cycle
(fires only if the keepalive process is silently suspended — row 16).

## 4. Dosing semantics during a loan (rulings applied)

- **Limits: therapy settings only** (R1, confirmed for from-stock 2026-07-17). No
  watch-specific caps, no per-loan cumulative ceiling (for now). Missing settings deny.
- **Strategy: temp basals only.** The `automaticBolus` arm remains an explicit
  configuration denial (ruled 2026-07-17; `WatchLoopManager.swift:486` TODO resolves to
  the ruled behavior).
- **Max temp = therapy `maximumBasalRatePerHour`** through the stock DoseMath clamp +
  stock driver rounding + pod ceiling; no companion limit (ruled 2026-07-17; `:494`).
- **Suspend = bounded rate-0 temp** (R3), duration from stock's four options (R4);
  pod auto-resumes at expiry so a dead watch can never strand delivery off. Resume =
  cancel the temp — the pod's stored schedule is the truth; no fabricated schedules
  (R10). The suspend rides the protocol as a first-class event; hand-back and reclaim
  preserve it (§3); the phone's suspended-state note follows the command outcome (C4).
- **Glucose recency** (R9): stock 15-min gates on the auto-loop and the manual/meal
  recommendation; stale anchor stops NEW temps only (lenient — a running bounded temp
  finishes on the pod's clock). Manual-bolus recency denial shows the explicit
  "No recent glucose — no recommendation" notice; the dial and carb logging remain
  available (ruled 2026-07-17; `:534`).
- **Glucose sovereignty — chosen, never silent** (ruled 2026-07-17, completing
  `DESIGN_G7_FULL_LOOP.md` §6a): dosing consumes **only direct-G7 samples** by default.
  A stale direct stream pauses new dosing (haptic + notice). Phone-fed dosing exists
  only as the picker's explicitly chosen, labeled mode — offered only when the phone is
  actually reachable and pushing fresh readings. Mode changes are events in the record
  stream and surface in `StatusReport.mode`.
- **Degraded-mode picker** (ruled 2026-07-17): at activation — CGM-viewer (first-class;
  glucose display, loop open, pod stays with phone) / phone-fed (only-if-real) / abort.
  Mid-session CGM death — continue phone-fed (if real) / stay paused / hand back.
- **Ring** (ruled 2026-07-17): during a loan the ring shows stock freshness of the
  **watch's own loop**; saddle-brown becomes the Sport-Mode accent, not a frozen ring.

## 5. Hand-back and reconciliation

### 5.1 Ordering invariants (kept verbatim from v1)

Write-doses-first; ack-only-after-commit (`a897d22c`); release-pod-only-after-ack;
deterministic per-event syncIdentifiers on the phone write (per-event UUIDs supersede
the `watchloan-<hash8>-<seq>` scheme); carb reconciliation is merge-not-replace
(`setSyncCarbObjects` replace-all finding).

### 5.2 Positive remainder (unchanged, R6 valve)

Enter IOB as a hand-back-timestamped dose (zero decay elapsed — deliberately
conservative), bounded logging of raw odometer values.

### 5.3 Negative remainder — layers 2 and 3 (RULED, Jeremy 2026-07-17: fingerprints
only — no arithmetic guessing, ever)

Layer 1 has usually already resolved uncertainty in-loan. If a negative remainder
survives to hand-back (the dead-watch case — no post-uncertainty pod contact):

1. **Allocation (layer 2) — act only on fingerprint matches:**
   - **Exact-size annulment**: the remainder equals one `.assumed` event's units
     within one pod pulse (0.05 U) → annul that event (the designed
     single-false-assumption case). If two `.assumed` events tie at that size,
     annul the one closest to the failure (identical arithmetic; only decay timing
     differs slightly).
   - **Skipped-reduction window**: the records carry an `.assumed(.skippedReduction)`
     marker (the watch flagged "I commanded a reduction I did not record" under
     max-exposure) and the remainder fits within that window's scheduled insulin
     (within one pulse) → record the reduction retroactively (the C′ case).
   - Reductions touch **only `.assumed` events**, never `.confirmed`, never below
     zero (R6).
   - **Everything else — any ambiguity, multiple candidates, inexact arithmetic —
     touches NO record.** The full remainder goes to layer 3. IOB stays overstated
     (Loop under-doses for a few hours — the safe direction). The draft's
     newest-first partial reduction is rejected: a wrong reduction understates IOB
     (the dangerous direction) precisely in the least-understood scenarios.
2. **Residual (layer 3):** any remainder layer 2 cannot fingerprint is **surfaced,
   never subtracted**. Ruled wording (verbatim): "The pod delivered X.XX U less than
   the watch session recorded. Records were not changed. Possible causes: pod fault,
   occlusion, or an interrupted command. Check the pod and review the session in
   Event History." Delivery: phone-side at reconciliation — persistent notification +
   banner until acknowledged, plus an Event History line.
3. **Phone post-reclaim pod re-audit (layer 3 companion):** on every reclaim/hand-back
   the phone runs its own forensic read — status, odometer, `lastProgrammingMessageSeqNum`
   vs. the journal tail — the same questions the watch's layer 1 asks, shrinking the
   dead-watch blind window. Discrepancies feed the same notice path; on the recovered-
   journal path the phone also ends any orphan running temp and records the truncation
   (C11, row 19).

## 6. Pod faults and alerts on the watch

Stock `PumpManagerAlert`s (fault, occlusion, expiry warnings) flow through the watch
host's `PumpManagerDelegate` → watch notification path (M4's log-only stubs become
real). A pod fault during a loan additionally: stops the loop (stock behavior), rides
`StatusReport.podFault` so the phone tile shows it, and is journaled as an event so
reconciliation knows delivery stopped (feeding §5.3's residual explanation). The
keepalive dead-man notification (row 16) and the "session ended" relaunch alert (P1#14)
carry over unchanged.

## 7. Version negotiation and the v1→v2 transition

`LoanRequest` advertises supported versions; the grant pins the session's version.
Any undecodable or version-mismatched payload → `ProtocolNack` + loud alert both sides;
nothing silently discarded (`:825`). During the transition window the phone build
supports v1+v2 side-by-side; the watch speaks only v2. v1 paths retire once the from-
stock watch is the wrist build (M5 exit).

## 8. Time, DST, and the frozen schedule

Therapy settings are snapshotted at grant **with their timezone**. During the loan the
watch does not accept settings pushes into the dosing path (a mid-loan settings change
on the phone takes effect at the next grant; the phone UI notes this during an active
loan). Temps and suspends are duration-based — immune to wall-clock jumps. Any basal-
schedule assertion (R10 resume, reclaim schedule-assert) uses the grant-captured
timezone. A DST transition mid-loan therefore shifts only the *schedule lookup*, which
follows the grant timezone deterministically; drill D18 exercises spring-forward and
fall-back mid-loan.

## 9. Failure matrix → bench drills (Part E)

Every row is a scripted bench drill (D1–D19) against the real bench pod; emulator runs
count for nothing (M-rule). Changes from the design-doc sketch are **bold**.

| D# | Interruption | Detection | Recovery | Invariant held |
|---|---|---|---|---|
| 1 | LoanRequest lost | watch request timeout | watch → IDLE, user retries | no side effects yet |
| 2 | LoanGrant lost | **phone T1 (5 min)** without TakeoverComplete | auto-reclaim + alert; late grant self-rejects on embedded expiry | at least one controller |
| 3 | Takeover fails (pod unreachable) | TakeoverFailed or T1 | watch full PodComms teardown; phone reclaims | no zombie bidder |
| 4 | TakeoverComplete lost | phone T1; watch ACTIVE | **query-before-reclaim**: StatusQuery; watch ACTIVE at current epoch ⇒ LOANED | exactly one controller |
| 5 | Watch app killed mid-loan | relaunch, persisted state | per-session policy: loop reopens; records drain as recovered hand-back; "session ended" alert | journal-loss-proof |
| 6 | Watch killed mid-pod-command | stock `PodState.unacknowledgedCommand` persisted pre-flight | stock recovery + **layer-1 verdict consumption** classifies; dose lands in DoseStore → drains **with provenance** | no vanished dose |
| 7 | Watch battery death | **no heartbeat (R8)**: 6 h loan reminder + user observation | pod safe (bounded temps; suspend auto-resumes per R3); escape hatch → RECLAIM_PENDING (dosing blocked) | blind-IOB dosing impossible |
| 8 | Phone off during loan | n/a — the product premise | records queue over transferUserInfo; reconcile on return | phone-free dosing |
| 9 | HandbackOffer lost | watch resend loop | same IDs each retry; watch keeps pod until ack | no orphaned pod, no dup |
| 10 | HandbackAck lost | watch resends offer | events already committed → same-cursor ack; ID-dedup absorbs growth | exactly-once accounting |
| 11 | Phone DoseStore write fails | reconcile error | no ack; dosing stays blocked; **1 h paused-dosing reminder** repeats | never dose on incomplete records |
| 12 | Escape-hatch reclaim, watch alive | watch gets Revoke | REVOKED + drain; phone blocked until reconcile or explicit override; **loop temp canceled, bounded suspend preserved** | single writer, no blind IOB |
| 13 | Revoke lost / watch unreachable | phone stays RECLAIM_PENDING | parked revoke; stale-epoch contact gets stale-ack → drains | dead loans cannot speak |
| 14 | Stale hand-back after new loan | epoch mismatch | ack-as-stale, ignore | epoch invariant |
| 15 | Version skew | decode failure | ProtocolNack + loud alert; phone dosing stays blocked; nothing discarded | no silent data loss |
| 16 | WorkoutKeepalive dies mid-session | dead-man notification armed per cycle | user alerted; pod safe; loop resumes on relaunch | no silent loop suspension |
| 17 | WC redelivery after reinstall | stale epoch / known IDs | idempotent ignore; no assertions on unknown payloads | idempotency |
| 18 | **DST transition mid-loan** | n/a (scheduled drill) | duration-based commands unaffected; schedule ops use grant timezone | deterministic schedule |
| 19 | Recovered journal shows uncanceled temp / suspend | phone inspects last event | phone ends orphan **loop** temp + records truncation (C11); **suspend surfaced as suspended-until, not canceled**; never "back on schedule" | truthful transfer |

Plus (not interruptions, still Part E): **D20** negative-remainder allocation — dead-
watch with one unresolved `.assumed` bolus, verify exact-match annulment + user notice;
**D21** layer-3 residual — fault-injected odometer shortfall with no `.assumed`
candidates, verify notice-not-subtraction; **D22** epoch race (bench B4) — also unit
tests; **D23** phone-fed picker — kill the G7 transport mid-loan with phone present,
verify pause → explicit choice → labeled mode in StatusReport.

## 10. Implementation map

**New (the one novel module):**
- `Common/Models/LoanProtocolV2.swift` — every message struct + versioning (one file,
  both targets).
- `Loop/Managers/PodLoanPhoneController.swift` — phone state machine §3.1 (replaces the
  loan parts of `WatchDataManager`; v1 paths quarantined until retirement).
- `WatchApp Extension/StockLoop/PodLoanWatchController.swift` — watch state machine
  §3.2, owns grant intake → `OmniPumpManager` construction from the PodState snapshot,
  hand-back, layer-1 chase (port of `d27a40c7` semantics against stock
  `recoverUnacknowledgedCommand`).
- `WatchApp Extension/StockLoop/LoanEventJournal.swift` — the per-event record +
  provenance store feeding `DoseRecordBatch`/`HandbackOffer` (thin layer over the watch
  DoseStore; events reference DoseStore entries, not a parallel dose world).
- Reconciliation: `Loop/Managers/LoanReconciler.swift` — cursor commit, §5 layers,
  post-reclaim re-audit, residual notices.

**Touched (ringfenced per R11 where hardware modules):**
- OmnipodKit: `releaseConnection`/`rearmConnection` seam port from the OmniBLE fork's
  pod-loan branch (`eb8f6c3` C5 semantics) into a `+PodLoan` extension file; any
  out-of-file line carries `// PODLOAN`.
- LoopKit: none expected (PumpConnectionLendable already hosted in `PumpManager.swift`).
- `WatchLoopManager.swift`: resolve the three ruled TODOs; wire `pumpManager` via the
  loan controller (the `:89` seam); picker/mode plumbing.

**Retires:** v1 grant/hand-back handling in `WatchDataManager`, whole-journal-hash
dedup, the mirror decoder, `podLoanedToWatch` as a volatile flag.

**Tests:** message round-trip + version-skew suite; epoch race unit tests (D22); state-
machine transition tables both sides; provenance allocation property tests (never
reduce confirmed, never below zero, exact-match preference); cursor idempotency under
redelivery/growth.

## 11. Acceptance

`RELEASE_TEST_SCRIPT.md` Parts A–C, plus Part E = D1–D23 on the bench pod. On-body only
after the full bench pass and Jeremy's explicit per-build authorization (risk-register
ruling #8 — reserved). Crude build (`g7-build-next`, watch build 73) remains the
installable fallback throughout.

## 12. Open items riding this sign-off

1. §5.3 allocation order — RULED (Jeremy, 2026-07-17): fingerprints only (exact-size
   annulment + skipped-reduction window); ambiguous remainders go whole to layer 3,
   records untouched. Newest-first fallback rejected.
2. §5.3 residual notice wording — RULED (Jeremy, 2026-07-17): the shorter wording,
   verbatim in §5.3, as persistent phone notification + banner + Event History line.
3. §8 mid-loan settings-push freeze — APPROVED (Jeremy, 2026-07-17).
4. ~~HealthKit-off (R19) provisional~~ — RESOLVED 2026-07-17: the challenge review
   upheld HK-off (see R19 for the mechanism, flip condition, and bench script). The
   spec's assumption stands: no watch HK writes anywhere above.

One implementation note from the challenge review that touches §4's phone-fed mode:
LoopKit's momentum math requires single-provenance glucose in its window
(`GlucoseMath.swift:92-100`), so when the picker switches the watch to phone-fed
samples, momentum will silently return empty until the window is single-source again.
That is stock behavior and conservative (no momentum ≠ wrong momentum), but the mode
transition should log it and the bench drill D23 should observe it — it is expected,
not a bug.
