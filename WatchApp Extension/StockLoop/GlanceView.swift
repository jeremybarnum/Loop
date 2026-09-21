//
//  GlanceView.swift
//  WatchApp
//
//  The Sport Mode glance — the wrist's landing surface during a loan.
//
//  Ported from the WatchKit build unchanged in substance: the view was always SwiftUI, hosted
//  by a WKHostingController that owned the page's lifecycle. next-dev's watch app is a SwiftUI
//  TabView, so the shell is gone and the view is a page like any other. What the shell used to
//  do — start the 2-second refresh only while the page is on screen, and repaint on a session
//  poke — is expressed here as .onAppear/.onDisappear and a notification observer, which is the
//  same behaviour stated in the idiom the rest of this app now uses.
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

struct GlanceView: View {
    @ObservedObject var model: GlanceViewModel
    @State private var confirmingClose = false
    @State private var closeProgress: Double = 0

    static let watchAppBundle: Bundle = {
        var url = Bundle.main.bundleURL
        while url.pathExtension != "app" && url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return Bundle(url: url) ?? .main
    }()

    var body: some View {
        VStack(spacing: 0) {
            statusLine
            Spacer(minLength: 0)
            centerBlock
            Spacer(minLength: 0)
            bottomBlock
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)

        .onAppear { model.startRefreshing() }
        .onDisappear { model.stopRefreshing() }

        .onReceive(NotificationCenter.default.publisher(for: .podLoanPhaseDidChange)
            .receive(on: DispatchQueue.main)) { _ in
            model.refreshNow()
        }

        .onReceive(NotificationCenter.default.publisher(for: .manualBolusStateDidChange)
            .receive(on: DispatchQueue.main)) { _ in
            model.refreshNow()
        }
    }

