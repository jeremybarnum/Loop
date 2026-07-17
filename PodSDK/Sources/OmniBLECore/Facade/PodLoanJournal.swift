//
//  PodLoanJournal.swift
//  OmniBLECore
//
//  NEW for the WatchPod project — the "loan journal": a record of everything the
//  watch did to the pod while it held control ("the loan"), so that when control
//  returns to the phone the user can be TOLD what happened ("delivered 1.5 U",
//  "zero-temp for 2 h", …).
//
//  Phase 1 scope (deliberate): CAPTURE + DISPLAY only. The journal is surfaced to
//  the user as a human-readable summary; it is NOT automatically written into
//  Loop's insulin-on-board. Automatic dose reconciliation is Phase 2. Worst case,
//  the user reads the summary and records it manually (Loop's Non-Pump Insulin).
//

import Foundation

/// One thing the watch did to the pod during a loan.
public struct PodLoanEvent: Identifiable, Equatable, Codable {
    public enum Kind: Equatable, Codable {
        case tookOver              // loan began (watch took control)
        case bolus(units: Double)
        case tempBasal(rate: Double, duration: TimeInterval)
        case suspend
        case resume
        case cancelTempBasal       // temp canceled; pod reverts to its scheduled basal
        case handedBack            // loan ended (control returned to phone)
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind) {
        self.id = id
        self.date = date
        self.kind = kind
    }

    public var describedAction: String {
        switch kind {
        case .tookOver:            return "Took over pod"
        case .bolus(let u):        return String(format: "Bolus %.2f U", u)
        case .tempBasal(let r, _): return String(format: "Set basal %.2f U/hr", r)
        case .suspend:             return "Suspended delivery"
        case .resume:              return "Resumed basal"
        case .cancelTempBasal:     return "Canceled temp basal"
        case .handedBack:          return "Handed back to phone"
        }
    }
}

/// A carb entry the user logged on the watch during a loan. Not a pod action (so
/// it lives beside `events`, not in `PodLoanEvent.Kind`, keeping the insulin math
/// pure) — but it rides the same hand-back channel so the phone can reconcile it
/// into its own carb store / Nightscout when the loan ends.
public struct PodLoanCarb: Identifiable, Equatable, Codable {
    public let id: UUID
    public let date: Date              // when eaten (the entry's startDate)
    public let grams: Double
    public let absorptionTime: TimeInterval

    public init(id: UUID = UUID(), date: Date = Date(), grams: Double, absorptionTime: TimeInterval) {
        self.id = id
        self.date = date
        self.grams = grams
        self.absorptionTime = absorptionTime
    }
}

/// A record of a watch "loan" of the pod. Codable so it can travel watch→phone
/// over WatchConnectivity on hand-back (encode with `encoded()` / decode with
/// `init?(data:)`).
public struct PodLoanJournal: Equatable, Codable {
    public let startedAt: Date
    /// Pod cumulative insulinDelivered (U) captured at loan start — a floor-truth
    /// cross-check independent of the discrete events below.
    public var deliveredAtStart: Double?
    /// Latest pod cumulative insulinDelivered (U) seen during the loan.
    public var deliveredLatest: Double?
    public private(set) var events: [PodLoanEvent] = []
    /// Carbs logged on the watch during the loan. Optional so a journal persisted
    /// by a PRE-carb app version still decodes across an update (absent → nil → []).
    public private(set) var carbs: [PodLoanCarb]?

    public init(startedAt: Date = Date(), deliveredAtStart: Double? = nil) {
        self.startedAt = startedAt
        self.deliveredAtStart = deliveredAtStart
        self.events.append(PodLoanEvent(date: startedAt, kind: .tookOver))
    }

    public mutating func record(_ kind: PodLoanEvent.Kind, at date: Date = Date()) {
        events.append(PodLoanEvent(date: date, kind: kind))
    }

    public mutating func recordCarb(_ carb: PodLoanCarb) {
        carbs = (carbs ?? []) + [carb]
    }

    /// Update the running pod-delivered cross-check from a status read.
    public mutating func noteDelivered(_ delivered: Double) {
        if deliveredAtStart == nil { deliveredAtStart = delivered }
        deliveredLatest = delivered
    }

    // MARK: - Derived

    public var totalBolusUnits: Double {
        events.reduce(0) { acc, e in
            if case .bolus(let u) = e.kind { return acc + u }
            return acc
        }
    }

    public var bolusCount: Int {
        events.filter { if case .bolus = $0.kind { return true }; return false }.count
    }

    public var tempBasalCount: Int {
        events.filter { if case .tempBasal = $0.kind { return true }; return false }.count
    }

    /// The most recent temp-basal rate set during the loan, if it is still in
    /// force — a later cancel/suspend/resume means the pod is back on (or off)
    /// its schedule, so this returns nil.
    public var lastTempBasalRate: Double? {
        for e in events.reversed() {
            switch e.kind {
            case .tempBasal(let r, _): return r
            case .cancelTempBasal, .suspend, .resume: return nil
            default: continue
            }
        }
        return nil
    }

    /// True if the last suspend has no matching later resume.
    public var isSuspended: Bool {
        for e in events.reversed() {
            switch e.kind {
            case .suspend: return true
            case .resume:  return false
            default:       continue
            }
        }
        return false
    }

    /// The pod's own cumulative-delivered delta over the loan, if known. This
    /// includes basal + boluses; the discrete `totalBolusUnits` counts only the
    /// watch's boluses.
    public var podDeliveredDelta: Double? {
        guard let start = deliveredAtStart, let latest = deliveredLatest else { return nil }
        return max(0, latest - start)
    }

