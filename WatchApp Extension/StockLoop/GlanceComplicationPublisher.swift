//
//  GlanceComplicationPublisher.swift
//  WatchApp Extension
//
//  Feeds the Sport glance complication (Loop Complications, kind "LoopGlance"). Its source is the
//  glance's: during a loan the watch's own loop, through `GlanceViewModel.activeState` over the glance
//  mirror; otherwise the phone's context, which on next-dev carries the watch's own G7 reading. So a
//  complication never disagrees with the Start screen. Published at every wake — each landed cycle
//  during a loan, each context update otherwise. Every change is saved; WidgetKit is asked to redraw
//  by GlanceReloadPolicy, which spends watchOS's one free refresh per 300 s on the reading.
//

import Foundation
import G7SensorKit
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
                    store(snapshot(loan: data, cob: cob, unit: unit, now: Date()), source: "watch loop", onOpen: onOpen,
                          sensorLinkUp: sensorLinkUp(delegate))
                }
            }
            return
        }
        guard let context else { return }
        store(snapshot(phone: context, override: delegate.loopManager.watchInfo.scheduleOverride,
                       suspendThreshold: delegate.loopManager.watchInfo.loopSettings.suspendThreshold?.quantity),
              source: "phone context", onOpen: onOpen, sensorLinkUp: sensorLinkUp(delegate))
    }

    /// When the watch's G7 link last came up: a background reload is free only while the app holds a
    /// Bluetooth connection, and not in its first moments (see GlanceReloadPolicy.linkSettle).
    @MainActor private static func sensorLinkUp(_ delegate: ExtensionDelegate) -> Date? {
        (delegate.stockLoopSession?.stack.loopManager.cgmManager as? G7CGMManager)?.lastConnect
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

    @MainActor private static func store(_ snapshot: GlanceComplicationSnapshot, source: String, onOpen: Bool = false,
                                         sensorLinkUp: Date? = nil) {
        let now = Date()
        let inFront = WKApplication.shared().applicationState == .active
        let changed = policy.save(snapshot, at: now)
        if changed { snapshot.save() }
        let lastRender = GlanceComplicationSnapshot.lastServed()
        let plan = policy.plan(now: now, inFront: inFront, opened: onOpen && inFront, sensorLinkUp: sensorLinkUp,
                               lastRenderAt: lastRender)
        if let plan { schedule(plan.at, sensorLinkUp: sensorLinkUp) }

        // Requested vs served redraws, and how old the shown values are. Only when something happened:
        // the glance republishes on every 2 s repaint while it is on screen.
        guard changed || plan != nil else { return }
        let served = GlanceComplicationSnapshot.served(after: lastLoggedAt)
        lastLoggedAt = now
        func age(_ date: Date?) -> String { date.map { "\(Int(now.timeIntervalSince($0)))s" } ?? "n/a" }
        let wait = plan.map { $0.at.timeIntervalSince(now) } ?? 0
        let reload = plan.map { wait > 0.05 ? String(format: "requested(%@, in %.1f s)", $0.reason, wait) : "requested(\($0.reason))" }
            ?? (policy.behind(lastRenderAt: lastRender) ? "owed" : "none")
        let metrics = Set(served.map(\.metric)).sorted().joined(separator: ",")
        SportLog.event("complication", "glance publish src=\(source) changed=\(changed) reload=\(reload) · served since last: \(served.count) [\(metrics)] · BG age \(age(snapshot.bgDate)) · loop age \(age(snapshot.loopDate))")
    }

    /// The deferred request, if one is waiting.
    private static var pendingAt: Date?

    /// Asks WidgetKit at `at`, keeping the process up until then (the sensor's hold covers 35 s from link-up;
    /// a request at the re-lodge needs a few seconds more).
    @MainActor private static func schedule(_ at: Date, sensorLinkUp: Date?) {
        let wait = at.timeIntervalSinceNow
        guard wait > 0.05 else { fire(sensorLinkUp: sensorLinkUp); return }
        if let pending = pendingAt, pending <= at { return }
        pendingAt = at
        let release = holdProcess(reason: "glance complication request", upTo: wait + 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            pendingAt = nil
            fire(sensorLinkUp: sensorLinkUp)
            release()
        }
    }

    /// Plans again at the moment (the widget may have rendered meanwhile); after asking, looks again a few seconds
    /// later: a refused request renders nothing, and the cycle's next window can try again.
    @MainActor private static func fire(sensorLinkUp: Date?) {
        let now = Date()
        let inFront = WKApplication.shared().applicationState == .active
        guard let plan = policy.plan(now: now, inFront: inFront, opened: false, sensorLinkUp: sensorLinkUp,
                                     lastRenderAt: GlanceComplicationSnapshot.lastServed()),
              plan.at.timeIntervalSince(now) <= 0.05 else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: GlanceComplicationKind.kind)
        guard !inFront else { return }
        let release = holdProcess(reason: "glance complication check", upTo: GlanceReloadPolicy.renderCheck + 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + GlanceReloadPolicy.renderCheck) {
            let later = Date()
            if let retry = policy.plan(now: later, inFront: false, opened: false, sensorLinkUp: sensorLinkUp,
                                       lastRenderAt: GlanceComplicationSnapshot.lastServed()) {
                SportLog.event("complication", String(format: "glance request not rendered — trying again in %.1f s", retry.at.timeIntervalSince(later)))
                schedule(retry.at, sensorLinkUp: sensorLinkUp)
            }
            release()
        }
    }

    /// As G7WatchAcquisition's process hold (performExpiringActivity, once-only): released when the returned
    /// closure is called or `wait` elapses, whichever first.
    private static func holdProcess(reason: String, upTo wait: TimeInterval) -> () -> Void {
        let gate = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
                if expired { gate.signal(); return }
                _ = gate.wait(timeout: .now() + wait)
            }
        }
        return { gate.signal() }
    }
}

