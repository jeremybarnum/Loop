//
//  PodLoanGrantUserInfo.swift
//  Loop
//
//  Phone → watch, sent as the reply to a PodLoanRequestUserInfo. Either GRANTS
//  the loan (carrying the pod identity the watch needs to take the pod over —
//  the same fields OmniBLECore's takeover path consumes: LTK, controllerId,
//  podId, podAddress, messageNumber) or DENIES it with a reason (e.g. no active
//  pod, pod already suspended for another reason).
//
//  Fixed-width identifiers cross the WatchConnectivity boundary as Int (they
//  fit in UInt32 and Int↔NSNumber bridging is reliable), then are rebuilt as
//  UInt32. The 16-byte LTK crosses as Data.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

struct PodLoanGrantUserInfo {
    let version = 1
    let granted: Bool

    // Present iff granted.
    let ltk: Data?
    let controllerId: UInt32?
    let podId: UInt32?
    let podAddress: UInt32?
    let messageNumber: Int?

    /// The pump's insulin type as LoopKit's InsulinType.rawValue (0=novolog,
    /// 1=humalog, 2=apidra, 3=fiasp, 4=lyumjev, 5=afrezza), so the watch can pick
    /// the matching activity curve for its Bolus IOB display (see OmniBLECore's
    /// PodLoanInsulinModel.forInsulinTypeRaw). Optional wire key ("it"): absent on
    /// grants from older phones, and older watches ignore it — both directions
    /// fall back to the rapid-acting-adult curve.
    let insulinTypeRaw: Int?

    /// The phone's last 16h of dose history (PodLoanDoseHistory, binary-plist
    /// encoded), so the watch prediction algorithm sees pre-loan IOB. The grant
    /// is the natural "frozen at handover" carrier. Optional wire key ("dh"):
    /// absent from older phones or if the fetch fails — the watch predicts
    /// degraded (loan-session insulin only) and says so.
    var doseHistoryData: Data?

    /// Whether the phone's beep setting says to beep for MANUAL commands (user
    /// bolus/basal/suspend on the watch) and for AUTOMATIC commands (the closed
    /// loop's temps), derived phone-side from `confirmationBeeps` + `silencePod`
    /// so the watch's pod beeps follow the phone's setting instead of a hard-coded
    /// flag. Optional wire keys ("bm"/"ba"): absent from older phones → the watch
    /// defaults to SILENT (safe/quiet).
    let beepsForManual: Bool?
    let beepsForAutomatic: Bool?

    // Present iff !granted.
    let denialReason: String?

    static func grant(ltk: Data, controllerId: UInt32, podId: UInt32, podAddress: UInt32, messageNumber: Int, insulinTypeRaw: Int? = nil, doseHistoryData: Data? = nil, beepsForManual: Bool? = nil, beepsForAutomatic: Bool? = nil) -> PodLoanGrantUserInfo {
        PodLoanGrantUserInfo(granted: true,
                             ltk: ltk,
                             controllerId: controllerId,
                             podId: podId,
                             podAddress: podAddress,
                             messageNumber: messageNumber,
                             insulinTypeRaw: insulinTypeRaw,
                             doseHistoryData: doseHistoryData,
                             beepsForManual: beepsForManual,
                             beepsForAutomatic: beepsForAutomatic,
                             denialReason: nil)
    }

    static func denied(reason: String) -> PodLoanGrantUserInfo {
        PodLoanGrantUserInfo(granted: false,
                             ltk: nil,
                             controllerId: nil,
                             podId: nil,
                             podAddress: nil,
                             messageNumber: nil,
                             insulinTypeRaw: nil,
                             doseHistoryData: nil,
                             beepsForManual: nil,
                             beepsForAutomatic: nil,
                             denialReason: reason)
    }
}

extension PodLoanGrantUserInfo: RawRepresentable {
    typealias RawValue = [String: Any]

    static let name = "PodLoanGrantUserInfo"

