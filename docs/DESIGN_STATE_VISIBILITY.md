# Design Note — Pod Control/Ownership State Visibility (Watch + Phone)

**Status:** **3a DONE + validated on device (2026-07-11, TestFlight build 78).** 3b/3c still design. From the 2026-07-11 bench findings (cluster 3a/3b/3c in `RELEASE_TEST_FINDINGS_2026-07-11.md`).

- **3a — watch "signal lost" indicator — SHIPPED & TESTED.** The Show Mode horse button (WatchKit `ActionHUDController`) tints **amber** (`.agingColor`) when the watch loses its BLE link to the pod during a loan, and returns to green on reconnect. Chain: `PodProofKit.onConnectionChanged` (fired from the connect/disconnect handlers) → `WatchPodLoanCoordinator.podConnected` (published, ~3s debounce so a routine drop-and-reconnect doesn't flash) → `ActionHUDController` re-`update()` repaints. Faraday-box test 2026-07-11: pod isolated → horse amber after the BLE timeout + debounce; pod removed → green within ~1s. Commit `b57a032a`. NOTE: a literal no-signal *badge* overlaid on the horse isn't possible in code on watchOS (`UIGraphicsImageRenderer` is `API_UNAVAILABLE(watchos)`) — the amber tint is the "subtle-first" v1; a storyboard image element is the louder upgrade if wanted.

## Principle

> The user should be able to tell — **at a glance, without taking any action** — who actually controls the pod and whether that control is **live**. Abnormal states are **surfaced, never hidden in a log**. Each device stays **epistemically honest**: it distinguishes "I know this is true right now" from "this was last true when I could still check."

These are **safety features (P5 — no silent failure)**, not cosmetics. The failure mode they prevent: a user *believing* they're in control (or that the pod is doing X) when it isn't — on the watch (a silently-dropped pod link still showing "basal running") or the phone (IOB blind after an escape-hatch reclaim, or not knowing the pod is on the watch at all).

## The states to represent (the ownership state machine)

Reality is the source of truth; each device shows only what it can *honestly* claim.

| # | Reality | Watch shows | Phone shows |
|---|---|---|---|
| 1 | **Phone control** (no loan) | Show Mode off | normal (implicit "phone controlling") |
| 2 | **Takeover in progress** | "Requesting… → Connecting to the pod…" *(done)* | "Handing off to Watch…" |
| 3 | **Loan active, pod link LIVE** | "Show Mode · connected" | **"On Watch"** (while WC contact is live) |
| 4 | **Loan active, pod link DOWN** (watch lost the pod; pod running autonomously) | **"Signal lost — reconnecting"** *(3a)* — replaces the confident "basal running" | **"On Watch — can't confirm"** when WC contact is also lost; or a relayed "watch lost the pod" if WC is up (see fork) |
| 5 | **Limbo** (phone released, watch never took real control) | may sit on "Connecting…" / failed | **"Handoff incomplete — reclaim to be safe?"** |
| 6 | **Hand-back in progress** | "Ending Show Mode…" | "Reclaiming…" |
| 7 | **Reclaimed, records pending** (escape hatch — watch dead/gone) | "Reclaimed by iPhone" | **"Reclaimed — the watch's insulin isn't in records yet"** *(3c + finding ①)* |
| 8 | **Abnormal hand-back** (journal drained via recovery) | done screen | surface the **⚠️** summary *(3c)* |

Startup edge case (from B7): tapping Start Show Mode with the **watch's Bluetooth off** currently hangs silently → should say **"Bluetooth off — turn it on to start Show Mode."**

## Watch — the *controller*

The watch is actively driving the pod during a loan, so its indicator is about **its own link to the pod**. The core deficiency (finding 3a, confirmed in code): there is **no liveness monitoring** — no heartbeat/periodic poll (`refreshStatus` is never called on a timer), and a BLE disconnect is handled by **silent auto-reconnect** (`PodProofKit` logs `"BLE: disconnected (auto-reconnect will retry)"`, sets no UI state). So states 3 and 4 look identical to the user.

**What to add:**
- A live connection indicator that flips to **"Signal lost — reconnecting"** on `didDisconnect` and clears on reconnect. The event **already fires** — it just isn't published to the view.
- Optional staleness backstop: if no pod contact for N seconds, show "stale" even absent an explicit disconnect.
- The startup BT-off message.

**Mechanism:** cheap and event-driven. Surface the existing `didDisconnect` (`PodProofKit`) as a `@Published` state on the coordinator; render it in `WatchPodControlView`. No polling, no new BLE traffic.

## Phone — the *observer / fallback controller*

The phone is **blind to the pod during a loan** (it released the connection and can't see the watch's BLE). So its indicator is about **ownership** and **the honesty of what it can claim** — not a live pod state it doesn't have.

**What to add:**
- A **persistent pod-ownership status** on the pod tile: *Phone controlling* / *On Watch* / *Reclaimed — records pending*.
- **Honest degradation** for "On Watch": assert it only while WC contact is live; when the watch goes out of WC range, downgrade to *"Pod on loan — can't confirm the watch has it"* rather than continuing to assert a state it can no longer verify.
- **"Records pending"** after an escape-hatch reclaim — the watch's insulin isn't in IOB yet, so IOB may be understated. Pairs with the finding ① "hold dosing until reconcile" fix.
- **Surface `lastWatchLoanSummary`** (esp. the ⚠️ abnormal-hand-back marker), which today is **stored but never displayed** — nearly free.

**Mechanism:** ownership derives from existing loan flags (`podLoanedToWatch`, `dosingEnabledBeforeWatchLoan`); the summary is already stored; the honest-degradation needs the WC-contact/reachability state (already observed elsewhere in `WatchDataManager`).

## Sequencing

- **Cheap wins first:** 3a (watch `didDisconnect` → banner) and 3c (display the stored summary). Small, high-value, low visual risk.
- **Moderate:** 3b (phone ownership tile + honest degradation) — needs the WC-contact state wired into the tile.
- **Already done:** the takeover step-text (handoff-time visibility).

## The one design fork

**Does the watch relay its live pod-link state to the phone over WatchConnectivity**, so the phone can show a richer *"On Watch · connected"* vs *"On Watch · watch lost the pod"* (state 4)?
- **v1 (no relay):** the phone shows ownership from its *own* knowledge (loan active / not / reclaimed-pending) + honest degradation on WC loss. Simpler, no new message.
- **v2 (relay):** the watch periodically sends its link-state; the phone reflects it. Richer, but adds a WC message and a cadence to manage.
Recommendation: v1 first; add v2 only if the extra fidelity proves worth it.

## Related findings this ties into
- **① escape-hatch blind-dosing** — the phone's "records pending" indicator is the user-facing half of that fix.
- **B7 (BT off) / B1 (range)** — both are state 4 (silent link loss); the watch banner covers both.
- **Takeover reliability / limbo** — state 5; the step-text already surfaces a stalled takeover.
