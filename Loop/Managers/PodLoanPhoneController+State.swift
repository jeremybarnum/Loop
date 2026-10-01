//
//  PodLoanPhoneController+State.swift
//  Loop
//
//  The phone controller's persisted state: one value, saved and restored as a unit, like a
//  device manager's state.
//

import Foundation
import LoopCore

struct PodLoanPhoneState: RawRepresentable {
    /// Bumped when a group of legacy keys moves in, so each group migrates exactly once.
    static let version = 2

    /// When the watch last reported a cycle, so a relaunch is not read as silence.
    var holdRenewedAt: Date?
    /// When the silence was noticed.
    var holdLapseNoticedAt: Date?
    var watchSilenceWarningsIssued = 0

    /// The watch said it can start alone; nothing dormant goes to a watch that cannot.
    var watchSupportsSeize = false
    /// Minted once and echoed by a watch that started alone: this phone's reunion credential.
    var seizeToken: UUID?

    init() {}

    init?(rawValue: [String: Any]) {
        holdRenewedAt = rawValue["holdRenewedAt"] as? Date
        holdLapseNoticedAt = rawValue["holdLapseNoticedAt"] as? Date
        watchSilenceWarningsIssued = rawValue["watchSilenceWarningsIssued"] as? Int ?? 0
        watchSupportsSeize = rawValue["watchSupportsSeize"] as? Bool ?? false
        seizeToken = (rawValue["seizeToken"] as? String).flatMap(UUID.init(uuidString:))
    }

    var rawValue: [String: Any] {
        var raw: [String: Any] = ["version": Self.version, "watchSilenceWarningsIssued": watchSilenceWarningsIssued,
                                  "watchSupportsSeize": watchSupportsSeize]
        raw["seizeToken"] = seizeToken?.uuidString
        raw["holdRenewedAt"] = holdRenewedAt
        raw["holdLapseNoticedAt"] = holdLapseNoticedAt
        return raw
    }

    /// Every key a group's fields came from, removed once the file holds them.
    static let legacyKeys = ["holdRenewedAt", "holdLapseNoticedAt", "watchSilenceWarningsIssued",
                             "watchSupportsSeize", "dormantSeizeToken"]
        .map { "PodLoanPhoneController." + $0 }

    /// Reads, field for field, each group the saved file predates.
    mutating func readLegacy(_ defaults: UserDefaults, savedVersion: Int) {
        let key = { "PodLoanPhoneController." + $0 }
        if savedVersion < 1 {
            holdRenewedAt = defaults.object(forKey: key("holdRenewedAt")) as? Date
            holdLapseNoticedAt = defaults.object(forKey: key("holdLapseNoticedAt")) as? Date
            watchSilenceWarningsIssued = defaults.integer(forKey: key("watchSilenceWarningsIssued"))
        }
        if savedVersion < 2 {
            watchSupportsSeize = defaults.bool(forKey: key("watchSupportsSeize"))
            seizeToken = defaults.string(forKey: key("dormantSeizeToken")).flatMap(UUID.init(uuidString:))
        }
    }
}

extension PodLoanPhoneController {
    static let stateFileKey = "PodLoanPhoneState"

    /// The saved file, plus any legacy group it predates; written first, then the keys go.
    static func loadState(from store: inout PersistedProperty<[String: Any]>, legacy defaults: UserDefaults) -> PodLoanPhoneState {
        let saved = store.wrappedValue
        var state = saved.flatMap(PodLoanPhoneState.init(rawValue:)) ?? PodLoanPhoneState()
        let savedVersion = saved?["version"] as? Int ?? 0
        if savedVersion < PodLoanPhoneState.version {
            state.readLegacy(defaults, savedVersion: savedVersion)
            store.wrappedValue = state.rawValue
        }
        if store.wrappedValue != nil {
            PodLoanPhoneState.legacyKeys.forEach(defaults.removeObject(forKey:))
        }
        return state
    }

    /// The persisted state, readable from any queue.
    var persisted: PodLoanPhoneState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _persisted
    }

    /// Applies one change and writes the whole value once, before returning.
    func updateState(_ change: (inout PodLoanPhoneState) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }
        change(&_persisted)
        stateStore.wrappedValue = _persisted.rawValue
    }
}
