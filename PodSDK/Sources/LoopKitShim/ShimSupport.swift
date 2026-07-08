//
//  ShimSupport.swift
//  LoopKitShim
//
//  Part of the minimal LoopKit shim for the OmniBLE watchOS port.
//  Provides the small pieces of LoopKit that the copied real LoopKit
//  source files (InsulinType, DoseType, DoseEntry, Alert) depend on,
//  so those files can be used verbatim.
//

import Foundation
import HealthKit

// LoopKit ships its own LocalizedString(_:tableName:value:comment:) helper.
// The copied InsulinType/DoseType files call it, so provide a trivial
// pass-through here (localization tables are not shipped in the shim).
func LocalizedString(_ key: String, tableName: String? = nil, value: String? = nil, comment: String) -> String {
    return value ?? key
}

// From LoopKit/SampleValue.swift — the minimal protocol DoseEntry conforms to.
public protocol TimelineValue {
    var startDate: Date { get }
    var endDate: Date { get }
}

public extension TimelineValue {
    var endDate: Date {
        return startDate
    }
}

// From LoopKit/Extensions/TimeInterval.swift. Kept internal (not public) so it
// does not collide with OmniBLECore's own TimeInterval extension when that
// module imports this shim. DoseEntry (inside this module) uses `.hours`.
extension TimeInterval {
    var minutes: Double {
        return self / 60.0
    }
    var hours: Double {
        return minutes / 60.0
    }
}

// From LoopKit/Extensions/HKUnit.swift — used by the copied DoseEntry.swift.
extension HKUnit {
    static let internationalUnitsPerHour: HKUnit = {
        return HKUnit.internationalUnit().unitDivided(by: .hour())
    }()
}

// LoopKit provides NumberFormatter.string(from: Double); the copied DoseEntry.swift uses it.
extension NumberFormatter {
    func string(from number: Double) -> String? {
        return string(from: NSNumber(value: number))
    }
}

// Minimal stand-in for LoopKit's QuantityFormatter, used only for alert body text
// in PumpManagerAlert. Formats an HKQuantity into a localized decimal string with
// the unit appended. Not a byte-for-byte match to LoopKit's formatter.
public class QuantityFormatter {
    private let unit: HKUnit
    private let numberFormatter: NumberFormatter

    public init(for unit: HKUnit) {
        self.unit = unit
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 3
        self.numberFormatter = f
    }

    public func string(from quantity: HKQuantity) -> String? {
        let value = quantity.doubleValue(for: unit)
        let number = numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return "\(number) \(unit.unitString)"
    }
}
