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
}

// MARK: - UI state (a pure value the view renders; previews hand-build these)

struct GlanceUIState {
    enum Phase { case idle, starting, active, handingBack, draining }
    enum BGColor { case inRange, high, low, dim }

    var phase: Phase = .idle
    var bgText: String = "—"
    var trendSymbol: String? = nil
    var bgColor: BGColor = .dim
    /// non-nil = stale: shown INSTEAD of the eventual line, number dims (R9/§6a).
    var staleAgeText: String? = nil
    var eventualText: String? = nil
    /// non-nil = suspended: "insulin off · resumes H:MM" (R3/R4).
    var suspendText: String? = nil
    var iobText: String = "—"
    var cobText: String = "—"
    var tempText: String = "—"
    var loopStatusText: String = ""
    var loopDotColor: Color = .clear
    var viaPhone: Bool = false

    /// Loop open/close control (active only). `canToggleLoop` is false when the phone
    /// disallows dosing (the watch can't close what the phone opened) or when suspended.
    var loopClosed: Bool = false
    var canToggleLoop: Bool = false

    /// Idle-only: why the last Start attempt returned to idle (timeout / refusal).
    var idleNote: String? = nil

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
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Preview-only: fixed state, no timer, no store access.
    init(preview: GlanceUIState) {
        isPreview = true
        state = preview
    }

    deinit { timer?.invalidate() }

