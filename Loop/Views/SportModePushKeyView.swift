//
//  SportModePushKeyView.swift
//  Loop
//
//  The user's Apple push key, so a watch with its own internet can tell this phone when it starts
//  Sport Mode without it. Kept in the phone's keychain; the watch receives it with its standing copy.
//  The same kind of key Nightscout's remote commands use; nothing is built into the app.
//

import SwiftUI
import LoopKit
import LoopKitUI
import LoopCore

struct SportModePushKey: Codable, Equatable {
    var keyID: String
    var teamID: String
    var key: String

    private static let keychainService = "SportModePushKey"

    static func load() -> SportModePushKey? {
        guard let data = try? KeychainManager().getGenericPasswordForServiceAsData(keychainService) else { return nil }
        return try? JSONDecoder().decode(SportModePushKey.self, from: data)
    }

    static func save(_ key: SportModePushKey?) {
        try? KeychainManager().replaceGenericPassword(key.flatMap { try? JSONEncoder().encode($0) }, forService: keychainService)
    }

    /// nil without a key or a push token: the watch then sends nothing.
    static func phoneReach(deviceToken: String?) -> PhoneReach? {
        guard let key = load(), let deviceToken, !deviceToken.isEmpty,
              let topic = Bundle.main.bundleIdentifier else { return nil }
        return PhoneReach(deviceToken: deviceToken, topic: topic, production: AppExpirationAlerter.isTestFlightBuild(),
                          keyID: key.keyID, teamID: key.teamID, key: key.key)
    }
}

struct SportModePushKeyView: View {
    @State private var keyID = ""
    @State private var teamID = ""
    @State private var key = ""
    @State private var isSet = SportModePushKey.load() != nil

    var body: some View {
        Form {
            Section(footer: Text(NSLocalizedString("When Sport Mode starts on a watch with its own internet while this iPhone is out of reach, the watch tells this iPhone right away, so it stops trying to loop. Use the APNs key from your Apple Developer account, the same kind Nightscout uses for remote commands.", comment: "Footer explaining the Sport Mode push key"))) {
                TextField(NSLocalizedString("Key ID", comment: "Sport Mode push key: the key's ID"), text: $keyID)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                TextField(NSLocalizedString("Team ID", comment: "Sport Mode push key: the Apple developer team ID"), text: $teamID)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                TextField(NSLocalizedString("Paste the key (.p8 contents)", comment: "Sport Mode push key: the key text"), text: $key, axis: .vertical)
                    .lineLimit(3...6)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            Section {
                Button(NSLocalizedString("Save", comment: "Sport Mode push key: save")) {
                    SportModePushKey.save(SportModePushKey(keyID: keyID.trimmingCharacters(in: .whitespacesAndNewlines),
                                                           teamID: teamID.trimmingCharacters(in: .whitespacesAndNewlines),
                                                           key: key.trimmingCharacters(in: .whitespacesAndNewlines)))
                    isSet = true
                    key = ""
                }
                .disabled(keyID.isEmpty || teamID.isEmpty || !key.contains("PRIVATE KEY"))
                if isSet {
                    Button(NSLocalizedString("Remove Key", comment: "Sport Mode push key: remove"), role: .destructive) {
                        SportModePushKey.save(nil)
                        isSet = false
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("Sport Mode Push", comment: "Title of the Sport Mode push key screen"))
        .onAppear {
            if let saved = SportModePushKey.load() {
                keyID = saved.keyID
                teamID = saved.teamID
            }
        }
    }
}

extension SettingsView {
    var sportModePushSection: some View {
        Section(header: SectionHeader(label: NSLocalizedString("Sport Mode", comment: "The title of the Sport Mode section in settings"))) {
            NavigationLink(destination: SportModePushKeyView()) {
                Text(NSLocalizedString("Push Key", comment: "Settings row for the Sport Mode push key"))
            }
        }
    }
}
