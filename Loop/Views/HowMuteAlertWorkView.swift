//
//  HowMuteAlertWorkView.swift
//  Loop
//
//  Created by Nathaniel Hamming on 2022-12-09.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKitUI

struct HowMuteAlertWorkView: View {
    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.appName) private var appName

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What are examples of Critical Alerts and Time Sensitive Notifications?")
                        .bold()
                    
                    Text("Critical Alerts and Time Sensitive Notifications are important types of iOS notifications used for events that require immediate attention. Examples include:")
                }
                
                HStack {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Critical Alerts")
                                .bold()
                            
                            Text("Urgent Low")
                                .bulleted()
                            Text("Sensor Failed")
                                .bulleted()
                            Text("Reservoir Empty")
                                .bulleted()
                            Text("Pump Expired")
                                .bulleted()
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Time Sensitive Notifications")
                                .bold()
                            
                            Text("High Glucose")
                                .bulleted()
                            Text("Transmitter Low Battery")
                                .bulleted()
                        }
                    }
                    
                    Spacer()
                }
                .font(.subheadline)
                .padding()
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.systemFill), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if !FeatureFlags.criticalAlertsEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            String(
                                format: NSLocalizedString(
                                    "What if Critical Alerts aren't available in %1$@?",
                                    comment: "Title text for critical alerts unavailable fallback (1: app name)"
                                ),
                                appName
                            )
                        )
                        .bold()

                        Text(
                            String(
                                format: NSLocalizedString(
                                    "Critical Alerts require a special permission from Apple that many do-it-yourself versions of %1$@ don't include. Without it, iOS treats even urgent alarms as ordinary notifications, so the Ring/Silent switch, Do Not Disturb, and Focus modes can silence them.",
                                    comment: "Description text explaining the critical alerts entitlement may be unavailable (1: app name)"
                                ),
                                appName
                            )
                        )

                        Text(
                            String(
                                format: NSLocalizedString(
                                    "To help make sure you're still alerted in urgent situations such as Urgent Low, %1$@ plays the alarm sound itself. This sound plays even when the Ring/Silent switch is set to silent or a Focus mode is on, and it repeats for up to 5 minutes or until you acknowledge the alert.",
                                    comment: "Description text explaining the in-app audio fallback for urgent alerts (1: app name)"
                                ),
                                appName
                            )
                        )
                    }

                    Callout(
                        .warning,
                        title: Text(
                            NSLocalizedString(
                                "Keep your volume up",
                                comment: "Critical alert audio fallback callout title"
                            )
                        ),
                        message: Text(
                            String(
                                format: NSLocalizedString(
                                    "%1$@ cannot turn your iPhone's volume up for you. Make sure your volume is turned up — especially overnight — or you may not hear urgent alarms. The Mute All App Sounds feature also silences these alarms while it is active.",
                                    comment: "Critical alert audio fallback callout message (1: app name)"
                                ),
                                appName
                            )
                        )
                    )
                    .padding(.horizontal, -20)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        String(
                            format: NSLocalizedString(
                                "How can I temporarily silence all %1$@ app sounds?",
                                comment: "Title text for temporarily silencing all sounds (1: app name)"
                            ),
                            appName
                        )
                    )
                    .bold()
                    
                    Text(
                        String(
                            format: NSLocalizedString(
                                "Use the Mute All App Sounds feature. It allows you to temporarily silence (up to 4 hours) all of the sounds from %1$@, including Critical Alerts and Time Sensitive Notifications.",
                                comment: "Description text for temporarily silencing all sounds (1: app name)"
                            ),
                            appName
                        )
                    )
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("How can I silence non-Critical Alerts?")
                        .bold()
                    
                    Text(
                        NSLocalizedString(
                            "To turn Silent mode on, flip the Ring/Silent switch toward the back of your iPhone.",
                            comment: "Description text for temporarily silencing non-critical alerts"
                        )
                    )
                    
                    if FeatureFlags.criticalAlertsEnabled {
                        Text(
                            NSLocalizedString(
                                "Critical Alerts will still sound, but all others will be silenced.",
                                comment: "Additional description text for temporarily silencing non-critical alerts"
                            )
                        )
                        .italic()
                    } else {
                        Text(
                            NSLocalizedString(
                                "Urgent alarms, such as Urgent Low, will still sound, but all others will be silenced.",
                                comment: "Additional description text for temporarily silencing non-critical alerts when Critical Alerts are unavailable"
                            )
                        )
                        .italic()
                    }
                }
                
                Callout(
                    .warning,
                    title: Text(
                        String(
                            format: NSLocalizedString(
                                "Keep All Notifications ON for %1$@",
                                comment: "Time sensitive notifications callout title (1: app name)"
                            ),
                            appName
                        )
                    ),
                    message: Text(
                        FeatureFlags.criticalAlertsEnabled
                            ? NSLocalizedString(
                                "Make sure to keep Notifications, Time Sensitive Notifications, and Critical Alerts turned ON in iOS Settings to receive essential safety and maintenance notifications.",
                                comment: "Time sensitive notifications callout message"
                            )
                            : NSLocalizedString(
                                "Make sure to keep Notifications and Time Sensitive Notifications turned ON in iOS Settings to receive essential safety and maintenance notifications.",
                                comment: "Time sensitive notifications callout message when Critical Alerts are unavailable"
                            )
                    )
                )
                .padding(.horizontal, -20)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        String(
                            format: NSLocalizedString(
                                "Can I use Focus modes with %1$@?",
                                comment: "Focus modes section title (1: app name)"
                            ),
                            appName
                        )
                    )
                    .bold()
                    
                    Text(
                        String(
                            format: NSLocalizedString(
                                "iOS Focus Modes enable you to have more control over when apps can send you notifications. If you decide to use these, ensure that notifications are allowed and NOT silenced from %1$@.",
                                comment: "Description text for focus modes (1: app name)"
                            ),
                            appName
                        )
                    )
                }
            }
            
            Section(header: SectionHeader(label: NSLocalizedString("Learn More", comment: "Learn more section header")).padding(.leading, -16).padding(.bottom, 4)) {
                NavigationLink {
                    IOSFocusModesView()
                } label: {
                    Text("iOS Focus Modes", comment: "iOS focus modes navigation link label")
                }

            }
        }
        .insetGroupedListStyle()
        .navigationTitle(NSLocalizedString("FAQ about Alerts", comment: "View title for how mute alerts work"))
    }
}

private extension Text {
    func bulleted(color: Color = .accentColor.opacity(0.5)) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "circle.fill")
                .resizable()
                .frame(width: 8, height: 8)
                .foregroundColor(color)
            
            self
        }
    }
}

struct HowMuteAlertWorkView_Previews: PreviewProvider {
    static var previews: some View {
        HowMuteAlertWorkView()
    }
}
