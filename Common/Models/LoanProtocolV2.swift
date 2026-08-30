//
//  LoanProtocolV2.swift
//  Loop / WatchApp Extension (compiled into BOTH targets — one source file, no
//  hand-maintained mirror decoder; the v1 mirror in WatchDataManager is a review finding)
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

/// Provenance rides every event (§1.3 — the wire-format change that forces v2).
/// Only `.assumed` events are ever negative-remainder allocation candidates.
public enum EventProvenance: Codable, Equatable {
    case confirmed
    case assumed(UncertainKind)

    public enum UncertainKind: String, Codable {
        case bolusUncertain
        case tempUncertain
        case resumeUncertain
        /// A real reduction the max-exposure rule declined to record (the C′ case);
        /// EXPLAINS remainder at hand-back rather than being reduced.
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
        /// Suspend IS a bounded rate-0 temp; kept as its own kind so suspend
        /// windows stay first-class through hand-back/reclaim (spec §3, 46f16d01).
        case suspend
        case resume
        case carb
        /// The wrist DELETED a carb entry during the loan. `syncIdentifier` names the
        /// victim; every other payload field is nil. Not a dose — it carries no insulin and
        /// contributes nothing to the odometer audit — but it is journal-worthy for the same
        /// reason `.overrideChange` is: while the watch holds the pod it owns the carb store, and
        /// the drain replays that ownership onto the phone.
        ///
        /// It MUST ride the journal rather than being applied locally. `ingestGrantCarbs` makes
        /// the watch an authoritative MIRROR of the phone at every takeover, so a delete the phone
        /// never heard about is RESURRECTED at the next grant — the user deletes it, watches it
        /// vanish, and it comes back still driving dosing.
        case carbDeleted
        /// A temp-change that died after its committed safe-cancel (C1/C2/C10 port).
        case plumbingCancel
        /// The phone's record-close of its running temp at the handover stamp.
        case boundaryTruncation
        /// The picker changed the dosing mode — mode transitions are events.
        case modeChange
        /// The WRIST enacted (or cleared) a temporary schedule override during
        /// the loan. Not a dose — it carries no insulin and contributes nothing to the
        /// odometer audit — but it IS journal-worthy: while the watch holds the pod it owns
        /// overrides, so the override has to follow the pod
        /// home. Riding the journal (rather than a bespoke WC message) is what makes a
        /// phone-ABSENT override survive: it inherits seq ordering, the commit cursor,
        /// resend-until-ack, and the hand-back drain for free. Payload lives in
        /// `overrideRaw` (nil = the user CLEARED the override).
        ///
        /// DEPLOYMENT SKEW (flagged, deliberately NOT gated — Jeremy's call to make):
        /// `Kind` is a plain String enum, so a phone build that predates this case THROWS on
        /// decode and the whole offer becomes undecodable. That is the §2.9 path, not a silent
        /// drop: the phone nacks + shows "The watch sent a message this phone build cannot
        /// read… Nothing was discarded", the watch shows its twin alert, and every record stays
        /// in the journal — updating the phone drains it intact. So a new-watch/old-phone pair
        /// STRANDS the loan (loudly, recoverably via the escape-hatch reclaim) rather than
        /// losing data. This is the first kind minted since the protocol froze at v2, so the
        /// hazard is real rather than theoretical; the alternative is a
        /// capability flag in the grant, which would instead degrade SILENTLY (the override
        /// would work on the wrist but never follow the pod home). Loud-and-recoverable was
        /// chosen over silent-and-lossy. Revisit if watch/phone builds routinely diverge.
        case overrideChange
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
    /// Stable syncId: the phone's OWN dose syncIdentifier. Carried so the watch seeds with a
    /// STABLE identity — a re-seed across epochs then upsert-dedups (same identity → one row)
    /// instead of accumulating under fresh epoch-keyed ids, the class of bug behind the takeover
    /// IOB inflation. nil (older phone) → the watch falls back to its epoch-keyed id.
    public let syncIdentifier: String?
    /// Insulin-model fidelity: the dose's insulin type, so the watch decays it on the SAME
    /// model the phone used. Novolog resolves to rapid-acting-adult on both, but fiasp/lyumjev
    /// differ — without this the watch silently decays them on the adult curve. nil → typeless.
    public let insulinType: InsulinType?
    /// Pulse fidelity: the pod's ACTUAL delivered units for this dose. Omnipod delivers only
    /// whole 0.05 U pulses, so OmniBLE FLOORS a superseded temp's units to the pulse boundary and
    /// LoopKit reads that via `deliveredUnits`. Without it on the wire the watch re-derives with
    /// `round(programmedUnits)` (DoseEntry.swift:147-153 — the Medtronic-era fallback), netting
    /// +0.025 U per elapsed temp slice against the phone: the wire gap (phone 0.70 vs
    /// watch 1.00 over 33 slices; the `net=-0.008` decomp rows are its fingerprint). The BOLUS arm
    /// already carried actual units; this closes the temp arm. nil (older phone) → round fallback.
    public let deliveredUnits: Double?
    /// (.overrideChange only): the plist-encoded `TemporaryScheduleOverride.rawValue`
    /// the wrist enacted. nil ON AN `.overrideChange` RECORD MEANS CLEARED — the user turned the
    /// preset off — which is why this is a payload field and not a flag: "cleared" and "no
    /// override record at all" must stay distinguishable on the phone. Plist rather than the
    /// LoopKit Codable conformance, for the same reason the grant carries `therapySettingsRaw`
    /// that way: the wire format versions independently of LoopKit's Codable evolution, and
    /// `rawValue` is the encoding LoopSettings itself already persists overrides through.
    /// nil on every other kind (and on records from an older watch, which never mint this kind).
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

// MARK: - Override records

extension LoanDoseRecord {

