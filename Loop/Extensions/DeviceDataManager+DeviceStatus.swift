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
            // Read ONCE and passed whole: the phase and the elapsed seconds must describe the
            // same instant, and two reads of a live accessor do not.
            let progress = podReclaimProgress
            return DeviceDataManager.podReclaimingStatusHighlight(phase: progress?.phase,
                                                                  elapsed: progress?.elapsed)
        } else if isPodTakeoverInProgress {
            // The grant is out but the watch has NOT confirmed it has the pod. This branch MUST
            // precede the one below: the grant releases the pod's BLE immediately, so
            // `isConnectionReleased` is already true here and would otherwise claim "Pod on
            // Watch" for a handover still in flight.
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

    static func podReclaimingStatusHighlight(phase: PodLoanPhoneController.ReclaimProgress.Phase?,
                                             elapsed: TimeInterval? = nil) -> PodReclaimingStatusHighlight {
        return PodReclaimingStatusHighlight(phase: phase, elapsed: elapsed)
    }

    struct PodReclaimingStatusHighlight: DeviceStatusHighlight {
        var localizedMessage: String
        var imageName: String = "arrow.triangle.2.circlepath"
        var state: DeviceStatusHighlightState = .normalPump

        /// nil phase = the reclaim is inside the drain's store commit, which has no deadline to
        /// name; plain "Reclaiming…" is the honest label for it.
        ///
        /// BOTH SETTLE CASES CARRY LIVE SECONDS, and they are different words on purpose. The
        /// settle's measured distribution is bimodal — most reclaims finish in a few seconds and
        /// a minority take minutes, with little in between — so a settle still running once the
        /// fast mode's deadline has passed is a different situation from the one the first label
        /// described, and repeating that label would repeat a promise that has already expired.
        ///
        /// The seconds keep climbing even after the bar caps, and once it has capped they are the
        /// only thing on this tile that can distinguish still-working from stuck. Both strings
        /// are kept to the width the other labels here have proven, which is why they are
        /// abbreviations rather than sentences.
        init(phase: PodLoanPhoneController.ReclaimProgress.Phase? = nil, elapsed: TimeInterval? = nil) {
            let seconds = max(elapsed ?? 0, 0)
            switch phase {
            case .forcing?, .forceReclaimingPod?:
                // One label across the force rung AND the settle that follows it, so the force
                // reads as a single timed operation rather than a chain of renamed waits. The
                // dead branch enters this the instant the tap lands — it no longer waits on a
                // watch that cannot answer — so this is the whole dead-reclaim experience: one
                // label, one bar, a few seconds.
                localizedMessage = String(format: NSLocalizedString("Forcing… %.0fs", comment: "Title text (with elapsed seconds) for the pump tile while the phone force-reclaims the pod and verifies it"),
                                          seconds)
            case .reconnectingToPod?:
                // Same string as the handover on purpose: to the user a live reclaim is ONE wait,
                // and the bar behind it is one continuous fill from the tap — a label change at
                // the handover/settle boundary would read as a phase they were never told about.
                localizedMessage = String(format: NSLocalizedString("Reclaiming… %.0fs", comment: "Title text (with elapsed seconds) for the pump tile while the pod comes home and its round-trip is verified"),
                                          seconds)
            case .watchNotAnswering?:
                // Static — the bar is capped and the next event is the force, so ticking seconds
                // would count toward nothing the user was promised.
                localizedMessage = NSLocalizedString("No watch reply…", comment: "Title text for the pump tile when the watch has not answered within the drain promise, shortly before the force")
            case .draining?:
                localizedMessage = String(format: NSLocalizedString("Reclaiming… %.0fs", comment: "Title text (with elapsed seconds) for the pump tile while the watch drains its records under the determinate bar"),
                                          seconds)
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
