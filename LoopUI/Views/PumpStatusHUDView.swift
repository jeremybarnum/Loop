//
//  PumpStatusHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-09.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI

public final class PumpStatusHUDView: DeviceStatusHUDView, NibLoadable {
    
    @IBOutlet public weak var basalRateHUD: BasalRateHUDView!
    
    @IBOutlet public weak var pumpManagerProvidedHUD: BaseHUDView!
        
    override public var orderPriority: HUDViewOrderPriority {
        return 3
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }
    
    override func setup() {
        super.setup()
        statusHighlightView.setIconPosition(.left)
    }
    
    public override func tintColorDidChange() {
        super.tintColorDidChange()
        
        basalRateHUD.tintColor = tintColor
    }

    override public func presentStatusHighlight() {
        // Hide the pump-provided pod HUD and the basal-rate HUD whenever a highlight
        // is shown — UNCONDITIONALLY, even if the highlight view is already in the
        // stack. The caller re-adds the pod HUD (visible) on every re-render; guarding
        // the whole method on "already present" (as before) left that re-added pod
        // glyph sitting next to the highlight, widening the tile — the "On Watch is
        // too wide, the pod is still there" regression, surfaced by more frequent
        // re-renders. removeArrangedSubview/isHidden are idempotent, so this is safe
        // to run every time; only the highlight-add step below stays idempotent.
        basalRateHUD.isHidden = true
        statusStackView.removeArrangedSubview(basalRateHUD)

        if let pumpManagerProvidedHUD = pumpManagerProvidedHUD {
            pumpManagerProvidedHUD.isHidden = true
            statusStackView.removeArrangedSubview(pumpManagerProvidedHUD)
        }

        guard !statusStackView.arrangedSubviews.contains(statusHighlightView) else {
            return
        }
        super.presentStatusHighlight()
    }
    
    override public func dismissStatusHighlight() {
        guard statusStackView.arrangedSubviews.contains(statusHighlightView) else {
            return
        }
        
        super.dismissStatusHighlight()
        
        statusStackView.addArrangedSubview(basalRateHUD)
        basalRateHUD.isHidden = false
        
        if let pumpManagerProvidedHUD = pumpManagerProvidedHUD {
            statusStackView.addArrangedSubview(pumpManagerProvidedHUD)
            pumpManagerProvidedHUD.isHidden = false
        }
    }
    
    public func removePumpManagerProvidedHUD() {
        guard let pumpManagerProvidedHUD = pumpManagerProvidedHUD else {
            return
        }
        
        statusStackView.removeArrangedSubview(pumpManagerProvidedHUD)
        pumpManagerProvidedHUD.removeFromSuperview()
    }
    
    public func addPumpManagerProvidedHUDView(_ pumpManagerProvidedHUD: BaseHUDView) {
        self.pumpManagerProvidedHUD = pumpManagerProvidedHUD
        statusStackView.addArrangedSubview(self.pumpManagerProvidedHUD)
    }
    
}
