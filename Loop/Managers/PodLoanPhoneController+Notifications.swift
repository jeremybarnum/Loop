//
//  PodLoanPhoneController+Notifications.swift
//  Loop
//
//  Part of PodLoanPhoneController (see PodLoanPhoneController.swift). Split by concern; stored properties live in the core class.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore
import UserNotifications
import os.log

extension PodLoanPhoneController {

    // MARK: - Notifications (the COMPLETE alarm inventory)

    func scheduleNotification(id: String, title: String, body: String, delay: TimeInterval, repeats: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: repeats)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancelNotification(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// Both directions of a protocol skew — the watch sent something this build cannot decode,
    /// or the watch nacked something this build sent — mean the same thing to the user, so they
    /// share one notice. The cause is named with "may", because the decode failure is all that
    /// was observed: a mismatched build is the designed reason (the envelope hard-guards
    /// protocolVersion and throws rather than guessing) and by far the likeliest one, but a
    /// corrupt payload produces the identical symptom. The check is worth naming because
    /// installing the two halves is genuinely fiddly and a half-updated pair is the common
    /// self-inflicted case.
    ///
    /// Latched once per skew and released on the first clean decode, for the reason the
    /// records-not-saved warning is latched: offers resend every 15 s, and `issueNotice` mints
    /// a fresh UUID per post, so an unlatched warning would stack a new banner every resend
    /// rather than replacing the last one.
    func warnProtocolMismatch() {
        os_log("Loan protocol skew — payload undecodable in this build", log: log, type: .error)
        guard !hasWarnedProtocolMismatch else { return }
        hasWarnedProtocolMismatch = true
        deps.issueNotice(
            NSLocalizedString("Watch Message Unreadable", comment: "Phone notice title when a loan message cannot be decoded"),
            NSLocalizedString("Loop can't read a message from the watch. The apps may be on different builds — check both are current.", comment: "Phone notice body when a loan message cannot be decoded"))
    }

    /// Shared by the three paths that end an unverifiable session: the pod never answered, it
    /// answered without an insulin total, or there was no start-of-loan baseline to compare
    /// against. Those are three internal reasons for one user-facing fact, and previously each
    /// shipped its own wording — so the same situation read as three different problems. The
    /// second sentence is the house phrasing already used elsewhere in this file for a latched
    /// loop, which is what makes it accurate here: nothing reopens it automatically.
    static let sessionUnverifiedBody = NSLocalizedString(
        "Loop couldn't verify the watch's insulin delivery. Automatic dosing is off until you turn it back on.",
        comment: "Phone notice when a watch session's insulin could not be verified after reclaim")

    /// RETIRED (ruled 2026-08-15). It repeated hourly, forever, to say that automatic dosing was
    /// paused — a state the user can see, and often one they chose. Worse, it was armed from four
    /// sites where the thing actually worth standing over (a booked placeholder) did not exist.
    /// Its two cancel sites survive as no-ops so an upgrade retires anything already scheduled.
    func armPausedReminder() {}


    // MARK: - Standing reminders (ruled 2026-08-15)
    //
    // Two conditions can outlive the notice that announced them, and both stop mattering after
    // the insulin action duration:
    //
    //   1. A PLACEHOLDER bolus stands in your IOB for insulin the pod proved it delivered and
    //      no record explains. You may be able to correct it from memory — but only while the
    //      dose is still within the manual-entry date picker's ±6 h reach, which is the same 6 h
    //      after which it has decayed out anyway. Two rungs, then silence.
    //   2. An AUDIT OPENED THE LOOP and nothing in this codebase closes it. One reminder only:
    //      the first tells someone who missed the original notice; a second would be nagging
    //      about a decision they have now made.

    /// Arm the placeholder ladder. Cancelled wherever the booking retires.
    func armPlaceholderReminders(units: Double, bookedAt: Date) {
        let amount = String(format: "%.2f", units)
        let time = Self.reminderTimeFormatter.string(from: bookedAt)
        for (index, delay) in ReminderLadder.placeholderRungs.enumerated() {
            scheduleNotification(
                id: NotificationID.placeholder(index),
                title: NSLocalizedString("Estimated Insulin Still Booked", comment: "Phone reminder title while an unexplained gap bolus stands"),
                body: String(format: NSLocalizedString("%1$@ U is booked as a bolus at %2$@ — the pod's total, not real timing. If you remember the session, correct it in Insulin Delivery.", comment: "Phone reminder body while an unexplained gap bolus stands (1: units, 2: time booked)"), amount, time),
                delay: delay, repeats: false)
        }
    }

    func cancelPlaceholderReminders() {
        for index in ReminderLadder.placeholderRungs.indices {
            cancelNotification(id: NotificationID.placeholder(index))
        }
    }

    /// Arm the single open-loop reminder. Best-effort cancelled: the phone cannot observe the
    /// user flipping Closed Loop back on from outside its own work, so this is also cleared at
    /// launch and at the next grant if dosing is already enabled by then. Worst case is one
    /// stale reminder, which is why this is a single rung and not a ladder.
    func armOpenLoopReminder() {
        scheduleNotification(
            id: NotificationID.openLoop,
            title: NSLocalizedString("Closed Loop Is Off", comment: "Phone reminder title after an audit opened the loop"),
            body: NSLocalizedString("Loop couldn't verify the watch session's insulin, so it stopped dosing. Turn Closed Loop back on when you're ready.", comment: "Phone reminder body after an audit opened the loop"),
            delay: ReminderLadder.openLoopDelay, repeats: false)
    }

    /// Clear the open-loop reminder if the user has already closed the loop themselves.
    func cancelOpenLoopReminderIfLoopClosed() {
        guard deps.settings().dosingEnabled else { return }
        cancelNotification(id: NotificationID.openLoop)
    }

    private static let reminderTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

}
