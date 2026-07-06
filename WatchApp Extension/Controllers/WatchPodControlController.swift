//
//  WatchPodControlController.swift
//  WatchApp Extension
//
//  Hosts WatchPodControlView. Registered as a storyboard scene (identifier
//  "WatchPodControlController") and presented from the main HUD screen, the same
//  way CarbAndBolusFlowController is.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import WatchKit
import SwiftUI
import LoopCore

final class WatchPodControlController: WKHostingController<WatchPodControlView>, IdentifiableClass {
    // The coordinator is owned by ExtensionDelegate (app scope), not this screen.
    // So closing this screen (the X) is a pure view dismissal — it does NOT tear
    // down the loan or its BLE connection to the pod. (B1 fix — orphaning.)
    override var body: WatchPodControlView {
        WatchPodControlView(coordinator: ExtensionDelegate.shared().podLoanCoordinator)
    }
}
