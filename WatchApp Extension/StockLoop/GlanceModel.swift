//
//  GlanceModel.swift
//  WatchApp Extension
//

import Foundation
import SwiftUI
import Combine
import WatchKit
import HealthKit
import LoopKit
import LoopCore
import G7SensorKit

struct GlanceUIState {
    enum Phase { case idle, starting, active, handingBack, draining }
    enum BGColor { case inRange, high, low, dim }

    enum LoopFreshness { case fresh, aging, stale, unknown }

    var phase: Phase = .idle
    var bgText: String = "—"
    var trendSymbol: String? = nil
    var bgColor: BGColor = .dim

    var staleAgeText: String? = nil
    var eventualText: String? = nil
    var iobText: String = "—"
    var cobText: String = "—"
    var tempText: String = "—"
    var loopStatusText: String = ""
    var loopFreshness: LoopFreshness = .unknown

    var predictionStale: Bool = false

    var seizeOfferAgeText: String? = nil

    var reunionPrompt: Bool = false
    var viaPhone: Bool = false

    enum BGSource { case directG7, phoneRelay, none }
    var bgSource: BGSource = .none

    var transientText: String? = nil

    var loopClosed: Bool = false

    var idleNote: String? = nil

    var phoneUnreachable: Bool = false

    var startedAt: Date? = nil

    var startingStageText: String? = nil

    var g7EtaText: String? = nil

    var bolusDelivery: (units: Double, startedAt: Date, endsAt: Date)? = nil

    var overrideLabel: String? = nil
    var handbackPending: Bool = false

    var handbackStartedAt: Date? = nil
}

@MainActor
final class GlanceViewModel: ObservableObject {
    @Published var state = GlanceUIState()

    @Published var hasControllerState = false

    var loanIsLive: Bool {
        ExtensionDelegate.sharedIfAvailable()?.stockLoopSession?.loanController.isLoanActiveNonBlocking ?? false
    }

    var isResuming: Bool {
        ExtensionDelegate.sharedIfAvailable()?.stockLoopSession?.loanController.isResumingNonBlocking ?? false
    }

    var wantsFocus: Bool {
        switch state.phase {
        case .starting, .active, .handingBack, .draining: return true
        case .idle: return false
        }
    }

    private var timer: Timer?
    private var latestCOB: Double?

    private var lastRenderLogAt: Date?
    private var lastRenderLogKey: String?
    private var latestCOBAt: Date?
    private var appStateObservers: [NSObjectProtocol] = []
    private let isPreview: Bool

    private static let displayStaleAge: TimeInterval = 7 * 60

    static let unitsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    init() {
        isPreview = false

        observeAppState()
    }

    private func observeAppState() {
        let center = NotificationCenter.default
        appStateObservers = [
            center.addObserver(forName: ExtensionDelegate.didBecomeActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.startRefreshing()
            },
            center.addObserver(forName: ExtensionDelegate.willResignActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.stopRefreshing()
            },
        ]
    }

    private var mirrorObserver: NSObjectProtocol?

