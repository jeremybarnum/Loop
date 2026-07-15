# Show-Mode Release Bench Test Script

**Build:** `show-mode @ e129d6cf` (formal handoff · DESIGN-5 · DESIGN-6 · §4c phase 1+2)
**Pod:** bench pod, water-filled, OFF body.
**Standing anti-measures (bench only):** TEMP-TEST-CAP = 3.0 U/hr, TEMP-TEST-BEEPS = on. These MUST be reverted (1.0 / false) and re-tested before anything goes on a person — see Part D.

## Architecture reminder (why the failure tools do what they do)
- During Show Mode the **watch drives the pod directly over BLE**; the phone *releases* its pod connection (`Pod connection released for loan (phone stops bidding)`) and reclaims it at hand-back.
- **Phone↔watch = WatchConnectivity** (rides BT + shared Wi-Fi; bootstrap needs BT). Grant, revoke, journal, hand-back all cross here.
- **Pod autonomy:** the pod keeps executing its last program with NO controller connected. That is the backstop every out-of-range/off test leans on.

So: **Faraday bag on pod** = drop the watch↔pod dosing link by range. **Watch BT off** = drop the same link by radio. **Watch off** = drop the link *and* kill the doser. **Phone off** = phone-free operation + deferred reconcile. **Wi-Fi off** = probe the WC channel.

## Instrumentation (set up once)
- Live log capture (idevicesyslog or Xcode). Useful greps: `Watch loan`, `Pod connection`, `Pod handed back`, `reclaim`, `0x31`.
- Watch three surfaces every step: (a) phone Loop UI — Active Insulin, Insulin Delivery chart, pod "Pump Manager Details"; (b) watch Show Mode screen; (c) pod beeps.
- Record scheduled basal rate; confirm closed loop ON; pod healthy, no active alerts.

---

## Part A — Normal modes (all must pass before Part B)

