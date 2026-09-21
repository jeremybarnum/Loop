//
//  WatchLoopManager+Dosing.swift
//  WatchApp Extension
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import G7SensorKit
import WatchConnectivity
import os.log

extension WatchLoopManager {

    func seedInsulinHistory(_ entries: [DoseEntry]) async throws {
        try await doseStore.syncDoseEntries(entries)
    }

    func recordPumpEvents(_ events: [NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool) async throws {
        try await doseStore.addPumpEvents(events, lastReconciliation: lastReconciliation, replacePendingEvents: replacePendingEvents)
    }

    func resetInsulinBook(reason: String) async {
        do {
            try await doseStore.resetPumpData()
        } catch {
            SportLog.event("book", "reset FAILED (pump events) — \(reason): \(String(describing: error))")
        }
        await doseStore.insulinDeliveryStore.purgeCachedInsulinDeliveryObjects()
        SportLog.event("book", "insulin book reset — \(reason)")
    }

    func insulinOnBoardFromStore(at date: Date) -> Double? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        guard let basal = basalRateScheduleApplyingOverrideHistory else { return nil }
        let longest = doseStore.longestEffectDuration
        guard let doses = try? runBlocking({
            try await self.doseStore.getNormalizedDoseEntries(start: date.addingTimeInterval(-longest), end: nil)
        }) else { return nil }
        if doses.isEmpty { return 0 }
        let window = (start: doses.map(\.startDate).min() ?? date,
                      end: (doses.map(\.endDate).max() ?? date).addingTimeInterval(longest))
        let basalTimeline = BasalRateSchedule.generateTimeline(
            schedules: [(date: .distantPast, schedule: basal)],
            startDate: window.start,
            endDate: window.end)
        let timeline = doses
            .map { $0.simpleDose(with: insulinModel(for: $0.insulinType)) }
            .annotated(with: basalTimeline)
            .insulinOnBoardTimeline(longestEffectDuration: longest,
                                    from: date.addingTimeInterval(-.minutes(5)),
                                    to: date.addingTimeInterval(.minutes(5)))
        let before = timeline.last(where: { $0.startDate <= date })?.value
        let after = timeline.first(where: { $0.startDate >= date })?.value
        return max(before ?? 0, after ?? 0)
    }

    func primeIOBFromStore(at date: Date, _ completion: @escaping (Double?) -> Void) {
        dataAccessQueue.async {
            let iob = self.insulinOnBoardFromStore(at: date)
            if let iob { self.activeInsulin = iob }
            completion(iob)
        }
    }

    func recommendManualBolus(potentialCarbEntry: NewCarbEntry? = nil,
                              completion: @escaping (Swift.Result<ManualBolusRecommendation, Error>) -> Void) {
        dataAccessQueue.async {
            completion(self.manualBolusRecommendationOnQueue(potentialCarbEntry: potentialCarbEntry))
        }
    }

    func manualBolusRecommendationOnQueue(potentialCarbEntry: NewCarbEntry? = nil) -> Swift.Result<ManualBolusRecommendation, Error> {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        var result: Swift.Result<ManualBolusRecommendation, Error>!
        let completion: (Swift.Result<ManualBolusRecommendation, Error>) -> Void = { result = $0 }
        do {
                var input = try self.runBlocking {
                    try await self.fetchAlgorithmInput(at: self.now(), recommendationType: .manualBolus)
                }

                if let potentialCarbEntry {
                    input.carbEntries += [StoredCarbEntry(
                        startDate: potentialCarbEntry.startDate,
                        quantity: potentialCarbEntry.quantity,
                        foodType: potentialCarbEntry.foodType,
                        absorptionTime: potentialCarbEntry.absorptionTime)]
                }

                let output = LoopAlgorithm.run(input: input)

                self.predictedGlucose = output.predictedGlucose
                self.activeInsulin = output.activeInsulin
                self.activeCarbs = output.activeCarbs
                self.lastAlgorithmEffects = output.effects

                switch output.recommendationResult {
                case .failure(let error):
                    throw error
                case .success(let recommendation):
                    guard var manual = recommendation.manual else {
                        throw WatchLoopError.missingDataError("no manual bolus recommendation")
                    }

                    if let pump = self.pumpManager {
                        manual.amount = pump.roundToSupportedBolusVolume(units: manual.amount)
                    }
                    completion(.success(manual))
                }
        } catch {
            completion(.failure(error))
        }
        return result
    }

