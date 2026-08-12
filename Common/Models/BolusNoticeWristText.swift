//
//  BolusNoticeWristText.swift
//  Loop
//
//  #117 (field 2026-08-11): WHY the recommendation is what it is, in wrist-sized words.
//
//  Stock computes a `BolusRecommendationNotice` on every manual-bolus recommendation and the
//  phone surfaces it; the watch was discarding it. That cost a field diagnosis: with the loop
//  correcting at maxBasal, the correct recommendation was 0.00 U, and the wrist showed a bare
//  "REC: 0 U" with no way to tell a legitimate zero from a broken screen. The number was right
//  and unreadable — the same shape as the stuck bolus bar and the stale dial pre-fill, all three
//  found the same evening.
//
//  Lives in Common/Models rather than in the watch view model for one reason: these strings are
//  SAFETY-RELEVANT at a glance — "predicted in range" and "below suspend threshold" both yield a
//  small or zero recommendation for opposite reasons, one meaning nothing to do and the other
//  being a warning — so they need a test, and the watch's SwiftUI view models are not compiled
//  into the test host.
//

import Foundation
import LoopKit

extension BolusRecommendationNotice {
    /// A short sentence for the watch's REC label. Deliberately plain and lower-case: it is read
    /// at a glance by someone deciding whether to dose, so it says what the algorithm SAW rather
    /// than what it did.
    ///
    /// Only the cases stock actually produces are mapped; an ordinary above-range correction
    /// carries no notice, and says nothing rather than padding the label with noise.
    public var wristDescription: String {
        switch self {
        case .predictedGlucoseInRange:
            return NSLocalizedString("predicted in range", comment: "Watch bolus notice: no bolus needed, the prediction is already in range")
        case .glucoseBelowSuspendThreshold:
            return NSLocalizedString("below suspend threshold", comment: "Watch bolus notice: glucose is at or below the suspend threshold")
        case .currentGlucoseBelowTarget:
            return NSLocalizedString("currently below target", comment: "Watch bolus notice: current glucose is below target")
        case .predictedGlucoseBelowTarget:
            return NSLocalizedString("predicted to go low", comment: "Watch bolus notice: the predicted curve dips below target")
        case .allGlucoseBelowTarget:
            return NSLocalizedString("all predicted values below target", comment: "Watch bolus notice: the entire predicted curve is below target")
        }
    }
}
