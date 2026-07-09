//
//  PodProofKit.swift
//  OmniBLECore
//
//  NEW for the WatchPod project — not part of upstream OmniBLE.
//
//  A small public facade over the internal PodComms / PodCommsSession /
//  BluetoothManager machinery, written for the WatchProof "radio proof" app
//  (scan -> connect -> pair -> EAP-AKA session -> getStatus from a standalone
//  Apple Watch). It deliberately lives INSIDE the OmniBLECore module so that
//  the internal driving surface (PodComms.runSession, pairAndSetupPod,
//  MessageLogger, PodAdvertisement, ...) does not have to be made public.
//
//  Threading model: all public callbacks (onLog / onDiscoveredPodsChanged /
//  onPhaseChanged and every completion handler) are delivered on the main
//  queue. connectAndPair() must be CALLED from the main thread because the
//  underlying PodComms.connectToNewPod() schedules a Timer on the calling
//  run loop.
//
//  DANGER: this facade can command insulin delivery on a real pod once the
//  BLE path works. It is intended ONLY for use against the pod emulator or
//  saline pods. It enforces a hard 1.0 U bolus ceiling as defense in depth;
//  the WatchProof app further limits boluses to 0.5 U.
//

import Foundation
import CoreBluetooth
import OmniBLEShim
import os.log

// MARK: - Public value types

/// A single timestamped log line for display in the proof app.
public struct PodProofLogEvent: Identifiable, Equatable {
    public let id = UUID()
    public let date: Date
    public let message: String

    /// Public so the WatchProof app's mock mode can fabricate log events.
    public init(_ message: String, date: Date = Date()) {
        self.date = date
        self.message = message
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public var formatted: String {
        return "\(Self.timeFormatter.string(from: date)) \(message)"
    }
}

/// Decoded DASH advertisement for a discovered pod / pod emulator.
/// Mirrors PodAdvertisement.swift (and tools/blescan) decoding, including the
/// emulator's 7-of-9 service UUID padding quirk.
public struct PodProofDiscoveredPod: Identifiable, Equatable {
    /// CoreBluetooth peripheral identifier (NOT stable across devices).
    public let id: UUID
    public let peripheralName: String?
    /// 32-bit pod address from the advertisement; 0xFFFFFFFE when fresh/pairable.
    public let podAddress: UInt32
    public let lotNo: UInt64
    public let sequenceNo: UInt32
    /// True when the pod advertises the fresh-pod address FFFF FFFE.
    public let pairable: Bool
    /// True when only 7 of 9 service UUIDs were advertised (pod emulator
    /// quirk). In that case lotNo/sequenceNo decode from padding and are
    /// garbage; only podAddress/pairable are trustworthy.
    public let paddedAdvertisement: Bool
    public let rssi: Int
    public let lastSeen: Date

    public var podAddressHex: String {
        return String(format: "%08X", podAddress)
    }

    /// Public memberwise init so the WatchProof app's mock mode can fabricate
    /// discovered pods.
    public init(id: UUID, peripheralName: String?, podAddress: UInt32, lotNo: UInt64,
                sequenceNo: UInt32, pairable: Bool, paddedAdvertisement: Bool,
                rssi: Int, lastSeen: Date) {
        self.id = id
        self.peripheralName = peripheralName
        self.podAddress = podAddress
        self.lotNo = lotNo
        self.sequenceNo = sequenceNo
        self.pairable = pairable
        self.paddedAdvertisement = paddedAdvertisement
        self.rssi = rssi
        self.lastSeen = lastSeen
    }
}

/// Snapshot of a pod StatusResponse, pre-formatted for simple display.
public struct PodProofStatus: Equatable {
    public let deliveryStatus: String
    public let podProgress: String
    /// Units remaining; nil when the pod only reports "above 50 U".
    public let reservoirLevel: Double?
    public let insulinDelivered: Double
    public let bolusNotDelivered: Double
    public let lastProgrammingMessageSeqNum: UInt8
    public let timeActive: TimeInterval
    public let alerts: String
    public let receivedAt: Date

    init(_ response: StatusResponse, at date: Date = Date()) {
        self.deliveryStatus = String(describing: response.deliveryStatus)
        self.podProgress = String(describing: response.podProgressStatus)
        if response.reservoirLevel >= Pod.reservoirLevelAboveThresholdMagicNumber {
            self.reservoirLevel = nil
        } else {
            self.reservoirLevel = response.reservoirLevel
        }
        self.insulinDelivered = response.insulinDelivered
        self.bolusNotDelivered = response.bolusNotDelivered
        self.lastProgrammingMessageSeqNum = response.lastProgrammingMessageSeqNum
        self.timeActive = response.timeActive
        self.alerts = response.alerts.isEmpty ? "none" : String(describing: response.alerts)
        self.receivedAt = date
    }

