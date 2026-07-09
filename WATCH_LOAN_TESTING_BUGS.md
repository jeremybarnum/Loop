# Watch Pod Loan — testing bug log

Running list of bugs found during live loan testing (branch `watch-handoff`).

---

## BUG-1: Stuck on "Handed back to iPhone" — can't Borrow again (found 2026-07-07)

**Symptom:** After a successful hand-back, opening the pod screen on the watch shows
"Handed back to iPhone" (the `.done` state) with no way to start a new loan — no
"Borrow pod" button. User must force-quit the watch app to Borrow again.

**Root cause:** `WatchPodLoanCoordinator.Phase.done` is terminal. `WatchPodControlView.doneSection`
renders only the checkmark + summary, with no action. Force-quit works around it
because a fresh launch reinitializes the coordinator to `.idle`.

**Fix (small, watch-side):** add a `reset()` on the coordinator (phase = .idle,
clear `status`/`heldGrant`/`lastError`) and a "Borrow again" / "Done" button in
`doneSection` that calls it. Optionally auto-return to `.idle` after a few seconds
on the done screen.

**Workaround:** force-quit + reopen the watch app.

**Severity:** low (UX only; loan/handback themselves work). Batch into next build.

---

## BUG-2: Suspend shows "priming" on the watch status card (found 2026-07-07)

**Symptom:** After tapping Suspend, the watch status headline reads "priming" instead
of "Suspended." The suspend command itself works — `STOP_DELIVERY (0x1f)` confirmed
landing on the pod.

**Root cause:** `WatchPodControlView.statusCard` shows `status.deliveryStatus`, and
`PodProofStatus.deliveryStatus` is set as `String(describing: response.deliveryStatus)`
(`WatchPodSandbox/PodSDK/Sources/OmniBLECore/Facade/PodProofKit.swift:111`) — i.e. the
raw OmniBLE `DeliveryStatus` enum case name, shown verbatim. Open question whether the
emulator's STOP_DELIVERY response reports a delivery-status byte that decodes to
`.priming`, or the raw description is just wrong/unfriendly — verify against a real pod.

**Fix:** map `DeliveryStatus` to explicit human strings (suspended → "Suspended",
scheduledBasal → "Basal", etc.) instead of `String(describing:)`. Confirm the actual
post-suspend deliveryStatus value on a real pod.

**Severity:** low (cosmetic; command works).

**Resolution (2026-07-07): WON'T FIX.** Confirmed it's our display, not the emulator:
`DeliveryStatus.priming = 4` is the internal name for "bolus active while basal
suspended" (`Pod.swift`), shown verbatim by `String(describing:)`. It only appears if
you tap Suspend *while a bolus is still in flight* — a pattern that won't occur in real
use. Left as-is to keep things simple.

---

## BUG-3: No feedback/spinner while Claim is in progress (~3 s) (found 2026-07-07)

**Symptom:** Tapping "Claim pod" gives no visual feedback for ~3 s while the takeover
runs — looks like nothing happened.

**Root cause:** `WatchPodControlView.armedSection` disables the Claim button on
`coordinator.busy` but shows no progress indicator; during the claim the phase stays
`.armed`, so no spinner renders. (Borrow already shows a spinner via the `.requesting`
phase — Claim just needs the equivalent.)

**Fix:** show a `ProgressView` + "Claiming…" in `armedSection` when `coordinator.busy`,
or add a dedicated `.claiming` phase.

**Severity:** low (UX polish).

---

## DESIGN-GAP-1: Phone never releases the pod on loan → reclaims it on BT-enable (found 2026-07-07)

**Symptom:** Re-enabling the phone's Bluetooth during an active loan lets the phone
grab the pod back from the watch (via the emulator crash + reconnect race), even
though the watch "holds" it. The phone should stay off the pod until hand-back.

**Root cause:** `handlePodLoanRequest` (`WatchDataManager.swift:514-539`) only sets
`podLoanedToWatch` + pauses dosing. It never touches the BLE link, so the pod's UUID
stays in `BluetoothManager.autoConnectIDs` with a standing zero-backoff `connect()`.
BT-on is literally a reconnect trigger (`BluetoothManager.swift:282-292`).

