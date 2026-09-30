//
//  ComplicationController.swift
//  WatchApp Extension
//
//  Created by Nathan Racklyeft on 8/29/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import ClockKit
import HealthKit
import LoopKit
import WatchKit
import LoopCore
import os.log

final class ComplicationController: NSObject, CLKComplicationDataSource {
    
    private let log = OSLog(category: "ComplicationController")

    // MARK: - Timeline Configuration
    
    func getSupportedTimeTravelDirections(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationTimeTravelDirections) -> Void) {
        handler([.backward])
    }
    
    func getTimelineStartDate(for complication: CLKComplication, withHandler handler: @escaping (Date?) -> Void) {
        if let date = ExtensionDelegate.shared().loopManager.activeContext?.glucoseDate {
            handler(date)
        } else {
            handler(nil)
        }
    }
    
    func getTimelineEndDate(for complication: CLKComplication, withHandler handler: @escaping (Date?) -> Void) {
        if let date = ExtensionDelegate.shared().loopManager.activeContext?.glucoseDate {
            handler(date)
        } else {
            handler(nil)
        }
    }
    
    func getPrivacyBehavior(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationPrivacyBehavior) -> Void) {
        handler(.hideOnLockScreen)
    }
    
    // MARK: - Timeline Population

    private let chartManager = ComplicationChartManager()

    private func updateChartManagerIfNeeded(for complication: CLKComplication, completion: @escaping () -> Void) {
        // #95 (2026-08-07): DO NOT ask CLKComplicationServer.activeComplications here. This method
        // runs INSIDE the server's own data-source callbacks (getCurrentTimelineEntry /
        // getTimelineEntries, invoked on MAIN in response to reloadTimeline), and
        // `activeComplications` is a SYNCHRONOUS round-trip to that same server — a re-entrant
        // query into a service that is mid-callback into us. That is a deadlock shape, and it is
        // queue-independent: main stops forever with every app queue idle, which is exactly the
        // 6.5-minute wedge of 2026-08-07 23:24 (force-quit) and the post-carb kills — the
        // context-update fan-out (flow dismiss -> requestContextUpdate reply -> reloadTimeline)
        // landed here 0.7-1.6s after each carb save. The callback already HAS the complication;
        // its family answers the only question this guard was asking, with no server round-trip.
        guard
            #available(watchOSApplicationExtension 5.0, *),
            complication.family == .graphicRectangular
        else {
            completion()
            return
        }

        ExtensionDelegate.shared().loopManager.generateChartData { chartData in
            self.chartManager.data = chartData
            completion()
        }
    }

    func makeChart() -> UIImage? {
        // c.f. https://developer.apple.com/design/human-interface-guidelines/watchos/icons-and-images/complication-images/
        let size: CGSize = {
            switch WKInterfaceDevice.current().screenBounds.width {
            case let x where x > 180:  // 44mm
                return CGSize(width: 171.0, height: 54.0)
            default: // 40mm
                return CGSize(width: 150.0, height: 47.0)
            }
        }()

        let scale = WKInterfaceDevice.current().screenScale
        return chartManager.renderChartImage(size: size, scale: scale)
    }

    func getCurrentTimelineEntry(for complication: CLKComplication, withHandler handler: (@escaping (CLKComplicationTimelineEntry?) -> Void)) {
        RuntimeStateLog.mark("complication.getCurrentTimelineEntry")
        if let value = SportValue(rawValue: complication.identifier) {
            return sportCurrentEntry(value, family: complication.family, handler: handler)
        }
        updateChartManagerIfNeeded(for: complication, completion: {
            let entry: CLKComplicationTimelineEntry?
            
            let timelineDate = Date()
            
            self.log.default("Updating current complication timeline entry")
            
            if let context = ExtensionDelegate.shared().loopManager.activeContext,
                let template = CLKComplicationTemplate.templateForFamily(complication.family,
                                                                         from: context,
                                                                         at: timelineDate,
                                                                         recencyInterval: LoopCoreConstants.inputDataRecencyInterval,
                                                                         chartGenerator: self.makeChart)
            {
                switch complication.family {
                case .graphicRectangular:
                    break
                default:
                    template.tintColor = .tintColor
                }
                entry = CLKComplicationTimelineEntry(date: timelineDate, complicationTemplate: template)
            } else {
                entry = nil
            }

            handler(entry)
        })
    }
    
    func getTimelineEntries(for complication: CLKComplication, after date: Date, limit: Int, withHandler handler: (@escaping ([CLKComplicationTimelineEntry]?) -> Void)) {
        RuntimeStateLog.mark("complication.getTimelineEntries")
        if let value = SportValue(rawValue: complication.identifier) {
            return sportFutureEntries(value, family: complication.family, after: date, handler: handler)
        }
        updateChartManagerIfNeeded(for: complication) {
            let entries: [CLKComplicationTimelineEntry]?
            
            guard let context = ExtensionDelegate.shared().loopManager.activeContext,
                let glucoseDate = context.glucoseDate else
            {
                handler(nil)
                return
            }
            
            var futureChangeDates: [Date] = [
                // Stale glucose date: just a second after glucose expires
                glucoseDate + LoopCoreConstants.inputDataRecencyInterval + 1,
            ]
            
            if let loopLastRunDate = context.loopLastRunDate {
                let freshnessCategories = [
                    LoopCompletionFreshness.fresh,
                    LoopCompletionFreshness.aging,
                    LoopCompletionFreshness.stale
                    ].compactMap( { $0.maxAge })
                futureChangeDates.append(contentsOf: freshnessCategories.map { loopLastRunDate + $0 + 1})
            }
            
            entries = futureChangeDates.filter { $0 > date }.compactMap({ (futureChangeDate) -> CLKComplicationTimelineEntry? in
                if let template = CLKComplicationTemplate.templateForFamily(complication.family,
                                                                            from: context,
                                                                            at: futureChangeDate,
                                                                            recencyInterval: LoopCoreConstants.inputDataRecencyInterval,
                                                                            chartGenerator: self.makeChart)
                {
                    template.tintColor = UIColor.tintColor
                    self.log.default("Adding complication timeline entry for date %{public}@", String(describing: futureChangeDate))
                    return CLKComplicationTimelineEntry(date: futureChangeDate, complicationTemplate: template)
                } else {
                    return nil
                }
            })
            
            handler(entries)
        }
    }

    // MARK: - Placeholder Templates

    func getLocalizableSampleTemplate(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationTemplate?) -> Void) {
        if let value = SportValue(rawValue: complication.identifier) {
            return handler(Self.sportSampleTemplate(value, family: complication.family))
        }
        let template = getLocalizableSampleTemplate(for: complication.family)
        handler(template)
    }

    func getLocalizableSampleTemplate(for family: CLKComplicationFamily) -> CLKComplicationTemplate? {
        let glucoseAndTrendText = CLKSimpleTextProvider.localizableTextProvider(withStringsFileTextKey: "120↘︎")
        let glucoseText = CLKSimpleTextProvider.localizableTextProvider(withStringsFileTextKey: "120")
        let timeText = CLKSimpleTextProvider.localizableTextProvider(withStringsFileTextKey: "3MIN")

        switch family {
        case .modularSmall:
            return CLKComplicationTemplateModularSmallStackText(line1TextProvider: glucoseAndTrendText, line2TextProvider: timeText)
        case .modularLarge:
            return CLKComplicationTemplateModularLargeTallBody(headerTextProvider: timeText, bodyTextProvider: glucoseAndTrendText)
        case .circularSmall:
            return CLKComplicationTemplateCircularSmallSimpleText(textProvider: glucoseAndTrendText)
        case .extraLarge:
            return CLKComplicationTemplateExtraLargeStackText(line1TextProvider: glucoseAndTrendText, line2TextProvider: timeText)
        case .utilitarianSmall, .utilitarianSmallFlat:
            return CLKComplicationTemplateUtilitarianSmallFlat(textProvider: glucoseAndTrendText)
        case .utilitarianLarge:
            let eventualGlucoseText = CLKSimpleTextProvider.localizableTextProvider(withStringsFileTextKey: "75")
            return CLKComplicationTemplateUtilitarianLargeFlat(textProvider: CLKSimpleTextProvider.localizableTextProvider(withStringsFileFormatKey: "UtilitarianLargeFlat", textProviders: [glucoseAndTrendText, eventualGlucoseText, CLKTimeTextProvider(date: Date())]))
        case .graphicCorner:
            if #available(watchOSApplicationExtension 5.0, *) {
                let template = CLKComplicationTemplateGraphicCornerStackText(innerTextProvider: timeText, outerTextProvider: glucoseAndTrendText)
                timeText.tintColor = .tintColor
                return template
            } else {
                return nil
            }
        case .graphicCircular:
            if #available(watchOSApplicationExtension 5.0, *) {
                return CLKComplicationTemplateGraphicCircularOpenGaugeSimpleText(
                    gaugeProvider: CLKSimpleGaugeProvider(style: .fill, gaugeColor: .tintColor, fillFraction: 1),
                    bottomTextProvider: glucoseText,
                    centerTextProvider: CLKSimpleTextProvider(text: "↘︎")
                )
            } else {
                return nil
            }
        case .graphicBezel:
            if #available(watchOSApplicationExtension 5.0, *) {
                guard let circularTemplate = getLocalizableSampleTemplate(for: .graphicCircular) as? CLKComplicationTemplateGraphicCircular else {
                    fatalError("\(#function) invoked with .graphicCircular must return a subclass of CLKComplicationTemplateGraphicCircular")
                }
                return CLKComplicationTemplateGraphicBezelCircularText(circularTemplate: circularTemplate, textProvider: timeText)
            } else {
                return nil
            }
        case .graphicRectangular:
            if #available(watchOSApplicationExtension 5.0, *) {
                // TODO: Better placeholder image here
                return CLKComplicationTemplateGraphicRectangularLargeImage(textProvider: glucoseAndTrendText, imageProvider: CLKFullColorImageProvider(fullColorImage: UIImage()))

            } else {
                return nil
            }
        case .graphicExtraLarge:
            if #available(watchOSApplicationExtension 5.0, *) {
                return CLKComplicationTemplateGraphicExtraLargeCircularOpenGaugeSimpleText(
                    gaugeProvider: CLKSimpleGaugeProvider(style: .fill, gaugeColor: .tintColor, fillFraction: 1),
                    bottomTextProvider: glucoseText,
                    centerTextProvider: CLKSimpleTextProvider(text: "↘︎")
                )
            } else {
                return nil
            }
        @unknown default:
            return nil
        }
    }
}