    /// Memberwise init so the WatchProof app can fabricate canned statuses in
    /// its simulator-only mock mode.
    public init(deliveryStatus: String, podProgress: String, reservoirLevel: Double?,
                insulinDelivered: Double, bolusNotDelivered: Double,
                lastProgrammingMessageSeqNum: UInt8, timeActive: TimeInterval,
                alerts: String, receivedAt: Date = Date()) {
        self.deliveryStatus = deliveryStatus
        self.podProgress = podProgress
        self.reservoirLevel = reservoirLevel
        self.insulinDelivered = insulinDelivered
        self.bolusNotDelivered = bolusNotDelivered
        self.lastProgrammingMessageSeqNum = lastProgrammingMessageSeqNum
        self.timeActive = timeActive
        self.alerts = alerts
        self.receivedAt = receivedAt
    }
}

/// A transferable pod identity — everything a second controller needs to take
/// over an already-activated pod WITHOUT re-pairing. In the real product this
/// travels phone→watch over WatchConnectivity; here it is captured from a pod
/// this same app paired, to prove the takeover mechanism against the emulator.
///
/// The durable secret is the `ltk` (+ controller/pod ids); everything else is
/// either metadata or (for `bleIdentifier`) a same-device convenience — see the
/// note on `PodProofController.takeOverPod`.
public struct PodProofIdentity: Equatable {
    public let ltk: Data
    public let controllerId: UInt32
    public let podId: UInt32
    public let podAddress: UInt32
    /// Current Omnipod 4-bit message number, so the taken-over session resumes
    /// in sequence. A getStatus after takeover also resynchronizes it.
    public let messageNumber: Int
    public let lotNo: UInt32
    public let lotSeq: UInt32
    public let productId: UInt8
    public let firmwareVersion: String
    public let bleFirmwareVersion: String
    /// CoreBluetooth peripheral UUID. Per-device: valid to reuse only for a
    /// same-watch handoff. A true cross-device (Loop→watch) handoff re-scans by
    /// podAddress to obtain the watch's own value.
    public let bleIdentifier: String

    public init(ltk: Data, controllerId: UInt32, podId: UInt32, podAddress: UInt32,
                messageNumber: Int, lotNo: UInt32, lotSeq: UInt32, productId: UInt8,
                firmwareVersion: String, bleFirmwareVersion: String, bleIdentifier: String) {
        self.ltk = ltk
        self.controllerId = controllerId
        self.podId = podId
        self.podAddress = podAddress
        self.messageNumber = messageNumber
        self.lotNo = lotNo
        self.lotSeq = lotSeq
        self.productId = productId
        self.firmwareVersion = firmwareVersion
        self.bleFirmwareVersion = bleFirmwareVersion
        self.bleIdentifier = bleIdentifier
    }

    public var summary: String {
        return String(format: "ltk=%@… controller=%08X pod=%08X addr=%08X msg#=%d",
                      Data(ltk.prefix(4)).hexadecimalString, controllerId, podId, podAddress, messageNumber)
    }
}

public enum PodProofPhase: String, Equatable {
    case idle
    case scanning
    case connecting
    case pairing
    case paired
}

public enum PodProofError: LocalizedError {
    case notPaired
    case bolusExceedsProofLimit(requested: Double, limit: Double)
    case tempBasalExceedsProofLimit(requested: Double, limit: Double)
    case operationInProgress

    public var errorDescription: String? {
        switch self {
        case .notPaired:
            return "No pod is paired/connected"
        case .bolusExceedsProofLimit(let requested, let limit):
            return String(format: "Bolus %.2f U exceeds proof-build limit of %.2f U", requested, limit)
        case .tempBasalExceedsProofLimit(let requested, let limit):
            return String(format: "Temp basal %.2f U/hr exceeds proof-build limit of %.2f U/hr", requested, limit)
        case .operationInProgress:
            return "Another pod operation is already in progress"
        }
    }
}

// MARK: - PodProofController

public final class PodProofController: NSObject {

    /// Hard ceiling on any bolus commanded through this facade.
    public static let bolusProofLimit: Double = 1.0

    /// Hard ceiling on any temp-basal RATE commanded through this facade (U/hr).
    // ⚠️ TEMP-TEST-CAP: raised 1.0 → 3.0 for testing only. This is the INDEPENDENT
    // defense-in-depth limit — raising it weakens the backstop, so it MUST REVERT
    // TO 1.0 before any real-pod / real-person use (Friday) and before release.
    // Paired with WatchPodLoanCoordinator.maxTempBasalRate.
    public static let tempBasalRateProofLimit: Double = 3.0   // TEMP-TEST-CAP (revert to 1.0)

    /// Flat basal schedule used for resumeBasal and initial setup.
    /// 0.5 U/hr, single entry starting at midnight.
    static let proofBasalSchedule = BasalSchedule(entries: [BasalScheduleEntry(rate: 0.5, startTime: 0)])

    // MARK: Public callbacks — all delivered on the main queue.

    public var onLog: ((PodProofLogEvent) -> Void)?
    public var onDiscoveredPodsChanged: (([PodProofDiscoveredPod]) -> Void)?
    public var onPhaseChanged: ((PodProofPhase) -> Void)?

    /// Main-thread-updated phase, for UI convenience.
    public private(set) var phase: PodProofPhase = .idle

