//
//  StockLoopSession.swift
//  WatchApp Extension
//
//  M5 integration: the app-lifecycle OWNER of the assembled stock loop and the loan
//  controller (resolves M4's "assemble() has no call sites"). ExtensionDelegate holds
//  one of these lazily; it stays inert (no radio, no dosing) until a loan grant
//  arrives (closedDirect is the only ruled dosing mode wired so far; the R20 picker adds
//  the others at the UI layer). CGM is stock G7SensorKit and runs independently of the loan.
//

import Foundation
import OmnipodKit
import G7SensorKit        // #86: PodLoanConnectClock.podLoanLogSink (pod BLE layer -> watch log)
import WatchConnectivity
import os.log

final class StockLoopSession {

    let stack: StockLoopStack.Stack

    /// Background runtime for the whole session.
    ///
    /// watchOS suspends a third-party app within seconds of the wrist dropping, and there is NO
    /// CoreBluetooth state restoration on watchOS — so a suspended app cannot be woken by a BLE
    /// event. An HKWorkoutSession is the only self-service API that keeps our process (and its BLE
    /// links) alive, which is what lets the loop run and lets stock G7SensorKit receive at all.
    /// Riding the Dexcom watch app's authenticated session buys us DATA, not RUNTIME: entitlements
    /// are not inheritable by a co-resident app.
    ///
    /// Refcounted by reason ("soak" for the loan, plus "takeover"/"handback" for the two windows
    /// that need runtime of their own), so overlapping holds cannot end the session early.
    private let keepalive = WorkoutKeepalive()

    /// Reference-counted so overlapping reasons can't drop the session out from under each other:
    /// a hand-back beginning while the takeover hold is still released, say.
    private func setKeepalive(_ holding: Bool, reason: String) {
        holding ? keepalive.acquire(reason) : keepalive.release(reason)
    }

