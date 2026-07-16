//
//  DeviceDataManager+DeviceStatus.swift
//  Loop
//
//  Created by Nathaniel Hamming on 2020-07-10.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import LoopKit
import LoopKitUI
import LoopCore

extension DeviceDataManager {
    var cgmStatusHighlight: DeviceStatusHighlight? {
        let bluetoothState = bluetoothProvider.bluetoothState
        if bluetoothState == .unsupported || bluetoothState == .unauthorized {
            return BluetoothState.unavailableHighlight
        } else if bluetoothState == .poweredOff {
            return BluetoothState.offHighlight
        } else if cgmManager == nil {
            return DeviceDataManager.addCGMStatusHighlight
        } else {
            return (cgmManager as? CGMManagerUI)?.cgmStatusHighlight
        }
    }
    
    var cgmStatusBadge: DeviceStatusBadge? {
        return (cgmManager as? CGMManagerUI)?.cgmStatusBadge
    }
    
    var cgmLifecycleProgress: DeviceLifecycleProgress? {
        return (cgmManager as? CGMManagerUI)?.cgmLifecycleProgress
    }

    var pumpStatusHighlight: DeviceStatusHighlight? {
        // TRUTH-ONLY REPORTING (see WATCH_LOAN_TESTING_BUGS.md): the phone
        // states only what it knows first-hand. It never claims the pod is "on
        // the watch" — a loan grant doesn't prove the watch took over (the watch's
        // Bluetooth can be off, ORPHANING the pod — observed live 2026-07-11), and
        // with Bluetooth off the phone can't see either device. Whether the watch
        // holds the pod is for the WATCH to say.
        //
        // Precedence: Bluetooth truth first (radio off → say that), then, whenever
        // the phone has RELEASED the pod for a loan, its first-hand fact: it is not
        // connected to the pod. 3b: shown the MOMENT of release — keyed on the pump
        // manager's PERSISTED release state (the same authoritative signal the
        // escape-hatch tap in didTapOnPumpStatus uses, so the indicator and the
        // reclaim action are always consistent) — rather than waiting ~8 min for
        // lastSync to age out. That stale-but-live-looking window misled testing on
        // 2026-07-11: the pod tile kept looking healthy while the phone was actually
        // released. The staleness check is retained as a secondary net.
        let bluetoothState = bluetoothProvider.bluetoothState
        // A loan is the phone's own first-hand fact (it released the pod, or it holds
        // the loan and contact has gone stale). During a loan that truth OUTRANKS the
        // BT-off tile: Sport Mode's premise is the phone can be away with BT off, and
        // the loan branch below (On Watch / Pod Not Connected — still delivered over
        // WatchConnectivity even with BT off) is honest, where a red "Enable Bluetooth"
        // demand would be misleading and would hide the real status.
        let inLoan = (pumpManager as? PumpConnectionLendable)?.isConnectionReleased == true
            || (podLoanedToWatch && isPodContactStale)
        if !inLoan, bluetoothState == .unsupported || bluetoothState == .unauthorized || bluetoothState == .poweredOff {
            return BluetoothState.enableHighlight
        }
        if inLoan {
            // 3b v2: reflect the watch's OWN recently-polled status — first-hand
            // over WC, never inferred from the grant (a grant doesn't prove
            // takeover; the pod can be orphaned). "On Watch" only when the watch
            // confirms it holds a live pod link; "Watch Lost Pod" when it holds the
            // loan but its link is down (its 3a signal-lost); otherwise the honest
            // "Pod Not Connected" (no recent confirmation, or watch not holding it).
            if let report = lastWatchLoanReport,
               Date().timeIntervalSince(report.lastHeard) < .minutes(5),
               report.watchHoldsPod {
                return report.podConnected ? OnWatchStatusHighlight() : WatchLostPodStatusHighlight()
            }
            return PodNotConnectedStatusHighlight()
        }
        if let onboardingManager = onboardingManager, !onboardingManager.isComplete, pumpManager?.isOnboarded != true {
            return DeviceDataManager.resumeOnboardingStatusHighlight
        } else if pumpManager == nil {
            return DeviceDataManager.addPumpStatusHighlight
        } else {
            return pumpManager?.pumpStatusHighlight
        }
    }