    public var isPaired: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (podState?.ltk.count ?? 0) > 0
    }

    // MARK: Private state

    private let log = OSLog(category: "PodProofController")

    // Display-only scanner (mirrors tools/blescan). The actual
    // connect-for-pairing path goes through PodComms' own BluetoothManager.
    private var scanCentral: CBCentralManager?
    private var wantScanning = false
    private var discovered: [UUID: PodProofDiscoveredPod] = [:]
    private let scanQueue = DispatchQueue(label: "com.watchpod.proof.scan")

    private var podComms: PodComms?
    private var myId: UInt32 = 0
    private var podId: UInt32 = 0

    private let stateLock = NSLock()
    private var podState: PodState?     // updated via PodCommsDelegate; guarded by stateLock

    /// Set while a takeOverPod() is waiting for the imported-LTK session to
    /// establish; fulfilled (once) from podCommsDidEstablishSession.
    private var pendingTakeover: ((Result<PodProofStatus, Error>) -> Void)?

    /// Record of what the watch did to the pod during the current loan (started
    /// on takeover). Surfaced to the user on hand-back. See PodLoanJournal.
    public private(set) var loanJournal: PodLoanJournal?

    /// Live human-readable summary of the current loan, or nil if none active.
    public var loanJournalSummary: String? { loanJournal?.summaryText }

    /// Finalize the loan (records hand-back) and return its summary text.
    public func endLoanSummary() -> String? { endLoan()?.summaryText }

    /// Note a status into the loan journal (running pod-delivered cross-check).
    private func journalNoteStatus(_ status: PodProofStatus) {
        loanJournal?.noteDelivered(status.insulinDelivered)
    }

    /// Wrap a completion so that, on success, it records a loan event (if any)
    /// and notes the pod-delivered cross-check before forwarding the result.
    private func journaling(_ kind: PodLoanEvent.Kind?,
                            _ completion: @escaping (Result<PodProofStatus, Error>) -> Void)
        -> (Result<PodProofStatus, Error>) -> Void {
        return { result in
            if case .success(let status) = result {
                if let kind = kind { self.journalRecord(kind) }
                self.journalNoteStatus(status)
            }
            completion(result)
        }
    }

    /// Record a discrete loan action if a loan is active.
    private func journalRecord(_ kind: PodLoanEvent.Kind) {
        guard loanJournal != nil else { return }
        loanJournal?.record(kind)
        emit("LOAN JOURNAL: \(PodLoanEvent(kind: kind).describedAction)")
    }

    /// End the current loan (records hand-back) and return its summary, or nil
    /// if no loan is active. The journal is retained for display until the next
    /// takeover starts a new one.
    @discardableResult
    public func endLoan() -> PodLoanJournal? {
        guard loanJournal != nil else { return nil }
        loanJournal?.record(.handedBack)
        emit("LOAN JOURNAL: hand-back\n" + (loanJournal?.summaryText ?? ""))
        return loanJournal
    }

    /// Release the pod WITHOUT deactivating it — disconnects BLE and drops it
    /// from auto-connect so the phone (or another controller) can reclaim it.
    /// The clean "give the pod back" step (vs. force-quitting the app). The pod's
    /// LTK/identity is NOT destroyed; the pod keeps delivering basal.
    public func releasePod() {
        emit("=== Release pod (hand back — pod NOT deactivated) ===")
        podComms?.forgetPod()
        podComms = nil
        stateLock.lock(); podState = nil; stateLock.unlock()
        setPhase(.idle)
    }

    public override init() {
        super.init()
    }

    // MARK: - Logging

    private func emit(_ message: String) {
        log.default("%{public}@", message)
        let event = PodProofLogEvent(message)
        DispatchQueue.main.async {
            self.onLog?(event)
        }
    }

    private func setPhase(_ newPhase: PodProofPhase) {
        DispatchQueue.main.async {
            guard self.phase != newPhase else { return }
            self.phase = newPhase
            self.onPhaseChanged?(newPhase)
        }
    }

    // MARK: - Scanning (display only)

    /// Start scanning for DASH advertisements (service UUID 0x4024) and
    /// publish decoded results via onDiscoveredPodsChanged. Display-only:
    /// does not connect.
    public func startScanning() {
        scanQueue.async {
            self.wantScanning = true
            if self.scanCentral == nil {
                self.emit("SCAN: creating CBCentralManager (expect Bluetooth permission prompt on first run)")
                self.scanCentral = CBCentralManager(delegate: self, queue: self.scanQueue)
            } else {
                self.startScanIfPossible()
            }
        }
        setPhase(.scanning)
    }

    public func stopScanning() {
        scanQueue.async {
            self.wantScanning = false
            if self.scanCentral?.isScanning == true {
                self.scanCentral?.stopScan()
                self.emit("SCAN: stopped")
            }
        }
        if phase == .scanning {
            setPhase(isPaired ? .paired : .idle)
        }
    }

