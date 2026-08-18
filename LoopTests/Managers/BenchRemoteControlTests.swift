//
//  BenchRemoteControlTests.swift
//  LoopTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import LoopCore
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
    func testEveryVerbParsesFromItsURL() {
        let expected: [String: BenchRemoteControl.Command] = [
            "reclaim": .reclaim, "wake": .wake, "loan-start": .loanStart, "loan-end": .loanEnd,
        ]
        for (verb, command) in expected {
            let url = URL(string: "Loop://bench/\(verb)")!
            XCTAssertTrue(BenchRemoteControl.isBenchURL(url))
            XCTAssertEqual(BenchRemoteControl.command(from: url), command, "\(verb) must parse")
        }
    }

    func testUnknownVerbsAreRefused() {
        for verb in ["", "start", "bolus", "deliver", "reclaim-now", "RECLAIM", "../reclaim",
                     "loanStart", "loan_start", "Loan-Start", "wake-up"] {
            let url = URL(string: "Loop://bench/\(verb)")!
            XCTAssertNil(BenchRemoteControl.command(from: url),
                         "'\(verb)' must not parse as a command")
        }
    }

    /// The safety property, stated as a test. The vocabulary is pinned to an exact list, so adding
    /// a verb fails here and forces the conversation rather than sliding in.
    ///
    /// The list grew from one to four on 2026-08-17, deliberately and with review. The boundary is
    /// NOT "these verbs are harmless" — three of them move who holds the pod, which is
    /// consequential. The boundary is that none of them commands a QUANTITY of insulin: every one
    /// is a button a human can already press, and the loan lifecycle decides doses identically
    /// whether a human or this channel opened the loan.
    func testTheBenchVocabularyCannotExpressADose() {
        XCTAssertEqual(Set(BenchRemoteControl.Command.allCases.map(\.rawValue)),
                       ["reclaim", "wake", "loan-start", "loan-end"],
                       "the bench channel must not grow a vocabulary without review")

        // Named explicitly so a future addition trips on the intent, not just the count.
        for forbidden in ["bolus", "carbs", "deliver", "dose", "units", "basal", "suspend", "resume", "target"] {
            XCTAssertFalse(BenchRemoteControl.Command.allCases.contains { $0.rawValue.contains(forbidden) },
                           "'\(forbidden)' would let this channel command therapy — it must not exist here")
        }
    }

    /// Only reclaim is the phone's to act on; the rest are carried to the wrist. Getting this
    /// backwards would have the phone silently swallow a command meant for the watch.
    func testOnlyReclaimIsHandledOnThePhone() {
        XCTAssertFalse(BenchRemoteControl.Command.reclaim.isForWatch)
        for c in [BenchRemoteControl.Command.wake, .loanStart, .loanEnd] {
            XCTAssertTrue(c.isForWatch, "\(c.rawValue) must be forwarded to the watch")
        }
    }

    /// The forwarding key must never collide with loan traffic, or a bench command could be parsed
    /// as a loan payload — or worse, a loan payload as a bench command.
    func testTheBenchKeyIsNotTheLoanKey() {
        XCTAssertNotEqual(BenchRemoteControl.messageKey, LoanProtocol.userInfoKey)
    }

    #endif
}
