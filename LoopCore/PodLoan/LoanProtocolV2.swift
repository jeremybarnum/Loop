//
//  LoanProtocolV2.swift
//  LoopCore — one module, linked by both the phone app and the watch app.
//  (The fork compiled this file into four targets; LoopCore replaces that with a single
//  compilation both platforms share, which is the same guarantee by simpler means.)
//
//  Loan protocol v2 wire format. Spec: docs/DESIGN_LOAN_PROTOCOL_V2.md §2 (messages),
//  §1 (epoch / event IDs / provenance).
//
//  Wire shape: one WatchConnectivity userInfo/message dictionary key
//  (LoanProtocol.userInfoKey) carrying JSON of `LoanEnvelope`. The envelope's `kind`
//  discriminator is hand-rolled so an UNKNOWN kind or version throws
//  LoanProtocolError.undecodable — the ProtocolNack path (§2.9); never ack-and-drop.
//

import Foundation
import HealthKit
import LoopKit

public enum LoanProtocol {
    public static let version = 2

    public static let userInfoKey = "podLoanV2"

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let milliseconds = try decoder.singleValueContainer().decode(Int64.self)
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }
        return d
    }
}

public enum LoanProtocolError: Error {
    case undecodable(seenVersion: Int?)
}

public enum EventProvenance: Codable, Equatable {
    case confirmed

    private enum CodingKeys: String, CodingKey { case tag }
    private enum Tag: String, Codable { case confirmed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .tag) {
        case .confirmed: self = .confirmed
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Tag.confirmed, forKey: .tag)
    }
}

public struct LoanDoseRecord: Codable, Equatable {
    public enum Kind: String, Codable {
        case bolus
        case tempBasal

        case suspend
        case carb

        case carbDeleted

        case overrideChange
    }

    public let kind: Kind
    public let startDate: Date
    public let endDate: Date?

    public let unitsPerHour: Double?

    public let amount: Double?

    public let absorptionTime: TimeInterval?

    public let note: String?

    public let syncIdentifier: String?

    public let insulinType: InsulinType?

    public let deliveredUnits: Double?

    public let overrideRaw: Data?

    public init(kind: Kind, startDate: Date, endDate: Date? = nil, unitsPerHour: Double? = nil,
                amount: Double? = nil, absorptionTime: TimeInterval? = nil, note: String? = nil,
                syncIdentifier: String? = nil, insulinType: InsulinType? = nil,
                deliveredUnits: Double? = nil, overrideRaw: Data? = nil) {
        self.kind = kind
        self.startDate = startDate
        self.endDate = endDate
        self.unitsPerHour = unitsPerHour
        self.amount = amount
        self.absorptionTime = absorptionTime
        self.note = note
        self.syncIdentifier = syncIdentifier
        self.insulinType = insulinType
        self.deliveredUnits = deliveredUnits
        self.overrideRaw = overrideRaw
    }
}

extension LoanDoseRecord {
    public static func overrideChange(_ override: TemporaryScheduleOverride?,
                                      at date: Date,
                                      note: String? = nil) -> LoanDoseRecord {
        let raw: Data? = override.flatMap { o in
            try? PropertyListSerialization.data(fromPropertyList: o.rawValue, format: .binary, options: 0)
        }
        return LoanDoseRecord(
            kind: .overrideChange,
            startDate: date,
            endDate: override.flatMap { $0.duration.isInfinite ? nil : $0.scheduledEndDate },
            note: note,
            syncIdentifier: override?.syncIdentifier.uuidString,
            overrideRaw: raw)
    }

    public var overrideChangePayload: TemporaryScheduleOverride? {
        guard kind == .overrideChange, let data = overrideRaw,
              let raw = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? TemporaryScheduleOverride.RawValue
        else { return nil }
        return TemporaryScheduleOverride(rawValue: raw)
    }

    public var overrideChangeIsClear: Bool {
        return kind == .overrideChange && overrideRaw == nil
    }
}

