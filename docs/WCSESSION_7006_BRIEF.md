# Loans fail to start: `WCErrorDomain 7006 "Watch app is not installed"`

Investigation brief, 2026-08-17. Written to be picked up cold. Everything below is either
quoted from logs or marked as inference.

## The headline, and what it is NOT

The phone's `WCSession` intermittently reports that the watch app is **not installed** — while
that same session is, in the same seconds, **receiving messages from that app**. Both cannot be
true. It is a system-level bookkeeping inconsistency in WatchConnectivity, not application logic.

**No pod has ever been lost.** Not once, across a full day of failures. Correcting an earlier
framing in this investigation: the word "orphaned" was used loosely and wrongly. What happens is
that the phone releases the pod's BLE link, the watch never takes over, and the pod continues
running its last program — a temp basal that expires on its own — with nobody connected. **Reclaim
from the phone has recovered it every single time, without exception.** The watch, for its part,
falls back to normal looping when a hand-back fails. Every layer degrades as designed.

So the severity is **obstructive, not dangerous**. Treat it as "loans sometimes will not start and
the user has to reclaim", not as a safety event.

## What the failure looks like

Watch side, every failure, identical:

```
17:39:34.107  [loan] REQUEST sent (build 1045) — awaiting grant
17:39:34.???  [wc]   send podLoanV2 — session 2, reachable true, path urgent
17:39:59.324  [loan] REQUEST TIMED OUT — no grant in 25s
```

Phone side, same moment:

```
17:39:34.205  [loan] e80 GRANT — releasing pod BLE (wasReleased=false)
17:39:37.499  [loan] e80 GRANT +3s — pod BLE released=true linkUp=false
17:39:56.452  [loan] e80 grant unconfirmed after 20s
```

The phone grants and releases the pod. The watch never receives anything.

And the cause, once instrumentation existed to see it:

```
18:25:37.984  [wc] transferUserInfo FAILED — Error Domain=WCErrorDomain Code=7006
              "Watch app is not installed."
```

14 occurrences over ~2 minutes and still going, while the phone logged `offer RX ev=0` — a
message that arrived *from* the allegedly absent app.

## Established facts

1. **Grants arrive in under 2 seconds, or never.** Across every log for the day there is no case
   of a late grant — not at 30s, not at 5 minutes. Successes: 0.6s, 1.7s, 0.6s. Failures produce
   no `RX grant` line, ever. **A longer timeout would not help.**
2. **`transferUserInfo` does not queue in this state — it fails outright with 7006.** This is why
   "guaranteed delivery" delivered nothing. It was rejected, not delayed.
3. **The failure was invisible before today.** `didFinish userInfoTransfer:error:` logged only to
   `os_log`, and its retry switch covers `LoopSettingsUserInfo` and `SupportedBolusVolumesUserInfo`
   only. Loan traffic gets no retry and left no trace.
4. **The loan send path is the only one that does not check `isWatchAppInstalled`.**
   `WatchDataManager` guards on it at four other sites (:555, :588, :611, :626) for stock's own
   transfers. The loan closure checks `isInteractiveHandshake` and `isReachable` only.
5. **It is bidirectional.** During one hand-back the *watch* logged `iPhone UNREACHABLE — offer
   queued` and resent every 15s for ~53 seconds while the phone was in use.
6. **It survives force-quitting both apps; reinstalling the watch app clears it.** Observed twice.
   Consistent with the state living below the app, in the OS's session bookkeeping.
7. **The code is exonerated.** A controlled test: rolled back to `e44ac193` (Caitlin's exact
   build) — loan succeeded. Reinstalled `production-merge` unchanged, byte-identical source to the
   build that had failed six times — loan succeeded in 8.7s. The 34-line delta between them
   (`b3300ee3` autobolus, `e9b82c37` carb matcher) is not the cause and neither touches transport.

## Inference, NOT established

- **That 7006 explains this morning's six failures.** It is consistent, but the
  `transferUserInfo FAILED` logging did not exist until build 1047. Its absence from earlier
  sessions proves nothing.
