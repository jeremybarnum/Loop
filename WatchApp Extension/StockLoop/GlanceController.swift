//
//  GlanceController.swift
//  WatchApp Extension
//
//  The Sport Mode glance screen (RULINGS.md R23, docs/DESIGN_SPORT_UI.md): layout A
//  "number-first". Display + activation only — every dosing path remains the ruled,
//  tested code; this file reads snapshots and calls the loan controller's existing
//  entry points. True-black background (OLED), centered number, three-cell rail.
//
//  Honest-state rules rendered here:
//  - Stale glucose NEVER looks fresh: number dims, arrow drops, explicit age (R9/§6a).
//  - Color only OUT of range: white in range, amber high, red low (R23 decision 7).
//    Display bounds: low = therapy suspendThreshold (fallback 70), high = 180 — the
//    TIR display convention. Display semantics only, never dosing limits.
//  - Suspended shows the R4 auto-resume countdown as primary state, not an alarm.
//  - Idle state shows PHONE-fed data dimmed and labeled (provenance always visible,
//    §6a) and hosts activation. Confirmation is a two-step alert for now; the crown
//    ceremony polish replaces it in the UI pass (the per-session opt-in semantics
//    are preserved either way).
//
//  Xcode canvas previews at the bottom render every state without runtime demo
//  branches (the design doc bans those in dosing paths).
//

import Foundation
import SwiftUI
import Combine
import WatchKit
import HealthKit
import LoopKit

final class GlanceController: WKHostingController<GlanceView> {

    /// The live instance, so the session owner can land here when a loan activates.
    private(set) static weak var current: GlanceController?

    private let model = GlanceViewModel()

    override func awake(withContext context: Any?) {
        super.awake(withContext: context)
        Self.current = self
    }

    override var body: GlanceView {
        GlanceView(model: model)
    }

    /// The 2s refresh runs ONLY while this page is actually on screen.
    ///
    /// It used to run for the controller's whole lifetime, so it kept firing while the stock
    /// carb/bolus flow was presented modally OVER the glance — invisible, but still taking the
    /// loan controller's queue every 2s. That queue doubles as the pump's delegateQueue, so
    /// during a bolus the tick queued behind pod BLE work and stalled the main thread: the
    /// frozen carb screen Jeremy hit on build 223. The mirror (ba92c3cb) stops it blocking;
    /// this stops it running at all when nothing is looking at it.
    override func didAppear() {
        super.didAppear()
        model.startRefreshing()
    }

    override func didDeactivate() {
        super.didDeactivate()
        model.stopRefreshing()
    }
}

// MARK: - UI state (a pure value the view renders; previews hand-build these)

struct GlanceUIState {
    enum Phase { case idle, starting, active, handingBack, draining }
    enum BGColor { case inRange, high, low, dim }
    /// Loop-ring freshness = BG recency (Jeremy 2026-07-24): meaningful OPEN or CLOSED,
    /// and stale G7 is the likely failure. Drives the stock ring color; open is NOT gray.
    enum LoopFreshness { case fresh, aging, stale, unknown }

    var phase: Phase = .idle
    var bgText: String = "—"
    var trendSymbol: String? = nil
    var bgColor: BGColor = .dim
    /// non-nil = stale: shown INSTEAD of the eventual line, number dims (R9/§6a).
    var staleAgeText: String? = nil
    var eventualText: String? = nil
    var iobText: String = "—"
    var cobText: String = "—"
    var tempText: String = "—"
    var loopStatusText: String = ""
    var loopDotColor: Color = .clear
    var loopFreshness: LoopFreshness = .unknown
    var viaPhone: Bool = false
    /// G7 pairing code likely wrong (aesVerifyFailed ×2) — glance shows a re-enter banner.
    var needsSensorCode: Bool = false

    /// *** DIABETIFY *** ringfence badge (bench, 2026-07-29): true while the g7.diabetify
    /// transform is remapping real G7 readings — the glance must never look normal then.
    var diabetifyActive: Bool = false

    /// Loop open/close control (active only). `canToggleLoop` is false when the phone
    /// disallows dosing (the watch can't close what the phone opened) or when suspended.
    var loopClosed: Bool = false
    var canToggleLoop: Bool = false

    /// Idle-only: why the last Start attempt returned to idle (timeout / refusal).
    var idleNote: String? = nil
    /// #67 follow-up (2026-08-03): the iPhone can't be reached while a hand-back is trying.
    /// Explicit rather than inferred from idleNote being non-nil — idleNote is set on other
    /// paths too, and "is the phone reachable" must not depend on which of them ran last.
    var phoneUnreachable: Bool = false

    /// Starting-only (R24): when the Start attempt began — the view animates the
    /// ~10s determinate pod bar from this anchor. nil = indeterminate fallback.
    var startedAt: Date? = nil
    /// Starting-only: which stage the bar is in ("reaching iPhone…" / "taking over pod…").
    var startingStageText: String? = nil
    /// R24 G7 prediction: countdown to the next expected G7 transmit ("G7 in ~2:40").
    /// Shown under the bar while starting, and under the stale line while active
    /// without a direct reading. Pod and G7 are deliberately decoupled — the pod bar
    /// completes without waiting for this.
    var g7EtaText: String? = nil

