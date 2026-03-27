//
//  AlertManagementView.swift
//  Loop
//
//  Created by Nathaniel Hamming on 2022-09-09.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopCore
import LoopKit
import LoopKitUI
import HealthKit

struct AlertManagementView: View {
    @Environment(\.appName) private var appName
    @Environment(\.guidanceColors) private var guidanceColors

    @ObservedObject private var checker: AlertPermissionsChecker
    @ObservedObject private var alertMuter: AlertMuter

    @State private var showMuteAlertOptions: Bool = false
    @State private var showHowMuteAlertWork: Bool = false
    
    // Local state variables for immediate UI updates
    @State private var isPreBolusRemindersEnabled: Bool = UserDefaults.standard.preBolusRemindersEnabled
    @State private var isLowBGNotificationsEnabled: Bool = UserDefaults.standard.lowBGNotificationsEnabled
    @State private var isNightLowBGNotificationsEnabled: Bool = UserDefaults.standard.nightLowBGNotificationsEnabled

    private var formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute]
        return formatter
    }()

    private var formattedSelectedDuration: Binding<String> {
        Binding(
            get: { formatter.string(from: alertMuter.configuration.duration)! },
            set: { newValue in
                guard let selectedDurationIndex = formatterDurations.firstIndex(of: newValue)
                else { return }
                DispatchQueue.main.async {
                    // avoid publishing during view update
                    alertMuter.configuration.startTime = Date()
                    alertMuter.configuration.duration = AlertMuter.allowedDurations[selectedDurationIndex]
                }
            }
        )
    }

    private var formatterDurations: [String] {
        AlertMuter.allowedDurations.compactMap { formatter.string(from: $0) }
    }
    
    // Binding wrappers for UserDefaults
    private var missedMealNotificationsEnabled: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.missedMealNotificationsEnabled },
            set: { UserDefaults.standard.missedMealNotificationsEnabled = $0 }
        )
    }
    
    private var prebolusDelayCriterion: Binding<Int> {
        Binding(
            get: { UserDefaults.standard.prebolusDelayCriterion },
            set: { UserDefaults.standard.prebolusDelayCriterion = $0 }
        )
    }
    
    private var warningSnooze: Binding<Int> {
        Binding(
            get: { UserDefaults.standard.warningSnooze },
            set: { UserDefaults.standard.warningSnooze = $0 }
        )
    }
    
    private var dontWarnIfLater: Binding<Int> {
        Binding(
            get: { UserDefaults.standard.dontWarnIfLater },
            set: { UserDefaults.standard.dontWarnIfLater = $0 }
        )
    }
    
    private var dontWarnIfSooner: Binding<Int> {
        Binding(
            get: { UserDefaults.standard.dontWarnIfSooner },
            set: { UserDefaults.standard.dontWarnIfSooner = $0 }
        )
    }
    
    private var delayAfterCarbEntry: Binding<Int> {
        Binding(
            get: { UserDefaults.standard.delayAfterCarbEntry },
            set: { UserDefaults.standard.delayAfterCarbEntry = $0 }
        )
    }
    
    private var nightWarningOffset: Binding<Int> {
        Binding(
            get: { UserDefaults.standard.nightWarningOffset },
            set: { UserDefaults.standard.nightWarningOffset = $0 }
        )
    }
    
    private var dayWarningOffset: Binding<Int> {
        Binding(
            get: { UserDefaults.standard.dayWarningOffset },
            set: { UserDefaults.standard.dayWarningOffset = $0 }
        )
    }

    public init(checker: AlertPermissionsChecker, alertMuter: AlertMuter = AlertMuter()) {
        self.checker = checker
        self.alertMuter = alertMuter
    }

    var body: some View {
        List {
            alertPermissionsSection
            if FeatureFlags.criticalAlertsEnabled {
                muteAlertsSection
            }
            if FeatureFlags.missedMealNotifications {
                missedMealAlertSection
            }
            preBolusRemindersSection
            lowBGAlertSection
            testNotificationSection
        }
        .onAppear {
            // Sync local state on appear
            isPreBolusRemindersEnabled = UserDefaults.standard.preBolusRemindersEnabled
            isLowBGNotificationsEnabled = UserDefaults.standard.lowBGNotificationsEnabled
        }
        .navigationTitle(NSLocalizedString("Alert Management", comment: "Title of alert management screen"))
        .onDisappear {
            // Trigger recalculation when user exits the view
            NotificationCenter.default.post(
                name: .LoopDataUpdated,
                object: nil,
                userInfo: [LoopDataManager.LoopUpdateContextKey: LoopDataManager.LoopUpdateContext.preferences.rawValue]
            )
        }
    }
    
    private var footerView: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 8) {
                Image("phone")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 64, maxHeight: 64)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        String(
                            format: NSLocalizedString(
                                "%1$@ APP SOUNDS",
                                comment: "App sounds title text (1: app name)"
                            ),
                            appName.uppercased()
                        )
                    )
                    
                    Text(
                        String(
                            format: NSLocalizedString(
                                "While mute alerts is on, all alerts from your %1$@ app including Critical and Time Sensitive alerts will temporarily display without sounds and will vibrate only.",
                                comment: "App sounds descriptive text (1: app name)"
                            ),
                            appName
                        )
                    )
                }
            }
            
            HStack(alignment: .top, spacing: 8) {
                Image("hardware")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 64, maxHeight: 64)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("HARDWARE SOUNDS")
                    
                    Text("While mute alerts is on, your insulin pump and CGM hardware may still sound.")
                }
            }
            
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "moon.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 64, maxHeight: 48)
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("IOS FOCUS MODES")
                    
                    Text(
                        String(
                            format: NSLocalizedString(
                                "If iOS Focus Mode is ON and Mute Alerts is OFF, Critical Alerts will still be delivered and non-Critical Alerts will be silenced until %1$@ is added to each Focus mode as an Allowed App.",
                                comment: "Focus modes descriptive text (1: app name)"
                            ),
                            appName
                        )
                    )
                }
            }
        }
        .padding(.top)
    }

    private var alertPermissionsSection: some View {
        Section(footer: DescriptiveText(label: String(format: NSLocalizedString("Notifications give you important %1$@ app information without requiring you to open the app.", comment: "Alert Permissions descriptive text (1: app name)"), appName))) {
            NavigationLink(destination:
                            NotificationsCriticalAlertPermissionsView(mode: .flow, checker: checker))
            {
                HStack {
                    Text(NSLocalizedString("Alert Permissions", comment: "Alert Permissions button text"))
                    if checker.showWarning ||
                        checker.notificationCenterSettings.scheduledDeliveryEnabled {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.critical)
                    }
                }
            }
            
            NavigationLink(destination: LiveActivityManagementView())
            {
                    Text(NSLocalizedString("Live activity", comment: "Alert Permissions live activity"))
            }
        }
    }

    @ViewBuilder
    private var muteAlertsSection: some View {
        Section(footer: footerView) {
            if !alertMuter.configuration.shouldMute {
                howMuteAlertsWork
                Button(action: { showMuteAlertOptions = true }) {
                    HStack {
                        muteAlertIcon
                        Text(NSLocalizedString("Mute All Alerts", comment: "Label for button to mute all alerts"))
                    }
                }
                .actionSheet(isPresented: $showMuteAlertOptions) {
                   muteAlertOptionsActionSheet
                }
            } else {
                Button(action: alertMuter.unmuteAlerts) {
                    HStack {
                        unmuteAlertIcon
                        Text(NSLocalizedString("Tap to Unmute Alerts", comment: "Label for button to unmute all alerts"))
                    }
                }
                HStack {
                    Text(NSLocalizedString("All alerts muted until", comment: "Label for when mute alert will end"))
                    Spacer()
                    Text(alertMuter.formattedEndTime)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var muteAlertIcon: some View {
        Image(systemName: "speaker.slash.fill")
            .foregroundColor(.white)
            .padding(5)
            .background(guidanceColors.warning)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var unmuteAlertIcon: some View {
        Image(systemName: "speaker.wave.2.fill")
            .foregroundColor(.white)
            .padding(.vertical, 5)
            .padding(.horizontal, 2)
            .background(guidanceColors.warning)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var howMuteAlertsWork: some View {
        Button(action: { showHowMuteAlertWork = true }) {
            HStack {
                Text(NSLocalizedString("Frequently asked questions about alerts", comment: "Label for link to see frequently asked questions"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "info.circle")
                    .font(.body)
            }
        }
        .sheet(isPresented: $showHowMuteAlertWork) {
            HowMuteAlertWorkView()
        }
    }

    private var muteAlertOptionsActionSheet: ActionSheet {
        var muteAlertDurationOptions: [SwiftUI.Alert.Button] = formatterDurations.map { muteAlertDuration in
            .default(Text(muteAlertDuration),
                     action: { formattedSelectedDuration.wrappedValue =  muteAlertDuration })
        }
        muteAlertDurationOptions.append(.cancel())

        return ActionSheet(
            title: Text(NSLocalizedString("Mute All Alerts Temporarily", comment: "Title for mute alert duration selection action sheet")),
            message: Text(NSLocalizedString("No alerts or alarms will sound while muted. Select how long you would you like to mute for.", comment: "Message for mute alert duration selection action sheet")),
            buttons: muteAlertDurationOptions)
    }
    
    private var missedMealAlertSection: some View {
        Section(footer: DescriptiveText(label: NSLocalizedString("When enabled, Loop can notify you when it detects a meal that wasn't logged.", comment: "Description of missed meal notifications."))) {
            Toggle(NSLocalizedString("Missed Meal Notifications", comment: "Title for missed meal notifications toggle"), isOn: missedMealNotificationsEnabled)
        }
    }
    
    private var preBolusRemindersSection: some View {
        Section(footer: DescriptiveText(label: NSLocalizedString("When enabled, Loop will remind you to eat when you prebolus.", comment: "Description of prebolus notifications."))) {
            Toggle(NSLocalizedString("Pre-bolus Reminders", comment: "Title for pre-bolus reminders toggle"), isOn: $isPreBolusRemindersEnabled)
                .onChange(of: isPreBolusRemindersEnabled) { newValue in
                    UserDefaults.standard.preBolusRemindersEnabled = newValue
                }
            
            if isPreBolusRemindersEnabled {
                HStack {
                    Text(NSLocalizedString("Prebolus Definition", comment: "Label for prebolus delay criterion"))
                    Spacer()
                    Picker("Delay Criterion", selection: prebolusDelayCriterion) {
                        ForEach(1..<39) {
                            Text("\($0) min").tag($0)
                        }
                    }
                    .pickerStyle(WheelPickerStyle())
                    .frame(height: 40)
                }
            }
        }
    }
    
    private var lowBGAlertSection: some View {
        Section(footer: DescriptiveText(label: NSLocalizedString("When enabled, Loop can notify you when it predicts a low glucose event.", comment: "Description of low BG notifications."))) {
            Toggle(NSLocalizedString("Predicted Low Warnings", comment: "Title for low BG warning enablement"), isOn: $isLowBGNotificationsEnabled)
                .onChange(of: isLowBGNotificationsEnabled) { newValue in
                    UserDefaults.standard.lowBGNotificationsEnabled = newValue
                }
            
            if isLowBGNotificationsEnabled {
                VStack(spacing: 16) {
                    HStack {
                        Text("Day low warning offset")
                        Spacer()
                        Picker("Daytime low warning offset", selection: dayWarningOffset) {
                            ForEach(0..<15) {
                                Text("\($0) mg/dl").tag($0)
                            }
                        }
                        .pickerStyle(WheelPickerStyle())
                        .frame(width: 115, height: 50)
                    }
                    
                    Toggle(NSLocalizedString("Enable warnings overnight", comment: "Title for enabling low BG warnings overnight"), isOn: $isNightLowBGNotificationsEnabled)
                        .onChange(of: isNightLowBGNotificationsEnabled) { newValue in
                            UserDefaults.standard.nightLowBGNotificationsEnabled = newValue
                        }
                    
                    if isNightLowBGNotificationsEnabled {
                        
                        HStack {
                            Text("Night low warning offset")
                            Spacer()
                            Picker("Nighttime low warning offset", selection: nightWarningOffset) {
                                ForEach(0..<15) {
                                    Text("\($0) mg/dl").tag($0)
                                }
                            }
                            .pickerStyle(WheelPickerStyle())
                            .frame(width: 115, height: 50)
                        }
                    }
                    HStack {
                        Text("Warning snooze time")
                        Spacer()
                        Picker("Warning snooze time", selection: warningSnooze) {
                            ForEach(1..<30) {
                                Text("\($0) min").tag($0)
                            }
                        }
                        .pickerStyle(WheelPickerStyle())
                        .frame(width: 100, height: 40)
                    }
                    
                    HStack {
                        Text("Don't warn if farther than")
                        Spacer()
                        Picker("Don't warn if farther than", selection: dontWarnIfLater) {
                            ForEach(20..<120) {
                                Text("\($0) min").tag($0)
                            }
                        }
                        .pickerStyle(WheelPickerStyle())
                        .frame(width: 100, height: 40)
                    }
                    
                    HStack {
                        Text("Don't warn if closer than")
                        Spacer()
                        Picker("Don't warn if sooner than", selection: dontWarnIfSooner) {
                            ForEach(1..<15) {
                                Text("\($0) min").tag($0)
                            }
                        }
                        .pickerStyle(WheelPickerStyle())
                        .frame(width: 100, height: 40)
                    }
                    
                    HStack {
                        Text("Delay after carb entry")
                        Spacer()
                        Picker("Delay after carb entry", selection: delayAfterCarbEntry) {
                            ForEach(10..<31) {
                                Text("\($0) min").tag($0)
                            }
                        }
                        .pickerStyle(WheelPickerStyle())
                        .frame(width: 100, height: 40)
                    }

                }
            }
        }
    }
    
    private var testNotificationSection: some View {
        Section(footer: DescriptiveText(label: NSLocalizedString("Test notifications to verify they appear in both foreground and background.", comment: "Description of test notifications."))) {
            Button(action: {
                // Test prebolus reminder notification
                let notification = UNMutableNotificationContent()
                notification.title = "Reminder to eat"
                notification.body =  "Test Notification"
                notification.sound = .default
                notification.interruptionLevel = .timeSensitive
                notification.categoryIdentifier = LoopNotificationCategory.lowBGWarning.rawValue //todo: check this is the right category for a test
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5.0, repeats: false)
                
                let request = UNNotificationRequest(
                    identifier: "test-notification",
                    content: notification,
                    trigger: trigger  // 5 second delay
                )
                
                UNUserNotificationCenter.current().add(request)
            }) {
                HStack {
                    Text(NSLocalizedString("Send Test Notification", comment: "Button to test notifications"))
                    Spacer()
                    Image(systemName: "bell.badge.fill")
                        .foregroundColor(.accentColor)
                }
            }
        }
    }
}

extension UserDefaults {
    private enum Key: String {
        case missedMealNotificationsEnabled = "com.loopkit.Loop.MissedMealNotificationsEnabled"
        case preBolusRemindersEnabled = "com.loopkit.Loop.preBolusRemindersEnabled"
        case prebolusDelayCriterion = "com.loopkit.Loop.prebolusDelayCriterion"
        case lowBGNotificationsEnabled = "com.loopkit.Loop.lowBGNotificationsEnabled"
        case warningSnooze = "com.loopkit.Loop.warningSnooze"
        case dontWarnIfLater = "com.loopkit.Loop.dontWarnIfLater"
        case dontWarnIfSooner = "com.loopkit.Loop.dontWarnIfSooner"
        case delayAfterCarbEntry = "com.loopkit.Loop.delayAfterCarbEntry"
        case nightLowBGNotificationsEnabled = "com.loopkit.Loop.nightLowBGNotificationsEnabled"
        case nightWarningOffset = "com.loopkit.Loop.nightWarningOffset"
        case dayWarningOffset = "com.loopkit.Loop.dayWarningOffset"
    }
    
    var missedMealNotificationsEnabled: Bool {
        get { object(forKey: Key.missedMealNotificationsEnabled.rawValue) as? Bool ?? false }
        set { set(newValue, forKey: Key.missedMealNotificationsEnabled.rawValue) }
    }
    
    var preBolusRemindersEnabled: Bool {
        get { object(forKey: Key.preBolusRemindersEnabled.rawValue) as? Bool ?? true }
        set { set(newValue, forKey: Key.preBolusRemindersEnabled.rawValue) }
    }
    
    var prebolusDelayCriterion: Int {
        get { object(forKey: Key.prebolusDelayCriterion.rawValue) as? Int ?? 5 }
        set { set(newValue, forKey: Key.prebolusDelayCriterion.rawValue) }
    }
    
    var lowBGNotificationsEnabled: Bool {
        get { object(forKey: Key.lowBGNotificationsEnabled.rawValue) as? Bool ?? false }
        set { set(newValue, forKey: Key.lowBGNotificationsEnabled.rawValue) }
    }
    
    var warningSnooze: Int {
        get { object(forKey: Key.warningSnooze.rawValue) as? Int ?? 9 }
        set {
            print("**Setting warningSnooze to \(newValue)")
            set(newValue, forKey: Key.warningSnooze.rawValue)
        }
    }
    
    var dontWarnIfLater: Int {
        get { object(forKey: Key.dontWarnIfLater.rawValue) as? Int ?? 45 }
        set { set(newValue, forKey: Key.dontWarnIfLater.rawValue) }
    }
    
    var dontWarnIfSooner: Int {
        get { object(forKey: Key.dontWarnIfSooner.rawValue) as? Int ?? 5 }
        set { set(newValue, forKey: Key.dontWarnIfSooner.rawValue) }
    }
    
    var delayAfterCarbEntry: Int {
        get { object(forKey: Key.delayAfterCarbEntry.rawValue) as? Int ?? 30 }
        set { set(newValue, forKey: Key.delayAfterCarbEntry.rawValue) }
    }
    var nightLowBGNotificationsEnabled: Bool {
        get { object(forKey: Key.nightLowBGNotificationsEnabled.rawValue) as? Bool ?? true }
        set { set(newValue, forKey: Key.nightLowBGNotificationsEnabled.rawValue) }
    }
    
    var nightWarningOffset: Int {
        get { object(forKey: Key.nightWarningOffset.rawValue) as? Int ?? 10 }
        set { set(newValue, forKey: Key.nightWarningOffset.rawValue) }
    }
    
    var dayWarningOffset: Int {
        get { object(forKey: Key.dayWarningOffset.rawValue) as? Int ?? 5 }
        set { set(newValue, forKey: Key.dayWarningOffset.rawValue) }
    }
}

struct AlertManagementView_Previews: PreviewProvider {
    static var previews: some View {
        AlertManagementView(checker: AlertPermissionsChecker(), alertMuter: AlertMuter())
    }
}
