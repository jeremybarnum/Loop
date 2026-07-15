// WorkoutKeepalive.swift — the background-runtime vehicle for the soak test.
//
// watchOS suspends a backgrounded third-party app within seconds (no CoreBluetooth state
// restoration on watchOS, so a G7 notification can't wake us). The one self-service API
// that keeps our OWN process running continuously with BLE alive is an HKWorkoutSession.
// We start one (activityType .other) at soak start; while it's running the OS won't suspend
// us, so our 5-min poll timer keeps firing and the G7 connection stays usable wrist-down /
// screen-off. This is the same pattern HR-strap and cycling-power-meter apps use.
//
// Requires: HealthKit capability (entitlement) + `workout-processing` in WKBackgroundModes
// + NSHealthShare/UpdateUsageDescription, all in the target's Info.plist/entitlements.

import Foundation
import HealthKit

final class WorkoutKeepalive: NSObject, HKWorkoutSessionDelegate {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?

    /// Request HealthKit auth (once) then start the keepalive session. Idempotent — safe to
    /// re-call on every foreground activation: a start attempted while BACKGROUNDED fails with
    /// HealthKit error 14 ("cannot start a workout session while in the background"), e.g. when
    /// watchOS relaunches the app in the background after an update; without a foreground retry
    /// the G7 reader silently suspends (observed 2026-07-15, 3.5h outage).
    func start() {
        guard session == nil else { return }   // already running (or starting)
        guard HKHealthStore.isHealthDataAvailable() else {
            log("WorkoutKeepalive: HealthKit unavailable on this device")
            return
        }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: share, read: []) { [weak self] ok, err in
            guard let self else { return }
            guard ok else {
                log("WorkoutKeepalive: HealthKit auth NOT granted (\(String(describing: err))) — background keepalive will NOT work; tap Allow on the watch")
                return
            }
            self.startSession()
        }
    }

    private func startSession() {
        let cfg = HKWorkoutConfiguration()
        cfg.activityType = .other
        cfg.locationType = .indoor
        do {
            let s = try HKWorkoutSession(healthStore: healthStore, configuration: cfg)
            s.delegate = self
            s.startActivity(with: Date())
            session = s
            log("WorkoutKeepalive: HKWorkoutSession(.other) started — background runtime ACTIVE")
        } catch {
            session = nil   // stay restartable — the next foreground ensure retries
            log("WorkoutKeepalive: HKWorkoutSession start FAILED: \(error)")
        }
    }

    func stop() {
        session?.end()
        session = nil
        log("WorkoutKeepalive: session ended")
    }

    // MARK: HKWorkoutSessionDelegate
    func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState,
                        from: HKWorkoutSessionState, date: Date) {
        log("WorkoutKeepalive: state \(from.rawValue) -> \(to.rawValue)")
    }
    func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        log("WorkoutKeepalive: session FAILED: \(error)")
        session = nil   // stay restartable — the next foreground ensure retries (HK error 14 path)
    }
}
