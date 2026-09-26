//
//  WatchBluetoothStateLog.swift
//  WatchApp Extension
//
//  Logs the watch's Bluetooth going off and coming back, from launch, whether or not a loan
//  is running.
//
//  A failed takeover that never heard the pod now asks the user to turn the watch's Bluetooth
//  off and on (field 2026-09-24; the 2026-08-22 cure). Whether they did, and whether the next
//  Start then worked, is the diagnosis — but the pod driver's central only exists during a
//  loan, and the G7 central keeps its state changes in os_log, so a toggle between loans left
//  no trace in the file the analysis reads. This listen-only central never scans or connects.
//

import CoreBluetooth
import Foundation

final class WatchBluetoothStateLog: NSObject, CBCentralManagerDelegate {

    static let shared = WatchBluetoothStateLog()

    private let queue = DispatchQueue(label: "WatchBluetoothStateLog")
    private var central: CBCentralManager?
    private var lastState: CBManagerState = .unknown
    private var leftPoweredOnAt: Date?

    func start() {
        queue.async {
            guard self.central == nil else { return }
            self.central = CBCentralManager(delegate: self, queue: self.queue,
                                            options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        let previous = lastState
        lastState = state
        guard state != previous else { return }
        if state == .poweredOn {
            // The first poweredOn after launch is routine, not a toggle.
            guard previous != .unknown else { return }
            let away = leftPoweredOnAt.map { String(format: " after %.0fs", Date().timeIntervalSince($0)) } ?? ""
            leftPoweredOnAt = nil
            SportLog.event("bt", "watch Bluetooth back ON\(away)")
        } else {
            if previous == .poweredOn { leftPoweredOnAt = Date() }
            SportLog.event("bt", "watch Bluetooth \(Self.name(state)) (was \(Self.name(previous)))")
        }
    }

    private static func name(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "ON"
        case .poweredOff: return "OFF"
        case .resetting: return "RESETTING"
        case .unauthorized: return "UNAUTHORIZED"
        case .unsupported: return "UNSUPPORTED"
        case .unknown: return "UNKNOWN"
        @unknown default: return "state \(state.rawValue)"
        }
    }
}
