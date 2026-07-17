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
        case lastReconciledWatchLoanJournalHash = "com.loopkit.Loop.LastReconciledWatchLoanJournalHash"
        case watchLoanReconcileState = "com.loopkit.Loop.WatchLoanReconcileState"
        case podLoanLastGrantedAt = "com.loopkit.Loop.PodLoanLastGrantedAt"
        case dosingEnabledBeforeWatchLoan = "com.loopkit.Loop.DosingEnabledBeforeWatchLoan"
        case pendingPodLoanRevokeDate = "com.loopkit.Loop.PendingPodLoanRevokeDate"
        case sensorPairingCodes = "com.loopkit.Loop.SensorPairingCodes"
        case lastSeenSensorID = "com.loopkit.Loop.LastSeenSensorID"
        case pendingSensorCodeRelay = "com.loopkit.Loop.PendingSensorCodeRelay"
    }

    /// SHA-256 hex digest of the last watch-loan journal whose doses were reconciled
    /// into the DoseStore. The duplicate-hand-back guard: the store does NOT dedupe
    /// manually-entered doses, so this is the only defense against double entry.
    var lastReconciledWatchLoanJournalHash: String? {
        get { string(forKey: Key.lastReconciledWatchLoanJournalHash.rawValue) }
        set { set(newValue, forKey: Key.lastReconciledWatchLoanJournalHash.rawValue) }
    }

    /// C7: per-loan incremental reconcile bookkeeping (encoded
    /// WatchLoanReconcileState) — which journal entry IDs have been entered,
    /// through when the basal timeline is covered, and how much audit remainder
    /// has been entered. Lets a GROWN journal resend (lost ack + further watch
    /// activity) reconcile only its new content instead of re-entering everything.
    var watchLoanReconcileStateData: Data? {
        get { data(forKey: Key.watchLoanReconcileState.rawValue) }
        set { set(newValue, forKey: Key.watchLoanReconcileState.rawValue) }
    }

    /// When the most recent pod-loan grant was issued. Discriminates a
    /// hand-back belonging to the CURRENT loan (journal started after this)
    /// from a stale dead-session hand-back racing a new grant (started before
    /// it) — see handlePodHandback's race guard. Persisted: the race can span
    /// phone relaunches.
    var podLoanLastGrantedAt: Date? {
        get { object(forKey: Key.podLoanLastGrantedAt.rawValue) as? Date }
        set { set(newValue, forKey: Key.podLoanLastGrantedAt.rawValue) }
    }

    /// The user's dosingEnabled setting captured at pod-loan grant, persisted so a
    /// phone reboot mid-loan can't lose it (which would leave closed loop silently
    /// off after hand-back). Nil when no loan is active.
    var dosingEnabledBeforeWatchLoan: Bool? {
        get { object(forKey: Key.dosingEnabledBeforeWatchLoan.rawValue) as? Bool }
        set { set(newValue, forKey: Key.dosingEnabledBeforeWatchLoan.rawValue) }
    }

    /// DESIGN-6: a pod-loan revoke that couldn't be queued because the WC session
    /// wasn't activated yet (escape-hatch reclaim racing app launch). Queued to
    /// the watch on activation, then cleared. Nil when none pending.
    var pendingPodLoanRevokeDate: Date? {
        get { object(forKey: Key.pendingPodLoanRevokeDate.rawValue) as? Date }
        set { set(newValue, forKey: Key.pendingPodLoanRevokeDate.rawValue) }
    }

    /// Per-sensor G7 pairing codes (Component A): sensorID → 4-digit code. Captured on the
    /// phone when the CGM reports a new sensor, and relayed to the watch. Low-sensitivity
    /// (a 4-digit pairing PIN); kept out of logs.
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

    /// The most recent G7 sensorID the phone has seen a `.sensorStart` for — so a repeated
    /// start event for the SAME sensor doesn't re-prompt.
    var lastSeenSensorID: String? {
        get { string(forKey: Key.lastSeenSensorID.rawValue) }
        set { set(newValue, forKey: Key.lastSeenSensorID.rawValue) }
    }

    /// A sensor-code relay that couldn't be sent because the watch session wasn't activated
    /// yet (a sensor change racing app launch). Fired to the watch on activation, then cleared.
    /// Stores the SensorCodeUserInfo rawValue (plist-safe: strings + a date).
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
