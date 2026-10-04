//
//  SportComplicationPublisher.swift
//  WatchApp Extension
//
//  Feeds the SportComplications widget extension (IOB, COB, eventual BG, BG → eventual).
//  During a loan it publishes the WATCH's own loop (the glance mirror and its COB read);
//  otherwise the phone's context — the glance's own sources, so a complication never
//  disagrees with the Start screen. The snapshot goes to the shared app group; WidgetKit is
//  then asked to reload, at most every 5 minutes because reloads are budgeted (an owed
//  reload is paid on the next publish).
//

import Foundation
import LoopAlgorithm
import LoopCore
import LoopKit
import WidgetKit

enum SportComplicationPublisher {

    static let minimumReloadInterval: TimeInterval = 5 * 60

    private static var lastPublished: SportComplicationSnapshot?
    private static var lastReloadAt = Date.distantPast
    private static var reloadOwed = false

    /// Called on main by the extension delegate (it passes itself: `ExtensionDelegate.shared()`
    /// asserts while a test host is still launching) at each phone context update and, during a
    /// loan, each glance-mirror update.
    @MainActor static func publish(from delegate: ExtensionDelegate) {
        reading(delegate) { snapshot in
            DispatchQueue.main.async { store(snapshot, now: Date()) }
        }
    }

    @MainActor private static func reading(_ delegate: ExtensionDelegate, _ completion: @escaping (SportComplicationSnapshot?) -> Void) {
        let context = delegate.loopManager.activeContext
        let unit = context?.displayGlucoseUnit ?? .milligramsPerDeciliter
        let mmol = unit == .millimolesPerLiter
        func value(_ quantity: LoopQuantity?) -> Double? { quantity?.doubleValue(for: unit) }

        if let session = delegate.stockLoopSession, session.loanController.isLoanActiveNonBlocking,
           let data = session.stack.loopManager.mirroredGlanceData {
            session.stack.loopManager.glanceCarbsOnBoard { cob in
                completion(SportComplicationSnapshot(glucose: value(data.glucose), glucoseDate: data.glucoseDate,
                                                     iob: data.iob, cob: cob, eventual: value(data.eventual),
                                                     loopDate: data.lastLoopCompleted, mmol: mmol))
            }
            return
        }
        guard let context else { return completion(nil) }
        completion(SportComplicationSnapshot(glucose: value(context.glucose), glucoseDate: context.glucoseDate,
                                             iob: context.iob, cob: context.cob, eventual: value(context.eventualGlucose),
                                             loopDate: context.loopLastRunDate, mmol: mmol))
    }

    /// Pure apart from the save and the reload; `now` is a parameter for the tests.
    static func store(_ snapshot: SportComplicationSnapshot?, now: Date,
                      save: (SportComplicationSnapshot) -> Void = { $0.save() },
                      reload: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        if let snapshot, snapshot != lastPublished {
            save(snapshot)
            lastPublished = snapshot
            reloadOwed = true
        }
        guard reloadOwed, now.timeIntervalSince(lastReloadAt) >= minimumReloadInterval else { return }
        reloadOwed = false
        lastReloadAt = now
        reload()
    }

    /// Tests only.
    static func resetForTesting() {
        lastPublished = nil
        lastReloadAt = .distantPast
        reloadOwed = false
    }
}
