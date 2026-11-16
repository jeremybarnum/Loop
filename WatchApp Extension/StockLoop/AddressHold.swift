//
//  AddressHold.swift
//  WatchApp Extension
//
//  Testing only, not for a pull request: a workaround for a fault in the watch's Bluetooth.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import CoreBluetooth
import WatchKit
import os.log

/// About every 20 minutes the watch's Bluetooth changes its own address. When the change falls due with a
/// connection pending, it holds every connection until a scan stops, and the watch is nearly always scanning,
/// so with the screen dark, the app behind the clock and the phone away a hold can last many minutes; a sensor
/// reading due in that time is lost. A scan started and stopped by the app ends the hold. A restart with no
/// change waiting does nothing.
///
/// This is the one place that restarts the scan, at the moments the app has run time:
/// - the sensor connects for a reading (a change due at the sensor's own wake would otherwise hold the cycle's
///   pod command);
/// - the background refresh asked for 30 s after each reading is due runs, so a reading is overdue
///   (`OverdueRefresh`): this keeps a hold to one lost reading;
/// - watchOS wakes the app for anything else (a phone message, a Bluetooth event) while the pod's connection
///   has been pending over a minute or the sensor has been silent over two, at most once a minute;
/// - the pod is dialed, with the same check.
/// No timer: with the app suspended none of these happen and nothing runs.
final class AddressHold: NSObject, CBCentralManagerDelegate {
    static let shared = AddressHold()

    /// Where the rule's lines go. A build with its own log file points this at it before `start()`.
    static var logLine: (String) -> Void = { line in
        os_log("%{public}@", log: OSLog(category: "AddressHold"), type: .default, line)
    }

    /// Refreshes are asked for only while a loop cycle ended in the last half hour (a loan is running).
    static let loanQuietAfter: TimeInterval = 30 * 60

    private let queue = DispatchQueue(label: "AddressHold")
    private var central: CBCentralManager?
    private var podPendingSince: Date?
    private var sensorLastConnected: Date?
    private var lastRestart = Date.distantPast
    private var lastCycleEnd = Date.distantPast
    private var refreshAskedFor: Date?
    private var overdue = OverdueRefresh()
    /// Matches no device; a scan request is all that is needed.
    private let filter = CBUUID(string: "7B1C0001-5C0A-4E0B-9A57-2F6D0C4E7A10")