| # | Action | Expected (log / UI) | Pass? |
|---|---|---|---|
| A1 | Claim / takeover (one tap) | phone log `Pod connection released for loan (phone stops bidding)`; watch shows control; phone pod status = released | |
| A2 | Bolus from watch (e.g. 0.5 U) | pod delivers + confirmation beep; watch odometer advances | |
| A3 | Set temp basal from watch | pod accepts; watch shows temp running | |
| A4 | Change basal (temp to a different rate) | **cancel-first** then new temp (BUG-6 fix); no 0x31 | |
| A5 | Suspend from watch | pod suspends; watch shows suspended | |
| A6 | Resume from watch | resume **freshens status first**; delivery resumes; **watch for NO 0x31** | |
| A7 | **Normal hand-back** | DESIGN-5 cancels any leftover temp; phone log `Pod handed back from watch: <summary>` → `Pod connection reclaimed after hand-back`; then `Watch loan audit v2: … remainder=~0.00` + `Watch loan reconciled: N entr…`; **phone Active Insulin now includes the watch boluses; Insulin Delivery chart shows the watch temp segments**; pod back on schedule, no fault | |
| A8 | **Escape-hatch reclaim, watch LIVE** (DESIGN-6). Phone → pod → `Pod Is On Loan` alert → `Reclaim Pod` | phone log `Manual pod reclaim from watch (escape hatch)`; watch flips to **"Reclaimed by iPhone" / "Show Mode was ended from your iPhone. Insulin records were sent back."**; doses reconcile **exactly once** (if the watch retries you'll see `Duplicate pod hand-back … dose entry skipped`, never a second entry) | |

---

## Part B — Induced failure modes

Each ends with the **Part C end-state check**. Any `0x31` = STOP and investigate.

### B1 — Pod out of range mid-loan (Faraday bag) — *P2 pod autonomy*
1. Loan active on watch; deliver a bolus; set a temp.
2. Seal pod in Faraday bag → watch shows **signal loss**; pod keeps running its last program.
3. Remove bag → watch **reconnects, no fault**, delivery continued.
4. Hand back → reconcile correct.
**PASS:** signal loss is shown (not hidden), no phantom fault, post-reconnect status = scheduled/temp as left, reconcile clean. *(This is the walk incident's signal-loss, controlled.)*

### B2 — Watch app killed mid-loan (crash-recovery hand-back) — *§4c-3 journal persistence, P4*
1. Loan active; deliver a **0.5 U** bolus on the watch.
2. Force-quit the watch app (deterministic version of the watchOS kill that happened on the walk).
3. Reopen the watch app **with the phone reachable**.
**Expected:** recovery hand-back fires → phone log `Pod handed back from watch: <summary> ⚠️ Sent after Show Mode ended without a normal hand-back.`; the 0.5 U lands in phone IOB; `Watch loan audit v2 … remainder=~0.00`; pod reclaimed.
**PASS:** bolus reconciled **exactly once**, ⚠️ marker present, no double-count, pod clean.

### B3 — Watch powered OFF mid-loan → phone reclaim (dead-watch reclaim) — *DESIGN-6, P1 "exactly one controller"*
1. Loan active; deliver a bolus; **power the watch fully off**.
2. Phone → `Reclaim Pod`. Expect `Manual pod reclaim from watch (escape hatch) — journal not yet received`; the alert warns records are missing until the watch reconnects.
3. Power the watch back on.
**Expected:** watch must **not resurrect** the loan (revoke lands) → shows "Reclaimed by iPhone" → drains its persisted journal (recovered hand-back, ⚠️ marker) → the previously-missing doses reconcile.
**PASS:** no resurrection, journal reconciled **once**, no double-count.

### B4 — Revoke vs. new loan race (staleness) — *DESIGN-6 scenario 4; the loan-epoch's target class*
1. Reclaim the pod from the phone (normal or B3-style).
2. **Immediately** start a new loan on the watch.
**Expected:** the stale revoke from loan #1 must **not** kill loan #2.
**PASS:** new loan survives and is controllable. *(Record behavior now as the pre-epoch baseline; the loan-epoch is meant to make this race impossible by construction.)*

### B5 — Phone OFF during loan, then hand back — *phone-free premise + deferred reconcile, P4/P7*
1. Loan active on watch; **power the phone off** (watch keeps dosing — the whole point).
2. Deliver a bolus on the watch.
3. Normal hand-back **while phone is off** → watch can't reach phone; journal persists.
4. Power the phone on → WC re-establishes → queued/orphaned journal drains.
**PASS:** phone-free dosing worked; doses reconcile **exactly once** on return (⚠️ marker if via recovery); nothing lost.

### B6 — Wi-Fi / BT transport (characterization) — *P7 truthful transfer*
1. Loan active, phone present. Turn **Wi-Fi off on both** (BT on). Issue a watch command + a hand-back → expect WC to sustain over BT; hand-back completes.
2. Reset; now **BT off** (Wi-Fi on, same network). Issue a command + hand-back → transport model says WC bootstrap needs BT; **characterize** whether it re-establishes.
**Record expected vs. observed** — this leg is characterization, not strict pass/fail. (Note: with **watch** BT off you also lose the watch↔pod dosing link — that's B7, not this.)

### B7 — Watch BT off mid-loan (dosing-link loss) — *P2 autonomy + P5 no silent failure*
1. Loan active; turn **watch BT off** → watch loses the pod (BLE dosing link).
2. Watch must show a **loud disconnect/failure**, not silently look fine.
3. Watch BT on → reconnect, or hand back.
**PASS:** the loss is visible/loud, pod stays safe on its last program, recovery works.

---

## Part C — End-state invariant (check after EVERY scenario)
- Pod: **no 0x31**, intended suspend/resume state, no *unintended* dangling temp.
- Ownership: phone owns pod (`podConnectionReleased` false) unless a loan is intentionally active.
- Accounting: phone Active Insulin matches the actual dose ledger; audit remainder was ~0 on each reconcile.
- Closed loop resumes on the phone.
- **Any 0x31 fault = terminal; stop, capture logs, replace pod.**

## Not benchable with these tools (documented gaps)
- **Ack-before-write lost-dose window** — needs code fault-injection (make the phone's dose write fail after it acks). Can't be induced by power/radio.
- **Double-count on a residual phone temp** — needs a crash *during* a loan that was re-opened while a phone temp was still running; B4-style sequencing + watching the `Watch loan audit v2` remainder is the closest physical probe.

## Part D — Pre-person gate (separate from bench pass)
1. Revert TEMP-TEST-CAP → 1.0 U/hr and TEMP-TEST-BEEPS → false (both tags; grep to find).
2. Re-run **A2, A3, A7** to confirm the caps/beeps reverted cleanly (bolus + temp respect 1.0 cap; no test beeps).
3. Only then is the build person-eligible.
