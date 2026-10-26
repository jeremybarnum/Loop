//
//  OrefAdapter.swift
//  Loop
//
//  Trio's oref beside Loop's algorithm, shared by the phone's loop and the watch's (Sport Mode):
//  Loop's stores and settings in oref's terms, and oref's decision as Loop's automatic dose
//  recommendation. Each caller passes its own sources, as with `StoredDataAlgorithmInput.fetch`.
//

import Foundation
import LoopKit
import LoopAlgorithm
import Trio

enum OrefAdapter {
    /// Loop's stores and settings in oref's terms: 24 hours of glucose and carbs and 30 of doses (autosens
    /// looks back 24 hours), schedules shifted to this device's time zone, and Loop's override as oref's.
    static func input(
        at now: Date,
        preferences: OrefPreferences,
        settings: StoredSettings,
        doseStore: DoseStoreProtocol,
        carbStore: CarbStoreProtocol,
        glucoseStore: GlucoseStoreProtocol,
        activeOverride: TemporaryScheduleOverride?,
        currentTempBasal: DoseEntry?,
        insulinType: InsulinType?,
        dailyDoses: DailyDoses
    ) async throws -> OrefInput {
        guard let basalSchedule = settings.basalRateSchedule else { throw LoopError.configurationError(.basalRateSchedule) }
        guard let sensitivitySchedule = settings.insulinSensitivitySchedule else { throw LoopError.configurationError(.insulinSensitivitySchedule) }
        guard let carbRatioSchedule = settings.carbRatioSchedule else { throw LoopError.configurationError(.carbRatioSchedule) }
        guard let targetSchedule = settings.glucoseTargetRangeSchedule else { throw LoopError.configurationError(.glucoseTargetRangeSchedule) }
        guard let maxBasal = settings.maximumBasalRatePerHour else { throw LoopError.configurationError(.maximumBasalRatePerHour) }
        guard let maxBolus = settings.maximumBolus else { throw LoopError.configurationError(.maximumBolus) }

        let glucose = try await glucoseStore.getGlucoseSamples(start: now.addingTimeInterval(.hours(-24)), end: now)
            .filter { !$0.isDisplayOnly && !$0.wasUserEntered }
            .map { OrefInput.Glucose(date: $0.startDate, mgdL: $0.quantity.doubleValue(for: .milligramsPerDeciliter)) }

        let doseEntries = try await doseStore.getNormalizedDoseEntries(start: now.addingTimeInterval(.hours(-30)), end: now)
        let doses: [OrefInput.Dose] = doseEntries.compactMap { dose in
            let id = dose.syncIdentifier ?? "\(dose.type)-\(dose.startDate.timeIntervalSince1970)"
            switch dose.type {
            case .bolus:
                return .bolus(id: id, date: dose.startDate, units: dose.deliveredUnits ?? dose.programmedUnits, automatic: dose.automatic ?? false)
            case .tempBasal:
                return .tempBasal(id: id, start: dose.startDate, minutes: dose.duration.minutes, unitsPerHour: dose.unitsPerHour)
            case .suspend:
                return .suspend(id: id, start: dose.startDate, end: dose.endDate > dose.startDate ? dose.endDate : nil)
            case .basal, .resume:
                return nil
            }
        }

        let carbs = try await carbStore.getCarbEntries(start: now.addingTimeInterval(.hours(-24)), end: now).map {
            OrefInput.Carbs(id: $0.syncIdentifier ?? $0.uuid?.uuidString ?? "\($0.startDate.timeIntervalSince1970)",
                            date: $0.startDate, grams: $0.quantity.doubleValue(for: .gram))
        }

        let mgdL = LoopUnit.milligramsPerDeciliter
        let basal = orefSchedule(basalSchedule.items.map { ($0.startTime, $0.value) }, timeZone: basalSchedule.timeZone)
        // The sensitivity schedule's unit is the glucose unit (mg/dL or mmol/L), per unit of insulin.
        let sensitivity = orefSchedule(sensitivitySchedule.items.map {
            ($0.startTime, LoopQuantity(unit: sensitivitySchedule.unit, doubleValue: $0.value).doubleValue(for: mgdL))
        }, timeZone: sensitivitySchedule.timeZone)
        let carbRatio = orefSchedule(carbRatioSchedule.items.map { ($0.startTime, $0.value) }, timeZone: carbRatioSchedule.timeZone)
        let lows = orefSchedule(targetSchedule.items.map {
            ($0.startTime, LoopQuantity(unit: targetSchedule.unit, doubleValue: $0.value.minValue).doubleValue(for: mgdL))
        }, timeZone: targetSchedule.timeZone)
        let highs = orefSchedule(targetSchedule.items.map {
            ($0.startTime, LoopQuantity(unit: targetSchedule.unit, doubleValue: $0.value.maxValue).doubleValue(for: mgdL))
        }, timeZone: targetSchedule.timeZone)
        let targets = zip(lows, highs).map { OrefInput.TargetItem(minutes: $0.minutes, low: $0.value, high: $1.value) }

        let suspendThreshold = settings.suspendThreshold?.quantity.doubleValue(for: mgdL) ?? 70

        let override: OrefInput.Override? = activeOverride.map { active in
            let target = active.settings.targetRange.map {
                ($0.lowerBound.doubleValue(for: mgdL) + $0.upperBound.doubleValue(for: mgdL)) / 2
            }
            return OrefInput.Override(percentage: (active.settings.insulinNeedsScaleFactor ?? 1) * 100, target: target)
        }

        let currentTemp = currentTempBasal.flatMap { temp -> OrefInput.CurrentTemp? in
            guard temp.endDate > now else { return nil }
            return OrefInput.CurrentTemp(start: temp.startDate, minutesRemaining: temp.endDate.timeIntervalSince(now).minutes,
                                         unitsPerHour: temp.unitsPerHour)
        }

        let insulinCurve: OrefInput.InsulinCurve
        switch insulinType {
        case .fiasp?, .lyumjev?: insulinCurve = .ultraRapid
        default: insulinCurve = .rapidActing
        }

        return OrefInput(
            now: now, glucose: glucose, doses: doses, carbs: carbs,
            basal: basal, sensitivity: sensitivity, carbRatio: carbRatio, targets: targets,
            suspendThreshold: suspendThreshold, maxBolus: maxBolus, maxBasalRate: maxBasal,
            insulinCurve: insulinCurve, insulinActionHours: max(preferences.insulinActionHours, 5),
            // oref floors micro-boluses to this; Loop then rounds to what the pump supports.
            bolusIncrement: 0.05, supportedBasalRates: [],
            currentTemp: currentTemp, override: override, reservoir: doseStore.lastReservoirValue?.unitVolume,
            totalDailyDose: dailyDoses.total, averageDailyDose: dailyDoses.average,
            preferences: preferences
        )
    }