    init?(rawValue: RawValue) {
        guard
            rawValue["v"] as? Int == version,
            rawValue["name"] as? String == PodLoanGrantUserInfo.name,
            let granted = rawValue["g"] as? Bool
            else {
                return nil
        }

        self.granted = granted

        if granted {
            guard
                let ltk = rawValue["ltk"] as? Data,
                let controllerId = rawValue["cid"] as? Int,
                let podId = rawValue["pid"] as? Int,
                let podAddress = rawValue["addr"] as? Int,
                let messageNumber = rawValue["mn"] as? Int
                else {
                    return nil
            }

            self.ltk = ltk
            self.controllerId = UInt32(truncatingIfNeeded: controllerId)
            self.podId = UInt32(truncatingIfNeeded: podId)
            self.podAddress = UInt32(truncatingIfNeeded: podAddress)
            self.messageNumber = messageNumber
            self.insulinTypeRaw = rawValue["it"] as? Int   // optional: absent from older phones
            self.doseHistoryData = rawValue["dh"] as? Data // optional: absent from older phones
            self.beepsForManual = rawValue["bm"] as? Bool  // optional: absent from older phones → silent
            self.beepsForAutomatic = rawValue["ba"] as? Bool
            self.denialReason = nil
        } else {
            self.ltk = nil
            self.controllerId = nil
            self.podId = nil
            self.podAddress = nil
            self.messageNumber = nil
            self.insulinTypeRaw = nil
            self.doseHistoryData = nil
            self.beepsForManual = nil
            self.beepsForAutomatic = nil
            self.denialReason = rawValue["dr"] as? String
        }
    }

    var rawValue: RawValue {
        var raw: RawValue = [
            "v": version,
            "name": PodLoanGrantUserInfo.name,
            "g": granted
        ]

        if granted {
            raw["ltk"] = ltk
            raw["cid"] = controllerId.map { Int($0) }
            raw["pid"] = podId.map { Int($0) }
            raw["addr"] = podAddress.map { Int($0) }
            raw["mn"] = messageNumber
            raw["it"] = insulinTypeRaw
            raw["dh"] = doseHistoryData
            raw["bm"] = beepsForManual
            raw["ba"] = beepsForAutomatic
        } else {
            raw["dr"] = denialReason
        }

        return raw
    }
}

// MARK: - Dose history payload

/// The phone's recent dose history, slimmed for the WatchConnectivity budget
/// (~65 KB per message): five fields per entry, binary-plist encoded. 16h of
/// 5-minute temp cycles is ~200 entries ≈ 15 KB. Ships inside the loan grant
/// ("dh") for the watch prediction algorithm. (Same shared-file pattern as
/// PodLoanRevokeUserInfo below.)
struct PodLoanDoseHistory: Codable {
    struct Entry: Codable {
        let t: String      // DoseType.rawValue
        let s: Date        // startDate
        let e: Date        // endDate
        let v: Double      // value
        let u: String      // DoseUnit.rawValue
    }

    let entries: [Entry]

    init(doses: [DoseEntry]) {
        // DoseEntry.value is internal; the public accessors are per-unit.
        entries = doses.map {
            let value = $0.unit == .unitsPerHour ? $0.unitsPerHour : $0.programmedUnits
            return Entry(t: $0.type.rawValue, s: $0.startDate, e: $0.endDate, v: value, u: $0.unit.rawValue)
        }
    }

    /// Back to DoseEntries for the algorithm; entries whose type/unit this
    /// build doesn't know (newer peer) are dropped rather than guessed.
    func doseEntries(insulinType: InsulinType? = nil) -> [DoseEntry] {
        entries.compactMap {
            guard let type = DoseType(rawValue: $0.t), let unit = DoseUnit(rawValue: $0.u) else { return nil }
            return DoseEntry(type: type, startDate: $0.s, endDate: $0.e, value: $0.v, unit: unit, insulinType: insulinType)
        }
    }

    func encoded() -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(self)
    }

    static func decode(from data: Data) -> PodLoanDoseHistory? {
        try? PropertyListDecoder().decode(PodLoanDoseHistory.self, from: data)
    }
}

/// Watch → phone: request recent dose history on demand. The loan grant is the
/// primary carrier ("dh"), but the sim demo fakes the grant locally, and a real
/// grant's payload could be absent (older phone, failed fetch). Reply:
/// ["dh": Data] (PodLoanDoseHistory-encoded), empty reply on failure.
enum PodLoanDoseHistoryRequest {
    static let name = "PodLoanDoseHistoryRequest"
}