    /// Re-assert the session if something still wants it. Called on every foreground — the one
    /// moment we KNOW we are executing, which matters because the only other re-assert path is a
    /// timer that by construction cannot fire while the process is suspended. No-op when nothing
    /// holds it, so foregrounding outside a loan does not start a workout.
    func ensureKeepalive() { keepalive.ensureRunning() }
    let loanController: PodLoanWatchController

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "StockLoopSession")

    init() {
        // LINK POLICY IS AUTOMATIC (#101 phase 2, Jeremy 2026-08-10: "implement it coherently
        // not as a toggle in the diagnostic screen"). The E4 toggle is GONE — both of its arms
        // were wrong for acquisition and indistinguishable in steady state:
        //
        // - OFF (hold the pod link) starved the acquisition scan: 0 adoptions across ~130 min
        //   of held-link windows on 2026-08-10, versus adoption within 7-10 min of each of the
        //   two releases. Steady state was immune — but a session that never adopts never
        //   reaches steady state on the direct path.
        // - ON (orphan + reclaim per cycle) collided by construction while un-adopted: the
        //   reclaim fires ~100ms after the relay reading, exactly when the D2W ride appears
        //   (census 23:31:48 — pod scan :48.089, G7 ad :48.197, connect never completed).
        //
        // The policy now: orphan between doses, reclaim every cycle (the most-validated radio
        // rhythm we have — E5 84/84, build 157 44/44, census build 263 3/3), with the reclaim
        // GATED on G7 acquisition state while un-adopted (WatchLoopManager's acquisition gate).
        // Persisted sensor identity (StockLoopStack) makes the un-adopted phase rare. The old
        // "g7.e4ReleasePod" default is no longer read anywhere. R31 amended accordingly.
        // FakeGlucose and E5 both substitute into the LIVE dosing/enact path; with their
        // toggles gone they must never linger enabled in a real session. Clear any
        // persisted test state at launch (both are trivially restored from git).
        FakeGlucose.setEnabled(false)
        UserDefaults.standard.set(false, forKey: "g7.e5RandomTemp")

        stack = StockLoopStack.assemble()
        loanController = PodLoanWatchController(loopManager: stack.loopManager)

        // #86 (2026-08-03): let the pod BLE layer write into the watch's mirrored log.
        // OmnipodKit logs via os_log, which never reaches the g7watch file the field analysis
        // reads — a [CONFIG] diagnostic added to settle "did we ever talk to the pod" produced
        // zero visible lines for exactly that reason. Wired here (watch only; the phone leaves
        // the sink nil and keeps os_log).
        PodLoanConnectClock.podLoanLogSink = { line in SportLog.event("pod-ble", line) }

        // #101 (2026-08-10): the G7 radio census — the acquisition mechanism was INFERRED from
        // a held-link/release toggle experiment; this makes it OBSERVED. Names which of the
        // three acquisition triggers fires (system-connected piggyback / connection event /
        // ad scan), D2W's connection rhythm, connect verdicts, and the GATT inventory at
        // unknownCharacteristic failures. Watch only, same rationale as the pod sink above.
        G7RadioCensus.sink = { line in SportLog.event("g7-ble", line) }

        // Main-thread stall detector (2026-08-07). Started at LAUNCH and never stopped, unlike
        // the loan-scoped heartbeat below: the two UI freezes on 2026-08-07 were invisible to
        // every existing instrument, and one of them ended in a watchdog kill that took the
        // unflushed tail of the log with it. A wedged main thread is exactly the condition under
        // which nothing else in this app can report anything, so the one detector that can must
        // always be running. Costs one ping per second on a utility queue and stays silent while
        // healthy.
        RuntimeStateLog.startMainStallDetector()

        // #67 follow-up: the one question the hand-back UI needs answered.
        loanController.isPhoneReachable = { WCSession.default.isReachable }

        loanController.send = { dictionary in
            // transferUserInfo: queued, survives reachability flaps and relaunches —
            // the delivery semantics the protocol's cursor/IDs are built around. It is also
            // explicitly NON-URGENT, which is wrong for the interactive handshake: see
            // LoanMessage.isInteractiveHandshake for the 2026-08-02 field case where a Start
            // request sat in the queue past the watch's own 25 s timeout. Those kinds take
            // sendMessage (wakes the phone app in ms) and fall back to the queue on failure,
            // so reliability is never worse than it was.
            let session = WCSession.default
            let urgent = LoanMessage.isInteractiveHandshake(transport: dictionary) && session.isReachable
            SportLog.event("wc", "send \(dictionary.keys.joined(separator: ",")) — session \(session.activationState.rawValue), reachable \(session.isReachable), path \(urgent ? "urgent" : "queued")")
            guard urgent else {
                session.transferUserInfo(dictionary)
                return
            }
            session.sendMessage(dictionary, replyHandler: nil, errorHandler: { error in
                SportLog.event("wc", "urgent send FAILED (\(error.localizedDescription)) — falling back to the queued path")
                session.transferUserInfo(dictionary)
            })
        }

        // NO RADIO ARBITER. It existed to make loop pod commands yield to OUR OWN G7 reader's
        // scan/handshake (#84), and that reader is gone — its flags were the arbiter's only
        // producer, so the predicate could now only ever read false.
        //
        // BE PRECISE ABOUT WHY (corrected 2026-08-06 by review): this is NOT because the app
        // stopped using the sensor radio. Stock G7SensorKit runs its own CBCentralManager
        // in-process, scans between readings and calls connect() — the app very much still drives
        // a sensor radio. What is gone is any signal about WHEN, plus the component whose
        // scan/handshake was actually starving the pod. Whether stock's own scanning contends with
        // the pod the way ours did is UNMEASURED; field data so far says no (build 244, deliberate
        // dosing load: zero deferrals, 9 cycles, 0 errors, 5/5 readings — against 79 refusals and
        // 585s blocks the night before), but that is one 30-minute run, not a proof.

        stack.loopManager.podBeepsOnManualBolusProbe = { [weak self] in
            self?.loanController.podBeepsOnManualBolus ?? false
        }

        // #86 (2026-08-03): the takeover ladder needs background RUNTIME. This hook fires true on
        // entering .takingOver and false on every exit, so it is exactly the ladder's lifetime.
        // Without it the 3 s poll is throttled the moment the wrist drops and the read budget burns
        // on wall-clock instead of attempts — the measured cause of that day's takeover failures.
        // (The radio half of R26 — standing the G7 down during the ladder — retired with the
        // reader that needed standing down.)
        loanController.onTakeoverRadioHold = { [weak self] holding in
            self?.setKeepalive(holding, reason: "takeover")
            // Log pipeline v4: snapshot at takeover start (grant picture) and at the
            // verdict — the ~40s window that decides a session, captured either way.
            self?.sendLogSnapshot(holding ? "takeover start" : "takeover verdict")
        }

        // Hand-back needs the same runtime the takeover ladder needed. Without it the watch
        // stops being reachable the moment the wrist drops after End, the phone's ack falls
        // back to the queued channel, and the pod stays held until iOS decides to deliver it.
        loanController.onHandbackRuntimeHold = { [weak self] holding in
            self?.setKeepalive(holding, reason: "handback")
            SportLog.event("loan", holding
                ? "hand-back runtime hold ACQUIRED — staying reachable for the phone's ack"
                : "hand-back runtime hold released")
        }

        // #82 RETIRED by #84 (2026-07-31): the dose-window stand-down is deliberately NOT
        // wired. It stranded the radio overnight — the app suspended mid-ladder holding the
        // sensor off, and with no BLE events left to wake it the watch went dark for 2.9h
        // (02:21 GAP 10555s). Waiting for the sensor's attempt to END cannot strand
        // anything, and covers the same three occupancy states the hold was added for.
        // The TAKEOVER hold (R26, above) stays: it is user-present and bounded.

        // E4 Stage 2 (task #40): the loop reclaims the E4-orphaned pod to dose, then
        // re-releases it for G7. Gated on the e4ReleasePod flag — when OFF, reclaim
        // returns connected=true immediately so the dosing path is byte-for-byte the
        // tagged baseline. When ON, the loan controller (which owns the OmniPumpManager)
        // does the bounded reconnect + settled re-release.
        // #101: unconditional. reclaimPodForDose already no-ops when the link is held
        // (guard isConnectionReleased → completion(true)), so this single wiring subsumes
        // both old E4 arms and can never strand a released bid (#97's failure mode).
        stack.loopManager.e4ReclaimPodForDose = { [weak self] completion in
            guard let self = self else { completion(false); return }
            self.loanController.reclaimPodForDose(completion)
        }
        stack.loopManager.e4ReleasePodAfterDose = { [weak self] in
            self?.loanController.releasePodAfterDose()
        }

        loanController.onLoanActiveChanged = { [weak self] active in
            guard let self = self else { return }
            if active {
                os_log("Loan active: starting G7 transport", log: self.log, type: .default)
                // R23's "every loan starts OPEN" reset was OVERTURNED 2026-08-04 (Jeremy):
                // the wrist inherits the phone's loop mode, applied from the grant in
                // PodLoanWatchController. Deliberately NOT re-asserted here — this callback
                // also fires on the hand-back-timeout resume path (:1284), where the user's
                // own choice for the session must survive rather than be reset under them.
                self.setKeepalive(true, reason: "soak")
                // H19: arm the loop-stall dead-man for the session; every live loop
                // cycle re-defers it (WatchLoopManager), so it fires only on a stall.
                LoopStallWatchdog.refresh()
                // WS4b: arm the sensor-blackout dead-man; every direct reading
                // re-defers it (WatchLoopManager CGM ingestion).
                SensorBlackoutAlert.refresh()
                // R23: the glance page is the landing surface during a loan.
                DispatchQueue.main.async { GlanceController.current?.becomeCurrentPage() }
                // Log pipeline v4: a 5-min PULSE independent of readings. The
                // per-reading transfer goes silent exactly when the session is dry —
                // twice (126, 127) a dead-G7 session was invisible until a manual
                // send. A dry session must still report itself.
                self.startLogPulse()
                // Suspension detector (2026-07-22). The +90s pod release firing 3m36s
                // late is what poisoned the BLE stack; that lateness had to be inferred
                // from clustered timestamps. Now it is measured.
                RuntimeStateLog.startHeartbeat()
            } else {
                os_log("Loan ended: stopping G7 transport", log: self.log, type: .default)
                self.setKeepalive(false, reason: "soak")
                LoopStallWatchdog.disarm()   // clean end — the loop stops on purpose
                SensorBlackoutAlert.disarm()
                self.stopLogPulse()
                RuntimeStateLog.stopHeartbeat()
                // PODLOAN diagnostics: queue the session log to the phone at every
                // loan end (queued transfer survives unreachability) — a deleted or
                // reinstalled app can no longer eat an unsent log (2026-07-19).
                self.sendLogSnapshot("loan end")
            }
        }

        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        SportLog.event("session", "Sport Mode ready — build \(build); tap Start to request a loan")
        // Name the policy at launch, same discipline as the old E4 arm line: a log that does
        // not say which policy produced it cannot be compared across builds.
        SportLog.event("policy", "link policy AUTOMATIC (#101): pod orphaned between doses, reclaim per cycle, acquisition-gated while un-adopted")
    }

    // MARK: Log pipeline v4 — event snapshots + loan pulse (2026-07-20)

    /// Queue the on-watch log to the phone NOW (WCSession queues transfers across
    /// unreachability). Event-driven — the reading-triggered transfer cannot be the
    /// only channel, because a dry session produces no readings and goes invisible.
    func sendLogSnapshot(_ reason: String) {
        guard WCSession.default.activationState == .activated, let url = LogFile.url else { return }
        SportLog.event("log", "snapshot → iPhone (\(reason))")
        WCSession.default.transferFile(url, metadata: ["kind": "g7watch.log"])
    }

    private var logPulse: DispatchSourceTimer?

    private func startLogPulse() {
        stopLogPulse()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(20))
        timer.setEventHandler { [weak self] in
            self?.sendLogSnapshot("loan pulse")
            // Keepalive self-heal (132, field 2026-07-20 evening): a dead
            // HKWorkoutSession previously waited for a FOREGROUND activation to be
            // re-asserted — a background session went reading-dead until the next
            // wrist raise. ensureRunning is refcount-aware and a no-op when healthy;
            // in background the restart attempt can fail (HK error 14) but logs the
            // evidence and heals at the first live moment instead of the next launch.
            self?.keepalive.ensureRunning()
        }
        timer.resume()
        logPulse = timer
    }

    private func stopLogPulse() {
        logPulse?.cancel()
        logPulse = nil
    }

    // MARK: E1 — standalone-G7 diagnostic mode (task #36, 2026-07-21)
    // Runs the G7 soak with NO pod loan and NO dosing: the ONLY BLE connection the
    // watch holds is the G7. Isolates whether holding the Omnipod link concurrently
    // starves G7 connects under watchOS's per-app BLE budget. Bench-only, firewalled:
    // takes no pod, enacts nothing, arms no dosing dead-mans — pure acquisition
    // telemetry (the same SportLog VALUE/observer/recreate lines) so the catch rate
    // is directly comparable to the b136 with-pod baseline (77%).
    private(set) var standaloneG7TestActive = false

    func startStandaloneG7Test() {
        guard !standaloneG7TestActive, !loanController.isLoanActive else { return }
        standaloneG7TestActive = true
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        SportLog.event("standalone", "=== STANDALONE G7 TEST START (E1, build \(build)) — no pod loan, no dosing — bench diagnostic ===")
        setKeepalive(true, reason: "soak")
        startLogPulse()   // flush every 5 min for an unattended multi-hour run
    }

    func stopStandaloneG7Test() {
        guard standaloneG7TestActive else { return }
        standaloneG7TestActive = false
        SportLog.event("standalone", "=== STANDALONE G7 TEST STOP ===")
        setKeepalive(false, reason: "soak")
        stopLogPulse()
        sendLogSnapshot("standalone test end")
    }

    /// Route a WC userInfo payload. Returns true when it was a v2 protocol message
    /// (consumed here); false lets the stock dispatch continue.
    func handleIncomingIfLoanMessage(_ userInfo: [String: Any]) -> Bool {
        guard userInfo[LoanProtocol.userInfoKey] != nil else { return false }
        loanController.handleIncoming(userInfo: userInfo)
        return true
    }

    /// Called on WCSession activation: a relaunch with undrained records sends the
    /// recovered hand-back (data-first; the session itself is never resurrected).
    func sessionDidActivate() {
        loanController.drainRecoveredIfNeeded()
    }
}
