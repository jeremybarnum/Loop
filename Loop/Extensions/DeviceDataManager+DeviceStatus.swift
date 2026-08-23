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
    var hasBluetoothIssue: Bool {
        bluetoothProvider.bluetoothState == .poweredOff || bluetoothProvider.bluetoothState == .unauthorized || bluetoothProvider.bluetoothState == .unsupported
    }
    
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
        let bluetoothState = bluetoothProvider.bluetoothState
        if bluetoothState == .unsupported || bluetoothState == .unauthorized || bluetoothState == .poweredOff {
            return BluetoothState.enableHighlight
        } else if let onboardingManager = onboardingManager, !onboardingManager.isComplete, pumpManager?.isOnboarded != true {
            return DeviceDataManager.resumeOnboardingStatusHighlight
        } else if pumpManager == nil {
            return DeviceDataManager.addPumpStatusHighlight
        } else if isPodLoanReclaiming {
            // Hand-back in flight — records draining and the radio re-arming take a few seconds;
            // show movement, not a frozen "on watch", which reads as ownership ambiguity.
            //
            // The label follows the reclaim's phase, because "Reclaiming…" over a watch that is
            // not answering implies progress that is not happening. The dead branch says the
            // watch is silent from the first second, which is the whole point of deciding the
            // branch before the wait starts rather than after it.
            //
            return DeviceDataManager.podReclaimingStatusHighlight(phase: podReclaimProgress?.phase)
        } else if isPodTakeoverInProgress {
            // The grant is out but the watch has NOT confirmed it has the pod. This branch MUST
            // precede the one below: the grant releases the pod's BLE immediately, so
            // `isConnectionReleased` is already true here and would otherwise claim "Pod on
            // Watch" for a handover still in flight.
            //
            // ONE label for the whole window, by ruling (2026-08-23). A two-stage pill
            // ("Handing over…" -> "Released — waiting for Watch…") shipped in 1087 and was
            // reverted the same day: the stall it addressed was the OLD 5-6 s frozen window,
            // and once takeovers dropped to ~5 s the stage-two label was clutter narrating a
            // wait too short to read. If the window ever grows long again, fix the speed, not
            // the copy.
            return DeviceDataManager.podHandingOverStatusHighlight
        } else if (pumpManager as? PumpConnectionLendable)?.isConnectionReleased == true || isPodLoanedToWatch {
            // While the pod is loaned to the watch, keying on the persisted release flag flips
            // this tile the MOMENT of release/reclaim — instead of the stock signal-loss
            // presentation aging in ~8 min later, which reads as a fault.
            return DeviceDataManager.podOnWatchStatusHighlight
        } else {
            return (pumpManager as? PumpManagerUI)?.pumpStatusHighlight
        }
    }

    static var podOnWatchStatusHighlight: PodOnWatchStatusHighlight {
        return PodOnWatchStatusHighlight()
    }

    struct PodOnWatchStatusHighlight: DeviceStatusHighlight {
        var localizedMessage: String = NSLocalizedString("Pod on Watch", comment: "Title text for the pump tile while the pod is loaned to the watch")
        var imageName: String = "applewatch"
        var state: DeviceStatusHighlightState = .normalPump
    }

    static var podHandingOverStatusHighlight: PodHandingOverStatusHighlight {
        return PodHandingOverStatusHighlight()
    }


    /// The outbound twin of `PodReclaimingStatusHighlight` — same in-transit idiom, same symbol,
    /// opposite direction.
    ///
    /// "HANDING over", deliberately, while the watch says "taking over" for the same instant:
    /// each device narrates the handover from its own side, so a user glancing between them reads
    /// one event from two viewpoints rather than the same words twice. The state predicates keep
    /// the protocol's vocabulary (`isPodTakeoverInProgress`) — it is one takeover either way;
    /// only the label is perspectival.
    struct PodHandingOverStatusHighlight: DeviceStatusHighlight {
        var localizedMessage: String = NSLocalizedString("Handing over…", comment: "Title text for the pump tile while the pod is being handed over to the watch")
        var imageName: String = "arrow.triangle.2.circlepath"
        var state: DeviceStatusHighlightState = .normalPump
    }

    static func podReclaimingStatusHighlight(phase: PodLoanPhoneController.ReclaimProgress.Phase?) -> PodReclaimingStatusHighlight {
        return PodReclaimingStatusHighlight(phase: phase)
    }

    struct PodReclaimingStatusHighlight: DeviceStatusHighlight {
        var localizedMessage: String
        var imageName: String = "arrow.triangle.2.circlepath"
        var state: DeviceStatusHighlightState = .normalPump

        /// nil phase = the reclaim is inside the drain's store commit, which has no deadline to
        /// name; plain "Reclaiming…" is the honest label for it.
        ///
        /// NO elapsed counter (lean ruling, 2026-08-23). The climbing seconds were the right
        /// honesty for a settle that ranged 4-190 s — you cannot promise a duration you do not
        /// know, so you show elapsed instead. With settles in a tight 5-10 s band the counter
        /// narrated a wait too short to read, and the deterministic bar behind the label is now
        /// truthful nearly every time; the rare overrun holds near-full until the verify lands.
        init(phase: PodLoanPhoneController.ReclaimProgress.Phase? = nil) {
            switch phase {
            case .forcing?, .forceReclaimingPod?:
                // One label across the force rung AND the settle that follows it, so the force
                // reads as a single operation rather than a chain of renamed waits.
                localizedMessage = NSLocalizedString("Forcing…", comment: "Title text for the pump tile while the phone force-reclaims the pod")
            case .reconnectingToPod?, .draining?:
                // Same string across the handover/settle boundary on purpose: to the user a
                // live reclaim is ONE wait behind one continuous bar.
                localizedMessage = NSLocalizedString("Reclaiming…", comment: "Title text for the pump tile while the pod is coming back from the watch")
            case .watchNotAnswering?:
                localizedMessage = NSLocalizedString("No watch reply…", comment: "Title text for the pump tile when the watch has not answered within the drain promise")
            case .none:
                localizedMessage = NSLocalizedString("Reclaiming…", comment: "Title text for the pump tile while the pod is coming back from the watch")
            }
        }
    }

    var pumpStatusBadge: DeviceStatusBadge? {
        return (pumpManager as? PumpManagerUI)?.pumpStatusBadge
    }

    var pumpLifecycleProgress: DeviceLifecycleProgress? {
        return (pumpManager as? PumpManagerUI)?.pumpLifecycleProgress
    }
    
    static var resumeOnboardingStatusHighlight: ResumeOnboardingStatusHighlight {
        return ResumeOnboardingStatusHighlight()
    }

    struct ResumeOnboardingStatusHighlight: DeviceStatusHighlight {
        var localizedMessage: String = NSLocalizedString("Complete Setup", comment: "Title text for button to complete setup")
        var imageName: String = "exclamationmark.circle.fill"
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
        if let action = bluetoothProvider.bluetoothState.action {
            return action
        } else if let onboardingManager = onboardingManager, !onboardingManager.isComplete, pumpManager?.isOnboarded != true {
            onboardingManager.resume()
            return .takeNoAction
        } else if let pumpManagerHUDProvider = pumpManagerHUDProvider,
            let view = view,
            let action = pumpManagerHUDProvider.didTapOnHUDView(view, allowDebugFeatures: FeatureFlags.allowDebugFeatures)
        {
            return action
        } else if let pumpManager = pumpManager as? PumpManagerUI {
            return .presentViewController(pumpManager.settingsViewController(bluetoothProvider: bluetoothProvider, colorPalette: .default, allowDebugFeatures: FeatureFlags.allowDebugFeatures, allowedInsulinTypes: allowedInsulinTypes))
        } else {
            return .setupNewPump
        }
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
