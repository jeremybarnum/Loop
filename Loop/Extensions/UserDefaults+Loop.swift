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
        case dosingEnabledBeforeWatchLoan = "com.loopkit.Loop.DosingEnabledBeforeWatchLoan"
        case pendingPodLoanRevokeDate = "com.loopkit.Loop.PendingPodLoanRevokeDate"
    }

    /// SHA-256 hex digest of the last watch-loan journal whose doses were reconciled
    /// into the DoseStore. The duplicate-hand-back guard: the store does NOT dedupe
    /// manually-entered doses, so this is the only defense against double entry.
    var lastReconciledWatchLoanJournalHash: String? {
        get { string(forKey: Key.lastReconciledWatchLoanJournalHash.rawValue) }
        set { set(newValue, forKey: Key.lastReconciledWatchLoanJournalHash.rawValue) }
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