    /// Mint the journal record for a wrist-enacted override change. `override == nil` is the
    /// CLEAR (empty payload), which the phone applies as `scheduleOverride = nil`.
    ///
    /// IDENTITY: `syncIdentifier` carries the override's OWN `syncIdentifier` (a UUID minted by
    /// `createOverride`), which is what makes the phone-side apply idempotent — a replayed drain
    /// re-derives the same identity and the phone recognises the override it already holds. A
    /// clear has no override to name, so it has no syncIdentifier; its exactly-once guarantee is
    /// the enclosing `LoanEvent.id` (the phone's persisted `committedIDs` filter) plus the
    /// "already nil → skip" check. `endDate` is the override's scheduled end (nil = indefinite),
    /// carried for the log line and for anyone reading the journal by hand.
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

    /// The override this `.overrideChange` record carries, decoded. nil for a CLEAR record —
    /// so callers must gate on `kind == .overrideChange` FIRST and treat nil as "clear", never
    /// as "not an override record". (An undecodable payload also lands here; a decode failure
    /// would otherwise silently become a clear, so `overrideChangeIsClear` distinguishes them.)
    public var overrideChangePayload: TemporaryScheduleOverride? {
        guard kind == .overrideChange, let data = overrideRaw,
              let raw = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? TemporaryScheduleOverride.RawValue
        else { return nil }
        return TemporaryScheduleOverride(rawValue: raw)
    }

    /// True when this record is an override CLEAR (empty payload) rather than a set. Kept
    /// separate from `overrideChangePayload == nil` so an undecodable payload is NOT silently
    /// treated as a clear — clearing a live override on the strength of a corrupt blob would be
    /// a therapy change nobody asked for.
    public var overrideChangeIsClear: Bool {
        return kind == .overrideChange && overrideRaw == nil
    }
}

// MARK: - Seed conversion (shared: watch takeover seed + handover-fidelity tests)
//
// Extracted from PodLoanWatchController so the watch seed AND the unit tests exercise
// IDENTICAL record→DoseEntry logic (the watch extension target is not reachable from
// LoopTests; this file is compiled into BOTH targets). See docs/DESIGN_LOAN_ADDPUMPEVENTS.md.

extension LoanDoseRecord {
    /// Convert a wire record to a DoseEntry for seeding the watch's dose store at takeover.
    ///
    /// Net-basal netting is deliberately NOT frozen here: the seed is written via
    /// `DoseStore.addPumpEvents`, and the pump-event table does not persist a dose's
    /// `scheduledBasalRate` — LoopKit re-derives it from the reader's `basalProfile` at read
    /// (`InsulinMath.annotated(with:)`). On the watch that profile is frozen to the grant
    /// schedule for the whole loan (WatchLoopManager.settings), so seeded temps net against
    /// the delivery-time schedule correctly, with no stamped rate needed. (The phone-side
    /// retroactive-netting fix, where the profile CAN change mid-loan, is a separate task.)
    func seedDoseEntry(syncIdentifier: String) -> DoseEntry? {
        switch kind {
        case .bolus:
            guard let units = amount else { return nil }
            return DoseEntry(type: .bolus, startDate: startDate, endDate: endDate ?? startDate,
                             value: units, unit: .units, syncIdentifier: syncIdentifier, insulinType: insulinType)
        case .tempBasal, .boundaryTruncation:
            guard let rate = unitsPerHour, let end = endDate else { return nil }
            // Carry the pod's floored actual delivery so the watch nets on the SAME quantum
            // the phone did (nil → LoopKit's round(programmedUnits) fallback, the pre-fix behavior).
            return DoseEntry(type: .tempBasal, startDate: startDate, endDate: end,
                             value: rate, unit: .unitsPerHour, deliveredUnits: deliveredUnits,
                             syncIdentifier: syncIdentifier, insulinType: insulinType)
        case .suspend:
            guard let end = endDate else { return nil }
            return DoseEntry(type: .tempBasal, startDate: startDate, endDate: end,
                             value: 0, unit: .unitsPerHour, deliveredUnits: deliveredUnits,
                             syncIdentifier: syncIdentifier, insulinType: insulinType)
        // .overrideChange carries no insulin — it never seeds a dose.
        case .resume, .carb, .carbDeleted, .plumbingCancel, .modeChange, .overrideChange:
            return nil
        }
    }
}

/// The `NewPumpEvent.raw` bytes a grant dose must be seeded under.
///
/// IDENTITY CONTRACT — why decoding matters: LoopKit's PumpEvent DISCARDS an incoming
/// DoseEntry.syncIdentifier and derives dose identity as `raw.hexadecimalString`
/// (PumpEvent+CoreDataClass.swift:229). So for every pump-event-sourced dose, the phone's stored
/// syncIdentifier IS the hex of the raw its own pump manager reported — and OmniBLE's raw is
/// `UnfinalizedDose.uniqueKey` = utf8("\(doseType) \(scheduledUnits ?? units) \(ISO8601 start)")
/// (UnfinalizedDose.swift:54), fully deterministic and cancel-stable, no UUID. DECODING the hex
/// therefore recovers the exact bytes the watch's own rebuilt pump manager will use when it
/// re-reports the same physical dose out of the inherited podState (a just-finished bolus rides
/// the grant un-pruned; the running temp re-reports on every status read). Same raw → the
/// re-report lands on the SAME PumpEvent row (raw uniqueness constraint, store-trump merge) and
/// the SAME delivery-store row (syncIdentifier constraint) instead of a second copy — and a
/// re-seed across epochs upserts instead of accumulating EVEN IF the wipe misfires.
///
/// The earlier bug: seeding raw = utf8(hexString) gave one physical dose two identities (hex vs
/// hex-of-hex — log proof: seeded id=303561 vs pod-native id=33305a for one bolus), which blinded
/// every stock dedup layer → the cycle-1 bolus echo (+1.15U, epoch 47) and cross-epoch IOB
/// inflation (epoch 42/44/45). Non-hex identifiers (epoch-keyed fallback "loanv2-grant-…",
/// UUID-style ids) keep the utf8 encoding — for phone rows whose raw was born as a utf8 string
/// (hand-back journal writes) the hex decode reproduces those original bytes too.
public enum LoanSeedIdentity {
    public static func raw(forSyncIdentifier syncIdentifier: String) -> Data {
        return hexDecoded(syncIdentifier) ?? Data(syncIdentifier.utf8)
    }

