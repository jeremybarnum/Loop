//
//  DiabetifyTransform.swift
//  Loop / WatchApp Extension (compiled into BOTH targets — Common/Models)
//
//  *** DIABETIFY *** BENCH-ONLY test transform (Jeremy's spec, 2026-07-29).
//  REMOVE (or verify flag-off) BEFORE PRODUCTION — grep "DIABETIFY" / "diabetify".
//
//  WHY THIS EXISTS: the bench tester is NOT diabetic, so real G7 readings sit in
//  narrow euglycemia (~75-135 mg/dL) and the loop never sees diabetic dynamics.
//  Diabetify remaps every REAL G7 reading — acquired over the REAL radio path, with
//  genuine timing, gaps, and backfill — into a diabetic-looking series before it
//  enters the glucose store:
//
//      y = 3.0 * (x - 80) + 115, clamped to [40, 400] mg/dL
//
//  A normal day (75-135) becomes a diabetic-looking day (100-280); real deltas are
//  amplified 3x (Δy = 3Δx away from the clamps), so euglycemic wobble reads as
//  diabetic excursions. The pod on the bench rig is filled with WATER and not worn,
//  so dosing against the transformed series is inert by construction.
//
//  DESIGN — a STATELESS POINTWISE map, deliberately NOT a stateful delta chain:
//  every reading transforms independently of history, so sensor gaps, backfill
//  batches, watch/phone restarts, and store wipes can never desynchronize the
//  series or double-apply a delta. Applying twice IS wrong (3x becomes 9x) — which
//  is why the transform runs ONLY at the two SOURCE adapters where G7SensorKit
//  readings first become NewGlucoseSamples (watch: WatchLoopManager.processCGMReadingResult;
//  phone: DeviceDataManager.processCGMReadingResult) and NEVER at relay points
//  (WatchContext phone-BG fallback, loan-grant glucose seeding, historical-glucose
//  backfill all carry values that were already transformed at the phone's source).
//
//  RINGFENCE: flag defaults FALSE ("g7.diabetify" in UserDefaults.standard, set
//  per device — phone and watch each need their own); every transformed reading
//  logs "[diabetify] raw=X → Y" (SportLog on the watch, DeviceDataManager's log on
//  the phone); and while active the watch glance and the phone CGM HUD both show a
//  persistent "Δ⚠︎ DIABETIFY" badge. Unlike FakeGlucose this flag deliberately
//  SURVIVES restarts (no session-start clear, no self-expiry): the map is
//  restart-proof by construction, and a multi-day bench wear must not silently
//  revert to real values after a reboot — the badge is the guard instead.
//

import Foundation
import HealthKit
import LoopKit

struct DiabetifyTransform {

    /// UserDefaults flag, default FALSE. Set per device (phone and watch separately),
    /// same convention as the other bench flags (g7.e5RandomTemp, g7.fakeBG).
    static let defaultsKey = "g7.diabetify"

    static var isActive: Bool {
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    // Affine map parameters + clamp bounds (mg/dL).
    static let slope: Double = 3.0
    static let rawAnchor: Double = 80
    static let mappedAnchor: Double = 115
    static let floor: Double = 40
    static let ceiling: Double = 400

    /// The pointwise map: y = 3.0*(x - 80) + 115, clamped to [40, 400] mg/dL.
    /// Stateless — no history, no deltas — so it is gap/backfill/restart-proof.
    static func apply(_ mgdl: Double) -> Double {
        return min(max(slope * (mgdl - rawAnchor) + mappedAnchor, floor), ceiling)
    }

    /// Rewrite a batch of real samples with transformed values, preserving dates and
    /// sync identifiers so store semantics (dedup, ordering, recency) are untouched —
    /// the FakeGlucose.substitute pattern. trendRate scales by the map's derivative
    /// (3x) so the displayed rate matches the transformed series' slope away from the
    /// clamps; the coarse trend-arrow bucket is left as reported (display-only, and a
    /// positive-slope affine map preserves direction). `condition` is preserved
    /// as-reported (it describes the SENSOR's range state, not the transformed value).
    /// UNCONDITIONAL — the caller gates on `isActive` (the flag-off path is the
    /// caller's untouched original values, a true identity passthrough).
    /// `log` receives one "raw=X → Y" line per reading; the call site routes it
    /// (SportLog on the watch, the device log on the phone).
    static func substitute(_ samples: [NewGlucoseSample], log: (String) -> Void) -> [NewGlucoseSample] {
        let mgdl = HKUnit.milligramsPerDeciliter
        let mgdlPerMin = mgdl.unitDivided(by: .minute())
        return samples.map { sample in
            let raw = sample.quantity.doubleValue(for: mgdl)
            let mapped = apply(raw)
            log(String(format: "raw=%.0f → %.0f", raw, mapped))
            return NewGlucoseSample(
                date: sample.date,
                quantity: HKQuantity(unit: mgdl, doubleValue: mapped),
                condition: sample.condition,
                trend: sample.trend,
                trendRate: sample.trendRate.map {
                    HKQuantity(unit: mgdlPerMin, doubleValue: slope * $0.doubleValue(for: mgdlPerMin))
                },
                isDisplayOnly: sample.isDisplayOnly,
                wasUserEntered: sample.wasUserEntered,
                syncIdentifier: sample.syncIdentifier,
                syncVersion: sample.syncVersion,
                device: sample.device)
        }
    }
}
