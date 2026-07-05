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

final class WatchPodControlController: WKHostingController<WatchPodControlView>, IdentifiableClass {
    private lazy var coordinator = WatchPodLoanCoordinator()

    override var body: WatchPodControlView {
        WatchPodControlView(coordinator: coordinator)
    }
}
