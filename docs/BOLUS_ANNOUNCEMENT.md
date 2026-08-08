# How a bolus is announced — stock phone, stock watch, and ours

**Why this document exists (2026-08-08).** Jeremy: *"I want to work on the way the UI announces
the bolusing… what we're doing is fine but not great in my view."* Before changing anything, this
pins what stock actually does on each device, because the two are radically different and the
watch's austerity is a deliberate consequence of stock's architecture, not an oversight.

The one-sentence summary:

> **Stock's phone narrates the whole delivery and lets you stop it. Stock's watch says nothing at
> all after the crown ceremony — the only feedback is the IOB number the phone pushes back.
> Ours sits in between, and stops talking at the wrong moment.**

---

## Stock, phone: a narrated ring you can tap to stop

1. **The row appears.** When `bolusState` becomes `.inProgress(dose)`, `StatusTableViewController`
   creates a progress reporter — `pumpManager.createBolusProgressReporter(reportingOn: .main)` —
   and swaps the status row for a `BolusProgressTableViewCell`
   (`StatusTableViewController.swift:250-262`, `:1113`).
2. **What it shows.** A `RingProgressView`, the label **"Bolused 0.35 of 0.90 U"**
   (`BolusProgressTableViewCell.swift:104`; before any delivery is credited it reads
   "Bolusing 0.90 U", `:111`), a stop square, and a **"tap to stop"** label (`:19-31`).
3. **Tapping the row cancels.** `didSelectRowAt` → `case .bolusing:` flips the row to
   `.cancelingBolus` and calls `pumpManager.cancelBolus()`
   (`StatusTableViewController.swift:1273-1289`). On failure it restores `.bolusing` and presents
   the error — the UI never claims a cancel it didn't get.

### The progress number is a CLOCK ESTIMATE, not a measurement

This is the load-bearing fact, and it is easy to assume otherwise.

`PodDoseProgressEstimator.progress` (OmnipodKit `PodDoseProgressEstimator.swift:19-24`):

```swift
let elapsed = -dose.startDate.timeIntervalSinceNow
let duration = dose.endDate.timeIntervalSince(dose.startDate)
let percentComplete = min(elapsed / duration, 1)
let delivered = pumpManager?.roundToSupportedBolusVolume(units: percentComplete * dose.programmedUnits)
```

**The pod is never queried.** No radio, no status command, no confirmation that a single unit
actually went in. It is `elapsed / duration` against the dose's own start and end dates, rounded
to a deliverable volume.

What makes it *read* as measured is the tick cadence: `timerParameters()` returns
`Pod.pulseSize / Pod.bolusDeliveryRate` = `0.05 U ÷ 0.025 U/s` = **exactly 2 seconds**, phase-aligned
to the next pulse boundary (`delayUntilNextPulse`). So the number advances one real pod pulse —
0.05 U — every 2 s, i.e. **1.5 U/min**, which is the pod's true bolus rate
(`Pod.swift:15,22,25`). The estimate is honest about the *schedule*; it is silent about whether
the schedule is being met.

### Cancel, by contrast, is entirely real

`OmniPumpManager.cancelBolus` runs a session and issues
`session.cancelDelivery(deliveryType: .bolus)` — a genuine radio command, with the PDM-matching
`beeeeeep` when confirmation beeps are on. It returns the **actual** `canceledBolus`, and that
partial is what gets stored as the dose. So stock's cancel does not estimate anything: the books
end up with what the pod really delivered.

---

## Stock, watch: the crown ceremony, then silence

**Validated on-wrist by Jeremy 2026-08-08:** *"Bolus, crown ceremony, IOB updates immediately,
that's it. No further communication with user."* The code agrees exactly.

- `BolusConfirmationView` is a **pre-delivery** ceremony, not progress: "Turn Digital Crown to
  bolus", a filling visual, and `WKInterfaceDevice.play(.success)` the moment the crown completes
  (`BolusConfirmationView.swift:35-37`). The haptic fires on **confirmation**, before a single byte
  has left the watch.
- Then `sendSetBolusUserInfo` → `WCSession.sendBolusMessage` and the flow dismisses
  (`CarbAndBolusFlowViewModel.swift:543-545`).