extension LoanDoseRecord {
    public func seedDoseEntry(syncIdentifier: String) -> DoseEntry? {
        switch kind {
        case .bolus:
            guard let units = amount else { return nil }
            return DoseEntry(type: .bolus, startDate: startDate, endDate: endDate ?? startDate,
                             value: units, unit: .units, decisionId: nil, syncIdentifier: syncIdentifier, insulinType: insulinType)
        case .tempBasal:
            guard let rate = unitsPerHour, let end = endDate else { return nil }

            return DoseEntry(type: .tempBasal, startDate: startDate, endDate: end,
                             value: rate, unit: .unitsPerHour, decisionId: nil, deliveredUnits: deliveredUnits,
                             syncIdentifier: syncIdentifier, insulinType: insulinType)
        case .suspend:
            guard let end = endDate else { return nil }
            return DoseEntry(type: .tempBasal, startDate: startDate, endDate: end,
                             value: 0, unit: .unitsPerHour, decisionId: nil, deliveredUnits: deliveredUnits,
                             syncIdentifier: syncIdentifier, insulinType: insulinType)

        case .carb, .carbDeleted, .overrideChange:
            return nil
        }
    }
}

public enum LoanSeedIdentity {
    public static func raw(forSyncIdentifier syncIdentifier: String) -> Data {
        return hexDecoded(syncIdentifier) ?? Data(syncIdentifier.utf8)
    }

    public static func hexDecoded(_ string: String) -> Data? {
        func nibble(_ u: UInt16) -> UInt8? {
            switch u {
            case 0x30...0x39: return UInt8(u - 0x30)
            case 0x41...0x46: return UInt8(u - 0x41 + 10)
            case 0x61...0x66: return UInt8(u - 0x61 + 10)
            default: return nil
            }
        }
        var data = Data(capacity: string.utf16.count / 2)
        var even = true
        var byte: UInt8 = 0
        for c in string.utf16 {
            guard let val = nibble(c) else { return nil }
            if even { byte = val << 4 } else { byte += val; data.append(byte) }
            even.toggle()
        }
        guard even, !data.isEmpty else { return nil }
        return data
    }
}

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

public struct LoanEvent: Codable, Equatable {
    public let id: UUID

    public let seq: Int
    public let provenance: EventProvenance
    public let record: LoanDoseRecord
    public let loggedAt: Date

