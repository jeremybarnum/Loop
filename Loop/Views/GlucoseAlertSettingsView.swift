//
//  GlucoseAlertSettingsView.swift
//  Loop
//
//  Dexcom-style two-level UI for Loop's threshold-based glucose
//  alerts. Top page is a summary list (one row per alert with current
//  value); tap any row to push a detail page with the enable toggle,
//  level picker, and per-alert options (snooze, horizon).
//

import SwiftUI

struct GlucoseAlertSettingsView: View {
    @ObservedObject var manager: GlucoseAlertManager

    var body: some View {
        List {
            sourceSection
            Section("Glucose Alerts") {
                AlertSummaryRow(
                    title: "Urgent Low",
                    valueText: manager.configuration.urgentLowEnabled ? "\(Int(manager.configuration.urgentLowThresholdMgDL)) mg/dL" : "Off",
                    enabled: manager.effectiveLoopAlertsEnabled
                ) {
                    GlucoseAlertDetailView.urgentLow(manager: manager)
                }
                AlertSummaryRow(
                    title: "Predicted Low",
                    valueText: manager.configuration.predictedLowEnabled ? "On" : "Off",
                    enabled: manager.effectiveLoopAlertsEnabled
                ) {
                    GlucoseAlertDetailView.predictedLow(manager: manager)
                }
                AlertSummaryRow(
                    title: "Low",
                    valueText: manager.configuration.lowEnabled ? "\(Int(manager.configuration.lowThresholdMgDL)) mg/dL" : "Off",
                    enabled: manager.effectiveLoopAlertsEnabled
                ) {
                    GlucoseAlertDetailView.low(manager: manager)
                }
                AlertSummaryRow(
                    title: "High",
                    valueText: manager.configuration.highEnabled ? "\(Int(manager.configuration.highThresholdMgDL)) mg/dL" : "Off",
                    enabled: manager.effectiveLoopAlertsEnabled
                ) {
                    GlucoseAlertDetailView.high(manager: manager)
                }
            }
            .disabled(!manager.effectiveLoopAlertsEnabled)
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var sourceSection: some View {
        if manager.cgmProvidesOwnAlerts {
            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.tint)
                    Text("Your CGM provides its own glucose alerts. Turn on the override below if you want Loop to also fire alerts in addition to your CGM's.")
                        .font(.footnote)
                }
                Toggle("Also alert from Loop", isOn: Binding(
                    get: { manager.configuration.loopAlertsOverrideForOwnAlertingCGM },
                    set: { manager.configuration.loopAlertsOverrideForOwnAlertingCGM = $0 }
                ))
            }
        }
    }
}

private struct AlertSummaryRow<Destination: View>: View {
    let title: String
    let valueText: String
    let enabled: Bool
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(enabled ? 1.0 : 0.4)
    }
}

// MARK: - Detail view

struct GlucoseAlertDetailView: View {
    @ObservedObject var manager: GlucoseAlertManager

    let navigationTitle: String
    let description: String
    let levelLabel: String
    /// Binding to the level value (mg/dL). nil for predicted-low which
    /// also has a horizon control rendered separately.
    let level: Binding<Double>?
    let levelRange: ClosedRange<Double>
    let enabled: Binding<Bool>
    /// Optional snooze section (low / high). Nil suppresses it.
    let snooze: SnoozeBinding?
    /// Optional horizon control (predicted-low only).
    let horizon: HorizonBinding?
    /// Optional notice rendered as its own info section right after
    /// the toggle. Used by Urgent Low to explain the audio fallback
    /// when the build lacks the Critical Alerts entitlement.
    let infoNotice: String?

    struct SnoozeBinding {
        let enabled: Binding<Bool>
        let interval: Binding<TimeInterval>
    }

    struct HorizonBinding {
        let value: Binding<TimeInterval>
    }