    /// WS1: hand-back requested but still draining — watch remains in control;
    /// the glance shows "ending…" plus a Cancel affordance.
    var handbackPending: Bool = false
    /// When the current reclaim began — anchors the determinate reclaim bar (2026-08-04).
    var handbackStartedAt: Date? = nil
}

// MARK: - View model

final class GlanceViewModel: ObservableObject {
    @Published var state = GlanceUIState()

    private var timer: Timer?
    private var latestCOB: Double?
    private let isPreview: Bool

    /// Display staleness: one 5-min G7 grid + grace. Display only — the dosing
    /// recency gates remain the stock 15-min constants in WatchLoopManager.
    private static let displayStaleAge: TimeInterval = 7 * 60

    init() {
        isPreview = false
        // One refresh so the first render has data; the repeating tick is owned by the
        // controller's visibility (startRefreshing / stopRefreshing).
        refresh()
    }

    /// Begin the on-screen refresh tick. Idempotent.
    func startRefreshing() {
        guard !isPreview, timer == nil else { return }
        refresh()   // don't show up to 2s of staleness on the way in
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Stop ticking while off screen — nothing is reading this, and each tick takes the loan
    /// controller's queue, which the pump also uses.
    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
    }

    /// Preview-only: fixed state, no timer, no store access.
    init(preview: GlanceUIState) {
        isPreview = true
        state = preview
    }

    deinit { timer?.invalidate() }

    func cancelHandback() {
        guard !isPreview else { return }
        ExtensionDelegate.shared().stockLoopSession.loanController.cancelHandback()
        // The cancel lands on the controller's queue — refresh after it drains so
        // the "ending…" UI doesn't linger a full timer tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    func startSportMode() {
        guard !isPreview else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let session = ExtensionDelegate.shared().stockLoopSession
        session.loanController.requestLoan(watchBuild: build)
        // Log pipeline v4: the Start tap itself ships a snapshot, and a +35s
        // follow-up captures the request's fate (grant/timeout) even when the
        // session then goes completely dry — no more invisible dead sessions.
        session.sendLogSnapshot("sport start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) {
            session.sendLogSnapshot("start +35s")
        }
        refresh()
    }

