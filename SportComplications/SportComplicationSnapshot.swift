//
//  SportComplicationSnapshot.swift
//  Loop
//
//  Compiled into BOTH the watch extension (writer) and the SportComplications widget extension
//  (reader). The watch app publishes what its complications show — its own loop during a loan,
//  the phone's otherwise — into the shared app-group defaults; the widget only formats it.
//  Plain values, no LoopKit: the widget extension links nothing of Loop's.
//

import Foundation

struct SportComplicationSnapshot: Codable, Equatable {
    /// Glucose values are already in the display unit; `mmol` says which.
    var glucose: Double?
    var glucoseDate: Date?
    var iob: Double?
    var cob: Double?
    var eventual: Double?
    /// When the loop that produced iob/cob/eventual last completed.
    var loopDate: Date?
    var mmol: Bool = false

    /// Older than this, a value is shown as a dash rather than as if it were current.
    static let recency: TimeInterval = 15 * 60

    static let defaultsKey = "SportComplicationSnapshot"

    /// The app group both extensions share, from each one's own Info.plist.
    static var sharedDefaults: UserDefaults? {
        (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String).flatMap { UserDefaults(suiteName: $0) }
    }

    static func load(from defaults: UserDefaults? = sharedDefaults) -> SportComplicationSnapshot? {
        defaults?.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save(to defaults: UserDefaults? = Self.sharedDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults?.set(data, forKey: Self.defaultsKey) }
    }

    static let sample = SportComplicationSnapshot(glucose: 120, glucoseDate: Date(), iob: 1.2, cob: 24, eventual: 128,
                                                  loopDate: Date(), mmol: false)

    // MARK: - What each complication says, at a given moment

    enum Kind: String, CaseIterable {
        case iob = "SportIOB"
        case cob = "SportCOB"
        case eventual = "SportEventual"
        case glucoseToEventual = "SportGlucoseToEventual"

        var title: String {
            switch self {
            case .iob: return "IOB"
            case .cob: return "COB"
            case .eventual: return "Eventual BG"
            case .glucoseToEventual: return "BG → Eventual"
            }
        }

        var widgetDescription: String { "Loop " + title }
    }

    static let dash = "—"

    func loopFresh(at date: Date) -> Bool { loopDate.map { date.timeIntervalSince($0) <= Self.recency } ?? false }
    func glucoseFresh(at date: Date) -> Bool { glucoseDate.map { date.timeIntervalSince($0) <= Self.recency } ?? false }

    func glucoseText(_ value: Double?) -> String? {
        value.map { mmol ? String(format: "%.1f", $0) : String(format: "%.0f", $0) }
    }

    func iobText(at date: Date) -> String? { loopFresh(at: date) ? iob.map { String(format: "%.1f", $0) } : nil }
    func cobText(at date: Date) -> String? { loopFresh(at: date) ? cob.map { String(format: "%.0f", $0) } : nil }
    func eventualText(at date: Date) -> String? { loopFresh(at: date) ? glucoseText(eventual) : nil }
    func currentText(at date: Date) -> String? { glucoseFresh(at: date) ? glucoseText(glucose) : nil }

    /// The short form, for a corner or a circle: "1.2", "24", "→128", "120→128". No units: there
    /// is no room for them on the wrist, and the label says what the number is.
    func short(_ kind: Kind, at date: Date) -> String {
        switch kind {
        case .iob: return iobText(at: date) ?? Self.dash
        case .cob: return cobText(at: date) ?? Self.dash
        case .eventual: return "→\(eventualText(at: date) ?? Self.dash)"
        case .glucoseToEventual: return "\(currentText(at: date) ?? Self.dash)→\(eventualText(at: date) ?? Self.dash)"
        }
    }

    /// The labelled form, for an inline slot (the Utility face's corners and bottom).
    func line(_ kind: Kind, at date: Date) -> String {
        switch kind {
        case .iob: return "IOB \(iobText(at: date) ?? Self.dash)"
        case .cob: return "COB \(cobText(at: date) ?? Self.dash)"
        case .eventual: return "Eventually \(eventualText(at: date) ?? Self.dash)"
        case .glucoseToEventual: return "BG \(currentText(at: date) ?? Self.dash) → \(eventualText(at: date) ?? Self.dash)"
        }
    }

    /// The moments after `date` at which something turns to a dash — the timeline's later entries.
    func staleMoments(after date: Date) -> [Date] {
        [loopDate, glucoseDate].compactMap { $0?.addingTimeInterval(Self.recency + 1) }.filter { $0 > date }.sorted()
    }
}