// MARK: - Sport Mode: IOB, COB, eventual BG and BG → eventual, sized for the Utility face
//
// Four small complications beside stock's own, each fitting a Utility corner (utilitarianSmall /
// SmallFlat) and the Utility bottom slot (utilitarianLarge). During a loan they read the watch's
// own loop (the glance's mirror); otherwise the phone's context — the same sources the glance
// uses, so the corner never disagrees with the Start screen.

extension ComplicationController {

    enum SportValue: String, CaseIterable {
        case iob = "sport.iob"
        case cob = "sport.cob"
        case eventual = "sport.eventual"
        case glucoseToEventual = "sport.glucoseToEventual"

        var displayName: String {
            switch self {
            case .iob: return NSLocalizedString("IOB", comment: "Complication name: insulin on board")
            case .cob: return NSLocalizedString("COB", comment: "Complication name: carbs on board")
            case .eventual: return NSLocalizedString("Eventual BG", comment: "Complication name: eventual glucose")
            case .glucoseToEventual: return NSLocalizedString("BG → Eventual", comment: "Complication name: current and eventual glucose")
            }
        }
    }

    static let sportFamilies: [CLKComplicationFamily] = [.utilitarianSmall, .utilitarianSmallFlat, .utilitarianLarge]

    func getComplicationDescriptors(handler: @escaping ([CLKComplicationDescriptor]) -> Void) {
        // The default descriptor keeps every face that already shows stock's complication.
        handler([CLKComplicationDescriptor(identifier: CLKDefaultComplicationIdentifier, displayName: "Loop",
                                           supportedFamilies: CLKComplicationFamily.allCases)]
                + SportValue.allCases.map {
                    CLKComplicationDescriptor(identifier: $0.rawValue, displayName: $0.displayName,
                                              supportedFamilies: Self.sportFamilies)
                })
    }

