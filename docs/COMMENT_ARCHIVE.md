# Comment archive

Verbatim text of comment lines removed by the readability pass of 2026-08-12, keyed by file.

**Why this exists.** The pass tightened the code's prose and made comments self-contained — no
`#N` / `RN` / `WSn` references a reader cannot resolve without our internal registers. Nothing
here was judged worthless; it was judged *not worth carrying at the call site*. Some of it is
load-bearing knowledge — why a guard exists, which failure it prevents — that is not written
down anywhere else, and this is the holding pen until it reaches its proper home.

**Git history is the real backstop.** `git log -p <file>` reproduces any of this exactly, in
context, and should be preferred when you want the surrounding code too. This file exists only
because nobody greps history to ask "why is this line here".

**Where it should end up.** A block recounting a field incident belongs in
`FIELD_OBSERVATIONS.md`; a block recording a decision belongs in `RULINGS.md`. Moving one there
and deleting it from here is an improvement, not a loss.

**A caveat on provenance.** Two sessions were editing this checkout concurrently on 2026-08-12.
The comment pass was committed inside two commits whose messages describe unrelated UI work
(`1a4f459e`, `3610bfc1`) — the extraction below is taken from those commits' diffs, so it may
include a small number of comment lines removed by the other session's work rather than by the
readability pass. Over-inclusion is the safe direction here.

## `WatchApp Extension/StockLoop/StockLoopSession.swift`

_136 lines, from `1a4f459e`_

