# Pod ownership

*Draft 2026-09-18, framework and recommendation added 2026-09-19. A thinking document: the
frame the loan code is measured against, and the alternatives it is measured beside. Not a
spec of the code as built. The first section is the conclusion; the rest is the working.*

## The framework, and the recommendation (2026-09-19)

Three designs are on the table. **Explicit loan** (built): each device stores a belief about
who owns the pod, and messages move it. **Free-for-all**: no ownership; both devices dose,
first to reach the pod on a reading wins. **Pod decides**: ownership is re-derived every
cycle from evidence, chiefly from the pod itself; the phone is preferred; beliefs expire.

### Eight facts any design has to live with

1. **The pod obeys anyone who holds its keys, one connection at a time, and it does not
   refuse a conflicting insulin command — it faults and dies.** (2026-09-19: a temp basal set
   over a running one, fault 0x31, pod lost.)
2. **To dose, a device must reach the pod.** A check made on the pod connection therefore
   cannot be bypassed by a lost message. A check made over the phone–watch link can.
3. **The pod reports how much, never when.** Total delivered, what is running now, and —
   through its session counter — that another controller has connected (reliability not yet
   characterised: 11 of 15 watch-side resyncs logged a zero delta, and the phone does not log
   it at all). Never carbs.
4. **Neither device holds the pod link between doses** on this line (upstream's
   connect-on-demand, OmnipodKit a715d9a). The pod is free between sessions, so either device
   can take a session at any time. Exclusion is per session, a few seconds, and no longer.
5. **The phone–watch link is the least reliable part.** A third of a second for 19 KB when
   it is up. But the phone cannot wake the watch on demand, while the watch can always wake
   the phone; and a queued message can land an hour late (2026-09-18: 65 minutes).
6. **Four books feed a dose.** *Glucose*: each device reads the sensor itself — already
   shared. *Insulin*: the timing lives only in the device that commanded it; the amount is
   also on the pod. *Carbs*: only where they were typed, and they are edited and deleted.
   *Settings*: change rarely.
7. **The errors are not symmetric.** A missing insulin record over-doses; the pod's total
   closes that hole in amount, with no link at all. A missing carb entry under-doses — the
   slow direction. A carb *deletion* that did not cross over-doses, and nothing backs it up.
8. **Temps forgive, boluses do not.** A later temp replaces an earlier one and is bounded by
   max basal for minutes; two boluses are a double dose. Every error is bounded in time:
   insulin six hours, carbs seven and a half.

**The pod's total is a backstop, not a sync.** A controller reads it every cycle, so while a
device is the controller its insulin book is checked every five minutes and the timing
uncertainty is one cycle — negligible. A device *resuming* control after a gap gets the
amount exactly and the timing only to within the gap. For a short gap that is fine. For a
long one (two hours away on the watch alone) it is a stand-in until the other device's
records arrive, and it must err the cautious way: unexplained insulin is booked as delivered
*now*, the latest it could have been, which overstates insulin on board and under-doses.

### The questions, and how each design answers them

