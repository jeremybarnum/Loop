//
//  PortLinkSpike.swift
//  WatchApp — TEMPORARY, delete once the real wrist stack lands
//
//  Phase 0b's exit criterion, as code: a file compiled INTO the watch app target that
//  references the pod driver, the CGM driver and LoopKit's pump protocol. If this compiles
//  and links, the watch can host a pump manager on next-dev — which is the single fact the
//  whole port depends on.
//
//  It deliberately does not construct a live manager or touch CoreBluetooth: instantiating a
//  pump manager has side effects (it starts looking for a pod), and nothing here should ever
//  run on a device. Type-level references are enough to force the linker to resolve the
//  symbols, which is what is actually in question.
//

import Foundation
import LoopKit
import OmnipodKit
import G7SensorKit

enum PortLinkSpike {

    /// Proves LoopKit's pump protocol is visible to the watch target. Our fork had to add
    /// `PumpManager.swift` to LoopKit-watchOS for this to resolve; on next-dev that was the
    /// only genuinely missing file, the rest of the fork's additions having moved into the
    /// LoopAlgorithm package.
    static func pumpManagerProtocolIsVisible(_ manager: PumpManager) -> String {
        manager.localizedTitle
    }

    /// Proves the Omnipod driver's own types resolve, including the state type the loan
    /// protocol carries across the wire as an opaque blob.
    static func podDriverTypesResolve() -> [String] {
        [
            String(describing: OmniPumpManager.self),
            String(describing: OmniPumpManagerState.self),
        ]
    }

    /// Proves the CGM driver resolves too — the wrist reads its own G7 rather than relying on
    /// the phone, so this is as load-bearing as the pump half.
    static func cgmDriverTypesResolve() -> [String] {
        [String(describing: G7CGMManager.self)]
    }
}