```swift
//  M5 integration: the app-lifecycle OWNER of the assembled stock loop and the loan
//  controller (resolves M4's "assemble() has no call sites"). ExtensionDelegate holds
//  one of these lazily; it stays inert (no radio, no dosing) until a loan grant
//  arrives (closedDirect is the only ruled dosing mode wired so far; the R20 picker adds
//  the others at the UI layer). CGM is stock G7SensorKit and runs independently of the loan.
    /// watchOS suspends a third-party app within seconds of the wrist dropping, and there is NO
    /// CoreBluetooth state restoration on watchOS — so a suspended app cannot be woken by a BLE
    /// event. An HKWorkoutSession is the only self-service API that keeps our process (and its BLE
    /// links) alive, which is what lets the loop run and lets stock G7SensorKit receive at all.
    /// Riding the Dexcom watch app's authenticated session buys us DATA, not RUNTIME: entitlements
    /// are not inheritable by a co-resident app.
    /// Refcounted by reason ("soak" for the loan, plus "takeover"/"handback" for the two windows
    /// that need runtime of their own), so overlapping holds cannot end the session early.
    /// Reference-counted so overlapping reasons can't drop the session out from under each other:
    /// a hand-back beginning while the takeover hold is still released, say.
    /// Re-assert the session if something still wants it. Called on every foreground — the one
    /// moment we KNOW we are executing, which matters because the only other re-assert path is a
    /// timer that by construction cannot fire while the process is suspended. No-op when nothing
    /// holds it, so foregrounding outside a loan does not start a workout.
        // LINK POLICY IS AUTOMATIC (#101 phase 2, Jeremy 2026-08-10: "implement it coherently
        // not as a toggle in the diagnostic screen"). The E4 toggle is GONE — both of its arms
        // were wrong for acquisition and indistinguishable in steady state:
        //
        // - OFF (hold the pod link) starved the acquisition scan: 0 adoptions across ~130 min
        //   of held-link windows on 2026-08-10, versus adoption within 7-10 min of each of the
        //   two releases. Steady state was immune — but a session that never adopts never
        //   reaches steady state on the direct path.
        // - ON (orphan + reclaim per cycle) collided by construction while un-adopted: the
        //   reclaim fires ~100ms after the relay reading, exactly when the D2W ride appears
        //   (census 23:31:48 — pod scan :48.089, G7 ad :48.197, connect never completed).
        // The policy now: orphan between doses, reclaim every cycle (the most-validated radio
        // rhythm we have — E5 84/84, build 157 44/44, census build 263 3/3), with the reclaim
        // GATED on G7 acquisition state while un-adopted (WatchLoopManager's acquisition gate).
        // Persisted sensor identity (StockLoopStack) makes the un-adopted phase rare. The old
        // "g7.e4ReleasePod" default is no longer read anywhere. R31 amended accordingly.
        // FakeGlucose and E5 both substitute into the LIVE dosing/enact path; with their
        // toggles gone they must never linger enabled in a real session. Clear any
        // persisted test state at launch (both are trivially restored from git).
        // #86 (2026-08-03): let the pod BLE layer write into the watch's mirrored log.
        // OmnipodKit logs via os_log, which never reaches the g7watch file the field analysis
        // reads — a [CONFIG] diagnostic added to settle "did we ever talk to the pod" produced
        // zero visible lines for exactly that reason. Wired here (watch only; the phone leaves
        // the sink nil and keeps os_log).
        // #101 (2026-08-10): the G7 radio census — the acquisition mechanism was INFERRED from
        // a held-link/release toggle experiment; this makes it OBSERVED. Names which of the
        // three acquisition triggers fires (system-connected piggyback / connection event /
        // ad scan), D2W's connection rhythm, connect verdicts, and the GATT inventory at
        // unknownCharacteristic failures. Watch only, same rationale as the pod sink above.
        // Main-thread stall detector (2026-08-07). Started at LAUNCH and never stopped, unlike
        // the loan-scoped heartbeat below: the two UI freezes on 2026-08-07 were invisible to
        // every existing instrument, and one of them ended in a watchdog kill that took the
        // unflushed tail of the log with it. A wedged main thread is exactly the condition under
        // which nothing else in this app can report anything, so the one detector that can must
        // always be running. Costs one ping per second on a utility queue and stays silent while
        // healthy.
            // transferUserInfo: queued, survives reachability flaps and relaunches —
            // the delivery semantics the protocol's cursor/IDs are built around. It is also
            // explicitly NON-URGENT, which is wrong for the interactive handshake: see
            // LoanMessage.isInteractiveHandshake for the 2026-08-02 field case where a Start
            // request sat in the queue past the watch's own 25 s timeout. Those kinds take
            // sendMessage (wakes the phone app in ms) and fall back to the queue on failure,
            // so reliability is never worse than it was.
        // NO RADIO ARBITER. It existed to make loop pod commands yield to OUR OWN G7 reader's
        // scan/handshake (#84), and that reader is gone — its flags were the arbiter's only
        // producer, so the predicate could now only ever read false.
        // BE PRECISE ABOUT WHY (corrected 2026-08-06 by review): this is NOT because the app
        // stopped using the sensor radio. Stock G7SensorKit runs its own CBCentralManager
        // in-process, scans between readings and calls connect() — the app very much still drives
        // a sensor radio. What is gone is any signal about WHEN, plus the component whose
        // scan/handshake was actually starving the pod. Whether stock's own scanning contends with
        // the pod the way ours did is UNMEASURED; field data so far says no (build 244, deliberate
        // dosing load: zero deferrals, 9 cycles, 0 errors, 5/5 readings — against 79 refusals and
        // 585s blocks the night before), but that is one 30-minute run, not a proof.
        // #86 (2026-08-03): the takeover ladder needs background RUNTIME. This hook fires true on
        // entering .takingOver and false on every exit, so it is exactly the ladder's lifetime.
        // Without it the 3 s poll is throttled the moment the wrist drops and the read budget burns
        // on wall-clock instead of attempts — the measured cause of that day's takeover failures.
        // (The radio half of R26 — standing the G7 down during the ladder — retired with the
        // reader that needed standing down.)
        // Hand-back needs the same runtime the takeover ladder needed. Without it the watch
        // stops being reachable the moment the wrist drops after End, the phone's ack falls
        // back to the queued channel, and the pod stays held until iOS decides to deliver it.
        // #82 RETIRED by #84 (2026-07-31): the dose-window stand-down is deliberately NOT
        // wired. It stranded the radio overnight — the app suspended mid-ladder holding the
        // sensor off, and with no BLE events left to wake it the watch went dark for 2.9h
        // (02:21 GAP 10555s). Waiting for the sensor's attempt to END cannot strand
        // anything, and covers the same three occupancy states the hold was added for.
        // The TAKEOVER hold (R26, above) stays: it is user-present and bounded.
        // The loop reclaims the orphaned pod to dose, then re-releases it for G7 (the loan
        // controller owns the OmniPumpManager and does the bounded reconnect + settled
        // re-release). The closure names keep their historical `e4` prefix; the experiment
        // they were named for is now simply the link policy.
        //
        // #101: unconditional on BOTH sides. reclaimPodForDose already no-ops when the link
        // is held (guard isConnectionReleased → completion(true)), so this single wiring
        // subsumes both old E4 arms and can never strand a released bid (#97's failure mode).
        // The matching release gates inside PodLoanWatchController were removed on 2026-08-11
        // — left in place they read a now-unregistered key as false and held the pod link
        // forever on any fresh install.
                // R23's "every loan starts OPEN" reset was OVERTURNED 2026-08-04 (Jeremy):
                // the wrist inherits the phone's loop mode, applied from the grant in
                // PodLoanWatchController. Deliberately NOT re-asserted here — this callback
                // also fires on the hand-back-timeout resume path (:1284), where the user's
                // own choice for the session must survive rather than be reset under them.
                // H19: arm the loop-stall dead-man for the session; every live loop
                // cycle re-defers it (WatchLoopManager), so it fires only on a stall.
                // WS4b: arm the sensor-blackout dead-man; every direct reading
                // re-defers it (WatchLoopManager CGM ingestion).
                // Log pipeline v4: a 5-min PULSE independent of readings. The
                // per-reading transfer goes silent exactly when the session is dry —
                // twice (126, 127) a dead-G7 session was invisible until a manual
                // send. A dry session must still report itself.
                // Suspension detector (2026-07-22). The +90s pod release firing 3m36s
                // late is what poisoned the BLE stack; that lateness had to be inferred
                // from clustered timestamps. Now it is measured.
                // PODLOAN diagnostics: queue the session log to the phone at every
                // loan end (queued transfer survives unreachability) — a deleted or
                // reinstalled app can no longer eat an unsent log (2026-07-19).
        // Name the policy at launch, same discipline as the old E4 arm line: a log that does
        // not say which policy produced it cannot be compared across builds.
    /// Queue the on-watch log to the phone NOW (WCSession queues transfers across
    /// unreachability). Event-driven — the reading-triggered transfer cannot be the
    /// only channel, because a dry session produces no readings and goes invisible.
            // Keepalive self-heal (132, field 2026-07-20 evening): a dead
            // HKWorkoutSession previously waited for a FOREGROUND activation to be
            // re-asserted — a background session went reading-dead until the next
            // wrist raise. ensureRunning is refcount-aware and a no-op when healthy;
            // in background the restart attempt can fail (HK error 14) but logs the
            // evidence and heals at the first live moment instead of the next launch.
    // MARK: E1 — standalone-G7 diagnostic mode (task #36, 2026-07-21)
    // Runs the G7 soak with NO pod loan and NO dosing: the ONLY BLE connection the
    // watch holds is the G7. Isolates whether holding the Omnipod link concurrently
    // starves G7 connects under watchOS's per-app BLE budget. Bench-only, firewalled:
    // takes no pod, enacts nothing, arms no dosing dead-mans — pure acquisition
    // telemetry (the same SportLog VALUE/observer/recreate lines) so the catch rate
    // is directly comparable to the b136 with-pod baseline (77%).
```

