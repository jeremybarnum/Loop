//
//  AlertManagementView.swift
//  Loop
//
//  Created by Nathaniel Hamming on 2022-09-09.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI

struct AlertManagementView: View {
    @Environment(\.appName) private var appName
    @Environment(\.guidanceColors) private var guidanceColors

    @ObservedObject private var checker: AlertPermissionsChecker
    @ObservedObject private var alertMuter: AlertMuter

    @State private var showMuteAlertOptions: Bool = false
    @State private var showHowMuteAlertWork: Bool = false
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
    
    private var slowAbsorptionNotificationsEnabled: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.slowAbsorptionNotificationsEnabled },
            set: { enabled in
                UserDefaults.standard.slowAbsorptionNotificationsEnabled = enabled
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
            alertPermissionsSection
            if FeatureFlags.criticalAlertsEnabled {
                muteAlertsSection
                
            }
            missedMealAlertSection
            slowAbsorptionAlertSection
            preBolusReminderSection
        }
        .onAppear {
                    isPreBolusReminderEnabled = UserDefaults.standard.preBolusReminderEnabled // Sync local state on appear
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
    
    private var slowAbsorptionAlertSection: some View {
        Section(footer: DescriptiveText(label: NSLocalizedString("When enabled, Loop can notify you when it sees carbs absorbing slowly, risking a crash.", comment: "Description of slow absorption notifications."))) {
            Toggle(NSLocalizedString("Slow Absorption Notifications", comment: "Title for slow absorption notification toggle"), isOn: slowAbsorptionNotificationsEnabled)
        }
    }
    private var preBolusReminderSection: some View {
        Section(footer: DescriptiveText(label: NSLocalizedString("When enabled, Loop will notify you when you prebolus and remind you to eat.", comment: "Description of prebolus notifications."))) {
            Toggle(NSLocalizedString("Pre-bolus notifications", comment: "Title for pre-bolus notification toggle"), isOn: preBolusReminderEnabled)
                .onChange(of: preBolusReminderEnabled.wrappedValue) { newValue in
                    UserDefaults.standard.preBolusReminderEnabled = newValue // Update UserDefaults
                    isPreBolusReminderEnabled = newValue // Update local state
                }
            if isPreBolusReminderEnabled { // Check local state
                HStack {
                    Text(NSLocalizedString("Prebolus Definition", comment: "Label for prebolus delay criterion"))
                    Spacer()
                    Picker("Delay Criterion", selection: prebolusDelayCriterion) {
                        ForEach(1..<31) {
                            Text("\($0) min").tag($0)
                        }
                    }
                    .pickerStyle(WheelPickerStyle())
                    .frame(height: 100) // Set the desired height
                }
            }
        }
    }
}

extension UserDefaults {
    private enum Key: String {
        case missedMealNotificationsEnabled = "com.loopkit.Loop.MissedMealNotificationsEnabled"
        case slowAbsorptionNotificationsEnabled = "com.loopkit.Loop.slowAbsorptionNotificationsEnabled"
        case preBolusReminderEnabled = "com.loopkit.Loop.preBolusReminderEnabled"
        case prebolusDelayCriterion = "com.loopkit.Loop.prebolusDelayCriterion"

        
    }
    
    var missedMealNotificationsEnabled: Bool {
        get {
            return object(forKey: Key.missedMealNotificationsEnabled.rawValue) as? Bool ?? false
        }
        set {
            set(newValue, forKey: Key.missedMealNotificationsEnabled.rawValue)
        }
    }
    
    var slowAbsorptionNotificationsEnabled: Bool {
        get {
            return object(forKey: Key.slowAbsorptionNotificationsEnabled.rawValue) as? Bool ?? false
        }
        set {
            set(newValue, forKey: Key.slowAbsorptionNotificationsEnabled.rawValue)
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
            return object(forKey: Key.prebolusDelayCriterion.rawValue) as? Int ?? 14 // Default value
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
