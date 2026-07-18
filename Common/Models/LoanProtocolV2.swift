//
//  LoanProtocolV2.swift
//  Loop / WatchApp Extension (compiled into BOTH targets — one source file, no
//  hand-maintained mirror decoder; the v1 mirror in WatchDataManager is a review finding)
//
//  Loan protocol v2 wire format. Spec: docs/DESIGN_LOAN_PROTOCOL_V2.md §2 (messages),
//  §1 (epoch / event IDs / provenance). Rulings: docs/RULINGS.md — R6 (layers),
//  R8 (alarm inventory), R11 (ringfence), R22 (fingerprints-only allocation).
//
//  Wire shape: one WatchConnectivity userInfo/message dictionary key
//  (LoanProtocol.userInfoKey) carrying JSON of `LoanEnvelope`. The envelope's `kind`
//  discriminator is hand-rolled so an UNKNOWN kind or version throws
//  LoanProtocolError.undecodable — the ProtocolNack path (§2.9); never ack-and-drop.
//

import Foundation

// MARK: - Protocol constants

public enum LoanProtocol {
    /// Version pinned by the grant for the whole session (§7).
    public static let version = 2

    /// The single WC dictionary key the entire v2 protocol rides under.
    public static let userInfoKey = "podLoanV2"

    /// Stable JSON coding: dates as INTEGER milliseconds since 1970 — deterministic,
    /// byte-stable round-trips (fractional-seconds Doubles drift at sub-millisecond
    /// precision through JSON, which the round-trip test caught). Timezone-free —
    /// wall-time semantics travel separately (LoanGrant.settingsTimeZoneID, spec §8).
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

/// Decode failures that must surface as ProtocolNack + loud alert (§2.9, finding :825).
public enum LoanProtocolError: Error {
    case undecodable(seenVersion: Int?)
    case unknownKind(String)
}

// MARK: - Support types

/// Provenance rides every event (§1.3, R6 layer 2 — the wire-format change that forces v2).
/// Only `.assumed` events are ever negative-remainder allocation candidates (R22).
public enum EventProvenance: Codable, Equatable {
    case confirmed
    case assumed(UncertainKind)

    public enum UncertainKind: String, Codable {
        case bolusUncertain
        case tempUncertain
        case resumeUncertain
        /// A real reduction the max-exposure rule declined to record (the C′ case);
        /// EXPLAINS remainder at hand-back rather than being reduced (R22).
        case skippedReduction
    }

    private enum CodingKeys: String, CodingKey { case tag, kind }
    private enum Tag: String, Codable { case confirmed, assumed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .tag) {
        case .confirmed: self = .confirmed
        case .assumed: self = .assumed(try c.decode(UncertainKind.self, forKey: .kind))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .confirmed:
            try c.encode(Tag.confirmed, forKey: .tag)
        case .assumed(let kind):
            try c.encode(Tag.assumed, forKey: .tag)
            try c.encode(kind, forKey: .kind)
        }
    }
}

/// One journal-worthy occurrence, generic across dose/carb/bookkeeping kinds (§2.4-2.5).
/// Deliberately OUR struct, not a LoopKit type: the wire format versions independently
/// of LoopKit's Codable evolution; conversion happens at the store boundary.
public struct LoanDoseRecord: Codable, Equatable {
    public enum Kind: String, Codable {
        case bolus
        case tempBasal
        /// R3: suspend IS a bounded rate-0 temp; kept as its own kind so suspend
        /// windows stay first-class through hand-back/reclaim (spec §3, 46f16d01).
        case suspend
        case resume
        case carb
        /// A temp-change that died after its committed safe-cancel (C1/C2/C10 port).
        case plumbingCancel
        /// The phone's record-close of its running temp at the handover stamp (R2/C5).
        case boundaryTruncation
        /// The picker changed the dosing mode (R18/R20) — mode transitions are events.
        case modeChange
    }

    public let kind: Kind
    public let startDate: Date
    public let endDate: Date?
    /// U/hr for tempBasal/suspend (0 for suspend by construction).
    public let unitsPerHour: Double?
    /// U for bolus; grams for carb.
    public let amount: Double?
    /// Carb absorption seconds; nil elsewhere.
    public let absorptionTime: TimeInterval?
    /// Free-form: mode names for .modeChange, cancellation context, etc.
    public let note: String?

    public init(kind: Kind, startDate: Date, endDate: Date? = nil, unitsPerHour: Double? = nil,
                amount: Double? = nil, absorptionTime: TimeInterval? = nil, note: String? = nil) {
        self.kind = kind
        self.startDate = startDate
        self.endDate = endDate
        self.unitsPerHour = unitsPerHour
        self.amount = amount
        self.absorptionTime = absorptionTime
        self.note = note
    }
}

