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
// "soak" for the duration of a loan, plus "takeover" and "handback" for the two bounded windows
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
    private var session: HKWorkoutSession?      // MAIN-only
    private var holders: Set<String> = []       // MAIN-only — the reasons the keepalive is wanted
    private var authOK = false                  // MAIN-only — HealthKit workout auth granted
    private var authInFlight = false            // MAIN-only — a first-time auth request is pending
    private var recoverInFlight = false         // MAIN-only — a recoverActiveWorkoutSession probe is pending
    private var recoveryProbed = false          // MAIN-only — the once-per-process survivor probe has run
    private var recoverGeneration: UInt64 = 0   // MAIN-only — invalidates a superseded probe watchdog

    // The runtime heartbeat ticks on a utility queue, so it cannot read the MAIN-only state
    // above. Mirror it into a lock-guarded tag that any thread may sample: every `[runtime]`
    // line then says whether the keepalive that is supposed to be holding us up was alive.
    private let tagLock = NSLock()
    private var _tag = "keepalive off"

    var stateTag: String { tagLock.lock(); defer { tagLock.unlock() }; return _tag }
    private func setTag(_ s: String) { tagLock.lock(); _tag = s; tagLock.unlock() }

    override init() {
        super.init()
        RuntimeStateLog.keepaliveProbe = { [weak self] in self?.stateTag ?? "keepalive ?" }
    }

    /// Want the keepalive for `reason`; starts the session if it wasn't running. Idempotent.
    func acquire(_ reason: String) { onMain { self.holders.insert(reason); self.startSessionIfNeeded() } }

    /// Stop wanting the keepalive for `reason`; ends the session only when NO reason remains.
    /// Removing an absent reason is a harmless no-op (safe to call twice from racing teardowns).
    func release(_ reason: String) { onMain { self.holders.remove(reason); if self.holders.isEmpty { self.endSession() } } }

    /// Re-assert the session if something still wants it but the OS killed it (HK error 14 after a
    /// background relaunch, or a session failure). Call on every foreground activation.
    func ensureRunning() { onMain { self.startSessionIfNeeded() } }

    private func startSessionIfNeeded() {   // MAIN
        guard session == nil, !authInFlight, !recoverInFlight else { return }   // running, or a start/probe is pending
        guard !holders.isEmpty else { return }                                  // nobody wants it
        guard HKHealthStore.isHealthDataAvailable() else {
            SportLog.event("keepalive", "HealthKit unavailable on this device")
            return
        }
        // #82: a session started BEFORE a background relaunch can still be running inside
        // HealthKit even though our `session` reference died with the old process. Creating a
        // second one on top of it fails, so adopt the survivor first and only start fresh if
        // there is nothing to adopt. Without this, every relaunch-recovery path silently lost.
        //
        // But the probe MUST NOT sit in front of the normal start. `acquire()` is called from
        // the FOREGROUND precisely because a start while backgrounded fails with HK error 14,
        // and an async HealthKit round-trip pushes the start to a later main-queue turn — long
        // enough for the app to background in between, turning a working start into a failing
        // one. A survivor can only come from a PREVIOUS process, so probing once per process is
        // sufficient; after that, go straight to the start on this same turn. A failed start is
        // the one signal that HealthKit may be holding a session we don't know about, so that
        // re-arms the probe (see startSession()).
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
                // A release() may have landed while the probe was in flight.
                guard !self.holders.isEmpty, self.session == nil else {
                    if let recovered { recovered.end() }   // nobody wants it any more — don't leak it
                    return
                }
                if let recovered, [.running, .paused, .prepared].contains(recovered.state) {
                    recovered.delegate = self
                    self.session = recovered
                    self.authOK = true          // it is running, so sharing was authorised
                    self.setTag("keepalive recovered(\(self.holderTag()))")
                    SportLog.event("keepalive", "adopted a surviving HKWorkoutSession (state \(recovered.state.rawValue)) — no new session needed (holders: \(self.holderTag()))")
                    return
                }
                if let recovered {
                    recovered.end()             // ended/stopped leftovers can block a fresh start
                    SportLog.event("keepalive", "discarded a dead recovered session (state \(recovered.state.rawValue))")
                }
                self.authoriseThenStart()
            }
        }
        // The probe MUST NOT be able to strand the keepalive: if HealthKit never calls back,
        // `recoverInFlight` would latch true and no session could ever start again. Fall through
        // to the plain start after 2 s — it is a local healthd query, so anything slower is a
        // hang, and every second here is a second the keepalive is not holding us up. A late
        // callback is harmless: it no-ops (or ends the stale session it recovered) once
        // `session` is non-nil.
        recoverGeneration &+= 1
        let generation = recoverGeneration   // a later probe invalidates this watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.recoverInFlight, self.recoverGeneration == generation else { return }
            self.recoverInFlight = false
            SportLog.event("keepalive", "recoverActiveWorkoutSession did not call back in 2s — starting a fresh session")
            self.authoriseThenStart()
        }
    }

    private func authoriseThenStart() {   // MAIN
        if authOK { startSession(); return }
        authInFlight = true
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: share, read: []) { [weak self] ok, err in
            guard let self else { return }
            self.onMain {
                self.authInFlight = false
                // `ok` means only that the REQUEST completed — it is true even when the user
                // tapped Don't Allow. The share status is the only thing that says we may
                // actually start a session, and reading `ok` as "granted" made a denial look
                // identical to a grant in the log (#82).
                let status = self.healthStore.authorizationStatus(for: HKObjectType.workoutType())
                self.authOK = (status == .sharingAuthorized)
                guard self.authOK else {
                    self.setTag("keepalive DENIED")
                    SportLog.event("keepalive", "workout share auth NOT granted (status \(status.rawValue), requestOK \(ok), err \(String(describing: err))) — background keepalive will NOT work; tap Allow on the watch")
                    return
                }
                // Only start if the session is STILL wanted — a release() may have landed while auth
                // was pending (this is the orphaned-session race the refcount closes).
                guard !self.holders.isEmpty, self.session == nil else { return }
                self.startSession()
            }
        }
    }

    private func holderTag() -> String { holders.sorted().joined(separator: ",") }   // MAIN

    private func startSession() {   // MAIN
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
            session = nil   // stay restartable — the next foreground ensureRunning retries
            // A failed start is the one thing that suggests HealthKit is holding a session we
            // don't know about, so let the next attempt probe for a survivor again.
            recoveryProbed = false
            setTag("keepalive START-FAILED")
            SportLog.event("keepalive", "HKWorkoutSession start FAILED: \(error)")
        }
    }

    private func endSession() {   // MAIN
        session?.end()
        session = nil
        setTag("keepalive off")
        SportLog.event("keepalive", "session ended (no holders)")
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    // MARK: HKWorkoutSessionDelegate
    func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState,
                        from: HKWorkoutSessionState, date: Date) {
        SportLog.event("keepalive", "state \(from.rawValue) -> \(to.rawValue)")
    }
    func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        SportLog.event("keepalive", "session FAILED: \(error)")
        setTag("keepalive FAILED")
        onMain { self.session = nil }   // stay restartable — next foreground ensureRunning retries (HK error 14 path)
    }
}