    private var statusLine: some View {
        HStack {
            Button(action: onLoopTap) { loopIndicator }
                .buttonStyle(.plain)
                .disabled(model.state.phase != .active)
            Spacer(minLength: 2)

            if let label = model.state.overrideLabel {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.glanceInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                Spacer(minLength: 2)
            }
            statusRight
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .sheet(isPresented: $confirmingClose) {
            LoopCloseCrownConfirmation(progress: $closeProgress) {
                model.setLoopClosed(true)
                confirmingClose = false
            }
            .onDisappear { closeProgress = 0 }
        }
    }

    @ViewBuilder
    private var statusRight: some View {
        if model.state.phase == .active {
            if model.state.handbackPending {
                Button { model.cancelHandback() } label: {
                    Text(NSLocalizedString("Cancel", comment: "Glance top-right: abort a pending hand-back"))
                        .modifier(GlanceActionChip(tint: .glanceWarn))
                }
                .buttonStyle(.plain)
            } else {
                Button { model.endSportMode() } label: {
                    Text(NSLocalizedString("End", comment: "Glance top-right: end Sport Mode / hand the pod back"))
                        .modifier(GlanceActionChip(tint: .glanceInk))
                }
                .buttonStyle(.plain)
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var loopIndicator: some View {
        if model.state.phase == .active {
            Image(loopAssetName, bundle: Self.watchAppBundle)
                .renderingMode(.template)
                .resizable()
                .frame(width: 26, height: 26)
                .foregroundColor(ringColor)
        } else if model.state.phase != .idle {
            Text(model.state.loopStatusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.glanceDim)
        }
    }

    private var ringColor: Color {
        switch model.state.loopFreshness {
        case .fresh:   return Color(red: 10/255, green: 180/255, blue: 67/255)
        case .aging:   return Color(red: 233/255, green: 194/255, blue: 68/255)
        case .stale:   return Color(red: 255/255, green: 69/255, blue: 58/255)
        case .unknown: return .glanceDim
        }
    }

    private var loopAssetName: String {
        let freshness: String
        switch model.state.loopFreshness {
        case .fresh:   freshness = "fresh"
        case .aging:   freshness = "aging"
        case .stale:   freshness = "stale"
        case .unknown: freshness = "unknown"
        }
        return "loop_\(freshness)_\(model.state.loopClosed ? "closed" : "open")"
    }

    private func onLoopTap() {
        WKInterfaceDevice.current().play(.click)
        if model.state.loopClosed {
            model.setLoopClosed(false)
        } else {
            confirmingClose = true
        }
    }

    @ViewBuilder
    private var centerBlock: some View {
        switch model.state.phase {
        case .idle:
            if model.hasControllerState { idleCenter }
            else if model.isResuming {
                Text(NSLocalizedString("Resuming session…", comment: "Glance: a saved Sport Mode session is being rebuilt after a relaunch"))
                    .font(.footnote).foregroundColor(.secondary)
            } else { Color.clear.frame(height: 1) }
        case .starting: startingCenter
        default:        standardCenter
        }
    }

    private var idleCenter: some View {
        VStack(spacing: 12) {
            if model.state.bgText != "—" {
                HStack(spacing: 5) {
                    Text("iPhone").font(.system(size: 11, weight: .medium)).foregroundColor(.glanceDim)
                    Text(model.state.bgText).font(.system(size: 22, weight: .semibold)).foregroundColor(.glanceDim)
                    if let arrow = model.state.trendSymbol {
                        Text(arrow).font(.system(size: 16)).foregroundColor(.glanceDim)
                    }
                }
            }
            if let age = model.state.seizeOfferAgeText {
                VStack(spacing: 6) {
                    Text("iPhone didn't answer")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.glanceInk)
                    Text("Start without it?\nLast synced \(age) ago — settings and history from then.")
                        .font(.system(size: 12))
                        .foregroundColor(.glanceDim)
                        .multilineTextAlignment(.center)
                    Button { model.confirmSeize() } label: {
                        Text("Start Anyway")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.glanceAccent)
                    Button { model.dismissSeize() } label: {
                        Text("Cancel").font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.glanceDim)
                }
            } else {
            Button { model.startSportMode() } label: {
                Text("Start Sport Mode")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.glanceAccent)
            }
            if let note = model.state.idleNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundColor(.glanceWarn)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
    }

    private var startingCenter: some View {
        VStack(spacing: 10) {
            if model.state.bgText != "—" {
                HStack(spacing: 5) {
                    Text("iPhone").font(.system(size: 11, weight: .medium)).foregroundColor(.glanceDim)
                    Text(model.state.bgText).font(.system(size: 22, weight: .semibold)).foregroundColor(.glanceDim)
                    if let arrow = model.state.trendSymbol {
                        Text(arrow).font(.system(size: 16)).foregroundColor(.glanceDim)
                    }
                }
            }
            startingBlock
        }
        .padding(.horizontal, 10)
    }

    private var standardCenter: some View {
        VStack(spacing: 1) {
            HStack(alignment: .top, spacing: 3) {
                Text(model.state.bgText)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(bgColor)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let arrow = model.state.trendSymbol {
                    Text(arrow)
                        .font(.system(size: 24))
                        .foregroundColor(bgColor)
                        .padding(.top, 8)
                }
            }
            if let stale = model.state.staleAgeText {
                Text(stale).font(.system(size: 12)).foregroundColor(.glanceWarn)
            } else if let eventual = model.state.eventualText {
                (Text("eventually ").foregroundColor(.glanceDim)
                 + Text(eventual).bold().foregroundColor(model.state.predictionStale ? .glanceDim : .primary))
                    .font(.system(size: 13))
            } else if model.state.viaPhone, model.state.phase == .idle || model.state.phase == .starting {
                Text("via iPhone").font(.system(size: 12)).foregroundColor(.glanceDim)
            }

            if let delivery = model.state.bolusDelivery {
                bolusDeliveryBlock(delivery)
            } else if let transient = model.state.transientText {
                Text(transient)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.glanceWarn)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            } else if model.state.phase == .active, let eta = model.state.g7EtaText {
                Text(eta).font(.system(size: 11))
                    .foregroundColor(model.state.bgSource == .phoneRelay ? .glanceWarn : .glanceDim)
            }
        }
    }

    @ViewBuilder
    private func bolusDeliveryBlock(_ delivery: (units: Double, startedAt: Date, endsAt: Date)) -> some View {
        TimelineView(.periodic(from: delivery.startedAt, by: 2)) { timeline in
            let duration = delivery.endsAt.timeIntervalSince(delivery.startedAt)
            let elapsed = timeline.date.timeIntervalSince(delivery.startedAt)
            let fraction = duration > 0 ? min(max(elapsed / duration, 0), 1) : 1

            if timeline.date < delivery.endsAt {
            let delivered = (fraction * delivery.units / 0.05).rounded(.down) * 0.05
            VStack(spacing: 3) {
                Text(String(format: NSLocalizedString("bolusing %1$@ of %2$@ U", comment: "Glance status while a manual bolus is being delivered (1: units delivered so far, 2: total units)"),
                            GlanceViewModel.unitsFormatter.string(from: NSNumber(value: delivered)) ?? String(delivered),
                            GlanceViewModel.unitsFormatter.string(from: NSNumber(value: delivery.units)) ?? String(delivery.units)))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.glanceAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.glanceDim.opacity(0.25))
                        Capsule().fill(Color.glanceAccent)
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 3)
                .frame(maxWidth: 120)
            }
            }
        }
    }

    @ViewBuilder
    private var bottomBlock: some View {
        switch model.state.phase {
        case .active:
            VStack(spacing: 4) {
                HStack {
                    railCell(model.state.iobText, "IOB U")
                    railCell(model.state.cobText, "COB G")
                    railCell(model.state.tempText, "TEMP U/H")
                }

                if model.state.handbackPending {
                    if model.state.phoneUnreachable, let note = model.state.idleNote {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundColor(.glanceWarn)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(NSLocalizedString("Records syncing to iPhone…", comment: "Glance note while a hand-back drains"))
                            .font(.system(size: 10))
                            .foregroundColor(.glanceDim)
                            .multilineTextAlignment(.center)
                    }
                }

                if model.state.reunionPrompt {
                    VStack(spacing: 3) {
                        Text(NSLocalizedString("iPhone is back — hand the pod back?", comment: "Glance prompt when the phone returns during a seized loan"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.glanceInk)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Button {
                                ExtensionDelegate.sharedIfAvailable()?.stockLoopSession?.loanController.confirmReunionHandback()
                            } label: {
                                Text(NSLocalizedString("Hand Back", comment: "Glance reunion prompt: end the seized loan"))
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.glanceAccent)
                            Button {
                                ExtensionDelegate.sharedIfAvailable()?.stockLoopSession?.loanController.dismissReunionPrompt()
                            } label: {
                                Text(NSLocalizedString("Keep", comment: "Glance reunion prompt: continue the seized loan"))
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(.bottom, 2)
        case .idle, .starting:

            EmptyView()
        case .handingBack, .draining:
            VStack(spacing: 4) {
                ProgressView()
                if let note = model.state.idleNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(.glanceWarn)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private static let podTakeoverExpected: TimeInterval = 17

    private static let podTakeoverOverrun: TimeInterval = 22

    private var startingBlock: some View {
        VStack(spacing: 4) {
            if let began = model.state.startedAt {
                TimelineView(.animation(minimumInterval: 0.1)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(began)
                    let progress = min(max(elapsed, 0) / Self.podTakeoverExpected, 0.95)
                    VStack(spacing: 4) {
                        Text(model.state.startingStageText ?? NSLocalizedString("starting…", comment: "Glance stage fallback while starting"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.glanceInk)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.glanceDim.opacity(0.25))
                                Capsule().fill(Color.glanceAccent)
                                    .frame(width: max(6, geo.size.width * progress))
                            }
                        }
                        .frame(height: 6)
                        if elapsed > Self.podTakeoverOverrun {
                            Text(NSLocalizedString("taking longer than usual…", comment: "Glance note when the pod takeover overruns the expected ~10s"))
                                .font(.system(size: 11))
                                .foregroundColor(.glanceWarn)
                        }
                    }
                }
            } else {
                Text(model.state.startingStageText ?? NSLocalizedString("starting…", comment: "Glance stage fallback while starting"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.glanceInk)
                ProgressView()
            }
            if let eta = model.state.g7EtaText {
                Text(eta).font(.system(size: 11)).foregroundColor(.glanceDim)
            }
        }
    }

    private func railCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 23, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundColor(.glanceInk)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .kerning(0.8)
                .foregroundColor(.glanceDim)
        }
        .frame(maxWidth: .infinity)
    }

    private var bgColor: Color {
        switch model.state.bgColor {
        case .inRange: return .glanceInk
        case .high: return .glanceWarn
        case .low: return .glanceCrit
        case .dim: return .glanceDim
        }
    }
}

extension Color {
    static let glanceInk = Color(white: 0.95)
    static let glanceDim = Color(white: 0.55)
    static let glanceAccent = Color(red: 0.36, green: 0.56, blue: 0.82)
    static let glanceGood = Color(red: 0.31, green: 0.82, blue: 0.48)
    static let glanceWarn = Color(red: 0.91, green: 0.70, blue: 0.25)
    static let glanceCrit = Color(red: 0.88, green: 0.36, blue: 0.31)
}

private struct GlanceActionChip: ViewModifier {
    let tint: Color
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 17)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct LoopCloseCrownConfirmation: View {
    @Binding private var progressStorage: Double
    private let completion: () -> Void
    private let resetProgress = PeriodicPublisher(interval: 0.25)

    private var progress: Binding<Double> {
        Binding(
            get: { self.progressStorage.clamped(to: -1...1) },
            set: { newValue in
                guard abs(self.progressStorage) < 1.0 else { return }
                withAnimation { self.progressStorage = newValue }
                self.resetProgress.acknowledge()
                if abs(newValue) >= 1.0 {
                    WKInterfaceDevice.current().play(.success)
                    self.completion()
                }
            }
        )
    }

    init(progress: Binding<Double>, onConfirmation completion: @escaping () -> Void) {
        self._progressStorage = progress
        self.completion = completion
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.glanceDim.opacity(0.25), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(abs(progress.wrappedValue)))
                    .stroke(Color.glanceGood, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.glanceGood)
            }
            .frame(width: 96, height: 96)
            Text("Turn Digital Crown\nto close the loop", comment: "Loop-close crown-confirmation help text")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(Color(.lightGray))
                .opacity(abs(progress.wrappedValue) >= 1.0 ? 0 : 1)
        }
        .focusable()
        .digitalCrownRotation(progress, over: -1...1, sensitivity: .low, scalingRotationBy: 4)
        .onReceive(resetProgress) { self.progress.wrappedValue = 0 }
    }
}

#if DEBUG
private func previewState(_ build: (inout GlanceUIState) -> Void) -> GlanceUIState {
    var s = GlanceUIState(); build(&s); return s
}

#if GLANCE_DEMO

struct GlanceDemoView: View {
    @StateObject private var model = GlanceViewModel(preview: GlanceDemoView.states[0].state)

    static let states: [(name: String, state: GlanceUIState)] = [
        ("Active · in range · CLOSED", previewState { s in
            s.phase = .active; s.bgText = "142"; s.trendSymbol = "↗"; s.bgColor = .inRange
            s.eventualText = "128"; s.iobText = "1.8"; s.cobText = "24"; s.tempText = "+0.75"
            s.loopFreshness = .fresh; s.loopClosed = true }),
        ("Active · OPEN (advisory)", previewState { s in
            s.phase = .active; s.bgText = "142"; s.trendSymbol = "↗"; s.bgColor = .inRange
            s.eventualText = "128"; s.iobText = "1.8"; s.cobText = "24"; s.tempText = "—"
            s.loopFreshness = .fresh; s.loopClosed = false }),
        ("Active · high", previewState { s in
            s.phase = .active; s.bgText = "214"; s.trendSymbol = "→"; s.bgColor = .high
            s.eventualText = "176"; s.iobText = "2.6"; s.cobText = "31"; s.tempText = "+1.20"
            s.loopFreshness = .fresh; s.loopClosed = true }),
        ("Active · low", previewState { s in
            s.phase = .active; s.bgText = "64"; s.trendSymbol = "↘"; s.bgColor = .low
            s.eventualText = "58"; s.iobText = "0.4"; s.cobText = "0"; s.tempText = "0.00"
            s.loopFreshness = .fresh; s.loopClosed = true }),

        ("Active · aging BG · CLOSED", previewState { s in
            s.phase = .active; s.bgText = "142"; s.trendSymbol = "→"; s.bgColor = .inRange
            s.eventualText = "158"; s.iobText = "1.6"; s.cobText = "18"; s.tempText = "+0.90"
            s.loopFreshness = .aging; s.loopClosed = true }),
        ("Active · aging BG · OPEN", previewState { s in
            s.phase = .active; s.bgText = "142"; s.trendSymbol = "→"; s.bgColor = .inRange
            s.eventualText = "158"; s.iobText = "1.6"; s.cobText = "18"; s.tempText = "—"
            s.loopFreshness = .aging; s.loopClosed = false }),
        ("Stale glucose · CLOSED", previewState { s in
            s.phase = .active; s.bgText = "148"; s.bgColor = .dim
            s.staleAgeText = "16 min ago — no direct G7"; s.iobText = "1.8"; s.cobText = "24"
            s.loopFreshness = .stale; s.loopClosed = true }),
        ("Idle · activation", previewState { s in
            s.phase = .idle; s.bgText = "138"; s.trendSymbol = "→"; s.bgColor = .dim
            s.viaPhone = true; s.loopStatusText = "phone loop active" }),
        ("Starting · reaching iPhone", previewState { s in
            s.phase = .starting; s.bgText = "138"; s.trendSymbol = "→"; s.bgColor = .dim
            s.viaPhone = true; s.loopStatusText = "starting…"
            s.startingStageText = "reaching iPhone…"
            s.g7EtaText = "G7 in ~3:10" }),
        ("Starting · pod takeover (R24)", previewState { s in
            s.phase = .starting; s.bgText = "138"; s.trendSymbol = "→"; s.bgColor = .dim
            s.viaPhone = true; s.loopStatusText = "starting…"
            s.startingStageText = "taking over pod…"
            s.startedAt = Date().addingTimeInterval(-3)
            s.g7EtaText = "G7 in ~2:40" }),
        ("Starting · overrun", previewState { s in
            s.phase = .starting; s.bgText = "138"; s.bgColor = .dim
            s.viaPhone = true; s.loopStatusText = "starting…"
            s.startingStageText = "taking over pod…"
            s.startedAt = Date().addingTimeInterval(-20)
            s.g7EtaText = "G7 in ~1:10" }),
        ("Active · awaiting first G7", previewState { s in
            s.phase = .active; s.bgText = "148"; s.bgColor = .dim
            s.staleAgeText = "no direct G7 reading yet"; s.g7EtaText = "G7 in ~1:20"
            s.iobText = "1.8"; s.cobText = "24"
            s.loopStatusText = "PAUSED" }),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                GlanceView(model: model)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.gray.opacity(0.3)))
                ForEach(Self.states.indices, id: \.self) { i in
                    Button(Self.states[i].name) { model.state = Self.states[i].state }
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("Glance demo")
    }
}
#endif

#Preview("Active · in range") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "142"; s.trendSymbol = "↗"; s.bgColor = .inRange
        s.eventualText = "128"; s.iobText = "1.8"; s.cobText = "24"; s.tempText = "+0.75"
        s.loopStatusText = "CLOSED · 2m"
    }))
}

