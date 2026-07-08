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
