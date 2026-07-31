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
//
// 2026-07-31 — the WKBackgroundModes entry was MISSING until build 199, and the measurement
// that found it is worth recording, because the log had been read the wrong way round for
// weeks. Builds ≤189 logged "[app] BACKGROUND (resigned active)" on RESIGN-ACTIVE, which fires
// on every screen dim; counting work inside those windows looked like background execution but
// was really frontmost-with-screen-off — which is all a workout session ever bought us. Builds
// ≥190 log the true WKApplication.state, and across four of them 1255 lines carry `state
// active` against 31 carrying `state background` — every one of the 31 a lifecycle marker or a
// "[runtime] GAP … app was NOT executing" report. Zero work, ever, in background. The
// clinching case (build 194): a session started 23:17:44 with holder "soak" was still nominally
// running at 06:49, yet the app went BACKGROUND at 23:19:02, died 6.5 min later mid-reclaim,
// and logged nothing until the wrist came up at 02:21:34. A running session that does not keep
// the process alive is exactly what a missing background mode looks like.
//
// So this file's opening premise was aspirational, not observed. `[runtime] BG-ALIVE` lines are
// the only thing that will make it true — their presence is the pass criterion, their absence
// across a night is the failure signal.

import Foundation
import HealthKit

final class WorkoutKeepalive: NSObject, HKWorkoutSessionDelegate {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?      // MAIN-only
    private var holders: Set<String> = []       // MAIN-only — the reasons the keepalive is wanted
    private var authOK = false                  // MAIN-only — HealthKit workout auth granted
    private var authInFlight = false            // MAIN-only — a first-time auth request is pending
    private var recoverInFlight = false         // MAIN-only — a recoverActiveWorkoutSession probe is pending
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
            log("WorkoutKeepalive: HealthKit unavailable on this device")
            return
        }
        // #82: a session started BEFORE a background relaunch can still be running inside
        // HealthKit even though our `session` reference died with the old process. Creating a
        // second one on top of it fails, so adopt the survivor first and only start fresh if
        // there is nothing to adopt. Without this, every relaunch-recovery path silently lost.
        recoverInFlight = true
        healthStore.recoverActiveWorkoutSession { [weak self] recovered, error in
            guard let self else { return }
            self.onMain {
                self.recoverInFlight = false
                if let error {
                    log("WorkoutKeepalive: recoverActiveWorkoutSession error: \(error)")
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
                    log("WorkoutKeepalive: adopted a surviving HKWorkoutSession (state \(recovered.state.rawValue)) — no new session needed (holders: \(self.holderTag()))")
                    return
                }
                if let recovered {
                    recovered.end()             // ended/stopped leftovers can block a fresh start
                    log("WorkoutKeepalive: discarded a dead recovered session (state \(recovered.state.rawValue))")
                }
                self.authoriseThenStart()
            }
        }
        // The probe MUST NOT be able to strand the keepalive: if HealthKit never calls back,
        // `recoverInFlight` would latch true and no session could ever start again. Fall through
        // to the plain start after 5 s. A late callback is harmless — it no-ops (or ends the
        // stale session it recovered) once `session` is non-nil.
        recoverGeneration &+= 1
        let generation = recoverGeneration   // a later probe invalidates this watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.recoverInFlight, self.recoverGeneration == generation else { return }
            self.recoverInFlight = false
            log("WorkoutKeepalive: recoverActiveWorkoutSession did not call back in 5s — starting a fresh session")
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
                    log("WorkoutKeepalive: workout share auth NOT granted (status \(status.rawValue), requestOK \(ok), err \(String(describing: err))) — background keepalive will NOT work; tap Allow on the watch")
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
            log("WorkoutKeepalive: HKWorkoutSession(.other) started — background runtime ACTIVE (holders: \(holderTag()))")
        } catch {
            session = nil   // stay restartable — the next foreground ensureRunning retries
            setTag("keepalive START-FAILED")
            log("WorkoutKeepalive: HKWorkoutSession start FAILED: \(error)")
        }
    }

    private func endSession() {   // MAIN
        session?.end()
        session = nil
        setTag("keepalive off")
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
        setTag("keepalive FAILED")
        onMain { self.session = nil }   // stay restartable — next foreground ensureRunning retries (HK error 14 path)
    }
}