    /// oref's decision as Loop's automatic dose recommendation. oref leaves the rate empty when the running
    /// temp should continue; its micro-bolus is capped at Loop's maximum bolus.
    static func recommendation(from output: OrefOutput, scheduledBasal: Double, currentTempBasal: DoseEntry?,
                               maxBolus: Double) -> AutomaticDoseRecommendation {
        let rate = output.unitsPerHour ?? currentTempBasal?.unitsPerHour ?? scheduledBasal
        let direction: AutomaticDoseRecommendation.Direction = rate > scheduledBasal ? .increase : rate < scheduledBasal ? .decrease : .neutral
        return AutomaticDoseRecommendation(
            basalAdjustment: TempBasalRecommendation(unitsPerHour: rate, duration: .minutes(output.durationMinutes ?? 30)),
            direction: direction,
            bolusUnits: output.microBolus.map { min($0, maxBolus) }
        )
    }

    static func logLine(_ output: OrefOutput) -> String {
        String(format: "oref: %@ for %@ min, SMB %@, eventual %@ — ",
               output.unitsPerHour.map { String(format: "%.2f U/h", $0) } ?? "keep temp",
               output.durationMinutes.map { String(format: "%.0f", $0) } ?? "-",
               output.microBolus.map { String(format: "%.2f U", $0) } ?? "none",
               output.eventualBG.map { String(format: "%.0f", $0) } ?? "-") + output.reason
    }