#Preview("Bolus · starting (not yet accepted)") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "111"; s.trendSymbol = "→"; s.bgColor = .inRange
        s.eventualText = "88"; s.iobText = "1.2"; s.cobText = "8"; s.tempText = "0.00"
        s.loopStatusText = "CLOSED · 1m"

        s.transientText = "starting 0.90 U…"
    }))
}

#Preview("Bolus · delivering") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "111"; s.trendSymbol = "→"; s.bgColor = .inRange
        s.eventualText = "88"; s.iobText = "1.7"; s.cobText = "8"; s.tempText = "0.00"
        s.loopStatusText = "CLOSED · 1m"

        let started = Date().addingTimeInterval(-22)
        s.bolusDelivery = (units: 0.90, startedAt: started, endsAt: started.addingTimeInterval(0.90 / 1.5 * 60))
    }))
}

#Preview("Bolus · slow to reach the pod") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "111"; s.trendSymbol = "→"; s.bgColor = .inRange
        s.eventualText = "88"; s.iobText = "1.2"; s.cobText = "8"; s.tempText = "0.00"
        s.loopStatusText = "CLOSED · 1m"
        s.transientText = "taking longer than usual — 0.90 U will deliver"
    }))
}

#Preview("Active · high") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "214"; s.trendSymbol = "→"; s.bgColor = .high
        s.eventualText = "176"; s.iobText = "2.6"; s.cobText = "31"; s.tempText = "+1.20"
        s.loopStatusText = "CLOSED · 1m"
    }))
}