| | Explicit loan (built) | Free-for-all | Pod decides |
|---|---|---|---|
| **Who may command, and how does each device know?** | A stored belief per device, changed only by messages: grant, hand-back, reclaim, seize. | Both, always. | Re-derived every cycle: can I reach the pod, and is the other device acting (told over the link, or visible on the pod)? Phone preferred; an optional hold prefers the watch. Beliefs about the other device expire. |
| **When the two disagree** | Both think yes: two controllers, undetected while the watch is reachable (09-18, three hours). Both think no: nobody doses until the user notices (09-08, four hours). **No built-in time bound.** | They always disagree; harmless only while the books agree. | The preferred device carries on; the other sees it and yields. About one cycle of overlapping temps at worst; nobody-doses is bounded by the expiry constants. |
| **Who writes the books?** | One writer at a time, by construction. | Two writers, every cycle. | One writer at a time in practice: the phone at home (the watch forwards entries, as stock does); the watch when away. Two writers only for an entry made on the idle device while the link is down. |
| **The books with the link down** | Frozen at the last boundary message; pod-total audit at reclaim. | Decisions alternate between two diverging books. | The controller's book is the truth. A device resuming control checks the pod's total against its own records first and books any surplus as delivered now, until the records arrive. Uncovered: a carb deletion made within one sync interval of a long outage. |
| **How control moves** | Four handshakes, each with a half-done state and its own recovery (ladder, revoke, force reclaim, seize, mirror). | It does not move; it alternates. | No handshake. One device starts, the other notices. A switch is: read status, cancel the running temp, set a new one. |
| **Switches per day** | Two (Start, End). | Up to 288. | A handful — the phone leaving and re-entering pod range, with a cycle of hysteresis. |
| **Watch radio and battery** | Pod sessions only during a loan. | A pod session every cycle, even with the phone beside it — contending with the sensor for nothing. | Pod sessions only while the phone is not dosing. |
| **What the user must do** | Remember Start and End. End can fail. | Nothing. | Nothing by default; Start becomes "hold it on the watch". Needs a plain who-is-dosing indicator on both. |
| **Distance from stock; size** | Stock plus about 9,000 lines of loan protocol, comments included (phone controller 4,700, watch controller 3,200, shared messages 1,200), much of it written for one field episode each. | Stock, twice, on one pump. | Stock on the phone; the stock remote on the watch; a fallback controller and a book sync. Mostly subtraction from what is built. |
| **Rulings touched** | — | R40(b), R40(f) | R40(b) automatic entry and R40(f) automatic return — either can stay manual at first. |

### One failure at a time

| Failure | Explicit loan | Pod decides |
|---|---|---|
| A link message is lost or an hour late | At a boundary: ownership splits (two controllers) or stalls (none). | Only the books go stale. Ownership is unaffected. |
| A device dies mid-transfer | A half-done handshake; recovery by ladder; a dead watch mid-loan waits for the user. | There is no mid-transfer. The survivor resumes when the other's activity stops: a fixed number of cycles. |
| A stale stored belief | 09-13 two-hour yield lockout; 09-19 inferred loan and the phantom 3.45 U. | Cannot outlive its expiry. |
| Both in pod range, link down | Undetected if the beliefs differ. | The pod shows each the other; the non-preferred yields. |
| The dosing device dies before its records cross | Pod-total backstop at reclaim. | Same backstop. |
| A carb edit does not cross | Snapshot at the grant; edits during a loan cross watch→phone only. | One sync interval of exposure. |
| Commands from both inside one cycle | Prevented by belief alone; the pod faulted on 09-19 when belief was stale. | Sessions cannot overlap; every session reads first; no automatic bolus in a cycle that shows the other device's insulin unexplained. |

### Recommendation

**Free-for-all is out.** Everything it offers, "pod decides" offers too. Having no preference
rule buys nothing and costs a switch every cycle — and every risk in this document lives at
a switch: the fault, the truncated temp record, the double bolus, the sensor contention.

**Between the other two, the deciding criterion is whether a failure is bounded by a
constant or by a person.** In the explicit loan the dangerous states — two controllers, no
controller, a stale yield — end when someone notices. In "pod decides" each ends by itself,
because arbitration rides on the one connection a device must have to do any harm (fact 2),
and because beliefs expire. That is the same principle as *time bounds every dosing error*,
applied to ownership.

**The two are closer than they look.** Give the explicit loan a pod check before every dose
and beliefs that expire, and the only remaining difference is a policy switch: does the
watch start by itself when the phone stops dosing? So: **build the "pod decides" mechanism by
subtraction from the loan, and keep today's policy — Start is a tap; the phone takes the pod
back when it can see it and no hold is fresh — until the bench says otherwise.** Automatic
entry is then a ruling, not a rewrite.

The mechanism is five rules:

1. **Pod first.** Every dose begins with a status read. A device that has not commanded the
   pod within the last cycle treats what it remembers about it as unknown (built 09-19,
   OmnipodKit a893b8c) and checks the pod's total against its own records *since its own
   last read* (exists as the reclaim audit; its anchor is wrong — the 09-19 phantom 3.45 U).
2. **One decision per reading.** On evidence that the other device is acting, the
   non-preferred device skips the cycle. No automatic bolus in a cycle that shows the other
   device's insulin unexplained; temps only, because temps forgive.
