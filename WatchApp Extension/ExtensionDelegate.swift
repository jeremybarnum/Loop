//
//  ExtensionDelegate.swift
//  WatchApp Extension
//
//  Created by Nathan Racklyeft on 8/29/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import WatchConnectivity
import WatchKit
import HealthKit
import Intents
import os
import os.log
import UserNotifications
import LoopKit
import Combine


final class ExtensionDelegate: NSObject, WKExtensionDelegate {
    private(set) lazy var loopManager = LoopDataManager()

    /// The pod loan lives here — at app scope — NOT inside the pod-control screen,
    /// so that dismissing that screen (the X) can't deallocate the loan and its
    /// live BLE connection to the pod, which would orphan the pod (see B1 in
    /// docs/LIVE_TEST_FINDINGS.md). The screen is only a view of this state.
    private(set) lazy var podLoanCoordinator = WatchPodLoanCoordinator()
    /// The single source of the watch's current Show Mode prediction (the
    /// LoopDataManager analog): observes glucose/carb/journal/settings/phase,
    /// recomputes one prediction, posts one didUpdate. Read by both HUD pages
    /// and the auto-loop.
    private(set) lazy var predictionStore = WatchPredictionStore(loopManager: loopManager, coordinator: podLoanCoordinator)

    /// The closed-loop policy layer — consumes the store's recommendation.
    private(set) lazy var autoLoop = WatchAutoLoop(store: predictionStore, coordinator: podLoanCoordinator)

    /// Phone-free CGM: the G7 direct-connect reader injects live EGVs into the loop's glucose store.
    private(set) lazy var g7 = G7GlucoseManager(loopManager: loopManager, predictionStore: predictionStore)

    private let log = OSLog(category: "ExtensionDelegate")

    private var observers: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var loanPhasePushCancellable: AnyCancellable?
    private var complicationReloadObserver: NSObjectProtocol?

    static func shared() -> ExtensionDelegate {
        return WKExtension.shared().extensionDelegate
    }

    override init() {
        super.init()

        let session = WCSession.default
        session.delegate = self

        // It seems, according to [this sample code](https://developer.apple.com/library/prerelease/content/samplecode/QuickSwitch/Listings/QuickSwitch_WatchKit_Extension_ExtensionDelegate_swift.html#//apple_ref/doc/uid/TP40016647-QuickSwitch_WatchKit_Extension_ExtensionDelegate_swift-DontLinkElementID_8)
        // that WCSession activation and delegation and WKWatchConnectivityRefreshBackgroundTask don't have any determinism,
        // and that KVO is the "recommended" way to deal with it.
        observers.append(session.observe(\WCSession.activationState) { [weak self] (session, change) in
            self?.log.default("WCSession.applicationState did change to %d", session.activationState.rawValue)

            DispatchQueue.main.async {
                self?.completePendingConnectivityTasksIfNeeded()
            }
        })
        observers.append(session.observe(\WCSession.hasContentPending) { [weak self] (session, change) in
            self?.log.default("WCSession.hasContentPending did change to %d", session.hasContentPending)

            DispatchQueue.main.async {
                self?.loopManager.sendDidUpdateContextNotificationIfNecessary()
                self?.completePendingConnectivityTasksIfNeeded()
            }
        })

        notifications.append(NotificationCenter.default.addObserver(forName: LoopDataManager.didUpdateContextNotification, object: loopManager, queue: nil) { [weak self] (_) in
            DispatchQueue.main.async {
                self?.loopManagerDidUpdateContext()
            }
        })

        session.activate()
    }

