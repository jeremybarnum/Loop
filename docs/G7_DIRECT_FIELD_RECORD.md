# G7 direct-to-watch — consolidated field record

**Purpose:** one place for everything we know about direct G7 reading on the watch, so we
stop re-deriving settled questions. Started 2026-08-04 after a bad run re-opened ground we
had already covered twice.

**Read these first, they are not superseded:**
- `E4_TIME_SEPARATION.md` — the 2026-07-21 pod/G7 radio contention breakthrough and its
  catch-rate table. Still the best mechanistic account we have.
- `G7_FIRST_PRINCIPLES_REVIEW.md` — the protocol/stack review.
- `RADIO_STACK_AUDIT.md` — findings, many still unapplied (task #28).

---

## 1. How the scheduler actually works (verified in code 2026-08-04)

`G7Client.swift` runs a **phase-locked loop on the sensor's own 5-minute EGV grid**:

```swift
let next = success ? max(retryInterval, autoRepeatInterval - scanLeadTime)  // 300 − 45 = 255s
                   : (useReconnect ? 3.0 : retryInterval)                    // hunt fast
```

- A **successful read gives phase lock.** It then sleeps 255s and arms a connect ~45s before
  the *predicted* next window. This is deliberately a LATE arm — an arm sitting ~295s gets
  decayed by the watchOS BLE duty-cycler and sleeps through the burst (build 124 measured
  3s-arms missing ~half their windows). The 300−45 geometry is inherited from the crude
  branch's proven scan scheduler.
- A **failure means the phase is unknown**, so it re-arms in 3s and hunts, backed by a 400s
  watchdog spanning two window chances.
- **The G7 client has NO knowledge of the phone.** Zero references to phone glucose, glucose
  age, or relay state. It does not stand down because the loop is being fed from elsewhere.
  Verified by grep, 2026-08-04.

**Consequence for the "phone leaves range" question (Jeremy, 2026-08-04):** nothing in the
scheduler changes when the phone goes away. If direct-G7 was reading successfully, it keeps
going seamlessly. If it was *failing* while the relay quietly covered, the failure was
already there — the phone was masking it, not causing it. There is no warm-up state to
trigger and no reason to tell a user to toggle Bluetooth.

**Disconnect-after-read is BY DESIGN.** The G7 is connect-per-reading: it drops the link
after delivering, and `!! disconnected (CBErrorDomain#7)` following `round0 putk=true` is the
*normal* end of a good exchange. A successful read and a failed one look identical up to that
point. Do not diagnose from the disconnect (I did, twice — 2026-08-03 and again 2026-08-04).

---

## 2. THE METRIC — and a correction that invalidates older numbers

**Count `[glucose] INGEST src=…` lines. Do NOT count `*** VALUE`.**

`*** VALUE` is emitted by the BLE layer only for **live notification** values. The G7 also
delivers history through its backfill characteristic (`F8083536-…`), and
`G7CGMManager.sensor(_:didReadBackfill:)` converts a whole batch into one `.newData([...])`
array. Those readings enter the store **silently**.

Build 211 added source-tagged ingestion at every route into the store:

```
[glucose] INGEST src=direct-G7   stored=1/4 · latest 107 mg/dL age 12s BATCH(backfill+live)
[glucose] INGEST src=phone-relay stored=1/1 · latest 121 mg/dL age 8s (direct-G7 gap)
[glucose] INGEST src=grant-seed  stored=6/6 · loan takeover warm-up
```

`stored=n/m` separates genuinely new readings from batch redelivery.

**Numbers quoted before build 211 measured live-read coverage, not glucose coverage.** The
"97%" (Aug 1 overnight) and "35%" (travel night) figures were `*** VALUE` greps. They are
comparable to each other but are NOT catch rates. The 2026-08-03 D2W window was read as
"0 reads in 2.8h / contention confirmed" on that basis and that conclusion was **wrong** —
the store was filling normally from backfill the whole time.

**Also: `INGEST src=phone-relay` appearing at all proves phone Bluetooth was ON.** It is the
cheapest possible check that a "BT-off" run really was one.

---

## 3. Field record — BT-OFF runs only

Only phone-BT-off runs isolate direct-G7. Phone-present runs cannot: the relay usually wins
the race and masks direct reads as `stored=0/N` duplicates.

| Date | Build | Duration | direct-G7 /hr | Catch | Notes |
|---|---|---|---|---|---|
| 2026-07-21 | 140 | — | — | **100%** (8/8) | E4 v2, open loop. See E4 doc. |
| 2026-07-21 | E1 | — | — | **94%** | No pod at all (standalone diagnostic) |
| 2026-08-03 | ~216 | 2.8h | — | see §5 | D2W on, phone BT+WiFi off. Loop stayed fed; direct-G7 rate not computed with the correct metric. |
| **2026-08-04** | **218** | **3.5h** | **3.1** | **26%** | **epoch 168 — bad. Detail below.** |
| **2026-08-04 pm** | **220** | **1.8h** | **12.5** | **100%** | **23/23, pod ON LOAN and dosing. Detail in §3b.** |

### Epoch 168 (2026-08-04 08:45→12:16, build 218) — the bad run

```
attempts started        50
pending connect FIRED   26
reached CONNECTED       26   (52% of attempts)
reached subscribed      25
reached auth round0     25
*** VALUE (live read)    0   ← not one live reading in 3.5 hours
INGEST direct-G7        11   (42% of connects; ALL from backfill)
cold reacquire path     84   ← the warm-bond branch never engaged
post-connect drops      33
central RECREATES       10
loop cycles OK           9   (2.6/hr — cycles track readings, not the reverse)

reads at 08:50 09:12 09:15 09:25 09:45 10:08 10:23 10:40 10:57 11:19 12:15
gaps    22, 3, 10, 20, 23, 15, 17, 17, 22, 56 min
```

**What was RULED OUT for this run:**
- *Pod holding a BLE slot.* E4 behaved correctly: `release DEFERRED +90s`, then
  `post-release pod state disconnected`, and each post-dose re-release logged
  `state connected -> disconnected (+3s)`. Clean teardown every time — **not** the E4-v1
  stuck-`.disconnecting` pathology.
- *The disconnects themselves.* Identical sequence on reads that succeeded (see §1).
- *Phone contention.* Phone BT was off until 12:10 (first `phone-relay` ingest).

**What stands out and is NOT yet explained:**
1. **Zero live reads.** Every ingest was backfill. The live notification path produced
   nothing for 3.5 hours.
2. **84 cold reacquires, zero warm.** `G7Client` has a WARM branch
   (`reconnectMode, let saved = savedPeripheral` → targeted pending connect, described in
   code as "the proven 15/15 path"). It was never taken. Every attempt ran
   `cold reacquire: targeted connect → … (scan fallback after 330s)`.
3. Only 52% of attempts even reached CONNECTED.

**Leading hypothesis (UNVERIFIED):** the warm bonded handle is not persisting, so every
window is fought from cold, and cold acquisition is too slow to land inside the sensor's
short advertisement burst. Whether the handle is being cleared, never set, or invalidated is
the open question. `savedPeripheral = nil` at `G7Client.swift:1243` (the stale-handle
fallback) is the first place to look.

---

### 2026-08-04 15:36-17:26 (build 220) — 100%, and it refutes §7's leading hypothesis

23 readings across 23 five-minute windows. Gaps 4.7-5.3 min, none over 6. Phone BT off
(last `phone-relay` ingest 14:20:52). A pod was ON LOAN and dosing throughout — 105 `E4:`
lines, 4 doses enacted and accepted — so this is NOT the E1 no-pod condition.

The 65-min hole before it (14:31→15:36) was **app suspension, not a G7 failure**:
`BACKGROUND (another app / screen off)` at 14:41:38, `WILL FOREGROUND` at 15:31:51.

**Same-day, same-log comparison against epoch 168:**

| | epoch 168 (24%) | afternoon (100%) |
|---|---|---|
| live `*** VALUE` | 0 | 0 |
| cold reacquires | 84 | 36 |
| warm reacquires | 0 | 0 |
| cold per attempt | 1.68 | 1.71 |
| central RECREATE/hr | 2.8 | 2.1 |
| attempts/hr | 14.2 | 11.3 |

**TWO OPEN QUESTIONS FROM §7 ARE NOW CLOSED — both were dead ends:**

1. **"Zero live reads" is NOT a failure signature.** The 100% run also had zero. Every
   reading in a PERFECT run arrived by backfill. Backfill-only is simply how this stack
   delivers; stop treating it as a symptom. (§7 question 2 — closed.)

2. **"The warm bonded handle isn't persisting, and cold acquisition is too slow" is
   REFUTED.** The 100% run was also 100% cold, at the same cold-per-attempt ratio (1.71 vs
   1.68). Cold acquisition every window is demonstrably fast enough for a perfect catch
   rate. Do not spend more time on `savedPeripheral` / the warm branch on these grounds.
   (§7 question 1 — closed.)

**What remains.** The stack's mechanics were essentially IDENTICAL in a 24% run and a 100%
run on the same device, same day, same build family. Only the yield differed. The higher
attempt rate in the bad run is a SYMPTOM (a failure re-arms in 3s and hunts), not a cause.
That points outside our code — RF environment, sensor session, body position — which is
consistent with Jeremy's standing prior and with §5's observation that the Dexcom app was
failing at the same time on the bad morning. The highest-value experiment is still §5:
paired direct-G7 vs D2W observation at the same timestamps.

---

## 4. Historical catch-rate table (from E4_TIME_SEPARATION.md — do not re-derive)

| Condition | On-time | Notes |
|---|---|---|
| No pod at all (E1) | **94%** | pod connection absent entirely |
| Pod orphaned, deferred release (E4 v2) | **100%** (8/8) | the fix, open loop |
| Pod held, closed loop | 77% | commands keep the connection warm |
| Pod held, open loop | ~20% | idle-drop reconnect churn is worst |

Ranking: **cleanly-gone (94–100%) > warm-held (77%) > idle-churning (20%)**.

Mechanism: watchOS caps BLE at ~2 connections per app. A peripheral stuck `.disconnecting`
still consumes a slot and poisons the shared budget. `cancelPeripheralConnection` is
non-blocking and does not guarantee teardown — hence the +90s deferred release, which
cancels a *settled* connection.

**Note epoch 168's 26% sits in the "idle-churning" band despite E4 working correctly.** That
is the anomaly worth explaining.

---

## 5. D2W (Dexcom direct-to-watch) — status: OPEN, previously mis-closed

Task #32 was closed 2026-08-04 on the basis that D2W caused no harm. That conclusion rested
on the discredited `*** VALUE` metric and should be treated as **unproven, not established**.

What is actually known:
- 2026-08-03 overnight with D2W on and phone BT+WiFi off: the loop stayed fed (14 cycles,
  10 doses, every cycle on glucose <5 min old across 2.8h). Direct-G7 rate was never computed
  with the correct instrument.
- On the morning of 2026-08-03, when our direct-G7 was failing, **the Dexcom watch app was
  also failing** (Jeremy, observed). Same again on 2026-08-04 during epoch 168.
- Jeremy's prior, which the evidence supports: the G7 is designed for multiple simultaneous
  connections (phone + watch + receiver). Simple connection-count contention should not
  degrade it, and no evidence has ever supported that theory. **It was asserted twice by
  Claude without evidence and should not be revived without data.**

**The open question, stated properly:** when direct-G7 fails, does D2W fail at the same time?
If yes, the cause is the sensor or the RF environment and our stack is a bystander. If no,
the cause is ours. This is the single highest-value experiment remaining, and it needs both
observations recorded at the same timestamps.

---

## 6. Radio priority framework (Jeremy's ruling, 2026-08-04)

- **Takeover → pod is priority.** (R26: G7 stands down during the takeover ladder.)
- **Looping → G7 is priority.** The 5-minute grid window must be highly protected; pod
  commands defer around it (#31, and the `isRadioBusy` arbiter in `StockLoopSession.swift:81-86`,
  which is `isAttemptActive || isHandshakeActive` — the sensor is busy for its whole attempt,
  not just the handshake).
- **Hand-back → pod is priority.**

BG outranks takeover snappiness. Any future takeover optimisation must not erode the
protected G7 window.

---

## 7. Open questions, ordered

1. **Warm-bond persistence.** Why did epoch 168 run 84 cold reacquires and never the warm
   path? This is the most specific unexplained signal we have.
2. **Zero live reads.** Is backfill-only a symptom of the cold path, or independent?
3. **D2W co-failure.** Does D2W drop whenever we do? (§5 — needs paired observation.)
4. **Regression vs 2026-07-21.** E4 v2 measured 100%; epoch 168 measured 26% with E4 behaving
   correctly. Either the earlier figure was measured differently (likely — it predates the
   INGEST instrument), or something regressed. Re-measure a known-good configuration with the
   current metric before concluding a regression exists.

---

## 8. Instrumentation available today

| Signal | Meaning |
|---|---|
| `[glucose] INGEST src=… stored=n/m` | the ONLY correct coverage metric (build 211+) |
| `=== G7 iOS attempt starting ===` | scheduler fired an attempt |
| `pending connect armed/FIRED after Ns` | predictive arm and its latency |
| `cold reacquire: …` | warm handle absent — running the slow path |
| `*** CONNECTED / subscribed / round0` | funnel stages |
| `*** VALUE` | LIVE reading only (not backfill) |
| `!! disconnected (…)` + reason | normal after a read; reason codes since build 205 |
| `RECREATING Bluetooth central` | stack rebuild |
| `[radio] … G7 standing down / waited Ns` | arbiter activity |
