# Show-Mode Bench Test — Session Findings (2026-07-10 → 07-11)

**Build:** `show-mode @ e129d6cf` (formal handoff · DESIGN-5 · DESIGN-6 · §4c phase 1+2)
**Pod:** bench pod (water-filled, off body). Test caps still in place: `TEMP-TEST-CAP = 3.0 U/hr`, `TEMP-TEST-BEEPS = on`.
**Log capture:** `idevicesyslog -p Loop` → `scratchpad/showmode-test.log` (JB iPhone 17). Live on shared WiFi for most of the session; **not** on shared WiFi during the earliest A-tests (car).

This is the first on-device validation of §4c **phase 2** (atomic reconcile + audit v2) on a real pod.

---

## Scorecard

| # | Scenario | Result | Notes |
|---|---|---|---|
| A1–A7 | Normal modes | ✅ | Clean phase-2 reconcile (`audit v2 remainder ≈ 0`), atomic write, pod back on schedule, no fault. |
| B1 (walk) | Pod signal-loss mid-loan | ✅ | Validated by the walk-incident reconstruction (watchOS killed backgrounded app → recovery hand-back). |
| B2 | Watch app killed → crash-recovery hand-back | ✅ | `⚠️` marker present; 0.5 U reconciled **once**; odometer confirmed delivery. |
| B3 | Watch powered off → phone reclaim → no resurrection → recovery drain | ✅ | Fired **both** double-count guard layers (see below). |
| B4 | Revoke vs. new loan | ✅ (characterized) | Sequential in practice; WC serializes the revoke ahead of the new loan. Loan-epoch is the construction-level fix. |
| B7 | Watch BT off (no silent failure) | ✅ | Commands fail **loud** (visual solid; haptic works); passive idle display is a gap. |
| **B5** | **Phone off (phone-free premise)** | ⏸ **DEFERRED** | Couldn't get a **solid** loan to safely power the phone off — WC too flaky (see HIGH findings). Partial evidence from an earlier accidental 4.5 h phone/pod separation: pod ran autonomously, clean reconnect, no fault. |
| B6 | WiFi/BT transport | ◐ partial | Confirmed WC rides WiFi independent of BT (control returned after a watch-BT cycle via WiFi). |
| B1 (controlled) | Faraday bag | ⏳ pending | Needs the bag. |

### Double-count defense-in-depth — both layers proven live
- **Serial** duplicate hand-back → **journal-hash gate** catches it → logs `Duplicate pod hand-back … dose entry skipped` (seen in B4).
- **Concurrent** duplicate (both messages race the gate before the hash is written) → **deterministic syncIdentifier** (`watchloan-{hash8}-bolus-{seq}`) + `CachedInsulinDeliveryObject` **uniqueness constraint on `syncIdentifier`** collapses them to **one row** (seen in B3; confirmed on phone: one 0.5 U entry, not two).
- ⇒ Two `Watch loan reconciled: 1 entry` logs with **no** `skipped` line is the *concurrent* path — safe, not a double-count. (The recovery hand-back double-fires because the watch triggers it from both `applicationDidBecomeActive` **and** `sessionReachabilityDidChange` on wake.)

---

## Findings (ranked)

### HIGH — WatchConnectivity reachability / takeover reliability  *(headline; ring blocker)*
WC flapped `reachable: NO` repeatedly all session. Symptoms: slow/hanging "Show Mode connecting" spinners, **two limbo grants**, and **one real orphan** (below). A slow, retry-prone one-tap takeover is not ring-ready — Caitlin needs it fast and reliable in the moment. **This is the #1 thing to chase.** Root cause not yet isolated (candidate factors: app foreground state, BT/WiFi bootstrap timing, watch-app wake latency).

