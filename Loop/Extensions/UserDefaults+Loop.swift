//
//  UserDefaults+Loop.swift
//  Loop
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit


extension UserDefaults {
    private enum Key: String {
        case legacyPumpManagerState = "com.loopkit.Loop.PumpManagerState"
        case legacyCGMManagerState = "com.loopkit.Loop.CGMManagerState"
        case legacyServicesState = "com.loopkit.Loop.ServicesState"
        case loopNotRunningNotifications = "com.loopkit.Loop.loopNotRunningNotifications"
        case inFlightAutomaticDose = "com.loopkit.Loop.inFlightAutomaticDose"
        case favoriteFoods = "com.loopkit.Loop.favoriteFoods"
        case sensorPairingCodes = "com.loopkit.Loop.SensorPairingCodes"
        case lastSeenSensorID = "com.loopkit.Loop.LastSeenSensorID"
        case pendingSensorCodeRelay = "com.loopkit.Loop.PendingSensorCodeRelay"
    }

    // MARK: - New-sensor pairing codes (Component A, ported from g7-build-next)

    /// Codes captured on the phone when the CGM reports a new sensor, and relayed to
    /// the watch. Low-sensitivity (a 4-digit pairing PIN); kept out of logs.
    var sensorPairingCodes: [String: String] {
        get { dictionary(forKey: Key.sensorPairingCodes.rawValue) as? [String: String] ?? [:] }
        set { set(newValue, forKey: Key.sensorPairingCodes.rawValue) }
    }

    func sensorPairingCode(for sensorID: String) -> String? { sensorPairingCodes[sensorID] }
    func setSensorPairingCode(_ code: String, for sensorID: String) {
        var codes = sensorPairingCodes
        codes[sensorID] = code
        sensorPairingCodes = codes
    }

    /// The most recent G7 sensorID the phone has seen a `.sensorStart` for — so a
    /// repeated start event for the SAME sensor doesn't re-prompt.
    var lastSeenSensorID: String? {
        get { string(forKey: Key.lastSeenSensorID.rawValue) }
        set { set(newValue, forKey: Key.lastSeenSensorID.rawValue) }
    }

    /// A sensor-code relay parked because the WC session wasn't activated yet; fired
    /// on activation (see WatchDataManager).
    var pendingSensorCodeRelay: [String: Any]? {
        get { dictionary(forKey: Key.pendingSensorCodeRelay.rawValue) }
        set { set(newValue, forKey: Key.pendingSensorCodeRelay.rawValue) }
    }

    var legacyPumpManagerRawValue: PumpManager.RawValue? {
        get {
            return dictionary(forKey: Key.legacyPumpManagerState.rawValue)
        }
    }
    func clearLegacyPumpManagerRawValue() {
        set(nil, forKey: Key.legacyPumpManagerState.rawValue)
    }


    var legacyCGMManagerRawValue: CGMManager.RawValue? {
        get {
            return dictionary(forKey: Key.legacyCGMManagerState.rawValue)
        }
    }

    func clearLegacyCGMManagerRawValue() {
        set(nil, forKey: Key.legacyCGMManagerState.rawValue)
    }

    var legacyServicesState: [Service.RawStateValue] {
        get {
            return array(forKey: Key.legacyServicesState.rawValue) as? [[String: Any]] ?? []
        }
    }

    func clearLegacyServicesState() {
        set(nil, forKey: Key.legacyServicesState.rawValue)
    }

    var inFlightAutomaticDose: AutomaticDoseRecommendation? {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.inFlightAutomaticDose.rawValue) as? Data else {
                return nil
            }
            return try? decoder.decode(AutomaticDoseRecommendation.self, from: data)
        }
        set {
            do {
                if let newValue = newValue {
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(newValue)
                    set(data, forKey: Key.inFlightAutomaticDose.rawValue)
                } else {
                    set(nil, forKey: Key.inFlightAutomaticDose.rawValue)
                }
            } catch {
                assertionFailure("Unable to encode AutomaticDoseRecommendation")
            }
        }
    }

    var loopNotRunningNotifications: [StoredLoopNotRunningNotification] {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.loopNotRunningNotifications.rawValue) as? Data else {
                return []
            }
            return (try? decoder.decode([StoredLoopNotRunningNotification].self, from: data)) ?? []
        }
        set {
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(newValue)
                set(data, forKey: Key.loopNotRunningNotifications.rawValue)
            } catch {
                assertionFailure("Unable to encode Loop not running notification")
            }
        }
    }
    
    var favoriteFoods: [StoredFavoriteFood] {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.favoriteFoods.rawValue) as? Data else {
                return []
            }
            return (try? decoder.decode([StoredFavoriteFood].self, from: data)) ?? []
        }
        set {
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(newValue)
                set(data, forKey: Key.favoriteFoods.rawValue)
            } catch {
                assertionFailure("Unable to encode stored favorite foods")
            }
        }
    }
}