- **Two theories were advanced and withdrawn during this investigation. Do not re-run them.**
  - *Diagnostic traffic clogging the queue.* Diag rode `transferUserInfo` from 60 `handbackDiag`
    call sites, and bursts of 22-23 messages preceded two wedges. Plausible, and the change was
    made and kept (it is correct on its own merits — instrumentation should never share an ordered
    queue with a grant). But it did not stop the failures, and 7006 means the queue was never the
    mechanism.
  - *Reachability as a physical/foreground condition.* `isReachable` on iOS means the watch app is
    foreground; it says nothing about Bluetooth, WiFi or proximity. But it is also *downstream* of
    `isWatchAppInstalled` — an app iOS thinks is absent can never be reachable. Reasoning from
    `reachable 0` sampled minutes later, after the watch had idled, was simply the wrong reading.
    Jeremy's objection was correct: every loan begins with a tap on the watch, which is foreground
    by definition.

## Leading hypothesis, untested

**A one-off corruption of the companion registration, caused by the delete — NOT by direct
installs as such.**

An earlier version of this brief blamed `devicectl` installs generally. That is now contradicted:
the watch app was `devicectl`-installed at least five times on the evening of 2026-08-16, and those
builds field-tested fine. Direct installs are therefore not sufficient to cause this, and the
workflow they support is not implicated.

What is distinctive about 2026-08-17 is narrower:

1. The watch app was **DELETED** at ~11:25 — the first time — forced by an unrelated
   incompatibility (next-dev's extensionless watch app cannot be replaced in place by
   production-merge's extension-based one; `MIInstallerErrorDomain 153`).
2. Before that, the same bundle id was occupied by a **structurally different app** — next-dev's
   single SwiftUI target rather than an app+extension pair.

So the hypothesis is that the delete, and/or that period of a different app shape under one
identity, left iOS's companion registration inconsistent, and every direct install since has
INHERITED that state rather than caused it.

This predicts something testable and much less disruptive: **one clean repair fixes it
permanently**, after which routine direct installs are fine again. Supporting, but circumstantial:

- The watch app was **deleted and reinstalled via `devicectl`** at ~11:25 today (forced by an
  unrelated incompatibility: next-dev's extensionless watch app cannot be replaced in place by
  production-merge's extension-based one). Problems begin after this.
- Builds 289–291, field-tested successfully for weeks with loan start/end/reclaim reported as
  excellent, were **TestFlight** installs — i.e. the companion flow.

**If this holds, Caitlin cannot hit it**, because her build arrives by TestFlight, and this whole
day is a bench-rig artifact rather than a product defect. That is the single most consequential
open question, and it gates the ship decision.

## Instrumentation now in place (build 1048)

All diagnosis, no behaviour change:

- `sessionWatchStateDidChange` — **was not implemented**. iOS calls it exactly when `isPaired` /
  `isWatchAppInstalled` change, so the transition that breaks a loan was previously invisible.
- Every loan send records `path`, `bytes`, `reachable`, `installed`, `paired`, `activationState`.
- 7006 is named in the failure message rather than buried in a generic error.

## Discriminators, in order

1. **Does it clear by itself?** Watch `WATCH STATE CHANGED` for `installed` returning to true with
   no reinstall. Decides whether the remedy needs a recovery path or only prevention.
2. **Companion install vs `devicectl`.** Install the watch app from the phone's Watch app, then run
   loans for an hour. If `installed` stays true, hypothesis confirmed.
3. **TestFlight build.** Same question, through the path Caitlin actually uses.

## Fix direction (not built, deliberately)

**Prevention, not instruction.** Check whether the session can actually deliver before releasing
the pod; if it cannot, deny the grant and keep the pod. The loan simply does not start and the
user taps Start again — no bad state, nothing to explain.

**Explicitly rejected: telling the user to reinstall the app.** That is a last-resort diagnostic
note, never user-facing text. Ruled by Jeremy, 2026-08-17.

Note also that the existing recovery — reclaim from the phone — already works with a perfect
record, so no new user-facing recovery is needed. Only the prevention.

An earlier proposal to hold the pod until the watch acknowledges the grant is **superseded**: there
is no early ack in the protocol (the watch sends nothing on receipt; `takeoverComplete` comes only
*after* it has the pod, which it cannot get until the phone releases). Adding one is a two-sided
protocol change needing a capability flag. Checking a flag the OS already provides is far smaller
and addresses the same failure.
