//
//  BenchRemoteControl.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import os.log

/// Debug-only URL commands for unattended bench testing.
///
/// WHY. Loan reliability — takeover, hand-back, reclaim — only reveals itself across many cycles,
/// and every cycle currently costs a human pressing a button. That caps an overnight run at
/// however long someone is willing to sit there. This lets the bench be DRIVEN as well as watched:
/// the log pipeline already provides the eyes, this provides the hands.
///
/// SCOPE, AND WHY IT IS THIS NARROW. Exactly one verb, and it is the one the pump pill already
/// offers. There is deliberately NO vocabulary for delivering insulin, entering carbs, changing
/// therapy settings, or altering dosing state. That is not an oversight to be filled in later: a
/// channel that cannot express a dose cannot be made to command one by a malformed URL, a stale
/// shortcut, or a mistake of mine at three in the morning. If a future command is needed, it gets
/// its own review — the restriction is the safety property.
///
/// COMPILED OUT of any build without DEBUG_FEATURES_ENABLED, which stock does not define. This is
/// bench equipment; it must not exist in anything a user runs.
///
/// The scheme is `Loop` — `URL_SCHEME_NAME` resolves from `MAIN_APP_DISPLAY_NAME`, verified in a
/// built Info.plist rather than assumed. It follows the app's display name, so a build that
/// renames the app renames the scheme with it.
///
/// USAGE — simulator:
///     xcrun simctl openurl booted 'Loop://bench/reclaim'
/// USAGE — device on the same network, app installed:
///     xcrun devicectl device open-url --device <UDID> --url 'Loop://bench/reclaim'
enum BenchRemoteControl {

    /// The URL host that marks a bench command. Distinct from the `Deeplink` hosts, which only
    /// NAVIGATE the UI — these ACT, and the two must never be confused for one another.
    static let host = "bench"

    enum Command: String, CaseIterable {
        /// Reclaim the pod from the watch. Identical to tapping the pump pill and choosing
        /// Reclaim — it calls the same entry point, so the bench exercises the real path rather
        /// than a parallel one that could drift from it.
        case reclaim
    }

    /// True if this URL is addressed to the bench channel at all.
    static func isBenchURL(_ url: URL) -> Bool {
        url.host == host
    }

    /// Parse a bench URL into a command. Returns nil for anything unrecognised — an unknown verb
    /// is refused rather than guessed at.
    static func command(from url: URL) -> Command? {
        let verb = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Command(rawValue: verb)
    }
}
