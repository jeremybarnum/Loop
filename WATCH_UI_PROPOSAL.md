# Watch UI cleanup — proposal + what's done

Branch `watch-ui` (off `vendor-podsdk`). Covers the three UI asks: pod button, bolus, declutter.

---

## 1. Pod button — replace the Pre-Meal button (IMPLEMENTED on this branch; needs build-verify)

The 2×2 grid was **Pre-Meal · Override · Carbs · Bolus**, with an ugly full-width **"Pod"
text button** tacked on below. You said Pre-Meal is the unused one — so I turned the
**Pre-Meal** button into the **Pod** button and deleted the text button. Result:
**Pod · Override · Carbs · Bolus**.

**What I changed (on `watch-ui`):**
- `WatchApp/Base.lproj/Interface.storyboard` — Pre-Meal button (`jY0-1m-ful`): action
  `togglePreMealMode` → `openPodControl`; label "Pre-Meal" → "Pod". Deleted the full-width
  Pod text button (`8PN-3k-XqF`). XML re-validated (tags balanced).
- `WatchApp Extension/Controllers/ActionHUDController.swift` — set the button icon in
  `willActivate()` and force `preMealButtonGroup.state = .off`; removed the pre-meal
  enable/disable logic from `update()` so the Pod button is always enabled and no longer
  reflects pre-meal state. (`togglePreMealMode`/`setPreMealEnabled`/`updateForPreMeal` are
  now dead but left in place — harmless, minimal churn.)

**Two things for you in Xcode (I couldn't build-verify either):**
1. **Build-check** — confirm it compiles and the Pod button opens the pod screen (the risk
   is the repurposed-button logic).
2. **Real icon** — I used the SF Symbol `bandage.fill` as a placeholder (set in code). To use
   the *actual* Omnipod artwork ("the pod icon from the phone"): drag OmniBLE's
   `Pod.imageset` (`OmniBLE/.../OmniBLEUI.xcassets/Pod.imageset`, the `pod1x/2x/3x.png`) into
   the WatchApp asset catalog as `Pod`, then either set the storyboard imageView image to
   `Pod` or change the code line to `preMealButtonImage.setImage(UIImage(named: "Pod"))`.
   (`bandage.fill` needs watchOS 9+; if your target is lower it'll render blank — the real
   asset fixes that regardless.)

*(Assumption to confirm: by "temp target button" you mean the **Override** button — the
one labeled Preset/Workout. If you meant **Pre-Meal**, same recipe, different button.)*

---

## 2. Bolus from the watch — the un-idiomatic part

**The hard constraint (important):** Loop's normal watch bolus (the main Bolus button →
`CarbAndBolusFlow`) sends the dose to the **phone**, and the phone's pump manager delivers
it. **During a loan the phone doesn't have the pod — the watch does.** So we cannot simply
reuse Loop's main bolus flow; a loan bolus must go **watch → pod directly** via
`PodProofController` (which is exactly what `coordinator.bolus()` does today).

So "wire it back to the main screen bolus button" is appealing but not free: that button
would need to detect "loan active" and route to the coordinator instead of to the phone.

**Options, least → most work:**

| | UX | Delivery path | Safety | Effort |
|---|---|---|---|---|
| **A. Keep fixed 0.5 U** (current) | two-tap confirm | watch→pod ✓ | fixed, very safe | none |
| **B. Crown-dial, capped** *(recommended)* | turn the Digital Crown to pick 0.05–2.0 U, then confirm — the watchOS-idiomatic way | watch→pod ✓ | bounded by a hard cap | small, self-contained |
| **C. Reuse `CarbAndBolusFlow` UI**, reroute delivery to the coordinator when a loan is active | identical to the normal watch bolus | watch→pod ✓ | inherits Loop's guardrails | larger; touches Loop's bolus flow |

**Recommendation: B now, C eventually.** B replaces the fixed 0.5 U with a crown-dialed,
hard-capped amount right on the pod-control screen — idiomatic and still safe (no free-form
unbounded dosing; keep the current cap philosophy). It stays self-contained, no changes to
Loop's main flow. C is the "one bolus button, context-aware" endgame — nicer but a real
integration into `CarbAndBolusFlow`, worth doing once B proves the direct-delivery UX.

(The current fixed 0.5 U was a deliberate safety choice — "no arbitrary dosing from the
watch." B preserves that intent with a cap; don't remove the bound.)

---

## 3. Declutter — DONE (conservative), plus ideas

**Done on this branch:** removed the inline running loan-journal (`liveSummary`) from the
**active** pod-control screen. It was the verbose "what the watch has done" logging you
flagged. No data lost — it still appears on the **hand-back / done** summary screen, which
is where a recap belongs. The active screen is now: status card → Suspend/Resume → Bolus →
Hand back.

**Further ideas (not done — your call):**
- Lead the status card with the **one number that matters** (delivered U this loan, or IOB)
  in `.title2`, with reservoir + delivery state as small secondary lines.
- Group Suspend/Resume as a single segmented control (they're mutually exclusive states).
- Move any remaining diagnostic text behind a force-press "Details" or a second page, keeping
  the first screen to: big number + 3 actions.
- Fix the "priming" wording only if we ever change the status source (see BUG-2, won't-fix).

---

## Build note
`watch-ui` is off `vendor-podsdk` (which vendors PodSDK in). Build-verify `vendor-podsdk`
first (does the PodSDK package resolve from its new in-repo path?), then this. The only code
change on `watch-ui` so far is the SwiftUI declutter above — low risk, easily reverted.
