//
//  PodAdvertListener.swift
//  Loop
//
//  PODLOAN diagnostic (2026-09-25): while the watch takes the pod over, the phone listens for
//  the pod's own adverts and writes what it heard to the phone log.
//
//  Field 2026-09-24: three takeovers in 19 minutes heard ZERO adverts from the pod, while the
//  phone re-linked the same pod after each one. A pod advertises only while nobody holds it,
//  so either the watch's radio was deaf or the pod was not advertising — and nothing on either
//  device could say which. This is the phone's half of that answer; the watch's wildcard probe
//  is the other. "Heard here, not on the watch" puts the fault on the watch; "heard nowhere"
//  puts it on the pod or the air between.
//
//  Listen-only, on its OWN central: the pod driver's central auto-connects anything in its
//  autoConnectIDs the moment it is discovered, and a phone connect mid-takeover is exactly the
//  failure this must never cause. This one scans and records; it has no connect path at all.
//  Kill switch: `PodLoan.podAdvertListenerDisabled` = true in the app's defaults.
//

import CoreBluetooth
import Foundation
import UIKit

final class PodAdvertListener: NSObject, CBCentralManagerDelegate {

    static let disabledKey = "PodLoan.podAdvertListenerDisabled"
    /// Longer than the watch's takeover ladder (~111 s), so a full failed ladder is covered.
    static let listenWindow: TimeInterval = 120
    /// CoreBluetooth reports a device once per scan; restarting the scan this often turns one
    /// "first heard" into a sampled record of whether the pod KEPT advertising.
    static let sampleWindow: TimeInterval = 10
    /// The DASH pod's main advertised service (16-bit 0x4024).
    private static let dashService = CBUUID(string: "4024")

    private struct Sighting {
        var firstAt: TimeInterval
        var lastAt: TimeInterval
        var windows: Set<Int>
        var firstRSSI: Int
        var lastRSSI: Int
        var bestRSSI: Int
    }

    private struct Session {
        let epoch: Int
        let startedAt: Date
        var window = 0
        var pods: [String: Sighting] = [:]
        var appState = "?"
    }

    private let queue = DispatchQueue(label: "com.loopkit.Loop.PodAdvertListener", qos: .utility)
    private var central: CBCentralManager?
    private var session: Session?

    /// Start listening for a grant's takeover. A newer grant supersedes an unfinished session.
    func listen(epoch: Int) {
        guard !UserDefaults.standard.bool(forKey: Self.disabledKey) else { return }
        queue.async {
            if let old = self.session { self.finish(old, reason: "superseded by e\(epoch)") }
            let startedAt = Date()
            self.session = Session(epoch: epoch, startedAt: startedAt)
            if self.central == nil {
                // The first poweredOn callback starts the scan.
                self.central = CBCentralManager(delegate: self, queue: self.queue,
                                                options: [CBCentralManagerOptionShowPowerAlertKey: false])
            } else {
                self.beginWindow()
            }
            // Background scans run at a far lower duty cycle than foreground ones, so "not heard"
            // means less from a pocketed phone. Record which it was.
            DispatchQueue.main.async {
                let state: String
                switch UIApplication.shared.applicationState {
                case .active: state = "active"
                case .inactive: state = "inactive"
                case .background: state = "background"
                @unknown default: state = "?"
                }
                self.queue.async {
                    if self.session?.startedAt == startedAt { self.session?.appState = state }
                }
            }
            self.queue.asyncAfter(deadline: .now() + Self.listenWindow) { [weak self] in
                guard let self = self, let s = self.session, s.startedAt == startedAt else { return }
                self.finish(s, reason: "window over")
            }
        }
    }

    /// End a grant's session early (the watch confirmed or reported the takeover).
    func stop(epoch: Int, reason: String) {
        queue.async {
            guard let s = self.session, s.epoch == epoch else { return }
            self.finish(s, reason: reason)
        }
    }

    // MARK: - Scanning

    private func beginWindow() {
        guard let central = central, central.state == .poweredOn, let s = session else { return }
        central.stopScan()
        central.scanForPeripherals(withServices: [Self.dashService], options: nil)
        let window = s.window, startedAt = s.startedAt
        queue.asyncAfter(deadline: .now() + Self.sampleWindow) { [weak self] in
            guard let self = self, self.session?.startedAt == startedAt, self.session?.window == window else { return }
            self.session?.window += 1
            self.beginWindow()
        }
    }

    private func finish(_ s: Session, reason: String) {
        central?.stopScan()
        session = nil
        let elapsed = Date().timeIntervalSince(s.startedAt)
        let windows = s.window + 1
        let heard: String
        if s.pods.isEmpty {
            heard = "NO pod advert heard"
        } else {
            heard = s.pods.sorted { $0.key < $1.key }.map { id, p in
                String(format: "pod 0x%@ heard in %d/%d window(s), first +%.1fs rssi %d, last +%.1fs rssi %d, best %d",
                       id, p.windows.count, windows, p.firstAt, p.firstRSSI, p.lastAt, p.lastRSSI, p.bestRSSI)
            }.joined(separator: " · ")
        }
        let radio = central.map { $0.state == .poweredOn ? "" : " · phone Bluetooth state \($0.state.rawValue) — nothing could be heard" } ?? ""
        PhoneLog.event("advert", String(format: "e%d listen END (%@) after %.0fs, app %@ · %@%@",
                                        s.epoch, reason, elapsed, s.appState, heard, radio))
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            beginWindow()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard var s = session else { return }
        // DASH adverts carry nine 16-bit service UUIDs; the 4th and 5th are the pod's address
        // (the same id OmnipodKit's PodAdvertisement decodes; "FFFFFFFE" before pairing).
        guard let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
              uuids.count >= 5, uuids[0].uuidString == "4024" else { return }
        let id = (uuids[3].uuidString + uuids[4].uuidString).lowercased()
        let at = Date().timeIntervalSince(s.startedAt)
        let rssi = RSSI.intValue
        if var p = s.pods[id] {
            p.lastAt = at
            p.lastRSSI = rssi
            if rssi != 127 { p.bestRSSI = max(p.bestRSSI, rssi) }
            p.windows.insert(s.window)
            s.pods[id] = p
        } else {
            s.pods[id] = Sighting(firstAt: at, lastAt: at, windows: [s.window], firstRSSI: rssi, lastRSSI: rssi,
                                  bestRSSI: rssi == 127 ? -127 : rssi)   // 127 = "not available"
            PhoneLog.event("advert", String(format: "e%d pod 0x%@ heard +%.1fs rssi %d (%@)", s.epoch, id, at, rssi, s.appState))
        }
        session = s
    }
}