/// Event = record + identity + provenance. IDs are minted at INTENT time, before
/// transmission to the pod (§1.2); retries reuse them, dedup is by ID, acks are
/// cursor-style over `seq` (af742c7a / C7 carried to both sides).
public struct LoanEvent: Codable, Equatable {
    public let id: UUID
    /// Monotonic per-loan sequence; the ack cursor is "highest contiguous committed seq".
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

/// Pod status distilled for the wire (full PodState never travels except in the grant blob).
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

/// The odometer audit pair (§1.4, R12): freshen-before-snapshot with the OQ-5 retry;
/// `freshenSucceeded` false means the audit is advisory-only this session.
public struct LoanOdometerSnapshot: Codable, Equatable {
    public let deliveredAtStart: Double
    public let deliveredLatest: Double
    public let freshenSucceeded: Bool

    public init(deliveredAtStart: Double, deliveredLatest: Double, freshenSucceeded: Bool) {
        self.deliveredAtStart = deliveredAtStart
        self.deliveredLatest = deliveredLatest
        self.freshenSucceeded = freshenSucceeded
    }
}

/// StatusReport dosing mode (R18/R20): the phone tile shows which world the watch is in.
public enum LoanDosingMode: String, Codable {
    case closedDirect      // default: dosing from the watch's own direct-G7 stream
    case closedPhoneFed    // the picker's explicitly chosen, labeled degraded mode
    case cgmViewer         // first-class: glucose display, loop open, pod with phone
    case pausedStale       // R9 lenient pause: stale anchor, no NEW temps
    case suspended         // bounded rate-0 suspend running (R3)
}

// MARK: - Messages (§2)

/// 1. watch→phone. The only message without an epoch.
public struct LoanRequest: Codable, Equatable {
    public let watchBuild: String
    public let supportedVersions: [Int]

    public init(watchBuild: String, supportedVersions: [Int] = [LoanProtocol.version]) {
        self.watchBuild = watchBuild
        self.supportedVersions = supportedVersions
    }
}

/// 2. phone→watch. Identity/keys live INSIDE `pumpManagerRawState` (the stock
/// OmniPumpManagerState raw snapshot, plist-encoded): the watch resumes via
/// `OmniPumpManager(rawState:)` exactly as the phone does on relaunch — including
/// `unfinalizedDoses` and any `unacknowledgedCommand`. Completeness is enforced
/// phone-side before send (deny-on-missing, never defaulted) and watch-side by init
/// failure → TakeoverFailed. R2: the phone does NOT cancel its running temp; its
/// RECORD closes at the handover stamp (`boundaryRecord`, kind .boundaryTruncation).
public struct LoanGrant: Codable, Equatable {
    public let epoch: Int
    /// A late-arriving grant self-rejects on the watch (§2.4 row 2).
    public let expiresAt: Date
    /// plist-encoded PumpManager.RawStateValue (opaque stock blob).
    public let pumpManagerRawState: Data
    /// Display/log sanity only — never a substitute for blob completeness.
    public let podAddress: UInt32
    /// plist-encoded LoopSettings rawValue: the ONLY dosing limits (R1/R16);
    /// frozen for the loan in `settingsTimeZoneID` (spec §8, mid-loan freeze APPROVED).
    public let therapySettingsRaw: Data
    public let settingsTimeZoneID: String
    /// 16 h context for the watch's stores (v1 `dh`, kept).
    public let doseHistory: [LoanDoseRecord]
    public let boundaryRecord: LoanDoseRecord?

    public init(epoch: Int, expiresAt: Date, pumpManagerRawState: Data, podAddress: UInt32,
                therapySettingsRaw: Data, settingsTimeZoneID: String,
                doseHistory: [LoanDoseRecord], boundaryRecord: LoanDoseRecord?) {
        self.epoch = epoch
        self.expiresAt = expiresAt
        self.pumpManagerRawState = pumpManagerRawState
        self.podAddress = podAddress
        self.therapySettingsRaw = therapySettingsRaw
        self.settingsTimeZoneID = settingsTimeZoneID
        self.doseHistory = doseHistory
        self.boundaryRecord = boundaryRecord
    }
}

/// 3a. watch→phone: only now does the phone commit LOANED (cancels T1 — R8's
/// "holdsPod push").
public struct TakeoverComplete: Codable, Equatable {
    public let epoch: Int
    public let firstPodStatus: LoanPodStatus

    public init(epoch: Int, firstPodStatus: LoanPodStatus) {
        self.epoch = epoch
        self.firstPodStatus = firstPodStatus
    }
}

/// 3b. watch→phone: the watch tears down PodComms completely on failure (finding :1009).
public struct TakeoverFailed: Codable, Equatable {
    public let epoch: Int
    public let reason: String

    public init(epoch: Int, reason: String) {
        self.epoch = epoch
        self.reason = reason
    }
}

/// 4. watch→phone, during loan, best-effort streaming: the phone accumulates the
/// record even if the watch later dies (the trap cell). `tombstones` unwind layer-1
/// annulments of already-streamed events (§1.3).
public struct DoseRecordBatch: Codable, Equatable {
    public let epoch: Int
    public let events: [LoanEvent]
    public let tombstones: [UUID]