    /// Strict hex → bytes (case-insensitive; nil on any non-hex character or odd length).
    /// Local copy of LoopKit's `Data(hexadecimalString:)`, which is internal to that module.
    static func hexDecoded(_ string: String) -> Data? {
        func nibble(_ u: UInt16) -> UInt8? {
            switch u {
            case 0x30...0x39: return UInt8(u - 0x30)          // '0'-'9'
            case 0x41...0x46: return UInt8(u - 0x41 + 10)     // 'A'-'F'
            case 0x61...0x66: return UInt8(u - 0x61 + 10)     // 'a'-'f'
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
    /// The seeded insulin history as DoseEntries with deterministic, epoch-keyed sync
    /// identifiers ("loanv2-grant-<epoch>-<index>") — idempotent under grant redelivery.
    ///
    /// The `boundaryRecord`, when present, is appended (kept for backward-compat with older
    /// phones); current phones send it nil because it is a same-start duplicate of the running
    /// temp already in `doseHistory` (the #1 double-seed). Routing the seed through
    /// `addPumpEvents` runs stock `reconciled()`, which collapses any residual same-start
    /// overlap to a single dose regardless.
    func seedDoseEntries() -> [DoseEntry] {
        var records = doseHistory
        if let boundary = boundaryRecord { records.append(boundary) }
        return records.enumerated().compactMap { index, record in
            // Stable syncId: prefer the phone's OWN dose syncIdentifier so a re-seed across
            // epochs upsert-dedups (same identity → one row) instead of accumulating under fresh
            // epoch-keyed ids. Epoch-keyed fallback keeps older phones (no syncIdentifier) working
            // — and stays unique per (epoch,index) so their re-seeds still rely on the wipe.
            let syncId = record.syncIdentifier ?? "loanv2-grant-\(epoch)-\(index)"
            return record.seedDoseEntry(syncIdentifier: syncId)
        }
    }

    /// The seed carries FINISHED history only. A dose still DELIVERING at the
    /// takeover instant (the running temp; a mid-flight bolus) is split out as `live` and NOT
    /// seeded: the grant's podState blob already carries it, and the watch's own pump manager
    /// reports it as a MUTABLE dose on the first status read — stock ownership, exactly how the
    /// phone books its own running temp. Stock IOB math integrates a mutable dose's delivery only
    /// up to now + model.delay (InsulinMath.continuousDeliveryInsulinOnBoard's loop bound), so the
    /// watch's IOB then TRACKS delivery in real time (0.50 → 0.57 over 5 min of a +1 U/hr net
    /// temp) and the eventual cancel/expiry finalization books actual units under the pod-native
    /// raw — with no seeded row to swallow it. (Supersedes Fix 2's trim-at-takeover, which — once
    /// the seed-identity fix made dedup work — permanently froze the temp at the takeover instant
    /// and understated IOB for the temp's remaining life.)
    func seedDoseEntries(finishedBy instant: Date) -> (seed: [DoseEntry], live: [DoseEntry]) {
        let all = seedDoseEntries()
        return (all.filter { $0.endDate <= instant }, all.filter { $0.endDate > instant })
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

/// The odometer audit pair (§1.4): freshen-before-snapshot with the OQ-5 retry;
/// `freshenSucceeded` false means the audit is advisory-only this session.
public struct LoanOdometerSnapshot: Codable, Equatable {
    public let deliveredAtStart: Double
    public let deliveredLatest: Double
    public let freshenSucceeded: Bool
    /// When `deliveredLatest` was actually read off the pod (the status response's validTime,
    /// watch-stamped like every record timestamp). This is what turns a snapshot into a
    /// CHECKPOINT for the since-last-sync audit: the phone can only advance its audit base past
    /// a reading whose moment it knows, because the window's expected-insulin integral runs to
    /// exactly this instant. nil (older watch) = no checkpoint — the audit keeps its
    /// whole-loan window, the pre-checkpoint behavior.
    public let asOf: Date?

    public init(deliveredAtStart: Double, deliveredLatest: Double, freshenSucceeded: Bool,
                asOf: Date? = nil) {
        self.deliveredAtStart = deliveredAtStart
        self.deliveredLatest = deliveredLatest
        self.freshenSucceeded = freshenSucceeded
        self.asOf = asOf
    }
}

/// StatusReport dosing mode: the phone tile shows which world the watch is in.
public enum LoanDosingMode: String, Codable {
    case closedDirect      // default: dosing from the watch's own direct-G7 stream
    case closedPhoneFed    // the picker's explicitly chosen, labeled degraded mode
    case cgmViewer         // first-class: glucose display, loop open, pod with phone
    case pausedStale       // Lenient pause: stale anchor, no NEW temps
    case suspended         // bounded rate-0 suspend running
}

// MARK: - Messages (§2)

/// 1. watch→phone. The only message without an epoch.
public struct LoanRequest: Codable, Equatable {
    public let watchBuild: String
    public let supportedVersions: [Int]
    /// Identity for duplicate suppression. The transport may deliver the
    /// SAME request twice — sendMessage reports a timeout without meaning "undelivered", so
    /// the queued fallback re-sends a copy that also arrives.
    ///
    /// Two copies milliseconds apart are NOT the same as a user double-tapping Start: the
    /// second lands while the phone is still in .grantOffered from the first, takes the
    /// stale-state recovery path, force-reclaims the pod it JUST released, and re-grants —
    /// which the reclaim-settle guard then denies. Observed result: the watch held a grant
    /// for epoch 122 while the pod stayed on the phone (`released=false`), so its whole
    /// ladder read `no-peripheral` and the loan died.
    ///
    /// Optional for back-compat: an older watch sends none, and the phone then behaves
    /// exactly as it did before (no dedupe).
    public let requestID: String?

    public init(watchBuild: String,
                supportedVersions: [Int] = [LoanProtocol.version],
                requestID: String = UUID().uuidString) {
        self.watchBuild = watchBuild
        self.supportedVersions = supportedVersions
        self.requestID = requestID
    }
}

/// 2. phone→watch. Identity/keys live INSIDE `pumpManagerRawState` (the stock
/// OmniPumpManagerState raw snapshot, plist-encoded): the watch resumes via
/// `OmniPumpManager(rawState:)` exactly as the phone does on relaunch — including
/// `unfinalizedDoses` and any `unacknowledgedCommand`. Completeness is enforced
/// phone-side before send (deny-on-missing, never defaulted) and watch-side by init
/// failure → TakeoverFailed. The phone does NOT cancel its running temp; its
/// RECORD closes at the handover stamp (`boundaryRecord`, kind .boundaryTruncation).
public struct LoanGrant: Codable, Equatable {
    public let epoch: Int
    /// A late-arriving grant self-rejects on the watch (§2.4 row 2).
    public let expiresAt: Date
    /// plist-encoded PumpManager.RawStateValue (opaque stock blob).
    public let pumpManagerRawState: Data
    /// Display/log sanity only — never a substitute for blob completeness.
    public let podAddress: UInt32
    /// plist-encoded LoopSettings rawValue: the ONLY dosing limits;
    /// frozen for the loan in `settingsTimeZoneID` (spec §8, mid-loan freeze APPROVED).
    public let therapySettingsRaw: Data
    public let settingsTimeZoneID: String
    /// 16 h context for the watch's stores (v1 `dh`, kept).
    public let doseHistory: [LoanDoseRecord]
    public let boundaryRecord: LoanDoseRecord?
    /// Capability gate (verify finding REAL-3, deployment skew): the watch sends
    /// INTERIM (released=false) hand-back offers only when the granting phone
    /// understands them — an old phone's decoder drops the unknown `released` key and
    /// would treat the first interim offer as a completed hand-back, reclaiming the
    /// pod while the watch is still dosing. nil (old phone) → legacy single-phase.
    public let supportsInterimHandback: Bool?
    /// Skew gate: does the GRANTING phone understand `.overrideChange` records?
    /// The watch and phone apps install separately on this rig, so a watch newer than its
    /// phone is routine. Minting a kind the phone cannot decode makes the whole hand-back
    /// offer undecodable and STRANDS the loan until the builds match (escape-hatch reclaim
    /// is the only way out) — unacceptable mid-exercise. When false/nil the watch still
    /// applies the override LOCALLY (dosing is correct on the wrist) and logs loudly that
    /// it will not follow the pod home. nil (older phone) => false.
    public let supportsOverrideRecords: Bool?
    /// Phone-local algorithm-experiment toggle (`UserDefaults.integralRetrospectiveCorrectionEnabled`,
    /// read at LoopDataManager:457 to pick Integral vs Standard RC). It is NOT part of
    /// LoopSettings, so it has to ride separately — otherwise the watch silently runs
    /// Standard while the phone runs Integral, producing different predictions from
    /// identical inputs with no error (audit 2026-07-22). Frozen for the loan exactly like
    /// the therapy settings. nil (older phone) → Standard, the pre-existing behavior.
    public let integralRetrospectiveCorrectionEnabled: Bool?
    /// The phone's own loop mode (`LoopSettings.dosingEnabled`) at the moment of the grant.
    ///
    /// The wrist INHERITS it: phone closed → watch closed, phone open → watch open. An
    /// earlier design reset every loan to OPEN/advisory and ignored the phone's mode
    /// entirely; inheritance is for intuitiveness to a second user rather than a change of
    /// confidence in the fail-safe — a broader release may well revert to always-open.
    ///
    /// Optional for deployment skew, like the capability flags above: the watch and phone apps
    /// install separately on this rig, so a watch newer than its phone is routine. nil (older
    /// phone that does not send it) → false, i.e. exactly the previous start-OPEN behavior.
    public let phoneClosedLoopEnabled: Bool?
    /// Active carbs the phone holds, seeded so the WATCH's own loop predicts with COB —
    /// not just IOB. The grant carried 16h of INSULIN (doseHistory) but no carbs, so the
    /// watch predicted LOWER than reality and under-delivered into a rising meal (field
    /// 2026-07-22: phone eventual 293 with 44 g aboard, watch showed 0). Each record
    /// carries the phone's stable syncIdentifier + provenanceIdentifier so re-seeding on
    /// every re-takeover is idempotent (CarbStore.syncCarbObjects dedups on that pair) —
    /// otherwise a dozen epochs would multiply COB. nil (older phone) → no seeding, the
    /// pre-existing behavior.
    public let carbHistory: [LoanCarbRecord]?
    /// ~3 h of recent glucose seeded phone→watch so momentum AND retrospective correction
    /// compute from the FIRST post-takeover cycle. The watch's GlucoseStore is otherwise empty
    /// at takeover (fed only by live G7 reads that accumulate over ~15 min), so momentum was
    /// blind for ~15 min and RC never warmed — the watch dosed on a prediction that ignored
    /// glucose history. 3 h is the Integral RC look-back (IntegralRetrospectiveCorrection
    /// retrospectionInterval); it comfortably covers Standard RC (30 min) and momentum (15 min).
    /// nil (older phone) → no seeding, pre-existing behavior.
    public let glucoseHistory: [LoanGlucoseRecord]?
    /// The phone's LAST-COMPUTED prediction decomposition at grant time (INSTRUMENTATION ONLY,
    /// no dosing effect). Carried so the watch can diff its first post-takeover prediction
    /// term-by-term against the phone ([predict-diff]) and reconcile phone-IOB vs SEED-IN-IOB
    /// ([iob-diff] Leg 1) — localizing the ~58 mg/dL takeover divergence to a specific effect
    /// term rather than eyeballing. Read from LoopDataManager's already-cached effect arrays
    /// (leave-one-out via stock predictGlucose, no recompute). nil (older phone / stale caches)
    /// → the watch simply skips the diff lines.
    public let predictionSnapshot: LoanPredictionSnapshot?
    /// The phone's last completed loop cycle, so the wrist's loop dot starts from the SYSTEM's
    /// recency instead of grey (ring ruling 2026-08-23: loop recency is a property of the
    /// system, not the device — the boundary inherits, and the new device's own next cycle
    /// then keeps or loses the freshness honestly). nil (older phone) = the old behavior.
    public let lastLoopCompleted: Date?

    public init(epoch: Int, expiresAt: Date, pumpManagerRawState: Data, podAddress: UInt32,
                therapySettingsRaw: Data, settingsTimeZoneID: String,
                doseHistory: [LoanDoseRecord], boundaryRecord: LoanDoseRecord?,
                supportsInterimHandback: Bool? = nil,
                supportsOverrideRecords: Bool? = nil,
                integralRetrospectiveCorrectionEnabled: Bool? = nil,
                phoneClosedLoopEnabled: Bool? = nil,
                carbHistory: [LoanCarbRecord]? = nil,
                glucoseHistory: [LoanGlucoseRecord]? = nil,
                predictionSnapshot: LoanPredictionSnapshot? = nil,
                lastLoopCompleted: Date? = nil) {
        self.epoch = epoch
        self.expiresAt = expiresAt
        self.pumpManagerRawState = pumpManagerRawState
        self.podAddress = podAddress
        self.therapySettingsRaw = therapySettingsRaw
        self.settingsTimeZoneID = settingsTimeZoneID
        self.doseHistory = doseHistory
        self.boundaryRecord = boundaryRecord
        self.supportsInterimHandback = supportsInterimHandback
        self.supportsOverrideRecords = supportsOverrideRecords
        self.integralRetrospectiveCorrectionEnabled = integralRetrospectiveCorrectionEnabled
        self.phoneClosedLoopEnabled = phoneClosedLoopEnabled
        self.carbHistory = carbHistory
        self.glucoseHistory = glucoseHistory
        self.predictionSnapshot = predictionSnapshot
        self.lastLoopCompleted = lastLoopCompleted
    }
}

/// The phone's last-computed prediction, decomposed, carried in the grant for INSTRUMENTATION.
/// The scalar shape is mirrored on both devices so [predict-diff] is a pure subtraction and the
/// IOB Leg-1 reconciliation is measurable. All impacts are leave-one-out counterfactuals on the
/// EVENTUAL — impact(X) = eventual(all effects) − eventual(all except X) — computed the SAME way
/// on both sides (both include positive velocity/RC), so a nonzero diff isolates the divergence to
/// the INPUT arrays, not to suppression policy. Purely additive/optional on the wire; an older
/// phone omits it and an older watch ignores it (no protocol-version bump). Dates round-trip via
/// LoanProtocol's custom Int64-millisecond coder.
public struct LoanPredictionSnapshot: Codable, Equatable {
    /// Capture instant — the watch ages every value below against this.
    public let snapshotAt: Date
    public let startGlucoseMgdl: Double
    /// Timestamp of the starting glucose, so the watch can isolate the stale-start term.
    public let startGlucoseDate: Date
    /// The phone eventual the loop actually dosed on.
    public let eventualMgdl: Double
    /// Display-parity eventual (includingPendingInsulin); optional because it is a recency add-on.
    public let eventualIncludingPendingMgdl: Double?
    public let impactMomentumMgdl: Double
    public let impactInsulinMgdl: Double
    public let impactCarbMgdl: Double
    public let impactRCMgdl: Double
    /// Phone IOB + its timestamp (folds in the phone-IOB-at-grant need — the watch ages this for
    /// [iob-diff] Leg 1 rather than the phone recomputing at the handover instant).
    public let iobUnits: Double
    public let iobDate: Date
    public let cobGrams: Double
    /// glucoseMomentumEffect.count on the phone — proves the phone HAD momentum where the watch had 0.
    public let momentumPointCount: Int
    /// retrospectiveGlucoseDiscrepancies.count on the phone — RC warmth.
    public let rcDiscrepancyCount: Int
    /// PredictionInputEffect mask used, so the diff is like-for-like.
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

/// One carb entry seeded phone→watch at grant time. Distinct from LoanDoseRecord —
/// carbs need the full sync identity (syncIdentifier + provenanceIdentifier + syncVersion)
/// that LoopKit's CarbStore.syncCarbObjects dedups on, which the dose record does not carry.
/// The watch reconstructs a SyncCarbObject from this and calls syncCarbObjects, so re-grants
/// are idempotent by construction.
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

/// One glucose sample seeded phone→watch at grant time so the watch's momentum + retrospective
/// correction warm from the first post-takeover cycle (the GlucoseStore is otherwise empty until
/// live G7 reads accumulate). The watch reconstructs a NewGlucoseSample and calls
/// GlucoseStore.addGlucoseSamples; reusing the phone's stable syncIdentifier makes re-grants
/// idempotent (GlucoseStore dedups on provenance + syncIdentifier). Seeded samples are
/// pre-takeover; because the watch's G7 path reads one current EGV per connection (no backfill),
/// at most a single boundary sample can duplicate (phone/watch derive different G7 syncIds), and
/// the algorithm tolerates it (momentum is duplicate-insensitive; counteraction skips <4-min pairs).
public struct LoanGlucoseRecord: Codable, Equatable {
    public let syncIdentifier: String?
    public let startDate: Date
    /// mg/dL — the wire carries a plain value; the watch rebuilds an HKQuantity.
    public let valueMgdl: Double
    /// mg/dL per minute, if the phone had a trend (display/only; momentum is computed from values).
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

/// 3a. watch→phone: only now does the phone commit LOANED (cancels T1 — the
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
    /// The watch's latest pod odometer reading, riding along so the phone can CHECKPOINT the
    /// audit mid-loan: records synced + odometer observed = this window is reconciled, and the
    /// audit base advances. A later forced reclaim then judges only the tail since this sync
    /// instead of the whole loan. nil (older watch, or no reading yet) = no checkpoint; the
    /// phone behaves exactly as before.
    public let odometer: LoanOdometerSnapshot?

    public init(epoch: Int, events: [LoanEvent], tombstones: [UUID],
                odometer: LoanOdometerSnapshot? = nil) {
        self.epoch = epoch
        self.events = events
        self.tombstones = tombstones
        self.odometer = odometer
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
    /// Two-phase hand-back: `false` = INTERIM drain — the
    /// watch is STILL DOSING and still owns the pod's connection; commit records +
    /// ack the cursor but do NOT reclaim. `true` = the watch has released the pod.
    /// nil (legacy senders, which only offered after stopping) = treat as released.
    public let released: Bool?
    /// The wrist's loop mode at hand-back. The phone
    /// INHERITS the watch's state on the way back, mirroring the grant's outbound inheritance,
    /// rather than restoring the value captured before the loan. nil (older watch) → the phone
    /// keeps its captured pre-loan value, i.e. the previous restore behavior.
    public let watchClosedLoopEnabled: Bool?
    /// The wrist's last completed loop cycle, the return-direction twin of the grant's field:
    /// at reclaim the phone seeds its own recency display from this, so the ~10 s settle does
    /// not paint a red ring over a system that looped seconds ago (the watch's temp is still
    /// running, R33 — therapy is genuinely continuous). nil (older watch) = no seed.
    public let lastLoopCompleted: Date?

    public init(epoch: Int, handedBackAt: Date, finalStatus: LoanPodStatus?,
                odometer: LoanOdometerSnapshot?, events: [LoanEvent], tombstones: [UUID],
                recovered: Bool, released: Bool? = nil, watchClosedLoopEnabled: Bool? = nil,
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
        self.lastLoopCompleted = lastLoopCompleted
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

/// 8b. watch→phone: sovereignty + mode, last event seq (reconcile progress),
/// pod fault surfacing (§6). NO heartbeat semantics attach to this message —
/// its absence alarms nothing.
public struct StatusReport: Codable, Equatable {
    public let epoch: Int
    public let mode: LoanDosingMode
    /// Age of the last DIRECT G7 read (§6a sovereignty signal — store freshness is not it).
    public let lastDirectGlucoseAge: TimeInterval?
    public let lastEventSeq: Int
    public let podFault: String?
    public let holdsPod: Bool
    /// Does this watch know about the epoch it was asked about?
    ///
    /// `holdsPod: false` is ambiguous on its own — it is equally true of a watch that never
    /// received the grant and of a watch that received it and is thirty seconds into taking the
    /// pod. Those need opposite responses, so the difference has to be said out loud.
    ///
    /// Optional because it is an added field: `nil` means an older build that could not answer,
    /// which the phone must read as "no information", never as "no".
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
/// A phone→watch diagnostic breadcrumb. The phone doesn't mirror to
/// iCloud like the watch does, so its hand-back-offer handling is invisible in the logs —
/// when the phone silently fails to ack, we can't see whether it received the offer, or
/// stalled on the store write. The phone relays compact breadcrumbs (offer received / write
/// start / write done / ack sent) that the watch logs into the iCloud mirror, making the
/// phone-side hand-back path debuggable. Purely diagnostic; touches no dosing state.
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
        case .diag(let m): return m.epoch
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
        case diag
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

    /// Which kinds ride the IMMEDIATE WCSession channel (sendMessage) instead of the queued one
    /// (transferUserInfo).
    ///
    /// transferUserInfo is explicitly NON-URGENT: iOS drains it opportunistically, and a whole
    /// queue can sit until the phone wakes — long enough for a Start request's answer to arrive
    /// after the watch's 25 s timeout has already told the user the takeover failed. So the
    /// INTERACTIVE moments of a loan, everything the user is watching a spinner through, take
    /// the immediate channel, which wakes the counterpart app in milliseconds.
    ///
    /// Background bookkeeping (record streaming, status, diagnostics) keeps transferUserInfo,
    /// whose guaranteed, relaunch-surviving delivery the cursor/ID machinery is built around.
    ///
    /// Every urgent kind is idempotent under those same cursor/ID rules — a redelivered offer
    /// re-acks the same cursor, a repeat request is a double-tap of Start — so the rare
    /// delivered-but-reported-failed duplicate from the fallback is harmless.
    ///
    /// `.takeoverComplete` belongs here: it is the moment the watch actually has the pod, and
    /// the pump tile distinguishes "Taking over…" from "Pod on Watch" on the strength of it.
    /// Queued, that label can sit for minutes after a takeover has already finished. The honest
    /// tile REQUIRES this channel — do not move it back without reverting the tile.
    /// Wire-kind name for logs. Matches the envelope's `kind` string, so a watch RX line
    /// and a phone SEND line for the same message read the same.
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
        }
    }

    public var isInteractiveHandshake: Bool {
        switch self {
        case .request, .grant, .denied, .nack, .revoke, .handbackOffer, .handbackAck,
             .takeoverComplete:
            return true
        case .takeoverFailed, .doseRecordBatch, .statusQuery,
             .statusReport, .diag:
            return false
        }
    }

    /// Transport-level kind peek, on LoanMessage beside its sibling transport peek:
    /// the wire `kind` string, or nil for anything not ours.
    /// Exists so the WATCH can identify which of its own QUEUED transfers are hand-back offers
    /// without decoding full envelopes — the supersede logic cancels only offers, because a
    /// cancelled offer is re-sent 15 s later by design while a cancelled record stream is not.
    public static func peekKind(transport userInfo: [String: Any]) -> String? {
        guard let data = userInfo[LoanProtocol.userInfoKey] as? Data else { return nil }
        struct Peek: Decodable { let kind: String }
        return (try? JSONDecoder().decode(Peek.self, from: data))?.kind
    }

    /// Transport-level peek: safe on any dictionary, false for anything not ours.
    public static func isInteractiveHandshake(transport userInfo: [String: Any]) -> Bool {
        // sendMessage caps payloads far below transferUserInfo. Anything unexpectedly large
        // takes the queue rather than burning a round-trip on a certain failure.
        //
        // This gate was formerly 24_000 — and a GRANT (pod state + seeded dose
        // history + glucose warm-up) routinely exceeds that, so the single most
        // spinner-watched message in the protocol was being silently demoted to the queued
        // path this comment block exists to avoid. On the simulator the queue may not drain
        // for minutes (found because sim grants never arrived: "kind=grant path=queued");
        // in the field it is a candidate mechanism for slow-takeover tails (grant issued in
        // 2s, arriving whenever iOS drains the queue). WCSession.sendMessage's real payload
        // ceiling is ~65 KB; 60_000 leaves envelope margin while letting every observed
        // grant ride the immediate channel. The errorHandler fallback still catches a
        // genuine too-big rejection.
        if let data = userInfo[LoanProtocol.userInfoKey] as? Data, data.count > 60_000 {
            return false
        }
        // `try?` flattens the throwing-optional, so this unwraps to a concrete message:
        // nil covers both "not ours" and "undecodable", and both correctly take the queue.
        guard let message = try? decode(fromTransport: userInfo) else { return false }
        return message.isInteractiveHandshake
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

// MARK: - Ledger cutover: assumed-dose conversion

extension LoanDoseRecord {
    /// The DoseEntry a chase-pending ASSUMED record models, for the session ledger's
    /// mirror of the journal's direction-aware convention (book only when it means MORE
    /// insulin than schedule; the caller applies that gate). Bolus end falls back to the
    /// DASH delivery ramp (1.5 U/min); temp/suspend end falls back to the stock 30-min
    /// program length. Non-dose kinds return nil.
    public func podLoanLedgerDoseEntry(insulinType: InsulinType?) -> DoseEntry? {
        switch kind {
        case .bolus:
            guard let units = amount else { return nil }
            return DoseEntry(type: .bolus, startDate: startDate,
                             endDate: endDate ?? startDate.addingTimeInterval(units / 1.5 * 60),
                             value: units, unit: .units,
                             insulinType: insulinType ?? self.insulinType)
        case .tempBasal, .suspend:
            guard let rate = unitsPerHour else { return nil }
            return DoseEntry(type: .tempBasal, startDate: startDate,
                             endDate: endDate ?? startDate.addingTimeInterval(.minutes(30)),
                             value: rate, unit: .unitsPerHour,
                             insulinType: insulinType ?? self.insulinType)
        // .overrideChange is a therapy-settings event, not a dose — the shadow
        // ledger never books it (it changes the SCHEDULE the ledger nets against, which the
        // override history already handles for both books).
        case .resume, .carb, .carbDeleted, .plumbingCancel, .boundaryTruncation, .modeChange, .overrideChange:
            return nil
        }
    }
}
