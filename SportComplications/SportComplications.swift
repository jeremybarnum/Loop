//
//  SportComplications.swift
//  SportComplications (watchOS widget extension)
//
//  IOB, COB, eventual BG and BG → eventual as WidgetKit complications. ClockKit, which the
//  watch app's own complication uses, is deprecated and current watchOS never asked it for
//  additional complications (2026-09-30), so these live here. The watch app publishes a
//  SportComplicationSnapshot to the shared app group and asks WidgetKit to reload; this
//  extension only reads and formats it.
//

import SwiftUI
import WidgetKit

struct SportEntry: TimelineEntry {
    let date: Date
    let snapshot: SportComplicationSnapshot?
}

struct SportProvider: TimelineProvider {
    func placeholder(in context: Context) -> SportEntry {
        SportEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SportEntry) -> Void) {
        completion(SportEntry(date: Date(), snapshot: context.isPreview ? .sample : SportComplicationSnapshot.load()))
    }

    /// Now, then each moment a value goes stale (it turns to a dash). The watch app reloads on new data.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SportEntry>) -> Void) {
        let now = Date()
        let snapshot = SportComplicationSnapshot.load()
        let moments = [now] + (snapshot?.staleMoments(after: now) ?? [])
        completion(Timeline(entries: moments.map { SportEntry(date: $0, snapshot: snapshot) }, policy: .never))
    }
}

struct SportComplicationView: View {
    let kind: SportComplicationSnapshot.Kind
    let entry: SportEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: SportComplicationSnapshot { entry.snapshot ?? SportComplicationSnapshot() }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(snapshot.line(kind, at: entry.date))
        case .accessoryCorner:
            Text(cornerCenter)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .widgetLabel { Text(cornerLabel) }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(circleTop).font(.system(size: 11, weight: .medium))
                    Text(circleValue).font(.system(size: 17, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
                .widgetAccentable()
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.headline).widgetAccentable()
                Text(snapshot.line(kind, at: entry.date)).font(.body)
                if let loopDate = snapshot.loopDate {
                    Text(loopDate, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            Text(snapshot.short(kind, at: entry.date))
        }
    }

    // A corner holds ~4 characters in the middle and a curved label along the edge.
    private var cornerCenter: String {
        let d = entry.date
        switch kind {
        case .iob: return snapshot.iobText(at: d) ?? SportComplicationSnapshot.dash
        case .cob: return snapshot.cobText(at: d) ?? SportComplicationSnapshot.dash
        case .eventual: return snapshot.eventualText(at: d) ?? SportComplicationSnapshot.dash
        case .glucoseToEventual: return snapshot.currentText(at: d) ?? SportComplicationSnapshot.dash
        }
    }

    private var cornerLabel: String {
        switch kind {
        case .iob: return "IOB U"
        case .cob: return "COB g"
        case .eventual: return "Eventual"
        case .glucoseToEventual: return "→ \(snapshot.eventualText(at: entry.date) ?? SportComplicationSnapshot.dash)"
        }
    }

    private var circleTop: String {
        switch kind {
        case .iob: return "IOB"
        case .cob: return "COB"
        case .eventual: return "→"
        case .glucoseToEventual: return snapshot.currentText(at: entry.date) ?? SportComplicationSnapshot.dash
        }
    }

    private var circleValue: String {
        switch kind {
        case .glucoseToEventual: return "→\(snapshot.eventualText(at: entry.date) ?? SportComplicationSnapshot.dash)"
        default: return cornerCenter
        }
    }
}

// `Widget` requires `init()`, so each complication is its own small type over one shared body.
protocol SportComplicationWidget: Widget {
    static var kind: SportComplicationSnapshot.Kind { get }
}

extension SportComplicationWidget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind.rawValue, provider: SportProvider()) { entry in
            SportComplicationView(kind: Self.kind, entry: entry)
        }
        .configurationDisplayName(Self.kind.title)
        // A plain String: an interpolated literal becomes formatted text, which WidgetKit
        // rejects with a fatal error for `description` (crashed in the simulator, 2026-09-30).
        .description(Self.kind.widgetDescription)
        .supportedFamilies([.accessoryInline, .accessoryCorner, .accessoryCircular, .accessoryRectangular])
    }
}

struct SportIOBWidget: SportComplicationWidget { static let kind = SportComplicationSnapshot.Kind.iob }
struct SportCOBWidget: SportComplicationWidget { static let kind = SportComplicationSnapshot.Kind.cob }
struct SportEventualWidget: SportComplicationWidget { static let kind = SportComplicationSnapshot.Kind.eventual }
struct SportGlucoseToEventualWidget: SportComplicationWidget { static let kind = SportComplicationSnapshot.Kind.glucoseToEventual }

@main
struct SportComplicationsBundle: WidgetBundle {
    var body: some Widget {
        SportIOBWidget()
        SportCOBWidget()
        SportEventualWidget()
        SportGlucoseToEventualWidget()
    }
}