## `Loop/Managers/WatchDataManager.swift`

_97 lines, from `3610bfc1`_

```swift
        // M5: construct eagerly so a relaunch mid-loan restores the persisted state
        // machine (dosing stays paused, reminders re-arm) before any message arrives.
                    // Capture-once (the 4880ef92 lesson), persisted so a relaunch
                    // mid-loan still restores the right value at reconcile.
                    // SPORT MODE (#2): loan just started — cancel the "Loop Failure" batch the last
                    // pre-loan loop already queued (the podOnLoanProvider gate stops FUTURE re-arms,
                    // but the queued 20/40/60/120-min ladder must be killed now so it never fires
                    // mid-loan). Also covers relaunch-into-loan (this closure runs at reconcile).
                    // #26: the ForLoanGrant variant also drops the future rungs' bookkeeping so
                    // loan-end inference can't record phantom "issued" alerts for cancelled rungs.
                    // #26 (replace, don't just mute): arm the watch-silence dead-man — during a
                    // loan the alarm-worthy failure is the WATCH going dark, not the phone not
                    // looping. Ungated arm (the loan state flips after this closure runs);
                    // main-hopped so every watch-silence mutation serializes on one queue.
                    // #26: this closure runs ON the loan controller's serial queue, and the
                    // reschedule below reads the podOnLoan gate, which does queue.sync onto that
                    // SAME queue — calling it inline is a guaranteed deadlock (adversarial
                    // review blocker). Hop to main: by the time it runs, state == .owner is
                    // already set (every unpause site flips state first), so the gate is open
                    // and reads safely cross-queue. The main hop also serializes the clear
                    // against any in-flight watch-receipt re-arm (TOCTOU).
                // #42 (2026-08-02): mirror of the watch's transport policy. The interactive
                // handshake (grant / denial / revoke / hand-back ack) takes the immediate
                // channel so a backgrounded watch app is woken now instead of whenever iOS
                // decides to drain its queue; record-bearing and diagnostic traffic keeps
                // transferUserInfo's guaranteed delivery. Failure falls back to that queue,
                // so this is never less reliable than the previous unconditional path.
                // #61/#35: log the SEND outcome. The grant's delivery was previously a black
                // box — an urgent send could fail into the queued fallback with no line saying
                // so, and on the simulator the queued path may not drain for minutes, which
                // presented as "phone granted, watch timed out" with zero evidence in between.
                // #69/#52: loan insulin behaves like real pump insulin — PumpEvent rows
                // (Event History) + stock reconciled() truncation + HealthKit. All loan
                // doses are IMMUTABLE (the interim open temp is deferred to the final drain),
                // so replacePendingEvents:false — there is no loan mutable dose to replace,
                // and it must NOT purge the phone's OWN resumed-pod in-flight temp when a
                // post-reclaim write (re-audit / forced reclaim) lands.
            // R30 (#89): a carb the WRIST deleted during the loan. Deleting through
            // `loopManager.deleteCarbEntry` (not carbStore directly) is deliberate — that is the
            // same door CarbAbsorptionViewController's swipe-to-delete uses, so the phone's COB
            // and prediction invalidate exactly as they do for a phone-side deletion.
            // MATCHED, NOT TRUSTED. We re-read the store and match rather than reconstructing a
            // StoredCarbEntry from the wire: syncIdentifier first (phone-originated carbs carry
            // the phone's own, seeded through the grant), falling back to (startDate, grams)
            // within a second. A miss is logged and dropped — deleting the WRONG carb because a
            // key was ambiguous would be far worse than failing to delete, and the failure
            // direction here is a carb that survives and keeps driving dosing, which is visible.
                // #68 part B: the watch's override lands on the phone through the SAME single
                // door every other override uses — mutateSettings, whose didSet does the
                // overrideHistory.recordOverride (LoopDataManager:269-270) that actually
                // rescales basal/ISF/carb-ratio. Nothing bespoke, and no merge: during a loan
                // the watch is sovereign over overrides, so this is a straight assignment.
                // Called INLINE on the loan controller's queue (as setAutomaticDosingPaused
                // above already does) so the controller's "already applied?" read and this
                // write cannot interleave; mutateSettings is Locked-based and any-queue safe,
                // and its own oldValue != newValue guard makes a redundant write free.
            // R23 overturned 2026-08-04: overwrite the captured pre-loan value with the WRIST's
            // final mode, so the restore in setAutomaticDosingPaused(false) picks it up
            // untouched. Writing the SAME key inherits the persistence that already survives a
            // relaunch mid-loan, and leaves the "missing capture defaults to OPEN" fail-safe
            // exactly as it was. Called inline on the loan controller's queue, like the
            // override door above; UserDefaults is any-queue safe.
                // #49: the phone's active carbs, carrying the identity CarbStore.syncCarbObjects
                // dedups on so re-seeding is idempotent. Absorbed carbs older than the window
                // fall off naturally; only entries with future absorption matter for COB.
                // INSTRUMENTATION ONLY (#45): the phone's last-computed prediction, decomposed,
                // for the grant. Pure cached read (no recompute, no dosing).
                // R33 (2026-08-11): the pod is home and reachable; drop the temp the WATCH set.
                // ORDER MATTERS. Clear the pre-loan capture FIRST: `setAutomaticDosingPaused(false)`
                // at the END of the next loan restores dosingEnabled from this key, so leaving it
                // set would silently re-close the loop R32 just opened — the user would get one
                // loud warning and then have the machine quietly resume anyway, which is worse
                // than never warning. With the key cleared, the next loan captures `false` and
                // restores `false`; only the user's own settings change re-closes the loop.
        // PODLOAN: while the pod is loaned to the watch this phone CANNOT deliver —
        // its pod link is deliberately released. Current watch builds enact locally
        // and never send a bolus here mid-loan; this catches stale/legacy requests
        // LOUDLY instead of letting them die in a BLE timeout. DELIVERY ONLY is
        // refused — an attached carb entry still stores below (dropping it would
        // lose the meal from the record entirely).
    /// #42: the IMMEDIATE channel. sendMessage(replyHandler: nil) lands HERE — the
    /// replyHandler variant above is only called when the sender supplied one — so without
    /// this method the watch's urgent Start request would be silently dropped. Mirrors the
    /// loan routing in didReceiveUserInfo below, including the sensor-code re-relay that a
    /// request triggers.
        // M5: loan protocol v2 rides its own single key. Unknown payloads are logged
        // and ignored — never asserted on (failure-matrix row 17: WC redelivers
        // queued userInfo across reinstalls).
            // #35 liveness: log EVERY loan userInfo the OS delivers to this phone, before
            // routing. If a future field log shows the watch resending offers but NO
            // "Loan userInfo delivered" line here, the OS never handed them over (app
            // suspended/killed/unreachable) — a delivery problem, not a controller drop.
            // Component A re-arm: a loan REQUEST is the moment the watch needs the
            // current sensor's pairing code (its direct-G7 bond/prewarm path). The
            // automatic .sensorStart capture only fires for sensors started after
            // install — for the sensor already on-body, re-relay the held code or
            // prompt for it now.
```

