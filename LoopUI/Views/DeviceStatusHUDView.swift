//
//  DeviceStatusHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-05.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI

@objc open class DeviceStatusHUDView: BaseHUDView {
    
    var statusHighlightView: StatusHighlightHUDView! {
        didSet {
            statusHighlightView.isHidden = true
        }
    }
    
    @IBOutlet private var statusBadgeView: StatusBadgeHUDView! {
        didSet {
            statusBadgeView.isHidden = true
        }
    }
    
    @IBOutlet private weak var progressView: UIProgressView! {
        didSet {
            progressView.isHidden = true
            progressView.tintColor = .systemGray
            // round the edges of the progress view
            progressView.layer.cornerRadius = 2
            progressView.clipsToBounds = true
            progressView.layer.sublayers!.last!.cornerRadius = 2
            progressView.subviews.last!.clipsToBounds = true
        }
    }
    
    @IBOutlet private weak var backgroundView: UIView! {
        didSet {
            backgroundView.backgroundColor = .systemBackground
            backgroundView.layer.cornerRadius = 23
            backgroundView.clipsToBounds = true   // so the fill below honors the pill's radius
        }
    }

    // MARK: - Activity fill (2026-08-04)

    /// A left-to-right fill of the pill's BACKGROUND, behind the icon and text.
    ///
    /// Jeremy, on the thin vertical `progressView` used for pod lifecycle: "that bar sucks and
    /// doesn't work. I'm picturing something moving left to right filling in the background
    /// behind Reclaiming." At 3pt wide against a 46pt pill, the lifecycle bar reads as a
    /// decoration rather than progress — and it is semantically taken anyway (pod EOL /
    /// expiry / fault), so a transient activity indicator must not borrow it.
    ///
    /// This is a separate channel: a tinted view pinned to the pill's leading edge whose width
    /// is a fraction of the pill. It sits at index 0 of `backgroundView`, so the label and icon
    /// always draw on top.
    private lazy var activityFillView: UIView = {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.insertSubview(view, at: 0)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            view.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            view.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
        ])
        let width = view.widthAnchor.constraint(equalTo: backgroundView.widthAnchor, multiplier: 0)
        width.isActive = true
        activityFillWidth = width
        return view
    }()

    private var activityFillWidth: NSLayoutConstraint?

    /// Drive the background fill. `fraction` nil clears it; 0...1 fills that much of the pill.
    /// `animated` lets the caller step it smoothly toward the next value rather than jumping.
    public func setActivityFill(_ fraction: Double?, color: UIColor = .systemOrange, animated: Bool = true) {
        guard let fraction = fraction else {
            activityFillView.isHidden = true
            activityFillWidth?.isActive = false
            activityFillWidth = activityFillView.widthAnchor.constraint(equalTo: backgroundView.widthAnchor, multiplier: 0)
            activityFillWidth?.isActive = true
            return
        }

        activityFillView.isHidden = false
        // Tinted, not opaque: the pill's text must stay legible where the fill has passed.
        activityFillView.backgroundColor = color.withAlphaComponent(0.22)

        activityFillWidth?.isActive = false
        let clamped = CGFloat(fraction.clamped(to: 0...1))
        activityFillWidth = activityFillView.widthAnchor.constraint(equalTo: backgroundView.widthAnchor,
                                                                    multiplier: max(clamped, 0.0001))
        activityFillWidth?.isActive = true

        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
                self.backgroundView.layoutIfNeeded()
            }
        } else {
            backgroundView.layoutIfNeeded()
        }
    }
    
    @IBOutlet weak var statusStackView: UIStackView!
    
    public var lifecycleProgress: DeviceLifecycleProgress? {
        didSet {
            guard let lifecycleProgress = lifecycleProgress else {
                resetProgress()
                return
            }
             
            progressView.isHidden = false
            progressView.progress = Float(lifecycleProgress.percentComplete.clamped(to: 0...1))
            progressView.tintColor = lifecycleProgress.progressState.color
        }
    }
    
    public var adjustViewsForNarrowDisplay: Bool = false {
        didSet {
            if adjustViewsForNarrowDisplay != oldValue {
                NSLayoutConstraint.activate([
                    statusHighlightView.icon.widthAnchor.constraint(equalToConstant: 26),
                    statusHighlightView.icon.heightAnchor.constraint(equalToConstant: 26),
                ])
            } else {
                NSLayoutConstraint.activate([
                    statusHighlightView.icon.widthAnchor.constraint(equalToConstant: 34),
                    statusHighlightView.icon.heightAnchor.constraint(equalToConstant: 34),
                ])
            }
        }
    }
    
    private func resetProgress() {
        progressView.isHidden = true
        progressView.progress = 0
    }
    
    func setup() {
        if statusHighlightView == nil {
            statusHighlightView = StatusHighlightHUDView(frame: self.frame)
        }
    }
    
    public func presentStatusHighlight(_ statusHighlight: DeviceStatusHighlight?) {
        guard let statusHighlight = statusHighlight else {
            dismissStatusHighlight()
            return
        }
        
        presentStatusHighlight(withMessage: statusHighlight.localizedMessage,
                               image: statusHighlight.image,
                               color: statusHighlight.state.color)
    }
    
    private func presentStatusHighlight(withMessage message: String,
                                       image: UIImage?,
                                       color: UIColor)
    {
        statusHighlightView.messageLabel.text = message
        statusHighlightView.messageLabel.tintColor = .label
        statusHighlightView.icon.image = image
        statusHighlightView.icon.tintColor = color
        presentStatusHighlight()
    }
    
    func presentStatusHighlight() {
        statusStackView?.addArrangedSubview(statusHighlightView)
        statusHighlightView.isHidden = false
    }
    
    func dismissStatusHighlight() {
        // need to also hide this view, since it will be added back to the stack at some point
        statusHighlightView.isHidden = true
        statusStackView?.removeArrangedSubview(statusHighlightView)
    }
    
    public func presentStatusBadge(_ statusBadge: DeviceStatusBadge?) {
        guard let statusBadge = statusBadge else {
            dismissStatusBadge()
            return
        }
        
        presentStatusBadge(withIcon: statusBadge.image,
                           color: statusBadge.state.color)
    }
    
    private func presentStatusBadge(withIcon badgeIcon: UIImage?,
                                    color: UIColor) {
        statusBadgeView.setBadgeIcon(badgeIcon)
        statusBadgeView.tintColor = color
        presentStatusBadge()
    }
    
    private func presentStatusBadge() {
        statusBadgeView.isHidden = false
    }
    
    private func dismissStatusBadge() {
        statusBadgeView.isHidden = true
    }
}