#Preview("Active · low") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "64"; s.trendSymbol = "↘"; s.bgColor = .low
        s.eventualText = "58"; s.iobText = "0.4"; s.cobText = "0"; s.tempText = "0.00"
        s.loopStatusText = "CLOSED · 3m"
    }))
}

#Preview("Stale") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "148"; s.bgColor = .dim
        s.staleAgeText = "9 min ago — no direct G7"
        s.iobText = "1.8"; s.cobText = "24"
        s.loopStatusText = "PAUSED"
    }))
}

#Preview("Active · OPEN (advisory)") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "142"; s.trendSymbol = "↗"; s.bgColor = .inRange
        s.eventualText = "128"; s.iobText = "1.8"; s.cobText = "24"; s.tempText = "—"
        s.loopStatusText = "OPEN"; s.loopClosed = false
    }))
}

#Preview("Idle · activation") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .idle; s.bgText = "138"; s.trendSymbol = "→"; s.bgColor = .dim
        s.viaPhone = true; s.loopStatusText = "phone loop active"
    }))
}

#Preview("Starting · pod takeover") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .starting; s.bgText = "138"; s.trendSymbol = "→"; s.bgColor = .dim
        s.viaPhone = true; s.loopStatusText = "starting…"
        s.startingStageText = "taking over pod…"
        s.startedAt = Date().addingTimeInterval(-3)
        s.g7EtaText = "G7 in ~2:40"
    }))
}

#Preview("Active · awaiting first G7") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "148"; s.bgColor = .dim
        s.staleAgeText = "no direct G7 reading yet"; s.g7EtaText = "G7 in ~1:20"
        s.iobText = "1.8"; s.cobText = "24"
        s.loopStatusText = "PAUSED"
    }))
}
#endif
