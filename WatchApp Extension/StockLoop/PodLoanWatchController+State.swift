//
//  PodLoanWatchController+State.swift
//  WatchApp Extension
//
//  The watch controller's persisted state: one value, saved and restored as a unit, like a
//  device manager's state.
//

import Foundation
import LoopCore

struct PodLoanWatchState: RawRepresentable {
    static let version = 1

    var phase: PodLoanWatchController.Phase = .idle
    /// The live loan's epoch; cleared at close.
    var epoch: Int?
    /// The highest epoch ever accepted; never cleared, so a spent epoch is never reused.
    var highWaterEpoch = 0
    /// The newest revoke heard; any grant at or below it is refused, across relaunches too.
    var lastRevokedEpoch: Int?

    /// What a resume needs from the grant: the settings, and the phone's capability flags.
    struct GrantedSettings {
        var therapySettingsRaw: Data
        var supplementRaw: Data?
        var supportsInterimHandback: Bool
        var supportsOverrideRecords: Bool
    }
    var grantedSettings: GrantedSettings?

    /// The odometer at takeover; every audit is measured from it.
    var deliveredAtTakeover: Double?
    /// The reunion token for a seized loan, echoed by every offer until the loan closes.
    var seizeToken: UUID?

    init() {}

    init?(rawValue: [String: Any]) {
        phase = (rawValue["phase"] as? String).flatMap(PodLoanWatchController.Phase.init(rawValue:)) ?? .idle
        epoch = rawValue["epoch"] as? Int
        highWaterEpoch = rawValue["highWaterEpoch"] as? Int ?? 0
        lastRevokedEpoch = rawValue["lastRevokedEpoch"] as? Int
        grantedSettings = (rawValue["grantedSettings"] as? [String: Any]).flatMap(Self.grantedSettings(from:))
        deliveredAtTakeover = rawValue["deliveredAtTakeover"] as? Double
        seizeToken = (rawValue["seizeToken"] as? String).flatMap(UUID.init(uuidString:))
    }

    var rawValue: [String: Any] {
        var raw: [String: Any] = ["version": Self.version, "phase": phase.rawValue, "highWaterEpoch": highWaterEpoch]
        raw["epoch"] = epoch
        raw["lastRevokedEpoch"] = lastRevokedEpoch
        raw["grantedSettings"] = grantedSettings.map {
            var d: [String: Any] = ["raw": $0.therapySettingsRaw, "interim": $0.supportsInterimHandback,
                                    "overrideRecords": $0.supportsOverrideRecords]
            d["supplement"] = $0.supplementRaw
            return d
        }
        raw["deliveredAtTakeover"] = deliveredAtTakeover
        raw["seizeToken"] = seizeToken?.uuidString
        return raw
    }

    /// The dictionary shape the legacy key used, kept for the file.
    static func grantedSettings(from d: [String: Any]) -> GrantedSettings? {
        guard let raw = d["raw"] as? Data else { return nil }
        return GrantedSettings(therapySettingsRaw: raw, supplementRaw: d["supplement"] as? Data,
                               supportsInterimHandback: d["interim"] as? Bool ?? false,
                               supportsOverrideRecords: d["overrideRecords"] as? Bool ?? false)
    }

    typealias Keys = PodLoanWatchController.Keys
    static let legacyKeys = [Keys.phase, Keys.epoch, Keys.highWaterEpoch, Keys.grantedTherapySettings,
                             Keys.deliveredAtTakeover, PodLoanWatchController.DormantKeys.activeToken]

    /// Field for field what the legacy keys held.
    init(legacy defaults: UserDefaults) {
        phase = defaults.string(forKey: Keys.phase).flatMap(PodLoanWatchController.Phase.init(rawValue:)) ?? .idle
        epoch = defaults.object(forKey: Keys.epoch) as? Int
        highWaterEpoch = defaults.integer(forKey: Keys.highWaterEpoch)
        grantedSettings = defaults.dictionary(forKey: Keys.grantedTherapySettings).flatMap(Self.grantedSettings(from:))
        deliveredAtTakeover = defaults.object(forKey: Keys.deliveredAtTakeover) as? Double
        seizeToken = defaults.string(forKey: PodLoanWatchController.DormantKeys.activeToken).flatMap(UUID.init(uuidString:))
    }
}

extension PodLoanWatchController {
    /// A file-backed value, seeded once from its legacy key; the key goes once the file holds it.
    static func migratedStore<V>(_ key: String, in directory: URL?, legacyKey: String,
                                 defaults: UserDefaults) -> PersistedProperty<V> {
        var store = directory.map { PersistedProperty<V>(key: key, directory: $0) } ?? PersistedProperty(key: key)
        if let legacy = defaults.object(forKey: legacyKey) as? V {
            if store.wrappedValue == nil { store.wrappedValue = legacy }
            if store.wrappedValue != nil { defaults.removeObject(forKey: legacyKey) }
        }
        return store
    }

    /// The file if present, else the legacy keys: written to the file first, then removed.
    static func loadState(from store: inout PersistedProperty<[String: Any]>, legacy defaults: UserDefaults) -> PodLoanWatchState {
        if let saved = store.wrappedValue.flatMap(PodLoanWatchState.init(rawValue:)) {
            PodLoanWatchState.legacyKeys.forEach(defaults.removeObject(forKey:))
            return saved
        }
        let state = PodLoanWatchState(legacy: defaults)
        store.wrappedValue = state.rawValue
        if store.wrappedValue != nil { PodLoanWatchState.legacyKeys.forEach(defaults.removeObject(forKey:)) }
        return state
    }

    /// The persisted state, readable from any queue.
    var persisted: PodLoanWatchState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _persisted
    }

    /// Applies one change and writes the whole value once, before returning. Phase observers
    /// run afterwards, outside the lock.
    func updateState(_ change: (inout PodLoanWatchState) -> Void) {
        stateLock.lock()
        let old = _persisted.phase
        change(&_persisted)
        stateStore.wrappedValue = _persisted.rawValue
        let new = _persisted.phase
        stateLock.unlock()
        phaseDidChange(from: old, to: new)
    }

    /// The loan phase; its observers drive the mirrors, runtime holds and the glance.
    var phase: Phase {
        get { persisted.phase }
        set { updateState { $0.phase = newValue } }
    }

    var epoch: Int? {
        get { persisted.epoch }
        set { updateState { $0.epoch = newValue } }
    }

    /// Recorded before matching the epoch, so any grant at or below it is refused.
    var lastRevokedEpoch: Int? {
        get { persisted.lastRevokedEpoch }
        set { updateState { $0.lastRevokedEpoch = newValue } }
    }

    var deliveredAtTakeover: Double? {
        get { persisted.deliveredAtTakeover }
        set { updateState { $0.deliveredAtTakeover = newValue } }
    }

    /// Mirrored synchronously, so main-thread readers never lag the queue.
    func phaseDidChange(from oldValue: Phase, to phase: Phase) {
        loanActiveMirrorLock.lock()
        _loanActiveMirror = (phase == .active)
        loanActiveMirrorLock.unlock()
        // Holds are edge-triggered, so re-asserting a phase cannot double-acquire.
        if (oldValue == .takingOver) != (phase == .takingOver) {
            onTakeoverRadioHold?(phase == .takingOver)
            setTakeoverSessionListener(phase == .takingOver)
        }
        if (oldValue == .handingBack) != (phase == .handingBack) {
            onHandbackRuntimeHold?(phase == .handingBack)
        }
        if oldValue != phase {
            NotificationCenter.default.post(name: .podLoanPhaseDidChange, object: nil)
        }
    }
}
