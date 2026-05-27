//
//  GlucoseAlertSettingsView.swift
//  Loop
//
//  Dexcom G7-style alert profile UI.
//  Profile list → profile detail → per-alert detail.
//  Radio button activates a profile; ">" navigates to its settings.
//

import SwiftUI

// MARK: - Profile list

struct GlucoseAlertSettingsView: View {
    @ObservedObject var manager: GlucoseAlertManager
    @ObservedObject var permissionsChecker: AlertPermissionsChecker

    @State private var pendingNewProfileID: UUID? = nil
    @State private var navigateToNew = false

    var body: some View {
        List {
            timeSensitiveDisabledBanner
            sourceSection

            Section(header: Text("Alert Profiles").textCase(nil)) {
                ForEach(manager.profiles) { profile in
                    profileRow(profile)
                }
                if manager.profiles.count < 2 {
                    Button("Add Alert Profile") {
                        let id = manager.addProfile()
                        pendingNewProfileID = id
                        navigateToNew = true
                    }
                }
            }
        }
        .background(
            NavigationLink(
                destination: pendingNewProfileID.map {
                    AlertProfileDetailView(manager: manager, profileID: $0)
                },
                isActive: $navigateToNew
            ) { EmptyView() }
        )
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func profileRow(_ profile: GlucoseAlertProfile) -> some View {
        let isActive = manager.activeProfileID == profile.id
        HStack(spacing: 14) {
            Button {
                manager.activate(profileID: profile.id)
            } label: {
                Image(systemName: isActive ? "circle.inset.filled" : "circle")
                    .font(.title3)
                    .foregroundStyle(isActive ? Color.green : Color(uiColor: .tertiaryLabel))
            }
            .buttonStyle(.plain)

            NavigationLink {
                AlertProfileDetailView(manager: manager, profileID: profile.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(profile.name)
                        Spacer()
                        Text(isActive ? "On" : "Off").foregroundStyle(.secondary)
                    }
                    if let label = manager.nextTransitionLabel(for: profile.id) {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar").font(.caption2)
                            Text(label).font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var timeSensitiveDisabledBanner: some View {
        if permissionsChecker.notificationCenterSettings.timeSensitiveDisabled {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Time-sensitive notifications are off for Loop. Focus modes (including Sleep) will silence these glucose alerts. Enable Time Sensitive Notifications in iOS Settings to let them break through.")
                            .font(.footnote)
                    }
                    Button("Open iOS Settings") { AlertPermissionsChecker.gotoSettings() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        if manager.cgmProvidesOwnAlerts {
            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.tint)
                    Text("Your CGM provides its own glucose alerts. Turn on the override below if you want Loop to also fire alerts in addition to your CGM's.")
                        .font(.footnote)
                }
                Toggle("Also alert from Loop", isOn: Binding(
                    get: { manager.loopAlertsOverrideForOwnAlertingCGM },
                    set: { manager.loopAlertsOverrideForOwnAlertingCGM = $0 }
                ))
            }
        }
    }
}

// MARK: - Profile detail

struct AlertProfileDetailView: View {
    @ObservedObject var manager: GlucoseAlertManager
    let profileID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    private var isPrimary: Bool { manager.primaryProfile.id == profileID }

    private var profile: GlucoseAlertProfile? {
        manager.profiles.first { $0.id == profileID }
    }

    private var profileName: String { profile?.name ?? "" }

    private var config: GlucoseAlertConfiguration {
        profile?.configuration ?? .default
    }

    /// Binding into this profile's configuration at a key path.
    func cfgBind<T>(_ kp: WritableKeyPath<GlucoseAlertConfiguration, T>) -> Binding<T> {
        Binding(
            get: {
                (manager.profiles.first { $0.id == profileID })?.configuration[keyPath: kp]
                    ?? GlucoseAlertConfiguration.default[keyPath: kp]
            },
            set: { v in
                guard let idx = manager.profiles.firstIndex(where: { $0.id == profileID }) else { return }
                manager.profiles[idx].configuration[keyPath: kp] = v
            }
        )
    }

    var body: some View {
        Form {
            Section {
                TextField("Profile Name", text: Binding(
                    get: { profile?.name ?? "" },
                    set: { v in
                        guard let idx = manager.profiles.firstIndex(where: { $0.id == profileID }) else { return }
                        manager.profiles[idx].name = v
                    }
                ))
            }

            Section("Glucose Alerts") {
                alertRow(title: "Urgent Low",
                         value: config.urgentLowEnabled ? "\(Int(config.urgentLowThresholdMgDL)) mg/dL" : "Off",
                         destination: GlucoseAlertDetailView.urgentLow(manager: manager, profileID: profileID, detail: self))
                alertRow(title: "Predicted Low",
                         value: config.predictedLowEnabled ? "On" : "Off",
                         destination: GlucoseAlertDetailView.predictedLow(manager: manager, profileID: profileID, detail: self))
                alertRow(title: "Low",
                         value: config.lowEnabled ? "\(Int(config.lowThresholdMgDL)) mg/dL" : "Off",
                         destination: GlucoseAlertDetailView.low(manager: manager, profileID: profileID, detail: self))
                alertRow(title: "High",
                         value: config.highEnabled ? "\(Int(config.highThresholdMgDL)) mg/dL" : "Off",
                         destination: GlucoseAlertDetailView.high(manager: manager, profileID: profileID, detail: self))
            }
            .disabled(!manager.effectiveLoopAlertsEnabled)

            if !isPrimary {
                schedulingSection
            }

            if !isPrimary {
                Section {
                    Button("Delete Alert Profile", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }
        }
        .navigationTitle(profileName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete \"\(profileName)\"?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                manager.removeProfile(id: profileID)
                dismiss()
            }
        }
    }

    private func alertRow<D: View>(title: String, value: String, destination: D) -> some View {
        NavigationLink { destination } label: {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Scheduling

    @ViewBuilder
    private var schedulingSection: some View {
        let scheduleBind = Binding<GlucoseAlertScheduleSettings>(
            get: { profile?.scheduleSettings ?? .default },
            set: { v in
                guard let idx = manager.profiles.firstIndex(where: { $0.id == profileID }) else { return }
                manager.profiles[idx].scheduleSettings = v
            }
        )
        let enabledBind = Binding(get: { scheduleBind.wrappedValue.enabled }, set: { scheduleBind.wrappedValue.enabled = $0 })
        let isEnabled = profile?.scheduleSettings.enabled ?? false
        let settings = profile?.scheduleSettings ?? .default

        Section {
            Toggle("Scheduling", isOn: enabledBind)

            if isEnabled {
                NavigationLink {
                    DaysPickerView(
                        activeDays: Binding(get: { settings.activeDays }, set: { scheduleBind.wrappedValue.activeDays = $0 }),
                        profileName: profileName
                    )
                } label: {
                    HStack {
                        Text("Days")
                        Spacer()
                        Text(daysLabel(settings.activeDays)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }

                NavigationLink {
                    TimePickerView(label: "Start Time", minuteOfDay: Binding(
                        get: { settings.startMinuteOfDay },
                        set: { scheduleBind.wrappedValue.startMinuteOfDay = $0 }
                    ))
                } label: {
                    HStack {
                        Text("Start Time")
                        Spacer()
                        Text(manager.formatMinuteOfDay(settings.startMinuteOfDay)).foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    TimePickerView(label: "Stop Time", minuteOfDay: Binding(
                        get: { settings.stopMinuteOfDay },
                        set: { scheduleBind.wrappedValue.stopMinuteOfDay = $0 }
                    ))
                } label: {
                    HStack {
                        Text("Stop Time")
                        Spacer()
                        stopTimeLabel(settings: settings)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stopTimeLabel(settings: GlucoseAlertScheduleSettings) -> some View {
        let overnight = settings.stopMinuteOfDay <= settings.startMinuteOfDay
        HStack(spacing: 4) {
            Text(manager.formatMinuteOfDay(settings.stopMinuteOfDay))
            if overnight { Text("(+1 day)").font(.caption) }
        }
        .foregroundStyle(.secondary)
    }

    private func daysLabel(_ days: Set<Int>) -> String {
        if days.count == 7 { return "Every Day" }
        if days.isEmpty { return "None" }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return (0...6).filter { days.contains($0) }.map { names[$0] }.joined(separator: " ")
    }
}

// MARK: - Days picker

private struct DaysPickerView: View {
    @Binding var activeDays: Set<Int>
    let profileName: String
    private let weekdays = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]

    var body: some View {
        Form {
            Section {
                Text("Use the alert schedule to automatically switch on your \(profileName) alert profile on the days and times you set.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                ForEach(0..<7, id: \.self) { idx in
                    Button {
                        if activeDays.contains(idx) {
                            if activeDays.count > 1 { activeDays.remove(idx) }
                        } else {
                            activeDays.insert(idx)
                        }
                    } label: {
                        HStack {
                            Text(weekdays[idx]).foregroundStyle(.primary)
                            Spacer()
                            if activeDays.contains(idx) {
                                Image(systemName: "checkmark").foregroundStyle(.green).fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Days")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Time picker

private struct TimePickerView: View {
    let label: String
    @Binding var minuteOfDay: Int
    @State private var pickerDate: Date

    init(label: String, minuteOfDay: Binding<Int>) {
        self.label = label
        _minuteOfDay = minuteOfDay
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = minuteOfDay.wrappedValue / 60
        comps.minute = minuteOfDay.wrappedValue % 60
        _pickerDate = State(initialValue: Calendar.current.date(from: comps) ?? Date())
    }

    var body: some View {
        VStack {
            DatePicker(label, selection: $pickerDate, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
        }
        .onChange(of: pickerDate) { _, date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            minuteOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        .navigationTitle(label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Per-alert detail

struct GlucoseAlertDetailView: View {
    @ObservedObject var manager: GlucoseAlertManager

    let navigationTitle: String
    let description: String
    let levelLabel: String
    let level: Binding<Double>?
    let levelRange: ClosedRange<Double>
    let enabled: Binding<Bool>
    let snooze: SnoozeBinding?
    let horizon: HorizonBinding?
    let infoNotice: String?
    var showsTestButton: Bool = false

    struct SnoozeBinding {
        let enabled: Binding<Bool>
        let interval: Binding<TimeInterval>
    }
    struct HorizonBinding {
        let value: Binding<TimeInterval>
    }

    var body: some View {
        Form {
            Section { Toggle(navigationTitle, isOn: enabled) } footer: { Text(description) }

            if let infoNotice {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.tint)
                        Text(infoNotice).font(.footnote)
                    }
                }
            }

            if enabled.wrappedValue {
                if let level {
                    Section { LevelPickerRow(label: levelLabel, value: level, range: levelRange) }
                }
                if let snooze {
                    Section {
                        Toggle("Snooze", isOn: snooze.enabled)
                        if snooze.enabled.wrappedValue { SnoozeIntervalRow(interval: snooze.interval) }
                    } footer: {
                        Text("Repeat the alert at the chosen interval if your reading stays out of range.")
                    }
                }
                if let horizon {
                    Section { HorizonRow(value: horizon.value) } footer: {
                        Text("Fires once when Loop's forecast first dips below the level inside this horizon. Re-arms when the forecast clears.")
                    }
                }
            }

            if showsTestButton, FeatureFlags.allowDebugFeatures {
                Section {
                    if manager.pendingTestUrgentLow {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Test armed — next CGM reading will fire")
                            Spacer()
                            Button("Cancel") { manager.cancelTestUrgentLow() }.foregroundStyle(.red)
                        }
                    } else {
                        Button("Arm test alert") { manager.armTestUrgentLowOnNextReading() }
                    }
                } footer: {
                    Text("Arming substitutes a below-threshold value in place of the next real CGM reading, so the alert fires from whatever app state Loop is in at that moment.")
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension GlucoseAlertDetailView {
    static func low(manager: GlucoseAlertManager, profileID: UUID, detail: AlertProfileDetailView) -> some View {
        GlucoseAlertDetailView(
            manager: manager, navigationTitle: "Low",
            description: "Alerts you when your sensor reading is at or below the set level.",
            levelLabel: "Level", level: detail.cfgBind(\.lowThresholdMgDL), levelRange: 60...90,
            enabled: detail.cfgBind(\.lowEnabled),
            snooze: .init(enabled: detail.cfgBind(\.lowSnoozeEnabled), interval: detail.cfgBind(\.lowRepeatInterval)),
            horizon: nil, infoNotice: nil
        )
    }

    static func urgentLow(manager: GlucoseAlertManager, profileID: UUID, detail: AlertProfileDetailView) -> some View {
        let notice: String? = FeatureFlags.criticalAlertsEnabled ? nil :
            "Critical Alerts aren't available on this build. Loop plays an in-app sound that overrides the silent switch and Focus, alongside a time-sensitive notification."
        return GlucoseAlertDetailView(
            manager: manager, navigationTitle: "Urgent Low",
            description: "Alerts you when your sensor reading is at or below this level. Repeats every 5 min while still low.",
            levelLabel: "Level", level: detail.cfgBind(\.urgentLowThresholdMgDL), levelRange: 50...70,
            enabled: detail.cfgBind(\.urgentLowEnabled),
            snooze: nil, horizon: nil, infoNotice: notice, showsTestButton: true
        )
    }

    static func high(manager: GlucoseAlertManager, profileID: UUID, detail: AlertProfileDetailView) -> some View {
        GlucoseAlertDetailView(
            manager: manager, navigationTitle: "High",
            description: "Alerts you when your sensor reading is at or above the set level.",
            levelLabel: "Level", level: detail.cfgBind(\.highThresholdMgDL), levelRange: 140...300,
            enabled: detail.cfgBind(\.highEnabled),
            snooze: .init(enabled: detail.cfgBind(\.highSnoozeEnabled), interval: detail.cfgBind(\.highRepeatInterval)),
            horizon: nil, infoNotice: nil
        )
    }

    static func predictedLow(manager: GlucoseAlertManager, profileID: UUID, detail: AlertProfileDetailView) -> some View {
        GlucoseAlertDetailView(
            manager: manager, navigationTitle: "Predicted Low",
            description: "Alerts you when Loop's dosing forecast predicts you'll drop below the set level within the chosen horizon.",
            levelLabel: "Level", level: detail.cfgBind(\.predictedLowThresholdMgDL), levelRange: 55...80,
            enabled: detail.cfgBind(\.predictedLowEnabled),
            snooze: nil, horizon: .init(value: detail.cfgBind(\.predictedLowHorizon)), infoNotice: nil
        )
    }
}

// MARK: - Pickers

private struct LevelPickerRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        NavigationLink {
            LevelPickerView(label: label, value: $value, range: range)
        } label: {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value)) mg/dL").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

private struct LevelPickerView: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack {
            Picker(label, selection: $value) {
                ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: 1)), id: \.self) { v in
                    Text("\(Int(v)) mg/dL").tag(v)
                }
            }
            .pickerStyle(.wheel).labelsHidden()
        }
        .navigationTitle(label).navigationBarTitleDisplayMode(.inline)
    }
}

private struct SnoozeIntervalRow: View {
    @Binding var interval: TimeInterval
    private let options: [TimeInterval] = [15*60, 30*60, 45*60, 60*60, 90*60, 120*60]
    var body: some View {
        Picker("Repeat every", selection: $interval) {
            ForEach(options, id: \.self) { v in Text("\(Int(v/60)) min").tag(v) }
        }
    }
}

private struct HorizonRow: View {
    @Binding var value: TimeInterval
    private let options: [TimeInterval] = [10*60, 15*60, 20*60, 25*60, 30*60, 45*60]
    var body: some View {
        Picker("Horizon", selection: $value) {
            ForEach(options, id: \.self) { v in Text("\(Int(v/60)) min").tag(v) }
        }
    }
}