    func startSportMode() {
        guard !isPreview else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        ExtensionDelegate.shared().stockLoopSession.loanController.requestLoan(watchBuild: build)
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
        let snap = session.loanController.debugSnapshot()

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
            s.loopStatusText = NSLocalizedString("handing back…", comment: "Glance status during hand-back")
            state = s
        case .revoked, .recoveredDrain:
            var s = GlanceUIState(); s.phase = .draining
            s.loopStatusText = NSLocalizedString("returning records…", comment: "Glance status while draining records")
            state = s
        case .active:
            let data = session.stack.loopManager.glanceData()
            state = Self.activeState(data: data, suspendEndsAt: snap.suspendEndsAt, cob: latestCOB, now: Date(),
                                     phoneGlucoseDate: ExtensionDelegate.shared().loopManager.activeContext?.glucoseDate)
            session.stack.loopManager.glanceCarbsOnBoard { [weak self] cob in
                DispatchQueue.main.async { self?.latestCOB = cob }
            }
        }
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
        s.startedAt = startedAt
        s.g7EtaText = g7EtaText(lastReading: context?.glucoseDate, now: now)
        return s
    }

    /// R24 G7 prediction: the transmitter sends on a fixed 5-minute grid anchored to
    /// the sensor session, so the next transmit is predictable from ANY prior reading
    /// (phone-fed or direct — the cadence belongs to the sensor, not the receiver).
    static func g7EtaText(lastReading: Date?, now: Date) -> String? {
        let cadence: TimeInterval = 5 * 60
        guard let last = lastReading, last <= now else {
            return NSLocalizedString("G7 within 5 min", comment: "Glance G7 prediction without a prior reading")
        }
        let untilNext = cadence - now.timeIntervalSince(last).truncatingRemainder(dividingBy: cadence)
        let seconds = Int(untilNext.rounded())
        guard seconds > 10 else {
            // Imminent (or just past — BLE delivery adds seconds): no "~0:00" flicker.
            return NSLocalizedString("G7 due about now", comment: "Glance G7 prediction when the next reading is imminent")
        }
        return String(format: NSLocalizedString("G7 in ~%d:%02d", comment: "Glance countdown to the next expected G7 reading (min, sec)"),
                      seconds / 60, seconds % 60)
    }

    static func activeState(data: WatchLoopManager.GlanceData, suspendEndsAt: Date?, cob: Double?, now: Date, phoneGlucoseDate: Date? = nil) -> GlanceUIState {
        var s = GlanceUIState()
        s.phase = .active

        // Rail.
        if let iob = data.iob { s.iobText = String(format: "%.1f", iob) }
        if let cob = cob { s.cobText = String(format: "%.0f", cob) }
        if suspendEndsAt != nil {
            s.tempText = "0.00"
        } else if let rate = data.tempRate {
            s.tempText = String(format: "%+.2f", rate)
        }

        // Number + honesty.
        let age = data.glucoseDate.map { now.timeIntervalSince($0) }
        let isStale = age.map { $0 > displayStaleAge } ?? true
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
            s.g7EtaText = g7EtaText(lastReading: data.glucoseDate ?? phoneGlucoseDate, now: now)
        } else if let eventual = data.eventual {
            s.eventualText = String(format: "%.0f", eventual.doubleValue(for: .milligramsPerDeciliter))
        }

        // Status line + suspend + open/close.
        s.loopClosed = data.closedLoopEnabled
        if let until = suspendEndsAt {
            let formatter = DateFormatter(); formatter.timeStyle = .short
            s.suspendText = String(format: NSLocalizedString("insulin off · resumes %@", comment: "Glance suspended line"), formatter.string(from: until))
            s.loopStatusText = NSLocalizedString("SUSPENDED", comment: "Glance loop status while suspended")
            s.loopDotColor = .clear
            s.canToggleLoop = false   // resume from the suspend control, not the loop toggle
        } else if !data.closedLoopEnabled {
            // OPEN by choice (or the phone disallows dosing) — advisory.
            s.loopStatusText = data.dosingAllowedByPhone
                ? NSLocalizedString("OPEN", comment: "Glance loop status: advisory / open loop")
                : NSLocalizedString("OPEN · phone", comment: "Glance loop status: open because the phone disallows dosing")
            s.loopDotColor = .clear
            s.canToggleLoop = data.dosingAllowedByPhone
        } else if isStale {
            s.loopStatusText = NSLocalizedString("PAUSED", comment: "Glance loop status while glucose is stale")
            s.loopDotColor = .glanceWarn
            s.canToggleLoop = true
        } else if let completed = data.lastLoopCompleted {
            let minutes = max(0, Int(now.timeIntervalSince(completed) / 60))
            s.loopStatusText = String(format: NSLocalizedString("CLOSED · %dm", comment: "Glance loop status with age"), minutes)
            s.loopDotColor = minutes <= 10 ? .glanceGood : .glanceWarn
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
    @State private var confirmingStart = false
    @State private var confirmingClose = false

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
    }

    private var statusLine: some View {
        HStack {
            if model.state.canToggleLoop {
                Button(action: onLoopTap) { loopPill }
                    .buttonStyle(.plain)
            } else {
                loopPill
            }
            Spacer()
            Text("SPORT")
                .font(.system(size: 11, weight: .semibold))
                .kerning(1.2)
                .foregroundColor(.glanceAccent)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .alert("Close the loop?", isPresented: $confirmingClose) {
            Button("Close Loop") { model.setLoopClosed(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The watch will start adjusting your basal automatically from direct-G7 readings.")
        }
    }

    private var loopPill: some View {
        HStack(spacing: 4) {
            if model.state.loopDotColor != .clear {
                Circle().fill(model.state.loopDotColor).frame(width: 8, height: 8)
            } else if model.state.canToggleLoop {
                Circle().stroke(Color.glanceDim, lineWidth: 1.5).frame(width: 7, height: 7)   // hollow = OPEN
            }
            Text(model.state.loopStatusText)
                .font(.system(size: 12))
                .foregroundColor(.glanceDim)
        }
    }

    /// Open (stop dosing) is fail-safe → immediate. Close (start dosing) → confirm.
    private func onLoopTap() {
        if model.state.loopClosed {
            model.setLoopClosed(false)
        } else {
            confirmingClose = true
        }
    }

    private var centerBlock: some View {
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
            } else if let suspend = model.state.suspendText {
                Text(suspend).font(.system(size: 13)).foregroundColor(.glanceWarn)
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
            HStack {
                railCell(model.state.iobText, "IOB U")
                railCell(model.state.cobText, "COB G")
                railCell(model.state.tempText, "TEMP U/H")
            }
            .padding(.bottom, 2)
        case .idle:
            VStack(spacing: 4) {
                Button {
                    confirmingStart = true
                } label: {
                    Text("Start Sport Mode").font(.system(size: 15, weight: .semibold))
                }
                .tint(.glanceAccent)
                .alert(isPresented: $confirmingStart) {
                    Alert(
                        title: Text("Start Sport Mode?"),
                        message: Text("Borrows the pod from the phone and runs the loop here, on direct G7."),
                        primaryButton: .default(Text("Start")) { model.startSportMode() },
                        secondaryButton: .cancel())
                }
                if let note = model.state.idleNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(.glanceWarn)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 2)
        case .starting:
            startingBlock
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        case .handingBack, .draining:
            ProgressView()
                .padding(.bottom, 8)
        }
    }

    /// R24 connect UX: a determinate bar calibrated to the expected ~10s takeover.
    /// It fills to 95% on schedule and holds there honestly (with a note) if the
    /// takeover overruns; completion is the whole view flipping to the active glance.
    /// The G7 prediction rides below — deliberately decoupled from the pod bar.
    private static let podTakeoverExpected: TimeInterval = 10
    private static let podTakeoverOverrun: TimeInterval = 14

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

// MARK: - Palette (R23: true black, saddle-brown identity, semantic state colors)

extension Color {
    static let glanceInk = Color(white: 0.95)
    static let glanceDim = Color(white: 0.55)
    static let glanceAccent = Color(red: 0.749, green: 0.400, blue: 0.227)   // #BF663A
    static let glanceGood = Color(red: 0.31, green: 0.82, blue: 0.48)
    static let glanceWarn = Color(red: 0.91, green: 0.70, blue: 0.25)
    static let glanceCrit = Color(red: 0.88, green: 0.36, blue: 0.31)
}

// MARK: - Previews (every state, no runtime demo branches)

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
            s.loopStatusText = "CLOSED · 2m"; s.loopDotColor = .glanceGood; s.loopClosed = true; s.canToggleLoop = true }),
        ("Active · OPEN (advisory)", previewState { s in
            s.phase = .active; s.bgText = "142"; s.trendSymbol = "↗"; s.bgColor = .inRange
            s.eventualText = "128"; s.iobText = "1.8"; s.cobText = "24"; s.tempText = "—"
            s.loopStatusText = "OPEN"; s.loopClosed = false; s.canToggleLoop = true }),
        ("Active · high", previewState { s in
            s.phase = .active; s.bgText = "214"; s.trendSymbol = "→"; s.bgColor = .high
            s.eventualText = "176"; s.iobText = "2.6"; s.cobText = "31"; s.tempText = "+1.20"
            s.loopStatusText = "CLOSED · 1m"; s.loopDotColor = .glanceGood; s.loopClosed = true; s.canToggleLoop = true }),
        ("Active · low", previewState { s in
            s.phase = .active; s.bgText = "64"; s.trendSymbol = "↘"; s.bgColor = .low
            s.eventualText = "58"; s.iobText = "0.4"; s.cobText = "0"; s.tempText = "0.00"
            s.loopStatusText = "CLOSED · 3m"; s.loopDotColor = .glanceGood; s.loopClosed = true; s.canToggleLoop = true }),
        ("Stale", previewState { s in
            s.phase = .active; s.bgText = "148"; s.bgColor = .dim
            s.staleAgeText = "9 min ago — no direct G7"; s.iobText = "1.8"; s.cobText = "24"
            s.loopStatusText = "PAUSED"; s.loopDotColor = .glanceWarn }),
        ("Suspended", previewState { s in
            s.phase = .active; s.bgText = "121"; s.trendSymbol = "→"; s.bgColor = .inRange
            s.suspendText = "insulin off · resumes 1:45"; s.iobText = "0.9"; s.cobText = "12"; s.tempText = "0.00"
            s.loopStatusText = "SUSPENDED" }),
        ("Idle · activation", previewState { s in
            s.phase = .idle; s.bgText = "138"; s.trendSymbol = "→"; s.bgColor = .dim
            s.viaPhone = true; s.loopStatusText = "phone loop active" }),
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

#Preview("Suspended") {
    GlanceView(model: GlanceViewModel(preview: previewState { s in
        s.phase = .active; s.bgText = "121"; s.trendSymbol = "→"; s.bgColor = .inRange
        s.suspendText = "insulin off · resumes 1:45"
        s.iobText = "0.9"; s.cobText = "12"; s.tempText = "0.00"
        s.loopStatusText = "SUSPENDED"
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
