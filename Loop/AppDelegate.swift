//
//  AppDelegate.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 8/15/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import UIKit
import LoopKit
import OmnipodKit   // PodLoanConnectClock.podLoanLogSink — the phone's pod-BLE lines into PhoneLog

final class AppDelegate: UIResponder, UIApplicationDelegate, WindowProvider {
    var window: UIWindow?

    private let loopAppManager = LoopAppManager()
    private let log = DiagnosticLog(category: "AppDelegate")

    // MARK: - UIApplicationDelegate - Initialization

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        log.default("%{public}@ with launchOptions: %{public}@", #function, String(describing: launchOptions))

        setenv("CFNETWORK_DIAGNOSTICS", "3", 1)

        // PHONE LOG (2026-08-05). Start the session file and, crucially, install the pod-BLE
        // sink the phone has always left nil — OmnipodKit calls PodLoanConnectClock.podLoanLog
        // from releaseConnection and the other loan seams, and on the phone those lines went to
        // os_log only, i.e. nowhere anyone would ever read them. That is precisely why
        // "did the phone actually drop the pod's link at grant?" has been unanswerable all day,
        // for both the hand-back stall and the takeover failures.
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        PhoneLog.startSession(build: build)
        PodLoanConnectClock.podLoanLogSink = { line in PhoneLog.event("pod-ble", line) }

        log.default("lastPathComponent = %{public}@", String(describing: Bundle.main.appStoreReceiptURL?.lastPathComponent))

        loopAppManager.initialize(windowProvider: self, launchOptions: launchOptions)
        loopAppManager.launch()
        return loopAppManager.isLaunchComplete
    }

    // MARK: - UIApplicationDelegate - Life Cycle

    func applicationDidBecomeActive(_ application: UIApplication) {
        log.default(#function)

        loopAppManager.didBecomeActive()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        log.default(#function)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        log.default(#function)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        log.default(#function)
        
        loopAppManager.askUserToConfirmLoopReset()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        log.default(#function)
    }

    // MARK: - UIApplicationDelegate - Environment

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        DispatchQueue.main.async {
            if self.loopAppManager.isLaunchPending {
                self.loopAppManager.launch()
            }
        }
    }

    // MARK: - UIApplicationDelegate - Remote Notification

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        log.default(#function)

        loopAppManager.remoteNotificationRegistrationDidFinish(.success(deviceToken))
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("%{public}@ with error: %{public}@", #function, String(describing: error))
        loopAppManager.remoteNotificationRegistrationDidFinish(.failure(error))
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        log.default(#function)

        completionHandler(loopAppManager.handleRemoteNotification(userInfo as? [String: AnyObject]) ? .noData : .failed)
    }
    
    // MARK: - UIApplicationDelegate - Deeplinking
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        loopAppManager.handle(url)
    }

    // MARK: - UIApplicationDelegate - Continuity

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        log.default(#function)

        return loopAppManager.userActivity(userActivity, restorationHandler: restorationHandler)
    }

    // MARK: - UIApplicationDelegate - Interface

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return loopAppManager.supportedInterfaceOrientations
    }
}