---

# 2026-08-13 sweep — narrative removed from six blocks

Comments-only; behavior provably unchanged. What was cut was the incident narrative. What each
comment now says is why the code is there and what it does. The findings themselves live in
FIELD_OBSERVATIONS.md and the commit history — this file keeps the detail that was in the code.

**GlanceController, the >20 s manual-bolus label.** The removed account: the second branch used
to read "waiting for sensor — bolus will deliver", which Jeremy called out in the field on
2026-08-05 ("it seems like that happens every time… in theory this should only happen when the
bolus coincides with a G7 read, so 10% of the time"). It was wrong twice over — never gated on
the G7 at all (a bare 20-second stopwatch, firing whenever a bolus was merely slow), and naming
a wait that cannot occur on this path, since R5 exempts manual boluses from the radio arbiter
(WatchLoopManager :2176) and there is no defer gate in enactManualBolus. True rate zero, not
10%. The #91 wording pass (2026-08-08, "'reaching' is no good") settled on "starting" over
stock's "Bolusing" (BolusProgressTableViewCell :111) because stock's verb is true on the phone,
where the pump is already connected, and false here where the pod is still orphaned. Three doses
were lost to End taps during this window, which is why the label exists at all.

**LoanProtocolV2, the urgent-channel list.** #42 (2026-08-02). Field 2026-08-02 08:38: a Start
request sat queued while the phone slept, the answer reached the watch 40 s later — 15 s AFTER
the 25 s timeout had told the user the takeover failed. An unrelated sensor-code relay arrived
0.1 s from the grant, the signature of a whole queue flushing on wake. #109 (2026-08-12) moved
`.takeoverComplete` to the urgent channel; measured on build 268 epoch 10, the watch had the pod
at +10.2 s and said so 1 ms later but on transferUserInfo, and at +20 s the phone was still in
`.grantOffered` and fired the #108 "did the grant arrive?" probe at a takeover that had already
succeeded. Invisible until the tile stopped treating `.grantOffered` and `.loaned` identically.

**PodLoanWatchController, the stalled-ladder message.** #86 (2026-07-31): the takeover ladder
ran with NO keepalive, because startSoak() only fired once the loan went ACTIVE — which needs a
takeover that already succeeded. Epochs 81-83 at 15% battery: reads stalled 86 s and 70 s, each
resuming only on a wrist raise, three takeovers failed in a row while the pod was fine. Fixed by
the 2026-08-06 keepalive-ownership refactor wiring `onTakeoverRadioHold` to the same
WorkoutKeepalive soak and hand-back use; from build ~244 `.takingOver` holds runtime for the
whole ladder. The old note blamed the pod ("check the pod is nearby and awake") and quoted a
40 s timeout that no longer matched the ~180 s ladder.

**PodLoanWatchController, asserting our own program at takeover.** R2 was OVERTURNED 2026-08-11
(Jeremy: "cancel any running temp as part of takeover, run a fresh loop/prediction at takeover,
and enact a new temp… it clarifies things"). R2 had said the phone does not cancel its running
temp and "the grant→first-enact gap is covered by the odometer audit" — and that clause was
load-bearing, but the audit had never printed a usable number (it compared whole-loan delivered
against one drain's doses). The ruling was resting on a net that was not reporting. Inheriting a
running temp was the root of #72 (unbooked tail), #76 (re-arm copy divergence), and the C5
record-close truncation.

**PodLoanWatchController, the R35 ledger seed.** R35 (2026-08-11, Jeremy: "stop pretending — use
it for settings and that's it"). The function was ~120 lines: wipe both DoseStore tables, audit
the wipe, force-repurge on a leak, hex-decode seed identities, seed via addPumpEvents, read the
store's IOB back. All of it maintained a second dose book that #111 proved never persisted a
row. The wipe leak (#110), the repurge (#111), #69's hex-decode and the SEED-IN store read all
left with it. The log line kept saying "1 live dose(s) omitted" for a build after that stopped
being true — field log 2026-08-12 18:08:00 has it directly under `[ledger] seeded — 123 doses
(122 finished + 1 live)`.

**WatchLoopManager, override-applied schedules.** #68 (2026-08-01): the port passed raw settings
schedules, so an override moved the target but not the scales. With a 60%-needs override the
[dosemath] line read `scheduled 0.70 · ISF 70` where 0.42 / ~117 were intended — every "neutral"
temp a 1.67x high temp, corrections 1.67x oversized, systematic OVER-delivery under a
reduced-needs override, while the prediction path already used the applied ISF (:1211, :1607) so
prediction and dosing disagreed. #112 (2026-08-11) then removed the `?? settings.<raw>` fallback
for stock parity.

## Second batch, same date — four more blocks

**PodLoanWatchController, loanDidRecordCarbs — this one was WRONG, not merely long.** It opened
with a whole paragraph of superseded v1 policy: "SUPPRESSED in v1 (Jeremy 2026-07-26): carbs are
ONE-WAY phone→watch ... Carb entry during a loan isn't part of v1, so this is a guard: we do NOT
mint a `.carb` journal event or stream it. Re-enable the round-trip (restore the mint +
streamRecords below) when the phone-side idempotent carb ingest lands. The carb-entry UI still
calls this; it just no-ops." The very next line said #49/#66 (2026-08-04) had shipped the
round-trip. A reader taking the paragraphs in order would conclude the opposite of what the code
does. Deleted rather than rewritten.

**PodLoanWatchController, the grant-timeout cancel ordering.** The stranded-phase fix
(2026-08-06): `requestTimeoutWork?.cancel()` used to run as the FIRST line, before validation, so
every rejection returned without restoring `phase` — leaving the controller at `.requested` with
no timeout pending and nothing to move it. Since requestLoan guards on `phase == .idle`, Start
became a silent no-op and Sport Mode was unstartable until relaunch. debugReset was the other
escape at the time; it was removed 2026-08-11.

**PodLoanWatchController, teardownPump's explicit BLE release.** Added 2026-08-04. Field evidence
(Jeremy): during "Reclaiming…" the phone's pump status read minutes old, from BEFORE the loan.
Measured — the watch reported CLOSED 0.9-7.2 s after End, yet the phone did not reach a verified
round-trip for another 85-99 s. Crude never had this problem because crude never had this
teardown path; E4 releases explicitly every five minutes and logs a clean
`state connected -> disconnected (+3s)`.

**PodLoanWatchController, the #81 reclaim gate.** The statistics stay in the code — they are the
non-obvious thing the gate exists for. What left is the regression history: it broke via two
changes that only co-occurred on 2026-07-30, the loop trigger moving to the phone-BG fallback
(firing ~1 s AFTER G7 connect, mid-handshake, where the watch's own glucose packet used to fire
at handshake END), and #54 making scan-adopt primary (a one-shot scan is contention-sensitive
where the old queued pending-connect with its read-6 escalation was not). Jul 25-26, live sensor,
old paths: 59/59.
