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


final class ExtensionDelegate: NSObject, WKExtensionDelegate {
    private(set) lazy var loopManager = LoopDataManager()

    /// M5: the stock-shaped loop + loan-protocol owner. Inert until a grant arrives
    /// (its stores live in a distinct directory, so it coexists with `loopManager`).
    private(set) lazy var stockLoopSession = StockLoopSession()

    private let log = OSLog(category: "ExtensionDelegate")

    private var observers: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []

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
        // M3 (58c646df port): force the lazy stockLoopSession to initialize HERE on
        // the main thread. Otherwise its first touch races between the WCSession
        // delegate queue (didReceiveUserInfo -> handleIncomingIfLoanMessage /
        // main-queue lifecycle hooks; a Swift lazy var is not
        // thread-safe, so a concurrent first-init can double-construct the stack.
        _ = stockLoopSession
    }

    func applicationDidBecomeActive() {
        // 135 instrumentation (Jeremy 2026-07-20: "does the log know foreground vs
        // background?"): every radio event between these markers is attributable to
        // an app state — turns the background-degrades-the-pounce anecdote into data.
        SportLog.event("app", "ACTIVE (wrist up, frontmost) · \(RuntimeStateLog.snapshot())")
        if WCSession.default.activationState != .activated {
            WCSession.default.activate()
        }

        // #82: re-assert the workout keepalive on every foreground. The only other caller is
        // the 5-minute log pulse, a DispatchSourceTimer that by construction cannot fire while
        // the process is suspended — so the recovery mechanism was scheduled by the very clock
        // that suspension stops. Cheap, idempotent (holder-refcounted), and the one moment we
        // KNOW we are executing.
        stockLoopSession.ensureKeepalive()

        NotificationCenter.default.post(name: type(of: self).didBecomeActiveNotification, object: self)
    }

    func applicationWillResignActive() {
        // NOT the same as backgrounding. This fires for the wrist-down/dimmed case where
        // we are still frontmost (state .inactive) AND on the way to a true background —
        // the old line said "BACKGROUND" for both, erasing exactly the distinction we
        // needed (Jeremy 2026-07-22). The state tag disambiguates.
        SportLog.event("app", "RESIGN ACTIVE · \(RuntimeStateLog.snapshot())")
        UserDefaults.standard.startOnChartPage = (WKExtension.shared().visibleInterfaceController as? ChartHUDController) != nil

        NotificationCenter.default.post(name: type(of: self).willResignActiveNotification, object: self)
    }

    /// The two hooks the port never implemented — without them a wrist-down dim and a
    /// genuine background were indistinguishable in the log.
    func applicationDidEnterBackground() {
        SportLog.event("app", "BACKGROUND (another app / screen off) · \(RuntimeStateLog.snapshot())")
    }

    func applicationWillEnterForeground() {
        SportLog.event("app", "WILL FOREGROUND · \(RuntimeStateLog.snapshot())")
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

        // Update complication data if needed
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
            stockLoopSession.sessionDidActivate()
            // PODLOAN diagnostics: queue the log to the phone once per launch — a
            // deleted/reinstalled app can no longer eat an unsent log (2026-07-19).
            if let url = LogFile.url,
               let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > 2048 {
                session.transferFile(url, metadata: ["kind": "g7watch.log"])
            }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        log.default("didReceiveApplicationContext")
        updateContext(applicationContext)
    }

    /// #42: the IMMEDIATE channel. sendMessage(replyHandler: nil) is delivered here, NOT to
    /// didReceiveUserInfo — without this method the interactive loan handshake would be
    /// dropped on the floor. Loan payloads only; anything else on this path is unexpected.
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        if stockLoopSession.handleIncomingIfLoanMessage(message) {
            return
        }
        log.default("Ignoring unexpected sendMessage: %{public}@", String(describing: message.keys))
    }

    // This method is called on a background thread of your app
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        // M5: loan protocol v2 rides its own single key; consumed entirely by the
        // loan controller (undecodable v2 payloads Nack there — never dropped).
        if stockLoopSession.handleIncomingIfLoanMessage(userInfo) {
            return
        }

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
        case "WatchContext":
            // WatchContext is the only userInfo type without a "name" key. This isn't a great heuristic.
            updateContext(userInfo)
        default:
            break
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
