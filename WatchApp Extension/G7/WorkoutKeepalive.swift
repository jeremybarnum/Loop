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

    /// Request HealthKit auth (once) then start the keepalive session.
    func start() {
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
    }
}
