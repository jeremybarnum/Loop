//
//  StockLoopSession.swift
//  WatchApp Extension
//
//  App-lifecycle OWNER of the assembled stock loop and the loan controller. ExtensionDelegate
//  holds one lazily; it stays inert — no radio, no dosing — until a loan grant arrives. CGM is
//  stock G7SensorKit and runs independently of the loan.
//

import Foundation
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

    init() {
        // The silent-death witness arms FIRST: MetricKit delivers held diagnostics at launch,
        // and a payload arriving while the stack is still wiring must not be missed.
        DeathBlackBox.shared.arm()
        // Link policy is automatic: orphan the pod between doses, reclaim every
        // cycle, and gate that reclaim on G7 acquisition state while the sensor is un-adopted.
        // Replaced a user toggle whose two arms were each wrong for acquisition — evidence in
        // docs/E4_TIME_SEPARATION.md.
        //
        // FakeGlucose and E5 substitute into the LIVE dosing path and their toggles are gone, so
        // neither may linger enabled in a real session. Both are trivially restored from git.
        FakeGlucose.setEnabled(false)
        UserDefaults.standard.set(false, forKey: "g7.e5RandomTemp")

        stack = StockLoopStack.assemble()
        loanController = PodLoanWatchController(loopManager: stack.loopManager)

        // Route the pod BLE layer into the watch's mirrored log. OmnipodKit logs via os_log,
        // which never reaches the file the field analysis reads. Watch only — the phone leaves the
        // sink nil and keeps os_log.
        PodLoanConnectClock.podLoanLogSink = { line in SportLog.event("pod-ble", line) }

        // The G7 radio census — names which of the three acquisition triggers fires
        // (system-connected piggyback / connection event / ad scan), D2W's rhythm, and connect
        // verdicts. Made the acquisition mechanism observed rather than inferred.
        // CENSUS THROTTLE. The radio census is 59% of a field log (2,363 of 3,941 lines on
        // 2026-08-21), and the log keeps only a trailing 512 KB — so at full volume it holds
        // ~4.6 days against a weekly cadence for seeing the user. A third of every interval was
        // being trimmed away, and it was always the OLDEST third, which is exactly where "when
        // did this start" lives.
        //
        // Steady state is what repeats: connect, didConnect, didDisconnect, disconnect, four
        // lines every five minutes forever, saying nothing that the first pair did not. Those
        // collapse into a periodic rollup. ANOMALIES ARE NEVER SUPPRESSED — a connect failure,
        // an auth error or a connection-limit refusal is the whole reason the census exists, and
        // 34 connection-limit failures in that same log were nearly missed because they render
        // as prose with no error code to grep for.
        //
        // SportLog's own repeat-suppression cannot do this: it collapses CONSECUTIVE identical
        // lines, and the census interleaves four different shapes per cycle.
        G7RadioCensus.sink = { line in CensusThrottle.emit(line) }
        // Sensor-switch detection: the radio names every G7 it sees; the loop manager keeps
        // the evidence and fires the #104 override when a different sensor is present while
        // the persisted one delivers nothing. Wired here because this is the one place that
        // holds both ends.
        G7RadioCensus.sensorSighted = { [weak self] name in self?.stack.loopManager.noteSensorSighted(name) }
        stack.loopManager.requestSensorRescan = { [weak self] in self?.stack.cgmManager.scanForNewSensor() }
        stack.loopManager.g7RadioSnapshot = { [weak self] in self?.stack.cgmManager.g7RadioSnapshot() }
        stack.loopManager.g7SessionLive = { [weak self] in self?.stack.cgmManager.isConnected ?? false }
        stack.loopManager.requestG7Recycle = { [weak self] in self?.stack.cgmManager.recycleG7ConnectForLab() }

        // Main-thread stall detector. Runs from LAUNCH and never stops, unlike the loan-scoped
        // heartbeat below: a wedged main thread is exactly the condition under which nothing else
        // in this app can report anything. One ping/second, silent while healthy.
        RuntimeStateLog.startMainStallDetector()

        // The one question the hand-back UI needs answered.
        loanController.isPhoneReachable = { WCSession.default.isReachable }

        // G7 window monitor: anchor the expected-burst clock on every direct reading.
        stack.loopManager.onDirectGlucose = { [weak self] date in
            DispatchQueue.main.async { self?.noteDirectReading(at: date) }
        }

        // The offer superseder's request-kind twin (#120 idiom): a request still queued for a
        // dark phone after the watch stops wanting it is a delayed detonator — delivered at
        // reunion inside the phone's 90 s freshness window, it re-grants over whatever loan
        // the watch is running by then (field 2026-08-31: ghost grant e276 against live e277).
        // Same safety rule as #120: never cancel a transfer already in flight.
        loanController.cancelQueuedLoanRequests = {
            let stale = WCSession.default.outstandingUserInfoTransfers.filter {
                LoanMessage.peekKind(transport: $0.userInfo) == "request" && !$0.isTransferring
            }
            stale.forEach { $0.cancel() }
            return stale.count
        }

        loanController.send = { [weak loanController] dictionary in
            // Two channels, chosen per message kind. transferUserInfo is queued and survives
            // reachability flaps and relaunches — the semantics the cursor/ID machinery assumes —
            // but it is non-urgent, which strands an interactive handshake. Those take sendMessage
            // and fall back to the queue on failure, so this is never less reliable.
            // See LoanMessage.isInteractiveHandshake for which kinds and why.
            let session = WCSession.default
            // Diagnosis gate (2026-09-04, see WCSilence): while the bench switch is on the watch
            // hands WatchConnectivity nothing at all, so a phone-away loan builds NO backlog.
            if WCSilence.shouldSuppress(enabled: WCSilence.enabled) {
                SportLog.event("wc", "SUPPRESSED (G7Lab.wcSilence) send \(dictionary.keys.joined(separator: ",")) — reachable \(session.isReachable) · backlog \(WCSilence.backlogSummary())")
                return
            }
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
                // Loop-Failure ladder (stock parity): every live cycle re-defers all four rungs.
                LoopStallWatchdog.refresh()
                SportLog.event("deadman", "ladder ARMED — 20/40m timeSensitive + 1/2h critical rungs [deadman]")
                // The glance page is the landing surface during a loan.
                DispatchQueue.main.async { GlanceController.current?.becomeCurrentPage() }
                // 5-min pulse independent of readings: the per-reading transfer goes silent
                // exactly when the session is dry, which is when we most need to hear from it.
                self.startLogPulse()
                // Suspension detector: a deferred pod release firing minutes late poisons the
                // BLE stack, and that lateness used to be inferable only from clustered timestamps.
                RuntimeStateLog.startHeartbeat()
            } else {
                os_log("Loan ended: stopping G7 transport", log: self.log, type: .default)
                self.setKeepalive(false, reason: "soak")
                LoopStallWatchdog.disarm()   // clean end — the phone's ladder re-arms at reclaim
                SportLog.event("deadman", "ladder CLEARED — loan ended, coverage transfers to the phone [deadman]")
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
                DispatchQueue.main.async { GlanceController.current?.refreshGlanceNow() }
            }
        }

        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        SportLog.event("session", "Sport Mode ready — build \(build); tap Start to request a loan")
        // Name the policy at launch: a log that does not say which policy produced it cannot be
        // compared across builds.
        SportLog.event("policy", "link policy AUTOMATIC (#101): pod orphaned between doses, reclaim per cycle, acquisition-gated while un-adopted")
    }

    // MARK: Log pipeline v4 — event snapshots + loan pulse (2026-07-20)

    /// Queue the on-watch log to the phone now; WCSession holds transfers across
    /// unreachability. Event-driven, because a dry session produces no readings to ride on.
    func sendLogSnapshot(_ reason: String) {
        guard WCSession.default.activationState == .activated, let url = LogFile.url else { return }
        // Reachability rides the pulse rather than getting a timer of its own. FIELD 2026-08-21:
        // a 25-minute glucose hole during a loan could not be explained afterwards, because
        // `reachable` is only ever sampled when something SENDS — and nothing sent for the whole
        // gap. Five of these pulse lines fell inside it, every one of them silent about the one
        // fact that would have separated "phone out of range" from "transport wedged".
        //
        // It costs no extra lines: the log rotates at 512 KB keeping only a tail, so a
        // once-a-minute heartbeat would push out the content worth keeping. This piggybacks.
        if WCSilence.shouldSuppress(enabled: WCSilence.enabled) {
            SportLog.event("log", "snapshot SUPPRESSED (G7Lab.wcSilence) (\(reason)) reachable=\(WCSession.default.isReachable) · backlog \(WCSilence.backlogSummary())")
            return
        }
        SportLog.event("log", "snapshot → iPhone (\(reason)) reachable=\(WCSession.default.isReachable)")
        WCSession.default.transferFile(url, metadata: ["kind": "g7watch.log"])
    }

    // MARK: WC silence (diagnosis) + G7 window monitor (2026-09-04)

    /// Bench switch `G7Lab.wcSilence`. While ON the watch hands WatchConnectivity NOTHING — no
    /// record streams, no offers, no status, no log snapshots — and at the moment it is switched
    /// on it cancels every queued transfer that is not already mid-flight.
    ///
    /// Why: every loan mute on record (her tennis and dinner, his breakfast, the 2026-09-03 night
    /// pair) ran with the phone UNREACHABLE, which is the one condition under which a loan builds
    /// a backlog of undeliverable transfers: a ~480 KB log file every 300 s pulse plus the record
    /// streams, all held by WCSession across unreachability AND across a force-quit. The
    /// force-quit test that night (00:36) left Dexcom dark with our process gone, so whatever
    /// blocks the sensor link survives our process — and this backlog is the only loan-created
    /// thing that does. Idle (no loan) and Dexcom-alone were clean in the same conditions.
    /// This switch removes exactly that condition and nothing else, so an A/B/A inside one
    /// phone-away loan can say whether it is the cause.
    ///
    /// Diagnosis only, not a product behaviour: records are journaled and unacked events resend
    /// by design, so nothing is lost, but the hand-back needs the switch OFF to deliver.
    enum WCSilence {
        static let key = "G7Lab.wcSilence"
        static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
        /// Pure: the gate's meaning, pinned so a test can hold it.
        static func shouldSuppress(enabled: Bool) -> Bool { enabled }

        @discardableResult
        static func cancelOutstanding() -> (userInfo: Int, files: Int) {
            let s = WCSession.default
            let ui = s.outstandingUserInfoTransfers.filter { !$0.isTransferring }
            let files = s.outstandingFileTransfers.filter { !$0.isTransferring }
            ui.forEach { $0.cancel() }
            files.forEach { $0.cancel() }
            let inFlight = (s.outstandingUserInfoTransfers.count - ui.count) + (s.outstandingFileTransfers.count - files.count)
            SportLog.event("lab", "WC SILENCE ON — cancelled \(ui.count) queued userInfo + \(files.count) queued file transfer(s); \(inFlight) mid-flight left alone")
            return (ui.count, files.count)
        }

        static func backlogSummary() -> String {
            let s = WCSession.default
            return "userInfo=\(s.outstandingUserInfoTransfers.count) files=\(s.outstandingFileTransfers.count)"
        }
    }

    /// One `[g7-window]` line per EXPECTED sensor burst, HIT or MISS, so a mute reads out of the
    /// log as a table instead of being rebuilt by hand against the Mac scanner. Anchored on the
    /// sensor's own phase: each direct reading marks a window, and the next verdict is due one
    /// period later; on a miss the chain keeps firing every period from the last known phase,
    /// which is exactly when the sensor keeps bursting.
    enum G7WindowPolicy {
        static let period: TimeInterval = 300
        /// The burst lasts 3–7 s and the reading lands 2–8 s after it starts; a reading that
        /// arrives up to a minute late (a between-burst connect, 2026-09-03 23:37:36) still
        /// belongs to that window rather than to no window.
        static let early: TimeInterval = 12
        static let late: TimeInterval = 72
        /// When to pass verdict on the burst expected one period after `anchor`.
        static func nextVerdict(after anchor: Date) -> Date { anchor.addingTimeInterval(period + late) }
        /// Pure: does a reading at `lastDirect` count as this window's?
        static func verdict(lastDirect: Date?, expectedBurst: Date) -> String {
            guard let d = lastDirect else { return "MISS" }
            let dt = d.timeIntervalSince(expectedBurst)
            return (dt >= -early && dt <= late) ? "HIT" : "MISS"
        }
    }

    private var windowTimer: DispatchSourceTimer?
    private var windowAnchor: Date?     // last direct reading, or the last expected burst while missing
    private var lastDirectAt: Date?

    private func noteDirectReading(at date: Date) {
        lastDirectAt = date
        if let anchor = windowAnchor {
            let expected = anchor.addingTimeInterval(G7WindowPolicy.period)
            if G7WindowPolicy.verdict(lastDirect: date, expectedBurst: expected) == "HIT" {
                logWindowVerdict("HIT", expectedBurst: expected)
            }
        }
        windowAnchor = date
        armWindowVerdict()
    }

    private func armWindowVerdict() {
        windowTimer?.cancel()
        guard let anchor = windowAnchor else { return }
        let expected = anchor.addingTimeInterval(G7WindowPolicy.period)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + max(1, G7WindowPolicy.nextVerdict(after: anchor).timeIntervalSinceNow), leeway: .seconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let v = G7WindowPolicy.verdict(lastDirect: self.lastDirectAt, expectedBurst: expected)
            // A HIT was already logged on arrival; only a MISS is news here, and it re-arms the
            // chain on the sensor's phase rather than on our clock.
            if v == "MISS" {
                self.logWindowVerdict("MISS", expectedBurst: expected)
                self.windowAnchor = expected
                self.armWindowVerdict()
            }
        }
        t.resume()
        windowTimer = t
    }

    private func logWindowVerdict(_ verdict: String, expectedBurst: Date) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        SportLog.event("g7-window", "\(verdict) burst ~\(f.string(from: expectedBurst)) · \(stack.cgmManager.g7RadioSnapshot() ?? "n/a") · wc reachable=\(WCSession.default.isReachable) backlog \(WCSilence.backlogSummary()) silence=\(WCSilence.enabled) · loan=\(loanController.isLoanActive)")
    }

    private var logPulse: DispatchSourceTimer?

    private func startLogPulse() {
        stopLogPulse()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(20))
        timer.setEventHandler { [weak self] in
            self?.sendLogSnapshot("loan pulse")
            // [g7-drought] on the PULSE, not the cycle (field 2026-09-03 08:41-09:21): with no
            // glucose there is no cycle, so the cycle-bound census logged nothing for the whole
            // 40-minute mute it was built for. The pulse fires every 300 s for as long as the
            // loan lives, glucose or not.
            if let mgr = self?.stack.loopManager, let age = mgr.latestGlucoseAge, age > .minutes(7) {
                SportLog.event("g7-drought", "glucose age \(Int(age))s · \(self?.stack.cgmManager.g7RadioSnapshot() ?? "n/a") · reachable=\(WCSession.default.isReachable)")
            }
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
    func sessionDidActivate() {
        loanController.drainRecoveredIfNeeded()
    }
}