- The phone replies immediately with an empty ack and enacts the bolus itself
  (`WatchDataManager.swift:661-665`); the new IOB reaches the wrist on the next pushed
  `WatchContext`, which the HUD renders event-driven off `didUpdateContextNotification`
  (`HUDInterfaceController.swift:28`). **That IOB step is the entire post-bolus feedback.**
- **There is no watch-side progress and no watch-side cancel.** Grepping the whole WatchApp
  Extension for `bolusProgress|DoseProgress|cancelBolus|isBolusing|bolusState` returns **zero
  hits**.

This is not an omission — it falls out of the architecture. In stock the watch never owns the
pump. It has no dose to time, no pump to cancel, and nothing to report that the phone isn't
already computing. The austerity is downstream of "the phone does the delivering".

**Which is exactly the assumption Sport Mode breaks.**

---

## Ours: we announce the wait, then stop talking when delivery starts

During a loan the watch *is* the pump, so the stock rationale no longer applies. What we
currently do:

- The glance's transient line shows **"reaching pod…"**, escalating after 20 s to **"still
  reaching pod — bolus will deliver"** (`GlanceController.swift:440-442`). This exists because a
  manual bolus spends most of its wall-clock re-acquiring the E4-orphaned pod, and three doses
  were lost to End taps during that silence.
- A failure buzzes `.failure` and raises a durable **"Bolus Not Delivered"** notification carrying
  the units and the reason (`CarbAndBolusFlowViewModel.swift:436-452`, logged since `573aca0c`).
- Success plays `.success` only when pod beeps are off, so the pod's own beep isn't doubled.

**The gap.** `manualBolusStartedAt` is cleared inside the `enactBolus` completion, and that
completion fires at **acceptance** — the pod acknowledging the command — not at the end of
delivery (`WatchLoopManager.swift:2316`, `:2332`). Field measurement 2026-08-08: enact at
16:24:42.782, "MANUAL BOLUS delivering" at 16:24:43.973 — **1.2 s**. The 0.90 U then takes about
36 s to physically go in.

So our transient covers the *reconnect*, and goes quiet at precisely the moment stock's phone
would **start** narrating. The entire real delivery window is unannounced.

---

## The comparison, in one table

| | Stock phone | Stock watch | Ours (during a loan) |
|---|---|---|---|
| Pre-delivery | Bolus screen, Deliver button | Crown ceremony + success haptic | Crown ceremony + success haptic (stock, unmodified) |
| During the radio wait | n/a (pump is local) | n/a | "reaching pod…" → "still reaching pod" at 20 s |
| During delivery | Ring + "Bolused X of Y U", ticking 0.05 U / 2 s | **nothing** | **nothing** |
| Cancel mid-bolus | Yes — tap to stop, real radio command, real partial stored | **no** | **no** |
| On failure | Error presented | Error presented | `.failure` haptic + durable "Bolus Not Delivered" notification with units and reason |
| Post-delivery | Row clears; IOB updates | IOB updates from the phone's pushed context | IOB updates from the watch's own ledger |

## What replication would cost, if we want it

**Progress is nearly free.** We already book the dose as
`startDate: acceptedAt, endDate: acceptedAt + rounded / 1.5 * 60` (`WatchLoopManager.swift:2320`),
and **1.5 U/min is exactly `Pod.bolusDeliveryRate`** — the same rate stock's estimator assumes. So
we already hold the two dates stock computes from. A stock-shaped progress display needs no radio,
no pod interaction, and no new plumbing: it is `elapsed / duration` on a dose we have, rendered in
a `TimelineView` exactly like the takeover bar (`GlanceController.swift:1001`). Note this inherits
stock's honesty limit — it would be an estimate, and should not be worded as confirmed delivery.

**Cancel is the hard one, and is a separate decision.** It is a real radio command, and during a
loan it would land in the middle of the E4 dance: `e4ReleasePodAfterDose?()` fires in the *same*
completion that accepts the bolus (`WatchLoopManager.swift:2314`), so by the time a user could tap
Cancel the pod is being released. A cancel would have to reclaim the pod, issue the cancel, and
book the real partial into the loan journal. Decide it independently of progress.

*Verified against source 2026-08-08 (phone Loop 3.14.3 fork, OmnipodKit fork, watch port at
573aca0c), and against Jeremy's on-wrist validation of the stock watch the same day. Line numbers
drift; the type names and the "estimate, not measurement" contract are the stable anchors.*