    struct SportReading {
        var glucose: HKQuantity?
        var glucoseDate: Date?
        var iob: Double?
        var cob: Double?
        var eventual: HKQuantity?
        var unit: HKUnit
        /// When the loop that produced iob/cob/eventual last completed.
        var loopDate: Date?
    }

    /// The watch's own loop during a loan, the phone's context otherwise.
    func sportReading(_ completion: @escaping (SportReading?) -> Void) {
        let delegate = ExtensionDelegate.shared()
        let context = delegate.loopManager.activeContext
        let unit = context?.displayGlucoseUnit ?? .milligramsPerDeciliter
        let session = delegate.stockLoopSession
        if session.loanController.isLoanActiveNonBlocking, let data = session.stack.loopManager.mirroredGlanceData {
            session.stack.loopManager.glanceCarbsOnBoard { cob in
                completion(SportReading(glucose: data.glucose, glucoseDate: data.glucoseDate, iob: data.iob, cob: cob,
                                        eventual: data.eventual, unit: unit, loopDate: data.lastLoopCompleted))
            }
            return
        }
        guard let context else { return completion(nil) }
        completion(SportReading(glucose: context.glucose, glucoseDate: context.glucoseDate, iob: context.iob, cob: context.cob,
                                eventual: context.eventualGlucose, unit: unit, loopDate: context.loopLastRunDate))
    }

