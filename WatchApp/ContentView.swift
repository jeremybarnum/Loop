//
//  WatchAppContent.swift
//  Loop
//
//  Created by Pete Schwamb on 9/21/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import LoopKit
import SwiftUI

struct ContentView: View {
    @Environment(LoopDataManager.self) var loopManager

    @State private var presetToConfirm: SelectablePreset? = nil
    @State private var selectedPage = UserDefaults.standard.startOnChartPage ? 1 : 0
    @StateObject private var glanceModel = GlanceViewModel()

    /// The glance's page index. Named rather than written inline because a live loan lands the
    /// user here, and a bare `2` at that call site would be a silent dependency on page order.
    private static let sportPage = 2

    /// Mirrored into plain state rather than read from `glanceModel` inside `body`. Reading the
    /// model here would subscribe THE ROOT VIEW to a timer-driven object on the loan path, so
    /// every glance tick would invalidate the whole app — and a publish that arrives off the main
    /// thread would do it from the wrong thread, which SwiftUI does not survive.
    @State private var loanIsLive = false

    /// Stock's onboarding gate, applied per PAGE instead of to the whole app.
    ///
    /// The stock pages have nothing to show until the phone reports both managers onboarded, so
    /// they still show stock's prompt. Sport Mode and diagnostics stay reachable regardless: the
    /// wrist has its own stores, its own CGM and its own log, and the diagnostics page is how you
    /// find out WHY the phone says onboarding is incomplete. Gating it behind the very flag you
    /// are trying to debug is the wrong way round.
    ///
    /// A LIVE LOAN OPENS THE GATE ON ITS OWN. The flag this consults is the PHONE's — set from the
    /// phone's own CGM and pump onboarding state, and reaching the wrist inside a context update.
    /// During a loan the phone may be switched off entirely, so it cannot arrive: waiting for it
    /// blanks precisely the screens the wrist needs while it is the one holding the pod. The watch
    /// is authoritative then, with its own stores and its own CGM, so the phone's readiness is not
    /// the question being asked.
    private var isOnboarded: Bool {
        if loanIsLive { return true }
        return loopManager.activeContext?.isOnboardingCompleted == true
    }

    var body: some View {
        VStack {
            // TabView for swipeable pages
            TabView(selection: $selectedPage) {
                // Gated pages keep their slots whether or not they are gated — the page indices
                // below are load-bearing (see sportPage), and a page that vanishes renumbers
                // the ones beside it.
                Group {
                    if isOnboarded { WatchActionsView() } else { CompleteOnboardingView() }
                }
                    .tag(0)
                    .task {
                        loopManager.requestContextUpdate {}
                    }

                Group {
                    if isOnboarded { ChartPageView() } else { CompleteOnboardingView() }
                }
                    .tag(1)
                    .task {
                        loopManager.requestContextUpdate {}
                    }

                // Sport Mode. Always present rather than conditionally inserted: a page that
                // appears and disappears under the user renumbers the ones beside it, and the
                // glance is also the only way to START a session, so it has to be reachable
                // before there is anything to show.
                GlanceView(model: glanceModel)
                    .tag(Self.sportPage)

                // Diagnostics. Last, so a swipe never lands here by accident.
                //
                // Retracting a loan-time carb lives in the STOCK Active Carbs list (CarbList),
                // reached by tapping through from the chart page — not on a page of its own. It
                // is the same list either way; during a loan it reads the loan's store and gains
                // swipe-to-delete.
                LoanDebugView()
                    .tag(Self.sportPage + 1)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .automatic))
        }
        .onChange(of: loopManager.pendingPresetReminder) { oldValue, newValue in
            if oldValue == nil, newValue != nil {
                presetToConfirm = loopManager.pendingPreset
            }
        }
        .sheet(item: $presetToConfirm) { preset in
            PresetConfirmationView(preset: preset)
        }
        .onChange(of: selectedPage, { oldValue, newValue in
            // Only pages 0/1 are remembered; landing on Sport is a consequence of a live loan,
            // not a preference to restore on next launch.
            if newValue < Self.sportPage {
                UserDefaults.standard.startOnChartPage = newValue == 1
            }
        })
        // A loan activating takes the user to the glance — it is the surface that says what the
        // watch is doing while it holds the pump. Replaces the WatchKit page-navigation call the
        // session used to make directly.
        // `.receive(on:)` is load-bearing, not tidiness: the phase notification is posted from
        // the loan's own queue, and both statements below mutate view state.
        .onReceive(NotificationCenter.default.publisher(for: .podLoanPhaseDidChange).receive(on: RunLoop.main)) { _ in
            let live = glanceModel.wantsFocus
            loanIsLive = live
            if live { selectedPage = Self.sportPage }
        }
        // Finishing a carb entry or a bolus during a loan returns to the glance.
        //
        // The flow is a SHEET presented from page 0, so dismissing it lands the user back on the
        // stock actions page. That is correct when the phone holds the pod — the actions page is
        // where they started. It is wrong when the WRIST holds it: the glance is the only surface
        // that shows the bolus actually delivering, the resulting IOB, and the loan still being
        // held. Landing on a page that shows none of that reads as "did it work?", which is the
        // one question a just-delivered bolus must not raise.
        //
        // Gated on `wantsFocus` rather than applied always, so this never yanks the page away from
        // someone using the watch as a plain remote.
        .onReceive(NotificationCenter.default.publisher(for: .carbAndBolusFlowDidComplete).receive(on: RunLoop.main)) { _ in
            if glanceModel.wantsFocus { selectedPage = Self.sportPage }
        }
        .task {
            // The gate also has to be right on a COLD LAUNCH into a live loan — relaunching
            // mid-session posts no phase change, and that is exactly when the watch is holding
            // the pod and needs these pages.
            loanIsLive = glanceModel.wantsFocus
        }
    }
}


#Preview {
    ContentView()
}