    func enactManualBolus(units: Double, activationType: BolusActivationType, completion: @escaping (Error?) -> Void) {
        dataAccessQueue.async {
            guard let pumpManager = self.pumpManager else {
                DispatchQueue.main.async { completion(WatchLoopError.pumpManagerUnconnected) }
                return
            }
            guard let maxBolus = self.settings.maximumBolus else {
                DispatchQueue.main.async { completion(WatchLoopError.configurationError("maximumBolus")) }
                return
            }
            guard units <= maxBolus + .ulpOfOne else {
                DispatchQueue.main.async { completion(WatchLoopError.configurationError("bolus exceeds therapy maximum")) }
                return
            }
            let rounded = pumpManager.roundToSupportedBolusVolume(units: units)

            let deliverBolus = {
                SportLog.event("loan", String(format: "MANUAL BOLUS %.2f U — enacting on the watch pump", rounded))
                pumpManager.enactBolus(decisionId: nil, units: rounded, activationType: activationType) { error in
                    if let error = error {
                        SportLog.event("loan", "MANUAL BOLUS FAILED — \(String(describing: error))")
                    } else {
                        let acceptedAt = self.now()
                        let deliveryEndsAt = acceptedAt.addingTimeInterval(rounded / 1.5 * 60)
                        SportLog.event("loan", String(format: "MANUAL BOLUS delivering %.2f U — estimated done in %.0fs",
                                                      rounded, deliveryEndsAt.timeIntervalSince(acceptedAt)))

                        self.setManualBolusDelivering(units: rounded, from: acceptedAt, to: deliveryEndsAt)

                        self.loop()
                    }
                    self.setManualBolusInFlight(false)
                    DispatchQueue.main.async { completion(error) }
                }
            }
            self.setManualBolusInFlight(true, units: rounded)

            self.dataAccessQueue.async { deliverBolus() }
        }
    }

    func addLoanCarbEntry(_ entry: NewCarbEntry) {
        carbStore.addCarbEntry(entry) { result in
            switch result {
            case .success(let stored):
                SportLog.event("loan", String(format: "carbs logged locally: %.0f g", stored.quantity.doubleValue(for: .gram)))

                self.loop()
            case .failure(let error):
                SportLog.event("loan", "carb store add FAILED — \(String(describing: error))")
            }
        }
    }

    func deleteLoanCarbEntry(_ entry: StoredCarbEntry, completion: @escaping (Bool) -> Void) {
        let grams = entry.quantity.doubleValue(for: .gram)

        SportLog.event("loan", String(format: "carb delete attempt %.0f g @ %@ · uuid=%@ sync=%@ ver=%@ prov=%@ mine=%@",
                                      grams, ISO8601DateFormatter().string(from: entry.startDate),
                                      entry.uuid == nil ? "nil" : "set",
                                      entry.syncIdentifier.map { String($0.prefix(8)) } ?? "nil",
                                      entry.syncVersion.map(String.init) ?? "nil",
                                      String(entry.provenanceIdentifier.prefix(12)),
                                      entry.createdByCurrentApp ? "y" : "n"))

        carbStore.deleteCarbEntrySkippingAuthorshipCheck(entry) { result, lookupDiag in
            switch result {
            case .success:
                SportLog.event("loan", String(format: "carb DELETED locally: %.0f g · lookup: %@", grams, lookupDiag))
                self.loop()

                let start = min(Calendar.current.startOfDay(for: self.now()),
                                Date(timeIntervalSinceNow: -CarbMath.maximumAbsorptionTimeInterval))
                self.carbStore.getCarbEntries(start: start) { readback in
                    if case .success(let remaining) = readback {
                        let total = remaining.reduce(0.0) { $0 + $1.quantity.doubleValue(for: .gram) }
                        SportLog.event("loan", String(format: "post-delete store: %d entr%@ remain, %.0f g total",
                                                      remaining.count, remaining.count == 1 ? "y" : "ies", total))
                    }
                }
                completion(true)
            case .failure(let error):
                SportLog.event("loan", "carb store delete FAILED — \(String(describing: error)) · lookup: \(lookupDiag)")
                completion(false)
            }
        }
    }

    func enactRecommendedAutomaticDose() -> WatchLoopError? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let recommendedDose = self.recommendedAutomaticDose else {
            return nil
        }

        guard abs(recommendedDose.date.timeIntervalSince(now())) < TimeInterval(minutes: 5) else {
            return .recommendationExpired(date: recommendedDose.date)
        }

        guard let pumpManager = pumpManager else {
            return .pumpManagerUnconnected
        }

        if case .suspended = pumpManager.status.basalDeliveryState {
            return .pumpSuspended
        }

        guard !pumpManager.status.deliveryIsUncertain else {
            SportLog.event("dose", "enact refused — the pod's last command is unacknowledged (delivery uncertain); the pump manager resolves it on its next session")
            return .enactFailed("delivery uncertain")
        }
        var enactError: WatchLoopError?

        let recommendation = recommendedDose.recommendation

        let temp = recommendation.basalAdjustment
        SportLog.event("dose", String(format: "enacting temp %.2f U/hr × %.0f min", temp.unitsPerHour, temp.duration / 60))
        if let bolus = recommendation.bolusUnits, bolus > 0 {
            SportLog.event("dose", String(format: "enacting bolus %.2f U", bolus))
        }
        do {
            try runBlocking {
                try await self.doseEnactor.enact(decisionId: nil, bolus: recommendation.bolusUnits,
                                                 tempBasal: recommendation.basalAdjustment, with: pumpManager)
            }
            SportLog.event("dose", String(format: "temp %.2f U/hr ACCEPTED by pod", temp.unitsPerHour))
        } catch {
            SportLog.event("dose", "enact FAILED — \(String(describing: error))")
            enactError = .enactFailed(String(describing: error))
        }

        if enactError == nil {
            self.recommendedAutomaticDose = nil
        }

        return enactError
    }
}
