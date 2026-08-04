//
//  Environment.swift
//  WatchApp Extension
//
//  Created by Michael Pangburn on 4/6/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import SwiftUI


extension EnvironmentValues {
    var sizeClass: WKInterfaceDevice.SizeClass {
        get { self[SizeClassKey.self] }
        set { self[SizeClassKey.self] = newValue }
    }
}


private struct SizeClassKey: EnvironmentKey {
    static let defaultValue = WKInterfaceDevice.current().sizeClass
}


extension WKInterfaceDevice {
    /// A group of watch displays that share a layout treatment.
    ///
    /// Matching is on *exact* point size — see `init?(screenSize:)`. A display absent from the
    /// table resolves to the geometrically nearest case — see `closest(to:)`.
    ///
    /// NAMING: the six original cases are named for Apple's marketing case size in millimeters.
    /// That namespace is not a unique key and must not be extended. Apple has since reused
    /// "42mm" for a display 31pt wider than the Series 3 42mm (187x223 vs 156x195), and ships
    /// two different displays both marketed as "49mm" (205x251 Ultra/Ultra 2, 211x257 Ultra 3).
    /// Cases added from Series 10 onward are therefore named for the point geometry they match,
    /// which is the actual lookup key. Do not add mm-named cases, and do not group a new case
    /// with an mm-named one on the strength of the marketing name: `.size187x223` is 1pt from
    /// the 44mm display in height and 40pt from the Series 3 "42mm" display in width.
    enum SizeClass: CaseIterable {
        // Apple Watch Series 3 and earlier
        case size38mm       // 136 x 170
        case size42mm       // 156 x 195

        // Apple Watch Series 4 - 6, SE (all generations, including SE 3)
        case size40mm       // 162 x 197
        case size44mm       // 184 x 224

        // Apple Watch Series 7 - 9
        case size41mm       // 176 x 215
        case size45mm       // 198 x 242

        // Apple Watch Series 10 - 11
        case size187x223    // marketed as 42mm
        case size208x248    // marketed as 46mm

        // Apple Watch Ultra
        case size205x251    // Ultra, Ultra 2 — marketed as 49mm
        case size211x257    // Ultra 3 — marketed as 49mm
    }

    var sizeClass: SizeClass {
        let size = screenBounds.size

        if let sizeClass = SizeClass(screenSize: size) {
            SportLog.event("ui", "sizeClass \(Int(size.width))x\(Int(size.height)) → \(sizeClass) (exact)")
            return sizeClass
        }

        // A display this build has never seen. Resolve to the physically closest supported class
        // rather than a fixed guess. The previous behavior returned .size40mm (162x197), one of
        // the smallest screens, which laid out every watch newer than Series 9 — and every Ultra
        // ever made — as a 40mm.
        let resolved = SizeClass.closest(to: size)
        SportLog.event("ui", "sizeClass \(Int(size.width))x\(Int(size.height)) → \(resolved) (NEAREST — unknown display)")
        return resolved
    }
}

extension WKInterfaceDevice.SizeClass {
    init?(screenSize: CGSize) {
        let sizeClassesWithSizes = WKInterfaceDevice.SizeClass.allCases.map { (sizeClass: $0, screenSize: $0.screenSize) }
        guard let sizeClass = sizeClassesWithSizes.first(where: { $0.screenSize == screenSize })?.sizeClass else {
            return nil
        }

        self = sizeClass
    }

    /// The supported class whose display geometry is nearest `size`, by squared Euclidean
    /// distance over (width, height).
    ///
    /// Only reached for displays absent from `screenSize`: every watch Apple has shipped to date
    /// exact-matches in `init?(screenSize:)` and never runs this. The unweighted metric needs no
    /// defense — it is only a tiebreak among candidates that are all within ~40pt on both axes.
    static func closest(to size: CGSize) -> WKInterfaceDevice.SizeClass {
        func squaredDistance(from sizeClass: WKInterfaceDevice.SizeClass) -> CGFloat {
            let dw = sizeClass.screenSize.width - size.width
            let dh = sizeClass.screenSize.height - size.height
            return dw * dw + dh * dh
        }

        // `allCases` is a non-empty compile-time constant, so `min(by:)` cannot return nil.
        // Coalesced rather than force-unwrapped so a hypothetical failure is a wrong layout
        // rather than a crash in the bolus flow.
        return allCases.min(by: { squaredDistance(from: $0) < squaredDistance(from: $1) }) ?? .size45mm
    }

    var screenSize: CGSize {
        switch self {
        case .size38mm:
            return CGSize(width: 136, height: 170)
        case .size42mm:
            return CGSize(width: 156, height: 195)
        case .size40mm:
            return CGSize(width: 162, height: 197)
        case .size41mm:
            return CGSize(width: 176, height: 215)
        case .size44mm:
            return CGSize(width: 184, height: 224)
        case .size45mm:
            return CGSize(width: 198, height: 242)
        case .size187x223:
            return CGSize(width: 187, height: 223)
        case .size208x248:
            return CGSize(width: 208, height: 248)
        case .size205x251:
            return CGSize(width: 205, height: 251)
        case .size211x257:
            return CGSize(width: 211, height: 257)
        }
    }

    var hasRoundedCorners: Bool {
        switch self {
        // Every display Apple has shipped since Series 4 is a rounded rectangle, so new cases
        // belong here. The `false` arm is closed: Series 3 was the last square-cornered watch.
        case .size40mm, .size41mm, .size44mm, .size45mm,
             .size187x223, .size208x248, .size205x251, .size211x257:
            return true
        case .size38mm, .size42mm:
            return false
        }
    }
}
