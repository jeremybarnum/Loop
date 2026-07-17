// WorkoutKeepalive.swift — the background-runtime vehicle for the direct G7 reader.
//
// watchOS suspends a backgrounded third-party app within seconds (no CoreBluetooth state
// restoration on watchOS, so a G7 notification can't wake us). The one self-service API
// that keeps our OWN process running continuously with BLE alive is an HKWorkoutSession.
// We start one (activityType .other) while the reader needs to stay awake; the OS won't
// suspend us, so our 5-min poll timer keeps firing and the G7 connection stays usable
// wrist-down / screen-off. Same pattern HR-strap and cycling-power-meter apps use.
//
// REFERENCE-COUNTED. More than one subsystem can want the keepalive at once: the Sport-Mode
// soak ("soak") and the one-shot new-sensor pre-warm ("prewarm"). The session runs iff at
// least one holder wants it — so a pre-warm ending can NEVER stop the keepalive Sport Mode is
// using, whatever the thread or ordering. ALL state (the holder set + the session + the auth
// flag) is confined to the MAIN queue — acquire/release/ensureRunning hop there internally — so
// concurrent callers from the BLE queue, the handshake Task, and the loan-phase observer cannot
// race it. A start attempted while BACKGROUNDED fails with HealthKit error 14 ("cannot start a
// workout session while in the background"), so callers MUST acquire from the foreground; a
// background relaunch that loses the session is recovered by the next foreground ensureRunning()
// (without it the reader silently suspends — observed 2026-07-15, 3.5h outage).
//
// Requires: HealthKit capability (entitlement) + `workout-processing` in WKBackgroundModes
// + NSHealthShare/UpdateUsageDescription, all in the target's Info.plist/entitlements.

import Foundation
import HealthKit

final class WorkoutKeepalive: NSObject, HKWorkoutSessionDelegate {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?      // MAIN-only
    private var holders: Set<String> = []       // MAIN-only — the reasons the keepalive is wanted
    private var authOK = false                  // MAIN-only — HealthKit workout auth granted
    private var authInFlight = false            // MAIN-only — a first-time auth request is pending

    /// Want the keepalive for `reason`; starts the session if it wasn't running. Idempotent.
    func acquire(_ reason: String) { onMain { self.holders.insert(reason); self.startSessionIfNeeded() } }

    /// Stop wanting the keepalive for `reason`; ends the session only when NO reason remains.
    /// Removing an absent reason is a harmless no-op (safe to call twice from racing teardowns).
    func release(_ reason: String) { onMain { self.holders.remove(reason); if self.holders.isEmpty { self.endSession() } } }

    /// Re-assert the session if something still wants it but the OS killed it (HK error 14 after a
    /// background relaunch, or a session failure). Call on every foreground activation.
    func ensureRunning() { onMain { self.startSessionIfNeeded() } }

    private func startSessionIfNeeded() {   // MAIN
        guard session == nil, !authInFlight else { return }   // already running or a start is pending
        guard !holders.isEmpty else { return }                // nobody wants it
        guard HKHealthStore.isHealthDataAvailable() else {
            log("WorkoutKeepalive: HealthKit unavailable on this device")
            return
        }
        if authOK { startSession(); return }
        authInFlight = true
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: share, read: []) { [weak self] ok, err in
            guard let self else { return }
            self.onMain {
                self.authInFlight = false
                self.authOK = ok
                guard ok else {
                    log("WorkoutKeepalive: HealthKit auth NOT granted (\(String(describing: err))) — background keepalive will NOT work; tap Allow on the watch")
                    return
                }
                // Only start if the session is STILL wanted — a release() may have landed while auth
                // was pending (this is the orphaned-session race the refcount closes).
                guard !self.holders.isEmpty, self.session == nil else { return }
                self.startSession()
            }
        }
    }

    private func startSession() {   // MAIN
        let cfg = HKWorkoutConfiguration()
        cfg.activityType = .other
        cfg.locationType = .indoor
        do {
            let s = try HKWorkoutSession(healthStore: healthStore, configuration: cfg)
            s.delegate = self
            s.startActivity(with: Date())
            session = s
            log("WorkoutKeepalive: HKWorkoutSession(.other) started — background runtime ACTIVE (holders: \(holders.sorted().joined(separator: ",")))")
        } catch {
            session = nil   // stay restartable — the next foreground ensureRunning retries
            log("WorkoutKeepalive: HKWorkoutSession start FAILED: \(error)")
        }
    }

    private func endSession() {   // MAIN
        session?.end()
        session = nil
        log("WorkoutKeepalive: session ended (no holders)")
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    // MARK: HKWorkoutSessionDelegate
    func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState,
                        from: HKWorkoutSessionState, date: Date) {
        log("WorkoutKeepalive: state \(from.rawValue) -> \(to.rawValue)")
    }
    func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        log("WorkoutKeepalive: session FAILED: \(error)")
        onMain { self.session = nil }   // stay restartable — next foreground ensureRunning retries (HK error 14 path)
    }
}
