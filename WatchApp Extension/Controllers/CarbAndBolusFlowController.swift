//
//  CarbAndBolusFlowController.swift
//  WatchApp Extension
//
//  Created by Michael Pangburn on 4/7/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import WatchKit
import SwiftUI
import HealthKit
import LoopCore
import LoopKit


final class CarbAndBolusFlowController: WKHostingController<CarbAndBolusFlow>, IdentifiableClass {
    private lazy var viewModel = {
        CarbAndBolusFlowViewModel(
            configuration: configuration,
            dismiss: { [weak self] in
                guard let self = self else { return }
                self.willDeactivateObserver = nil
                self.dismiss()
            }
        )
    }()

    private var configuration: CarbAndBolusFlow.Configuration = .carbEntry(nil)

    override var body: CarbAndBolusFlow {
        CarbAndBolusFlow(viewModel: viewModel)
    }

    private var willDeactivateObserver: AnyObject? {
        didSet {
            if let oldValue = oldValue {
                NotificationCenter.default.removeObserver(oldValue)
            }
        }
    }

    override func awake(withContext context: Any?) {
        if let configuration = context as? CarbAndBolusFlow.Configuration {
            self.configuration = configuration
        }
    }

    override func didAppear() {
        super.didAppear()

        updateNewCarbEntryUserActivity()

        let appearedAt = Date()

        // If the screen turns off, the screen should be dismissed for safety reasons
        willDeactivateObserver = NotificationCenter.default.addObserver(forName: ExtensionDelegate.willResignActiveNotification, object: ExtensionDelegate.shared(), queue: nil, using: { [weak self] (_) in
            if let self = self {
                // TELEMETRY ONLY — behavior unchanged. A field log showed 302 RESIGN ACTIVE
                // events, 144 of them within 2s of becoming ACTIVE (some sub-second), and this
                // observer force-dismisses the carb/bolus flow on every one. We could not tell
                // from that log whether a flow was actually open at the time, so we could not
                // size the problem. This line answers exactly that, and how long the user had
                // before the screen was taken away. Do NOT change the dismiss behavior on the
                // strength of this alone — it is a deliberate stock safety behavior.
                SportLog.event("bolus-ui", String(
                    format: "flow DISMISSED by resign-active after %.1fs open · %@",
                    Date().timeIntervalSince(appearedAt),
                    RuntimeStateLog.snapshot()
                ))
                WKInterfaceDevice.current().play(.failure)
                self.dismiss()
            }
        })
    }

    override func didDeactivate() {
        super.didDeactivate()

        willDeactivateObserver = nil
    }
}

extension CarbAndBolusFlowController: NSUserActivityDelegate {
    func updateNewCarbEntryUserActivity() {
        update(.forDidAddCarbEntryOnWatch())
    }
}