    /// End Sport Mode = R25 two-phase stay-active hand-back: request the return, keep
    /// dosing/bolus/G7 running while the journal drains, transfer ownership only when
    /// acked. Cancelable until finalize (the glance shows "ending… / Cancel Ending").
    func endSportMode() {
        guard !isPreview else { state.handbackPending = true; return }
        ExtensionDelegate.shared().stockLoopSession.loanController.beginHandback()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    /// Apply a 4-digit sensor code entered on the watch (wrong-code recovery). No sensorID →
    /// same sensor, corrected pin only; clears needsSensorCode (and its alert, via didSet).
    /// The next G7 attempt uses the new code.
    func submitSensorCode(_ code: String) {
        guard !isPreview else { state.needsSensorCode = false; return }
        ExtensionDelegate.shared().stockLoopSession.stack.client.applySensorCode(code)
        refresh()
    }

    /// Open (disable dosing) is fail-safe — no confirm. Close (enable dosing) is gated
    /// by the confirm alert in the view.
    func setLoopClosed(_ closed: Bool) {
        guard !isPreview else {
            // Demo/preview mode: mutate local state so the pill is interactive on the sim.
            state.loopClosed = closed
            state.loopStatusText = closed ? "CLOSED · 0m" : "OPEN"
            state.loopDotColor = closed ? .glanceGood : .clear
            return
        }
        ExtensionDelegate.shared().stockLoopSession.stack.loopManager.setClosedLoopEnabled(closed)
        refresh()
    }

    private func refresh() {
        guard !isPreview else { return }
        let session = ExtensionDelegate.shared().stockLoopSession
        // Main-safe read: the loan queue doubles as the pump's delegate queue, so a sync
        // here blocked the whole UI for the length of any bolus / takeover / reclaim.
        session.loanController.refreshDebugSnapshot()
        guard let snap = session.loanController.mirroredDebugSnapshot else { return }

        switch snap.phase {
        case .idle:
            state = Self.idleState(context: ExtensionDelegate.shared().loopManager.activeContext,
                                   note: snap.lastIdleNote)
        case .requested, .takingOver:
            state = Self.startingState(context: ExtensionDelegate.shared().loopManager.activeContext,
                                       takingOver: snap.phase == .takingOver,
                                       startedAt: snap.startedAt,
                                       now: Date())
        case .handingBack:
            var s = GlanceUIState(); s.phase = .handingBack
            // MISSED IN THE FIRST CUT (build 221 shipped without a bar on this screen —
            // Jeremy, on-wrist): this is the PRIMARY reclaim screen, and a fresh
            // GlanceUIState() leaves handbackStartedAt nil, so the view fell through to the
            // indeterminate spinner. The anchor was wired into .revoked/.recoveredDrain and
            // the active-screen interim drain but not here.
            s.handbackStartedAt = snap.handbackStartedAt
            // Honest limbo (party finding 2026-07-18: 97 min of ambiguity): while the
            // iPhone is unreachable this state can persist — say exactly what's true.
            s.loopStatusText = NSLocalizedString("ending…", comment: "Glance status during hand-back")
            // #67 follow-up (2026-08-03): distinguish "the phone is thinking about it" from
            // "I cannot reach the phone at all". The second has a remedy the user can act on
            // NOW; the old single message left them staring at "ending…" for the full 120 s
            // timeout with no idea which it was (field 2026-08-02 23:58, phone Bluetooth off).
            s.phoneUnreachable = !snap.phoneReachable
            s.idleNote = snap.phoneReachable
                ? NSLocalizedString("Ending Sport Mode — waiting for iPhone. The pod is still on your watch; bolus is unavailable until the iPhone connects.", comment: "Glance note while a hand-back waits for the phone")
                : NSLocalizedString("Can't reach iPhone. Move it closer, or check that its Bluetooth is on. Sport Mode will end by itself as soon as the phone connects — the pod is still on your watch.", comment: "Glance note while a hand-back waits for an UNREACHABLE phone")
            state = s
        case .revoked, .recoveredDrain:
            var s = GlanceUIState(); s.phase = .draining
            s.handbackStartedAt = snap.handbackStartedAt
            s.loopStatusText = NSLocalizedString("returning records…", comment: "Glance status while draining records")
            state = s
        case .active:
            let data = session.stack.loopManager.glanceData()
            var s = Self.activeState(data: data, cob: latestCOB, now: Date(),
                                     phoneGlucoseDate: ExtensionDelegate.shared().loopManager.activeContext?.glucoseDate)
            if snap.handbackPending {
                s.handbackPending = true
                s.handbackStartedAt = snap.handbackStartedAt
                s.loopStatusText = NSLocalizedString("ending…", comment: "Glance status while a hand-back drains in the background")
                // WS1 interim drain — the watch is STILL looping, so this path deliberately
                // carried no note. But an unreachable phone is exactly the case the user must
                // be told about (it is why "ending…" appears to hang), and it is the state
                // they actually hit: End tapped while the loop keeps running. Looping
                // continuing is the reassuring half of the message, so say both.
                s.phoneUnreachable = !snap.phoneReachable
                if !snap.phoneReachable {
                    s.idleNote = NSLocalizedString("Can't reach iPhone. Move it closer, or check that its Bluetooth is on. Sport Mode will end as soon as the phone connects; looping continues until then.", comment: "Glance note when an interim hand-back is blocked by an unreachable phone")
                }
            }
            state = s
            session.stack.loopManager.glanceCarbsOnBoard { [weak self] cob in
                DispatchQueue.main.async { self?.latestCOB = cob }
            }
        }
        // Cross-cutting (any phase): a likely-wrong G7 pairing code surfaces the re-enter banner.
        state.needsSensorCode = session.stack.client.needsSensorCode
        // Cross-cutting: the DIABETIFY bench transform shows its ringfence badge in every phase.
        state.diabetifyActive = DiabetifyTransform.isActive
    }

    // MARK: State builders (static + pure, so previews and tests can drive them)

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
        s.idleNote = note   // why the last start attempt returned to idle (nil = none)
        return s
    }