**Why it matters (safety):** verified via two multi-agent investigations — a real DASH
pod does NOT enforce mutual exclusion between two SAME-controllerId devices (watch and
phone share the copied tuple). Single-writer must be enforced in software. Two devices
driving the pod independently diverge the sequence counters, which AndroidAPS warns can
BRICK the pod. See memory: pod-single-writer-safety.

**Fix (spans OmniBLE + a shared protocol + Loop):**
1. Add `PodComms.disconnectAndStayDisconnected()` (drops pod UUID from `autoConnectIDs`
   via existing `disconnectFromDevice`, keeps `podState`) and `reconnectToExistingPod()`
   (re-adds UUID → auto re-establish → getStatus resync). Do NOT use `forgetPod()` — its
   pump-manager wrapper nulls `podState` (`OmniBLEPumpManager.swift:755-777`), irreversible.
2. Expose `releasePodConnectionForLoan()` / `reclaimPodConnection()` on OmniBLEPumpManager,
   reachable from Loop via a small capability protocol in LoopKit (Loop can't `import OmniBLE`).
3. `handlePodLoanRequest`: call release inside the first-grant guard, next to the dosing pause.
4. `handlePodHandback`: call reclaim; drop the inline `ensureCurrentPumpData` (link isn't up
   yet) — resync happens for free on reconnect.

**Test on emulator:** grant loan → confirm phone dropped from autoConnectIDs + isConnected
false → toggle phone BT off/on → PASS = phone does NOT reconnect (no "New connection from"
phone on the Pi, no crash). The crash simply not happening is the pass signal.

**Severity:** HIGH (this is the single-writer safety property; the actual point of the feature).

---

## BUG-4: Borrow hangs ~2 min before "Pod keys ready" (found 2026-07-07)

**Symptom:** Tapping Borrow (phone on) spins for a couple of minutes before it lands on
the `.armed` "Pod keys ready" screen.

**Root cause:** `handleGrantReply` (`WatchPodLoanCoordinator.swift`) immediately calls
`takeOver()`, which runs `takeOverExternalPod` against a pod the phone still holds. The
BLE connect can't succeed (slot busy) and burns its full timeout (~2 min) before falling
back to `.armed`.

**Fix:** on Borrow, skip the immediate takeover — store the keys and go straight to
`.armed`. The takeover belongs to Claim (after the phone is off), where it can actually
succeed. The immediate attempt only ever succeeds if the pod slot happens to be free,
which in the intended phone-on Borrow flow it never is — so removing it costs nothing and
removes the hang.

**Severity:** low (UX; functionally correct, just slow).

---

## OPEN QUESTIONS

### OQ-1: Does a real pod first-lock or ping-pong between same-controllerId devices? (saline-pod testing rung)

Unresolved by code/emulator (see memory: pod-single-writer-safety). Two possibilities for
what a real pod does when a second device with the SAME controllerId+LTK tuple connects
while the first holds a live session:
- **First-locks:** second device refused until the holder proactively releases.
- **Ping-pong (leaning this way, moderate confidence):** last device to complete a valid
  in-sequence handshake wins; the other goes stale.

**Definitive experiment (needs a real/saline pod — the emulator crashes on the 2nd
connection, an unfinished path, not a modeled behavior):** device A holds a live, active
connection; device B (same copied keys) attempts to connect *while A is still connected and
not dropping*. If B is refused until A releases → first-locks. If B connects and A sees a
disconnect → ping-pong.

Does NOT block the design: both models require software single-writer (DESIGN-GAP-1). Under
first-locks the failure is "watch loses the pod on any link blip and is locked out"; under
ping-pong it's "sequence-counter divergence / brick risk." Same fix either way.

### OQ-2: Does Control Center Bluetooth-off actually disconnect the iPhone from the pod?

Earlier finding (E5) claimed toggling Bluetooth off via **Control Center** does NOT truly
disconnect (iOS keeps BT on for the phone's own use), so **Settings → Bluetooth** was
required to free the pod for the watch. Jeremy is skeptical — **test it**: with the watch
armed, toggle BT off via Control Center only, then Untether, and watch the pod side. If the
watch takes over cleanly, Control Center is sufficient and the UI copy ("Disconnect
Bluetooth on your iPhone") stays as-is. If the takeover fails (phone still holds the pod),
the copy must become "in Settings" and the E5 finding stands.

**RESOLVED (2026-07-08, emulator, controlled comparison — E5 inverted):**

- **Control Center BT-off** (17:08 run): pod IS dropped (non-Apple accessory) → watch
  takeover + bolus clean; watch↔phone WatchConnectivity survives (Apple-ecosystem traffic
  is exempt from CC-off) so hand-back even works without re-enabling BT. **BUT the phone's
  BLE stays live** — it reconnected to the pod at 17:09:17 with CC still "off", same BLE
  address `bd:48…` (radio never cycled), and it retries the pod ~every 60 s. The test
  session (~30 s) simply fit inside one reconnect cycle. **A longer session = the phone
  races the watch for the pod mid-loan → the DESIGN-GAP-1 single-writer hazard.** So E5
  inverts: CC-off DOES disconnect the pod, but does NOT disable the phone's BLE.
- **Settings BT-off** (17:13 run): radio truly dead; phone cannot touch the pod during the
  loan; on re-enable it returned with a NEW rotated BLE address `8a:f0…` (full radio-cycle
  fingerprint) and reclaimed cleanly at 17:14:18.

**Rule until DESIGN-GAP-1 (phone-side pod release) is built:** instruct **Settings →
Bluetooth off** only. CC-off becomes a legitimate (and nicer, one-toggle) flow ONLY once
the phone proactively releases the pod for the loan's duration. The "iPhone Bluetooth Is
Off" end-alert guards on WCSession reachability — under CC-off the phone is (correctly)
still reachable so no alert; under Settings-off it fires as designed.

### OQ-3: Takeover after Settings-BT-off seems to require foregrounding Loop + dismissing its Bluetooth alert (found 2026-07-08, hardware)

**Symptom (Jeremy):** after turning Bluetooth off in Settings, the watch takeover only
succeeded after (a) bringing Loop to the foreground on the phone — it shows a
"Bluetooth needs to be enabled"-style warning — and (b) dismissing that warning. Then
Enable Show Mode worked.

**Two candidate mechanisms (discriminating experiment below):**
1. *Causal:* the phone doesn't fully release the pod BLE link (or bluetoothd keeps some
   state alive) until Loop runs foreground and processes the BT-off transition; the
   dismissal genuinely frees the slot.
2. *Timing coincidence:* the pod side simply takes ~30–60 s to drop the stale phone
   connection after BT-off, and the foreground/dismiss ritual burns exactly that time.
   (Earlier same-day successes may have masked this because Loop was being used actively
   around each test.)

**Experiment:** Settings-BT off → do NOT touch the phone → wait 60 s → Enable Show Mode.
Clean takeover ⇒ timing (fix: watch enable-screen copy adds "wait a moment"). Failure
until the alert is dismissed ⇒ causal (fix: copy tells the user to open Loop and dismiss
the warning; investigate the phone-side connection release).

**Status 2026-07-08 (late):** Jeremy leans CAUSAL from repeated hardware runs, not yet
tested to full precision. If confirmed, the mechanism is worth understanding before
wording the UI copy — a Settings-level radio kill shouldn't need app cooperation to drop
a BLE link, so the dismissal presumably correlates with Loop foreground-processing some
transition it defers while backgrounded. Precision test still pending.

**RESOLVED 2026-07-09 (controlled no-touch run, emulator): TIMING, not causal.**
Protocol: horse tap (BT on) → Loop backgrounded → Settings-BT off → phone locked and
untouched → 90 s wait → Enable Show Mode → **clean takeover, no dismissal, no Loop
foregrounding**. Pod-side timeline (clock-offset corrected): the phone's stale
connection dropped on the pod's ~60 s idle timeout well within the wait; the slot was
free ~80 s before the Enable tap. Last night's "needed to dismiss the alert" was the
ritual burning exactly that window. Fix: enable-screen copy should tell the user to
wait ~a minute after turning Bluetooth off (see wording proposal). Re-confirm the drop
timing on a real DASH pod (different supervision/timeout semantics possible).

**Either way:** DESIGN-GAP-1 (phone proactively releases the pod at loan grant)
eliminates this whole class — no BT toggle, no alert, no ritual. This is additional
motivation for it. **FAQ note meanwhile:** current reliable procedure is: turn BT off in
Settings → open Loop → dismiss its Bluetooth warning → Enable Show Mode on the watch.

---

## OQ-4: Phone cannot re-establish its pod session after a loan — emulator wedges (found 2026-07-09)

**Symptom:** After a clean hand-back (reconciliation correct: `podDelta=0.50`,
single `reconciled: 1 dose(s)`), the phone reconnects to the pod at the BLE layer
(`Pod connected` → `didDiscoverServices` → `needsSessionEstablishment=true`) but the
EAP-AKA session establishment fails every ~30 s: first
`CommunicationError("Could not send the EAP AKA challenge")`, then `emptyValue`, then
steady `PeripheralManagerError.timeout` on the characteristic write. Loop shows
"Signal Loss" indefinitely — it does NOT self-heal. Ran ~4–5 min (08:37–08:41) in a
stuck retry loop. Pod-side: the phone's BLE address connects every 30 s but the
emulator logs no command in response and does not crash.

**Unstick:** `sudo systemctl restart podsim` (emulator). Immediately after the restart
the phone's next knock re-established cleanly: `GET_STATUS` then `PROGRAM_INSULIN`
type 01 (phone reasserting scheduled basal) within 5 s. So the phone's reclaim logic
is CORRECT — the blocker was stale per-connection session state the emulator carried
from having hosted the watch's keys/counter during the loan, which a fresh
establishment could not clear.

**Why it matters / Friday crux:** a real DASH pod has **no restart button**. The open
question is whether a real pod carries the same wedged session state after the watch
advanced its message counter, or whether it re-hosts the phone cleanly. If it wedges
like the emulator, that is a hard DESIGN-GAP-1 blocker needing a real mitigation
(candidates: pass the advanced messageNumber back to the phone at hand-back so it
resumes with the correct counter instead of a stale one; or force a clean re-pair on
reclaim). **This is now the single most important thing to prove on the real pod.**
Do NOT conclude the reclaim "works" from emulator runs — the emulator is the flakiest
oracle for exactly this layer, and here it needed manual intervention to recover.

**Tooling note:** `idevicesyslog` (libimobiledevice, `brew install`) now streams the
phone console without root — use `idevicesyslog -p Loop` filtered on `Watch loan` /
`session sync` for future reclaim debugging instead of hand-pasting Console.app.

---

## DESIGN-2: Phone status must be truth-only — "On Watch" removed (2026-07-09)

**Jeremy's principle:** the phone states only what it knows first-hand. A loan grant
doesn't prove the watch took over (granted-but-never-enabled leaves the flag set), and
with Bluetooth off the phone can't see either device — so "On Watch" was an unverifiable
claim. Whether the watch holds the pod is for the WATCH to say.

**Implemented** (DeviceDataManager+DeviceStatus.pumpStatusHighlight):
- Bluetooth off/unauthorized → the Bluetooth highlight (radio truth first; previously
  "On Watch" wrongly outranked it).
- Bluetooth on + loan window + pod contact stale >8 min → **"Pod Not Connected"**
  (phone's own connection state, no watch claim).
- Fresh pod contact → normal status (a stale loan flag cannot manufacture a warning).

Wording "Pod Not Connected" is a first draft — flag for Jeremy's review.

**PARKED 2026-07-09 — approach direction (not yet built):**
- Responsive seconds-level icon needs the passive BLE `CBPeripheral.state` (or an
  unthrottled poll) — both walled inside OmniBLE; blocked by the no-framework directive.
- Framework-free alternative (Jeremy's reframe): evaluate pod-status age **at a
  regular loop-refresh moment**, not on a free-running timer. A healthy cycle just
  freshened the data (~0 min); if status is still >~2 min right after, the cycle
  FAILED to reach the pod — a true signal, low false-positive. Hook: Loop already
  emits `pumpDataTooOld` per cycle (seen in logs) — Loop app state, likely reachable
  without touching OmniBLE. Tradeoff: resolution = loop cadence (~5 min lag), correct
  but not fast. Investigate when un-parked.
- WATCH side is lower priority: pod (on body) + watch (on wrist) are co-located, so
  watch–pod separation is rare (unlike phone–pod). Watch battery also argues against
  aggressive connection-listening. The watch's real split-brain trigger is the PHONE
  reclaiming, better handled by a reclaim handshake than constant watch listening.

---

# REAL-POD BENCH SESSION — 2026-07-09 evening (first real DASH hardware)

Three full Show Mode cycles on a real pod (open loop, bench). Build: watch-prediction
@ eb98f39f-era TestFlight. Full phone-log evidence in the session logarchive + capture.

## OQ-4 RESOLVED (real pod): EAP SQN resynchronization observed
At 19:48:00 the phone re-established its session after the watch loan and the log shows
"Received EAP SQN resynchronization … Updating EAP SQN to: 15" — the REAL pod gracefully
resyncs a controller with stale session state. This is the exact operation the emulator
crashes on ("expected 3030 received 3036") and then wedges after restart. OQ-4's wedge
is an emulator defect; the real pod healed every handoff all night (3 cycles, zero
wedges, reclaims in ~2 s, takeovers in ~11 s).

## Validated on real hardware tonight
- Multi-cycle enable → command → hand-back → re-enable: clean, three times.
- Takeover ~11 s after Settings-BT-off (real pod frees the connection at supervision-
  timeout speed — the emulator's 60 s idle-drop was an artifact; no "wait a minute"
  copy needed).
- WATCHCONNECTIVITY OVER WI-FI PROVEN with timestamps: hand-back #1 received 19:22:44
  and grant #2 completed 19:23:14 — Bluetooth stayed off until 19:24:11. Both
  directions of the loan protocol run BT-off on shared Wi-Fi.
- Watch resume() programmed the REAL basal schedule to a real pod (accepted; scheduled
  clicks resumed ~1/min at ~3 U/hr).
- Negative session basal end-to-end: 7-min watch suspend → watch "Session Basal −0.36"
  == phone shadow line "net −0.36 U" (independent computations, exact agreement).
  First §5-gate real-pod evidence point. Loop's own IOB is knowingly ~0.36 overstated
  (stock assumes schedule ran — see PodState.swift:302-353 findings) — the exact gap
  the symmetric write-back (§4a/§4b options) would close.
- Reconciliation integrity: journal boluses entered at real timestamps (0.5@19:21,
  0.3@19:23, 0.55@19:25); failed bolus NOT journaled; negative remainders clamped;
  basal-only journal → zero entries + hash persisted.

## BUG-5: watch command failure is SILENT (top priority)
Split-brain test: watch bolus 0.9 attempted at ~19:51 while the phone held the pod.
Pod accepted the watch connection (dropped the phone 19:51:44) but the phone's
auto-reconnect stole it back in 2 s → watch command never completed → NO delivery, and
NO error shown anywhere. The dose screen dismisses optimistically on crown-confirm; the
failure lands later on coordinator.lastError which nothing surfaces prominently. The
journal/Session rows correctly EXCLUDE it (truthful-but-passive). FIX: failed pod
commands — especially bolus — must alert loudly (haptic + persistent error banner).

## OQ-5: podDelta=0.00 on 2 of 3 sessions (odometer freshen race suspected)
Audits: S1 podDelta=0.00 (0.5 U definitely delivered), S2 podDelta=1.00 (plausible),
S3 podDelta=0.00 (~0.4 U delivered). Suspect: hand-back's final getStatus freshen fails
(S3: phone held the pod at hand-back; S1: freshen may have raced the in-flight bolus) →
deliveredLatest stale from claim → delta 0 → remainder negative → clamped (safe, but
the audit is blind). FIX: audit line must log raw deliveredAtStart/deliveredLatest +
freshen success/failure; consider freshen retry.

## DESIGN-3: phone auto-reconnect during an active loan (split-brain window)
With BT re-enabled mid-loan the phone reclaimed the pod within seconds while the watch
still showed Show Mode active. Pod = last-connector-wins (it dropped the phone to accept
the watch at 19:51:44); the PERSISTENT reconnector (phone) beats the one-shot connector
(watch), so the phone dominates contention. Dosing-paused-at-grant makes this safe-ish
today (phone won't command), but the window is real: watch commands fail silently
(BUG-5) and control is ambiguous. Policy needed: suppress phone pod-reconnect while
podLoanedToWatch (DESIGN-GAP-1's other half), or a reclaim handshake.

## DESIGN-4: hand-back received while phone BT is off → pod orphaned; nag needed
Wi-Fi hand-back means the phone can hold the journal while unable to touch the pod
(BT off): pod runs the watch's last program with NO controller until BT returns. The
watch-side BT-off alert never fires in this case (phone IS reachable). FIX: phone-side
alert on hand-back-received-while-BT-off: "Pod handed back — turn on Bluetooth to
resume control." (The watch alert's condition tests reachability; the real question is
pod-controllability.)
