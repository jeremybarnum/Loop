//
//  ExtensionDelegate+BluetoothWake.swift
//  WatchApp Extension
//
//  Sport Mode's log of the background tasks a wake delivers. Holding the Bluetooth task is stock's
//  (`ExtensionDelegate.holdBluetoothTask`).
//

import Foundation
import WatchKit

extension ExtensionDelegate {

    /// Called from `handle(_ backgroundTasks:)`, once per delivery.
    func podLoanNoteBackgroundTasks(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        guard FeatureFlags.sportModeEnabled else { return }
        let bluetoothOnly = backgroundTasks.allSatisfy { $0 is WKBluetoothAlertRefreshBackgroundTask }
        if !bluetoothOnly {
            let kinds = backgroundTasks.map { String(describing: type(of: $0)) }.sorted().joined(separator: ",")
            SportLog.event("lifecycle", "background tasks [\(kinds)] on main [bt-task]")
        }
    }
}