3. **One writer, one copy.** The controller's book is the book; the other device pulls it
   every cycle. Entries typed on the idle device are forwarded (stock) or, with the link
   down, merged later by identity, deletions carried as tombstones (the journal has them).
4. **The watch starts every exchange** (fact 5). On each sensor wake it sends what it sees
   and its records, and gets the phone's back: one round trip, then carry on without an
   answer after about three seconds.
5. **Every belief about the other device expires.** A hold is renewed each cycle the watch
   actually doses, and lapses in about fifteen minutes. The phone never yields without a
   fresh one. The watch yields to any evidence of the phone.

**Unproven, in the order to test it:**

- *Fault-free alternation with the status read first.* Bench, water pod, one hour, control
  swapped every cycle, no hand-back protocol at all. Pass: the pod survives and both books
  equal the pod's total.
- *The pod's session counter as a witness.* Log both counters on both devices during that
  hour. The design has to work from the pod's total and the link alone if it proves noisy.
- *Switch cost.* Watch takeover: 5.6 s best, 88 s on 09-19. Phone reclaim: 2–4 s typical,
  184 s on 09-19. And the watch's sensor read rate while alternating.
- *Two-way carb merge with deletions.*

**What would change this recommendation.** Faults or unreliable totals in the first two
tests: keep the explicit loan and add only the expiries and a watch-silence watchdog.
Switches that routinely take tens of seconds and cost sensor reads: entry stays manual.

## The invariant

**The pod has exactly one controller at a time.** Stock enforces it for free: there is one
phone. Everything below is what it costs to keep the invariant with two candidates.

Three questions, and only three:

1. **Who holds it?** One persisted belief per device — the phone's `owner`/`loaned`, the
   watch's `phase`. A relaunch reloads it (R40(e)); it is never inferred.
2. **How does it move?** Four transfers, all built: **grant** (phone → watch, on request),
   **hand-back** (watch → phone, records first, then the pod; urgent-only and never queued, R41 — which removes late delivery but cannot detect presence), **reclaim** (phone takes it
   back, forced if the watch is silent), **seize** (watch takes it with the phone out of
   reach, from the dormant grant — R40(b)). Resume is not a transfer: the holder never changed.
3. **What when the two beliefs disagree?** Count the devices *in pod range* — a recent pod
   round-trip, which each device knows about itself. **Zero:** nobody doses; the pod runs
   its schedule, stock's own failure mode. **One:** that device commands, whichever it is;
   no conflict is possible. **Two:** the only cell that needs a rule, and the rule is a
   *default*, not a law (R40(a) as amended 2026-09-18): **prefer the watch, because it is
   usually on the body — unless it knows it is not.** A watch on the charger is off the
   body by definition and yields; the phone cannot know where it is, so it never claims.
   The watch-wins default is what the mirror implements today; the self-disqualification is
   new and cheap.

**Absence is not conflict.** A watch that goes silent mid-loan is nobody on the body's side
answering. Today the phone waits for the user (field 2026-09-08: 4 h 06 m). Deliberately
unhandled in the first draft — see deferred risk 2 under R40(e) in RULINGS.md.

**What is not the rule.** The reclaim ladder (948 lines) and the mirror (390) carry patches
from specific field episodes: revokes re-aimed at a newer epoch, ghost grants abandoned, a
20 s probe, a 5-minute dead-man, a settle window. Each fixed a real race in a transfer
handshake. Each is a special case. Step 2 below tags every one as an instance of the rule,
a handshake race fix, or neither. Nothing is deleted by this document.

## What the pod knows

Everything below depends on this, so it is stated once. Querying the pod yields: the
**odometer** (total pulses delivered), whether a temp or bolus is running *now*, the pulses
of an in-progress bolus not yet delivered, the reservoir, and the pod's time since
activation. A raw log of the last 60 pulses exists; the kit dumps its bits undecoded and no
timing field in it has been published. **The pod says how much, never when.** The timing
of every dose lives only in the device that commanded it.

So a bolus and a temp are the same thing — pulses at a rate from a moment — and *both*
halves of the insulin book are link-dependent, exactly as carbs are. The odometer adds a
fallback the carbs do not have: amount exact, timing bounded to the contact interval. A
bound, not a sync.

## The scenario grid

