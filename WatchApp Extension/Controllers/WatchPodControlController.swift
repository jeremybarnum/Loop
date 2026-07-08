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
import Combine

final class WatchPodControlController: WKHostingController<WatchPodControlView>, IdentifiableClass {
    // The coordinator is owned by ExtensionDelegate (app scope), not this screen.
    // So closing this screen (the X) is a pure view dismissal — it does NOT tear
    // down the loan or its BLE connection to the pod. (B1 fix — orphaning.)
    /// Which control to show (set from the presentController context). Read in
    /// awake(withContext:) before `body` is evaluated — same pattern as
    /// CarbAndBolusFlowController.
    private var entry: PodControlEntry = .start

    override var body: WatchPodControlView {
        WatchPodControlView(coordinator: ExtensionDelegate.shared().podLoanCoordinator,
                            entry: entry,
                            dismiss: { [weak self] in self?.dismiss() })
    }

    override func awake(withContext context: Any?) {
        super.awake(withContext: context)
        if let entry = context as? PodControlEntry { self.entry = entry }
    }

    private var autoReturnCancellable: AnyCancellable?

    override func willActivate() {
        super.willActivate()
        // This screen is just the transient "steps." The instant the loan completes a
        // transition, drop the user back onto the main HUD — no manual X needed:
        //   • → .active  Untether succeeded → go use Show Mode on the main screen
        //   • → .done    hand-back finished → back to tethered
        // dropFirst() skips the phase we opened in, so opening this screen while already
        // .active (to end Show Mode) doesn't instantly dismiss.
        autoReturnCancellable = ExtensionDelegate.shared().podLoanCoordinator.$phase
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                if phase == .active || phase == .done {
                    self?.dismiss()
                }
            }
    }

    override func didDeactivate() {
        super.didDeactivate()
        autoReturnCancellable = nil
    }
}
