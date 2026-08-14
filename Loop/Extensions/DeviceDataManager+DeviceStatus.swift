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
        let bluetoothState = bluetoothProvider.bluetoothState
        if bluetoothState == .unsupported || bluetoothState == .unauthorized || bluetoothState == .poweredOff {
            return BluetoothState.enableHighlight
        } else if let onboardingManager = onboardingManager, !onboardingManager.isComplete, pumpManager?.isOnboarded != true {
            return DeviceDataManager.resumeOnboardingStatusHighlight
        } else if pumpManager == nil {
            return DeviceDataManager.addPumpStatusHighlight
        } else if isPodLoanReclaiming {
            // PODLOAN: hand-back in flight — records draining + radio re-arming takes
            // a few seconds; show movement, not a frozen "on watch" (2026-07-18: the
            // ~5s frozen tile during hand-back read as ownership ambiguity).
            //
            // The label follows the reclaim's phase, because "Reclaiming…" over a watch that is
            // not answering implies progress that is not happening. The dead branch says the
            // watch is silent from the first second, which is the whole point of deciding the
            // branch before the wait starts rather than after it.
            //
            // Read ONCE and passed whole: the phase and the elapsed seconds must describe the same
            // instant, and two reads of a live accessor do not.
            let progress = podReclaimProgress
            return DeviceDataManager.podReclaimingStatusHighlight(phase: progress?.phase,
                                                                  elapsed: progress?.elapsed)
        } else if isPodTakingOver {
            // PODLOAN #92 (2026-08-12): the grant is out but the watch has NOT confirmed it has
            // the pod. This branch MUST precede the one below: the grant releases the pod's BLE
            // immediately, so `isConnectionReleased` is already true here and would otherwise
            // claim "Pod on Watch" for a handover still in flight.
            return DeviceDataManager.podHandingOverStatusHighlight
        } else if (pumpManager as? PumpConnectionLendable)?.isConnectionReleased == true || isPodLoanedToWatch {
            // PODLOAN (ported from the crude branch's "instant status update"): while
            // the pod is loaned to the watch, keying on the persisted release flag
            // flips this tile the MOMENT of release/reclaim — instead of the stock
            // signal-loss presentation aging in ~8 min later (and reading as a fault).
            return DeviceDataManager.podOnWatchStatusHighlight
        } else {
            return pumpManager?.pumpStatusHighlight
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
    /// opposite direction. Requires `.takeoverComplete` on the immediate channel (#109): on the
    /// queued channel this label would outlive the takeover by minutes and read as a hang.
    ///
    /// "HANDING over", deliberately, while the watch says "taking over" for the same instant
    /// (Jeremy, 2026-08-12, after field-validating the two-state pill). Each device narrates the
    /// handover from its own side, so a user glancing between them reads one event from two
    /// viewpoints rather than the same words twice. The state predicates keep the protocol's
    /// vocabulary (`isPodTakeoverInProgress`) — it is one takeover either way; only the label is
    /// perspectival.
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
        /// settle's measured distribution is bimodal — 70 of 91 reclaims logged between 2026-08-02
        /// and 2026-08-14 finished in 1-11 s, the other 21 in 24-190 s, none in between — so a
        /// settle still running once the fast mode's deadline has passed is a different situation
        /// from the one the first label described, and repeating that label would be repeating a
        /// promise that has already expired. The second says the link is slow, which is what it
        /// is: the pod is fine and nothing has failed, the radio is just taking the long path.
        ///
        /// The seconds keep climbing even after the bar caps, and once it has capped they are the
        /// only thing on this tile that can distinguish still-working from stuck. Both strings are
        /// kept to the width the other labels here have proven, which is why they are
        /// abbreviations rather than sentences.
        init(phase: PodLoanPhoneController.ReclaimProgress.Phase? = nil, elapsed: TimeInterval? = nil) {
            let seconds = max(elapsed ?? 0, 0)
            switch phase {
            case .wakingTheWatch?:
                // Say it in the first second — the five dead revokes on record had silences of
                // 5.5 to 21.2 minutes before the tap — but say the ATTEMPT, not the verdict:
                // a revoke goes out the moment the tap lands, and "reaching" is what the phone
                // is actually doing. The verdict has its own phase seconds later.
                localizedMessage = NSLocalizedString("Reaching Watch…", comment: "Title text for the pump tile while a reclaim's first revoke waits on a watch that has not been heard from")
            case .watchUnreachable?:
                localizedMessage = NSLocalizedString("Can't Reach Watch", comment: "Title text for the pump tile once both revoke attempts have gone out unanswered, before the force")
            case .forcing?, .forceReclaimingPod?:
                // One label across the force rung AND the settle that follows it, so the force
                // reads as a single timed operation rather than three renamed waits. The settle
                // phase behind it carries the determinate bar; this string carries the clock.
                localizedMessage = String(format: NSLocalizedString("Forcing… %.0fs", comment: "Title text (with elapsed seconds) for the pump tile while the phone force-reclaims the pod and verifies it"),
                                          seconds)
            case .reconnectingToPod?:
                localizedMessage = String(format: NSLocalizedString("Reconnect… %.0fs", comment: "Title text (with elapsed seconds) for the pump tile while the phone re-establishes its own connection to the pod after a watch session"),
                                          seconds)
            case .reconnectingToPodSlowly?:
                localizedMessage = String(format: NSLocalizedString("Link slow… %.0fs", comment: "Title text (with elapsed seconds) for the pump tile when the phone's reconnection to the pod is taking the slow path"),
                                          seconds)
            case .draining?, .none:
                localizedMessage = NSLocalizedString("Reclaiming…", comment: "Title text for the pump tile while the pod is coming back from the watch")
            }
        }
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