### HIGH — DESIGN-4 orphan reproduced live
Sequence: phone **released** the pod for the loan; the grant(s) landed while WC was `reachable: NO`, so the watch got the loan **state (baton)** but **not a working pod session (secrets)** — its bolus failed loudly (`pod not connected`). Result: pod running autonomously with **no active controller**, phone sitting paused, **and nothing auto-detected it** — caught only because we beep-checked before the phone-off step.
- **Re-grant idempotency did NOT rescue it** — it restored the loan *state*, but the broken thing (WC/secret handoff) is upstream of the state. So "re-grant recovers limbo" has a hard limit.
- Recovery required a **manual phone escape-hatch reclaim** (worked cleanly; empty journal → nothing phantom entered).
- **Fixes to consider:** (a) atomic takeover — phone stays owner until the watch **confirms working pod control** (e.g. a successful status/handshake), not just receipt of the baton; (b) auto-detect limbo (phone released + no watch confirmation within N s) → phone auto-reclaims; (c) surface the limbo state to the user instead of showing "Show Mode enabled."

### MEDIUM — Closed-loop enact races the loan release at grant
At the 00:20:11 grant, a loop cycle enacted concurrently with the release (`Enact temp basal 0.000 U/hr for 0s` — a no-op here, so benign). The loop should be **fully suppressed before** the pod is released, so a non-zero recommendation can't leave a **residual phone temp** on the pod as the watch takes over. Connects to the documented "double-count on residual phone temp" gap.

### MEDIUM — Observability: non-atomic duplicate-hash gate
The hash gate is check-then-write with the hash written only *after* the async reconcile completes, so **concurrent** duplicates both pass it → two `reconciled` logs, no `skipped`. Safe (syncID constraint backstops it) but **misleading in logs**. Fix: write the hash atomically, or log when the uniqueness constraint drops a duplicate.

### LOW-MEDIUM — BT-off startup hang with no indication  *(upgraded — hit during testing)*
Tapping Start Show Mode with the **watch's** BT off produces a silent spinner/hang, no explanation. A hang is worse than a loud failure — it doesn't say why. **Fix:** startup check → *"Bluetooth is off — turn it on to start Show Mode."* Detection already exists (`PodProofKit.centralManagerDidUpdateState` sees `poweredOff`); just wire it to the startup path.

### LOW — Passive stale display mid-loan
After a silent pod-link drop, the watch keeps showing a confident "basal running." Softened by pod autonomy (the pod *is* still running the last program) and by loud command failures (any action reveals the truth). A "signal lost — last known state, can't confirm the pod" banner would close it.

### LOW — Command-failure haptic reliability
The loud-fail path (`WKInterfaceDevice.play(.failure)` + visual alert) fired **with haptic** on the limbo bolus, so it works. It was inconsistent earlier (likely context/settings). Value is mainly for **late** failures (screen already dismissed, user glanced away) — ensure that buzz is reliable. Visual alert is primary and solid.

### LOW — Display-refresh lag on reclaim
After the phone reclaims, the watch keeps showing Show Mode active until the user interacts, then flips to "Reclaimed by iPhone." Should update proactively.

### BENIGN (documented) — OQ-5 stale bolus-ack odometer
Reproduced repeatedly: `podDelta` often `0.00` at hand-back even with a real bolus, giving a large **negative** audit remainder. Harmless by design — the bolus is entered from the journal **event** (authoritative), and negative remainders are **never** entered. The odometer cross-check simply can't verify a bolus still completing at hand-back. Pod odometer confirmed actual delivery each time (e.g. B2: 57.90 → 58.45).

---

## Still pending

- **Loan-epoch** — *designed, not implemented.* Construction-level fix for the B4 revoke/new-loan race (revoke names epoch N; a new loan is N+1 → dead on arrival). Plan: branch `loan-epoch` off `show-mode`, implement, test.
- **B5 (phone off)** and **B1 controlled (Faraday bag)** — re-run once WC is reliable / bag on hand.
- **Part D — pre-person gate (MUST do before anything goes on Caitlin):** revert `TEMP-TEST-CAP` 3.0 → 1.0 and `TEMP-TEST-BEEPS` on → off, then re-run A2/A3/A7 to confirm caps/beeps reverted cleanly.
- **Safety-paradigm ratification** (`SAFETY_PARADIGM.md`).

## Bottom line
Phase-2 reconcile and the crash/reclaim/revoke recovery paths are **validated on device** and the anti-double-count design held up under a real concurrent race. The gating issue for a ring-ready product is **not** dose accounting — it's **takeover reliability** (WC reachability) and the **orphan detection/recovery** it exposed.
