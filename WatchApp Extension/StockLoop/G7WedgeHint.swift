//
//  G7WedgeHint.swift
//  WatchApp
//
//  The glance's "watch Bluetooth" hint. Two or more consecutive expected bursts with no direct
//  read, with the phone not relaying — the indicia of a parked watch Bluetooth stack (mute
//  record §7c). The only cure short of waiting 20–45 min is the WATCH's Bluetooth off and on;
//  ruled wording 2026-09-05: it must name the watch — the phone's Bluetooth does nothing for
//  this. Not an alert. Derived from state rather than counted per window: 10.5 min of direct
//  silence is two missed bursts by construction on the 300-s grid.
//

import Foundation

enum G7WedgeHint {
    static func text(directAge: TimeInterval?, relayAge: TimeInterval?) -> String? {
        guard let age = directAge, age >= 10.5 * 60 else { return nil }
        if let r = relayAge, r < 10 * 60 { return nil }
        return String(format: NSLocalizedString("G7 silent %d min · try toggling watch Bluetooth", comment: "Glance line when the watch has missed two or more sensor bursts with the phone away"), Int(age / 60))
    }
}