    // MARK: - Daily insulin (dynamic ISF only)

    struct DailyDoses: Codable, Equatable {
        /// Insulin delivered over the last 24 hours.
        var total: Double?
        /// Average per day over up to the last 7 days, refreshed hourly; nil under one day of history.
        var average: Double?
    }

    /// The last totals this device computed; the phone puts them in a loan grant.
    nonisolated(unsafe) static var lastDailyDoses = DailyDoses()
    nonisolated(unsafe) private static var averageCache: (date: Date, value: Double?)?

    static func dailyDoses(at now: Date, doseStore: DoseStoreProtocol) async throws -> DailyDoses {
        let day = try await doseStore.getNormalizedDoseEntries(start: now.addingTimeInterval(.hours(-24)), end: now)
        let total = insulinDelivered(day, from: now.addingTimeInterval(.hours(-24)), to: now)

        let average: Double?
        if let cached = averageCache, now.timeIntervalSince(cached.date) < .hours(1) {
            average = cached.value
        } else {
            let start = now.addingTimeInterval(.days(-7))
            let week = try await doseStore.getNormalizedDoseEntries(start: start, end: now)
            let covered = now.timeIntervalSince(max(start, week.map(\.startDate).min() ?? now))
            average = covered >= .days(1) ? insulinDelivered(week, from: start, to: now) / (covered / .days(1)) : nil
            averageCache = (now, average)
        }
        let doses = DailyDoses(total: total > 0 ? total : nil, average: average)
        lastDailyDoses = doses
        return doses
    }

    /// Insulin delivered between two dates: boluses by start time, basal pro rata.
    private static func insulinDelivered(_ doses: [DoseEntry], from start: Date, to end: Date) -> Double {
        doses.reduce(0) { total, dose in
            switch dose.type {
            case .bolus:
                return dose.startDate >= start && dose.startDate < end ? total + (dose.deliveredUnits ?? dose.programmedUnits) : total
            case .basal, .tempBasal:
                let overlap = min(dose.endDate, end).timeIntervalSince(max(dose.startDate, start))
                return overlap > 0 ? total + dose.unitsPerHour * overlap / .hours(1) : total
            case .suspend, .resume:
                return total
            }
        }
    }

    /// A Loop daily schedule (seconds after midnight in the schedule's time zone) as oref's (minutes after
    /// midnight in this device's time zone, starting at midnight).
    private static func orefSchedule(_ items: [(TimeInterval, Double)], timeZone: TimeZone) -> [OrefInput.ScheduleItem] {
        let shift = TimeInterval(TimeZone.current.secondsFromGMT() - timeZone.secondsFromGMT())
        let day = TimeInterval.days(1)
        var shifted = items.map { item -> OrefInput.ScheduleItem in
            let start = (item.0 + shift).truncatingRemainder(dividingBy: day)
            return OrefInput.ScheduleItem(minutes: Int(((start < 0 ? start + day : start) / 60).rounded()), value: item.1)
        }.sorted { $0.minutes < $1.minutes }
        if let first = shifted.first, first.minutes != 0, let last = shifted.last {
            shifted.insert(OrefInput.ScheduleItem(minutes: 0, value: last.value), at: 0)
        }
        return shifted
    }
}

/// What a loan grant carries for oref: the phone's choice and settings, and its daily insulin totals
/// (the watch holds too little dose history to compute them). Opaque JSON in `LoanGrant.orefContext`.
struct OrefLoanContext: Codable, Equatable {
    var configuration: OrefConfiguration
    var dailyDoses: OrefAdapter.DailyDoses
}