    /// R24 connect state: phone-fed BG stays visible (dimmed, provenance-labeled), the
    /// determinate ~10s pod bar runs below, and the G7 arrival prediction rides under
    /// it. Covers both request (grant round-trip, usually <1s) and takeover.
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
        // The determinate bar measures the TAKEOVER only (anchor reset at grant) —
        // the grant round-trip is WCSession-variable, so the request stage renders
        // the honest indeterminate spinner instead of a bar that would lie.
        s.startedAt = takingOver ? startedAt : nil
        s.g7EtaText = g7EtaText(lastReading: context?.glucoseDate, now: now, firstConnect: true)
        return s
    }

    /// R24 G7 prediction: the transmitter sends on a fixed 5-minute grid anchored to
    /// the sensor session, so the next transmit is predictable from ANY prior reading
    /// (phone-fed or direct — the cadence belongs to the sensor, not the receiver).
    static func g7EtaText(lastReading: Date?, now: Date, firstConnect: Bool = false) -> String? {
        let cadence: TimeInterval = 5 * 60
        guard let last = lastReading, last <= now else {
            // No prior reading = no grid anchor: expected wait is one full window on
            // AVERAGE, and field cold-catches routinely need two (Jeremy 2026-07-20:
            // "within 5 min" was too optimistic). Promise what we can keep.
            return NSLocalizedString("G7 typically within 10 min", comment: "Glance G7 prediction without a prior reading")
        }
        let untilNext = cadence - now.timeIntervalSince(last).truncatingRemainder(dividingBy: cadence)
        if firstConnect {
            // Used at session start and after a missed window — both cases where
            // the next catch isn't yet locked. The grid PHASE is predicted
            // accurately from the last reading (2026-07-21: predicted :37:35,
            // caught :37:39 — dead on), and E4 (build 140+) catches the FIRST
            // window ~94-100% of the time — so estimate the next slot itself,
            // softened to "likely" (users read it as an estimate, not a promise).
            // The old +1-cycle pad (calibrated 2026-07-18, pre-E4) was
            // systematically a full window pessimistic. The ladder ceiling
            // (untilNext + cadence) stays one line away for an explicit
            // "no later than …" if the estimate ever proves shakier than it looks.
            let by = now.addingTimeInterval(untilNext)
            let formatter = DateFormatter(); formatter.timeStyle = .short
            return String(format: NSLocalizedString("G7 likely by ~%@", comment: "Glance G7 first-catch estimate (1: clock time)"),
                          formatter.string(from: by))
        }
        let seconds = Int(untilNext.rounded())
        guard seconds > 10 else {
            // Imminent (or just past — BLE delivery adds seconds): no "~0:00" flicker.
            return NSLocalizedString("G7 due about now", comment: "Glance G7 prediction when the next reading is imminent")
        }
        return String(format: NSLocalizedString("G7 in ~%d:%02d", comment: "Glance countdown to the next expected G7 reading (min, sec)"),
                      seconds / 60, seconds % 60)
    }

    static func activeState(data: WatchLoopManager.GlanceData, cob: Double?, now: Date, phoneGlucoseDate: Date? = nil) -> GlanceUIState {
        var s = GlanceUIState()
        s.phase = .active

        // Rail.
        if let iob = data.iob { s.iobText = String(format: "%.1f", iob) }
        if let cob = cob { s.cobText = String(format: "%.0f", cob) }
        if let rate = data.tempRate {
            s.tempText = String(format: "%+.2f", rate)
        }

        // Number + honesty.
        let age = data.glucoseDate.map { now.timeIntervalSince($0) }
        let isStale = age.map { $0 > displayStaleAge } ?? true
        // Ring freshness = BG recency (Jeremy 2026-07-24). One G7 grid (~5m) + grace is
        // fresh, a missed window is aging, well past is stale; nil = no reading yet
        // (unknown/gray). Meaningful whether the loop is open or closed.
        if let age = age {
            s.loopFreshness = age < .minutes(7) ? .fresh : (age < .minutes(15) ? .aging : .stale)
        } else {
            s.loopFreshness = .unknown
        }
        if let quantity = data.glucose {
            let mgdl = quantity.doubleValue(for: .milligramsPerDeciliter)
            s.bgText = String(format: "%.0f", mgdl)
            if isStale {
                s.bgColor = .dim   // stale never looks fresh: dim + no arrow + age line
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
            // R24: the wait is predictable — show when the next reading should land.
            // The sport store only holds DIRECT readings, so on a first-ever session
            // it's empty; the phone-fed timestamp anchors the same sensor grid.
            // HONESTY (Jeremy 2026-07-18): a confident countdown ONLY while readings
            // are actually flowing; once we've missed a window (or never connected),
            // promise a clock time with slack instead — the ladder may need a cycle.
            let missedAWindow = (age ?? .infinity) > 8 * 60
            s.g7EtaText = g7EtaText(lastReading: data.glucoseDate ?? phoneGlucoseDate, now: now, firstConnect: missedAWindow)
        } else if let eventual = data.eventual {
            s.eventualText = String(format: "%.0f", eventual.doubleValue(for: .milligramsPerDeciliter))
        }
        // PROVENANCE (Jeremy 2026-07-20: "the UI doesn't make it clear if it's
        // dexcom direct or not"): the sport store is direct-only by construction,
        // so a fresh number here is ALWAYS the watch's own radio — say so.
        if !isStale, let age = age {
            s.g7EtaText = String(format: NSLocalizedString("G7 direct · %dm", comment: "Glance provenance line for a fresh direct reading (1: minutes ago)"), Int(age / 60))
        }

        // Status line + suspend + open/close.
        s.loopClosed = data.closedLoopEnabled
        if !data.closedLoopEnabled {
            // OPEN by choice — advisory. (R23 as amended 2026-07-18: the watch is
            // sovereign in a loan; the phone's own loop mode no longer gates this.)
            s.loopStatusText = NSLocalizedString("OPEN", comment: "Glance loop status: advisory / open loop")
            s.loopDotColor = .clear
            s.canToggleLoop = true
        } else if isStale {
            s.loopStatusText = NSLocalizedString("PAUSED", comment: "Glance loop status while glucose is stale")
            s.loopDotColor = .glanceWarn
            s.canToggleLoop = true
        } else if let completed = data.lastLoopCompleted {
            let interval = now.timeIntervalSince(completed)
            let minutes = max(0, Int(interval / 60))
            s.loopStatusText = String(format: NSLocalizedString("CLOSED · %dm", comment: "Glance loop status with age"), minutes)
            // #48: stock's fresh/aging/stale grading (HUDInterfaceController, 6/20 min),
            // replacing the old binary blank. The eventual stays visible; the dot conveys
            // how current the prediction is — green fresh · amber aging · red stale — so a
            // stale loop MARKS its last eventual rather than hiding it (which read as "none").
            let fresh: TimeInterval = .minutes(6)
            let aging: TimeInterval = .minutes(20)
            s.loopDotColor = interval < fresh ? .glanceGood : (interval < aging ? .glanceWarn : .glanceCrit)
            s.canToggleLoop = true
        } else {
            s.loopStatusText = NSLocalizedString("CLOSED · —", comment: "Glance loop status before the first loop")
            s.loopDotColor = .glanceWarn
            s.canToggleLoop = true
        }
        return s
    }
}

