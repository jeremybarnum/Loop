//
//  G7ClientTransportAdapter.swift
//  WatchApp Extension
//
//  M3 of the watch-from-stock rebuild (DESIGN_FROM_STOCK_REBUILD.md §1.4).
//
//  Bridges the PROVEN direct-BLE transport (G7Client: J-PAKE handshake via libg7auth,
//  connect-per-reading predictive scheduler — on-body validated, 100% capture) to the STOCK
//  G7SensorKit manager/parsing stack, replacing stock's passive CoreBluetooth listener.
//
//  Flow:  G7Client raw EGV notification bytes
//           -> stock G7GlucoseMessage(data:)                       [full parse: trend,
//              predicted, sequence, age, algorithm state, display-only/calibration bit]
//           -> G7CGMManager.sensor(_:didRead:)                     [stock G7SensorDelegate seam]
//           -> CGMManagerDelegate.cgmManager(_:hasNew:)            [stock provenance, dedup,
//              reliability gating, below-40 clamp-with-condition]
//           -> WatchLoopManager (M4) -> GlucoseStore -> loop       [wired in StockLoopStack]
//
//  The stock G7CGMManager owns an idle G7Sensor (and thus an idle CBCentralManager). This
//  adapter NEVER starts the stock scanner: it always maps disconnects as
//  suspectedEndOfSession=false (the G7 hangs up after every reading BY DESIGN under the
//  connect-per-reading scheduler), and it never calls scanForNewSensor()/fetchNewDataIfNeeded().
//  Session lifecycle belongs to G7Client; injecting a transport UNDER G7Sensor itself is the
//  upstreamable seam deferred to M4 (design doc §6).
//

import Foundation
import G7SensorKit

final class G7ClientTransportAdapter {

    /// How many glucose samples THIS adapter has handed to G7CGMManager — i.e. how many came from
    /// G7Client's own read path, as opposed to G7SensorKit's independent CBCentralManager.
    ///
    /// Both producers funnel into the same delegate, and the INGEST log line hardcodes
    /// "src=direct-G7" (WatchLoopManager :2820), so a stored sample has never named its actual
    /// producer. That mattered enormously: on 2026-08-06, 103 readings arrived while G7Client's
    /// unconditional read markers ("-> glucose [4E]", "*** GLUCOSE<-", "*** VALUE =") logged ZERO
    /// — including 30 overnight with the phone's Bluetooth OFF — and four multi-sample
    /// BATCH(backfill+live) ingests appeared that G7Client cannot physically produce (it contains
    /// no backfill code and never discovers that characteristic). Meanwhile G7Client's scanning was
    /// what blocked the pod from dosing, 79 refusals in one night. The radio was being held by the
    /// component delivering nothing, and the log said the opposite.
    ///
    /// A counter rather than a flag: the reader compares against the value it last saw, so a
    /// delivery cannot be missed or double-counted regardless of thread timing.
    private static let deliveryLock = NSLock()
    private static var _deliveries = 0
    static var deliveryCount: Int {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        return _deliveries
    }
    private static func noteDelivery() {
        deliveryLock.lock(); _deliveries += 1; deliveryLock.unlock()
    }

    /// The proven transport (owned).
    let client: G7Client

    /// The stock manager. Its CGMManagerDelegate output (readings, sensor-start events, state
    /// persistence) is the watch loop's input: StockLoopStack.assemble() sets
    /// `manager.cgmManagerDelegate` + `manager.delegateQueue` to the WatchLoopManager, which
    /// routes samples into the watch GlucoseStore (M4).
    let manager: G7CGMManager

    /// Serializes all traffic into the stock delegate seam (G7Client fires its hooks from the
    /// CoreBluetooth queue / async tasks; the stock G7Sensor used a private delegateQueue for
    /// the same purpose).
    private let queue = DispatchQueue(label: "com.loopkit.Loop.G7ClientTransportAdapter", qos: .utility)

    /// Last peripheral name seen by the transport ("DXCMxx"/"Dexcomxx"), the same identity the
    /// stock passive listener keys sensor discovery on. Confined to `queue`.
    private var lastConnectedPeripheralName: String?

