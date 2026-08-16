//
//  WatchSettingsProvider.swift
//  WatchApp
//
//  The wrist's answer to `SettingsProvider`.
//
//  On the phone that protocol is served by `SettingsManager`, which reads a Core Data
//  history: settings can change at any time, so "what was the basal schedule between
//  T1 and T2" is a genuine query. The wrist's situation is different in a way that
//  makes the same protocol much cheaper to satisfy — it holds exactly ONE settings
//  snapshot, the one handed to it in the loan grant, and that snapshot is fixed for
//  the life of the loan. There is no history to search because there is only ever one
//  entry, in effect for the whole window.
//
//  So each history accessor here answers with the granted schedule projected across
//  the requested window, using the same `generateTimeline` upstream uses. Feeding it a
//  single schedule dated `.distantPast` says precisely what is true: this schedule was
//  already in effect before the window opened and never changed inside it.
//
//  Deliberately NOT supported: `executeSettingsQuery`. That exists so the phone can
//  sync settings history to Nightscout and Tidepool. The wrist is not a settings
//  author — it never edits therapy settings, it only borrows them — so it has no
//  history to publish, and returning an empty page is the honest answer rather than a
//  stub that pretends a store exists.
//

import Foundation
import LoopKit
import LoopAlgorithm
import LoopCore
import Observation

/// Serves the loan grant's settings snapshot to everything that expects a `SettingsProvider`
/// — principally `TemporaryPresetsManager`, which turns the schedules plus the active
/// override into the override-applied schedules the loop actually doses from.
@Observable
final class WatchSettingsProvider {

    /// The granted snapshot, as the rest of the app's settings machinery expects to see it.
    /// Replaced wholesale when a grant lands; never edited piecemeal on the wrist.
    private(set) var storedSettings: StoredSettings

    /// The `LoopSettings` the grant actually carried. Kept alongside because the loan
    /// protocol speaks in these terms and several call sites want the original.
    private(set) var loopSettings: LoopSettings

    init(settings: LoopSettings = LoopSettings()) {
        self.loopSettings = settings
        self.storedSettings = Self.stored(from: settings)
    }

    /// Apply a new grant. Whole-snapshot replacement is the point: a partial update would
    /// let the wrist dose against a mix of two grants.
    func update(with settings: LoopSettings) {
        loopSettings = settings
        storedSettings = Self.stored(from: settings)
    }

    private static func stored(from s: LoopSettings) -> StoredSettings {
        StoredSettings(
            dosingEnabled: s.dosingEnabled,
            glucoseTargetRangeSchedule: s.glucoseTargetRangeSchedule,
            preMealTargetRange: s.preMealTargetRange,
            overridePresets: s.overridePresets,
            maximumBasalRatePerHour: s.maximumBasalRatePerHour,
            maximumBolus: s.maximumBolus,
            suspendThreshold: s.suspendThreshold,
            basalRateSchedule: s.basalRateSchedule,
            insulinSensitivitySchedule: s.insulinSensitivitySchedule,
            carbRatioSchedule: s.carbRatioSchedule,
            automaticDosingStrategy: s.automaticDosingStrategy
        )
    }
}

// MARK: - SettingsProvider

extension WatchSettingsProvider: SettingsProvider {

    var settings: StoredSettings { storedSettings }

    var dosingEnabled: Bool { storedSettings.dosingEnabled }

    func getBasalHistory(startDate: Date, endDate: Date) async throws -> [AbsoluteScheduleValue<Double>] {
        guard let schedule = storedSettings.basalRateSchedule else { return [] }
        return BasalRateSchedule.generateTimeline(
            schedules: [(date: .distantPast, schedule: schedule)],
            startDate: startDate,
            endDate: endDate
        )
    }

    func getCarbRatioHistory(startDate: Date, endDate: Date) async throws -> [AbsoluteScheduleValue<Double>] {
        guard let schedule = storedSettings.carbRatioSchedule else { return [] }
        return schedule.between(start: startDate, end: endDate)
    }

    func getInsulinSensitivityHistory(startDate: Date, endDate: Date) async throws -> [AbsoluteScheduleValue<LoopQuantity>] {
        guard let schedule = storedSettings.insulinSensitivitySchedule else { return [] }
        return schedule.quantitiesBetween(start: startDate, end: endDate)
    }

    func getTargetRangeHistory(startDate: Date, endDate: Date) async throws -> [AbsoluteScheduleValue<ClosedRange<LoopQuantity>>] {
        guard let schedule = storedSettings.glucoseTargetRangeSchedule else { return [] }
        return schedule.between(start: startDate, end: endDate).map {
            AbsoluteScheduleValue(
                startDate: $0.startDate,
                endDate: $0.endDate,
                value: $0.value.quantityRange(for: schedule.unit)
            )
        }
    }

    func getDosingLimits(at date: Date) async throws -> DosingLimits {
        DosingLimits(
            suspendThreshold: storedSettings.suspendThreshold?.quantity,
            maxBolus: storedSettings.maximumBolus,
            maxBasalRate: storedSettings.maximumBasalRatePerHour
        )
    }

    /// See the file note: the wrist authors no settings, so it has no history to sync.
    func executeSettingsQuery(fromQueryAnchor queryAnchor: SettingsStore.QueryAnchor?,
                              limit: Int,
                              completion: @escaping (SettingsStore.SettingsQueryResult) -> Void) {
        completion(.success(queryAnchor ?? SettingsStore.QueryAnchor(), []))
    }
}