    /// The phone hasn't successfully heard from the pod recently. During a loan
    /// window this is the phone's honest, first-hand statement — it says nothing
    /// about who else may hold the pod. The 8-minute threshold sits above the
    /// ~5-min background poll cadence (so a normal between-poll gap doesn't trip
    /// it) and below OmniBLE's 12-min "Signal Loss" (so the more specific
    /// "Pod Not Connected" is what shows). No lastSync at all counts as stale.
    private var isPodContactStale: Bool {
        guard let lastSync = pumpManager?.lastSync else { return true }
        return Date().timeIntervalSince(lastSync) > .minutes(8)
    }

    var pumpStatusBadge: DeviceStatusBadge? {
        return pumpManager?.pumpStatusBadge
    }

    var pumpLifecycleProgress: DeviceLifecycleProgress? {
        return pumpManager?.pumpLifecycleProgress
    }
    
    static var resumeOnboardingStatusHighlight: ResumeOnboardingStatusHighlight {
        return ResumeOnboardingStatusHighlight()
    }

    struct ResumeOnboardingStatusHighlight: DeviceStatusHighlight {
        var localizedMessage: String = NSLocalizedString("Complete Setup", comment: "Title text for button to complete setup")
        var imageName: String = "exclamationmark.circle.fill"
        var state: DeviceStatusHighlightState = .warning
    }

    /// Shown when Bluetooth is on but the phone has no recent contact with the
    /// pod during a loan window. Deliberately makes NO claim about the watch —
    /// only the phone's own connection state (truth-only reporting).
    struct PodNotConnectedStatusHighlight: DeviceStatusHighlight {
        var localizedMessage: String = NSLocalizedString("Pod Not\nConnected", comment: "Pump status highlight when the phone has no connection to the pod")
        var imageName: String = "antenna.radiowaves.left.and.right.slash"
        var state: DeviceStatusHighlightState = .warning
    }

    /// 3b v2: the watch has confirmed (first-hand, over WatchConnectivity) that it
    /// holds the pod with a live BLE link. Calm/informational — the expected
    /// Show-Mode state, so the phone stops looking falsely disconnected.
    struct OnWatchStatusHighlight: DeviceStatusHighlight {
        var localizedMessage: String = NSLocalizedString("On Watch", comment: "Pump status highlight when the Apple Watch is confirmed to be controlling the pod")
        var imageName: String = "applewatch"
        var state: DeviceStatusHighlightState = .normalPump
    }

    /// 3b v2: the watch still holds the loan but has reported its own BLE link to
    /// the pod is down (its 3a "signal lost"). Warn — the pod is running
    /// autonomously and neither device can currently command it.
    struct WatchLostPodStatusHighlight: DeviceStatusHighlight {
        var localizedMessage: String = NSLocalizedString("Watch Lost\nPod", comment: "Pump status highlight when the watch holds the loan but reports its link to the pod is lost")
        var imageName: String = "applewatch.slash"
        var state: DeviceStatusHighlightState = .warning
    }

    static var addCGMStatusHighlight: AddDeviceStatusHighlight {
        return AddDeviceStatusHighlight(localizedMessage: NSLocalizedString("Add CGM", comment: "Title text for button to set up a CGM"),
                                        state: .critical)
    }
    
    static var addPumpStatusHighlight: AddDeviceStatusHighlight {
        return AddDeviceStatusHighlight(localizedMessage: NSLocalizedString("Add Pump", comment: "Title text for button to set up a Pump"),
                                        state: .critical)
    }
    
    struct AddDeviceStatusHighlight: DeviceStatusHighlight {
        var localizedMessage: String
        var imageName: String = "plus.circle"
        var state: DeviceStatusHighlightState
    }
    
