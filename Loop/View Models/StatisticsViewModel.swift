//
//  StatisticsViewModel.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import LoopAlgorithm

@MainActor
final class StatisticsViewModel: ObservableObject {

    /// Selectable look-back windows. Bounded by the 90-day on-device glucose cache.
    enum DateRange: Int, CaseIterable, Identifiable {
        case week = 7
        case twoWeeks = 14
        case month = 30
        case quarter = 90

        var id: Int { rawValue }
        var days: Int { rawValue }

        var localizedTitle: String {
            String(format: NSLocalizedString("%d days", comment: "Statistics date-range option (number of days)"), rawValue)
        }
    }

    @Published var selectedRange: DateRange = .twoWeeks {
        didSet {
            guard selectedRange != oldValue else { return }
            Task { await load() }
        }
    }

    @Published private(set) var statistics: GlucoseStatistics?
    @Published private(set) var isLoading = false

    private let glucoseStore: GlucoseStoreProtocol
    private let now: () -> Date
    private let calendar: Calendar

    init(glucoseStore: GlucoseStoreProtocol, calendar: Calendar = .current, now: @escaping () -> Date = { Date() }) {
        self.glucoseStore = glucoseStore
        self.calendar = calendar
        self.now = now
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        let end = now()
        let start = calendar.date(byAdding: .day, value: -selectedRange.days, to: end)
            ?? end.addingTimeInterval(-Double(selectedRange.days) * 24 * 60 * 60)

        do {
            let samples = try await glucoseStore.getGlucoseSamples(start: start, end: end)
                .filter { !$0.isDisplayOnly && !$0.wasUserEntered }
            statistics = GlucoseStatistics(samples: samples, start: start, end: end, calendar: calendar)
        } catch {
            statistics = GlucoseStatistics(samples: [], start: start, end: end, calendar: calendar)
        }
    }
}