    private func startScanIfPossible() {
        dispatchPrecondition(condition: .onQueue(scanQueue))
        guard wantScanning, let central = scanCentral else { return }
        guard central.state == .poweredOn else {
            emit("SCAN: waiting for Bluetooth (state=\(central.state.rawValue))")
            return
        }
        guard !central.isScanning else { return }
        emit("SCAN: scanning for DASH advertisement service 0x4024")
        central.scanForPeripherals(withServices: [OmnipodServiceUUID.advertisement.cbUUID], options: nil)
    }

    private func publishDiscovered() {
        let pods = discovered.values.sorted { $0.lastSeen > $1.lastSeen }
        DispatchQueue.main.async {
            self.onDiscoveredPodsChanged?(pods)
        }
    }

    // MARK: - Connect + pair

    /// Discover, connect and pair with a fresh pod (LTK exchange -> EAP-AKA
    /// session -> AssignAddress/SetupPod), then configure the default
    /// low-reservoir alert and read initial status.
    ///
    /// Must be called on the main thread (PodComms.connectToNewPod schedules
    /// a Timer on the calling run loop). Uses PodComms' internal discovery,
    /// which connects to the first pairable pod it sees (10 s timeout).
    public func connectAndPair(completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))

        stopScanning()

        if podComms == nil {
            // Same ID scheme as OmniBLEPumpManagerState: random 0x17xxxxxx
            // controller id; pod id = controller id + 1.
            myId = createControllerId()
            podId = myId + 1
            let comms = PodComms(podState: nil, myId: myId, podId: podId)
            comms.delegate = self
            comms.messageLogger = self
            podComms = comms
            emit(String(format: "PAIR: created PodComms (myId=%08X podId=%08X)", myId, podId))
        }

        guard let podComms = podComms else { return }

        setPhase(.connecting)
        emit("PAIR: discovering + connecting (connects to first pairable pod, 10 s timeout)")

        podComms.connectToNewPod { result in
            switch result {
            case .failure(let error):
                self.emit("PAIR: discovery/connect failed: \(error)")
                self.setPhase(.idle)
                DispatchQueue.main.async { completion(.failure(error)) }
            case .success(let device):
                self.emit("PAIR: connected to peripheral \(device.manager.peripheral.identifier.uuidString)")
                self.setPhase(.pairing)
                self.pairAndSetup(completion: completion)
            }
        }
    }

    /// Re-establish an encrypted session on an already-paired pod (e.g. after
    /// the emulator's ~1-minute idle disconnect, PodComms auto-reconnects and
    /// re-establishes; this is the manual path). Internally this re-runs
    /// pairAndSetupPod, which detects the paired state and only performs
    /// EAP-AKA session establishment.
    public func establishSession(completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        guard podComms != nil, isPaired else {
            completion(.failure(PodProofError.notPaired))
            return
        }
        emit("SESSION: re-establishing EAP-AKA session")
        pairAndSetup(completion: completion)
    }

    private func pairAndSetup(completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        guard let podComms = podComms else {
            DispatchQueue.main.async { completion(.failure(PodProofError.notPaired)) }
            return
        }

        podComms.pairAndSetupPod(timeZone: .currentFixed, insulinType: .novolog, messageLogger: self) { result in
            // Called on the peripheral manager's session queue.
            switch result {
            case .failure(let error):
                self.emit("PAIR: pairAndSetupPod failed: \(error)")
                self.setPhase(self.isPaired ? .paired : .idle)
                DispatchQueue.main.async { completion(.failure(error)) }
            case .success(let session):
                self.emit("PAIR: paired; encrypted session established")
                do {
                    // Default low-reservoir alert, per the brief. UNVERIFIED
                    // against hardware: on a real pod alerts are normally
                    // configured later in setup (insertCannula); the emulator
                    // acks PROGRAM_ALERTS at any stage.
                    let units = Pod.defaultLowReservoirReminder
                    _ = try session.configureAlerts([.lowReservoir(units: units, silent: false)])
                    self.emit(String(format: "PAIR: configured low-reservoir alert at %.0f U", units))
                } catch {
                    // Non-fatal for the radio proof.
                    self.emit("PAIR: low-reservoir alert configuration failed (continuing): \(error)")
                }
                do {
                    let status = try session.getStatus()
                    self.emit("PAIR: initial getStatus OK")
                    self.setPhase(.paired)
                    DispatchQueue.main.async { completion(.success(PodProofStatus(status))) }
                } catch {
                    self.emit("PAIR: initial getStatus failed: \(error)")
                    self.setPhase(.paired) // pairing itself succeeded
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
    }

    // MARK: - Commands

    /// Run a getStatus round-trip. THE radio-proof milestone command.
    public func getStatus(completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        runCommand(named: "Get status", completion: journaling(nil, completion)) { session in
            return try session.getStatus()
        }
    }

    /// Suspend insulin delivery (untimed, silent). NOTE: the driver refuses
    /// this before pod setup is complete (setupNotComplete) because a cancel
    /// command would fault a mid-setup pod — run completeSetup() first.
    public func suspend(completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        runCommand(named: "Suspend delivery", completion: journaling(.suspend, completion)) { session in
            let result = session.suspendDelivery(suspendReminder: nil, silent: true)
            switch result {
            case .success(let statusResponse, _):
                return statusResponse
            case .certainFailure(let error):
                throw error
            case .unacknowledged(let error):
                throw error
            }
        }
    }

    /// Resume basal delivery on the proof build's flat 0.5 U/hr schedule.
    public func resume(completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        runCommand(named: "Resume basal", completion: journaling(.resume, completion)) { session in
            let offset = TimeZone.currentFixed.scheduleOffset(forDate: Date())
            return try session.resumeBasal(schedule: Self.proofBasalSchedule, scheduleOffset: offset)
        }
    }

    /// Deliver a bolus. Hard-capped at bolusProofLimit (1.0 U); the WatchProof
    /// app further restricts this to 0.5 U.
    public func bolus(units: Double, completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        guard units <= Self.bolusProofLimit else {
            emit(String(format: "BOLUS: refused %.2f U (proof limit %.2f U)", units, Self.bolusProofLimit))
            completion(.failure(PodProofError.bolusExceedsProofLimit(requested: units, limit: Self.bolusProofLimit)))
            return
        }
        runCommand(named: String(format: "Bolus %.2f U", units), completion: journaling(.bolus(units: units), completion)) { session in
            let result = session.bolus(units: units, acknowledgementBeep: false, completionBeep: false)
            switch result {
            case .success(let statusResponse):
                return statusResponse
            case .certainFailure(let error):
                throw error
            case .unacknowledged(let error):
                throw error
            }
        }
    }

    /// Set a temp basal at an absolute rate (U/hr) for a fixed duration. Hard-capped
    /// at tempBasalRateProofLimit (1.0 U/hr). Mirrors bolus(): rate-capped, journaled,
    /// three-way DeliveryCommandResult switch. `isHighTemp:false, automatic:false` =
    /// a manual, user-initiated temp. The pod auto-reverts to its scheduled basal when
    /// the duration expires — a safety backstop if the watch dies mid-loan.
    public func setTempBasal(rate: Double, duration: TimeInterval, completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        guard rate <= Self.tempBasalRateProofLimit else {
            emit(String(format: "TEMP BASAL: refused %.2f U/hr (proof limit %.2f U/hr)", rate, Self.tempBasalRateProofLimit))
            completion(.failure(PodProofError.tempBasalExceedsProofLimit(requested: rate, limit: Self.tempBasalRateProofLimit)))
            return
        }
        runCommand(named: String(format: "Temp basal %.2f U/hr for %.0f min", rate, duration / 60),
                   completion: journaling(.tempBasal(rate: rate, duration: duration), completion)) { session in
            let result = session.setTempBasal(rate: rate, duration: duration, isHighTemp: false, automatic: false)
            switch result {
            case .success(let statusResponse):
                return statusResponse
            case .certainFailure(let error):
                throw error
            case .unacknowledged(let error):
                throw error
            }
        }
    }

    /// Cancel the running temp basal only — the pod reverts to its stored
    /// scheduled basal on its own (0x1f STOP_DELIVERY, temp bit). Distinct from
    /// suspend(), which stops ALL delivery.
    public func cancelTempBasal(completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        runCommand(named: "Cancel temp basal", completion: journaling(.cancelTempBasal, completion)) { session in
            let result = session.cancelDelivery(deliveryType: .tempBasal)
            switch result {
            case .success(let statusResponse, _):
                return statusResponse
            case .certainFailure(let error):
                throw error
            case .unacknowledged(let error):
                throw error
            }
        }
    }

    /// Complete pod setup after pairing: prime, program the flat proof basal
    /// schedule, insert cannula. Required before suspend/resume/bolus (the
    /// driver refuses delivery-affecting commands mid-setup). Takes several
    /// minutes of wall-clock time (prime ~52 s, cannula ~10 s), mirroring the
    /// real activation sequence. UNVERIFIED against hardware/emulator; the
    /// emulator's PodProgress state machine (prime -> basal -> cannula ->
    /// running) implements the same steps.
    public func completeSetup(completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        guard let podComms = podComms, isPaired else {
            completion(.failure(PodProofError.notPaired))
            return
        }

        emit("SETUP: step 1/3 prime")
        podComms.runSession(withName: "Prime pod") { result in
            switch result {
            case .failure(let error):
                self.emit("SETUP: prime session failed: \(error)")
                DispatchQueue.main.async { completion(.failure(error)) }
            case .success(let session):
                do {
                    let finishWait = try session.prime()
                    self.emit(String(format: "SETUP: priming; waiting %.0f s", finishWait))
                    DispatchQueue.main.asyncAfter(deadline: .now() + finishWait + 1) {
                        self.setupStep2(completion: completion)
                    }
                } catch {
                    self.emit("SETUP: prime failed: \(error)")
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
    }

    private func setupStep2(completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        guard let podComms = podComms else {
            completion(.failure(PodProofError.notPaired))
            return
        }
        emit("SETUP: step 2/3 program initial basal schedule + insert cannula")
        podComms.runSession(withName: "Basal schedule + cannula") { result in
            switch result {
            case .failure(let error):
                self.emit("SETUP: session failed: \(error)")
                DispatchQueue.main.async { completion(.failure(error)) }
            case .success(let session):
                do {
                    let offset = TimeZone.currentFixed.scheduleOffset(forDate: Date())
                    try session.programInitialBasalSchedule(Self.proofBasalSchedule, scheduleOffset: offset)
                    self.emit("SETUP: initial basal schedule programmed (flat 0.5 U/hr)")
                    let finishWait = try session.insertCannula(optionalAlerts: [], silent: true)
                    self.emit(String(format: "SETUP: cannula inserting; waiting %.0f s", finishWait))
                    DispatchQueue.main.asyncAfter(deadline: .now() + finishWait + 1) {
                        self.setupStep3(completion: completion)
                    }
                } catch {
                    self.emit("SETUP: step 2 failed: \(error)")
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
    }

    private func setupStep3(completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        emit("SETUP: step 3/3 check insertion completed")
        runCommand(named: "Check insertion completed", completion: completion) { session in
            try session.checkInsertionCompleted()
            return try session.getStatus()
        }
    }

    /// Deactivate the pod. On the emulator, the process exits afterwards
    /// (restart it with -fresh to pair again).
    public func deactivate(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let podComms = podComms, isPaired else {
            completion(.failure(PodProofError.notPaired))
            return
        }
        emit("=== Deactivate pod ===")
        podComms.runSession(withName: "Deactivate pod") { result in
            switch result {
            case .failure(let error):
                self.emit("DEACTIVATE: session failed: \(error)")
                DispatchQueue.main.async { completion(.failure(error)) }
            case .success(let session):
                do {
                    try session.deactivatePod()
                    self.emit("DEACTIVATE: pod deactivated")
                    self.setPhase(.idle)
                    DispatchQueue.main.async { completion(.success(())) }
                } catch {
                    self.emit("DEACTIVATE: failed: \(error)")
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
    }

    // MARK: - Command plumbing

    private func runCommand(named name: String,
                            completion: @escaping (Result<PodProofStatus, Error>) -> Void,
                            _ body: @escaping (PodCommsSession) throws -> StatusResponse) {
        guard let podComms = podComms, isPaired else {
            completion(.failure(PodProofError.notPaired))
            return
        }
        emit("=== \(name) ===")
        podComms.runSession(withName: name) { result in
            switch result {
            case .failure(let error):
                self.emit("\(name): session failed: \(error)")
                DispatchQueue.main.async { completion(.failure(error)) }
            case .success(let session):
                do {
                    let statusResponse = try body(session)
                    self.emit("\(name): OK")
                    DispatchQueue.main.async { completion(.success(PodProofStatus(statusResponse))) }
                } catch {
                    self.emit("\(name): failed: \(error)")
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
    }

    // MARK: - Handoff / takeover

    /// Capture the current pod's transferable identity (LTK + controller/pod
    /// ids + address + current message number + metadata). Returns nil if not
    /// paired. In the real product this blob would be sent phone→watch over
    /// WatchConnectivity; here it lets the app hand a pod off to itself to prove
    /// the takeover mechanism.
    public func exportIdentity() -> PodProofIdentity? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ps = podState, ps.ltk.count > 0 else { return nil }
        return PodProofIdentity(
            ltk: ps.ltk,
            controllerId: myId,
            podId: podId,
            podAddress: ps.address,
            messageNumber: ps.messageTransportState.messageNumber,
            lotNo: ps.lotNo,
            lotSeq: ps.lotSeq,
            productId: ps.productId,
            firmwareVersion: ps.firmwareVersion,
            bleFirmwareVersion: ps.bleFirmwareVersion,
            bleIdentifier: ps.bleIdentifier)
    }

    /// Take over an already-activated pod using an exported identity, WITHOUT
    /// re-pairing. This is the phone→watch handoff mechanism, proven against the
    /// emulator: it releases any existing connection, builds a fresh PodComms
    /// from the identity's LTK, and lets OmniBLE reconnect and re-derive the
    /// encrypted session from the LTK — exactly what it does on app relaunch
    /// (OmniBLEPumpManager creates PodComms(podState:...) and completeConfiguration
    /// re-establishes the session). A getStatus then confirms/​resyncs.
    ///
    /// Must be called on the main thread. NOTE: this proof reuses the identity's
    /// bleIdentifier (valid because it is the same watch). A true cross-device
    /// handoff would re-scan for the pod by podAddress to obtain the watch's own
    /// bleIdentifier; the session establishment is otherwise identical.
    public func takeOverPod(identity: PodProofIdentity,
                            completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        emit("=== TAKE OVER POD (simulated handoff) ===")
        emit("TAKEOVER: importing identity \(identity.summary)")

        // 1. Release any existing controller/connection (simulates the phone
        //    letting go so the pod starts advertising again).
        if let old = podComms {
            emit("TAKEOVER: releasing existing controller/connection")
            old.forgetPod()
        }
        podComms = nil
        stateLock.lock(); podState = nil; stateLock.unlock()
        setPhase(.connecting)

        // 2. Give the pod a few seconds to disconnect and re-advertise before a
        //    brand-new PodComms goes looking for it.
        emit("TAKEOVER: released old connection; waiting 5 s for the pod to re-advertise")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.buildTakeoverComms(identity: identity, completion: completion)
        }
    }

    private func buildTakeoverComms(identity: PodProofIdentity,
                                    completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))

        // Start a loan journal for this takeover — records everything the watch
        // does to the pod, to tell the phone/user on hand-back. deliveredAtStart
        // is filled by the first status read below.
        loanJournal = PodLoanJournal(startedAt: Date())

        // Build a PodState describing an ALREADY-ACTIVATED pod from the identity.
        // messageTransportState starts with no session keys (ck/noncePrefix nil);
        // completeConfiguration re-derives them from the LTK on connect.
        let mts = MessageTransportState(ck: nil, noncePrefix: nil, messageNumber: identity.messageNumber)
        var newState = PodState(
            address: identity.podAddress,
            ltk: identity.ltk,
            firmwareVersion: identity.firmwareVersion,
            bleFirmwareVersion: identity.bleFirmwareVersion,
            lotNo: identity.lotNo,
            lotSeq: identity.lotSeq,
            productId: identity.productId,
            messageTransportState: mts,
            bleIdentifier: identity.bleIdentifier,
            insulinType: .novolog)
        newState.setupProgress = .completed   // we are taking over an active pod

        myId = identity.controllerId
        podId = identity.podId

        // Fresh PodComms: its NEW BluetoothManager powers on with the pod's
        // bleIdentifier already registered for auto-connect, so it scans, finds
        // the pod, connects, and completeConfiguration establishes the session
        // from the LTK. (Reusing the paired PodComms would NOT scan, because its
        // central is already powered on — a fresh one mimics app relaunch.)
        let comms = PodComms(podState: newState, myId: identity.controllerId, podId: identity.podId)
        comms.delegate = self
        comms.messageLogger = self
        podComms = comms
        stateLock.lock(); podState = newState; stateLock.unlock()

        emit(String(format: "TAKEOVER: fresh PodComms built (myId=%08X podId=%08X); reconnecting to %@ and deriving session from imported LTK",
                    identity.controllerId, identity.podId, identity.bleIdentifier))

        // Wait for the imported-LTK session to establish, then getStatus.
        pendingTakeover = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, let pending = self.pendingTakeover else { return }
            self.pendingTakeover = nil
            self.emit("TAKEOVER: timed out waiting for session establishment from imported LTK")
            pending(.failure(PodProofError.notPaired))
        }
    }

    /// Take over an EXTERNALLY-paired pod (e.g. one Loop paired on the phone),
    /// given only its keys/ids — the TRUE cross-device handoff. Unlike
    /// takeOverPod(identity:), the watch does NOT know the pod's per-device
    /// CoreBluetooth UUID (that belongs to the phone), so it first SCANS for a
    /// pod advertising the given podAddress to obtain its own bleIdentifier,
    /// then builds the identity and reconnects/​re-derives the session from the
    /// imported LTK.
    ///
    /// For the emulator round-trip proof, the keys come from reading the
    /// emulator log after Loop pairs (see WatchProof ExternalIdentity config).
    /// UNTESTED against hardware as of this writing — the scan-by-address +
    /// takeover path compiles but has not run live.
    ///
    /// Must be called on the main thread.
    public func takeOverExternalPod(ltk: Data, controllerId: UInt32, podId: UInt32,
                                    podAddress: UInt32, messageNumber: Int,
                                    completion: @escaping (Result<PodProofStatus, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        emit("=== TAKE OVER EXTERNAL POD (cross-device handoff) ===")
        emit(String(format: "TAKEOVER-EXT: scanning for pod addr=%08X to take over with imported keys (ltk=%@…)",
                    podAddress, Data(ltk.prefix(4)).hexadecimalString))

        // Release anything we might be holding, then scan to locate the pod by
        // its advertised address and resolve OUR bleIdentifier for it.
        if let old = podComms {
            emit("TAKEOVER-EXT: releasing existing controller/connection")
            old.forgetPod()
        }
        podComms = nil
        stateLock.lock(); podState = nil; stateLock.unlock()
        setPhase(.connecting)
        startScanning()

        let deadline = Date().addingTimeInterval(25)
        pollForExternalPod(podAddress: podAddress, deadline: deadline) { [weak self] bleIdentifier in
            guard let self = self else { return }
            let identity = PodProofIdentity(
                ltk: ltk, controllerId: controllerId, podId: podId, podAddress: podAddress,
                messageNumber: messageNumber, lotNo: 0, lotSeq: 0, productId: 0,
                firmwareVersion: "0.0.0", bleFirmwareVersion: "0.0.0", bleIdentifier: bleIdentifier)
            self.stopScanning()
            self.buildTakeoverComms(identity: identity, completion: completion)
        } notFound: { [weak self] in
            self?.emit("TAKEOVER-EXT: pod addr not found in scan within timeout")
            completion(.failure(PodProofError.notPaired))
        }
    }

    /// Poll the display scanner (on its queue) for a pod whose advertised
    /// address matches, returning its peripheral UUID (our bleIdentifier).
    private func pollForExternalPod(podAddress: UInt32, deadline: Date,
                                    found: @escaping (String) -> Void,
                                    notFound: @escaping () -> Void) {
        scanQueue.async {
            if let match = self.discovered.values.first(where: { $0.podAddress == podAddress }) {
                let bleId = match.id.uuidString
                DispatchQueue.main.async {
                    self.emit(String(format: "TAKEOVER-EXT: found pod addr=%@ as peripheral %@", match.podAddressHex, bleId))
                    found(bleId)
                }
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.pollForExternalPod(podAddress: podAddress, deadline: deadline, found: found, notFound: notFound)
                }
            } else {
                DispatchQueue.main.async { notFound() }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate (display-only scanner)

extension PodProofController: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit("SCAN: Bluetooth state -> \(central.state.rawValue)")
        startScanIfPossible()
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let adv = PodAdvertisement(advertisementData) else {
            emit("SCAN: 0x4024 advertiser \(peripheral.identifier.uuidString) had undecodable advertisement")
            return
        }
        let padded = adv.serviceUUIDs.count == 7
        let pod = PodProofDiscoveredPod(
            id: peripheral.identifier,
            peripheralName: peripheral.name,
            podAddress: adv.podId,
            lotNo: adv.lotNo,
            sequenceNo: adv.sequenceNo,
            pairable: adv.pairable,
            paddedAdvertisement: padded,
            rssi: RSSI.intValue,
            lastSeen: Date()
        )
        let isNew = discovered[peripheral.identifier] == nil
        discovered[peripheral.identifier] = pod
        if isNew {
            emit(String(format: "SCAN: pod %@ addr=%@ pairable=%@ lot=%lu seq=%u rssi=%d%@",
                        peripheral.name ?? peripheral.identifier.uuidString,
                        pod.podAddressHex,
                        pod.pairable ? "YES" : "no",
                        adv.lotNo, adv.sequenceNo, RSSI.intValue,
                        padded ? " (7-UUID emulator adv; lot/seq unreliable)" : ""))
        }
        publishDiscovered()
    }
}

// MARK: - MessageLogger (protocol-level tracing)

extension PodProofController: MessageLogger {
    func didSend(_ message: Data) {
        emit("SEND: \(message.hexadecimalString)")
    }

    func didReceive(_ message: Data) {
        emit("RECV: \(message.hexadecimalString)")
    }

    func didError(_ message: String) {
        emit("COMMS ERROR: \(message)")
    }
}

// MARK: - PodCommsDelegate (connection + state changes)

extension PodProofController: PodCommsDelegate {
    func podComms(_ podComms: PodComms, didChange podState: PodState?) {
        stateLock.lock()
        self.podState = podState
        stateLock.unlock()
        if let podState = podState {
            emit("STATE: setupProgress=\(podState.setupProgress) fault=\(podState.fault != nil ? "YES" : "none")")
        } else {
            emit("STATE: podState cleared")
        }
    }

    func podCommsDidEstablishSession(_ podComms: PodComms) {
        emit("SESSION: encrypted session (re)established")
        setPhase(.paired)
        // If a takeover is waiting on this, the imported LTK just produced a
        // working session — confirm with a getStatus and fulfill it (once). Use
        // noSeqGetStatus so a stale 4-bit message counter (the taking-over
        // controller may not know the pod's current value) doesn't fail the
        // first read — this is exactly what OmniBLEPumpManager.getPodStatus does
        // on reconnect. The status response resynchronizes the counter.
        DispatchQueue.main.async {
            guard let pending = self.pendingTakeover else { return }
            self.pendingTakeover = nil
            self.emit("TAKEOVER: session established from imported LTK — confirming with getStatus(noSeq)")
            self.runCommand(named: "Takeover getStatus", completion: self.journaling(nil, pending)) { session in
                return try session.getStatus(noSeqGetStatus: true)
            }
        }
    }

    func omnipodPeripheralWasRestored(manager: PeripheralManager) {
        emit("BLE: peripheral restored \(manager.peripheral.identifier.uuidString)")
    }

    func omnipodPeripheralDidConnect(manager: PeripheralManager) {
        emit("BLE: connected \(manager.peripheral.identifier.uuidString)")
    }

    func omnipodPeripheralDidDisconnect(peripheral: CBPeripheral, error: Error?) {
        emit("BLE: disconnected \(peripheral.identifier.uuidString)\(error.map { " error: \($0)" } ?? "") (auto-reconnect will retry)")
    }

    func omnipodPeripheralDidFailToConnect(peripheral: CBPeripheral, error: Error?) {
        emit("BLE: failed to connect \(peripheral.identifier.uuidString)\(error.map { " error: \($0)" } ?? "")")
    }
}