/// Collapses the radio census's steady-state repetition while letting every anomaly through.
///
/// Shape-based, not text-based: the sensor name, RSSI and counters vary line to line, so the
/// throttle normalises those away and rate-limits what remains. A shape seen within the window
/// is counted rather than written; the count is flushed with the next line of that shape, so a
/// rollup never strands a number nobody ever sees.
enum CensusThrottle {
    private static let lock = NSLock()
    private static var lastEmitted: [String: Date] = [:]
    private static var suppressed: [String: Int] = [:]

    /// One G7 cadence period plus margin. Long enough that routine cycles collapse, short enough
    /// that a shape which is genuinely churning still shows a heartbeat.
    private static let window: TimeInterval = 6 * 60

    /// Anything that smells like a failure bypasses the throttle entirely. Deliberately generous:
    /// the cost of letting a line through is one line, and the cost of suppressing the wrong one
    /// is a diagnosis we cannot make a week later.
    private static func isAnomaly(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains("error") || l.contains("fail") || l.contains("maximum number")
            || l.contains("timed out") || l.contains("unexpected") || l.contains("encrypt")
    }

    private static func shape(of line: String) -> String {
        var s = line
        // Sensor names, signal strengths and counts are the varying parts; the SHAPE is what
        // repeats. Collapsing them is what lets four-lines-per-cycle become one-per-window.
        if let r = s.range(of: "DXCM[A-Za-z0-9]+", options: .regularExpression) {
            s.replaceSubrange(r, with: "SENSOR")
        }
        s = s.replacingOccurrences(of: "-?[0-9]+", with: "N", options: .regularExpression)
        return s
    }

    static func emit(_ line: String) {
        guard !isAnomaly(line) else { SportLog.event("g7-ble", line); return }

        let key = shape(of: line)
        let now = Date()
        var pending = 0
        var write = false

        lock.lock()
        if let last = lastEmitted[key], now.timeIntervalSince(last) < window {
            suppressed[key, default: 0] += 1
        } else {
            pending = suppressed.removeValue(forKey: key) ?? 0
            lastEmitted[key] = now
            write = true
        }
        lock.unlock()

        guard write else { return }
        SportLog.event("g7-ble", pending > 0 ? "\(line)  [+\(pending) like this suppressed]" : line)
    }
}
