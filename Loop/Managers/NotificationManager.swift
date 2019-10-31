//
//  NotificationManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/30/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit
import UserNotifications
import LoopKit

struct NotificationManager {

    enum Action: String {
        case retryBolus
    }

    enum UserInfoKey: String {
        case bolusAmount
        case bolusStartDate
    }

    private static var notificationCategories: Set<UNNotificationCategory> {
        var categories = [UNNotificationCategory]()

        let retryBolusAction = UNNotificationAction(
            identifier: Action.retryBolus.rawValue,
            title: NSLocalizedString("Retry", comment: "The title of the notification action to retry a bolus command"),
            options: []
        )

        categories.append(UNNotificationCategory(
            identifier: LoopNotificationCategory.bolusFailure.rawValue,
            actions: [retryBolusAction],
            intentIdentifiers: [],
            options: []
        ))

        return Set(categories)
    }

    static func authorize(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()

        center.delegate = delegate
        center.requestAuthorization(options: [.badge, .sound, .alert]) { (granted, error) in
            guard granted else { return }
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized else { return }
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
        center.setNotificationCategories(notificationCategories)
    }


    // MARK: - Notifications

    static func sendBolusFailureNotification(for error: Error, units: Double, at startDate: Date) {
        let notification = UNMutableNotificationContent()

        notification.title = NSLocalizedString("Bolus", comment: "The notification title for a bolus failure")

        let sentenceFormat = NSLocalizedString("%@.", comment: "Appends a full-stop to a statement")

        switch error {
        case let error as SetBolusError:
            notification.subtitle = error.errorDescriptionWithUnits(units)

            let body = [error.failureReason, error.recoverySuggestion].compactMap({ $0 }).map({
                String(format: sentenceFormat, $0)
            }).joined(separator: " ")

            notification.body = body
        case let error as LocalizedError:
            if let subtitle = error.errorDescription {
                notification.subtitle = subtitle
            }
            let message = [error.failureReason, error.recoverySuggestion].compactMap({ $0 }).map({
                String(format: sentenceFormat, $0)
            }).joined(separator: "\n")
            notification.body = message.isEmpty ? String(describing: error) : message
        default:
            notification.body = error.localizedDescription
        }

        notification.sound = .default

        if startDate.timeIntervalSinceNow >= TimeInterval(minutes: -5) {
            notification.categoryIdentifier = LoopNotificationCategory.bolusFailure.rawValue
        }

        notification.userInfo = [
            UserInfoKey.bolusAmount.rawValue: units,
            UserInfoKey.bolusStartDate.rawValue: startDate
        ]

        let request = UNNotificationRequest(
            // Only support 1 bolus notification at once
            identifier: LoopNotificationCategory.bolusFailure.rawValue,
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // Cancel any previous scheduled notifications in the Loop Not Running category
    static func clearPendingNotificationRequests() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    static func scheduleLoopNotRunningNotifications() {
        // Give a little extra time for a loop-in-progress to complete
        let gracePeriod = TimeInterval(minutes: 0.5)

        for minutes: Double in [20, 40, 60, 120] {
            let notification = UNMutableNotificationContent()
            let failureInterval = TimeInterval(minutes: minutes)

            let formatter = DateComponentsFormatter()
            formatter.maximumUnitCount = 1
            formatter.allowedUnits = [.hour, .minute]
            formatter.unitsStyle = .full

            if let failueIntervalString = formatter.string(from: failureInterval)?.localizedLowercase {
                notification.body = String(format: NSLocalizedString("Loop has not completed successfully in %@", comment: "The notification alert describing a long-lasting loop failure. The substitution parameter is the time interval since the last loop"), failueIntervalString)
            }

            notification.title = NSLocalizedString("Loop Failure", comment: "The notification title for a loop failure")
            notification.sound = .default
            notification.categoryIdentifier = LoopNotificationCategory.loopNotRunning.rawValue
            notification.threadIdentifier = LoopNotificationCategory.loopNotRunning.rawValue

            let request = UNNotificationRequest(
                identifier: "\(LoopNotificationCategory.loopNotRunning.rawValue)\(failureInterval)",
                content: notification,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: failureInterval + gracePeriod,
                    repeats: false
                )
            )

            UNUserNotificationCenter.current().add(request)
        }
    }

    static func clearLoopNotRunningNotifications() {
        // Clear out any existing not-running notifications
        UNUserNotificationCenter.current().getDeliveredNotifications { (notifications) in
            let loopNotRunningIdentifiers = notifications.filter({
                $0.request.content.categoryIdentifier == LoopNotificationCategory.loopNotRunning.rawValue
            }).map({
                $0.request.identifier
            })

            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: loopNotRunningIdentifiers)
        }
    }

    static func sendPumpBatteryLowNotification() {
        let notification = UNMutableNotificationContent()

        notification.title = NSLocalizedString("Pump Battery Low", comment: "The notification title for a low pump battery")
        notification.body = NSLocalizedString("Change the pump battery immediately", comment: "The notification alert describing a low pump battery")
        notification.sound = .default
        notification.categoryIdentifier = LoopNotificationCategory.pumpBatteryLow.rawValue

        let request = UNNotificationRequest(
            identifier: LoopNotificationCategory.pumpBatteryLow.rawValue,
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    static func clearPumpBatteryLowNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [LoopNotificationCategory.pumpBatteryLow.rawValue])
    }

    static func sendPumpReservoirEmptyNotification() {
        let notification = UNMutableNotificationContent()

        notification.title = NSLocalizedString("Pump Reservoir Empty", comment: "The notification title for an empty pump reservoir")
        notification.body = NSLocalizedString("Change the pump reservoir now", comment: "The notification alert describing an empty pump reservoir")
        notification.sound = .default
        notification.categoryIdentifier = LoopNotificationCategory.pumpReservoirEmpty.rawValue

        let request = UNNotificationRequest(
            // Not a typo: this should replace any pump reservoir low notifications
            identifier: LoopNotificationCategory.pumpReservoirLow.rawValue,
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    static func sendPumpReservoirLowNotificationForAmount(_ units: Double, andTimeRemaining remaining: TimeInterval?) {
        let notification = UNMutableNotificationContent()

        notification.title = NSLocalizedString("Pump Reservoir Low", comment: "The notification title for a low pump reservoir")

        let unitsString = NumberFormatter.localizedString(from: NSNumber(value: units), number: .decimal)

        let intervalFormatter = DateComponentsFormatter()
        intervalFormatter.allowedUnits = [.hour, .minute]
        intervalFormatter.maximumUnitCount = 1
        intervalFormatter.unitsStyle = .full
        intervalFormatter.includesApproximationPhrase = true
        intervalFormatter.includesTimeRemainingPhrase = true

        if let remaining = remaining, let timeString = intervalFormatter.string(from: remaining) {
            notification.body = String(format: NSLocalizedString("%1$@ U left: %2$@", comment: "Low reservoir alert with time remaining format string. (1: Number of units remaining)(2: approximate time remaining)"), unitsString, timeString)
        } else {
            notification.body = String(format: NSLocalizedString("%1$@ U left", comment: "Low reservoir alert format string. (1: Number of units remaining)"), unitsString)
        }

        notification.sound = .default
        notification.categoryIdentifier = LoopNotificationCategory.pumpReservoirLow.rawValue

        let request = UNNotificationRequest(
            identifier: LoopNotificationCategory.pumpReservoirLow.rawValue,
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    static func clearPumpReservoirNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [LoopNotificationCategory.pumpReservoirLow.rawValue])
    }

    static func sendCarbCorrectionNotification(_ carbCorrectionNotification: CarbCorrectionNotification) {
        let notification = UNMutableNotificationContent()
        let gramsSuggested = carbCorrectionNotification.grams
        let gramsRemaining = carbCorrectionNotification.gramsRemaining
        let lowPredictedIn = carbCorrectionNotification.lowPredictedIn
        let correctionType = carbCorrectionNotification.type
        let imminentLowTimeInterval = TimeInterval(minutes: 15)

        notification.title = NSLocalizedString("Carb Correction", comment: "The notification title for carb correction")

        let gramsString = NumberFormatter.localizedString(from: NSNumber(value: gramsSuggested), number: .none)
        let gramsRemainingString = NumberFormatter.localizedString(from: NSNumber(value: gramsRemaining), number: .none)

        let intervalFormatter = DateComponentsFormatter()
        intervalFormatter.allowedUnits = [.hour, .minute]
        intervalFormatter.maximumUnitCount = 1
        intervalFormatter.unitsStyle = .full
        intervalFormatter.includesApproximationPhrase = false
        intervalFormatter.includesTimeRemainingPhrase = false

        var lowPredictedInString: String = "-"
        if let timeString = intervalFormatter.string(from: lowPredictedIn) {
            lowPredictedInString = timeString
        }

        switch correctionType {
        case .noCorrection:
            notification.body = String(format: NSLocalizedString("-", comment: "No carb correction needed format string."))
        case .correction:
            if lowPredictedIn < imminentLowTimeInterval {
                notification.body = String(format: NSLocalizedString("%1$@ g Recommended", comment: "Carb correction for imminent low alert format string. (1: Recommended correction grams)"), gramsString)
            } else {
                notification.body = String(format: NSLocalizedString("%1$@ g Recommended to Treat Low Predicted in %2$@", comment: "Carb correction and time to predicted low alert format string. (1: Recommended correction grams)(2: Time to predicted low)"), gramsString, lowPredictedInString)
            }
        case .warning:
            notification.body = String(format: NSLocalizedString("Warning: Slow Absorbing Carbs (%1$@ g Remaining)", comment: "Slow carb absorption warning format string. (1: Correction needed if remaining carbs expire)"), gramsRemainingString)
        case .correctionPlusWarning:
            if lowPredictedIn < imminentLowTimeInterval {
                notification.body = String(format: NSLocalizedString("%1$@ g Recommended, Warning: Slow Absorbing Carbs (%2$@ g Remaining)", comment: "Carb correction for imminent low alert format string. (1: Recommended correction grams)(2: Correction needed if remaining carbs expire)"), gramsString, gramsRemainingString)
            } else {
                notification.body = String(format: NSLocalizedString("%1$@ g Recommended to Treat Low Predicted in %2$@. Warning: Slow Absorbing Carbs (%3$@ g Remaining)", comment: "Carb correction with time to predicted low alert format string. (1: Recommended correction grams)(2: Time to predicted low)(3: Correction needed if remaining carbs expire)"), gramsString, lowPredictedInString, gramsRemainingString)
            }
        default:
            notification.body = String(format: NSLocalizedString("--", comment: "Error format string"))
        }

        notification.sound = UNNotificationSound.default()
        notification.categoryIdentifier = Category.carbCorrectionRecommended.rawValue
        notification.badge = NSNumber(value: gramsSuggested)

        let request = UNNotificationRequest(
            identifier: Category.carbCorrectionRecommended.rawValue,
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    static func clearCarbCorrectionNotification() {
        let notification = UNMutableNotificationContent()
        notification.categoryIdentifier = Category.carbCorrectionRecommended.rawValue
        notification.badge = NSNumber(value: 0)
        notification.sound = nil
        let clearBadge = UNNotificationRequest(
            identifier: Category.carbCorrectionRecommended.rawValue,
            content: notification,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(clearBadge)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Category.carbCorrectionRecommended.rawValue])
    }

    static func sendCarbCorrectionNotificationBadge(_ grams: Int) {
        let notification = UNMutableNotificationContent()
        notification.categoryIdentifier = Category.carbCorrectionRecommended.rawValue
        notification.badge = NSNumber(value: grams)
        notification.sound = nil
        let setBadge = UNNotificationRequest(
            identifier: Category.carbCorrectionRecommended.rawValue,
            content: notification,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(setBadge)
    }

}
