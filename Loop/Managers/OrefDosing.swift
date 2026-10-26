//
//  OrefDosing.swift
//  Loop
//
//  Trio's oref algorithm as a second dosing algorithm. Everything oref-specific on Loop's side is in
//  this file: the stored choice, reading Loop's stores into oref's inputs, and turning oref's decision
//  into Loop's automatic dose recommendation. LoopDataManager.loop() makes one call here.
//

import Foundation
import SwiftUI
import LoopKit
import LoopCore
import LoopAlgorithm
import Trio

/// The stored algorithm choice and oref settings, and oref's latest decision for the settings screen.
@MainActor
final class OrefStatus: ObservableObject {
    static let shared = OrefStatus()

    @Published var configuration: OrefConfiguration {
        didSet { configuration.save(to: UserDefaults.appGroup ?? .standard) }
    }
    @Published var lastOutput: OrefOutput?

    private init() {
        configuration = OrefConfiguration.load(from: UserDefaults.appGroup ?? .standard)
    }
}

struct OrefSettingsScreen: View {
    @ObservedObject var status = OrefStatus.shared

    var body: some View {
        OrefSettingsView(configuration: $status.configuration, lastOutput: status.lastOutput)
    }
}

extension DosingAlgorithm {
    var title: String {
        switch self {
        case .loop: return "Loop"
        case .orefShadow: return "Loop, oref alongside"
        case .oref: return "oref (Trio)"
        }
    }
}

extension LoopDataManager {
    /// When oref is chosen, replaces Loop's automatic recommendation in `output` with oref's; when oref runs
    /// alongside, only logs it. Loop's forecast in `output` is kept either way: the screen, the warnings and
    /// the bolus calculator keep using it. If oref fails, the cycle fails rather than falling back to Loop.
    func applyOref(to output: inout AlgorithmOutput<StoredCarbEntry>, input: StoredDataAlgorithmInput, at now: Date) async throws {
        let configuration = OrefStatus.shared.configuration
        guard configuration.algorithm != .loop else { return }

        let orefOutput: OrefOutput
        do {
            let orefInput = try await orefInput(at: now, preferences: configuration.preferences)
            orefOutput = try await Task.detached(priority: .userInitiated) { try Oref.determine(orefInput) }.value
        } catch {
            logger.error("oref failed: %{public}@", String(describing: error))
            if configuration.algorithm == .oref { throw error }
            return
        }
        OrefStatus.shared.lastOutput = orefOutput
        logger.default("oref: rate %{public}@ for %{public}@ min, SMB %{public}@, eventual %{public}@ — %{public}@",
                       String(describing: orefOutput.unitsPerHour), String(describing: orefOutput.durationMinutes),
                       String(describing: orefOutput.microBolus), String(describing: orefOutput.eventualBG), orefOutput.reason)

        guard configuration.algorithm == .oref else { return }

        guard let scheduledBasal = input.basal.closestPrior(to: now)?.value else {
            throw LoopError.configurationError(.basalRateSchedule)
        }
        // oref leaves the rate empty when the running temp should continue.
        let currentTemp = deliveryDelegate?.basalDeliveryState?.currentTempBasal
        let rate = orefOutput.unitsPerHour ?? currentTemp?.unitsPerHour ?? scheduledBasal
        let duration = TimeInterval(minutes: orefOutput.durationMinutes ?? 30)
        let bolus = orefOutput.microBolus.map { min($0, input.maxBolus) }
        let direction: AutomaticDoseRecommendation.Direction = rate > scheduledBasal ? .increase : rate < scheduledBasal ? .decrease : .neutral

        let recommendation = AutomaticDoseRecommendation(
            basalAdjustment: TempBasalRecommendation(unitsPerHour: rate, duration: duration),
            direction: direction,
            bolusUnits: bolus
        )
        output.recommendationResult = .success(.init(automatic: recommendation))
    }

