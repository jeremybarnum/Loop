// WorkoutKeepalive.swift — the background-runtime vehicle for the watch loop.
//
// watchOS suspends a backgrounded third-party app within seconds, and there is NO CoreBluetooth
// state restoration on watchOS — so a suspended app cannot be woken by a BLE event. An
// HKWorkoutSession is the only self-service API that keeps our process (and its BLE links) alive.
// That is what lets the loop keep dosing and lets stock G7SensorKit keep receiving with the wrist
// down. Riding the Dexcom watch app's authenticated session buys us DATA, not RUNTIME:
// entitlements are not inheritable by a co-resident app.
//
// More than one subsystem can want the keepalive at once, so holds are REFCOUNTED BY REASON —
// "loanWorkout" for the duration of a loan, plus "takeover" and "handback" for the two bounded windows
// that need runtime of their own. Releasing one can never stop a session another still wants.
// Owned by StockLoopSession, which drives all three.
//
// (Until 2026-08-06 this file lived under G7/ and was owned by the reverse-engineered G7 reader,
// with a fourth "prewarm" holder. The reader and pre-warm are gone; three of the four holders were
// always loan-lifecycle concerns and had nothing to do with the sensor.)
//
import Foundation
import HealthKit

final class WorkoutKeepalive: NSObject, HKWorkoutSessionDelegate {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var holders: Set<String> = []
    private var authOK = false
    private var authInFlight = false
    private var recoverInFlight = false
    private var recoveryProbed = false
    private var recoverGeneration: UInt64 = 0

    private let tagLock = NSLock()
    private var _tag = "keepalive off"

    var stateTag: String { tagLock.lock(); defer { tagLock.unlock() }; return _tag }
    private func setTag(_ s: String) { tagLock.lock(); _tag = s; tagLock.unlock() }

    private var _held = false
    var isHeld: Bool { tagLock.lock(); defer { tagLock.unlock() }; return _held }
    private func setHeld(_ v: Bool) { tagLock.lock(); _held = v; tagLock.unlock() }

    override init() {
        super.init()
        RuntimeStateLog.keepaliveProbe = { [weak self] in self?.stateTag ?? "keepalive ?" }
    }

    func acquire(_ reason: String) { setHeld(true); onMain { self.holders.insert(reason); self.startSessionIfNeeded() } }

    func release(_ reason: String) { onMain { self.holders.remove(reason); if self.holders.isEmpty { self.setHeld(false); self.endSession() } } }

    func ensureRunning() { onMain { self.startSessionIfNeeded() } }

    private func startSessionIfNeeded() {
        guard session == nil, !authInFlight, !recoverInFlight else { return }
        guard !holders.isEmpty else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            SportLog.event("keepalive", "HealthKit unavailable on this device")
            return
        }

        guard !recoveryProbed else { authoriseThenStart(); return }
        recoveryProbed = true
        recoverInFlight = true
        healthStore.recoverActiveWorkoutSession { [weak self] recovered, error in
            guard let self else { return }
            self.onMain {
                self.recoverInFlight = false
                if let error {
                    SportLog.event("keepalive", "recoverActiveWorkoutSession error: \(error)")
                }

                guard !self.holders.isEmpty, self.session == nil else {
                    if let recovered { recovered.end() }
                    return
                }
                if let recovered, [.running, .paused, .prepared].contains(recovered.state) {
                    recovered.delegate = self
                    self.session = recovered
                    self.authOK = true
                    self.setTag("keepalive recovered(\(self.holderTag()))")
                    SportLog.event("keepalive", "adopted a surviving HKWorkoutSession (state \(recovered.state.rawValue)) — no new session needed (holders: \(self.holderTag()))")
                    return
                }
                if let recovered {
                    recovered.end()
                    SportLog.event("keepalive", "discarded a dead recovered session (state \(recovered.state.rawValue))")
                }
                self.authoriseThenStart()
            }
        }

        recoverGeneration &+= 1
        let generation = recoverGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.recoverInFlight, self.recoverGeneration == generation else { return }
            self.recoverInFlight = false
            SportLog.event("keepalive", "recoverActiveWorkoutSession did not call back in 2s — starting a fresh session")
            self.authoriseThenStart()
        }
    }

    private func authoriseThenStart() {
        if authOK { startSession(); return }
        authInFlight = true
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: share, read: []) { [weak self] ok, err in
            guard let self else { return }
            self.onMain {
                self.authInFlight = false

                let status = self.healthStore.authorizationStatus(for: HKObjectType.workoutType())
                self.authOK = (status == .sharingAuthorized)
                guard self.authOK else {
                    self.setTag("keepalive DENIED")
                    SportLog.event("keepalive", "workout share auth NOT granted (status \(status.rawValue), requestOK \(ok), err \(String(describing: err))) — background keepalive will NOT work; tap Allow on the watch")
                    return
                }

                guard !self.holders.isEmpty, self.session == nil else { return }
                self.startSession()
            }
        }
    }

    private func holderTag() -> String { holders.sorted().joined(separator: ",") }

    private func startSession() {
        let cfg = HKWorkoutConfiguration()
        cfg.activityType = .other
        cfg.locationType = .indoor
        do {
            let s = try HKWorkoutSession(healthStore: healthStore, configuration: cfg)
            s.delegate = self
            s.startActivity(with: Date())
            session = s
            setTag("keepalive running(\(holderTag()))")
            SportLog.event("keepalive", "HKWorkoutSession(.other) started — background runtime ACTIVE (holders: \(holderTag()))")
        } catch {
            session = nil

            recoveryProbed = false
            setTag("keepalive START-FAILED")
            SportLog.event("keepalive", "HKWorkoutSession start FAILED: \(error)")
        }
    }

    private func endSession() {
        session?.end()
        session = nil
        setTag("keepalive off")
        SportLog.event("keepalive", "session ended (no holders)")
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState,
                        from: HKWorkoutSessionState, date: Date) {
        SportLog.event("keepalive", "state \(from.rawValue) -> \(to.rawValue)")
    }
    func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        SportLog.event("keepalive", "session FAILED: \(error)")
        setTag("keepalive FAILED")
        onMain { self.session = nil }
    }
}