    deinit {
        for notification in notifications {
            NotificationCenter.default.removeObserver(notification)
        }
    }

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        if #available(watchOSApplicationExtension 5.0, *) {
            INRelevantShortcutStore.default.registerShortcuts()
        }
        // Warm the prediction store and open-loop layer now so they're live
        // before the first Show Mode activation (lazy creation could miss the
        // .active transition and the early recommendation trail). Cheap: they
        // do nothing until a session is active.
        _ = predictionStore
        _ = autoLoop
        g7.start()   // phone-free: begin the G7 reader (pending-connect reacquire + workout keepalive)

        // 3b v2.1: PUSH the Show-Mode status to the phone on phase TRANSITIONS (grant/end) so
        // its tile updates immediately — the user just watched Show Mode activate on the wrist;
        // the phone shouldn't take a poll interval to agree. The poll stays the steady state
        // (watch remains timer-free); this is edge-triggered only.
        loanPhasePushCancellable = podLoanCoordinator.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.pushLoanStatusToPhone(active: phase == .active)
            }

        // P1#11 — in Sport Mode the phone stops pushing context, so nothing reloads
        // the complication. Reload it on each watch-local prediction update (a fresh
        // direct-G7 reading recomputes the store) so the wrist face tracks the real
        // sensor instead of freezing on the last phone value.
        complicationReloadObserver = NotificationCenter.default.addObserver(
            forName: WatchPredictionStore.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.podLoanCoordinator.phase == .active else { return }
            self.reloadComplications()
        }
    }

    private func pushLoanStatusToPhone(active: Bool) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let status = WatchLoanStatusUserInfo(holdsPod: active,
                                             podConnected: podLoanCoordinator.podConnected)
        if session.isReachable {
            session.sendMessage(status.rawValue, replyHandler: nil, errorHandler: { _ in
                session.transferUserInfo(status.rawValue)   // fall back to the queued channel
            })
        } else {
            session.transferUserInfo(status.rawValue)       // delivers on next contact
        }
        log.default("pushed Show-Mode status to phone (active=%d)", active ? 1 : 0)
    }

    func applicationDidBecomeActive() {
        // §4c-3: deliver any loan journal a previous run left behind (crash/update).
        podLoanCoordinator.attemptRecoveredJournalHandback()
        if WCSession.default.activationState != .activated {
            WCSession.default.activate()
        }

        requestSettingsSyncIfNeeded()
        g7.ensureKeepalive()   // re-arm if a background relaunch left the workout session dead
        exportG7LogIfDue()

        NotificationCenter.default.post(name: type(of: self).didBecomeActiveNotification, object: self)
    }

    /// Ship Documents/g7watch.log (G7 BLE trace + loop decisions + pod commands) to the phone via
    /// WCSession.transferFile — queued, so it delivers whenever the phone is next reachable even if
    /// it's off right now. Throttled: WatchConnectivity shares the watch's one radio with the G7
    /// link, so exports are opportunistic on app-open, never mid-soak on a timer.
    private var lastG7LogExport: Date? {
        get { UserDefaults.standard.object(forKey: "lastG7LogExport") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastG7LogExport") }
    }
    private func exportG7LogIfDue() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard let src = LogFile.url, FileManager.default.fileExists(atPath: src.path) else { return }
        if let last = lastG7LogExport, Date().timeIntervalSince(last) < 10 * 60 { return }
        lastG7LogExport = Date()
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("g7watch-export.log")
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else { return }
        session.transferFile(dst, metadata: ["kind": "g7log"])
        fileLog("export-log: queued to iPhone (reach \(session.isReachable ? "y" : "n"))")
    }

    /// Pull settings from the phone when ours are incomplete. The push path
    /// (transferUserInfo) loses them across a watch-app reinstall — the phone
    /// skips resending while it believes nothing changed — and is unreliable on
    /// simulators. sendMessage is synchronous and works in both places;
    /// idempotent, so firing on every activation is safe.
    private func requestSettingsSyncIfNeeded() {
        let settings = loopManager.settings
        guard settings.basalRateSchedule == nil
            || settings.insulinSensitivitySchedule == nil
            || settings.carbRatioSchedule == nil
            || settings.glucoseTargetRangeSchedule == nil else {
            return
        }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }

        log.default("Requesting settings refresh from phone (incomplete local settings)")
        session.sendMessage(["name": LoopSettingsUserInfo.name], replyHandler: { [weak self] reply in
            guard let self, let settings = LoopSettingsUserInfo(rawValue: reply)?.settings else {
                self?.log.error("Settings refresh reply failed to decode")
                return
            }
            DispatchQueue.main.async {
                self.log.default("Settings refresh received from phone")
                // Assigning settings fires LoopDataManager.didUpdateContextNotification,
                // which the prediction store observes — no manual nudge needed.
                self.loopManager.settings = settings
            }
        }, errorHandler: { [weak self] error in
            self?.log.error("Settings refresh request failed: %{public}@", String(describing: error))
        })
    }

    func applicationWillResignActive() {
        UserDefaults.standard.startOnChartPage = (WKExtension.shared().visibleInterfaceController as? ChartHUDController) != nil

        NotificationCenter.default.post(name: type(of: self).willResignActiveNotification, object: self)
    }

    // Presumably the main thread?
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        loopManager.requestGlucoseBackfillIfNecessary()

        for task in backgroundTasks {
            switch task {
            case is WKApplicationRefreshBackgroundTask:
                log.default("Processing WKApplicationRefreshBackgroundTask")
                break
            case let task as WKSnapshotRefreshBackgroundTask:
                log.default("Processing WKSnapshotRefreshBackgroundTask")
                task.setTaskCompleted(restoredDefaultState: false, estimatedSnapshotExpiration: Date(timeIntervalSinceNow: TimeInterval(minutes: 5)), userInfo: nil)
                return  // Don't call the standard setTaskCompleted handler
            case is WKURLSessionRefreshBackgroundTask:
                break
            case let task as WKWatchConnectivityRefreshBackgroundTask:
                log.default("Processing WKWatchConnectivityRefreshBackgroundTask")

                pendingConnectivityTasks.append(task)

                if WCSession.default.activationState != .activated {
                    WCSession.default.activate()
                }

                completePendingConnectivityTasksIfNeeded()
                return // Defer calls to the setTaskCompleted handler
            default:
                break
            }

            if #available(watchOSApplicationExtension 4.0, *) {
                task.setTaskCompletedWithSnapshot(false)
            } else {
                task.setTaskCompleted()
            }
        }
    }

    private var pendingConnectivityTasks: [WKWatchConnectivityRefreshBackgroundTask] = []

    private func completePendingConnectivityTasksIfNeeded() {
        if WCSession.default.activationState == .activated && !WCSession.default.hasContentPending {
            pendingConnectivityTasks.forEach { (task) in
                self.log.default("Completing WKWatchConnectivityRefreshBackgroundTask %{public}@", String(describing: task))
                if #available(watchOSApplicationExtension 4.0, *) {
                    task.setTaskCompletedWithSnapshot(false)
                } else {
                    task.setTaskCompleted()
                }
            }
            pendingConnectivityTasks.removeAll()
        }
    }

    func handle(_ userActivity: NSUserActivity) {
        if #available(watchOSApplicationExtension 5.0, *) {
            switch userActivity.activityType {
            case NSUserActivity.newCarbEntryActivityType, NSUserActivity.didAddCarbEntryOnWatchActivityType:
                if let statusController = WKExtension.shared().visibleInterfaceController as? HUDInterfaceController {
                    statusController.addCarbs()
                }
            default:
                break
            }
        }
    }

    private func updateContext(_ data: [String: Any]) {
        guard let context = WatchContext(rawValue: data) else {
            log.error("Could not decode WatchContext: %{public}@", data)
            return
        }

        if context.displayGlucoseUnit == nil {
            let type = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
            loopManager.healthStore.preferredUnits(for: [type]) { (units, error) in
                context.displayGlucoseUnit = units[type]

                DispatchQueue.main.async {
                    self.loopManager.updateContext(context)
                }
            }
        } else {
            DispatchQueue.main.async {
                self.loopManager.updateContext(context)
            }
        }
    }

    private func loopManagerDidUpdateContext() {
        dispatchPrecondition(condition: .onQueue(.main))

        if WKExtension.shared().applicationState != .active {
            WKExtension.shared().scheduleSnapshotRefresh(withPreferredDate: Date(), userInfo: nil) { (error) in
                if let error = error {
                    self.log.error("scheduleSnapshotRefresh error: %{public}@", String(describing: error))
                }
            }
        }

        reloadComplications()
    }

    /// Reload every active complication timeline (phone-context update, or a
    /// watch-local prediction update in Sport Mode — see P1#11).
    func reloadComplications() {
        let server = CLKComplicationServer.sharedInstance()
        for complication in server.activeComplications ?? [] {
            log.default("Reloading complication timeline")
            server.reloadTimeline(for: complication)
        }
    }
}


