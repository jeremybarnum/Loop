//
//  LoanMessages.swift
//  Loop
//

import Foundation
import HealthKit
import LoopKit

extension LoanGrant {
    public func seedDoseEntries() -> [DoseEntry] {
        return doseHistory.enumerated().compactMap { index, record in

            let syncId = record.syncIdentifier ?? "loanv2-grant-\(epoch)-\(index)"
            return record.seedDoseEntry(syncIdentifier: syncId)
        }
    }

    public func seedDoseEntries(finishedBy instant: Date) -> (seed: [DoseEntry], live: [DoseEntry]) {
        let all = seedDoseEntries()
        return (all.filter { $0.endDate <= instant }, all.filter { $0.endDate > instant })
    }
}

public struct LoanPodStatus: Codable, Equatable {
    public let timestamp: Date
    public let deliveredUnits: Double?
    public let reservoirLevel: Double?
    public let isSuspended: Bool
    public let faultCode: String?

    public init(timestamp: Date, deliveredUnits: Double?, reservoirLevel: Double?,
                isSuspended: Bool, faultCode: String?) {
        self.timestamp = timestamp
        self.deliveredUnits = deliveredUnits
        self.reservoirLevel = reservoirLevel
        self.isSuspended = isSuspended
        self.faultCode = faultCode
    }
}

public enum LoanDosingMode: String, Codable {
    case closedDirect
    case closedPhoneFed
    case cgmViewer
    case pausedStale
    case suspended
}

public struct LoanRequest: Codable, Equatable {
    public let watchBuild: String
    public let supportedVersions: [Int]

    public let requestID: String?

    public let supportsSeize: Bool?

    public let sentAt: Date?

    public init(watchBuild: String,
                supportedVersions: [Int] = [LoanProtocol.version],
                requestID: String = UUID().uuidString,
                supportsSeize: Bool? = nil,
                sentAt: Date? = nil) {
        self.watchBuild = watchBuild
        self.supportedVersions = supportedVersions
        self.requestID = requestID
        self.supportsSeize = supportsSeize
        self.sentAt = sentAt
    }
}

public struct DormantGrant: Codable, Equatable {
    public let grant: LoanGrant
    public let issuedAt: Date
    public let seizeToken: UUID

    public init(grant: LoanGrant, issuedAt: Date, seizeToken: UUID) {
        self.grant = grant
        self.issuedAt = issuedAt
        self.seizeToken = seizeToken
    }
}

public struct LoanGrant: Codable, Equatable {
    public let epoch: Int

    public let expiresAt: Date

    public let pumpManagerRawState: Data

    public let podAddress: UInt32

    public let therapySettingsRaw: Data
    public let settingsTimeZoneID: String

    public let doseHistory: [LoanDoseRecord]

    public let supportsInterimHandback: Bool?

    public let supportsOverrideRecords: Bool?

    public let integralRetrospectiveCorrectionEnabled: Bool?

    public let phoneClosedLoopEnabled: Bool?

    public let carbHistory: [LoanCarbRecord]?

    public let lastLoopCompleted: Date?

    public let glucoseHistory: [LoanGlucoseRecord]?

    public let predictionSnapshot: LoanPredictionSnapshot?

    public let activeOverrideRaw: Data?

    public let therapySettingsSupplementRaw: Data?

    public init(epoch: Int, expiresAt: Date, pumpManagerRawState: Data, podAddress: UInt32,
                therapySettingsRaw: Data, settingsTimeZoneID: String,
                doseHistory: [LoanDoseRecord],
                supportsInterimHandback: Bool? = nil,
                supportsOverrideRecords: Bool? = nil,
                integralRetrospectiveCorrectionEnabled: Bool? = nil,
                phoneClosedLoopEnabled: Bool? = nil,
                carbHistory: [LoanCarbRecord]? = nil,
                glucoseHistory: [LoanGlucoseRecord]? = nil,
                predictionSnapshot: LoanPredictionSnapshot? = nil,
                activeOverrideRaw: Data? = nil,
                therapySettingsSupplementRaw: Data? = nil,
                lastLoopCompleted: Date? = nil) {
        self.epoch = epoch
        self.expiresAt = expiresAt
        self.pumpManagerRawState = pumpManagerRawState
        self.podAddress = podAddress
        self.therapySettingsRaw = therapySettingsRaw
        self.settingsTimeZoneID = settingsTimeZoneID
        self.doseHistory = doseHistory
        self.supportsInterimHandback = supportsInterimHandback
        self.supportsOverrideRecords = supportsOverrideRecords
        self.integralRetrospectiveCorrectionEnabled = integralRetrospectiveCorrectionEnabled
        self.phoneClosedLoopEnabled = phoneClosedLoopEnabled
        self.carbHistory = carbHistory
        self.glucoseHistory = glucoseHistory
        self.predictionSnapshot = predictionSnapshot
        self.activeOverrideRaw = activeOverrideRaw
        self.therapySettingsSupplementRaw = therapySettingsSupplementRaw
        self.lastLoopCompleted = lastLoopCompleted
    }
}