    static func sportTemplate(_ value: SportValue, family: CLKComplicationFamily, reading r: SportReading, at date: Date) -> CLKComplicationTemplate? {
        let recency = LoopCoreConstants.inputDataRecencyInterval
        let loopFresh = r.loopDate.map { date.timeIntervalSince($0) <= recency } ?? false
        let glucoseFresh = r.glucoseDate.map { date.timeIntervalSince($0) <= recency } ?? false
        let formatter = NumberFormatter.glucoseFormatter(for: r.unit)
        func glucose(_ q: HKQuantity?) -> String? { q.flatMap { formatter.string(from: $0.doubleValue(for: r.unit)) } }

        let iob = loopFresh ? r.iob.map { String(format: "%.1f", $0) } : nil
        let cob = loopFresh ? r.cob.map { String(format: "%.0f", $0) } : nil
        let eventual = loopFresh ? glucose(r.eventual) : nil
        let current = glucoseFresh ? glucose(r.glucose) : nil
        let dash = "—"

        let small: String
        let large: String
        switch value {
        case .iob:
            small = iob.map { "\($0)U" } ?? "IOB \(dash)"
            large = "IOB \(iob.map { "\($0) U" } ?? dash)"
        case .cob:
            small = cob.map { "\($0)g" } ?? "COB \(dash)"
            large = "COB \(cob.map { "\($0) g" } ?? dash)"
        case .eventual:
            small = "→\(eventual ?? dash)"
            large = "Eventually \(eventual ?? dash)"
        case .glucoseToEventual:
            small = "\(current ?? dash)→\(eventual ?? dash)"
            large = "BG \(current ?? dash) → \(eventual ?? dash)"
        }

        let text = CLKSimpleTextProvider(text: family == .utilitarianLarge ? large : small, shortText: small)
        let template: CLKComplicationTemplate
        switch family {
        case .utilitarianSmall, .utilitarianSmallFlat:
            template = CLKComplicationTemplateUtilitarianSmallFlat(textProvider: text)
        case .utilitarianLarge:
            template = CLKComplicationTemplateUtilitarianLargeFlat(textProvider: text)
        default:
            return nil
        }
        switch LoopCompletionFreshness(lastCompletion: r.loopDate, at: date) {
        case .fresh: template.tintColor = .tintColor
        case .aging: template.tintColor = .agingColor
        case .stale: template.tintColor = .staleColor
        }
        return template
    }

    func sportCurrentEntry(_ value: SportValue, family: CLKComplicationFamily, handler: @escaping (CLKComplicationTimelineEntry?) -> Void) {
        sportReading { reading in
            let now = Date()
            let entry = reading.flatMap { r in
                Self.sportTemplate(value, family: family, reading: r, at: now)
                    .map { CLKComplicationTimelineEntry(date: now, complicationTemplate: $0) }
            }
            DispatchQueue.main.async { handler(entry) }
        }
    }

    /// One future entry: the moment the reading goes stale and its values turn to dashes.
    func sportFutureEntries(_ value: SportValue, family: CLKComplicationFamily, after date: Date, handler: @escaping ([CLKComplicationTimelineEntry]?) -> Void) {
        sportReading { reading in
            let recency = LoopCoreConstants.inputDataRecencyInterval
            let stalePoints = [reading?.loopDate, reading?.glucoseDate].compactMap { $0?.addingTimeInterval(recency + 1) }
            let entries = reading.map { r in
                stalePoints.filter { $0 > date }.sorted().compactMap { at in
                    Self.sportTemplate(value, family: family, reading: r, at: at)
                        .map { CLKComplicationTimelineEntry(date: at, complicationTemplate: $0) }
                }
            }
            DispatchQueue.main.async { handler(entries) }
        }
    }

    static func sportSampleTemplate(_ value: SportValue, family: CLKComplicationFamily) -> CLKComplicationTemplate? {
        let sample = SportReading(glucose: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 120), glucoseDate: Date(),
                                  iob: 1.2, cob: 24, eventual: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 128),
                                  unit: .milligramsPerDeciliter, loopDate: Date())
        return sportTemplate(value, family: family, reading: sample, at: Date())
    }
}