    public init(id: UUID, seq: Int, provenance: EventProvenance, record: LoanDoseRecord, loggedAt: Date) {
        self.id = id
        self.seq = seq
        self.provenance = provenance
        self.record = record
        self.loggedAt = loggedAt
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

public struct LoanOdometerSnapshot: Codable, Equatable {
    public let deliveredAtStart: Double
    public let deliveredLatest: Double
    public let freshenSucceeded: Bool

    public let asOf: Date?

    public init(deliveredAtStart: Double, deliveredLatest: Double, freshenSucceeded: Bool,
                asOf: Date? = nil) {
        self.deliveredAtStart = deliveredAtStart
        self.deliveredLatest = deliveredLatest
        self.freshenSucceeded = freshenSucceeded
        self.asOf = asOf
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

public struct LoanPredictionSnapshot: Codable, Equatable {
    public let snapshotAt: Date
    public let startGlucoseMgdl: Double

    public let startGlucoseDate: Date

    public let eventualMgdl: Double

    public let eventualIncludingPendingMgdl: Double?
    public let impactMomentumMgdl: Double
    public let impactInsulinMgdl: Double
    public let impactCarbMgdl: Double
    public let impactRCMgdl: Double

    public let iobUnits: Double
    public let iobDate: Date
    public let cobGrams: Double

    public let momentumPointCount: Int

    public let rcDiscrepancyCount: Int

    public let enabledEffectsRaw: Int

    public init(snapshotAt: Date, startGlucoseMgdl: Double, startGlucoseDate: Date,
                eventualMgdl: Double, eventualIncludingPendingMgdl: Double?,
                impactMomentumMgdl: Double, impactInsulinMgdl: Double,
                impactCarbMgdl: Double, impactRCMgdl: Double,
                iobUnits: Double, iobDate: Date, cobGrams: Double,
                momentumPointCount: Int, rcDiscrepancyCount: Int, enabledEffectsRaw: Int) {
        self.snapshotAt = snapshotAt
        self.startGlucoseMgdl = startGlucoseMgdl
        self.startGlucoseDate = startGlucoseDate
        self.eventualMgdl = eventualMgdl
        self.eventualIncludingPendingMgdl = eventualIncludingPendingMgdl
        self.impactMomentumMgdl = impactMomentumMgdl
        self.impactInsulinMgdl = impactInsulinMgdl
        self.impactCarbMgdl = impactCarbMgdl
        self.impactRCMgdl = impactRCMgdl
        self.iobUnits = iobUnits
        self.iobDate = iobDate
        self.cobGrams = cobGrams
        self.momentumPointCount = momentumPointCount
        self.rcDiscrepancyCount = rcDiscrepancyCount
        self.enabledEffectsRaw = enabledEffectsRaw
    }
}

public struct LoanCarbRecord: Codable, Equatable {
    public let syncIdentifier: String?
    public let provenanceIdentifier: String
    public let syncVersion: Int?
    public let startDate: Date
    public let grams: Double
    public let absorptionTime: TimeInterval?
    public let foodType: String?
    public let userCreatedDate: Date?
    public let userUpdatedDate: Date?

    public init(syncIdentifier: String?, provenanceIdentifier: String, syncVersion: Int?,
                startDate: Date, grams: Double, absorptionTime: TimeInterval?, foodType: String?,
                userCreatedDate: Date?, userUpdatedDate: Date?) {
        self.syncIdentifier = syncIdentifier
        self.provenanceIdentifier = provenanceIdentifier
        self.syncVersion = syncVersion
        self.startDate = startDate
        self.grams = grams
        self.absorptionTime = absorptionTime
        self.foodType = foodType
        self.userCreatedDate = userCreatedDate
        self.userUpdatedDate = userUpdatedDate
    }
}

public struct LoanGlucoseRecord: Codable, Equatable {
    public let syncIdentifier: String?
    public let startDate: Date

    public let valueMgdl: Double

    public let trendRateMgdlPerMin: Double?
    public let isDisplayOnly: Bool
    public let wasUserEntered: Bool

    public init(syncIdentifier: String?, startDate: Date, valueMgdl: Double,
                trendRateMgdlPerMin: Double?, isDisplayOnly: Bool, wasUserEntered: Bool) {
        self.syncIdentifier = syncIdentifier
        self.startDate = startDate
        self.valueMgdl = valueMgdl
        self.trendRateMgdlPerMin = trendRateMgdlPerMin
        self.isDisplayOnly = isDisplayOnly
        self.wasUserEntered = wasUserEntered
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

public enum LoanMessage: Equatable {
    case request(LoanRequest)
    case grant(LoanGrant)
    case takeoverComplete(TakeoverComplete)
    case takeoverFailed(TakeoverFailed)
    case doseRecordBatch(DoseRecordBatch)
    case handbackOffer(HandbackOffer)
    case handbackAck(HandbackAck)
    case revoke(Revoke)
    case statusQuery(StatusQuery)
    case statusReport(StatusReport)
    case nack(ProtocolNack)
    case denied(LoanDenied)
    case diag(LoanDiag)

    case dormantGrant(DormantGrant)
}

public struct LoanEnvelope: Codable {
    public let protocolVersion: Int
    public let message: LoanMessage

    public init(message: LoanMessage) {
        self.protocolVersion = LoanProtocol.version
        self.message = message
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, kind, body }

    private enum Kind: String, Codable {
        case request, grant, takeoverComplete, takeoverFailed, doseRecordBatch
        case handbackOffer, handbackAck, revoke, statusQuery, statusReport, nack, denied
        case diag, dormantGrant
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .protocolVersion)
        self.protocolVersion = version
        guard version == LoanProtocol.version else {
            throw LoanProtocolError.undecodable(seenVersion: version)
        }
        guard let kindString = try? c.decode(String.self, forKey: .kind),
              let kind = Kind(rawValue: kindString) else {
            throw LoanProtocolError.undecodable(seenVersion: version)
        }
        switch kind {
        case .request: self.message = .request(try c.decode(LoanRequest.self, forKey: .body))
        case .grant: self.message = .grant(try c.decode(LoanGrant.self, forKey: .body))
        case .takeoverComplete: self.message = .takeoverComplete(try c.decode(TakeoverComplete.self, forKey: .body))
        case .takeoverFailed: self.message = .takeoverFailed(try c.decode(TakeoverFailed.self, forKey: .body))
        case .doseRecordBatch: self.message = .doseRecordBatch(try c.decode(DoseRecordBatch.self, forKey: .body))
        case .handbackOffer: self.message = .handbackOffer(try c.decode(HandbackOffer.self, forKey: .body))
        case .handbackAck: self.message = .handbackAck(try c.decode(HandbackAck.self, forKey: .body))
        case .revoke: self.message = .revoke(try c.decode(Revoke.self, forKey: .body))
        case .statusQuery: self.message = .statusQuery(try c.decode(StatusQuery.self, forKey: .body))
        case .statusReport: self.message = .statusReport(try c.decode(StatusReport.self, forKey: .body))
        case .nack: self.message = .nack(try c.decode(ProtocolNack.self, forKey: .body))
        case .denied: self.message = .denied(try c.decode(LoanDenied.self, forKey: .body))
        case .diag: self.message = .diag(try c.decode(LoanDiag.self, forKey: .body))
        case .dormantGrant: self.message = .dormantGrant(try c.decode(DormantGrant.self, forKey: .body))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(protocolVersion, forKey: .protocolVersion)
        switch message {
        case .request(let m): try c.encode(Kind.request, forKey: .kind); try c.encode(m, forKey: .body)
        case .grant(let m): try c.encode(Kind.grant, forKey: .kind); try c.encode(m, forKey: .body)
        case .takeoverComplete(let m): try c.encode(Kind.takeoverComplete, forKey: .kind); try c.encode(m, forKey: .body)
        case .takeoverFailed(let m): try c.encode(Kind.takeoverFailed, forKey: .kind); try c.encode(m, forKey: .body)
        case .doseRecordBatch(let m): try c.encode(Kind.doseRecordBatch, forKey: .kind); try c.encode(m, forKey: .body)
        case .handbackOffer(let m): try c.encode(Kind.handbackOffer, forKey: .kind); try c.encode(m, forKey: .body)
        case .handbackAck(let m): try c.encode(Kind.handbackAck, forKey: .kind); try c.encode(m, forKey: .body)
        case .revoke(let m): try c.encode(Kind.revoke, forKey: .kind); try c.encode(m, forKey: .body)
        case .statusQuery(let m): try c.encode(Kind.statusQuery, forKey: .kind); try c.encode(m, forKey: .body)
        case .statusReport(let m): try c.encode(Kind.statusReport, forKey: .kind); try c.encode(m, forKey: .body)
        case .nack(let m): try c.encode(Kind.nack, forKey: .kind); try c.encode(m, forKey: .body)
        case .denied(let m): try c.encode(Kind.denied, forKey: .kind); try c.encode(m, forKey: .body)
        case .diag(let m): try c.encode(Kind.diag, forKey: .kind); try c.encode(m, forKey: .body)
        case .dormantGrant(let m): try c.encode(Kind.dormantGrant, forKey: .kind); try c.encode(m, forKey: .body)
        }
    }
}

extension LoanMessage {
    public func transportDictionary() throws -> [String: Any] {
        let data = try LoanProtocol.encoder.encode(LoanEnvelope(message: self))
        return [LoanProtocol.userInfoKey: data]
    }

    public var kindLabel: String {
        switch self {
        case .request:          return "request"
        case .grant:            return "grant"
        case .takeoverComplete: return "takeoverComplete"
        case .takeoverFailed:   return "takeoverFailed"
        case .doseRecordBatch:  return "doseRecordBatch"
        case .handbackOffer:    return "handbackOffer"
        case .handbackAck:      return "handbackAck"
        case .revoke:           return "revoke"
        case .statusQuery:      return "statusQuery"
        case .statusReport:     return "statusReport"
        case .nack:             return "nack"
        case .denied:           return "denied"
        case .diag:             return "diag"
        case .dormantGrant:     return "dormantGrant"
        }
    }

    public var isInteractiveHandshake: Bool {
        switch self {
        case .request, .grant, .denied, .nack, .revoke, .handbackOffer, .handbackAck,
             .takeoverComplete:
            return true
        case .takeoverFailed, .doseRecordBatch, .statusQuery,
             .statusReport, .diag,

             .dormantGrant:
            return false
        }
    }

    public static func peekKind(transport userInfo: [String: Any]) -> String? {
        guard let data = userInfo[LoanProtocol.userInfoKey] as? Data else { return nil }
        struct Peek: Decodable { let kind: String }
        return (try? JSONDecoder().decode(Peek.self, from: data))?.kind
    }

    public static func isInteractiveHandshake(transport userInfo: [String: Any]) -> Bool {
        if let data = userInfo[LoanProtocol.userInfoKey] as? Data, data.count > 60_000 {
            return false
        }

        guard let message = try? decode(fromTransport: userInfo) else { return false }
        return message.isInteractiveHandshake
    }

    public static func decode(fromTransport userInfo: [String: Any]) throws -> LoanMessage? {
        guard let data = userInfo[LoanProtocol.userInfoKey] as? Data else { return nil }
        do {
            return try LoanProtocol.decoder.decode(LoanEnvelope.self, from: data).message
        } catch let error as LoanProtocolError {
            throw error
        } catch {
            throw LoanProtocolError.undecodable(seenVersion: nil)
        }
    }
}