    init(client: G7Client, manager: G7CGMManager) {
        self.client = client
        self.manager = manager

        client.onRawEGV = { [weak self] data in
            guard let self else { return }
            self.queue.async { self.handleRawEGV(data) }
        }
        client.onConnectionChange = { [weak self] connected, name in
            guard let self else { return }
            self.queue.async { self.handleConnectionChange(connected: connected, name: name) }
        }
    }

    // MARK: - Transport events -> stock G7SensorDelegate seam

    /// One complete control-characteristic notification (the response to the [0x4E] glucose
    /// poll). Mirrors stock G7Sensor.bluetoothManager(_:didReceiveControlResponse:) +
    /// handleGlucoseMessage(message:peripheralManager:) minus the CoreBluetooth plumbing.
    private func handleRawEGV(_ data: Data) {
        // Same opcode gate as the stock control-response switch. (G7Opcode is internal to
        // G7SensorKit; 0x4E == G7Opcode.glucoseTx.)
        guard data.first == 0x4E else {
            return
        }

        guard let message = G7GlucoseMessage(transportData: data) else {
            // Stock parity: "Unable to handle glucose control response"
            manager.sensor(manager.sensor, didError: G7SensorError.observationError(
                "Unable to parse EGV frame (\(data.count) bytes)"))
            return
        }

        // Stock parity (handleGlucoseMessage): derive the sensor activation date from the
        // message's sensor-clock timestamp on EVERY reading, and hand it to the manager via the
        // G7Sensor it reads timestamps from. `setActivationDate` (and `transportData:` above)
        // are the M3 transport seam, ringfenced in G7SensorKit+WatchTransportSeam.swift on the
        // watch-from-stock branch.
        let activationDate = Date().addingTimeInterval(-TimeInterval(message.messageTimestamp))
        manager.sensor.setActivationDate(activationDate)

        // Sensor discovery, stock-shaped: when the manager isn't yet following this sensor,
        // offer it exactly as the passive listener would on first contact. The stock manager
        // mutates its state (sensorID/activatedAt), emits the .sensorStart PersistedCgmEvent,
        // and returns whether to follow. No fabricated identity: without a peripheral name from
        // the transport there is no discovery and no sample (no-silent-fallbacks rule).
        guard let name = currentSensorName() else {
            manager.sensor(manager.sensor, didError: G7SensorError.observationError(
                "EGV received before the transport reported a sensor name; dropping"))
            return
        }

        if manager.sensorName != name {
            guard manager.sensor(manager.sensor, didDiscoverNewSensor: name, activatedAt: activationDate) else {
                return
            }
        }

        // Full stock ingestion: duplicate detection, failed-sensor/session-ended handling,
        // reliability gating (algorithm state), display-only flagging, [40,400] clamping with
        // condition, syncIdentifier provenance — all G7CGMManager's code, not ours.
        Self.noteDelivery()   // attribute the sample to G7Client at the INGEST line
        manager.sensor(manager.sensor, didRead: message)
    }

    private func handleConnectionChange(connected: Bool, name: String?) {
        if let name, !name.isEmpty {
            lastConnectedPeripheralName = name
        }
        if connected {
            if let name = currentSensorName() {
                manager.sensorDidConnect(manager.sensor, name: name)   // stamps latestConnect
            }
        } else {
            // ALWAYS false: under the connect-per-reading scheduler the sensor drops the link
            // after every reading by design. suspectedEndOfSession=true would make the stock
            // manager start the PASSIVE stock scanner (scanForNewSensor), which must stay idle
            // — session-end detection stays with G7Client/the phone relay for now (M4 item).
            manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: false)
        }
    }

    /// The sensor identity used for discovery and connect events: the transport's last-seen
    /// peripheral name, falling back to the phone-relayed sensor ID G7Client persists
    /// (g7.lastKnownSensorIDv1 — same store its sensor-code relay writes).
    private func currentSensorName() -> String? {
        if let name = lastConnectedPeripheralName {
            return name
        }
        return UserDefaults.standard.string(forKey: "g7.lastKnownSensorIDv1")
    }
}

// The M3 bring-up entry point (G7TransportBringup.makeStack) retired in M4: its purpose —
// proving this stack constructs — is absorbed by StockLoopStack.assemble(), which builds the
// same stack and wires its CGMManagerDelegate output into the WatchLoopManager.
