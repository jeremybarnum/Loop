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
/// SCOPE, AND WHY IT IS THIS NARROW. Four verbs, and every one is a button a human can already
/// press on the phone or the wrist. There is deliberately NO vocabulary for delivering insulin,
/// entering carbs, or changing therapy settings. That is not an oversight to be filled in later: a
/// channel that cannot express a dose cannot be made to command one by a malformed URL, a stale
/// shortcut, or a mistake at three in the morning.
///
/// The boundary is worth stating precisely, because it is not "these verbs are harmless". Three of
/// them MOVE WHO HOLDS THE POD, which is consequential. What none of them does is command a
/// QUANTITY of insulin, and that is the line: the loan lifecycle decides doses, and decides them
/// identically whether a human or this channel opened the loan. Widening past that line needs its
/// own review — `testTheBenchVocabularyCannotExpressADose` fails if anyone tries.
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
///     xcrun simctl openurl booted 'Loop://bench/wake'
///     xcrun simctl openurl booted 'Loop://bench/loan-start'
///     xcrun simctl openurl booted 'Loop://bench/loan-end'
///
/// iOS asks "Open in Loop?" the FIRST time a scheme is used and remembers the answer, so an
/// unattended run needs one confirmation tap before it can run untouched. Verified 2026-08-17.
/// USAGE — device on the same network, app installed:
///     xcrun devicectl device open-url --device <UDID> --url 'Loop://bench/reclaim'
enum BenchRemoteControl {

    /// The URL host that marks a bench command. Distinct from the `Deeplink` hosts, which only
    /// NAVIGATE the UI — these ACT, and the two must never be confused for one another.
    static let host = "bench"

    /// The key a forwarded command travels under on the WatchConnectivity channel. Distinct from
    /// `LoanProtocol.userInfoKey`, so bench traffic can never be mistaken for a loan payload by
    /// either side.
    static let messageKey = "benchCommand"

    enum Command: String, CaseIterable {
        /// Reclaim the pod from the watch. Identical to tapping the pump pill and choosing
        /// Reclaim — the same entry point, so the bench exercises the real path rather than a
        /// parallel one free to drift from it. Handled on the PHONE.
        case reclaim

        /// Take a keepalive hold on the watch so it stops being suspended. This is what makes an
        /// unattended run possible at all: watchOS suspends a backgrounded app within seconds and
        /// nothing wakes it on demand, so without a hold every later command arrives minutes late
        /// or not at all. An HKWorkoutSession is the only self-service API that keeps the process
        /// alive, and holds are refcounted BY REASON — "bench" cannot disturb the loan lifecycle's
        /// own "soak", "takeover" and "handback" holders. It costs battery, so a soak run expects
        /// the watch on the charger.
        case wake

        /// Start a loan: the blue Start Sport Mode button on the wrist.
        case loanStart = "loan-start"

        /// End a loan: the end button on the wrist, which begins hand-back.
        case loanEnd = "loan-end"

        /// True when the phone forwards this to the watch rather than acting on it itself.
        var isForWatch: Bool { self != .reclaim }
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
