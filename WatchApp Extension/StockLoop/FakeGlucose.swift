//
//  FakeGlucose.swift
//  WatchApp Extension
//
//  BENCH-ONLY scripted glucose (task #33 / R29). Jeremy 2026-07-22: "we really need to see
//  a test that involves high temping and low temping more dynamically with some no-change
//  cycles in order to have confidence that it will work in real world conditions."
//
//  WHY THIS EXISTS: Jeremy is not diabetic, so field BG is narrow euglycemia (~75-135).
//  Every dosing observation to date has therefore been a zero temp or no-change — the
//  loop's entire high-temp range has NEVER been exercised on hardware, and that is exactly
//  the range where a dosing bug matters. No amount of wrist time fixes that; the input has
//  to be synthesized.
//
//  DESIGN — substitute the VALUE at ingestion, never bypass acquisition:
//   * The real G7 connect/handshake/read still happens, so BLE contention with the pod is
//     genuine and the E4 timing geometry is unchanged.
//   * The scripted value replaces the real mg/dL only after a SUCCESSFUL read, so a missed
//     window stays missed and catch-rate telemetry stays honest.
//   * Everything downstream is real: glucose store, momentum, prediction, DoseMath, the pod
//     command. This tests the actual dosing path, not a simulation of it.
//
//  The profile sweeps the whole decision space rather than oscillating in one band, because
//  the goal is to see the loop TRANSITION: rising through target (high temps), at target
//  (no change), falling below (zero temp / suspend), and back. A band that never crosses
//  target would only ever prove one branch — and saturating at cap/floor produces repeated
//  identical commands, which the pod path may coalesce, hiding failures.
//
//  SAFETY: bench flag, loud per-value logging, and a hard self-expiry so it cannot silently
//  persist into a session that is meant to be real. This drives REAL insulin into a REAL
//  pod — it must never be ambiguous whether a log came from fake input.
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm

enum FakeGlucose {

    private static let enabledKey = "g7.fakeBG"
    private static let startedAtKey = "g7.fakeBGStartedAt"

    /// Sweep parameters. Centre sits above target so the curve spends real time in
    /// high-temp territory, and the trough goes below suspend threshold so the zero-temp
    /// branch is exercised too.
    private static let centre: Double = 155      // mg/dL
    private static let amplitude: Double = 85    // -> ~70 to ~240
    private static let period: TimeInterval = .hours(2)
    /// Self-expiry: bench runs are deliberate and bounded. If this is still on hours later
    /// it is an accident, and an accident here means dosing against fiction.
    private static let maxDuration: TimeInterval = .hours(8)

    static var isEnabled: Bool {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return false }
        guard let started = UserDefaults.standard.object(forKey: startedAtKey) as? Date else { return false }
        if Date().timeIntervalSince(started) > maxDuration {
            setEnabled(false)
            SportLog.event("fakebg", "FAKE BG auto-disabled — exceeded \(Int(maxDuration / 3600))h bench limit")
            return false
        }
        return true
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on {
            UserDefaults.standard.set(Date(), forKey: startedAtKey)
            SportLog.event("fakebg", String(format: "*** FAKE BG ENABLED *** sweep %.0f-%.0f mg/dL over %.0f min — REAL insulin will be dosed against SYNTHETIC glucose",
                                            centre - amplitude, centre + amplitude, period / 60))
        } else {
            UserDefaults.standard.removeObject(forKey: startedAtKey)
            SportLog.event("fakebg", "FAKE BG disabled — real sensor values resume")
        }
    }

    /// Elapsed fraction through the sweep, for display.
    static var phaseDescription: String {
        guard let started = UserDefaults.standard.object(forKey: startedAtKey) as? Date else { return "—" }
        let mins = Date().timeIntervalSince(started) / 60
        return String(format: "%.0fm (%.0f%% of sweep)", mins, (mins * 60).truncatingRemainder(dividingBy: period) / period * 100)
    }

    /// The scripted value at a moment. Sine rather than a ramp so the rate-of-change varies
    /// too — steep through the middle, flat at the extremes — which exercises momentum and
    /// keeps consecutive recommendations genuinely different instead of a constant slope.
    static func value(at date: Date) -> Double {
        guard let started = UserDefaults.standard.object(forKey: startedAtKey) as? Date else { return centre }
        let elapsed = date.timeIntervalSince(started)
        let radians = (elapsed / period) * 2 * Double.pi
        return (centre + amplitude * sin(radians)).rounded()
    }

    /// Rewrite a batch of real samples with scripted values, preserving dates and sync
    /// identifiers so store semantics (dedup, ordering, recency) are untouched.
    static func substitute(_ samples: [NewGlucoseSample]) -> [NewGlucoseSample] {
        return samples.map { sample in
            let fake = value(at: sample.date)
            SportLog.event("fakebg", String(format: "*** FAKE BG *** %.0f mg/dL substituted for real %.0f · %@",
                                            fake,
                                            sample.quantity.doubleValue(for: .milligramsPerDeciliter),
                                            phaseDescription))
            return NewGlucoseSample(
                date: sample.date,
                quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: fake),
                condition: nil,
                trend: nil,
                trendRate: nil,
                isDisplayOnly: false,
                wasUserEntered: false,
                syncIdentifier: sample.syncIdentifier
            )
        }
    }
}
