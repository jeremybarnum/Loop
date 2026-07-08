# Watch UI cleanup — proposal + what's done

Branch `watch-ui` (off `vendor-podsdk`). Covers the three UI asks: pod button, bolus, declutter.

---

## 1. Pod button — replace the "Override" icon with a Pod icon (SPEC — apply in Xcode)

**Current layout** (`WatchApp/Base.lproj/Interface.storyboard`, Action HUD scene):
a 2×2 icon grid — **Pre-Meal · Override · Carbs · Bolus** — and then an **ugly full-width
"Pod" text button** tacked on below the grid (button id `8PN-3k-XqF`, line ~151). That's
the ugliness.

**Proposed:** turn the **Override** icon button into the **Pod** button, and delete the
full-width text button. Result: a clean grid — **Pre-Meal · Pod · Carbs · Bolus**.

I did NOT hand-edit the storyboard (a wrong action connection = crash on tap, and I can't
build-verify it here). Do it in Xcode's Interface Builder where you get visual + build
feedback — it's ~5 minutes:

**Storyboard (Override button, id `dYe-c2-Sfm`, label "Override"):**
1. Change its `imageView` image from `workout` to a pod glyph (see *Icon* below).
2. Change the action connection from `toggleOverride` → `openPodControl` (that IBAction
   already exists on `HUDInterfaceController` and is what the old text button used).
3. Change the label text "Override" → "Pod".
4. Optionally retint: `tintColor`/`backgroundColor` from `workout`/`workout-dark` to
   `insulin`/`insulin-dark` (or a neutral) so it reads as a device control, not a target.
5. **Delete** the full-width "Pod" button (`8PN-3k-XqF`, the `<button width="136" title="Pod">`).

**Controller (`ActionHUDController.swift`):** the Override button is state-managed in
`update()` (disabled when `!canEnableOverride`). Once it's the Pod button that must NOT
inherit that:
- Remove the `overrideButtonGroup.state = .disabled/.off` lines in `update()` for this button
  (Pod is always available while there's a pod).
- Simplest: leave the `overrideButton` IBOutlet wired but stop touching its group state; or
  rename the outlet to `podButton` and drop `overrideButtonGroup`, `toggleOverride`,
  `sendOverride`, `updateForOverrideContext`, and the `OverrideSelectionControllerDelegate`
  conformance (they're now dead for the grid — keep only if used elsewhere).

**Icon:** there's no clean SF Symbol that reads as "Omnipod." Two options:
- **(a) Reuse the phone's pod glyph** — add the OmniBLE pod image asset to the WatchApp
  asset catalog and reference it (matches "the pod icon from the phone" literally).
- **(b) SF Symbol placeholder** — e.g. `bandage.fill` or `cross.vial.fill`, tinted insulin.
  Fastest; swap for the real asset later.

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