    /// Contiguous suspend windows as (start, end?) — end nil if still suspended.
    public var suspendWindows: [(start: Date, end: Date?)] {
        var windows: [(Date, Date?)] = []
        var openStart: Date?
        for e in events {
            switch e.kind {
            case .suspend:
                if openStart == nil { openStart = e.date }
            case .resume:
                if let s = openStart { windows.append((s, e.date)); openStart = nil }
            default:
                continue
            }
        }
        if let s = openStart { windows.append((s, nil)) }
        return windows.map { (start: $0.0, end: $0.1) }
    }

    // MARK: - Human-readable summary (the Phase-1 hand-back screen)

    public func summaryLines(now: Date = Date(), schedule: PodLoanBasalSchedule? = nil) -> [String] {
        var lines: [String] = []

        let loanMinutes = Int((now.timeIntervalSince(startedAt) / 60).rounded())
        lines.append("Watch held the pod for \(durationString(minutes: loanMinutes)).")

        if bolusCount > 0 {
            lines.append(String(format: "Delivered %.2f U in %d bolus%@.",
                                totalBolusUnits, bolusCount, bolusCount == 1 ? "" : "es"))
        }

        for w in suspendWindows {
            if let end = w.end {
                let mins = Int((end.timeIntervalSince(w.start) / 60).rounded())
                lines.append("Suspended delivery for \(durationString(minutes: mins)) (\(timeString(w.start))–\(timeString(end))).")
            } else {
                let mins = Int((now.timeIntervalSince(w.start) / 60).rounded())
                lines.append("Suspended delivery for \(durationString(minutes: mins)), still suspended at hand-back.")
            }
        }

        if let rate = lastTempBasalRate {
            lines.append(String(format: "Set basal to %.2f U/hr (%d change%@).",
                                rate, tempBasalCount, tempBasalCount == 1 ? "" : "s"))
        }

        if bolusCount == 0 && suspendWindows.isEmpty && tempBasalCount == 0 {
            lines.append("No boluses or suspends — basal only.")
        }

        if let schedule = schedule {
            // Net basal vs the wearer's schedule — the IOB-relevant figure (delivered
            // above/below scheduled), matching the live Show Mode HUD. Preferred over the
            // raw pod-odometer total below, which lumps basal + boluses together and is
            // meaningless without the schedule baseline.
            let net = netBasalDelivered(until: now, schedule: schedule)
            lines.append(String(format: "Basal delivered %+.2f U vs schedule.", net))
        } else if let delta = podDeliveredDelta {
            // Fallback when no schedule is available (e.g. the force-quit recovery path,
            // where the journal is decoded from storage without the live schedule).
            lines.append(String(format: "Pod reports %.2f U total delivered during the loan (basal + boluses).", delta))
        }

        if isSuspended {
            lines.append("⚠️ Delivery is SUSPENDED — resume it on the phone if needed.")
        }

        return lines
    }

    public var summaryText: String { summaryLines().joined(separator: "\n") }

    // MARK: - WatchConnectivity transport (watch → phone on hand-back)

    /// Encode for sending to the phone. Small JSON blob.
    /// Counterpart of encoded() — same coder configuration (ISO-8601 dates).
    public static func decoded(from data: Data) -> PodLoanJournal? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PodLoanJournal.self, from: data)
    }

    public func encoded() -> Data? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(self)
    }

    /// Decode a journal received from the watch.
    public init?(data: Data) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let decoded = try? dec.decode(PodLoanJournal.self, from: data) else { return nil }
        self = decoded
    }

    // MARK: - Formatting helpers

    private func durationString(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}


/// §4c-3 (journal persistence): the loan journal survives watch-app crashes and
/// updates by being written to UserDefaults on every mutation. A journal that
/// outlives its session is RECOVERED data — handed back to the phone for
/// reconciliation, never used to resume the session. Motivating incident:
/// 2026-07-10, a phone crash at hand-back plus an app update destroyed an
/// in-memory journal holding 0.85 U of delivered insulin.
public enum PodLoanJournalStore {
    /// Injectable for tests; .standard on the watch.
    public static var defaults: UserDefaults = .standard
    static let key = "PodLoanJournalStore.activeJournal"
    /// DESIGN-6: an UNACKED journal displaced by a new takeover parks here so
    /// the new session's persists can't overwrite undelivered records. Holds at
    /// most one journal: a second displacement before delivery overwrites it
    /// (requires two abandoned sessions with zero phone contact between — and
    /// starting a new loan itself requires a reachable phone, which triggers a
    /// recovery send first).
    static let orphanKey = "PodLoanJournalStore.orphanJournal"

    public static func persist(_ journal: PodLoanJournal?) {
        guard let data = journal?.encoded() else { return }
        defaults.set(data, forKey: key)
    }

    public static func clear() {
        defaults.removeObject(forKey: key)
    }

    public static func persistedData() -> Data? {
        return defaults.data(forKey: key)
    }

    /// Move the active slot's journal (if any) to the orphan slot. Called
    /// before a new takeover creates its journal.
    public static func orphanActiveJournal() {
        guard let data = defaults.data(forKey: key) else { return }
        defaults.set(data, forKey: orphanKey)
        defaults.removeObject(forKey: key)
    }

    /// Undelivered journal data awaiting recovery hand-back: the orphan slot
    /// first (displaced by a newer session), else the active slot.
    public static func recoverableData() -> Data? {
        return defaults.data(forKey: orphanKey) ?? defaults.data(forKey: key)
    }

    /// The phone acked a recovered journal — clear the slot it came from
    /// (mirror of recoverableData()'s preference order).
    public static func clearRecoverable() {
        if defaults.data(forKey: orphanKey) != nil {
            defaults.removeObject(forKey: orphanKey)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