/// When to ask WidgetKit to redraw the glance complication.
///
/// The rule it works under (watchOS 26, measured 2026-10-05 to 10-08, real pod and emulator): the widget daemon
/// grants a background reload free only while the app is connected to a Bluetooth peripheral — the G7 link, or a
/// pending connect — and only one per 300 s; anything else is charged to a reload budget this complication does
/// not have. The G7 reads every 300 s too, with ±2 s of jitter, so a request tied to each reading is refused about
/// half the time. An app open while connected spends the 300-s slot as well.
///
/// What the face shows comes from the widget's own record: each granted reload builds a timeline from the saved
/// snapshot and notes the time (`GlanceComplicationSnapshot.noteServed`). So the face is behind when nothing was
/// built since the snapshot changed, and the daemon's 300-s period runs from that build. A request is not a draw.
///
/// In the background, a change goes at the first moment that is connected and 300.1 s after the last build — just
/// after the link settles, else at the re-lodge 35 s after link-up (its pending connect counts); a request that
/// built nothing is tried again in the next window. Outside those windows a change waits for the next reading.
/// In front, a request goes only when the face is behind on the reading, so opening the app does not spend the
/// slot the next reading needs (modelled: readings never drawn 43 % → ~1–2 %, typical delay ~40 s).
struct GlanceReloadPolicy {
    /// The daemon's 300-s period, plus a margin.
    static let minimumSpacing: TimeInterval = 300.1
    /// At the instant the link comes up, Bluetooth may not yet report the app as connected: requests 0.1–0.7 s
    /// after link-up were refused (3 of 28), from about 1 s on they were free.
    static let linkSettle: TimeInterval = 1.2
    /// The G7 link lasts 3.6 s or more after link-up.
    static let linkEnd: TimeInterval = 3.3
    /// The re-lodge — a pending connect — comes 35 s after link-up (G7WatchAcquisition.tailClearanceSeconds).
    static let lodgeStart: TimeInterval = 35.5
    /// How long after link-up a deferred request may still wait for, holding the process.
    static let lodgeEnd: TimeInterval = 45
    /// A granted reload builds within about a second; after this, no build means refused.
    static let renderCheck: TimeInterval = 2.5

    private(set) var lastSaved: GlanceComplicationSnapshot?
    /// When the saved snapshot last changed, and when its reading did.
    private(set) var changedAt: Date?
    private(set) var readingChangedAt: Date?

    /// Keeps the snapshot; true when it changed.
    mutating func save(_ snapshot: GlanceComplicationSnapshot, at now: Date) -> Bool {
        guard snapshot != lastSaved else { return false }
        if snapshot.bgDate != lastSaved?.bgDate { readingChangedAt = now }
        lastSaved = snapshot
        changedAt = now
        return true
    }

    /// Nothing built since the snapshot changed.
    func behind(lastRenderAt: Date?) -> Bool {
        guard let changedAt else { return false }
        return (lastRenderAt ?? .distantPast) < changedAt
    }

    /// Nothing built since the reading changed.
    func readingBehind(lastRenderAt: Date?) -> Bool {
        guard let readingChangedAt else { return false }
        return (lastRenderAt ?? .distantPast) < readingChangedAt
    }

    /// Connected at `t`, as far as timing tells: the G7 link, or the pending connect from the re-lodge on.
    static func attached(at t: Date, sensorLinkUp: Date?) -> Bool {
        guard let linkUp = sensorLinkUp else { return false }
        let s = t.timeIntervalSince(linkUp)
        return (s >= 0 && s <= linkEnd + 0.3) || s >= lodgeStart - 0.5
    }

    /// When to ask, and why; nil = not now and not in this cycle's windows.
    func plan(now: Date, inFront: Bool, opened: Bool, sensorLinkUp: Date?, lastRenderAt: Date?) -> (at: Date, reason: String)? {
        if inFront {
            guard readingBehind(lastRenderAt: lastRenderAt) else { return nil }
            return (now, opened ? "opened" : "free")
        }
        guard behind(lastRenderAt: lastRenderAt), let linkUp = sensorLinkUp else { return nil }
        let reason = lastRenderAt == nil ? "first" : "changed"
        let earliest = max(now, lastRenderAt.map { $0.addingTimeInterval(Self.minimumSpacing) } ?? now)
        for (a, b) in [(Self.linkSettle, Self.linkEnd), (Self.lodgeStart, Self.lodgeEnd)] {
            let t = max(earliest, linkUp.addingTimeInterval(a))
            if t <= linkUp.addingTimeInterval(b) { return (t, reason) }
        }
        return nil
    }
}