    /// Loop's stores and settings in oref's terms: 24 hours of glucose and carbs and 30 of doses (autosens
    /// looks back 24 hours), schedules shifted to the phone's time zone, and Loop's override as oref's.
    private func orefInput(at now: Date, preferences: OrefPreferences) async throws -> OrefInput {
        let settings = settingsProvider.settings
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
        let isfUnit = LoopUnit.milligramsPerDeciliterPerInternationalUnit
        let basal = Self.orefSchedule(basalSchedule.items.map { ($0.startTime, $0.value) }, timeZone: basalSchedule.timeZone)
        let sensitivity = Self.orefSchedule(sensitivitySchedule.items.map {
            ($0.startTime, LoopQuantity(unit: sensitivitySchedule.unit, doubleValue: $0.value).doubleValue(for: isfUnit))
        }, timeZone: sensitivitySchedule.timeZone)
        let carbRatio = Self.orefSchedule(carbRatioSchedule.items.map { ($0.startTime, $0.value) }, timeZone: carbRatioSchedule.timeZone)
        let lows = Self.orefSchedule(targetSchedule.items.map {
            ($0.startTime, LoopQuantity(unit: targetSchedule.unit, doubleValue: $0.value.minValue).doubleValue(for: mgdL))
        }, timeZone: targetSchedule.timeZone)
        let highs = Self.orefSchedule(targetSchedule.items.map {
            ($0.startTime, LoopQuantity(unit: targetSchedule.unit, doubleValue: $0.value.maxValue).doubleValue(for: mgdL))
        }, timeZone: targetSchedule.timeZone)
        let targets = zip(lows, highs).map { OrefInput.TargetItem(minutes: $0.minutes, low: $0.value, high: $1.value) }

        let suspendThreshold = settings.suspendThreshold?.quantity.doubleValue(for: mgdL) ?? 70

        let override: OrefInput.Override? = temporaryPresetsManager.presetHistory.activeOverride(at: now).map { active in
            let target = active.settings.targetRange.map {
                ($0.lowerBound.doubleValue(for: mgdL) + $0.upperBound.doubleValue(for: mgdL)) / 2
            }
            return OrefInput.Override(percentage: (active.settings.insulinNeedsScaleFactor ?? 1) * 100, target: target)
        }

        let currentTemp = deliveryDelegate?.basalDeliveryState?.currentTempBasal.flatMap { temp -> OrefInput.CurrentTemp? in
            guard temp.endDate > now else { return nil }
            return OrefInput.CurrentTemp(start: temp.startDate, minutesRemaining: temp.endDate.timeIntervalSince(now).minutes,
                                         unitsPerHour: temp.unitsPerHour)
        }

        let insulinCurve: OrefInput.InsulinCurve
        switch deliveryDelegate?.pumpInsulinType {
        case .fiasp?, .lyumjev?: insulinCurve = .ultraRapid
        default: insulinCurve = .rapidActing
        }

        let totalDailyDose = Self.insulinDelivered(doseEntries, from: now.addingTimeInterval(.hours(-24)), to: now)
        let averageDailyDose = try await orefAverageDailyDose(at: now)

        return OrefInput(
            now: now, glucose: glucose, doses: doses, carbs: carbs,
            basal: basal, sensitivity: sensitivity, carbRatio: carbRatio, targets: targets,
            suspendThreshold: suspendThreshold, maxBolus: maxBolus, maxBasalRate: maxBasal,
            insulinCurve: insulinCurve, insulinActionHours: 6,
            // oref floors micro-boluses to this; Loop then rounds to what the pump supports.
            bolusIncrement: 0.05, supportedBasalRates: [],
            currentTemp: currentTemp, override: override, reservoir: doseStore.lastReservoirValue?.unitVolume,
            totalDailyDose: totalDailyDose > 0 ? totalDailyDose : nil, averageDailyDose: averageDailyDose,
            preferences: preferences
        )
    }

    /// Average insulin per day over up to the last 7 days of dose history, refreshed hourly; nil under one day.
    private func orefAverageDailyDose(at now: Date) async throws -> Double? {
        if let cached = Self.averageDailyDoseCache, now.timeIntervalSince(cached.date) < .hours(1) { return cached.value }
        let start = now.addingTimeInterval(.days(-7))
        let doses = try await doseStore.getNormalizedDoseEntries(start: start, end: now)
        let covered = now.timeIntervalSince(max(start, doses.map(\.startDate).min() ?? now))
        let value = covered >= .days(1) ? Self.insulinDelivered(doses, from: start, to: now) / (covered / .days(1)) : nil
        Self.averageDailyDoseCache = (now, value)
        return value
    }

    nonisolated(unsafe) private static var averageDailyDoseCache: (date: Date, value: Double?)?

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
    /// midnight in the phone's time zone, starting at midnight).
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
