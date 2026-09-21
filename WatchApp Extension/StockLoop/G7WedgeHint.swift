//
//  G7WedgeHint.swift
//  WatchApp
//
//  One line on the glance when the watch's own Bluetooth stack looks parked: sensor bursts are
//  due and nothing is being read, and the phone is not covering the gap either.
//
//  The copy must name the WATCH's Bluetooth. Toggling the phone's does nothing for a parked
//  watch stack, and a hint that sends the user to the wrong device is worse than none.
//
//  It is a hint, not an alert: it appears on a screen the user is already looking at and
//  raises nothing.
//

import Foundation

enum G7WedgeHint {
    /// nil unless BOTH conditions hold: no direct reading for 10.5 minutes — two missed bursts
    /// by construction on the G7's 300 s grid, so a single skipped window stays quiet — and no
    /// relayed reading inside the last 10 minutes. A phone that is still relaying means glucose
    /// is arriving, which is not the failure this line describes.
    static func text(directAge: TimeInterval?, relayAge: TimeInterval?) -> String? {
        guard let age = directAge, age >= 10.5 * 60 else { return nil }
        if let r = relayAge, r < 10 * 60 { return nil }
        return String(format: NSLocalizedString("G7 silent %d min · try toggling watch Bluetooth", comment: "Glance line when the watch has missed two or more sensor bursts with the phone away"), Int(age / 60))
    }
}