    var body: some View {
        Form {
            Section {
                Toggle(navigationTitle, isOn: enabled)
            } footer: {
                Text(description)
            }

            if let infoNotice {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.tint)
                        Text(infoNotice)
                            .font(.footnote)
                    }
                }
            }

            if enabled.wrappedValue {
                if let level {
                    Section {
                        LevelPickerRow(label: levelLabel, value: level, range: levelRange)
                    }
                }

                if let snooze {
                    Section {
                        Toggle("Snooze", isOn: snooze.enabled)
                        if snooze.enabled.wrappedValue {
                            SnoozeIntervalRow(interval: snooze.interval)
                        }
                    } footer: {
                        Text("Repeat the alert at the chosen interval if your reading stays out of range.")
                    }
                }

                if let horizon {
                    Section {
                        HorizonRow(value: horizon.value)
                    } footer: {
                        Text("Fires once when Loop's forecast first dips below the level inside this horizon. Re-arms when the forecast clears.")
                    }
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension GlucoseAlertDetailView {
    static func low(manager: GlucoseAlertManager) -> some View {
        GlucoseAlertDetailView(
            manager: manager,
            navigationTitle: "Low",
            description: "Alerts you when your sensor reading is at or below the set level.",
            levelLabel: "Level",
            level: Binding(get: { manager.configuration.lowThresholdMgDL },
                           set: { manager.configuration.lowThresholdMgDL = $0 }),
            levelRange: 60...90,
            enabled: Binding(get: { manager.configuration.lowEnabled },
                             set: { manager.configuration.lowEnabled = $0 }),
            snooze: .init(
                enabled: Binding(get: { manager.configuration.lowSnoozeEnabled },
                                 set: { manager.configuration.lowSnoozeEnabled = $0 }),
                interval: Binding(get: { manager.configuration.lowRepeatInterval },
                                  set: { manager.configuration.lowRepeatInterval = $0 })
            ),
            horizon: nil,
            infoNotice: nil
        )
    }

    static func urgentLow(manager: GlucoseAlertManager) -> some View {
        // When the build doesn't have the Critical Alerts entitlement,
        // explain what the user gets instead (audio fallback + a
        // time-sensitive notification rather than a true critical
        // alert). Hidden when the entitlement is in place.
        let notice: String?
        if FeatureFlags.criticalAlertsEnabled {
            notice = nil
        } else {
            notice = "Critical Alerts aren't available on this build. Loop plays an in-app sound that overrides the silent switch and Focus, alongside a time-sensitive notification."
        }
        return GlucoseAlertDetailView(
            manager: manager,
            navigationTitle: "Urgent Low",
            description: "Alerts you when your sensor reading is at or below this level. Repeats every 5 min while still low.",
            levelLabel: "Level",
            level: Binding(get: { manager.configuration.urgentLowThresholdMgDL },
                           set: { manager.configuration.urgentLowThresholdMgDL = $0 }),
            levelRange: 50...70,
            enabled: Binding(get: { manager.configuration.urgentLowEnabled },
                             set: { manager.configuration.urgentLowEnabled = $0 }),
            snooze: nil,
            horizon: nil,
            infoNotice: notice
        )
    }

    static func high(manager: GlucoseAlertManager) -> some View {
        GlucoseAlertDetailView(
            manager: manager,
            navigationTitle: "High",
            description: "Alerts you when your sensor reading is at or above the set level.",
            levelLabel: "Level",
            level: Binding(get: { manager.configuration.highThresholdMgDL },
                           set: { manager.configuration.highThresholdMgDL = $0 }),
            levelRange: 140...300,
            enabled: Binding(get: { manager.configuration.highEnabled },
                             set: { manager.configuration.highEnabled = $0 }),
            snooze: .init(
                enabled: Binding(get: { manager.configuration.highSnoozeEnabled },
                                 set: { manager.configuration.highSnoozeEnabled = $0 }),
                interval: Binding(get: { manager.configuration.highRepeatInterval },
                                  set: { manager.configuration.highRepeatInterval = $0 })
            ),
            horizon: nil,
            infoNotice: nil
        )
    }

    static func predictedLow(manager: GlucoseAlertManager) -> some View {
        GlucoseAlertDetailView(
            manager: manager,
            navigationTitle: "Predicted Low",
            description: "Alerts you when Loop's dosing forecast predicts you'll drop below the set level within the chosen horizon.",
            levelLabel: "Level",
            level: Binding(get: { manager.configuration.predictedLowThresholdMgDL },
                           set: { manager.configuration.predictedLowThresholdMgDL = $0 }),
            levelRange: 55...80,
            enabled: Binding(get: { manager.configuration.predictedLowEnabled },
                             set: { manager.configuration.predictedLowEnabled = $0 }),
            snooze: nil,
            horizon: .init(
                value: Binding(get: { manager.configuration.predictedLowHorizon },
                               set: { manager.configuration.predictedLowHorizon = $0 })
            ),
            infoNotice: nil
        )
    }
}

// MARK: - Pickers

/// Tappable summary row that pushes a wheel picker on a child screen
/// (Dexcom-style "Level → 60 mg/dL >" navigation).
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
                Text("\(Int(value)) mg/dL")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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
            .pickerStyle(.wheel)
            .labelsHidden()
        }
        .navigationTitle(label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SnoozeIntervalRow: View {
    @Binding var interval: TimeInterval

    private let options: [TimeInterval] = [15 * 60, 30 * 60, 45 * 60, 60 * 60, 90 * 60, 120 * 60]

    var body: some View {
        Picker("Repeat every", selection: $interval) {
            ForEach(options, id: \.self) { v in
                Text("\(Int(v / 60)) min").tag(v)
            }
        }
    }
}

private struct HorizonRow: View {
    @Binding var value: TimeInterval

    private let options: [TimeInterval] = [10 * 60, 15 * 60, 20 * 60, 25 * 60, 30 * 60, 45 * 60]

    var body: some View {
        Picker("Horizon", selection: $value) {
            ForEach(options, id: \.self) { v in
                Text("\(Int(v / 60)) min").tag(v)
            }
        }
    }
}
