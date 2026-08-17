//
//  StockLoopSession.swift
//  WatchApp Extension
//
//  App-lifecycle OWNER of the assembled stock loop and the loan controller. ExtensionDelegate
//  holds one lazily; it stays inert — no radio, no dosing — until a loan grant arrives. CGM is
//  stock G7SensorKit and runs independently of the loan.
//

import Foundation
import LoopCore
import OmnipodKit
import G7SensorKit        // PodLoanConnectClock.podLoanLogSink (pod BLE layer -> watch log)
import WatchConnectivity
import os.log

final class StockLoopSession {

    let stack: StockLoopStack.Stack

    /// Background runtime for the whole session.
    ///
    /// watchOS suspends a third-party app seconds after the wrist drops, and there is NO
    /// CoreBluetooth state restoration on watchOS — a suspended app cannot be woken by a BLE
    /// event. An HKWorkoutSession is the only self-service API that keeps the process and its BLE
    /// links alive. Riding the Dexcom watch app's session buys DATA, not RUNTIME: entitlements are
    /// not inheritable by a co-resident app.
    ///
    /// Refcounted by reason ("soak", "takeover", "handback") so overlapping holds cannot end the
    /// session early.
    private let keepalive = WorkoutKeepalive()

    private func setKeepalive(_ holding: Bool, reason: String) {
        holding ? keepalive.acquire(reason) : keepalive.release(reason)
    }

