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

    /// Stock's onboarding gate, applied per PAGE instead of to the whole app.
    ///
    /// The stock pages have nothing to show until the phone reports both managers onboarded, so
    /// they still show stock's prompt. Sport Mode and diagnostics stay reachable regardless: the
    /// wrist has its own stores, its own CGM and its own log, and the diagnostics page is how you
    /// find out WHY the phone says onboarding is incomplete. Gating it behind the very flag you
    /// are trying to debug is the wrong way round.
    private var isOnboarded: Bool {
        loopManager.activeContext?.isOnboardingCompleted == true
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
        .onReceive(NotificationCenter.default.publisher(for: .podLoanPhaseDidChange)) { _ in
            if glanceModel.wantsFocus { selectedPage = Self.sportPage }
        }
    }
}


#Preview {
    ContentView()
}
