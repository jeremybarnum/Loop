//
//  AlertManagementView.swift
//  Loop
//
//  Created by Nathaniel Hamming on 2022-09-09.
//  Copyright 2022 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKitUI
import LoopKit

struct AlertManagementView: View {
    @Environment(\.appName) private var appName
    @Environment(\.guidanceColors) private var guidanceColors

    @ObservedObject private var checker: AlertPermissionsChecker
    @ObservedObject private var alertMuter: AlertMuter

    @State private var showMuteAlertOptions: Bool = false
    @State private var showHowMuteAlertWork: Bool = false
    @State private var islowBGNotificationEnabled: Bool = UserDefaults.standard.lowBGNotificationsEnabled //local state
    @State private var isPreBolusReminderEnabled: Bool = UserDefaults.standard.preBolusReminderEnabled // Local state


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
    
    private var missedMealNotificationsEnabled: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.missedMealNotificationsEnabled },
            set: { enabled in
                UserDefaults.standard.missedMealNotificationsEnabled = enabled
            }
        )
    }
    
    private var lowBGNotificationsEnabled: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.lowBGNotificationsEnabled },
            set: { enabled in
                UserDefaults.standard.lowBGNotificationsEnabled = enabled
            }
        )
    }
    
  /*  private var lowBGWarningThreshold: Binding<Int> {
        Binding(
            get: { UserDefaults.standard.lowBGWarningThreshold },
            set: { newValue in
                UserDefaults.standard.lowBGWarningThreshold = newValue
                NotificationCenter.default.post(
                    name: .LoopDataUpdated,
                    object: nil,
                    userInfo: [LoopDataManager.LoopUpdateContextKey: LoopDataManager.LoopUpdateContext.preferences.rawValue]
                )
                print("SET lowBGWarningThreshold in View: \(newValue)")
               }
            
            )
        
    }*/
    private var warningSnooze: Binding<Int> {
        Binding(
            get: { UserDefaults.standard.warningSnooze },
            set: { newValue in
                UserDefaults.standard.warningSnooze = newValue
                NotificationCenter.default.post(
                    name: .LoopDataUpdated,
                    object: nil,
                    userInfo: [LoopDataManager.LoopUpdateContextKey: LoopDataManager.LoopUpdateContext.preferences.rawValue]
                )
                print("SET warningSnooze in View: \(newValue)")
               }
            
            )
        
    }
    
    private var dontWarnIfLater: Binding<Int> {
        Binding(
            get: { UserDefaults.standard.dontWarnIfLater },
            set: { newValue in
                UserDefaults.standard.dontWarnIfLater = newValue
                NotificationCenter.default.post(
                    name: .LoopDataUpdated,
                    object: nil,
                    userInfo: [LoopDataManager.LoopUpdateContextKey: LoopDataManager.LoopUpdateContext.preferences.rawValue]
                )
                print("SET dontWarnIfLater in View: \(newValue)")
               }
            
            )
        
    }
    private var dontWarnIfSooner: Binding<Int> {
        Binding(
            get: { UserDefaults.standard.dontWarnIfSooner },
            set: { newValue in
                UserDefaults.standard.dontWarnIfSooner = newValue
                NotificationCenter.default.post(
                    name: .LoopDataUpdated,
                    object: nil,
                    userInfo: [LoopDataManager.LoopUpdateContextKey: LoopDataManager.LoopUpdateContext.preferences.rawValue]
                )
                print("SET dontWarnIfSooner in View: \(newValue)")
               }
            
            )
        
    }
    private var delayAfterCarbEntry: Binding<Int> {
        Binding(
            get: { UserDefaults.standard.delayAfterCarbEntry },
            set: { newValue in
                UserDefaults.standard.delayAfterCarbEntry = newValue
                NotificationCenter.default.post(
                    name: .LoopDataUpdated,
                    object: nil,
                    userInfo: [LoopDataManager.LoopUpdateContextKey: LoopDataManager.LoopUpdateContext.preferences.rawValue]
                )
                print("SET delayAfterCarbEntry in View: \(newValue)")
               }
            
            )
        
    }
    
    private var preBolusReminderEnabled: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.preBolusReminderEnabled },
            set: { enabled in
                UserDefaults.standard.preBolusReminderEnabled = enabled
            }
        )
    }
    
    private var prebolusDelayCriterion: Binding<Int> {
        Binding(
            get: { UserDefaults.standard.prebolusDelayCriterion },
            set: { newValue in
                UserDefaults.standard.prebolusDelayCriterion = newValue
            }
        )
    }

    public init(checker: AlertPermissionsChecker, alertMuter: AlertMuter = AlertMuter()) {
        self.checker = checker
        self.alertMuter = alertMuter
    }

    var body: some View {
        
        
        List {
            lowBGAlertSection
            preBolusReminderSection
            alertPermissionsSection
            if FeatureFlags.criticalAlertsEnabled {
                muteAlertsSection
                }
            missedMealAlertSection
            testNotificationSection
            nightscoutTestSection
        }
        .onAppear {
                    isPreBolusReminderEnabled = UserDefaults.standard.preBolusReminderEnabled // Sync local state on appear
                islowBGNotificationEnabled = UserDefaults.standard.lowBGNotificationsEnabled// Sync local state on appear
                }
        .navigationTitle(NSLocalizedString("Alert Management", comment: "Title of alert management screen"))
        
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
    
    /*private var slowAbsorptionAlertSection: some View {
        Section(footer: DescriptiveText(label: NSLocalizedString("When enabled, Loop can notify you when it sees carbs absorbing slowly, risking a crash.", comment: "Description of slow absorption notifications."))) {
            Toggle(NSLocalizedString("Slow Absorption Notifications", comment: "Title for slow absorption notification toggle"), isOn: slowAbsorptionNotificationsEnabled)
        }
    }*/
    private var lowBGAlertSection: some View {
        Group{
            // First section with toggle and its footer
            Section(footer: DescriptiveText(label: NSLocalizedString("When enabled, Loop can notify you when it sees carbs absorbing slowly or too much insulin on board, risking a crash.", comment: "Description of low bg notifications."))) {
                Toggle(NSLocalizedString("Predicted low warnings", comment: "Title for low BG warning enablement"), isOn: $islowBGNotificationEnabled)
                    .onChange(of: islowBGNotificationEnabled) { newValue in
                        UserDefaults.standard.lowBGNotificationsEnabled = newValue
                    }
            }
            
            // Individual sections for each setting when enabled
            if islowBGNotificationEnabled {
               /* Section(footer: DescriptiveText(label: "Warn if prediction drops below this level")) {
                    HStack {
                        Text("Warning threshold")
                        Spacer()
                        Picker("Warning Threshold", selection: lowBGWarningThreshold) {
                            ForEach(40..<110) {
                                Text("\($0) mg/dl").tag($0)
                            }
                        }
                        .pickerStyle(WheelPickerStyle())
                        .frame(width: 120, height: 40)
                    }.frame(height:30)
                }*/
                
                Section(footer: DescriptiveText(label: "Wait at least this long between warnings")) {
                    HStack {
                        Text("Warning snooze time")
                        Spacer()
                        Picker("Warning snooze time", selection: warningSnooze) {
                            ForEach(1..<30) {
                                Text("\($0) min").tag($0)
                            }
                        }
                        .pickerStyle(WheelPickerStyle())
                        .frame(width: 120, height: 40)
                    }.frame(height:30)
                }
                
                Section(footer: DescriptiveText(label: "Don't warn if low is farther than this - things change")) {
                    HStack {
                        Text("Don't warn if farther than")
                        Spacer()
                        Picker("Don't warn if farther than", selection: dontWarnIfLater) {
                            ForEach(20..<120) {
                                Text("\($0) min").tag($0)
                            }
                        }
                        .pickerStyle(WheelPickerStyle())
                        .frame(width: 120, height: 40)
                    }.frame(height:30)
                }
                Section(footer: DescriptiveText(label: "Don't warn if low is closer than this - not worth it")) {
                    HStack {
                        Text("Don't warn if closer than")
                        Spacer()
                        Picker("Don't warn if sooner than", selection: dontWarnIfSooner) {
                            ForEach(1..<15) {
                                Text("\($0) min").tag($0)
                            }
                        }
                        .pickerStyle(WheelPickerStyle())
                        .frame(width: 120, height: 40)
                    }.frame(height:30)
                }
                
                Section(footer: DescriptiveText(label: "Wait to start warning until new carbs have some absorption history.")) {
                    HStack {
                        Text("Delay after carb entry")
                        Spacer()
                        Picker("Delay after carb entry", selection: delayAfterCarbEntry) {
                            ForEach(10..<31) {
                                Text("\($0) min").tag($0)
                            } //TODO: what if multiple entries?
                        }
                        .pickerStyle(WheelPickerStyle())
                        .frame(width: 120, height: 40)
                    }.frame(height:30)
                }
            }
        }
    }
    
    private var preBolusReminderSection: some View {
        Section(footer: DescriptiveText(label: NSLocalizedString("When enabled, Loop will note you when you prebolus and remind you to eat.", comment: "Description of prebolus notifications."))) {
            Toggle(NSLocalizedString("Pre-bolus reminders", comment: "Title for pre-bolus reminders toggle"), isOn: $isPreBolusReminderEnabled) // Bind to local state
                .onChange(of: isPreBolusReminderEnabled) { newValue in // Use local state for change tracking
                    UserDefaults.standard.preBolusReminderEnabled = newValue // Update UserDefaults
                }
            if isPreBolusReminderEnabled { // Check local state
                HStack {
                    Text(NSLocalizedString("Prebolus Definition", comment: "Label for prebolus delay criterion"))
                    Spacer()
                    Picker("Delay Criterion", selection: prebolusDelayCriterion) {
                        ForEach(1..<39) {
                            Text("\($0) min").tag($0)
                        }
                    }//starting at 1 to help with testing 
                    .pickerStyle(WheelPickerStyle())
                    .frame(height: 40) // Set the desired height
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
                notification.body = String(format: NSLocalizedString("You declared %@ carbs with a %@hr absorption time.", comment: ""), "25", "2.0")
                notification.sound = .default
                notification.interruptionLevel = .timeSensitive
                notification.categoryIdentifier = LoopNotificationCategory.prebolusReminder.rawValue
                
                let request = UNNotificationRequest(
                    identifier: "test-prebolus-reminder",
                    content: notification,
                    trigger: nil  // Immediate notification
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
    
    private var nightscoutTestSection: some View {
        Section(header: Text("Nightscout Test")) {
            Button(action: {
                let notificationName  = Notification.Name.lowBGWarning
                let messagePayload = "Test Message"
                let messageTime = Date()
                let userInfo: [String: Any] = [
                    "warningMessage": messagePayload,
                    "warningTimestamp": messageTime
            ]
                NotificationCenter.default.post(
                    name: notificationName, // The name you defined
                    object: nil,            // Sending nil as the object simplifies things
                    userInfo: userInfo
                )
                print("**Posting notification: \(userInfo)-")
            }) {
                Text("Test Nightscout")
            }
        }
        
    }
}

extension UserDefaults {
    private enum Key: String {
        case missedMealNotificationsEnabled = "com.loopkit.Loop.MissedMealNotificationsEnabled"
        case lowBGNotificationsEnabled = "com.loopkit.Loop.lowBGNotificationsEnabled"
        case preBolusReminderEnabled = "com.loopkit.Loop.preBolusReminderEnabled"
        case prebolusDelayCriterion = "com.loopkit.Loop.prebolusDelayCriterion"
       // case lowBGWarningThreshold = "com.loopkit.Loop.lowBGWarningThreshold"
        case warningSnooze = "com.loopkit.Loop.warningSnooze"
        case dontWarnIfLater = "com.loopkit.Loop.dontWarnIfLater"
        case dontWarnIfSooner = "com.loopkit.Loop.dontWarnIfSooner"
        case delayAfterCarbEntry = "com.loopkit.Loop.delayAfterCarbEntry"
    }
    
    var missedMealNotificationsEnabled: Bool {
        get {
            return object(forKey: Key.missedMealNotificationsEnabled.rawValue) as? Bool ?? false
        }
        set {
            set(newValue, forKey: Key.missedMealNotificationsEnabled.rawValue)
        }
    }
    
    var lowBGNotificationsEnabled: Bool {
        get {
            return object(forKey: Key.lowBGNotificationsEnabled.rawValue) as? Bool ?? false
        }
        set {
            set(newValue, forKey: Key.lowBGNotificationsEnabled.rawValue)
        }
    }
    
    /*var lowBGWarningThreshold: Int {
            get {
                return object(forKey: Key.lowBGWarningThreshold.rawValue) as? Int ?? 70
            }
            set {
                set(newValue, forKey: Key.lowBGWarningThreshold.rawValue)
            }
        }*/
    
    var warningSnooze: Int {
            get {
                return object(forKey: Key.warningSnooze.rawValue) as? Int ?? 10
            }
            set {
                set(newValue, forKey: Key.warningSnooze.rawValue)
            }
        }
    
    var dontWarnIfLater: Int {
            get {
                return object(forKey: Key.dontWarnIfLater.rawValue) as? Int ?? 45
            }
            set {
                set(newValue, forKey: Key.dontWarnIfLater.rawValue)
            }
        }
    
    
    var dontWarnIfSooner: Int {
            get {
                return object(forKey: Key.dontWarnIfSooner.rawValue) as? Int ?? 10
            }
            set {
                set(newValue, forKey: Key.dontWarnIfSooner.rawValue)
            }
        }
    
    var delayAfterCarbEntry: Int {
            get {
                return object(forKey: Key.delayAfterCarbEntry.rawValue) as? Int ?? 30
            }
            set {
                set(newValue, forKey: Key.delayAfterCarbEntry.rawValue)
            }
        }
    
    var preBolusReminderEnabled: Bool {
        get {
            return object(forKey: Key.preBolusReminderEnabled.rawValue) as? Bool ?? false
        }
        set {
            set(newValue, forKey: Key.preBolusReminderEnabled.rawValue)
        }
    }
    
    var prebolusDelayCriterion: Int {
        get {
            return object(forKey: Key.prebolusDelayCriterion.rawValue) as? Int ?? 5 // Default value
        }
        set {
            set(newValue, forKey: Key.prebolusDelayCriterion.rawValue)
        }
    }

}

struct AlertManagementView_Previews: PreviewProvider {
    static var previews: some View {
        AlertManagementView(checker: AlertPermissionsChecker(), alertMuter: AlertMuter())
    }
}