Two devices, A and B. Each is in range or out, alive or dead; the transitions matter more
than the cells.

1. **Both in pod range** — walking around the house, phone on the charger; or the *watch*
   on the charger with the phone in a pocket, which is the case "watch always wins" got
   wrong. In single-owner this is trivial: one device commands, the other watches. In shared control
   it is *the hardest case*: both may command, and correctness rests entirely on the link
   carrying every dose and carb, fast. Everything the paradigm saves in transfer machinery
   it spends here.
2. **Out of range** — leaving the house without the phone. Either paradigm collapses to
   current Sport Mode: one device holds the pod, the other is absent, and the holder's book
   is the truth until they meet again.
3. **A device dies** — most often the watch away from the phone. Recovery away from the
   phone is R40(e), built. Recovery when the phone comes back first is the reclaim.
   **The known risk today, in both paradigms:** a bolus on the device that then dies, before
   its record reached the other. The other takes over short by that bolus. The odometer
   catches the amount at first contact and bounds the timing to the gap; nothing recovers
   the moment. This is a sync-cadence problem — how soon after a dose its record crosses
   the link — and sharing neither fixes nor worsens it.

Out of range and dead-device collapse to what exists. The paradigms differ only in cell 1 —
and cell 1 is where the *two-in-range* rule above lives.

## The alternative: shared control

Keep the invariant by making ownership an *artefact* rather than a *belief*: both devices
run stock Loop, both may command the pod, **whoever reaches the pod first on a reading
wins, the other skips the cycle.** No grant handshake, hand-back, reclaim, seize, epoch,
ladder, mirror or dead-man.

It works because **Loop is stateless** and **there is no forward credit for a running temp**
on this line: two devices computing at different moments on the same reading are a faster
cadence of what stock does every five minutes — the later decision replaces the earlier.
Divergent *timing* is harmless; only divergent *inputs* are dangerous, and that is cell 1.

**Does the grant buy anything?** Most of it is already the sync: the dormant grant,
re-issued on every checkpoint and settings change, is a continuous state transfer, and
shared control needs exactly that. What the grant adds is the *handshake* — takeover ladder,
confirmation, dead-man — and that is what sharing removes.

Building blocks:

- **The link is the book.** Every dose and carb crosses it as it happens; the dormant-grant
  refresh pipe already carries records both ways. Its cadence is the safety parameter in
  both paradigms; in shared control it is load-bearing.
- **"Link active" selects the regime.** Active: the book is synced. Not: the pod's odometer
  bounds insulin, carbs go unsynced in the safe direction (under-dosing). Measured as *a
  round trip completed recently*, never the reachability flag (R40(b)). Cellular slots in.
- **The odometer at every contact** books the delta over the gap (the reclaim audit's own
  primitive) — the bounded fallback, in both paradigms.
- **Boluses**: not idempotent, so two devices must not both send one on a reading. A known
  risk in the dead-device family, not a deal-breaker at this phase (ruled 2026-09-18).
- **The pod link is exclusive**: every swap costs a session resync. Cost per swap and effect
  on the watch's sensor radio: unmeasured.

**What it costs a reviewer.** Single-owner is "stock plus a transfer protocol". Shared control is
"stock, twice, sharing a pump" — a pump-layer concept no shipping system has.

## The third model: pod-visibility ownership

Proposed 2026-09-18, and the one that looks buildable. **Ownership is decided by who can
see the pod, once per cycle.** Each device knows whether it reached the pod recently; the
link tells it whether the other did.

- **One device sees the pod:** it owns it. Whichever it is. No conflict is possible.
- **Two see it:** the **phone** owns it. It is stock's controller, and while it holds the
  pod the watch is *exactly the stock watch app* — a remote that forwards carbs and boluses
  over the link. Cell 1 is stock. The watch becomes a controller only when the phone cannot
  reach the pod: today's Sport Mode entry, made automatic.
- **Decided once per cycle:** get BG, run the loop, check ownership, dose. Flapping is
  bounded to one switch per cycle by construction; one cycle of hysteresis on the phone's
  side stops a walk past the phone from taking the pod for a single dose. A switch is cheap
  — no ladder, no confirmation, no dead-man; the new owner's status read and command.