public struct TakeoverComplete: Codable, Equatable {
    public let epoch: Int
    public let firstPodStatus: LoanPodStatus

    public init(epoch: Int, firstPodStatus: LoanPodStatus) {
        self.epoch = epoch
        self.firstPodStatus = firstPodStatus
    }
}

public struct TakeoverFailed: Codable, Equatable {
    public let epoch: Int
    public let reason: String

    public init(epoch: Int, reason: String) {
        self.epoch = epoch
        self.reason = reason
    }
}

public struct DoseRecordBatch: Codable, Equatable {
    public let epoch: Int
    public let events: [LoanEvent]
    public let tombstones: [UUID]

    public let odometer: LoanOdometerSnapshot?

    public let sentAt: Date?

    public init(epoch: Int, events: [LoanEvent], tombstones: [UUID],
                odometer: LoanOdometerSnapshot? = nil, sentAt: Date? = nil) {
        self.epoch = epoch
        self.events = events
        self.tombstones = tombstones
        self.odometer = odometer
        self.sentAt = sentAt
    }
}

public struct HandbackOffer: Codable, Equatable {
    public let epoch: Int
    public let handedBackAt: Date
    public let finalStatus: LoanPodStatus?
    public let odometer: LoanOdometerSnapshot?
    public let events: [LoanEvent]
    public let tombstones: [UUID]
    public let recovered: Bool

    public let released: Bool?

    public let watchClosedLoopEnabled: Bool?

    public let seizeToken: UUID?

    public let lastLoopCompleted: Date?

    public init(epoch: Int, handedBackAt: Date, finalStatus: LoanPodStatus?,
                odometer: LoanOdometerSnapshot?, events: [LoanEvent], tombstones: [UUID],
                recovered: Bool, released: Bool? = nil, watchClosedLoopEnabled: Bool? = nil,
                seizeToken: UUID? = nil,
                lastLoopCompleted: Date? = nil) {
        self.epoch = epoch
        self.handedBackAt = handedBackAt
        self.finalStatus = finalStatus
        self.odometer = odometer
        self.events = events
        self.tombstones = tombstones
        self.recovered = recovered
        self.released = released
        self.watchClosedLoopEnabled = watchClosedLoopEnabled
        self.seizeToken = seizeToken
        self.lastLoopCompleted = lastLoopCompleted
    }
}

public struct HandbackAck: Codable, Equatable {
    public let epoch: Int
    public let committedCursor: Int
    public let stale: Bool

    public init(epoch: Int, committedCursor: Int, stale: Bool = false) {
        self.epoch = epoch
        self.committedCursor = committedCursor
        self.stale = stale
    }
}

public struct Revoke: Codable, Equatable {
    public let epoch: Int

    public init(epoch: Int) {
        self.epoch = epoch
    }
}

public struct StatusQuery: Codable, Equatable {
    public let epoch: Int

    public init(epoch: Int) {
        self.epoch = epoch
    }
}

public struct StatusReport: Codable, Equatable {
    public let epoch: Int
    public let mode: LoanDosingMode

    public let lastDirectGlucoseAge: TimeInterval?
    public let lastEventSeq: Int
    public let podFault: String?
    public let holdsPod: Bool

    public let knowsGrant: Bool?

    public init(epoch: Int, mode: LoanDosingMode, lastDirectGlucoseAge: TimeInterval?,
                lastEventSeq: Int, podFault: String?, holdsPod: Bool, knowsGrant: Bool? = nil) {
        self.epoch = epoch
        self.mode = mode
        self.lastDirectGlucoseAge = lastDirectGlucoseAge
        self.lastEventSeq = lastEventSeq
        self.podFault = podFault
        self.holdsPod = holdsPod
        self.knowsGrant = knowsGrant
    }
}

public struct ProtocolNack: Codable, Equatable {
    public let seenVersion: Int?
    public let supportedVersions: [Int]

    public init(seenVersion: Int?, supportedVersions: [Int] = [LoanProtocol.version]) {
        self.seenVersion = seenVersion
        self.supportedVersions = supportedVersions
    }
}

public struct LoanDenied: Codable, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

public struct LoanDiag: Codable, Equatable {
    public let epoch: Int
    public let text: String
    public init(epoch: Int, text: String) {
        self.epoch = epoch
        self.text = text
    }
}
