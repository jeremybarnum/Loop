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
