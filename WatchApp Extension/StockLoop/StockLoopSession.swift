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
import G7SensorKit
import WatchConnectivity
import os.log

final class StockLoopSession {
    let stack: StockLoopStack.Stack

    private let keepalive = WorkoutKeepalive()

    static let loanWorkoutKey = "G7Lab.loan.workout"
    static var loanWorkout: Bool { UserDefaults.standard.bool(forKey: loanWorkoutKey) }

    private func setKeepalive(_ holding: Bool, reason: String) {
        if reason == "loanWorkout", !Self.loanWorkout {
            SportLog.event("keepalive", "loan workout holder \(holding ? "not held" : "release ignored") — no workout session during loans (Diagnostics ▸ Pod loan); the app sleeps between bursts")
            keepalive.release(reason)
            return
        }
        holding ? keepalive.acquire(reason) : keepalive.release(reason)
    }

    func ensureKeepalive() { keepalive.ensureRunning() }
    let loanController: PodLoanWatchController

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "StockLoopSession")

    init?() async {
        guard let assembled = await StockLoopStack.assemble() else { return nil }
        stack = assembled
        loanController = PodLoanWatchController(loopManager: stack.loopManager)

        PodLoanConnectClock.podLoanLogSink = { line in SportLog.event("pod-ble", line) }

        RuntimeStateLog.startMainStallDetector()

        loanController.isPhoneReachable = { WCSession.default.isReachable }
        stack.loopManager.onCycleLanded = { [weak loanController] in loanController?.renewHold() }

        loanController.cancelQueuedLoanRequests = {
            let stale = WCSession.default.outstandingUserInfoTransfers.filter {
                LoanMessage.peekKind(transport: $0.userInfo) == "request" && !$0.isTransferring
            }
            stale.forEach { $0.cancel() }
            return stale.count
        }

        loanController.send = { [weak loanController] dictionary in

            let session = WCSession.default

            let wedged = loanController?.urgentSendWedged ?? false
            let urgent = LoanMessage.isInteractiveHandshake(transport: dictionary)
                && session.isReachable && !wedged
            SportLog.event("wc", "send \(dictionary.keys.joined(separator: ",")) — session \(session.activationState.rawValue), reachable \(session.isReachable), path \(urgent ? "urgent" : "queued")")

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

            let urgentOnly = dictionary["urgentOnly"] as? Bool == true
            guard urgent else {
                if urgentOnly {
                    SportLog.event("wc", "live hand-back offer NOT queued — urgent path unavailable (reachable \(session.isReachable), wedged \(wedged)); the resend loop retries")
                    return
                }
                enqueueSuperseding(dictionary)
                return
            }
            session.sendMessage(dictionary, replyHandler: nil, errorHandler: { error in
                loanController?.noteUrgentSendFailed()
                if urgentOnly {
                    SportLog.event("wc", "urgent send FAILED (\(error.localizedDescription)) — live hand-back offer NOT queued; the resend loop retries")
                    return
                }
                SportLog.event("wc", "urgent send FAILED (\(error.localizedDescription)) — falling back to the queued path")
                enqueueSuperseding(dictionary)
            })
        }

        stack.loopManager.podBeepsOnManualBolusProbe = { [weak self] in
            self?.loanController.podBeepsOnManualBolus ?? false
        }

        loanController.onTakeoverRadioHold = { [weak self] holding in
            self?.setKeepalive(holding, reason: "takeover")

            self?.sendLogSnapshot(holding ? "takeover start" : "takeover verdict")
        }

        loanController.onHandbackRuntimeHold = { [weak self] holding in
            self?.setKeepalive(holding, reason: "handback")
            SportLog.event("loan", holding
                ? "hand-back runtime hold ACQUIRED — staying reachable for the phone's ack"
                : "hand-back runtime hold released")
        }

        loanController.onLoanActiveChanged = { [weak self] active in
            guard let self = self else { return }
            if active {
                os_log("Loan active: starting G7 transport", log: self.log, type: .default)

                self.setKeepalive(true, reason: "loanWorkout")

                LoopStallWatchdog.refresh()
                SportLog.event("deadman", "ladder ARMED — 20/40m timeSensitive + 1/2h critical rungs [deadman]")

                NotificationCenter.default.post(name: .podLoanPhaseDidChange, object: nil)

                self.startLogPulse()

                RuntimeStateLog.startHeartbeat()
            } else {
                os_log("Loan ended: stopping G7 transport", log: self.log, type: .default)
                self.setKeepalive(false, reason: "loanWorkout")
                LoopStallWatchdog.disarm()
                SportLog.event("deadman", "ladder CLEARED — loan ended, coverage transfers to the phone [deadman]")
                self.stopLogPulse()
                RuntimeStateLog.stopHeartbeat()

                self.sendLogSnapshot("loan end")

                self.stack.loopManager.resetClosedLoopForSessionEnd()

                NotificationCenter.default.post(name: .podLoanPhaseDidChange, object: nil)
            }
        }

        loanController.resumeIfNeeded()

        let build = BuildDetails.default.codeIdentity
        SportLog.event("session", "Sport Mode ready — build \(build); tap Start to request a loan\(Self.launchForensics())")
        startLinkCensus()

        SportLog.event("policy", "link policy AUTOMATIC (#101): pod orphaned between doses, reclaim per cycle, acquisition-gated while un-adopted")
    }

    private static let previousLaunchKey = "SportMode.previousLaunchAt"

    private static func launchForensics() -> String {
        let now = Date()
        let previous = UserDefaults.standard.object(forKey: previousLaunchKey) as? Date
        UserDefaults.standard.set(now, forKey: previousLaunchKey)
        let sincePrevious = previous.map { String(format: "%.0fs", now.timeIntervalSince($0)) } ?? "first"
        return " · sincePrevLaunch=\(sincePrevious) footprint=\(residentFootprint())"
    }

    private static func residentFootprint() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return "?" }
        return String(format: "%.0fMB", Double(info.phys_footprint) / 1024 / 1024)
    }

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

            self?.keepalive.ensureRunning()
        }
        timer.resume()
        logPulse = timer
    }

    private func stopLogPulse() {
        logPulse?.cancel()
        logPulse = nil
    }

    func handleIncomingIfLoanMessage(_ userInfo: [String: Any], channel: LoanTransportChannel) -> Bool {
        guard userInfo[LoanProtocol.userInfoKey] != nil else { return false }
        loanController.handleIncoming(userInfo: userInfo, channel: channel)
        return true
    }

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