    /// Re-assert the session if something still wants it. Called on every foreground: the one
    /// moment we KNOW we are executing, since the only other re-assert path is a timer that cannot
    /// fire while suspended. No-op when nothing holds it.
    func ensureKeepalive() { keepalive.ensureRunning() }
    let loanController: PodLoanWatchController

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "StockLoopSession")

    init?() async {
        // Link policy is automatic: orphan the pod between doses, reclaim every
        // cycle, and gate that reclaim on G7 acquisition state while the sensor is un-adopted.
        // Replaced a user toggle whose two arms were each wrong for acquisition — evidence in
        // docs/E4_TIME_SEPARATION.md.
        //
        // FakeGlucose and E5 substitute into the LIVE dosing path and their toggles are gone, so
        // neither may linger enabled in a real session. Both are trivially restored from git.
        FakeGlucose.setEnabled(false)
        UserDefaults.standard.set(false, forKey: "g7.e5RandomTemp")

        guard let assembled = await StockLoopStack.assemble() else { return nil }
        stack = assembled
        loanController = PodLoanWatchController(loopManager: stack.loopManager)

        // Route the pod BLE layer into the watch's mirrored log. OmnipodKit logs via os_log,
        // which never reaches the file the field analysis reads. Watch only — the phone leaves the
        // sink nil and keeps os_log.
        PodLoanConnectClock.podLoanLogSink = { line in SportLog.event("pod-ble", line) }

        // The G7 radio census — names which of the three acquisition triggers fires
        // (system-connected piggyback / connection event / ad scan), D2W's rhythm, and connect
        // verdicts. Made the acquisition mechanism observed rather than inferred.
        G7RadioCensus.sink = { line in SportLog.event("g7-ble", line) }

        // Main-thread stall detector. Runs from LAUNCH and never stops, unlike the loan-scoped
        // heartbeat below: a wedged main thread is exactly the condition under which nothing else
        // in this app can report anything. One ping/second, silent while healthy.
        RuntimeStateLog.startMainStallDetector()

        // The one question the hand-back UI needs answered.
        loanController.isPhoneReachable = { WCSession.default.isReachable }

        loanController.send = { [weak loanController] dictionary in
            // Two channels, chosen per message kind. transferUserInfo is queued and survives
            // reachability flaps and relaunches — the semantics the cursor/ID machinery assumes —
            // but it is non-urgent, which strands an interactive handshake. Those take sendMessage
            // and fall back to the queue on failure, so this is never less reliable.
            // See LoanMessage.isInteractiveHandshake for which kinds and why.
            let session = WCSession.default
            let urgent = LoanMessage.isInteractiveHandshake(transport: dictionary) && session.isReachable
            SportLog.event("wc", "send \(dictionary.keys.joined(separator: ",")) — session \(session.activationState.rawValue), reachable \(session.isReachable), path \(urgent ? "urgent" : "queued")")

            // AT MOST ONE QUEUED OFFER. The resend loop re-offers every 15 s and
            // transferUserInfo queues every call separately, so an unreachable phone accumulated
            // one copy per 15 s — a dozen in one observed case — delivered as a burst at wake,
            // which is the flood defended against downstream. Supersede at the source: when
            // enqueueing a NEW offer, cancel the still-undelivered PREVIOUS offer transfers.
            //
            // ORDER IS LOAD-BEARING, in both directions. Capture the stale list BEFORE enqueueing
            // (outstandingUserInfoTransfers includes the new transfer immediately, and cancelling
            // that would leave ZERO queued offers — the first cut of this code had exactly that
            // bug); cancel AFTER enqueueing, so the queue is never empty in between and the worst
            // case is both copies delivering — the already-idempotent case. ONLY offers are ever
            // cancelled: they are resent by design, so a cancelled one is replaced within 15 s;
            // record streams and status messages are one-shot and are never touched.
            let enqueueSuperseding = { (payload: [String: Any]) in
                let isOffer = LoanMessage.peekKind(transport: payload) == "handbackOffer"
                let stale = isOffer
                    ? session.outstandingUserInfoTransfers.filter {
                        LoanMessage.peekKind(transport: $0.userInfo) == "handbackOffer"
                      }
                    : []
                session.transferUserInfo(payload)
                let cancelled = stale.filter { !$0.isTransferring }
                guard !cancelled.isEmpty else { return }
                cancelled.forEach { $0.cancel() }
                SportLog.event("wc", "superseded \(cancelled.count) queued offer(s) with the fresh one (#120)")
            }

            guard urgent else {
                enqueueSuperseding(dictionary)
                return
            }
            session.sendMessage(dictionary, replyHandler: nil, errorHandler: { error in
                SportLog.event("wc", "urgent send FAILED (\(error.localizedDescription)) — falling back to the queued path")
                loanController?.noteUrgentSendFailed()   // an erroring send means the link is re-establishing, not one-way wedged
                enqueueSuperseding(dictionary)
            })
        }

        // NO RADIO ARBITER, deliberately. It made pod commands yield to our own G7 reader's
        // scan/handshake; that reader is gone, and its flags were the arbiter's only
        // producer.
        //
        // Not because the app stopped using the sensor radio — stock G7SensorKit still runs its
        // own CBCentralManager in-process. What is gone is any signal about WHEN, plus the
        // component that was actually starving the pod. Whether stock's scanning contends the same
        // way is UNMEASURED; one 30-minute run says no, which is not a proof.

        stack.loopManager.podBeepsOnManualBolusProbe = { [weak self] in
            self?.loanController.podBeepsOnManualBolus ?? false
        }

        // The takeover ladder needs background runtime — fires true on entering .takingOver
        // and false on every exit, so it spans exactly the ladder. Without it the poll is throttled
        // the moment the wrist drops and the read budget burns on wall-clock instead of attempts.
        loanController.onTakeoverRadioHold = { [weak self] holding in
            self?.setKeepalive(holding, reason: "takeover")
            // Log pipeline v4: snapshot at takeover start (grant picture) and at the
            // verdict — the ~40s window that decides a session, captured either way.
            self?.sendLogSnapshot(holding ? "takeover start" : "takeover verdict")
        }

        // Hand-back needs the same runtime: without it the watch stops being reachable when the
        // wrist drops after End, the phone's ack falls to the queued channel, and the pod stays
        // held until iOS delivers it.
        loanController.onHandbackRuntimeHold = { [weak self] holding in
            self?.setKeepalive(holding, reason: "handback")
            SportLog.event("loan", holding
                ? "hand-back runtime hold ACQUIRED — staying reachable for the phone's ack"
                : "hand-back runtime hold released")
        }

        // The dose-window stand-down is deliberately NOT wired — it stranded
        // the radio for 2.9 h overnight (app suspended mid-ladder holding the sensor off, no BLE
        // event left to wake it). The takeover hold above stays: user-present and bounded.

        // Reclaim the orphaned pod to dose, then re-release it for G7. Unconditional on both
        // sides: reclaimPodForDose already no-ops when the link is held, so one wiring
        // covers every case and can never strand a released bid.
        stack.loopManager.reclaimPodForDose = { [weak self] completion in
            guard let self = self else { completion(false); return }
            self.loanController.reclaimPodForDose(completion)
        }
        stack.loopManager.releasePodAfterDose = { [weak self] in
            self?.loanController.releasePodAfterDose()
        }

        loanController.onLoanActiveChanged = { [weak self] active in
            guard let self = self else { return }
            if active {
                os_log("Loan active: starting G7 transport", log: self.log, type: .default)
                // The wrist inherits the phone's loop mode from the grant.
                // Deliberately NOT re-asserted here: this also fires on the
                // hand-back-timeout resume path, where the user's own choice must survive.
                self.setKeepalive(true, reason: "soak")
                // Loop-stall dead-man: every live cycle re-defers it, so it fires only on a stall.
                LoopStallWatchdog.refresh()
                // Sensor-blackout dead-man: every direct reading re-defers it.
                SensorBlackoutAlert.refresh()
                // The glance page is the landing surface during a loan.
                NotificationCenter.default.post(name: .podLoanPhaseDidChange, object: nil)
                // 5-min pulse independent of readings: the per-reading transfer goes silent
                // exactly when the session is dry, which is when we most need to hear from it.
                self.startLogPulse()
                // Suspension detector: a deferred pod release firing minutes late poisons the
                // BLE stack, and that lateness used to be inferable only from clustered timestamps.
                RuntimeStateLog.startHeartbeat()
            } else {
                os_log("Loan ended: stopping G7 transport", log: self.log, type: .default)
                self.setKeepalive(false, reason: "soak")
                LoopStallWatchdog.disarm()   // clean end — the loop stops on purpose
                SensorBlackoutAlert.disarm()
                self.stopLogPulse()
                RuntimeStateLog.stopHeartbeat()
                // Queue the session log at every loan end, so a deleted or reinstalled app
                // cannot eat it.
                self.sendLogSnapshot("loan end")
                // Loop mode is PER-SESSION: the next grant re-asserts it from the phone's
                // inheritance, so a "closed" left over from this session must not survive —
                // stale, it makes an open-inheriting grant read as a closed→open transition
                // and fire the temp cancel during grant intake, at a pod mid-takeover.
                self.stack.loopManager.resetClosedLoopForSessionEnd()
                // The start branch lands the user ON the glance; the end branch must at
                // least repaint it. The 2 s tick dies on a screen dim and a bare undim does
                // not revive it, so a phone-initiated revoke arriving in that gap goes
                // unpainted — the glance holds its last active-loan frame, which reads as
                // two devices both in control, until a swipe forces an appearance event
                // (field, 2026-08-14). One render, no timer re-arm: the page may be hidden,
                // and a hidden page must not tick.
                NotificationCenter.default.post(name: .podLoanPhaseDidChange, object: nil)
            }
        }

        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        SportLog.event("session", "Sport Mode ready — build \(build); tap Start to request a loan")
        startLinkCensus()
        // Name the policy at launch: a log that does not say which policy produced it cannot be
        // compared across builds.
        SportLog.event("policy", "link policy AUTOMATIC (#101): pod orphaned between doses, reclaim per cycle, acquisition-gated while un-adopted")
    }

    // MARK: Log pipeline v4 — event snapshots + loan pulse (2026-07-20)

    /// Queue the on-watch log to the phone now; WCSession holds transfers across
    /// unreachability. Event-driven, because a dry session produces no readings to ride on.
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
            // Keepalive self-heal: a dead HKWorkoutSession used to wait for a FOREGROUND
            // activation, so a background session went reading-dead until the next wrist raise.
            // ensureRunning is refcount-aware and a no-op when healthy.
            self?.keepalive.ensureRunning()
        }
        timer.resume()
        logPulse = timer
    }

    private func stopLogPulse() {
        logPulse?.cancel()
        logPulse = nil
    }

    // MARK: Standalone-G7 diagnostic mode
    // Runs the G7 soak with no pod loan and no dosing, so the G7 is the only BLE connection the
    // watch holds. Isolates whether holding the pod link starves G7 connects under watchOS's
    // per-app BLE budget. Bench-only and firewalled: takes no pod, enacts nothing, arms no
    // dosing dead-mans.
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
    func handleIncomingIfLoanMessage(_ userInfo: [String: Any], channel: LoanTransportChannel) -> Bool {
        guard userInfo[LoanProtocol.userInfoKey] != nil else { return false }
        loanController.handleIncoming(userInfo: userInfo, channel: channel)
        return true
    }

    /// Called on WCSession activation: a relaunch with undrained records sends the
    /// recovered hand-back (data-first; the session itself is never resurrected).
    /// LINK CENSUS — one line a minute saying whether this watch can see the phone.
    ///
    /// Reachability is only ever logged today as a side effect of a SEND, so the record has
    /// gaps exactly where nothing was being sent — and "the watch went quiet" and "the watch
    /// could not reach the phone" are indistinguishable in the log. A fixed cadence makes the
    /// link's state readable across a whole session, including the stretches where nothing
    /// happened, which is what a correlation against takeover and settle timings needs.
    ///
    /// Deliberately unconditional on a loan: the interesting window includes before Start and
    /// after hand-back.
    private var linkCensusTimer: DispatchSourceTimer?

    private func startLinkCensus() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        t.setEventHandler {
            let s = WCSession.default
            SportLog.event("link", "phone reachable=\(s.isReachable) activation=\(s.activationState.rawValue) companionInstalled=\(s.isCompanionAppInstalled)")
        }
        t.resume()
        linkCensusTimer = t
    }

    func sessionDidActivate() {
        loanController.drainRecoveredIfNeeded()
    }
}