    func didTapOnCGMStatus(_ view: BaseHUDView? = nil) -> HUDTapAction? {
        if let action = bluetoothProvider.bluetoothState.action {
            return action
        } else if let url = cgmManager?.appURL,
            UIApplication.shared.canOpenURL(url)
        {
            return .openAppURL(url)
        } else if let cgmManagerUI = (cgmManager as? CGMManagerUI) {
            return .presentViewController(cgmManagerUI.settingsViewController(bluetoothProvider: bluetoothProvider, displayGlucosePreference: displayGlucosePreference, colorPalette: .default, allowDebugFeatures: FeatureFlags.allowDebugFeatures))
        } else {
            return .setupNewCGM
        }
    }
    
    func didTapOnPumpStatus(_ view: BaseHUDView? = nil) -> HUDTapAction? {
        // During a loan, tapping the pump status offers the ESCAPE HATCH: reclaim
        // the pod without a hand-back (watch lost/dead). Normal loans end from the
        // watch; this exists because the phone no longer reclaims accidentally
        // (formal handoff removed the BT-toggle safety net).
        // Keyed on the pump manager's PERSISTED release state, NOT the volatile
        // podLoanedToWatch flag: a crash mid-loan resets the flag on relaunch
        // (observed 2026-07-10) while the release persists — and post-crash is
        // exactly when the escape hatch must be reachable.
        // Checked BEFORE the Bluetooth action so the reclaim stays reachable even with
        // BT off during a loan (Sport Mode expects the phone away/BT-off); otherwise
        // .poweredOff → .takeNoAction would swallow the tap and strand the escape hatch.
        if (pumpManager as? PumpConnectionLendable)?.isConnectionReleased == true {
            presentReclaimPodAlert()
            return .takeNoAction
        }
        if let action = bluetoothProvider.bluetoothState.action {
            return action
        }
        if let onboardingManager = onboardingManager, !onboardingManager.isComplete, pumpManager?.isOnboarded != true {
            onboardingManager.resume()
            return .takeNoAction
        } else if let pumpManagerHUDProvider = pumpManagerHUDProvider,
            let view = view,
            let action = pumpManagerHUDProvider.didTapOnHUDView(view, allowDebugFeatures: FeatureFlags.allowDebugFeatures)
        {
            return action
        } else if let pumpManager = pumpManager {
            return .presentViewController(pumpManager.settingsViewController(bluetoothProvider: bluetoothProvider, colorPalette: .default, allowDebugFeatures: FeatureFlags.allowDebugFeatures, allowedInsulinTypes: allowedInsulinTypes))
        } else {
            return .setupNewPump
        }
    }
    
    var isGlucoseValueStale: Bool {
        guard let latestGlucoseDataDate = glucoseStore.latestGlucose?.startDate else { return true }

        return Date().timeIntervalSince(latestGlucoseDataDate) > LoopCoreConstants.inputDataRecencyInterval
    }
}

// MARK: - BluetoothState

fileprivate extension BluetoothState {
    struct Highlight: DeviceStatusHighlight {
        var localizedMessage: String
        var imageName: String = "bluetooth.disabled"
        var state: DeviceStatusHighlightState = .critical

        init(localizedMessage: String) {
            self.localizedMessage = localizedMessage
        }
    }

    static var offHighlight: Highlight {
        return Highlight(localizedMessage: NSLocalizedString("Bluetooth\nOff", comment: "Message to the user to that the bluetooth is off"))
    }

    static var enableHighlight: Highlight {
        return Highlight(localizedMessage: NSLocalizedString("Enable\nBluetooth", comment: "Message to the user to enable bluetooth"))
    }

    static var unavailableHighlight: Highlight {
        return Highlight(localizedMessage: NSLocalizedString("Bluetooth\nUnavailable", comment: "Message to the user that bluetooth is unavailable to the app"))
    }

    var action: HUDTapAction? {
        switch self {
        case .unauthorized:
            return .openAppURL(URL(string: UIApplication.openSettingsURLString)!)
        case .poweredOff:
            return .takeNoAction
        default:
            return nil
        }
    }
}
