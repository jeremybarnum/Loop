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

    /// Selectable look-back windows. Bounded by the on-device glucose cache.
    enum DateRange: Int, CaseIterable, Identifiable {
        case week = 7
        case twoWeeks = 14
        case month = 30
        case quarter = 90

        var id: Int { rawValue }
        var days: Int { rawValue }
    }

    @Published var selectedRange: DateRange = .twoWeeks {
        didSet {
            guard selectedRange != oldValue else { return }
            recompute()
        }
    }

    @Published private(set) var statistics: GlucoseStatistics?
    @Published private(set) var isLoading = false
    /// Days of glucose actually available (bounded by data accumulated and the cache).
    @Published private(set) var availableDays: Double = 0

    private var allSamples: [StoredGlucoseSample] = []
    private let glucoseStore: GlucoseStoreProtocol
    private let calendar: Calendar
    private let now: () -> Date

    /// Configured local cache duration (how far back glucose is retained on device).
    let cacheDuration: TimeInterval

    init(glucoseStore: GlucoseStoreProtocol,
         cacheDuration: TimeInterval = Bundle.main.localCacheDuration,
         calendar: Calendar = .current,
         now: @escaping () -> Date = { Date() }) {
        self.glucoseStore = glucoseStore
        self.cacheDuration = cacheDuration
        self.calendar = calendar
        self.now = now
    }

    var cacheDurationDays: Int { Int((cacheDuration / 86400).rounded()) }

    /// True when the cache is configured below the longest range, so the longer
    /// views can never be fully populated regardless of how long Loop has run.
    var cacheLimitsHistory: Bool {
        cacheDurationDays < (DateRange.allCases.map(\.days).max() ?? 90)
    }

    /// Ranges we have enough data to offer (always at least the shortest). A range
    /// is offered once data reaches within a day of its length.
    var availableRanges: [DateRange] {
        DateRange.allCases.filter { $0 == .week || availableDays >= Double($0.days) - 1 }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        let end = now()
        let start = end.addingTimeInterval(-cacheDuration)
        do {
            allSamples = try await glucoseStore.getGlucoseSamples(start: start, end: end)
                .filter { !$0.isDisplayOnly && !$0.wasUserEntered }
                .sorted { $0.startDate < $1.startDate }
        } catch {
            allSamples = []
        }
        availableDays = allSamples.first.map { end.timeIntervalSince($0.startDate) / 86400 } ?? 0

        // Drop to the largest available range if the current selection outruns the data.
        if !availableRanges.contains(selectedRange) {
            selectedRange = availableRanges.last ?? .week
        }
        recompute()
    }

    /// Recompute statistics for the selected window from the already-loaded samples
    /// (no store round-trip), so switching ranges is instant.
    private func recompute() {
        let end = now()
        let start = calendar.date(byAdding: .day, value: -selectedRange.days, to: end)
            ?? end.addingTimeInterval(-Double(selectedRange.days) * 24 * 60 * 60)
        statistics = GlucoseStatistics(samples: allSamples, start: start, end: end, calendar: calendar)
    }
}