- **User-initiated commands check ownership first** and forward on the non-owner, as stock
  does. If the forward cannot be delivered, refuse and say so; Start is the escape. The
  watch does not grab the pod for one command.

What it removes: the grant handshake, hand-back as a transfer, the reclaim ladder, seize
as a separate flow, revoke, the reunion prompt. What stays is what every model needs: the
continuous sync of pairing, settings and records (the dormant-grant pipe), pod-visibility
tracking (largely present), the odometer reconciliation at each switch (the audit).

Honest items: (1) the other device's visibility arrives over the link; when the link is
down and both see the pod, both may claim, the pod's exclusive link arbitrates that cycle,
and a duplicated temp is harmless — the stale-information constant ("treat the phone as
absent after N cycles unheard") is the one to get right. (2) It reverses R40(f) (return
becomes automatic: the phone wins when it sees the pod) and R40(b) (entry becomes
automatic) — both to be re-ruled explicitly. (3) The dead-device bolus risk is unchanged.

## How hard is the sync? (measured 2026-09-18)

Sync is needed on a change of state: once per cycle plus user actions. Today's link, from
the logs:

| Message | Size | Path | Observed latency |
|---|---|---|---|
| Grant, phone → watch | ~19 KB (71–94 dose seeds ≈ 15 KB, pod state 2.9 KB, settings 0.4 KB) | urgent | 0.25–0.3 s to arrive |
| Dormant-grant refresh | ~26 KB, 22 times today | queued | deferred when unreachable |
| Hand-back offer, watch → phone | small | urgent | 54 ms to arrive; ack back in ~310 ms round trip |
| Checkpoint, watch → phone | small, 20 today | urgent | phone processes in 50–75 ms |
| Failures | 2 urgent sends timed out today; both fell back to the queued path | | |

So the link is fast when up — a third of a second for 19 KB — and the expensive part is
that every refresh re-sends the whole dose history. Under continuous sync the per-cycle
payload is the new dose record, the pod state (2.9 KB, changes per command — the other
device needs it to take over without discovery), the odometer and the ownership flags:
about 3 KB and one round trip. Not hard. What is unmeasured is the queued path's delay
across a reachability flap, which is the number that bounds the dead-device risk.

**Sync design (ruled 2026-09-18): full book, not deltas.** Latency only matters at a switch,
and the cycle absorbs a second: the receiver's ownership check runs after the sync lands.
Bandwidth is not the argument; simplicity is. A full-book sync is *stateless* — no cursors,
no acks, no gap tracking; a missed message costs nothing because the next book repairs it
— which retires today's checkpoint/cursor machinery. Carbs are edited, deleted and
back-dated, insulin mostly appends (a replaced temp and a resolved uncertain command are
the exceptions); one merge rule covers both: **identity, latest edit wins** (a UUID for
carbs, the pod's raw bytes for doses — both exist, so the merge is idempotent). Window:
the dosing horizon (6 h insulin, the carb absorption tail), ~100 records, 15–20 KB. In one
sentence: *each device sends its last eight hours once a cycle and on any user action; the
receiver merges by identity; nothing is acknowledged.* The dormant-grant refresh already
does this phone → watch; the missing half is the watch's book back, in the same shape,
replacing the journal drain.

*Implementation note:* the message carries three books — insulin, carbs, settings — each
with its hash. The receiver skips the merge for any book whose hash it already holds
(settings change rarely, carbs a few times a day, insulin every cycle), and logs one line
per receipt: "insulin changed, carbs same, settings same". No hash pre-check round trip,
and never "send only the changed books": both reintroduce state, and a lost message would
then need a repair. Three hashes, three full books, every time.

## Scoring

Superseded by the framework at the top of this page (2026-09-19).

## Next steps

1. The owner's read of this page.
2. **Measure the queued path** across a reachability flap: how long a record waits when the
   urgent send fails. The urgent path is measured above; this is the number that bounds
   the dead-device risk in every model.
3. **Audit** the phone controller against the single-owner rule: tag every conflict path
   (rule / race fix / neither) with the field episode that created it. Output: candidates.
4. Decide what to prune — after the resume bench work settles which races can still occur.
5. The two shared-control measurements, if the alternative is still live after 1–4.
