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
import LoopAlgorithm
import Intents
import os
import os.log
import UserNotifications
import LoopKit
import LoopCore
import ClockKit

class ExtensionDelegate: NSObject, WKApplicationDelegate {

    private let log = OSLog(category: "ExtensionDelegate")

    /// The Sport Mode stack: the watch's own loop, the loan controller, the CGM transport and
    /// the workout keepalive that holds the app awake between doses.
    ///
    /// Optional rather than `lazy` because building it opens the dose store, which is async now.
    /// It is started at launch — before any loan message can arrive — and a message that lands
    /// in the gap is logged rather than dropped silently.
    private(set) var stockLoopSession: StockLoopSession?
    private var stockLoopSessionStarting = false

    private func startStockLoopSession() {
        guard stockLoopSession == nil, !stockLoopSessionStarting else { return }
        stockLoopSessionStarting = true
        // Built OFF the main actor and hopped back only to publish the result. Opening three
        // Core Data stores and a BLE central is not main-thread work, and on a watch the launch
        // window is short enough that doing it there risks the app being killed for being
        // unresponsive before it has drawn anything.
        Task.detached(priority: .userInitiated) {
            let session = await StockLoopSession()
            await MainActor.run {
                self.stockLoopSession = session
                self.stockLoopSessionStarting = false
                if session == nil {
                    // Sport Mode is unavailable; the rest of the watch app is not affected.
                    SportLog.event("session", "SPORT MODE UNAVAILABLE — stack did not assemble")
                } else {
                    session?.sessionDidActivate()
                }
            }
        }
    }

    private var observers: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []

    /// The live delegate, registered by the delegate itself.
    ///
    /// Deliberately NOT `WKApplication.shared().delegate`. Under the SwiftUI application
    /// lifecycle the delegate is created and owned by `@WKApplicationDelegateAdaptor`, and that
    /// property is never populated — it reads nil for the whole life of the app even while THIS
    /// object is receiving every lifecycle callback. The old WatchKit extension installed its
    /// delegate from Info.plist, which is the only reason the same lookup worked there.
    ///
    /// The failure mode is worth remembering because it is silent: every view asking for the
    /// delegate got nil, so `stockLoopSession` read nil, so the Start button and the diagnostics
    /// controls did nothing whatsoever — no error, no log line, a UI that renders correctly and is
    /// completely inert. The launch crash that preceded it was the same nil arriving through
    /// `shared()`, which is implicitly unwrapped and therefore trapped instead of returning.
    private static var installed: ExtensionDelegate?

    static func shared() -> ExtensionDelegate {
        return sharedIfAvailable()!
    }

    /// The delegate, or nil if it does not exist yet.
    ///
    /// Anything reachable from view construction must ask this way: `shared()` traps on nil, and
    /// SwiftUI can evaluate a `@StateObject` initializer before the delegate is constructed.
    static func sharedIfAvailable() -> ExtensionDelegate? {
        return installed
    }

    let loopManager = LoopDataManager.shared

