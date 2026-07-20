//
//  StockLoopSession.swift
//  WatchApp Extension
//
//  M5 integration: the app-lifecycle OWNER of the assembled stock loop and the loan
//  controller (resolves M4's "assemble() has no call sites"). ExtensionDelegate holds
//  one of these lazily; it stays inert (no radio, no dosing) until a loan grant
//  arrives — the G7 transport starts when the loan becomes ACTIVE and stops when the
//  pod is released (closedDirect is the only ruled dosing mode wired so far; the
//  R20 picker adds the others at the UI layer).
//

import Foundation
import WatchConnectivity
import os.log

final class StockLoopSession {

    let stack: StockLoopStack.Stack
    let loanController: PodLoanWatchController

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "StockLoopSession")

    init() {
        stack = StockLoopStack.assemble()
        loanController = PodLoanWatchController(loopManager: stack.loopManager)

        loanController.send = { dictionary in
            // transferUserInfo: queued, survives reachability flaps and relaunches —
            // the delivery semantics the protocol's cursor/IDs are built around.
            let session = WCSession.default
            SportLog.event("wc", "send \(dictionary.keys.joined(separator: ",")) — session \(session.activationState.rawValue), reachable \(session.isReachable)")
            session.transferUserInfo(dictionary)
        }

        // Fix B (radio arbiter, c6c9e18f port): BG wins the single watch radio — loop
        // pod commands and the quiet verdict chase yield to an active G7 handshake.
        let radioBusy: () -> Bool = { [weak self] in self?.stack.client.isHandshakeActive ?? false }
        stack.loopManager.isRadioBusy = radioBusy
        loanController.isRadioBusy = radioBusy

        // R26 (reverse arbiter): the pod TAKEOVER outranks the G7 — during its
        // bounded ~40s ladder, G7 scans stop and new attempts defer. Field
        // 2026-07-20: takeovers failed inside G7 scan/handshake windows and
        // succeeded the moment the radio freed.
        loanController.onTakeoverRadioHold = { [weak self] holding in
            self?.stack.client.setPodTakeoverHold(holding)
            // Log pipeline v4: snapshot at takeover start (grant picture) and at the
            // verdict — the ~40s window that decides a session, captured either way.
            self?.sendLogSnapshot(holding ? "takeover start" : "takeover verdict")
        }

        loanController.onLoanActiveChanged = { [weak self] active in
            guard let self = self else { return }
            if active {
                os_log("Loan active: starting G7 transport", log: self.log, type: .default)
                // R23 confidence model: every loan starts OPEN (advisory); the user
                // closes the loop deliberately from the glance screen.
                self.stack.loopManager.setClosedLoopEnabled(false)
                self.stack.client.prewarmIfPending()
                self.stack.client.startSoak()
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
            } else {
                os_log("Loan ended: stopping G7 transport", log: self.log, type: .default)
                self.stack.client.stopSoak()
                LoopStallWatchdog.disarm()   // clean end — the loop stops on purpose
                SensorBlackoutAlert.disarm()
                self.stopLogPulse()
                // PODLOAN diagnostics: queue the session log to the phone at every
                // loan end (queued transfer survives unreachability) — a deleted or
                // reinstalled app can no longer eat an unsent log (2026-07-19).
                self.sendLogSnapshot("loan end")
            }
        }

        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        SportLog.event("session", "Sport Mode ready — build \(build); tap Start to request a loan")
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
        timer.setEventHandler { [weak self] in self?.sendLogSnapshot("loan pulse") }
        timer.resume()
        logPulse = timer
    }

    private func stopLogPulse() {
        logPulse?.cancel()
        logPulse = nil
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
