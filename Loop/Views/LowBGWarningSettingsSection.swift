//
//  LowBGWarningSettingsSection.swift
//  Loop
//
//  The predicted-low warning's settings, in Alert Management: her section from the production line,
//  with its labels, ranges and stored values as they are. The test goes through the same alert path
//  as a real warning.
//

import SwiftUI
import LoopKit
import LoopKitUI
import LoopCore

struct LowBGWarningSettingsSection: View {
    let alertIssuer: AlertIssuer?
    @State private var settings = UserDefaults.standard.lowBGWarningSettings

    var body: some View {
        Section(footer: DescriptiveText(label: NSLocalizedString("When enabled, Loop can notify you when it predicts a low glucose event.", comment: "Description of low BG notifications."))) {
            Toggle(NSLocalizedString("Predicted Low Warnings", comment: "Title for low BG warning enablement"), isOn: $settings.enabled)

            if settings.enabled {
                VStack(spacing: 16) {
                    wheel("Day low warning offset", mgdl: \.dayWarningOffset, range: 0..<15)

                    Toggle(NSLocalizedString("Enable warnings overnight", comment: "Title for enabling low BG warnings overnight"), isOn: $settings.nightWarningsEnabled)

                    if settings.nightWarningsEnabled {
                        wheel("Night low warning offset", mgdl: \.nightWarningOffset, range: 0..<15)
                    }
                    wheel("Warning snooze time", minutes: \.warningSnooze, range: 1..<30)
                    wheel("Don't warn if farther than", minutes: \.dontWarnIfLater, range: 20..<120)
                    wheel("Don't warn if closer than", minutes: \.dontWarnIfSooner, range: 1..<15)
                    wheel("Delay after carb entry", minutes: \.delayAfterCarbEntry, range: 10..<31)
                }

                if let alertIssuer {
                    Button(NSLocalizedString("Test Predicted Low Warning", comment: "Button that issues a test predicted-low warning")) {
                        Task { @MainActor in
                            await LowGlucoseWarningAlerter(alertIssuer: alertIssuer, defaults: .standard).issueTest()
                        }
                    }
                }
            }
        }
        .onChange(of: settings) { newValue in
            UserDefaults.standard.lowBGWarningSettings = newValue
        }
    }

    private func wheel(_ title: String, mgdl keyPath: WritableKeyPath<LowBGWarningSettings, Double>, range: Range<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: Binding(get: { Int(settings[keyPath: keyPath]) },
                                             set: { settings[keyPath: keyPath] = Double($0) })) {
                ForEach(range, id: \.self) { Text("\($0) mg/dl").tag($0) }
            }
            .pickerStyle(WheelPickerStyle())
            .frame(width: 115, height: 50)
        }
    }

    private func wheel(_ title: String, minutes keyPath: WritableKeyPath<LowBGWarningSettings, TimeInterval>, range: Range<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: Binding(get: { Int(settings[keyPath: keyPath] / 60) },
                                             set: { settings[keyPath: keyPath] = TimeInterval($0) * 60 })) {
                ForEach(range, id: \.self) { Text("\($0) min").tag($0) }
            }
            .pickerStyle(WheelPickerStyle())
            .frame(width: 100, height: 40)
        }
    }
}