    override init() {
        super.init()

        // Register FIRST, before any other setup: SwiftUI can construct a view — and a
        // @StateObject initializer that reaches for the delegate — as soon as this object exists
        // and before applicationDidFinishLaunching runs. That window is where the launch crash
        // happened, and registering late would leave it open.
        Self.installed = self

        let session = WCSession.default
        session.delegate = self

        // It seems, according to [this sample code](https://developer.apple.com/library/prerelease/content/samplecode/QuickSwitch/Listings/QuickSwitch_WatchKit_Extension_ExtensionDelegate_swift.html#//apple_ref/doc/uid/TP40016647-QuickSwitch_WatchKit_Extension_ExtensionDelegate_swift-DontLinkElementID_8)
        // that WCSession activation and delegation and WKWatchConnectivityRefreshBackgroundTask don't have any determinism,
        // and that KVO is the "recommended" way to deal with it.
        observers.append(session.observe(\WCSession.activationState) { [weak self] (session, change) in
            self?.log.default("WCSession.applicationState did change to %d", session.activationState.rawValue)

            self?.log.default("WCSession.applicationState did change rootInterfaceController = %{public}@", String(describing: WKApplication.shared().rootInterfaceController))
            self?.log.default("WCSession.applicationState did change visibleInterfaceController = %{public}@", String(describing: WKApplication.shared().visibleInterfaceController))

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
        // Start the loan stack HERE, not on first use: the loan's transport callbacks land on
        // this delegate, and a stack that only builds when something arrives would miss the
        // message that was meant to build it. It is built off-main and cannot fail the launch:
        // if it does not assemble, Sport Mode is simply unavailable.
        SportLog.event("session", "launch: starting Sport Mode stack")
        startStockLoopSession()
        UNUserNotificationCenter.current().delegate = self
        if #available(watchOSApplicationExtension 5.0, *) {
            INRelevantShortcutStore.default.registerShortcuts()
        }
    }

    func applicationDidBecomeActive() {
        if WCSession.default.activationState != .activated {
            WCSession.default.activate()
        }

        // Catch up when the app comes to the foreground (e.g. tapping a stale
        // complication). Otherwise glucose is only fetched during background
        // refresh tasks, so opening the app could show just the current point
        // and forecast with no history. Pull the latest context and backfill any
        // glucose we're missing.
        loopManager.requestContextUpdate()
        loopManager.requestGlucoseBackfillIfNecessary()

        // Re-assert the workout session if anything still holds it. This is the one moment we
        // KNOW we are executing — the only other re-assert path is a timer, which cannot fire
        // while suspended. No-op when nothing holds it.
        startStockLoopSession()
        stockLoopSession?.ensureKeepalive()
        SportLog.event("lifecycle", "didBecomeActive [lifecycle-crumb]")
        NotificationCenter.default.post(name: Self.didBecomeActiveNotification, object: self)
    }

    func applicationWillResignActive() {
        // Breadcrumb for the silent-death investigation: the deaths cluster in the
        // radio-quiet window, and the app's exact lifecycle state at last breath is the
        // discriminator between watchdog-on-transition and background-kill theories.
        SportLog.event("lifecycle", "willResignActive [lifecycle-crumb]")
        NotificationCenter.default.post(name: Self.willResignActiveNotification, object: self)
    }

    /// Foreground transitions, as notifications. A SwiftUI page that only wants to work while
    /// it is actually being looked at keys its refresh off these.
    static let didBecomeActiveNotification = Notification.Name("com.loopkit.Loop.LoopWatch.didBecomeActive")
    static let willResignActiveNotification = Notification.Name("com.loopkit.Loop.LoopWatch.willResignActive")

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
        switch userActivity.activityType {
        case NSUserActivity.newCarbEntryActivityType, NSUserActivity.didAddCarbEntryOnWatchActivityType:
            loopManager.bolusViewModel = CarbAndBolusFlowViewModel(configuration: .carbEntry(nil))
        default:
            break
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
                defer {
                    DispatchQueue.main.async {
                        self.loopManager.updateContext(context)
                    }
                }
                
                guard let unit = units[type] else {
                    context.displayGlucoseUnit = nil
                    return
                }
                
                context.displayGlucoseUnit = LoopUnit(from: unit)
            }
        } else {
            DispatchQueue.main.async {
                self.loopManager.updateContext(context)
            }
        }
    }

    private func loopManagerDidUpdateContext() {
        dispatchPrecondition(condition: .onQueue(.main))

        if WKApplication.shared().applicationState != .active {
            WKApplication.shared().scheduleSnapshotRefresh(withPreferredDate: Date(), userInfo: nil) { (error) in
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
        log.default("activationDidCompleteWith %{public}@", String(describing: activationState))

        log.default("activationDidCompleteWith rootInterfaceController = %{public}@", String(describing: WKApplication.shared().rootInterfaceController))
        log.default("activationDidCompleteWith visibleInterfaceController = %{public}@", String(describing: WKApplication.shared().visibleInterfaceController))

        if activationState == .activated {
            updateContext(session.receivedApplicationContext)
            stockLoopSession?.sessionDidActivate()
            Task {
                await loopManager.requestSettingsUpdate()
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        SportLog.event("wc", "REACHABILITY CHANGED — reachable=\(session.isReachable) "
                           + "activation=\(session.activationState.rawValue)")
        // R40 reunion: a seized loan PROMPTS (debounced, R40(f)) when the phone genuinely
        // returns — the controller ignores everything but that case.
        stockLoopSession?.loanController.noteReachabilityChanged(session.isReachable)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        log.default("didReceiveApplicationContext")
        updateContext(applicationContext)
    }

    /// The IMMEDIATE channel — and the one the phone's GRANT arrives on.
    ///
    /// `sendMessage(_:replyHandler:nil)` is delivered here, NOT to `didReceiveUserInfo`. Without
    /// this method the interactive half of the loan handshake is dropped by WatchConnectivity with
    /// no error on either side: the phone logs a grant sent and then reclaims the pod 20s later
    /// having never been acked, and the wrist sits on "awaiting grant" until its own timeout and
    /// reports the hand-over never arrived. Both devices behave correctly and the loan still
    /// cannot start.
    ///
    /// Its fingerprint in the watch log is that EVERY inbound line reads `ch=queued` while the
    /// watch's own sends read `path urgent` — i.e. the fast channel works outbound and silently
    /// does not exist inbound.
    ///
    /// This is the exact mirror of the phone-side gap in WatchDataManager; both halves of the
    /// urgent channel were lost in the port, and each one hides the other: fixing only the phone
    /// moves the failure from "no response" to "hand-over never reached the watch".
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        if let stockLoopSession {
            if stockLoopSession.handleIncomingIfLoanMessage(message, channel: .urgent) { return }
        } else if message[LoanProtocol.userInfoKey] != nil {
            // Same recovery as the queued path: a grant that arrives before the stack is up is
            // logged and the stack started, rather than silently discarded.
            log.error("Loan payload arrived on the urgent channel before the Sport Mode stack finished starting")
            startStockLoopSession()
            return
        }
        log.default("Ignoring unexpected sendMessage: %{public}@", String(describing: Array(message.keys)))
    }

    // This method is called on a background thread of your app
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        // Loan traffic first: it is addressed to the loan controller, not to the context
        // machinery below, and the switch's default arm would otherwise swallow it.
        if let session = stockLoopSession {
            if session.handleIncomingIfLoanMessage(userInfo, channel: .queued) { return }
        } else if userInfo[LoanProtocol.userInfoKey] != nil {
            log.error("Loan payload arrived before the Sport Mode stack finished starting")
            startStockLoopSession()
            return
        }

        let name = userInfo["name"] as? String ?? "WatchContext"

        log.default("didReceiveUserInfo: %{public}@", name)

        switch name {
        case LoopSettingsUserInfo.name:
            if let loopSettings = LoopSettingsUserInfo(rawValue: userInfo) {
                DispatchQueue.main.async {
                    self.loopManager.watchInfo = loopSettings
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
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {

        log.default("UNNotificationResponse rootInterfaceController = %{public}@", String(describing: WKApplication.shared().rootInterfaceController))
        log.default("UNNotificationResponse visibleInterfaceController = %{public}@", String(describing: WKApplication.shared().visibleInterfaceController))

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            guard response.notification.request.identifier == LoopNotificationCategory.missedMeal.rawValue else {
                break
            }

            let userInfo = response.notification.request.content.userInfo
            // If we have info about a meal, the carb entry UI should reflect it
            if
                let mealTime = userInfo[LoopNotificationUserInfoKey.missedMealTime.rawValue] as? Date,
                let carbAmount = userInfo[LoopNotificationUserInfoKey.missedMealCarbAmount.rawValue] as? Double
            {
                let missedEntry = NewCarbEntry(quantity: LoopQuantity(unit: .gram,
                                                                         doubleValue: carbAmount),
                                                    startDate: mealTime,
                                                    foodType: nil,
                                                    absorptionTime: nil)
                loopManager.bolusViewModel = CarbAndBolusFlowViewModel(configuration: .carbEntry(missedEntry))
            // Otherwise, just provide the ability to add carbs
            } else {
                loopManager.bolusViewModel = CarbAndBolusFlowViewModel(configuration: .carbEntry(nil))
            }
        case NotificationManager.Action.startPreset.rawValue:
            // Response contains the preset id and alert id
            let userInfo = response.notification.request.content.userInfo
            guard let presetIdentifier = userInfo[LoopNotificationUserInfoKey.presetId.rawValue] as? String,
                  let alertIdentifier = userInfo[LoopNotificationUserInfoKey.alertTypeID.rawValue] as? LoopKit.Alert.AlertIdentifier,
                  let managerIdentifier = userInfo[LoopNotificationUserInfoKey.managerIDForAlert.rawValue] as? String
            else {
                log.default("Unable to find keys in userInfo: %{public}@", String(describing: userInfo))
                return
            }
            log.default("Setting up PendingPresetReminder(presetIdentifier: %{public}@, alertIdentifier: %{public}@), managerIdentifier: %{public}@", presetIdentifier, alertIdentifier, managerIdentifier)

            loopManager.pendingPresetReminder = PendingPresetReminder(
                presetIdentifier: presetIdentifier,
                alertIdentifier: alertIdentifier,
                managerIdentifier: managerIdentifier
            )

            guard let visibleVC = WKApplication.shared().visibleInterfaceController else {
                log.error("no visible interface controller for presenting preset reminder!")
                return
            }

            guard let preset = loopManager.selectablePresets.first(where: { $0.id == presetIdentifier }) else {
                log.error("Unable to find preset %{public}@", presetIdentifier)
                return
            }

            visibleVC.presentController(withName: "PresetConfirmHostingController", context: preset)

        default:
            let userInfo = response.notification.request.content.userInfo
            if let alertIdentifier = userInfo[LoopNotificationUserInfoKey.alertTypeID.rawValue] as? LoopKit.Alert.AlertIdentifier,
               let managerIdentifier = userInfo[LoopNotificationUserInfoKey.managerIDForAlert.rawValue] as? String
            {
                await loopManager.sendUserSelectedNotificationActionMessage(alertIdentifier: alertIdentifier, managerIdentifier: managerIdentifier, actionIdentifier: response.actionIdentifier)
            }
            break
        }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.badge, .sound, .list, .banner])
    }
}


extension ExtensionDelegate {
    /// Global shortcut to present an alert for a specific error out-of-context with a specific interface controller.
    ///
    /// - parameter error: The error whose contents to display
    func present(_ error: Error) {
        dispatchPrecondition(condition: .onQueue(.main))

        WKApplication.shared().rootInterfaceController?.presentAlert(withTitle: error.localizedDescription, message: (error as NSError).localizedRecoverySuggestion ?? (error as NSError).localizedFailureReason, preferredStyle: .alert, actions: [WKAlertAction.dismissAction()])
    }
}


// `WKApplication.extensionDelegate` (which was `delegate as? ExtensionDelegate`) was deleted
// rather than left unused. Under the SwiftUI lifecycle that lookup always yields nil, so keeping
// it around is keeping a loaded gun: it reads like the obvious way to reach the delegate and
// silently returns nothing. Use `ExtensionDelegate.sharedIfAvailable()`.
