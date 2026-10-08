//
//  GlanceComplicationPublisher.swift
//  WatchApp Extension
//
//  Feeds the Sport glance complication (Loop Complications, kind "LoopGlance"). Its source is the
//  glance's: during a loan the watch's own loop, through `GlanceViewModel.activeState` over the glance
//  mirror; otherwise the phone's context, which on next-dev carries the watch's own G7 reading. So a
//  complication never disagrees with the Start screen. Published at every wake — each landed cycle
//  during a loan, each context update otherwise. Every change is saved; WidgetKit is asked to redraw
//  by GlanceReloadPolicy, which spends watchOS's reload budget on the reading.
//

import Foundation
import LoopAlgorithm
import LoopCore
import LoopKit
import WatchKit
import WidgetKit

enum GlanceComplicationPublisher {

    private static var policy = GlanceReloadPolicy()

    /// Called on main by the extension delegate, which passes itself (`ExtensionDelegate.shared()`
    /// asserts while a test host is still launching).
    @MainActor static func publish(from delegate: ExtensionDelegate, onOpen: Bool = false) {
        let context = delegate.loopManager.activeContext
        let unit = context?.displayGlucoseUnit ?? .milligramsPerDeciliter

        if let session = delegate.stockLoopSession, session.loanController.isLoanActiveNonBlocking,
           let data = session.stack.loopManager.mirroredGlanceData {
            session.stack.loopManager.glanceCarbsOnBoard { cob in
                Task { @MainActor in
                    store(snapshot(loan: data, cob: cob, unit: unit, now: Date()), source: "watch loop", onOpen: onOpen)
                }
            }
            return
        }
        guard let context else { return }
        store(snapshot(phone: context, override: delegate.loopManager.watchInfo.scheduleOverride,
                       suspendThreshold: delegate.loopManager.watchInfo.loopSettings.suspendThreshold?.quantity),
              source: "phone context", onOpen: onOpen)
    }

    /// The watch holds the pod: the glance's own frame, with the reading in the display unit.
    @MainActor static func snapshot(loan data: WatchLoopManager.GlanceData, cob: Double?, unit: LoopUnit, now: Date) -> GlanceComplicationSnapshot {
        let glance = GlanceViewModel.activeState(data: data, cob: cob, now: now)
        let formatter = NumberFormatter.glucoseFormatter(for: unit)
        func text(_ quantity: LoopQuantity?) -> String? { quantity.flatMap { formatter.string(from: $0.doubleValue(for: unit)) } }

        var s = loop(date: data.lastLoopCompleted, closed: data.closedLoopEnabled)
        s.bgText = text(data.glucose)
        s.trendSymbol = data.trend?.symbol
        s.bgStaleAt = data.glucoseDate.map { $0.addingTimeInterval(LoopAlgorithm.inputDataRecencyInterval) }
        s.bgDate = data.glucoseDate
        switch glance.bgColor {
        case .low: s.bgRange = .low
        case .inRange: s.bgRange = .inRange
        case .high: s.bgRange = .high
        case .dim: s.bgRange = nil
        }
        s.eventualText = text(data.eventual)
        s.iobText = data.iob == nil ? nil : glance.iobText
        s.cobText = cob == nil ? nil : glance.cobText
        s.tempText = data.tempRate == nil ? nil : glance.tempText
        s.overrideLabel = glance.overrideLabel
        s.watchHasPod = true
        return s
    }

    /// The phone loops: its context, formatted as the glance formats.
    static func snapshot(phone context: WatchContext, override: TemporaryScheduleOverride?,
                         suspendThreshold: LoopQuantity? = nil) -> GlanceComplicationSnapshot {
        let unit = context.displayGlucoseUnit ?? .milligramsPerDeciliter
        let formatter = NumberFormatter.glucoseFormatter(for: unit)

        var s = loop(date: context.loopLastRunDate, closed: context.isClosedLoop ?? true)
        s.bgText = context.glucoseCondition?.localizedDescription
            ?? context.glucose.flatMap { formatter.string(from: $0.doubleValue(for: unit)) }
        s.trendSymbol = context.glucoseTrend?.symbol
        // Coloured as during a loan; who holds the pod is the icon's job, not the colour's.
        s.bgRange = context.glucose.map { range(mgdl: $0.doubleValue(for: .milligramsPerDeciliter), suspendThreshold: suspendThreshold) }
        s.bgStaleAt = context.glucoseDate.map { $0.addingTimeInterval(LoopAlgorithm.inputDataRecencyInterval) }
        s.bgDate = context.glucoseDate
        s.eventualText = context.eventualGlucose.flatMap { formatter.string(from: $0.doubleValue(for: unit)) }
        s.iobText = context.iob.map { String(format: "%.1f", $0) }
        s.cobText = context.cob.map { String(format: "%.0f", $0) }
        s.tempText = context.lastNetTempBasalDose.map { String(format: "%+.2f", $0) }
        s.overrideLabel = WatchLoopManager.overrideLabel(for: override)
        return s
    }