// MARK: - View (layout A, per the decided mocks: centered number, 23pt rail)

struct GlanceView: View {
    @ObservedObject var model: GlanceViewModel
    @State private var confirmingClose = false
    @State private var closeProgress: Double = 0   // #22: crown-to-fill loop-close ceremony
    @State private var enteringCode = false

    /// Always-visible build tag so a TestFlight install is unambiguous on-wrist
    /// (Jeremy 2026-07-20 — often installs mid-session and needs to know the build).
    static let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    /// The stock loop-ring assets (loop_<freshness>_<closed|open>) live in the WatchApp
    /// bundle's DefaultAssets catalog — the parent .app of this extension's .appex. Point
    /// SwiftUI at it explicitly; the extension's own Bundle.main can't see them.
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
            if model.state.needsSensorCode { sensorCodeBanner }
            Spacer(minLength: 0)
            centerBlock
            Spacer(minLength: 0)
            bottomBlock
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .sheet(isPresented: $enteringCode) {
            SensorCodeEntryView { code in
                model.submitSensorCode(code)
                enteringCode = false
            }
        }
    }

    /// Wrong-code banner (2026-07-24): shown in any phase when the G7 pairing code is likely
    /// wrong. Tap → on-wrist 4-digit entry. Watch-primary recovery for the phone-left-behind case.
    private var sensorCodeBanner: some View {
        Button { enteringCode = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                Text(NSLocalizedString("Check sensor code — tap to re-enter", comment: "Glance banner: G7 pairing code may be wrong"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.glanceCrit)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(Color.glanceCrit.opacity(0.15))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    private var statusLine: some View {
        HStack {
            // R21→ring (2026-07-24): the loop indicator IS the control now. Tap toggles —
            // open is immediate (fail-safe), close runs the crown ceremony (#22). Uses the
            // stock watch loop ring (solid=closed, gapped=open), pre-tinted by freshness.
            Button(action: onLoopTap) { loopIndicator }
                .buttonStyle(.plain)
                .disabled(model.state.phase != .active)
            // *** DIABETIFY *** ringfence badge: persistent while the bench transform is
            // remapping real G7 readings (3x amplification) — every phase, impossible to miss.
            if model.state.diabetifyActive {
                Text("Δ⚠︎ DIABETIFY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.glanceCrit)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer()
            statusRight
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .sheet(isPresented: $confirmingClose) {
            // #22: closing the loop = enabling autonomous dosing → a deliberate crown-to-fill
            // ceremony (same interaction as bolus delivery), replacing the tap-alert. Opening the
            // loop stays immediate (fail-safe). Not reachable if the loop is already closed.
            LoopCloseCrownConfirmation(progress: $closeProgress) {
                model.setLoopClosed(true)
                confirmingClose = false
            }
            .onDisappear { closeProgress = 0 }
        }
    }

    /// Top-right (option C, 2026-07-24): the SESSION control during an active loan —
    /// End, or Cancel while a hand-back drains. Otherwise the SPORT build tag. Start
    /// lives in the idle body; End rides up here so the active body is pure number + rail.
    @ViewBuilder
    private var statusRight: some View {
        if model.state.phase == .active {
            // The SESSION control: a subtly raised, tappable chip — a gentle top-lit gradient +
            // a soft bevel rim, no gloss (Jeremy 2026-07-28). Neutral (no alarming color) since
            // End is cancelable. "End" reads unambiguously on the Sport Mode glance; text color
            // carries the state (neutral End vs warn Cancel) over the shared chip chrome.
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
            // Just the build tag — "SPORT" misreads when sport isn't active (Jeremy
            // 2026-07-24). Temporary; the build tag goes away for production (#58).
            Text("b\(Self.buildNumber)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.glanceDim)
        }
    }

    /// The loop ring + status text. In an active loan the ring is the tappable loop
    /// control; other phases show just the phase text (no loop to control yet). The ring
    /// uses the stock watch assets (loop_<freshness>_<closed|open>) so it matches the main
    /// screen exactly; freshness comes from the #48 loop-recency grade.
    @ViewBuilder
    private var loopIndicator: some View {
        if model.state.phase == .active {
            // Ring only (like the stock screen): shape carries closed/open, color carries
            // BG-recency freshness. No text — the ring says it all.
            Image(loopAssetName, bundle: Self.watchAppBundle)
                .resizable()
                .frame(width: 26, height: 26)
        } else if model.state.phase != .idle {
            // starting / handing back / draining: the phase text. IDLE shows nothing —
            // the "Start Sport Mode" button is the whole message (Jeremy 2026-07-24).
            Text(model.state.loopStatusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.glanceDim)
        }
    }

    /// (closed/open × BG-recency freshness) → the stock loop-ring asset name.
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

    /// Open (stop dosing) is fail-safe → immediate. Close (start dosing) → confirm.
    private func onLoopTap() {
        if model.state.loopClosed {
            model.setLoopClosed(false)
        } else {
            confirmingClose = true
        }
    }

    @ViewBuilder
    private var centerBlock: some View {
        switch model.state.phase {
        case .idle:     idleCenter
        case .starting: startingCenter
        default:        standardCenter
        }
    }

    /// Idle/activation (redesigned 2026-07-24): the screen's job is to START, so the Start
    /// button is the centered hero. Phone-fed BG is a small dimmed labeled line (the phone
    /// is the source; the watch isn't looping yet). Softer than the number-first active
    /// screen — no 64pt number, calm-blue button instead of burnt-orange.
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
            Button { model.startSportMode() } label: {
                Text("Start Sport Mode")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.glanceAccent)
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

    /// Starting/connect (2026-07-24): same calm activation aesthetic as idle — small
    /// phone-BG line, no 64pt number — with the R24 connect progress (stage + determinate
    /// pod bar + G7 ETA) centered as the hero. The pod bar is glanceAccent (now calm blue).
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
                (Text("eventually ").foregroundColor(.glanceDim) + Text(eventual).bold())
                    .font(.system(size: 13))
            } else if model.state.viaPhone, model.state.phase == .idle || model.state.phase == .starting {
                Text("via iPhone").font(.system(size: 12)).foregroundColor(.glanceDim)
            }
            // R24: predicted next G7 while active without a fresh direct reading.
            // (While starting, the prediction rides under the pod bar instead.)
            if model.state.phase == .active, let eta = model.state.g7EtaText {
                Text(eta).font(.system(size: 11)).foregroundColor(.glanceDim)
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
                // Option C (2026-07-24): the session control (End / Cancel) lives top-right,
                // so the active body is pure number + rail. While a hand-back drains, keep
                // the honest "still in control" note here (Cancel is top-right).
                if model.state.handbackPending {
                    // #67 follow-up (2026-08-03): "Records syncing…" is FALSE when the phone
                    // can't be reached — nothing is syncing, and the reassuring dim styling
                    // made a stuck hand-back look like normal progress. Field 00:41:43 that
                    // night: End tapped with phone BT+WiFi off; isReachable correctly returned
                    // false and the controller logged it, but this branch rendered no note at
                    // all (idleNote is only drawn on the idle screen and in .handingBack), so
                    // the wrist still read "Records syncing to iPhone…". Detection was right;
                    // this was the missing half.
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
            }
            .padding(.bottom, 2)
        case .idle, .starting:
            // Idle & starting content is centered (idleCenter / startingCenter); nothing
            // at the bottom for those phases (#22 one-tap start lives in idleCenter).
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

    /// R24 connect UX: a determinate bar calibrated to the expected ~10s takeover.
    /// It fills to 95% on schedule and holds there honestly (with a note) if the
    /// takeover overruns; completion is the whole view flipping to the active glance.
    /// The G7 prediction rides below — deliberately decoupled from the pod bar.
    /// Deliberately PESSIMISTIC (Jeremy, 2026-08-04): "I want the successful grant to almost
    /// always finish early… that way the typical takeover is a pleasant surprise." Measured
    /// takeovers run 8-12s, so a 12s fill means the good case completes at or before the bar
    /// lands rather than after it — the bar is an upper estimate to be beaten, not a forecast
    /// to be matched.
    // The watch-side reclaim bar added in build 222 is REMOVED (Jeremy, build 223: "I saw a
    // flash of a progress bar in the sport loop screen on the watch for the reclaim process.
    // Confirming that we don't want that"). Reclaim progress belongs on the PHONE's pump pill,
    // which is the surface that owns the pod's return; the wrist keeps its honest text.

    private static let podTakeoverExpected: TimeInterval = 12
    /// Kept 4s beyond the fill, as before, so "taking longer than usual" still means genuinely
    /// atypical rather than firing the moment the bar pins.
    private static let podTakeoverOverrun: TimeInterval = 16

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
                // No timing anchor (e.g. relaunch mid-takeover) — honest indeterminate.
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
                .minimumScaleFactor(0.6)   // TEMP ("+1.20") is wider than IOB/COB — shrink to fit its cell
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

// MARK: - On-wrist sensor-code entry (wrong-code recovery)

/// 4-digit sensor-code entry on the watch (2026-07-24). The user may be mid-workout with no
/// iPhone, so the watch must be able to take the corrected code itself — this is the
/// watch-primary half of the wrong-code flow. Presented from the glance's re-enter banner.
struct SensorCodeEntryView: View {
    let onSubmit: (String) -> Void
    @State private var code = ""

    private var digits: String { String(code.filter { $0.isNumber }.prefix(4)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(NSLocalizedString("Sensor Code", comment: "Sensor code entry title"))
                    .font(.headline)
                Text(NSLocalizedString("The new G7 wouldn't authenticate. Enter the 4-digit code from the sensor applicator.", comment: "Sensor code entry explanation"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                TextField("0000", text: $code)
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.center)
                Button(NSLocalizedString("Submit", comment: "Submit sensor code")) {
                    onSubmit(digits)
                }
                .disabled(digits.count != 4)
                .tint(.glanceAccent)
            }
            .padding()
        }
    }
}

// MARK: - Palette (R23: true black; calm-blue identity as of 2026-07-24 — was saddle-brown; semantic state colors)

extension Color {
    static let glanceInk = Color(white: 0.95)
    static let glanceDim = Color(white: 0.55)
    static let glanceAccent = Color(red: 0.36, green: 0.56, blue: 0.82)   // #5C8FD1 calm blue — retired the burnt-orange identity 2026-07-24 (distinct from the green loop ring)
    static let glanceGood = Color(red: 0.31, green: 0.82, blue: 0.48)
    static let glanceWarn = Color(red: 0.91, green: 0.70, blue: 0.25)
    static let glanceCrit = Color(red: 0.88, green: 0.36, blue: 0.31)
}

// MARK: - Previews (every state, no runtime demo branches)

/// The glance's top-right session-pill chrome (R25): a subtly raised, tappable chip — a
/// gentle top-lit gradient + a soft bevel rim, no gloss (Jeremy 2026-07-28). Shared by the
/// End and Cancel states via `.modifier()`; `tint` is the label color that carries the state.
/// MUST live outside the `#if DEBUG` preview block below — statusRight (always compiled)
/// applies it, so a DEBUG-only definition fails the Release archive ("cannot find in scope").
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

/// #22: crown-to-fill confirmation for closing the loop (enabling autonomous dosing), matching
/// the bolus-delivery ceremony (BolusConfirmationView). Rotate the Digital Crown to sweep the ring
/// to 100%; a `.success` haptic fires and the loop closes. Releasing mid-sweep auto-resets
/// (PeriodicPublisher), so it's cancelable. MUST live outside the `#if DEBUG` preview block — it's
/// presented from statusLine, which is always compiled.
private struct LoopCloseCrownConfirmation: View {
    @Binding private var progressStorage: Double
    private let completion: () -> Void
    private let resetProgress = PeriodicPublisher(interval: 0.25)

    private var progress: Binding<Double> {
        Binding(
            get: { self.progressStorage.clamped(to: -1...1) },
            set: { newValue in
                guard abs(self.progressStorage) < 1.0 else { return }   // no changes after completion
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

/// Runtime glance-state gallery, reachable from the bench page (Diagnostics → Glance
/// demo). Reliable on the simulator where the legacy WatchKit extension's *live*
/// SwiftUI previews hang — this is a real running view, so it renders and interacts.
/// Tap a state to show it; the loop pill toggles OPEN↔CLOSED live.
struct GlanceDemoView: View {
    @StateObject private var model = GlanceViewModel(preview: GlanceDemoView.states[0].state)

    static let states: [(name: String, state: GlanceUIState)] = [
        ("Active · in range · CLOSED", previewState { s in
            s.phase = .active; s.bgText = "142"; s.trendSymbol = "↗"; s.bgColor = .inRange
            s.eventualText = "128"; s.iobText = "1.8"; s.cobText = "24"; s.tempText = "+0.75"
            s.loopFreshness = .fresh; s.loopClosed = true; s.canToggleLoop = true }),
        ("Active · OPEN (advisory)", previewState { s in
            s.phase = .active; s.bgText = "142"; s.trendSymbol = "↗"; s.bgColor = .inRange
            s.eventualText = "128"; s.iobText = "1.8"; s.cobText = "24"; s.tempText = "—"
            s.loopFreshness = .fresh; s.loopClosed = false; s.canToggleLoop = true }),
        ("Active · high", previewState { s in
            s.phase = .active; s.bgText = "214"; s.trendSymbol = "→"; s.bgColor = .high
            s.eventualText = "176"; s.iobText = "2.6"; s.cobText = "31"; s.tempText = "+1.20"
            s.loopFreshness = .fresh; s.loopClosed = true; s.canToggleLoop = true }),
        ("Active · low", previewState { s in
            s.phase = .active; s.bgText = "64"; s.trendSymbol = "↘"; s.bgColor = .low
            s.eventualText = "58"; s.iobText = "0.4"; s.cobText = "0"; s.tempText = "0.00"
            s.loopFreshness = .fresh; s.loopClosed = true; s.canToggleLoop = true }),
        // BG recency drives the ring, open OR closed (2026-07-24) — open is NOT gray.
        ("Active · aging BG · CLOSED", previewState { s in
            s.phase = .active; s.bgText = "142"; s.trendSymbol = "→"; s.bgColor = .inRange
            s.eventualText = "158"; s.iobText = "1.6"; s.cobText = "18"; s.tempText = "+0.90"
            s.loopFreshness = .aging; s.loopClosed = true; s.canToggleLoop = true }),
        ("Active · aging BG · OPEN", previewState { s in
            s.phase = .active; s.bgText = "142"; s.trendSymbol = "→"; s.bgColor = .inRange
            s.eventualText = "158"; s.iobText = "1.6"; s.cobText = "18"; s.tempText = "—"
            s.loopFreshness = .aging; s.loopClosed = false; s.canToggleLoop = true }),
        ("Stale glucose · CLOSED", previewState { s in
            s.phase = .active; s.bgText = "148"; s.bgColor = .dim
            s.staleAgeText = "16 min ago — no direct G7"; s.iobText = "1.8"; s.cobText = "24"
            s.loopFreshness = .stale; s.loopClosed = true }),
        ("Sensor code wrong (banner)", previewState { s in
            s.phase = .active; s.bgText = "142"; s.trendSymbol = "→"; s.bgColor = .inRange
            s.eventualText = "128"; s.iobText = "1.8"; s.cobText = "24"; s.tempText = "+0.75"
            s.loopFreshness = .fresh; s.loopClosed = true; s.canToggleLoop = true
            s.needsSensorCode = true }),
        ("Idle · activation", previewState { s in
            s.phase = .idle; s.bgText = "138"; s.trendSymbol = "→"; s.bgColor = .dim
            s.viaPhone = true; s.loopStatusText = "phone loop active" }),
        ("Starting · reaching iPhone", previewState { s in
            s.phase = .starting; s.bgText = "138"; s.trendSymbol = "→"; s.bgColor = .dim
            s.viaPhone = true; s.loopStatusText = "starting…"
            s.startingStageText = "reaching iPhone…"   // nil anchor → indeterminate spinner
            s.g7EtaText = "G7 in ~3:10" }),
        ("Starting · pod takeover (R24)", previewState { s in
            s.phase = .starting; s.bgText = "138"; s.trendSymbol = "→"; s.bgColor = .dim
            s.viaPhone = true; s.loopStatusText = "starting…"
            s.startingStageText = "taking over pod…"
            s.startedAt = Date().addingTimeInterval(-3)   // bar ~30% and filling live
            s.g7EtaText = "G7 in ~2:40" }),
        ("Starting · overrun", previewState { s in
            s.phase = .starting; s.bgText = "138"; s.bgColor = .dim
            s.viaPhone = true; s.loopStatusText = "starting…"
            s.startingStageText = "taking over pod…"
            s.startedAt = Date().addingTimeInterval(-20)   // held at 95% + honest note
            s.g7EtaText = "G7 in ~1:10" }),
        ("Active · awaiting first G7", previewState { s in
            s.phase = .active; s.bgText = "148"; s.bgColor = .dim
            s.staleAgeText = "no direct G7 reading yet"; s.g7EtaText = "G7 in ~1:20"
            s.iobText = "1.8"; s.cobText = "24"
            s.loopStatusText = "PAUSED"; s.loopDotColor = .glanceWarn }),
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

#Preview("Active · in range") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "142"; s.trendSymbol = "↗"; s.bgColor = .inRange
        s.eventualText = "128"; s.iobText = "1.8"; s.cobText = "24"; s.tempText = "+0.75"
        s.loopStatusText = "CLOSED · 2m"; s.loopDotColor = .glanceGood
    }))
}

#Preview("Active · high") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "214"; s.trendSymbol = "→"; s.bgColor = .high
        s.eventualText = "176"; s.iobText = "2.6"; s.cobText = "31"; s.tempText = "+1.20"
        s.loopStatusText = "CLOSED · 1m"; s.loopDotColor = .glanceGood
    }))
}

#Preview("Active · low") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "64"; s.trendSymbol = "↘"; s.bgColor = .low
        s.eventualText = "58"; s.iobText = "0.4"; s.cobText = "0"; s.tempText = "0.00"
        s.loopStatusText = "CLOSED · 3m"; s.loopDotColor = .glanceGood
    }))
}

#Preview("Stale") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "148"; s.bgColor = .dim
        s.staleAgeText = "9 min ago — no direct G7"
        s.iobText = "1.8"; s.cobText = "24"
        s.loopStatusText = "PAUSED"; s.loopDotColor = .glanceWarn
    }))
}

#Preview("Active · OPEN (advisory)") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "142"; s.trendSymbol = "↗"; s.bgColor = .inRange
        s.eventualText = "128"; s.iobText = "1.8"; s.cobText = "24"; s.tempText = "—"
        s.loopStatusText = "OPEN"; s.loopDotColor = .clear; s.loopClosed = false; s.canToggleLoop = true
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
        s.loopStatusText = "PAUSED"; s.loopDotColor = .glanceWarn
    }))
}
#endif