    func startRefreshing() {
        guard !isPreview else { return }
        RuntimeStateLog.mark("glance.startRefreshing")
        SportLog.event("glance", "render loop STARTED [glance-life]")
        if let o = oneShotMirrorObserver { NotificationCenter.default.removeObserver(o); oneShotMirrorObserver = nil }
        if mirrorObserver == nil {
            mirrorObserver = NotificationCenter.default.addObserver(
                forName: WatchLoopManager.glanceMirrorDidUpdate, object: nil, queue: .main
            ) { [weak self] _ in self?.refresh(kickMirror: false) }
        }

        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private var boundaryTimer: Timer?

    private func armFreshnessBoundaryRepaint() {
        boundaryTimer?.invalidate(); boundaryTimer = nil
        guard state.phase == .active,
              let last = ExtensionDelegate.sharedIfAvailable()?.stockLoopSession?.stack.loopManager.mirroredGlanceData?.lastLoopCompleted
        else { return }
        let age = Date().timeIntervalSince(last)
        let boundaries: [TimeInterval] = [6 * 60, 16 * 60]
        guard let next = boundaries.first(where: { $0 > age }) else { return }
        let delay: TimeInterval = next - age + 1
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            SportLog.event("glance", "freshness boundary passed — self-repaint [glance-life]")
            self?.refreshNow()
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        boundaryTimer = t
    }

    private var oneShotMirrorObserver: NSObjectProtocol?

    func refreshNow() {
        guard !isPreview else { return }
        RuntimeStateLog.mark("glance.refreshNow")
        if mirrorObserver == nil, oneShotMirrorObserver == nil {
            oneShotMirrorObserver = NotificationCenter.default.addObserver(
                forName: WatchLoopManager.glanceMirrorDidUpdate, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                if let o = self.oneShotMirrorObserver {
                    NotificationCenter.default.removeObserver(o)
                    self.oneShotMirrorObserver = nil
                }
                self.refresh(kickMirror: false)
            }
        }
        refresh()
    }

    func stopRefreshing() {
        RuntimeStateLog.mark("glance.stopRefreshing")
        SportLog.event("glance", "render loop STOPPED [glance-life]")

        timer?.invalidate()
        timer = nil
    }

    init(preview: GlanceUIState) {
        isPreview = true
        state = preview
    }

    deinit {
        if let o = mirrorObserver { NotificationCenter.default.removeObserver(o) }
        if let o = oneShotMirrorObserver { NotificationCenter.default.removeObserver(o) }
        timer?.invalidate()
        appStateObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func cancelHandback() {
        guard !isPreview else { return }

        WKInterfaceDevice.current().play(.click)
        state.handbackPending = false

        ExtensionDelegate.sharedIfAvailable()?.stockLoopSession?.loanController.cancelHandback()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    func confirmSeize() {
        guard !isPreview else { return }
        RuntimeStateLog.mark("glance.confirmSeize")
        ExtensionDelegate.sharedIfAvailable()?.stockLoopSession?.loanController.confirmSeize()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    func dismissSeize() {
        guard !isPreview else { return }
        ExtensionDelegate.sharedIfAvailable()?.stockLoopSession?.loanController.dismissSeize()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    func startSportMode() {
        RuntimeStateLog.mark("glance.startSportMode")
        guard !isPreview else { return }

        let build = BuildDetails.default.codeIdentity

        guard let session = ExtensionDelegate.sharedIfAvailable()?.stockLoopSession else {
            let why = ExtensionDelegate.sharedIfAvailable() == nil ? "no app delegate" : "no session"
            SportLog.event("session", "START TAPPED but Sport Mode is unavailable (\(why)) — the stack never assembled · build \(build)")
            return
        }

        switch session.stack.loopManager.sportModeStartGate() {
        case .allowed:
            break
        case .noSensorEverEnrolled:

            SportLog.event("loan", "START with NO SENSOR EVER ENROLLED — loan will run on relayed BG alone and will stop looping if the phone leaves; proceeding (bench rigs look identical from here)")
        case .waitingForFirstReading(let sensorName):

            SportLog.event("loan", "START with sensor \(sensorName) enrolled but no direct reading yet on this watch — proceeding")
        case .noDirectConnection(let sensorName, let silentMinutes):

            SportLog.event("loan", "START with no direct BG from \(sensorName) for \(silentMinutes)m — expected between loans (no runtime, no radio); proceeding, but a relay-only loan stops looping if the phone leaves")
        }
        session.loanController.requestLoan(watchBuild: build)

        session.sendLogSnapshot("sport start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) {
            session.sendLogSnapshot("start +35s")
        }
        refresh()
    }

    func endSportMode() {
        RuntimeStateLog.mark("glance.endSportMode")
        guard !isPreview else { state.handbackPending = true; return }

        WKInterfaceDevice.current().play(.click)
        state.handbackPending = true

        ExtensionDelegate.sharedIfAvailable()?.stockLoopSession?.loanController.beginHandback()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    func setLoopClosed(_ closed: Bool) {
        guard !isPreview else {
            state.loopClosed = closed
            state.loopStatusText = closed ? "CLOSED · 0m" : "OPEN"
            return
        }
        ExtensionDelegate.sharedIfAvailable()?.stockLoopSession?.stack.loopManager.setClosedLoopEnabled(closed)
        refresh()
    }

    private func refresh(kickMirror: Bool = true) {
        guard !isPreview else { return }
        RuntimeStateLog.mark("glance.refresh(kick:\(kickMirror))")
        guard let session = ExtensionDelegate.sharedIfAvailable()?.stockLoopSession else { return }

        RuntimeStateLog.mark("glance.refresh.debugSnap")
        session.loanController.refreshDebugSnapshot()
        RuntimeStateLog.mark("glance.refresh.mirrorRead")
        guard let snap = session.loanController.mirroredDebugSnapshot else { return }
        if !hasControllerState { hasControllerState = true }
        RuntimeStateLog.mark("glance.refresh.phase(\(snap.phase.rawValue))")
        defer { armFreshnessBoundaryRepaint() }

        switch snap.phase {
        case .idle:

            var idle = Self.idleState(context: ExtensionDelegate.sharedIfAvailable()?.loopManager.activeContext,
                                      note: snap.lastIdleNote ?? G7WatchDirectRead.needsCodeNote)

            if let issued = snap.seizeOfferIssuedAt {
                let f = DateComponentsFormatter()
                f.maximumUnitCount = 1
                f.allowedUnits = [.day, .hour, .minute]
                f.unitsStyle = .abbreviated
                idle.seizeOfferAgeText = f.string(from: Date().timeIntervalSince(issued)) ?? "?"
            }
            state = idle
        case .requested, .takingOver:
            state = Self.startingState(context: ExtensionDelegate.sharedIfAvailable()?.loopManager.activeContext,
                                       takingOver: snap.phase == .takingOver,
                                       startedAt: snap.startedAt,
                                       now: Date())
        case .handingBack:
            var s = GlanceUIState(); s.phase = .handingBack

            s.handbackStartedAt = snap.handbackStartedAt

            s.loopStatusText = NSLocalizedString("ending…", comment: "Glance status during hand-back")

            s.phoneUnreachable = !snap.phoneReachable
            s.idleNote = snap.phoneReachable
                ? NSLocalizedString("Waiting for iPhone — pod still on watch. Bolus unavailable until it connects.", comment: "Glance note while a hand-back waits for the phone")
                : NSLocalizedString("Can't reach iPhone — pod still on watch. Move it closer or check its Bluetooth.", comment: "Glance note while a hand-back waits for an UNREACHABLE phone")
            state = s
        case .recoveredDrain:

            var restIdle = Self.idleState(context: ExtensionDelegate.sharedIfAvailable()?.loopManager.activeContext,
                                          note: snap.lastIdleNote
                                            ?? G7WatchDirectRead.needsCodeNote
                                            ?? NSLocalizedString("Records from the last session are waiting for your iPhone. You can still start.",
                                                                 comment: "Glance note while resting on a parked drain"))
            if let issued = snap.seizeOfferIssuedAt {
                let f = DateComponentsFormatter()
                f.maximumUnitCount = 1
                f.allowedUnits = [.day, .hour, .minute]
                f.unitsStyle = .abbreviated
                restIdle.seizeOfferAgeText = f.string(from: Date().timeIntervalSince(issued)) ?? "?"
            }
            state = restIdle
        case .revoked:
            var s = GlanceUIState(); s.phase = .draining
            s.handbackStartedAt = snap.handbackStartedAt

            s.loopStatusText = NSLocalizedString("returning records…", comment: "Glance status while draining records")
            state = s
        case .active:

            RuntimeStateLog.mark("glance.refresh.kickGlance")
            if kickMirror { session.stack.loopManager.refreshGlanceData() }
            guard let data = session.stack.loopManager.mirroredGlanceData else { return }
            RuntimeStateLog.mark("glance.refresh.activeStateBuild")
            var s = Self.activeState(data: data, cob: latestCOB, now: Date(),
                                     phoneGlucoseDate: ExtensionDelegate.sharedIfAvailable()?.loopManager.activeContext?.glucoseDate)
            if snap.handbackPending {
                s.handbackPending = true
                s.handbackStartedAt = snap.handbackStartedAt
                s.loopStatusText = NSLocalizedString("ending…", comment: "Glance status while a hand-back drains in the background")

                s.transientText = s.loopStatusText

                s.phoneUnreachable = !snap.phoneReachable
                if !snap.phoneReachable {
                    s.idleNote = NSLocalizedString("Can't reach iPhone — still looping. Move it closer or check its Bluetooth.", comment: "Glance note when an interim hand-back is blocked by an unreachable phone")
                }
            } else if let at = snap.handbackFailedAt, let text = snap.handbackFailureText,
                      Date().timeIntervalSince(at) < 20 {
                s.transientText = text
            } else if let at = snap.startNoteAt, let text = snap.startNoteText,
                      Date().timeIntervalSince(at) < 90 {
                s.transientText = text
            }
            s.reunionPrompt = snap.reunionPromptVisible

            if let startedAt = session.stack.loopManager.manualBolusStartedAt {
                let pending = session.stack.loopManager.manualBolusPendingUnits
                let amount = pending.map { Self.unitsFormatter.string(from: NSNumber(value: $0)) ?? String($0) }

                let elapsed = Date().timeIntervalSince(startedAt)
                s.transientText = elapsed < 0.4 ? nil
                    : elapsed < 20
                    ? (amount.map { String(format: NSLocalizedString("starting %@ U…", comment: "Glance status while a manual bolus is being sent to the pod (1: units)"), $0) }
                        ?? NSLocalizedString("starting bolus…", comment: "Glance status while a manual bolus is being sent, amount unknown"))

                    : (amount.map { String(format: NSLocalizedString("taking longer than usual — %@ U will deliver", comment: "Glance status when a manual bolus is slow to reach the pod (1: units)"), $0) }
                        ?? NSLocalizedString("taking longer than usual — the bolus will deliver", comment: "Glance status when a slow manual bolus has no known amount"))
            }

            if let delivery = session.stack.loopManager.manualBolusDelivery {
                s.bolusDelivery = delivery
                s.transientText = nil
            }
            RuntimeStateLog.mark("glance.refresh.statePublish")
            state = s
            RuntimeStateLog.mark("glance.refresh.logRender")
            logRender(iob: data.iob, cob: latestCOB, glucoseDate: data.glucoseDate, now: Date())
            RuntimeStateLog.mark("glance.refresh.carbFetchDispatch")
            session.stack.loopManager.glanceCarbsOnBoard { [weak self] cob in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let changed = cob != self.latestCOB
                    self.latestCOB = cob
                    self.latestCOBAt = Date()

                    if changed { self.refresh(kickMirror: false) }
                }
            }
        }
    }

    private func logRender(iob: Double?, cob: Double?, glucoseDate: Date?, now: Date) {
        let key = String(format: "%@|%@", iob.map { String(format: "%.2f", $0) } ?? "nil",
                                          cob.map { String(format: "%.1f", $0) } ?? "nil")
        if key == lastRenderLogKey, let last = lastRenderLogAt, now.timeIntervalSince(last) < 60 { return }
        lastRenderLogKey = key
        lastRenderLogAt = now
        let bgAge = glucoseDate.map { Int(now.timeIntervalSince($0)) }
        let cobAge = latestCOBAt.map { Int(now.timeIntervalSince($0)) }
        SportLog.event("glance", String(format: "RENDER iob=%@ cob=%@ · bgAge=%@ cobCacheAge=%@",
                                        iob.map { String(format: "%.2f", $0) } ?? "nil",
                                        cob.map { String(format: "%.1f", $0) } ?? "nil",
                                        bgAge.map { "\($0)s" } ?? "nil",
                                        cobAge.map { "\($0)s" } ?? "never"))
    }

    static func idleState(context: WatchContext?, note: String? = nil) -> GlanceUIState {
        var s = GlanceUIState()
        s.phase = .idle
        s.viaPhone = true
        s.bgColor = .dim
        if let quantity = context?.glucose {
            s.bgText = String(format: "%.0f", quantity.doubleValue(for: .milligramsPerDeciliter))
            s.trendSymbol = context?.glucoseTrend?.symbol
        }
        s.loopStatusText = NSLocalizedString("phone loop active", comment: "Glance status when the phone runs the loop")
        s.idleNote = note
        return s
    }

    static func startingState(context: WatchContext?, takingOver: Bool, startedAt: Date?, now: Date) -> GlanceUIState {
        var s = GlanceUIState()
        s.phase = .starting
        s.viaPhone = true
        s.bgColor = .dim
        if let quantity = context?.glucose {
            s.bgText = String(format: "%.0f", quantity.doubleValue(for: .milligramsPerDeciliter))
            s.trendSymbol = context?.glucoseTrend?.symbol
        }
        s.loopStatusText = NSLocalizedString("starting…", comment: "Glance status while starting Sport Mode")
        s.startingStageText = takingOver
            ? NSLocalizedString("taking over pod…", comment: "Glance stage: pod takeover in progress")
            : NSLocalizedString("reaching iPhone…", comment: "Glance stage: waiting for the loan grant")

        s.startedAt = takingOver ? startedAt : nil
        s.g7EtaText = g7EtaText(lastReading: context?.glucoseDate, now: now, firstConnect: true)
        return s
    }

    static func g7EtaText(lastReading: Date?, now: Date, firstConnect: Bool = false) -> String? {
        let cadence: TimeInterval = 5 * 60
        guard let last = lastReading, last <= now else {
            return NSLocalizedString("G7 typically within 10 min", comment: "Glance G7 prediction without a prior reading")
        }
        let untilNext = cadence - now.timeIntervalSince(last).truncatingRemainder(dividingBy: cadence)
        if firstConnect {
            return nil
        }
        let seconds = Int(untilNext.rounded())
        guard seconds > 10 else {
            return NSLocalizedString("G7 due about now", comment: "Glance G7 prediction when the next reading is imminent")
        }
        return String(format: NSLocalizedString("G7 in ~%d:%02d", comment: "Glance countdown to the next expected G7 reading (min, sec)"),
                      seconds / 60, seconds % 60)
    }

    static func activeState(data: WatchLoopManager.GlanceData, cob: Double?, now: Date, phoneGlucoseDate: Date? = nil) -> GlanceUIState {
        var s = GlanceUIState()
        s.overrideLabel = data.overrideLabel
        s.phase = .active

        if let iob = data.iob { s.iobText = String(format: "%.1f", iob) }
        if let cob = cob { s.cobText = String(format: "%.0f", cob) }
        if let rate = data.tempRate {
            s.tempText = String(format: "%+.2f", rate)
        }

        let within: (Date?) -> Bool = { $0.map { now.timeIntervalSince($0) < displayStaleAge } ?? false }
        if within(data.directG7At) {
            s.bgSource = .directG7
        } else if within(data.phoneRelayAt) {
            s.bgSource = .phoneRelay
        } else {
            s.bgSource = .none
        }

        let age = data.glucoseDate.map { now.timeIntervalSince($0) }
        let isStale = age.map { $0 > displayStaleAge } ?? true

        switch data.lastLoopCompleted.map({ LoopCompletionFreshness(age: now.timeIntervalSince($0)) }) {
        case .fresh?: s.loopFreshness = .fresh
        case .aging?: s.loopFreshness = .aging
        case .stale?: s.loopFreshness = .stale
        case nil:     s.loopFreshness = .unknown
        }
        if let quantity = data.glucose {
            let mgdl = quantity.doubleValue(for: .milligramsPerDeciliter)
            s.bgText = String(format: "%.0f", mgdl)
            if isStale {
                s.bgColor = .dim
            } else {
                s.trendSymbol = data.trend?.symbol
                let low = data.suspendThreshold?.doubleValue(for: .milligramsPerDeciliter) ?? 70
                s.bgColor = mgdl < low ? .low : (mgdl > 180 ? .high : .inRange)
            }
        }
        if isStale {
            if let age = age {
                s.staleAgeText = String(format: NSLocalizedString("%d min ago — no direct G7", comment: "Glance stale-glucose age line"), Int(age / 60))
            } else {
                s.staleAgeText = NSLocalizedString("no direct G7 reading yet", comment: "Glance line before the first direct reading")
            }

            let missedAWindow = (age ?? .infinity) > 8 * 60
            s.g7EtaText = g7EtaText(lastReading: data.glucoseDate ?? phoneGlucoseDate, now: now, firstConnect: missedAWindow)

            if let hint = G7WedgeHint.text(directAge: data.directG7At.map { now.timeIntervalSince($0) },
                                           relayAge: data.phoneRelayAt.map { now.timeIntervalSince($0) }) {
                s.g7EtaText = hint
            }
        } else if let eventual = data.eventual {
            s.eventualText = String(format: "%.0f", eventual.doubleValue(for: .milligramsPerDeciliter))
        }

        if !isStale, let age = age {
            switch s.bgSource {
            case .directG7:
                s.g7EtaText = String(format: NSLocalizedString("G7 direct · %dm", comment: "Glance provenance line for a fresh direct reading (1: minutes ago)"), Int(age / 60))
            case .phoneRelay:
                s.g7EtaText = String(format: NSLocalizedString("via iPhone · %dm", comment: "Glance provenance line when the phone is relaying in a direct-G7 gap (1: minutes ago)"), Int(age / 60))
            case .none:
                break
            }
        }

        s.loopClosed = data.closedLoopEnabled
        if data.closedLoopEnabled, !isStale, let completed = data.lastLoopCompleted {
            s.predictionStale = LoopCompletionFreshness(age: now.timeIntervalSince(completed)) == .stale
        }
        return s
    }
}
