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

    var body: some View {
        VStack {
            // TabView for swipeable pages
            TabView(selection: $selectedPage) {
                WatchActionsView()
                    .tag(0)
                    .task {
                        loopManager.requestContextUpdate {}
                    }

                ChartPageView()
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