    /// The glance's colour rule (GlanceViewModel.activeState): low below the suspend threshold (70 if
    /// unknown), high above 180.
    static func range(mgdl: Double, suspendThreshold: LoopQuantity?) -> GlanceComplicationSnapshot.BGRange {
        let low = suspendThreshold?.doubleValue(for: .milligramsPerDeciliter) ?? 70
        return mgdl < low ? .low : (mgdl > 180 ? .high : .inRange)
    }

    /// The loop's ring and the moment its values go stale, from one cycle date.
    private static func loop(date: Date?, closed: Bool) -> GlanceComplicationSnapshot {
        var s = GlanceComplicationSnapshot()
        s.loopClosed = closed
        s.loopDate = date
        s.loopValuesStaleAt = date.map { $0.addingTimeInterval(LoopAlgorithm.inputDataRecencyInterval) }
        s.freshUntil = date.flatMap { d in LoopCompletionFreshness.fresh.maxAge.map { d.addingTimeInterval($0) } }
        s.agingUntil = date.flatMap { d in LoopCompletionFreshness.aging.maxAge.map { d.addingTimeInterval($0) } }
        return s
    }

    /// The last publish, for the diagnostics line.
    private static var lastLoggedAt = Date()

    @MainActor private static func store(_ snapshot: GlanceComplicationSnapshot, source: String, onOpen: Bool = false) {
        let now = Date()
        // In front, a reload costs no budget (Apple DTS); chronod logs each request's treatment.
        let free = WKApplication.shared().applicationState == .active
        let decision = policy.offer(snapshot, now: now, free: free, opened: onOpen && free)
        if decision.save { snapshot.save() }
        if decision.reload != nil { WidgetCenter.shared.reloadTimelines(ofKind: GlanceComplicationKind.kind) }

        // Requested vs served redraws, and how old the shown values are. Only when something happened:
        // the glance republishes on every 2 s repaint while it is on screen.
        guard decision.save || decision.reload != nil else { return }
        let served = GlanceComplicationSnapshot.served(after: lastLoggedAt)
        lastLoggedAt = now
        func age(_ date: Date?) -> String { date.map { "\(Int(now.timeIntervalSince($0)))s" } ?? "n/a" }
        let reload = decision.reload.map { "requested(\($0))" } ?? (policy.owed ? "owed" : "none")
        let metrics = Set(served.map(\.metric)).sorted().joined(separator: ",")
        SportLog.event("complication", "glance publish src=\(source) changed=\(decision.save) reload=\(reload) · served since last: \(served.count) [\(metrics)] · BG age \(age(snapshot.bgDate)) · loop age \(age(snapshot.loopDate))")
    }
}

/// When to ask WidgetKit to redraw the glance complication: whenever what the face would show has
/// changed. In front a reload is free, so it goes at once, and opening the app always reloads (a request
/// is not a drawn reload: watchOS may never run it). In the background, at most one request per
/// `freeWindow`; a change inside the window waits for the next chance, carrying everything since.
struct GlanceReloadPolicy {
    /// On a watch with the developer exemption, watchOS grants a complication one free background reload
    /// per 300 s and charges any other request in that window to the reload budget (measured 2026-10-07:
    /// granted at ≥ 300 s, refused at < 300 s, no daily cap). Any request starts the window, in front or
    /// not; a background request inside it can only be refused. 300 s is also the G7's cadence.
    static let freeWindow: TimeInterval = 300

    private(set) var lastSaved: GlanceComplicationSnapshot?
    /// What the face was last asked to draw, and when.
    private(set) var lastRequested: GlanceComplicationSnapshot?
    private(set) var lastRequestAt: Date?

    /// A change the face has not been asked to draw.
    var owed: Bool { lastSaved != nil && lastSaved != lastRequested }

    /// `save`: the snapshot changed. `reload`: why WidgetKit is asked to redraw now, nil if it is not.
    mutating func offer(_ snapshot: GlanceComplicationSnapshot, now: Date, free: Bool, opened: Bool = false) -> (save: Bool, reload: String?) {
        let changed = snapshot != lastSaved
        if changed { lastSaved = snapshot }
        let reason: String
        if opened {
            reason = "opened"
        } else {
            guard snapshot != lastRequested else { return (changed, nil) }
            if !free, let last = lastRequestAt, now.timeIntervalSince(last) < Self.freeWindow { return (changed, nil) }
            reason = free ? "free" : (lastRequested == nil ? "first" : "changed")
        }
        lastRequested = snapshot
        lastRequestAt = now
        return (changed, reason)
    }
}
