//
//  DoseType.swift
//  LoopKit
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import Foundation


/// A general set of ways insulin can be delivered by a pump
public enum DoseType: String, CaseIterable {
    case basal
    case bolus
    case resume
    case suspend
    case tempBasal
    
    public var localizedDescription: String {
        switch self {
        case .basal:
            return LocalizedString("Basal", comment: "Title for basal dose type")
        case .bolus:
            return LocalizedString("Bolus", comment: "Title for bolus dose type")
        case .tempBasal:
            return LocalizedString("Temp Basal", comment: "Title for temp basal dose type")
        case .suspend:
            return LocalizedString("Suspended", comment: "Title for suspend dose type")
        case .resume:
            return LocalizedString("Resumed", comment: "Title for resume dose type")
        }
    }
}

extension DoseType: Codable {}
// Modified from LoopKit for watchOS port: removed the PumpEventType compatibility
// extension (init?(pumpEventType:) / var pumpEventType). PumpEventType and its
// ReplaceableComponent dependency are not part of the portable driver core.