extension ExtensionDelegate: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated {
            updateContext(session.receivedApplicationContext)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        // §4c-3 / DESIGN-6: an undelivered journal (crash or revoke) retries
        // whenever the phone becomes reachable — not just on app activation.
        // A revoke can arrive precisely while unreachable (that's the queued
        // channel's job), so this is the delivery trigger for that case.
        guard session.isReachable else { return }
        Task { @MainActor in
            self.podLoanCoordinator.attemptRecoveredJournalHandback()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        log.default("didReceiveApplicationContext")
        updateContext(applicationContext)
    }

    // This method is called on a background thread of your app
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        let name = userInfo["name"] as? String ?? "WatchContext"

        log.default("didReceiveUserInfo: %{public}@", name)

        switch name {
        case LoopSettingsUserInfo.name:
            if let settings = LoopSettingsUserInfo(rawValue: userInfo)?.settings {
                DispatchQueue.main.async {
                    self.loopManager.settings = settings
                }
            } else {
                log.error("Could not decode LoopSettingsUserInfo: %{public}@", userInfo)
            }
        case SupportedBolusVolumesUserInfo.name:
            guard let volumes = SupportedBolusVolumesUserInfo(rawValue: userInfo)?.supportedBolusVolumes else {
                log.error("Could not decode SupportedBolusVolumesUserInfo: %{public}@", userInfo)
                return
            }

            DispatchQueue.main.async {
                self.loopManager.supportedBolusVolumes = volumes
            }
        case PodLoanRevokeUserInfo.name:
            // DESIGN-6: the phone reclaimed the pod via its escape hatch.
            guard let revoke = PodLoanRevokeUserInfo(rawValue: userInfo) else {
                log.error("Could not decode PodLoanRevokeUserInfo: %{public}@", userInfo)
                return
            }
            Task { @MainActor in
                self.podLoanCoordinator.handleLoanRevoked(revokedAt: revoke.revokedAt)
            }
        case "WatchContext":
            // WatchContext is the only userInfo type without a "name" key. This isn't a great heuristic.
            updateContext(userInfo)
        default:
            break
        }
    }

    // 3b v2: the phone POLLS the watch for its Show-Mode status. The watch is
    // answer-only — it never pushes, it just replies here when asked, so there's
    // no new watch timer or battery cost. Runs on a background thread; hop to the
    // main actor to read the @MainActor coordinator, then reply (WCSession accepts
    // the reply from any thread). Always call replyHandler exactly once.
    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        switch message["name"] as? String {
        case WatchLoanStatusRequestUserInfo.name:
            Task { @MainActor in
                let coordinator = self.podLoanCoordinator
                let status = WatchLoanStatusUserInfo(holdsPod: coordinator.phase == .active,
                                                     podConnected: coordinator.podConnected)
                replyHandler(status.rawValue)
            }
        default:
            replyHandler([:])
        }
    }
}


