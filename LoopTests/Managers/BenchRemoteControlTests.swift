//
//  BenchRemoteControlTests.swift
//  LoopTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import Loop

/// The bench channel's parsing, which is the whole of its attack surface.
///
/// These matter more than their size suggests: this channel commands a pod on a live insulin rig,
/// and the property that makes it safe is that its vocabulary is TINY and closed. A parser that
/// accepted a little more than intended — a path that fell through, a host that matched loosely —
/// would quietly widen it. So the negative cases are the point, not the positive one.
final class BenchRemoteControlTests: XCTestCase {

    #if DEBUG_FEATURES_ENABLED

    func testRecognisesTheReclaimCommand() {
        let url = URL(string: "Loop://bench/reclaim")!
        XCTAssertTrue(BenchRemoteControl.isBenchURL(url))
        XCTAssertEqual(BenchRemoteControl.command(from: url), .reclaim)
    }

    /// Navigation deeplinks must not be mistaken for bench commands, and vice versa. They live in
    /// the same URL space and mean entirely different things — one moves the UI, one moves a pod.
    func testNavigationDeeplinksAreNotBenchURLs() {
        for host in ["carb-entry", "manual-bolus", "pre-meal-preset", "custom-presets"] {
            let url = URL(string: "Loop://\(host)")!
            XCTAssertFalse(BenchRemoteControl.isBenchURL(url),
                           "\(host) is a navigation deeplink and must never route to the bench channel")
        }
    }

    /// An unknown verb is REFUSED, not guessed at. The dispatcher logs and drops it.
    func testUnknownVerbsAreRefused() {
        for verb in ["", "start", "bolus", "deliver", "reclaim-now", "RECLAIM", "../reclaim"] {
            let url = URL(string: "Loop://bench/\(verb)")!
            XCTAssertNil(BenchRemoteControl.command(from: url),
                         "'\(verb)' must not parse as a command")
        }
    }

    /// The safety property, stated as a test: there is exactly one verb, and it is not a dosing
    /// verb. If someone adds a command that can deliver insulin, enter carbs, or change therapy
    /// settings, this fails and forces the conversation.
    func testTheVocabularyIsExactlyOneNonDosingVerb() {
        XCTAssertEqual(BenchRemoteControl.Command.allCases.map(\.rawValue), ["reclaim"],
                       "the bench channel must not grow a vocabulary without review — and must never gain a dosing verb")
    }

    #endif
}
