//
//  CompleteOnboardingView.swift
//  Loop
//
//  Created by Nathaniel Hamming on 2026-02-26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

struct CompleteOnboardingView: View {

    var body: some View {
        VStack(alignment: .center) {
            Spacer()
            Text(String(format: NSLocalizedString("Please complete onboarding to use the %1$@ Watch app", comment: "Watch app onboarding prompt (1: app name)"), (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Loop"))
                .multilineTextAlignment(.center)
            Spacer()
        }
    }
}