extension ExtensionDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            guard
                response.notification.request.identifier == LoopNotificationCategory.missedMeal.rawValue,
                let statusController = WKExtension.shared().visibleInterfaceController as? HUDInterfaceController
            else {
                break
            }

            let userInfo = response.notification.request.content.userInfo
            // If we have info about a meal, the carb entry UI should reflect it
            if
                let mealTime = userInfo[LoopNotificationUserInfoKey.missedMealTime.rawValue] as? Date,
                let carbAmount = userInfo[LoopNotificationUserInfoKey.missedMealCarbAmount.rawValue] as? Double
            {
                let missedEntry = NewCarbEntry(quantity: HKQuantity(unit: .gram(),
                                                                         doubleValue: carbAmount),
                                                    startDate: mealTime,
                                                    foodType: nil,
                                                    absorptionTime: nil)
                statusController.addCarbs(initialEntry: missedEntry)
            // Otherwise, just provide the ability to add carbs
            } else {
                statusController.addCarbs()
            }
        default:
            break
        }

        completionHandler()
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.badge, .sound, .list, .banner])
    }
}


extension ExtensionDelegate {
    static let didBecomeActiveNotification = Notification.Name("com.loopkit.Loop.LoopWatch.didBecomeActive")

    static let willResignActiveNotification = Notification.Name("com.loopkit.Loop.LoopWatch.willResignActive")

    /// Global shortcut to present an alert for a specific error out-of-context with a specific interface controller.
    ///
    /// - parameter error: The error whose contents to display
    func present(_ error: Error) {
        dispatchPrecondition(condition: .onQueue(.main))

        WKExtension.shared().rootInterfaceController?.presentAlert(withTitle: error.localizedDescription, message: (error as NSError).localizedRecoverySuggestion ?? (error as NSError).localizedFailureReason, preferredStyle: .alert, actions: [WKAlertAction.dismissAction()])
    }
}


fileprivate extension WKExtension {
    var extensionDelegate: ExtensionDelegate! {
        return delegate as? ExtensionDelegate
    }
}