// MARK: - Loan revoke (DESIGN-6)

/// Phone → watch. Sent after the phone's escape-hatch reclaim
/// (reclaimPodFromWatch): the phone has already taken the pod back without a
/// hand-back, and the watch — whenever it next receives this — must stop
/// treating the loan as live and send its journal for reconciliation.
///
/// Rides transferUserInfo (queued): delivery survives the watch being
/// unreachable, asleep, or dead, arriving on its next app run. `revokedAt`
/// lets the watch ignore a stale revoke that outlived its loan: a loan
/// STARTED after this date is a new grant the revoke doesn't apply to.
/// (Lives in this file rather than its own to avoid pbxproj surgery — same
/// pattern as PumpConnectionLendable in LoopKit's PumpManager.swift.)
struct PodLoanRevokeUserInfo {
    let version = 1
    let revokedAt: Date
}

extension PodLoanRevokeUserInfo: RawRepresentable {
    typealias RawValue = [String: Any]

    static let name = "PodLoanRevokeUserInfo"

    init?(rawValue: RawValue) {
        guard
            rawValue["v"] as? Int == version,
            rawValue["name"] as? String == PodLoanRevokeUserInfo.name,
            let revokedAt = rawValue["ra"] as? Date
            else {
                return nil
        }
        self.revokedAt = revokedAt
    }

    var rawValue: RawValue {
        return [
            "v": version,
            "name": PodLoanRevokeUserInfo.name,
            "ra": revokedAt
        ]
    }
}

// MARK: - Show-Mode status poll (3b v2 — phone-driven ownership indicator)

/// Phone → watch, sent as a WCSession message (with reply handler) on the phone's
/// own cadence while a loan is active. The phone POLLS the watch for its live
/// status instead of the watch pushing it — this keeps the watch answer-only (no
/// new watch timer, no proactive send, negligible battery), and a poll that can't
/// reach the watch simply fails, which IS the honest "can't confirm" signal.
/// (Lives in this file to avoid pbxproj surgery — same pattern as
/// PodLoanRevokeUserInfo above.)
struct WatchLoanStatusRequestUserInfo {
    let version = 1
}

extension WatchLoanStatusRequestUserInfo: RawRepresentable {
    typealias RawValue = [String: Any]

    static let name = "WatchLoanStatusRequestUserInfo"

    init?(rawValue: RawValue) {
        guard
            rawValue["v"] as? Int == version,
            rawValue["name"] as? String == WatchLoanStatusRequestUserInfo.name
            else {
                return nil
        }
    }

    var rawValue: RawValue {
        return [
            "v": version,
            "name": WatchLoanStatusRequestUserInfo.name
        ]
    }
}

/// Watch → phone, the reply to a WatchLoanStatusRequestUserInfo. First-hand
/// status the phone can trust because the watch itself reports it (NOT inferred
/// from the grant — a grant doesn't prove takeover): `holdsPod` = the watch is
/// actively holding the pod (its `phase == .active`), and `podConnected` = its
/// BLE link to the pod is live (3a's debounced signal). Drives the phone's
/// "On Watch" / "Watch Lost Pod" tile; a stale/absent reply falls back to the
/// honest "Pod Not Connected".
struct WatchLoanStatusUserInfo {
    let version = 1
    let holdsPod: Bool
    let podConnected: Bool
}

extension WatchLoanStatusUserInfo: RawRepresentable {
    typealias RawValue = [String: Any]

    static let name = "WatchLoanStatusUserInfo"

    init?(rawValue: RawValue) {
        guard
            rawValue["v"] as? Int == version,
            rawValue["name"] as? String == WatchLoanStatusUserInfo.name,
            let holdsPod = rawValue["hp"] as? Bool,
            let podConnected = rawValue["pc"] as? Bool
            else {
                return nil
        }
        self.holdsPod = holdsPod
        self.podConnected = podConnected
    }

    var rawValue: RawValue {
        return [
            "v": version,
            "name": WatchLoanStatusUserInfo.name,
            "hp": holdsPod,
            "pc": podConnected
        ]
    }
}