    func start() {
        queue.async {
            guard self.central == nil else { return }
            self.central = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    /// watchOS handed the app background tasks. Call before they are finished.
    func appWoken(refresh: Bool) {
        queue.async {
            if refresh { self.refreshRan() }
            self.check()
        }
    }

    /// A loop cycle ended: a loan is running. Its first cycle asks for the refresh; the sensor's connections
    /// ask from then on.
    func cycleEnded() {
        queue.async {
            let now = Date()
            self.lastCycleEnd = now
            if self.refreshAskedFor.map({ $0 < now }) ?? true { self.scheduleRefresh(at: self.overdue.sensorConnected(now: now), log: true) }
        }
    }

    func sensorConnected() {
        queue.async {
            let now = Date()
            self.sensorLastConnected = now
            self.restart(reason: "sensor connected")
            guard self.loanRunning(now) else { return }
            self.scheduleRefresh(at: self.overdue.sensorConnected(now: now), log: false)
        }
    }

    /// The sensor delivered a reading taken at `taken`: time the refresh from the reading itself, since a reading
    /// that was blocked arrives minutes old and the next one is due sooner.
    func readingArrived(taken: Date) {
        queue.async {
            let now = Date()
            guard self.loanRunning(now), let date = self.overdue.readingArrived(taken: taken, now: now) else { return }
            self.scheduleRefresh(at: date, log: false)
        }
    }

    func podConnectRequested() { queue.async { if self.podPendingSince == nil { self.podPendingSince = Date() }; self.check() } }
    func podConnected() { queue.async { self.podPendingSince = nil } }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    // MARK: On `queue`

    private func loanRunning(_ now: Date) -> Bool { now.timeIntervalSince(lastCycleEnd) < Self.loanQuietAfter }

    private func refreshRan() {
        let now = Date()
        let late = refreshAskedFor.map { String(format: "%.0f s after the time asked", now.timeIntervalSince($0)) } ?? "none was asked for"
        let reading = overdue.readingDue.map { String(format: "reading overdue by %.0f s", now.timeIntervalSince($0)) } ?? "no reading expected"
        refreshAskedFor = nil
        Self.logLine("[refresh] ran, \(late) · \(reading)")
        restart(reason: "reading overdue", minGap: 0)
        guard loanRunning(now) else {
            Self.logLine("[refresh] no cycle for 30 min: not asked again")
            overdue = OverdueRefresh()
            return
        }
        scheduleRefresh(at: overdue.refreshRan(now: now), log: true)
    }

    private func check() {
        let now = Date()
        let podWait = podPendingSince.map { now.timeIntervalSince($0) } ?? 0
        let sensorWait = sensorLastConnected.map { now.timeIntervalSince($0) } ?? 0
        guard podWait > 60 || sensorWait > 120 else { return }
        restart(reason: String(format: "pod pending %.0f s, sensor silent %.0f s", podWait, sensorWait), minGap: 60)
    }

    /// Each request replaces the pending one; the routine requests of a normal cycle are not logged.
    private func scheduleRefresh(at date: Date, log: Bool) {
        refreshAskedFor = date
        DispatchQueue.main.async {
            WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: date, userInfo: nil) { error in
                if let error {
                    Self.logLine("[refresh] request refused: \(error.localizedDescription)")
                } else if log {
                    Self.logLine("[refresh] asked for \(Int(date.timeIntervalSinceNow.rounded())) s from now")
                }
            }
        }
    }

    /// Not within `minGap` of the last restart: 5 s by default, so two 1-s scans never overlap.
    private func restart(reason: String, minGap: TimeInterval = 5) {
        let now = Date()
        guard now.timeIntervalSince(lastRestart) > minGap else { return }
        guard let central, central.state == .poweredOn else {
            Self.logLine("[radio] scan restart wanted but Bluetooth is not ready")
            return
        }
        lastRestart = now
        Self.logLine("[radio] scan restart: \(reason)")
        central.scanForPeripherals(withServices: [filter], options: nil)
        queue.asyncAfter(deadline: .now() + 1) { central.stopScan() }
    }
}

/// When to ask for the background refresh. The app cannot see when the watch's address change falls due (a
/// system scan can complete one unseen), so the refresh is tied to what it can see: a reading that did not
/// arrive. Each sensor connection asks for 30 s after the next reading is due, and a request replaces the
/// pending one, so in a normal cycle it never runs. If the sensor stays away (not a hold), the next requests are
/// 5, 10 and 15 min apart: watchOS runs about four refreshes an hour.
struct OverdueRefresh {
    static let readingPeriod: TimeInterval = 5 * 60
    static let margin: TimeInterval = 30
    static let retryDelays: [TimeInterval] = [5 * 60, 10 * 60, 15 * 60]

    /// When the next reading is due, as far as known.
    private(set) var readingDue: Date?
    private(set) var retries = 0

    /// The sensor connected at `now`, a few seconds after its reading was taken. Returns when to ask for.
    mutating func sensorConnected(now: Date) -> Date {
        retries = 0
        let due = now.addingTimeInterval(Self.readingPeriod)
        readingDue = due
        return due.addingTimeInterval(Self.margin)
    }

    /// A reading taken at `taken` arrived. Returns when to ask for, or nil for a reading too old to time the
    /// next one from (backfill).
    mutating func readingArrived(taken: Date, now: Date) -> Date? {
        let age = now.timeIntervalSince(taken)
        guard age >= 0, age < Self.readingPeriod else { return nil }
        let due = taken.addingTimeInterval(Self.readingPeriod)
        readingDue = due
        return due.addingTimeInterval(Self.margin)
    }

    /// The refresh ran at `now`: the reading is overdue. Returns when to ask for the next, should the sensor
    /// stay away.
    mutating func refreshRan(now: Date) -> Date {
        let delay = Self.retryDelays[min(retries, Self.retryDelays.count - 1)]
        retries += 1
        return now.addingTimeInterval(delay)
    }
}