    public init(epoch: Int, events: [LoanEvent], tombstones: [UUID]) {
        self.epoch = epoch
        self.events = events
        self.tombstones = tombstones
    }
}

/// 5. watch→phone: same event IDs on every retry (ID-stability subsumes v1's
/// snapshot-for-byte-stability rule). `recovered` marks the relaunch-drain path
/// (data-first; never resurrect a session).
public struct HandbackOffer: Codable, Equatable {
    public let epoch: Int
    public let handedBackAt: Date
    public let finalStatus: LoanPodStatus?
    public let odometer: LoanOdometerSnapshot?
    public let events: [LoanEvent]
    public let tombstones: [UUID]
    public let recovered: Bool

    public init(epoch: Int, handedBackAt: Date, finalStatus: LoanPodStatus?,
                odometer: LoanOdometerSnapshot?, events: [LoanEvent], tombstones: [UUID],
                recovered: Bool) {
        self.epoch = epoch
        self.handedBackAt = handedBackAt
        self.finalStatus = finalStatus
        self.odometer = odometer
        self.events = events
        self.tombstones = tombstones
        self.recovered = recovered
    }
}

/// 6. phone→watch: sent ONLY after the phone's DoseStore write commits (a897d22c).
/// Empty hand-backs ack cursor 0 (finding :948). `stale` = epoch was old; the sender
/// stops retrying but nothing was (or will be) acted on — dead loans cannot speak.
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

/// 7. phone→watch: idempotent; parked-until-activation delivery kept from v1.
public struct Revoke: Codable, Equatable {
    public let epoch: Int

    public init(epoch: Int) {
        self.epoch = epoch
    }
}

/// 8a. phone→watch poll (3b-v2 mechanism, extended).
public struct StatusQuery: Codable, Equatable {
    public let epoch: Int

    public init(epoch: Int) {
        self.epoch = epoch
    }
}

/// 8b. watch→phone: sovereignty + mode (R18/R20), last event seq (reconcile progress),
/// pod fault surfacing (§6). NO heartbeat semantics attach to this message (R8) —
/// its absence alarms nothing.
public struct StatusReport: Codable, Equatable {
    public let epoch: Int
    public let mode: LoanDosingMode
    /// Age of the last DIRECT G7 read (§6a sovereignty signal — store freshness is not it).
    public let lastDirectGlucoseAge: TimeInterval?
    public let lastEventSeq: Int
    public let podFault: String?
    public let holdsPod: Bool

    public init(epoch: Int, mode: LoanDosingMode, lastDirectGlucoseAge: TimeInterval?,
                lastEventSeq: Int, podFault: String?, holdsPod: Bool) {
        self.epoch = epoch
        self.mode = mode
        self.lastDirectGlucoseAge = lastDirectGlucoseAge
        self.lastEventSeq = lastEventSeq
        self.podFault = podFault
        self.holdsPod = holdsPod
    }
}

/// 9. either direction: the never-silently-discard path (§7, finding :825).
public struct ProtocolNack: Codable, Equatable {
    public let seenVersion: Int?
    public let supportedVersions: [Int]

    public init(seenVersion: Int?, supportedVersions: [Int] = [LoanProtocol.version]) {
        self.seenVersion = seenVersion
        self.supportedVersions = supportedVersions
    }
}

/// Phone→watch: the phone refused or could not fulfil a loan request, with a
/// human-readable reason. No epoch (denial precedes the loan). Lets the watch show
/// WHY on the glance screen instead of hanging silently on "requesting…".
public struct LoanDenied: Codable, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

// MARK: - Envelope

/// The polymorphic carrier. Hand-rolled `kind` discriminator: unknown kinds throw
/// (→ ProtocolNack), and the encoding is stable against enum reordering.
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

    /// The message's epoch, nil only for request/nack/denied (§1.1).
    public var epoch: Int? {
        switch self {
        case .request, .nack, .denied: return nil
        case .grant(let m): return m.epoch
        case .takeoverComplete(let m): return m.epoch
        case .takeoverFailed(let m): return m.epoch
        case .doseRecordBatch(let m): return m.epoch
        case .handbackOffer(let m): return m.epoch
        case .handbackAck(let m): return m.epoch
        case .revoke(let m): return m.epoch
        case .statusQuery(let m): return m.epoch
        case .statusReport(let m): return m.epoch
        }
    }
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
        }
    }
}

// MARK: - Transport helpers

extension LoanMessage {
    /// The WC userInfo/message dictionary for this message.
    public func transportDictionary() throws -> [String: Any] {
        let data = try LoanProtocol.encoder.encode(LoanEnvelope(message: self))
        return [LoanProtocol.userInfoKey: data]
    }

    /// nil = not a v2 payload (not ours to handle — lets v1/other WC traffic pass).
    /// throws = it IS a v2 payload that cannot be decoded → ProtocolNack path (§2.9).
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
