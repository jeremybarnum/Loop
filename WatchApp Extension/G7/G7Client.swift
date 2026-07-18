// G7Client.swift — iOS CoreBluetooth client + view-model for the Dexcom G7.
//
// This is a faithful port of the working macOS client (../G7Mac/G7Client.swift),
// which itself ports the proven raw-ATT Python reference. The J-PAKE / ECDSA / AES
// crypto is the prebuilt C library libg7auth (header g7auth.h, exposed to Swift via
// the bridging header G7iOS-Bridging-Header.h). Everything the Python did over a raw
// L2CAP/ATT socket is expressed as CoreBluetooth GATT operations; CoreBluetooth
// auto-confirms indications on setNotifyValue(true) and auto-pairs/encrypts the link
// when the sensor asks for it (this shows the iOS "Bluetooth Pairing Request" prompt
// the user taps "Pair"/"Allow" on).
//
// WHAT CHANGED VS. THE macOS CLIENT (the BLE/handshake byte flow is IDENTICAL):
//   * G7Client is an ObservableObject view-model. Instead of print()/exit(), it
//     publishes @Published glucose / trendState / statusText / logLines for SwiftUI.
//   * connect()/stop() drive a repeatable connect→handshake→read cycle (the macOS
//     client ran once and exit()ed). No exit() anywhere.
//   * The global log(...) sink is routed into logLines (all existing log() call
//     sites in the handshake are kept verbatim). @Published mutations always happen
//     on the main thread.

import Foundation
@preconcurrency import CoreBluetooth
#if os(watchOS)
import WatchKit
#endif

// MARK: - Logging

private let logFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

/// A process-wide sink so the verbatim `log(...)` calls in the ported handshake can be
/// mirrored into the SwiftUI log view without threading a logger through every function.
final class LogSink: @unchecked Sendable {
    static let shared = LogSink()
    var handler: ((String) -> Void)?
}

/// Timestamped logging: to the Xcode console (NSLog) AND to the active client's log view.
func log(_ items: Any...) {
    let msg = items.map { "\($0)" }.joined(separator: " ")
    let line = "\(logFmt.string(from: Date())) \(msg)"
    NSLog("%@", line)
    LogSink.shared.handler?(line)
    LogFile.append(line)
}

/// Battery %/state tag (watchOS only) — for correlating dead-gaps with power throttling.
/// e.g. "pwr 41%/batt", "pwr 88%/chg". Off-wrist + low battery is when the workout keepalive
/// gets throttled, which is exactly when the long read-gaps appear.
func batteryTag() -> String {
    #if os(watchOS)
    let dev = WKInterfaceDevice.current()
    dev.isBatteryMonitoringEnabled = true
    let lvl = dev.batteryLevel
    let st: String
    switch dev.batteryState {
    case .charging:  st = "chg"
    case .full:      st = "full"
    case .unplugged: st = "batt"
    default:         st = "?"
    }
    return lvl < 0 ? "pwr ?/\(st)" : "pwr \(Int(lvl * 100))%/\(st)"
    #else
    return "pwr n/a"
    #endif
}

/// Appends every log line to Documents/g7watch.log so it can be pulled off-device
/// via `devicectl device copy from --domain-type appDataContainer` (autonomous testing).
enum LogFile {
    static let url: URL? = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("g7watch.log")
    static func append(_ line: String) {
        guard let url else { return }
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
func hex(_ bytes: ArraySlice<UInt8>) -> String { hex(Array(bytes)) }

// MARK: - Errors

enum G7Error: Error, CustomStringConvertible {
    case timeout(String)
    case disconnected
    case cryptoFailed(String)
    case aesVerifyFailed
    case unexpectedAuth(Int)
    case setup(String)
    case shortFrame(String)

    var description: String {
        switch self {
        case .timeout(let w):       return "timeout waiting for \(w)"
        case .disconnected:         return "peripheral disconnected"
        case .cryptoFailed(let s):  return "crypto failed: \(s)"
        case .aesVerifyFailed:      return "AES challenge verify BAD (dropped chunk?)"
        case .unexpectedAuth(let a):return "auth=\(a) unexpected (not authenticated)"
        case .setup(let s):         return "setup: \(s)"
        case .shortFrame(let s):    return "short/malformed frame: \(s)"
        }
    }
}

// MARK: - BLE identifiers

enum G7UUID {
    static let service = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
    static let auth    = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5") // 3535 opcodes / indications
    static let data    = CBUUID(string: "F8083538-849E-531C-C594-30F1F86A4EA5") // 3538 bulk payloads
    static let control = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5") // 3534 glucose
}

// MARK: - Crypto bridge (thin Swift wrappers over the C functions)

enum Crypto {
    @discardableResult
    static func initPIN(_ pin4: [UInt8]) -> Bool {
        precondition(pin4.count == 4, "pin must be 4 ASCII digits")
        return pin4.withUnsafeBufferPointer { g7_init($0.baseAddress) } == 1
    }

    /// J-PAKE round 1/2 output (which = 0 or 1): 160 bytes.
    static func round12(_ which: Int32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 160)
        out.withUnsafeMutableBufferPointer { _ = g7_round12(which, $0.baseAddress) }
        return out
    }

    /// Feed the sensor's 160-byte round payload (which 0,1,2). Returns true if valid.
    @discardableResult
    static func putPubkey(_ which: Int32, _ in160: [UInt8]) -> Bool {
        in160.withUnsafeBufferPointer { g7_put_pubkey(which, $0.baseAddress) } == 1
    }

    /// J-PAKE round 3 output: 160 bytes (nil if the C side reports failure).
    static func round3() -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 160)
        let ok = out.withUnsafeMutableBufferPointer { g7_round3($0.baseAddress) } == 1
        return ok ? out : nil
    }

    /// ECDSA-P256 proof-of-possession signature over `data`: 64 bytes (r||s).
    static func challenge(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 64)
        data.withUnsafeBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { o in
                _ = g7_challenge(inp.baseAddress, Int32(data.count), o.baseAddress)
            }
        }
        return out
    }

    /// AES-8 over the derived shared key: input 8 bytes -> output 8 bytes.
    static func aes8(_ data8: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 8)
        data8.withUnsafeBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { o in
                _ = g7_aes8(inp.baseAddress, o.baseAddress)
            }
        }
        return out
    }
}

// MARK: - Async inbound channels
//
// Delegate callbacks arrive on the central manager's serial queue. Each channel owns
// its own serial queue so buffer mutation, waiter registration and timeout firing are
// all serialized, which keeps the CheckedContinuations single-resume without locks.

/// Byte-accumulating channel for the data (3538) characteristic: `recv(n)` yields the
/// next `n` bytes, accumulating across 20-byte notifications (mirrors Python `recv`).
final class ByteStream: @unchecked Sendable {
    private let q: DispatchQueue
    private var buffer: [UInt8] = []
    private var closed = false
    private var pending: (need: Int, id: Int, cont: CheckedContinuation<[UInt8], Error>)?
    private var nextId = 0

    init(label: String) { q = DispatchQueue(label: label) }

    func append(_ bytes: [UInt8]) {
        q.async {
            self.buffer.append(contentsOf: bytes)
            self.tryResolve()
        }
    }

    func close() {
        q.async {
            self.closed = true
            if let p = self.pending { self.pending = nil; p.cont.resume(throwing: G7Error.disconnected) }
        }
    }

    private func tryResolve() {
        guard let p = pending, buffer.count >= p.need else { return }
        let out = Array(buffer.prefix(p.need))
        buffer.removeFirst(p.need)
        pending = nil
        p.cont.resume(returning: out)
    }

    func recv(_ n: Int, timeout: TimeInterval) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { cont in
            q.async {
                if self.closed { cont.resume(throwing: G7Error.disconnected); return }
                let id = self.nextId; self.nextId += 1
                self.pending = (n, id, cont)
                self.q.asyncAfter(deadline: .now() + timeout) {
                    if let p = self.pending, p.id == id {
                        self.pending = nil
                        p.cont.resume(throwing: G7Error.timeout("\(n) data bytes"))
                    }
                }
                self.tryResolve()
            }
        }
    }
}

/// Message-queue channel for the auth (3535) and control (3534) characteristics: each
/// inbound notification/indication is one discrete message. `recv(op:)` returns the next
/// message, optionally skipping ones whose first byte != op (mirrors Python `recv_auth`).
final class MessageStream: @unchecked Sendable {
    private let q: DispatchQueue
    private let name: String
    private var messages: [[UInt8]] = []
    private var closed = false
    private var pending: (op: UInt8?, id: Int, cont: CheckedContinuation<[UInt8], Error>)?
    private var nextId = 0

    init(label: String, name: String) { q = DispatchQueue(label: label); self.name = name }

    func append(_ msg: [UInt8]) {
        q.async {
            self.messages.append(msg)
            self.tryResolve()
        }
    }

    func close() {
        q.async {
            self.closed = true
            if let p = self.pending { self.pending = nil; p.cont.resume(throwing: G7Error.disconnected) }
        }
    }

    private func tryResolve() {
        guard let p = pending else { return }
        while !messages.isEmpty {
            let m = messages.removeFirst()
            if p.op == nil || m.first == p.op {
                pending = nil
                p.cont.resume(returning: m)
                return
            } else {
                log("  (skip \(name) \(hex(m)))")
            }
        }
    }

    func recv(op: UInt8? = nil, timeout: TimeInterval) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { cont in
            q.async {
                if self.closed { cont.resume(throwing: G7Error.disconnected); return }
                let id = self.nextId; self.nextId += 1
                self.pending = (op, id, cont)
                let what = op.map { String(format: "%@ op 0x%02x", self.name, $0) } ?? "\(self.name) msg"
                self.q.asyncAfter(deadline: .now() + timeout) {
                    if let p = self.pending, p.id == id {
                        self.pending = nil
                        p.cont.resume(throwing: G7Error.timeout(what))
                    }
                }
                self.tryResolve()
            }
        }
    }
}

// MARK: - G7Client (ObservableObject view-model)

final class G7Client: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {

    // MARK: Published UI state (always mutated on the main thread — see onMain()).
    @Published var glucose: Int?          // mg/dL, nil = no valid reading
    /// Fired on every fresh EGV (mg/dL + read time). The Loop integration sets this to inject the
    /// reading into the glucose store. Not @Published — it's a data sink, not UI state.
    var onEGV: ((Int, Date, UInt32) -> Void)?   // (value, on-body measurement time, sensor-clock reading id)
    // M3 (watch-from-stock): raw EGV frame hook for the stock-parsing adapter
    // (G7ClientTransportAdapter). Carries the COMPLETE control-characteristic notification
    // (opcode 0x4E frame) so stock G7GlucoseMessage(data:) can parse trend/predicted/sequence/
    // display-only — fields the inline parser and onEGV drop. Fired on every glucose
    // notification, BEFORE the legacy in-session/plausibility gate: state gating is the stock
    // manager's job in the from-stock stack.
    var onRawEGV: ((Data) -> Void)?
    // M3 (watch-from-stock): connect/disconnect hook for the stock adapter (mapped onto
    // G7SensorDelegate sensorDidConnect/sensorDisconnected). Bool = connected; String? = the
    // peripheral name when known.
    var onConnectionChange: ((Bool, String?) -> Void)?
    @Published var trendState: UInt8?     // EGV algorithm-state byte (0x06 = OK/in-session)
    @Published var statusText: String = "Idle"
    @Published var logLines: [String] = []
    @Published var isRunning: Bool = false
    @Published var autoRepeat: Bool = false {
        didSet {
            if !autoRepeat { cancelAutoRepeat() }
        }
    }
    /// The active sensor's 4-digit pairing code. PERSISTED so it survives relaunch. Set by
    /// (a) the phone relaying a new sensor's code (primary — Component A), (b) the watch's
    /// just-in-time prompt on a wrong-code auth failure (fallback), or (c) the current bench
    /// sensor's default. There's ONE active sensor at a time, so a single current-code is
    /// enough on the watch; the phone owns the per-sensor-ID keying + relay.
    static let sensorCodeKey = "g7.sensorCodeV1"
    @Published var pin: String = UserDefaults.standard.string(forKey: "g7.sensorCodeV1") ?? "3102" {
        didSet { UserDefaults.standard.set(pin, forKey: Self.sensorCodeKey) }
    }

    /// Apply a sensor pairing code (from the phone relay or the JIT prompt). Digits-only,
    /// exactly 4; ignored otherwise. Takes effect on the next connect attempt. Clears the
    /// `needsSensorCode` prompt flag.
    ///
    /// `sensorID` is supplied by the phone relay (Component A) and omitted by the watch's JIT
    /// prompt. When it names a sensor DIFFERENT from the one we last bonded, this is a genuinely
    /// new sensor: we (a) invalidate the stale bonded handle so the reader scans fresh instead of
    /// chasing a dead handle for 330s at the next Sport Mode, and (b) mark a pre-warm pending so
    /// the next foreground activation bonds it ahead of the workout.
    /// Returns true iff this was a genuinely NEW sensor (pre-warm armed) — the app uses that to
    /// schedule the "tap to enable" watch notification.
    @discardableResult
    func applySensorCode(_ code: String, sensorID: String? = nil) -> Bool {
        let digits = String(code.filter { $0.isNumber })
        guard digits.count == 4 else { return false }
        onMain { self.pin = digits; self.needsSensorCode = false }
        log("sensor code applied (\(digits.count) digits)")

        guard let sensorID, !sensorID.isEmpty,
              sensorID != UserDefaults.standard.string(forKey: Self.lastKnownSensorIDKey) else { return false }
        UserDefaults.standard.set(sensorID, forKey: Self.lastKnownSensorIDKey)
        UserDefaults.standard.set(sensorID, forKey: Self.pendingPrewarmKey)
        UserDefaults.standard.removeObject(forKey: Self.prewarmFailKey)   // fresh sensor, fresh retry budget
        cbQueue.async {   // invalidate the stale handle so beginAcquire scans for the NEW sensor
            UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
            self.savedPeripheral = nil
        }
        log("new sensor \(sensorID) — cleared stale bond, pre-warm pending")
        return true
    }

    /// Pre-warm entry — call on every FOREGROUND activation. If a new sensor's code has arrived
    /// but we haven't bonded it yet, and we're NOT in Sport Mode, run a one-time, bounded,
    /// workout-backed bond so the first Sport Mode on this sensor is a fast targeted connect
    /// instead of a cold scan. No-op unless a pre-warm is pending. MUST be foreground — the
    /// HKWorkoutSession keepalive can't be started in the background (HK error 14).
    func prewarmIfPending() {
        guard UserDefaults.standard.string(forKey: Self.pendingPrewarmKey) != nil else { return }
        guard !soakActive else { return }        // Sport Mode owns the reader; its cold path will bond
        guard !needsSensorCode else { return }   // code is known-bad (JIT prompt up) — don't hammer
        guard pin.filter({ $0.isNumber }).count == 4 else { return }   // need a valid code first
        cbQueue.async {
            guard !self.attemptActive, !self.prewarmActive else { return }   // already working
            self.prewarmActive = true
            log("=== PRE-WARM: bonding new sensor (bounded \(Int(self.prewarmWindow))s scan, workout-backed) · \(batteryTag()) ===")
            // Bounded backstop: if we never bond within the window (BT off, sensor out of range,
            // no chirp), stop cleanly and leave the pending flag set to retry next app open.
            self.prewarmTimeoutWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.prewarmActive else { return }
                log("pre-warm window elapsed — no bond; will retry on next app open")
                self.stop()   // tears down the attempt AND the pre-warm (see stop() / teardownPrewarm)
            }
            self.prewarmTimeoutWork = work
            self.cbQueue.asyncAfter(deadline: .now() + self.prewarmWindow, execute: work)
            self.onMain { self.workout.acquire("prewarm"); self.connect() }   // foreground-legal keepalive + one cycle
        }
    }

    /// Tear down an in-flight pre-warm (runs on cbQueue — finishAttempt is routed through cbQueue,
    /// and stop()/the timeout call it there too). RELEASES the "prewarm" keepalive hold: because
    /// the keepalive is reference-counted, this can never stop the session while Sport Mode's
    /// "soak" hold is present — so there is no soakActive read and no adopt-handoff race. On a
    /// successful bond it clears the pending flag; on failure it bumps a bounded retry counter and
    /// gives up after prewarmMaxFails. No-op when no pre-warm is active — normal teardown untouched.
    private func teardownPrewarm(bonded: Bool) {   // cbQueue
        guard prewarmActive else { return }
        prewarmActive = false
        prewarmTimeoutWork?.cancel(); prewarmTimeoutWork = nil
        var resolved = false   // pending flag cleared → the "tap to enable" notification is now moot
        if bonded {
            UserDefaults.standard.removeObject(forKey: Self.pendingPrewarmKey)
            UserDefaults.standard.removeObject(forKey: Self.prewarmFailKey)
            resolved = true
            log("=== PRE-WARM DONE: new sensor bonded + handle saved; first Sport Mode will be fast ===")
        } else {
            let fails = UserDefaults.standard.integer(forKey: Self.prewarmFailKey) + 1
            if fails >= prewarmMaxFails {
                UserDefaults.standard.removeObject(forKey: Self.pendingPrewarmKey)
                UserDefaults.standard.removeObject(forKey: Self.prewarmFailKey)
                resolved = true
                log("pre-warm gave up after \(fails) tries; the first Sport Mode will bond via the cold path")
            } else {
                UserDefaults.standard.set(fails, forKey: Self.prewarmFailKey)
                log("pre-warm attempt \(fails)/\(prewarmMaxFails) failed; will retry on next app open")
            }
        }
        if resolved { NotificationCenter.default.post(name: Self.prewarmDidResolveNotification, object: nil) }
        onMain { self.workout.release("prewarm") }
    }

    /// FALLBACK trigger (Component A): set when a connect reaches the sensor but the code is
    /// WRONG (aesVerifyFailed) — the watch UI shows a just-in-time code prompt. Cleared by
    /// applySensorCode. The phone-primary relay normally sets the code before we ever get
    /// here, so this is the safety net (older phone / race / mistyped).
    @Published var needsSensorCode: Bool = false

    /// Consecutive aesVerifyFailed count — the JIT prompt fires only after this REPEATS, so a
    /// rare transient decrypt glitch (a dropped BLE chunk also surfaces as aesVerifyFailed)
    /// doesn't nag. Reset on any successful read.
    private var consecutiveAuthFailures = 0

    #if FAKE_NEW_SENSOR
    // MARK: - Test hooks (Component E) — exercise the new-sensor path WITHOUT burning a real
    // sensor. Compiled OUT of release builds; enable with `-D FAKE_NEW_SENSOR` (SWIFT_ACTIVE_
    // COMPILATION_CONDITIONS). Surfaced via a debug control in the watch UI.

    /// TEST: forget the current sensor — clear the persisted bond identifier AND the stored
    /// code, so the next attempt behaves like a brand-new sensor (must rediscover via scan and
    /// needs a fresh code from the phone relay or the JIT prompt). Lets the ENTIRE first-time
    /// path — code acquisition → handshake → bond → save identifier — run against the EXISTING
    /// sensor, repeatably, for free (and it exercises the REAL handshake, not a mock). The one
    /// thing it can't vary is the code value; that's what a single real new-sensor test covers.
    func forgetCurrentSensor() {
        cbQueue.async {
            UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
            self.savedPeripheral = nil
        }
        onMain { self.pin = ""; self.needsSensorCode = false; self.consecutiveAuthFailures = 0 }
        log("TEST: forgot current sensor (cleared bond identifier + code)")
    }

    /// TEST: set a deliberately WRONG code so the next handshake fails aesVerifyFailed — to
    /// exercise the fallback JIT prompt path without a real new sensor.
    func injectWrongCode() {
        onMain { self.pin = "0000"; self.consecutiveAuthFailures = 0 }
        log("TEST: injected wrong code 0000")
    }

    /// TEST: arm a pre-warm as if a new sensor's code just arrived — clears the bonded handle and
    /// sets the pending flag while KEEPING the current (correct) code, so the next foreground
    /// activation (or a direct prewarmIfPending call) runs the ENTIRE pre-warm path — continuous
    /// scan → handshake → bond → save handle → stop keepalive — against the EXISTING sensor,
    /// repeatably, for free.
    func armPrewarm() {
        UserDefaults.standard.set("TEST-PREWARM", forKey: Self.pendingPrewarmKey)
        cbQueue.async {
            UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
            self.savedPeripheral = nil
        }
        log("TEST: armed pre-warm (cleared handle, set pending); foreground the app to fire it")
    }
    #endif

    // MARK: Coexistence / whitelabeling probe (receiver-role experiment, task #1)
    /// Client SLOT/role byte — the trailing byte of the AES-auth request (see doAesAuth).
    /// Runtime-settable (toggle in the UI) so a sweep runs in ONE install:
    ///   0x01 = concurrent/secondary slot (DEFAULT — coexists with an active phone, auth=1, PROVEN)
    ///   0x02 = phone/standard (collides with the real phone -> auth=2)
    ///   0x08 = receiver candidate, 0x04 = watch candidate (neither worked — wrong namespace)
    /// CONFIRMED as the slot selector (xDrip "keks" names it `slot`). 0x01 rides a separate
    /// channel from the phone (sensor reports maxDevices=3) — concurrent is now the common case,
    /// so it's the default; flip to 0x02 to reproduce the sole-client/collision behavior.
    @Published var authEndByte: UInt8 = {
        UserDefaults.standard.object(forKey: "authEndByte") == nil
            ? 0x01 : UInt8(UserDefaults.standard.integer(forKey: "authEndByte") & 0xff)
    }() {
        didSet { UserDefaults.standard.set(Int(authEndByte), forKey: "authEndByte") }
    }
    /// statusReply auth byte from the last handshake (1 = accepted, 2 = rejected/collision).
    @Published var lastAuthByte: Int?
    /// Raw 0xEA device-list response (the "what role did the sensor assign me" oracle) + summary.
    @Published var deviceListHex: String?
    @Published var deviceListSummary: String?

    // MARK: Soak-test stats (background-keepalive validation, task #12)
    @Published var soakActive: Bool = false
    @Published var lastReadDate: Date?               // when the last successful read landed
    @Published var maxGapSeconds: TimeInterval = 0   // largest gap between successful reads this soak
    @Published var readCount: Int = 0
    @Published var soakStartDate: Date?
    private let workout = WorkoutKeepalive()

    // Constants from the Python/macOS reference.
    static let RAND8:  [UInt8] = Array(0x11...0x18)          // AES-auth nonce
    static let RAND16: [UInt8] = Array(0x21...0x30)          // proof-of-possession nonce
    static let CERTS: [[UInt8]] = [Certs.CERT0, Certs.CERT1]
    // (authEndByte moved to a runtime-settable @Published property above — see the
    //  coexistence/whitelabeling probe section.)

    let recvTimeout: TimeInterval = 12.0
    let scanTimeout: TimeInterval = 20.0
    var autoRepeatInterval: TimeInterval = 300.0   // 5 min = the G7 EGV grid (spacing to the next ad window)
    var retryInterval: TimeInterval = 15.0         // fast retry while HUNTING the ad window (early/late/missed)
    var scanLeadTime: TimeInterval = 45.0          // start scanning this long BEFORE the predicted window

    // Pending-connect experiment (A/B vs scan): after the first scan+bond, reacquire the G7 via a
    // re-armed connect() on the Bluetooth controller's targeted path (theory: dodges the background
    // scan throttle that caps us at ~20% capture at rest) instead of scanForPeripherals. A scan
    // fallback fires if a pending connect goes quiet — so a stale bonded identifier (address
    // rotation) degrades to today's behavior instead of a silent false-negative.
    @Published var reconnectMode: Bool = UserDefaults.standard.bool(forKey: "reconnectModeV1") {
        didSet { UserDefaults.standard.set(reconnectMode, forKey: "reconnectModeV1") }
    }
    private var savedPeripheral: CBPeripheral?         // bonded G7 held for pending reconnect
    /// Persisted identifier of the bonded G7 so a COLD start (fresh app launch, which
    /// loses `savedPeripheral`) can go straight to the non-throttled targeted-connect
    /// path via retrievePeripherals — instead of a background-throttled scan that can
    /// take many minutes to catch an advertising window (the observed 53-min gap).
    private static let savedPeripheralKey = "g7.savedPeripheralUUIDv1"
    private var reconnectArmedAt: Date?                // when the current pending connect was armed
    let reconnectWatchdog: TimeInterval = 400.0        // no connect in this long → fall back to scan
    /// Cold reacquire: how long the targeted connect gets ALONE (one ~5-min advertising cycle
    /// + margin) before we treat the saved handle as stale and fall back to a scan. No scan
    /// runs during this window — a concurrent scan destabilized the fresh connection (build 69
    /// instant-drops). With a good handle the targeted connect lands well inside this.
    let coldScanFallbackDelay: TimeInterval = 330.0

    // MARK: Pre-warm — one-time, bounded, foreground-initiated bond of a NEWLY changed sensor.
    // A brand-new sensor has never been bonded, so the FIRST Sport Mode on it would have to
    // discover it by SCAN (the throttled path) — a fat-tailed wait if the wrist is down. Pre-warm
    // moves that one slow discovery OFF the workout's critical path: when the phone relays a new
    // sensor's code, we bond it opportunistically the next time the watch app is foregrounded, so
    // the first Sport Mode is a fast targeted connect. It MUST run in the foreground — HKWorkoutSession
    // (the only keepalive) can't start in the background (HK error 14). See DESIGN_NEW_SENSOR_WORKFLOW.md.
    /// Persisted "pre-warm pending for this sensorID" flag; survives suspension, retried on each
    /// foreground activation until the bond lands, then cleared.
    private static let pendingPrewarmKey = "g7.pendingPrewarmSensorIDv1"
    /// The sensorID we last saw a code for — so we can tell a genuinely NEW sensor (→ pre-warm)
    /// from a re-relay of the current one (→ nothing to do).
    private static let lastKnownSensorIDKey = "g7.lastKnownSensorIDv1"
    /// A bounded pre-warm bond is in flight (transient; cbQueue). Kept separate from `soakActive`
    /// so pre-warm never masquerades as Sport Mode in the UI/gating.
    private var prewarmActive = false
    private var prewarmTimeoutWork: DispatchWorkItem?
    /// Bounded pre-warm window: one advertising cycle (~5 min) + margin to catch a chirp on a
    /// continuous scan AND complete the handshake. On expiry we stop and retry on the next app open.
    let prewarmWindow: TimeInterval = 360.0
    /// Give up after this many failed pre-warm attempts (absent or mis-coded sensor) so we don't
    /// burn a workout+scan on EVERY foreground forever; the first Sport Mode's cold path then does
    /// the bond (no worse than pre-pre-warm). A fresh code relay resets the count and re-arms.
    private static let prewarmFailKey = "g7.prewarmFailCountV1"
    let prewarmMaxFails = 3
    /// Posted (main) when a pending pre-warm RESOLVES — the sensor bonded, or pre-warm gave up. The
    /// app observes it to pull the "new sensor — tap to enable" watch notification.
    static let prewarmDidResolveNotification = Notification.Name("com.loopkit.Loop.g7.prewarmDidResolve")

    let chunkGap: UInt64 = 50_000_000    // 50 ms between 20-byte data-char chunks
    let chunkTail: UInt64 = 200_000_000  // 200 ms after a full bulk write

    // BLE plumbing (touched on cbQueue).
    private let cbQueue = DispatchQueue(label: "g7.cb")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral!
    private var authChar: CBCharacteristic?
    private var dataChar: CBCharacteristic?
    private var ctrlChar: CBCharacteristic?

    // Inbound channels — recreated fresh for each connect attempt.
    private var dataStream = ByteStream(label: "g7.data")
    private var authStream = MessageStream(label: "g7.auth", name: "auth")
    private var ctrlStream = MessageStream(label: "g7.ctrl", name: "ctrl")

    // Discovery: collect candidates over a short window, then connect to the strongest —
    // during a pending sensor swap, preferring the candidate whose advertised name matches
    // the phone-relayed sensor ID (suffix-2 rule, same as stock G7Sensor).
    private var candidates: [(p: CBPeripheral, rssi: Int, name: String)] = []
    private var scanWindowStarted = false
    private var scanTimeoutWork: DispatchWorkItem?

    // Continuations bridged from delegate callbacks (all touched on cbQueue).
    private var writeCont: CheckedContinuation<Void, Error>?
    private var notifyConts: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    // Attempt lifecycle (touched on cbQueue).
    private var pin4: [UInt8] = Array("3102".utf8)
    private var finished = false
    private var attemptActive = false
    /// Monotonic identity for the current connect→handshake→read attempt (bumped every time an
    /// attempt starts). runHandshake runs on a Task executor and its finishAttempt hops back onto
    /// cbQueue several hops later; if the attempt was SUPERSEDED in between (Sport Mode preempting
    /// a pre-warm, or a Bluetooth toggle re-arming), a stale terminus must NOT tear down the fresh
    /// attempt. attemptActive alone can't tell them apart (it's true for BOTH), so the terminus is
    /// gated on this generation matching the one captured when the handshake began.
    private var attemptGeneration = 0
    /// The in-flight handshake Task (touched on cbQueue). Cancelled whenever the attempt is
    /// superseded or torn down, so two handshakes can never interleave writes on one link —
    /// the generation gate protects the terminus, this protects the link itself.
    private var handshakeTask: Task<Void, Never>?

    /// Fix B (radio arbiter, ported from g7-build-next c6c9e18f): true ONLY during the ACTIVE
    /// handshake — set at didConnect (the ~8-10s heavy J-PAKE/cert burst that saturates the
    /// single watch radio) and cleared at finishAttempt. Deliberately NOT set during the idle
    /// scan / pending-connect wait (the lightweight "pounce"); blocking the pod through those
    /// long idle waits would be wrong. Read cross-thread from the pod command paths so a LOOP
    /// pod command yields to an in-flight handshake instead of colliding with it ("Empty
    /// Value"); the pod retries next cycle. The G7 never yields to the pod, so a reading is
    /// never at risk. Written on cbQueue / in finishAttempt; NSLock-guarded.
    private let handshakeActiveLock = NSLock()
    private var _handshakeActive = false
    var isHandshakeActive: Bool {
        handshakeActiveLock.lock(); defer { handshakeActiveLock.unlock() }
        return _handshakeActive
    }
    private func setHandshakeActive(_ active: Bool) {
        handshakeActiveLock.lock(); _handshakeActive = active; handshakeActiveLock.unlock()
    }
    private var wantConnect = false
    private var autoRepeatWork: DispatchWorkItem?

    override init() {
        super.init()
        // Default the role byte to 0x01 (concurrent slot) now that coexistence is proven and is
        // the common case. One-time reset of any stale 0x02 persisted by an earlier build.
        if !UserDefaults.standard.bool(forKey: "roleByteDefaultV2") {
            authEndByte = 0x01
            UserDefaults.standard.set(true, forKey: "roleByteDefaultV2")
        }
        // Route the verbatim log(...) sink into the SwiftUI log view.
        LogSink.shared.handler = { [weak self] line in
            self?.onMain { self?.appendLog(line) }
        }
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log("=== G7Watch build \(v) (\(b)) · \(batteryTag()) ===")
    }

    // MARK: Main-thread helpers for @Published state

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }
    private func setStatus(_ s: String) { onMain { self.statusText = s } }

    // MARK: Public API (called from the UI / main thread)

    /// Begin a single connect → handshake → glucose-read cycle. Safe to call repeatedly.
    func connect() {
        // Validate the pairing code up front.
        let digits = pin.filter { $0.isNumber }
        guard digits.count == 4 else {
            setStatus("PIN must be exactly 4 digits")
            return
        }
        let pinBytes = Array(digits.utf8)

        onMain { self.isRunning = true; self.statusText = "Starting…" }
        cbQueue.async {
            guard !self.attemptActive else { return }
            self.attemptActive = true
            self.attemptGeneration &+= 1   // new attempt identity (see attemptGeneration / runHandshake guard)
            self.finished = false
            self.setHandshakeActive(false)   // Fix B: a fresh attempt begins in the lightweight pounce phase
            self.wantConnect = true
            self.pin4 = pinBytes

            log("=== G7 iOS attempt starting (pin \(digits)) · \(batteryTag()) ===")
            log("initializing crypto (g7_init)")
            guard Crypto.initPIN(pinBytes) else {
                log("*** FATAL: g7_init failed (crypto/cert/openssl setup) ***")
                self.finishAttempt(success: false, message: "Crypto init failed")
                return
            }

            if self.central == nil {
                // Creating the central triggers centralManagerDidUpdateState, which
                // starts the scan once Bluetooth reports .poweredOn.
                self.central = CBCentralManager(delegate: self, queue: self.cbQueue)
                log("central manager created; waiting for Bluetooth to power on…")
            } else if self.central.state == .poweredOn {
                self.beginAcquire()
            } else {
                log("Bluetooth not ready (state \(self.central.state.rawValue)); waiting…")
            }
        }
    }

    /// Stop everything: cancel auto-repeat, stop scanning, disconnect. Safe any time.
    func stop() {
        onMain { self.autoRepeat = false }   // so a late success can't re-arm scheduleAutoRepeat
        cancelAutoRepeat()
        cbQueue.async {
            self.wantConnect = false
            self.scanTimeoutWork?.cancel(); self.scanTimeoutWork = nil
            self.handshakeTask?.cancel(); self.handshakeTask = nil
            if self.central != nil, self.central.state == .poweredOn { self.central.stopScan() }
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.dataStream.close(); self.authStream.close(); self.ctrlStream.close()
            if self.attemptActive {
                self.attemptActive = false
                self.finished = true   // suppress the disconnect->fail path
            }
            self.teardownPrewarm(bonded: false)   // release a pre-warm keepalive if one was running
            self.onMain { self.isRunning = false; self.statusText = "Stopped" }
        }
    }

    private func cancelAutoRepeat() {
        cbQueue.async { self.autoRepeatWork?.cancel(); self.autoRepeatWork = nil }
    }

    // MARK: Soak test — HKWorkoutSession keepalive + periodic poll, with continuity stats.

    /// Begin a background soak: start the workout-session keepalive, then poll every
    /// `autoRepeatInterval` (5 min). Each successful read updates the freshness stats so a
    /// glance shows current staleness + the worst gap this session (task #12).
    func startSoak() {
        // Hold the keepalive for "soak" FIRST (before preempting any pre-warm) so the session never
        // lapses across the handoff — reference-counted, so this adopts a live pre-warm session.
        workout.acquire("soak")
        // Preempt an in-flight pre-warm: tear its attempt DOWN and release its keepalive hold, then
        // Sport Mode starts a fresh, properly-bounded attempt below. We don't try to keep the
        // in-flight attempt — a still-scanning pre-warm has no backstop of its own once we cancel
        // its timer, and a mid-handshake one re-bonds in seconds anyway (the sensor is right here).
        cbQueue.async {
            if self.prewarmActive {
                self.prewarmActive = false
                self.prewarmTimeoutWork?.cancel(); self.prewarmTimeoutWork = nil
                self.scanTimeoutWork?.cancel(); self.scanTimeoutWork = nil
                self.handshakeTask?.cancel(); self.handshakeTask = nil
                if self.central != nil, self.central.state == .poweredOn { self.central.stopScan() }
                if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
                self.dataStream.close(); self.authStream.close(); self.ctrlStream.close()
                self.attemptActive = false
                self.finished = true
                self.workout.release("prewarm")   // hand the hold to "soak" (already acquired above)
            }
        }
        onMain {
            self.soakStartDate = Date()
            self.lastReadDate = nil
            self.maxGapSeconds = 0
            self.readCount = 0
            self.soakActive = true
        }
        log("=== SOAK START: role 0x\(String(format: "%02X", authEndByte)) · predictive \(Int(autoRepeatInterval))s grid (lead \(Int(scanLeadTime))s) · \(batteryTag()) ===")
        autoRepeat = true
        connect()
    }

    /// Re-arm the workout keepalive if it died — e.g. watchOS relaunched the app in the
    /// BACKGROUND (post-update), where HKWorkoutSession.start fails with HK error 14 and the
    /// reader silently suspends. Called on every foreground activation; the refcount decides
    /// whether anything (soak/prewarm) still wants it, so no soakActive gate here.
    func ensureKeepalive() {
        workout.ensureRunning()
    }

    /// End the soak: release the "soak" keepalive hold and stop all polling. The session actually
    /// ends only when no other holder (a pre-warm) still wants it.
    func stopSoak() {
        onMain { self.soakActive = false }
        log("=== SOAK STOP ===")
        workout.release("soak")
        stop()
    }

    /// Record a successful fresh reading for the soak continuity stats (main thread).
    private func recordReading() {
        let now = Date()
        if let last = lastReadDate {
            let gap = now.timeIntervalSince(last)
            if gap > maxGapSeconds { maxGapSeconds = gap }
        }
        lastReadDate = now
        readCount += 1
    }

    // MARK: Attempt teardown

    /// Finish the current attempt (success or failure) WITHOUT exiting the process.
    /// Cleans up the link and, if auto-repeat is on, schedules the next read.
    private func finishAttempt(success: Bool, message: String) {   // on cbQueue
        scanTimeoutWork?.cancel(); scanTimeoutWork = nil
        handshakeTask?.cancel(); handshakeTask = nil   // attempt over — a lingering task must not keep retrying
        if central != nil, central.state == .poweredOn { central.stopScan() }
        if success, let p = peripheral {
            savedPeripheral = p                        // hold the bonded G7 for pending reconnect
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedPeripheralKey)   // survive relaunch
        }
        // NOTE: we deliberately do NOT clear the pending-pre-warm flag on a generic success — during
        // a G7 sensor OVERLAP (old + new both transmitting ~12h) an in-flight attempt using the OLD
        // code can succeed reading the OLD sensor and would wrongly drop the NEW sensor's pending
        // pre-warm. The flag is cleared only by a genuine pre-warm resolution in teardownPrewarm.
        // Cost: a Sport-Mode-preempted pre-warm triggers one redundant, self-correcting pre-warm
        // later — cheap, and strictly safer than a wrong-clear.
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        dataStream.close(); authStream.close(); ctrlStream.close()
        attemptActive = false
        setHandshakeActive(false)   // Fix B: handshake window closed → the pod may use the radio again
        teardownPrewarm(bonded: success)   // no-op unless a pre-warm bond was in flight
        let useReconnect = reconnectMode && savedPeripheral != nil
        onMain {
            self.isRunning = false
            self.statusText = message
            if self.autoRepeat {
                // PREDICTIVE scheduler. The G7 disconnects after every read BY DESIGN (connect-
                // per-reading) and only re-advertises on its fixed ~5-min EGV grid. So after a
                // GOOD read, sleep until scanLeadTime before the next window (no continuous scan
                // = big battery saving); after a FAILURE, hunt fast (retryInterval) to catch a
                // window we're early/late/missed for. Disconnect-after-read is expected, not a fault.
                // RECONNECT MODE (A/B): skip sleep+scan — re-arm a pending connect() after a brief
                // settle and let the OS's targeted path wait out the ~5-min gap (theory: no throttle).
                let next = useReconnect ? 3.0
                         : (success ? max(self.retryInterval, self.autoRepeatInterval - self.scanLeadTime)
                                    : self.retryInterval)
                self.scheduleAutoRepeat(after: next)
            }
        }
    }

    private func scheduleAutoRepeat(after interval: TimeInterval) {   // called on main
        cbQueue.async {
            self.autoRepeatWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.autoRepeat, !self.attemptActive else { return }
                self.onMain { self.connect() }
            }
            self.autoRepeatWork = work
            self.cbQueue.asyncAfter(deadline: .now() + interval, execute: work)
            log("next attempt in \(Int(interval))s · \(batteryTag())")
        }
    }

    // MARK: Acquisition — scan (default) or pending-connect (A/B experiment)

    private func beginAcquire() {   // on cbQueue
        if prewarmActive {
            // Pre-warm always SCANS for the new (never-bonded) sensor — never a targeted reconnect
            // to a stale handle. beginScan runs continuously for the whole bounded pre-warm window.
            beginScan()
        } else if reconnectMode, let saved = savedPeripheral {
            // WARM: in-memory bonded handle → targeted pending connect (the proven 15/15 path).
            beginReconnect(saved)
        } else if reconnectMode, let restored = restorePersistedPeripheral() {
            // COLD (post-relaunch/crash): no in-memory handle, but the bonded identifier is
            // persisted. Restore it and run the non-throttled targeted connect IN PARALLEL with
            // a scan. The targeted path catches the sensor's sparse advertisement that a
            // throttled background scan misses — the whole reason warm reconnect is 15/15 while
            // cold scan whiffs — and the concurrent scan is the safety net so a STALE handle (a
            // new sensor) can never block discovery the way the reverted retrievePeripherals-only
            // version did (it armed a targeted connect with a 400s watchdog and NO scan).
            beginColdReacquire(restored)
        } else {
            // No handle at all (first-ever sensor, or the OS forgot the bond) → scan only.
            beginScan()
        }
    }

    /// Restore the bonded G7 by its PERSISTED identifier (survives relaunch, unlike the
    /// in-memory `savedPeripheral`). This is what lets a cold start take the non-throttled
    /// targeted-connect path instead of a background-throttled scan. Returns nil if we've
    /// never bonded, the OS no longer knows the peripheral, or Bluetooth isn't up yet.
    private func restorePersistedPeripheral() -> CBPeripheral? {
        guard central?.state == .poweredOn,
              let s = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
              let uuid = UUID(uuidString: s) else { return nil }
        return central.retrievePeripherals(withIdentifiers: [uuid]).first
    }

    /// COLD-start reacquire: a targeted `connect()` to the restored bonded peripheral
    /// (non-throttled) running CONCURRENTLY with a scan (the safety net for a stale/changed
    /// sensor). Whichever path yields a connection first wins — `didConnect` stops the scan;
    /// `didDiscover` drops a stale targeted handle before connecting to the discovered sensor.
    /// A SINGLE watchdog gives up only if BOTH stay silent, so — unlike the reverted version —
    /// a bad restored handle can never blind us: the scan runs the whole time.
    private func beginColdReacquire(_ p: CBPeripheral) {   // on cbQueue
        candidates = []
        scanWindowStarted = false
        finished = false
        dataStream = ByteStream(label: "g7.data")
        authStream = MessageStream(label: "g7.auth", name: "auth")
        ctrlStream = MessageStream(label: "g7.ctrl", name: "ctrl")

        peripheral = p
        peripheral.delegate = self
        reconnectArmedAt = Date()
        setStatus("Reconnecting…")
        log("cold reacquire: targeted connect → \(p.identifier) (scan fallback after \(Int(coldScanFallbackDelay))s)")
        // TARGETED CONNECT ONLY — no concurrent scan. Scanning while a fresh connection is
        // being established was destabilizing it (build 69: connect → instant "device has
        // disconnected" before the handshake, ONLY on this cold path; the scan-free warm path
        // never dropped). With a good saved handle — the common case — the targeted connect
        // catches the next ~5-min advertisement cleanly and cheaply, and no scan ever runs.
        central.connect(p, options: nil)

        // DELAYED fallback: only if the targeted connect hasn't fired within one advertising
        // cycle+ (coldScanFallbackDelay) — meaning the saved handle is stale (a new/changed
        // sensor the OS still resolves, or a dead bond) — drop it and scan to rediscover. That
        // keeps the scan a genuine corner case (new sensors are normally seeded via onboarding
        // pre-warm), removes the concurrent-scan interference, and saves an always-on scan's
        // battery. A successful scan re-persists the real handle → self-healing.
        scanTimeoutWork?.cancel()
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.attemptActive, self.peripheral?.state != .connected else { return }
            log("cold reacquire: targeted connect quiet \(Int(self.coldScanFallbackDelay))s — handle likely stale, falling back to scan")
            self.central.cancelPeripheralConnection(p)
            self.savedPeripheral = nil
            self.peripheral = nil
            self.beginScan()   // beginScan arms its own scan-window timeout → finishAttempt if empty
        }
        scanTimeoutWork = fallback
        cbQueue.asyncAfter(deadline: .now() + coldScanFallbackDelay, execute: fallback)
    }

    /// Pending-connect reacquire (no scan): re-arm connect() on the held bonded peripheral so the
    /// Bluetooth controller's targeted path catches the G7's next advertisement — the theory being
    /// this path is NOT duty-cycle-throttled like a background scan. Falls back to a fresh scan if
    /// the pending connect stays quiet (out of range, or the bonded identifier went stale).
    private func beginReconnect(_ p: CBPeripheral) {   // on cbQueue
        candidates = []
        scanWindowStarted = false
        finished = false
        dataStream = ByteStream(label: "g7.data")
        authStream = MessageStream(label: "g7.auth", name: "auth")
        ctrlStream = MessageStream(label: "g7.ctrl", name: "ctrl")

        peripheral = p
        peripheral.delegate = self
        reconnectArmedAt = Date()
        setStatus("Reconnecting…")
        log("pending connect armed → \(p.identifier) (no scan)")
        central.connect(p, options: nil)

        scanTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.attemptActive, self.peripheral?.state != .connected else { return }
            log("pending connect quiet \(Int(self.reconnectWatchdog))s — falling back to scan")
            self.central.cancelPeripheralConnection(p)
            self.savedPeripheral = nil
            self.peripheral = nil
            self.beginScan()
        }
        scanTimeoutWork = work
        cbQueue.asyncAfter(deadline: .now() + reconnectWatchdog, execute: work)
    }

    // MARK: Scanning

    private func beginScan() {   // on cbQueue
        // Fresh per-attempt state + channels.
        candidates = []
        scanWindowStarted = false
        finished = false
        dataStream = ByteStream(label: "g7.data")
        authStream = MessageStream(label: "g7.auth", name: "auth")
        ctrlStream = MessageStream(label: "g7.ctrl", name: "ctrl")

        setStatus("Scanning for G7…")
        log("scanning for G7 (service \(G7UUID.service.uuidString) / name DXCM*)")
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        // Fail gracefully if no sensor turns up in the scan window. Pre-warm SKIPS this short
        // cutoff: it scans continuously for the whole bounded pre-warm window (its own
        // prewarmTimeoutWork is the single backstop), because catching the sensor's sparse ~5-min
        // chirp needs far longer than the 20s a normal attempt allows.
        guard !prewarmActive else { return }
        scanTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.attemptActive, self.peripheral == nil else { return }
            log("scan timed out — no G7 found")
            self.finishAttempt(success: false, message: "No G7 sensor found (in range?)")
        }
        scanTimeoutWork = work
        cbQueue.asyncAfter(deadline: .now() + scanTimeout, execute: work)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("Bluetooth poweredOn")
            // Fires on the FIRST start (connect() created the central and is waiting for BT)
            // and when BT is toggled back ON mid-session. WEDGE FIX (safe half, kept): clear a
            // stale `peripheral` left from before a power-off — it used to block the old
            // `peripheral == nil` gate and stall the reader until relaunch. Then route through
            // beginAcquire so the COLD first-connect takes the persisted-UUID targeted connect
            // (∥ scan) — NOT a bare scan. (The earlier retrievePeripherals-only routing was
            // reverted for regressing first-connect; beginColdReacquire's concurrent scan is
            // the fix that makes this safe.)
            guard wantConnect else { return }
            if let p = peripheral, p.state != .connected { central.cancelPeripheralConnection(p) }
            peripheral = nil
            scanWindowStarted = false
            attemptActive = true
            attemptGeneration &+= 1   // BT-toggle resume is a new attempt too — supersede any stale handshake
            handshakeTask?.cancel(); handshakeTask = nil   // …and stop the stale task from touching the link
            beginAcquire()
        case .poweredOff:
            log("Bluetooth is powered OFF")
            if attemptActive { finishAttempt(success: false, message: "Bluetooth is off") }
            else { setStatus("Bluetooth is off") }
        case .unauthorized:
            log("Bluetooth unauthorized — grant permission in Settings")
            if attemptActive { finishAttempt(success: false, message: "Bluetooth permission denied") }
            else { setStatus("Bluetooth permission denied") }
        case .unsupported:
            log("Bluetooth LE unsupported on this device")
            if attemptActive { finishAttempt(success: false, message: "Bluetooth LE unsupported") }
        default:
            log("Bluetooth state: \(central.state.rawValue) (waiting)")
            setStatus("Waiting for Bluetooth…")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let matches = services.contains(G7UUID.service) || name.uppercased().hasPrefix("DXCM")
        guard matches else { return }

        if !candidates.contains(where: { $0.p.identifier == peripheral.identifier }) {
            log("  discovered candidate '\(name.isEmpty ? "?" : name)' \(peripheral.identifier) RSSI=\(RSSI)")
            candidates.append((peripheral, RSSI.intValue, name))
        }

        // Collect for ~2s, then pick the strongest RSSI and connect.
        if !scanWindowStarted {
            scanWindowStarted = true
            cbQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                // Bail if a concurrent targeted connect (cold reacquire) already won.
                guard let self, !self.candidates.isEmpty, self.attemptActive,
                      self.peripheral?.state != .connected else { return }
                self.central.stopScan()
                // SENSOR-SWAP guard: while a new sensor's bond is pending (overlap window — the
                // old sensor may still be chirping), prefer candidates whose advertised name
                // matches the phone-relayed sensor ID (suffix-2 rule, same as stock
                // G7Sensor.shouldConnectPeripheral). Falls back to ALL candidates when nothing
                // matches, so a name mismatch can never blind the scan.
                var pool = self.candidates
                if UserDefaults.standard.string(forKey: Self.pendingPrewarmKey) != nil,
                   let expected = UserDefaults.standard.string(forKey: Self.lastKnownSensorIDKey),
                   expected.count >= 2 {
                    let matching = pool.filter { $0.name.count >= 2 && $0.name.suffix(2) == expected.suffix(2) }
                    if !matching.isEmpty {
                        if matching.count < pool.count {
                            log("  sensor swap pending: preferring ID match …\(expected.suffix(2)) (\(matching.count)/\(pool.count) candidates)")
                        }
                        pool = matching
                    }
                }
                let best = pool.max(by: { $0.rssi < $1.rssi })!
                // Cold reacquire: if a targeted connect to a DIFFERENT (stale) handle is
                // pending, drop it before connecting to the freshly discovered sensor.
                if let cur = self.peripheral, cur.identifier != best.p.identifier {
                    self.central.cancelPeripheralConnection(cur)
                }
                self.peripheral = best.p
                self.peripheral.delegate = self
                log("connecting to strongest candidate \(best.p.identifier) RSSI=\(best.rssi)")
                self.setStatus("Connecting…")
                self.central.connect(best.p, options: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        central.stopScan()                                        // cold reacquire ran a concurrent scan
        scanTimeoutWork?.cancel(); scanTimeoutWork = nil          // stop the reconnect/cold watchdog
        if let armed = reconnectArmedAt {
            log("pending connect FIRED after \(Int(Date().timeIntervalSince(armed)))s")   // key A/B metric
            reconnectArmedAt = nil
        }
        log("*** CONNECTED — discovering services ***")
        setHandshakeActive(true)   // Fix B: heavy handshake begins → a loop pod command yields the radio to this read
        onConnectionChange?(true, peripheral.name)   // M3 (watch-from-stock): stock-adapter hook
        setStatus("Connected — discovering…")
        peripheral.discoverServices([G7UUID.service])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("connect failed: \(error?.localizedDescription ?? "unknown")")
        if attemptActive { finishAttempt(success: false, message: "Connect failed") }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("!! disconnected (\(error?.localizedDescription ?? "clean"))")
        onConnectionChange?(false, peripheral.name)   // M3 (watch-from-stock): stock-adapter hook
        dataStream.close(); authStream.close(); ctrlStream.close()
        // If we disconnected before finishing, the awaiting handshake throws .disconnected
        // and runHandshake() -> finishAttempt() reports it. Do NOT exit the app.
        if !finished && attemptActive {
            finishAttempt(success: false, message: "Disconnected during handshake")
        }
        // Otherwise this is the EXPECTED post-read disconnect (the G7 hangs up after each
        // reading) — nothing to recover; the predictive scheduler already queued the next window.
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("discoverServices error: \(error)"); if attemptActive { finishAttempt(success: false, message: "Service discovery failed") }; return }
        guard let svc = peripheral.services?.first(where: { $0.uuid == G7UUID.service }) else {
            log("G7 service not found"); if attemptActive { finishAttempt(success: false, message: "G7 service not found") }; return
        }
        peripheral.discoverCharacteristics([G7UUID.auth, G7UUID.data, G7UUID.control], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log("discoverCharacteristics error: \(error)"); if attemptActive { finishAttempt(success: false, message: "Characteristic discovery failed") }; return }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case G7UUID.auth:    authChar = c
            case G7UUID.data:    dataChar = c
            case G7UUID.control: ctrlChar = c
            default: break
            }
        }
        guard authChar != nil, dataChar != nil, ctrlChar != nil else {
            log("missing one of auth/data/control characteristics")
            if attemptActive { finishAttempt(success: false, message: "Missing G7 characteristics") }
            return
        }
        log("characteristics found: auth(3535), data(3538), control(3534)")
        setStatus("Authenticating…")
        // Kick off the linear async handshake. Cancel any superseded one first — its terminus is
        // already generation-gated, but the task itself must stop touching the link.
        handshakeTask?.cancel()
        let gen = attemptGeneration   // snapshot on cbQueue so a superseded handshake can't tear down a fresh attempt
        handshakeTask = Task { await self.runHandshake(generation: gen) }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("  didUpdateValue error on \(characteristic.uuid): \(error)"); return }
        let bytes = [UInt8](characteristic.value ?? Data())
        switch characteristic.uuid {
        case G7UUID.data:
            dataStream.append(bytes)
        case G7UUID.auth:
            log("  IND auth<- \(hex(bytes))")
            authStream.append(bytes)
        case G7UUID.control:
            log("  NTF ctrl<- \(hex(bytes))")
            ctrlStream.append(bytes)
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Only .withResponse writes produce this callback.
        let c = writeCont; writeCont = nil
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let c = notifyConts.removeValue(forKey: characteristic.uuid)
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    // MARK: Write / notify helpers (async)

    private func setNotify(_ characteristic: CBCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cbQueue.async {
                guard let p = self.peripheral else {   // nil after a BT toggle / stale-handle fallback
                    cont.resume(throwing: G7Error.disconnected)
                    return
                }
                self.notifyConts[characteristic.uuid] = cont
                p.setNotifyValue(true, for: characteristic)
            }
        }
    }

    /// Write with response (mirrors Python `wreq`): awaits the ATT write response.
    private func writeResp(_ characteristic: CBCharacteristic, _ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cbQueue.async {
                guard let p = self.peripheral else {   // nil after a BT toggle / stale-handle fallback
                    cont.resume(throwing: G7Error.disconnected)
                    return
                }
                self.writeCont = cont
                p.writeValue(Data(bytes), for: characteristic, type: .withResponse)
            }
        }
    }

    /// Bulk write to the data (3538) characteristic in 20-byte .withoutResponse chunks
    /// with ~50ms spacing (mirrors Python `send_ext`). With-response is rejected by 3538.
    private func writeDataChunks(_ payload: [UInt8]) async {
        var i = 0
        while i < payload.count {
            if Task.isCancelled { return }   // superseded attempt: stop touching the link
            let end = min(i + 20, payload.count)
            let chunk = Array(payload[i..<end])
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                cbQueue.async {
                    if let p = self.peripheral, let dc = self.dataChar {
                        p.writeValue(Data(chunk), for: dc, type: .withoutResponse)
                    }   // else: link torn down mid-bulk-write — drop the chunk; the next recv fails cleanly
                    cont.resume()
                }
            }
            try? await Task.sleep(nanoseconds: chunkGap)
            i += 20
        }
        try? await Task.sleep(nanoseconds: chunkTail)
    }

    // MARK: The handshake — linear port of the macOS client / g7att_new.py

    private func runHandshake(generation gen: Int) async {
        do {
            try await handshake()
            finished = true
            log("*** SUCCESS — full G7 handshake to live glucose on iOS! ***")
            consecutiveAuthFailures = 0
            onMain { self.needsSensorCode = false }
            let g = await MainActor.run { self.glucose }
            let msg = g.map { "Glucose \($0) mg/dL" } ?? "Read complete (no value)"
            // Read done. Disconnect (the G7 will drop us in a few seconds anyway) and let the
            // predictive scheduler queue the next 5-min window. runHandshake runs on the Task
            // cooperative executor, NOT cbQueue — so hop back onto cbQueue to serialize teardown
            // (incl. teardownPrewarm) with startSoak's preempt block and every other reader mutation.
            cbQueue.async { if self.attemptActive, self.attemptGeneration == gen { self.finishAttempt(success: true, message: msg) } }
        } catch is CancellationError {
            log("handshake superseded — cancelled cleanly")
        } catch {
            log("*** FAILED: \(error) ***")
            // A WRONG CODE surfaces as aesVerifyFailed at the AES challenge step — but so can a
            // rare dropped BLE chunk. Only raise the JIT code prompt after it REPEATS, so a
            // transient decrypt glitch doesn't nag. (The phone-primary relay normally sets the
            // right code before we ever reach here — this is the fallback.)
            if case G7Error.aesVerifyFailed = error {
                consecutiveAuthFailures += 1
                if consecutiveAuthFailures >= 2 { onMain { self.needsSensorCode = true } }
            }
            // Same as the success path: hop onto cbQueue so teardown is serialized (not run from
            // the Task executor, which would race the cbQueue reader state).
            cbQueue.async { if self.attemptActive, self.attemptGeneration == gen { self.finishAttempt(success: false, message: "Failed: \(error)") } }
        }
    }

    // Linear async handshake mirroring the macOS `handshake()`. BYTE FLOW IS VERBATIM.
    private func handshake() async throws {
        let auth = authChar!, data = dataChar!, ctrl = ctrlChar!

        // 1) Subscribe: data(3538) notify, auth(3535) indicate. CoreBluetooth auto-confirms
        //    indications, so there are no manual CCCD writes / ATT confirmations to manage.
        try await setNotify(data)
        try await setNotify(auth)
        log("subscribed: 3538 notify, 3535 indicate")

        // 2) J-PAKE, rounds 0,1,2.
        try await doJPake(auth: auth)

        // 3) AES authentication.
        let (authByte, bondByte) = try await doAesAuth(auth: auth)
        guard authByte == 1 || authByte == 2 else { throw G7Error.unexpectedAuth(authByte) }

        // 4) Certificate exchange + proof-of-possession + bond gate.
        //    On iOS the link encryption/pairing that the Pi did by hand is initiated
        //    automatically by CoreBluetooth when the sensor requires it (showing the
        //    system pairing prompt). Always run the full cert exchange + bond gate —
        //    even on a bonded reconnect (bond=1). A bonded reconnect does NOT re-encrypt
        //    the link automatically, and the "bond=1 shortcut" left the link unencrypted
        //    → the sensor dropped us at the encrypted glucose read. The full flow
        //    re-establishes encryption (matches the Pi). If the sensor withholds a step
        //    here, the retry loop just reconnects.
        do {
            try await doCerts(auth: auth)
            log("-> KeepAlive [06 19]")
            try await writeResp(auth, [0x06, 0x19])
            // Wait for the bond gate: an auth indication beginning with 0x06 (…the [06 00]).
            let gate = try await authStream.recv(op: 0x06, timeout: recvTimeout)
            log("*** BOND-READY / gate \(hex(gate)) (bond=\(bondByte)) ***")
        } catch {
            log("  cert/gate step failed on reconnect (bond=\(bondByte)): \(error) — proceeding to glucose anyway")
        }

        // 5) Glucose read — factored into readEGV so the persistent re-poll can reuse it on the
        //    already-subscribed, encrypted link (no rescan, no re-handshake).
        try await readEGV(ctrl: ctrl)
    }

    /// Read one EGV on the subscribed, encrypted control(3534) link: write [0x4E], parse the
    /// notification, update glucose + soak stats, read back the device-list.
    ///
    /// The control char requires an ENCRYPTED link. On the very first read, touching it makes
    /// CoreBluetooth initiate SMP pairing; the first access can return "Encryption is insufficient"
    /// (CBATTError 15) while pairing completes — so wait and retry. On a held/bonded link the first
    /// attempt succeeds immediately.
    private func readEGV(ctrl: CBCharacteristic) async throws {
        setStatus("Reading glucose…")
        var egv: [UInt8] = []
        var gotEGV = false
        for attempt in 1...8 {
            try Task.checkCancellation()   // superseded/torn-down attempt: stop retrying, leave the link alone
            do {
                try await setNotify(ctrl)
                log("-> glucose [4E] (attempt \(attempt))")
                try await writeResp(ctrl, [0x4E])
                // M6 (58c646df port): require the EGV echo opcode 0x4E; a stray control
                // notification (e.g. a late 0xEA device-list) must not be parsed as glucose.
                egv = try await ctrlStream.recv(op: 0x4E, timeout: recvTimeout)
                gotEGV = true
                break
            } catch {
                log("  glucose attempt \(attempt): \(error) — waiting for pairing/encryption…")
                setStatus("Pairing… tap Pair/Allow if prompted (\(attempt))")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        guard gotEGV else { throw G7Error.timeout("glucose read — encryption/pairing never established") }
        log("*** GLUCOSE<- \(hex(egv)) ***")

        onRawEGV?(Data(egv))   // M3 (watch-from-stock): full frame to the stock-parsing adapter

        let rawEGV: Int = egv.count >= 14 ? Int(egv[12]) | (Int(egv[13]) << 8) : 0xffff
        let value: Int? = rawEGV == 0xffff ? nil : (rawEGV & 0x0fff)
        let state: UInt8? = egv.count >= 15 ? egv[14] : nil

        // Sensor-TIME timestamping (mirrors G7SensorKit/G7GlucoseMessage byte layout): bytes 2-5 =
        // the sensor clock at message time; bytes 10-11 = the reading's AGE (sec from on-body
        // measurement to BLE comms). The TRUE measurement time is Date()-age — NOT Date() (the
        // read-completion time, which we used before). `glucoseTimestamp` (messageTimestamp-age) is
        // the reading's STABLE sensor-clock id; the store syncIdentifier is derived from it so a
        // RE-READ of the same EGV dedups instead of looking like a fresh reading (which, stamped
        // Date(), could defeat the loop's staleness gate and dose off stale BG — safety-audit HIGH).
        let msgTimestamp: UInt32 = egv.count >= 6
            ? UInt32(egv[2]) | (UInt32(egv[3]) << 8) | (UInt32(egv[4]) << 16) | (UInt32(egv[5]) << 24)
            : 0
        let egvAge: UInt16 = egv.count >= 12 ? UInt16(egv[10]) | (UInt16(egv[11]) << 8) : 0
        let glucoseTimestamp = msgTimestamp &- UInt32(egvAge)      // reading's fixed sensor-clock id
        let readingDate = Date().addingTimeInterval(-Double(egvAge))   // true on-body measurement time

        let valStr = value.map { "\($0)" } ?? "nil"
        log(String(format: "*** VALUE = \(valStr) mg/dL  state=0x%02x (0x06=OK/in-session)  rawEGV=0x%04x  age=\(egvAge)s ***",
                   Int(state ?? 0), rawEGV))

        onMain {
            self.glucose = value       // DISPLAY: show whatever we got (even non-OK)
            self.trendState = state
            if let value {
                self.recordReading()
                // GATE the LOOP feed (not the display): only inject a real in-session EGV
                // (state 0x06) within a physiologically plausible range. A warmup/ending/
                // error reading with a numeric value must NOT enter the glucose store as a
                // full-effect CGM sample and drive dosing (design §2.6 / topGap).
                let inSession = (state == 0x06)
                let plausible = (value >= 40 && value <= 400)
                if inSession && plausible {
                    self.onEGV?(value, readingDate, glucoseTimestamp)   // → Loop glucose store (measurement-time stamped)
                } else {
                    LogFile.append(String(format: "loop-bridge: EGV %d NOT injected (state=0x%02x inSession=%@ plausible=%@)",
                                          value, Int(state ?? 0), inSession ? "y" : "n", plausible ? "y" : "n"))
                }
            }
        }

        // Whitelabeling: read back which slot/role the sensor assigned us.
        await queryDeviceList(ctrl: ctrl)
    }

    // Whitelabeling probe: ask the sensor which clients are connected and in what SLOT/role.
    // [0xEA, 0x00] on control(3534) -> DeviceListResponse. Byte[2] = maxDevices; the device
    // records carry displayType (phone/watch/receiver). Oracle for the receiver-role sweep:
    // set authEndByte, connect, and read back the role the sensor actually assigned us.
    private func queryDeviceList(ctrl: CBCharacteristic) async {
        do {
            try await writeResp(ctrl, [0xEA, 0x00])
            let resp = try await ctrlStream.recv(timeout: recvTimeout)
            let hx = hex(resp)
            let maxDev = resp.count >= 3 ? Int(resp[2]) : -1
            let sent = String(format: "0x%02x", authEndByte)
            log("*** DEVICE-LIST (0xEA)<- \(hx)  maxDevices=\(maxDev)  (we sent role \(sent)) ***")
            onMain {
                self.deviceListHex = hx
                self.deviceListSummary = "maxDev \(maxDev) · sent \(sent)"
            }
        } catch {
            log("  device-list (0xEA) query failed: \(error)")
        }
    }

    // 2) J-PAKE — for w in 0,1,2: write [0x0A,w] to auth, recv 160 on data, feed it,
    //    then send our 160 (round12 for w<2, round3 for w==2) to data.
    private func doJPake(auth: CBCharacteristic) async throws {
        for w in Int32(0)...Int32(2) {
            try await writeResp(auth, [0x0A, UInt8(w)])
            let sensor160 = try await dataStream.recv(160, timeout: recvTimeout)
            let valid = Crypto.putPubkey(w, sensor160)
            log("round\(w) putk=\(valid)")
            let ours: [UInt8]
            if w < 2 {
                ours = Crypto.round12(w)
            } else {
                guard let r3 = Crypto.round3() else { throw G7Error.cryptoFailed("g7_round3") }
                ours = r3
            }
            await writeDataChunks(ours)
        }
    }

    // 3) AES auth: write [0x02]+RAND8+[0x02]; recv [0x03]+X8+Y8; verify aes8(RAND8)==X8;
    //    write [0x04]+aes8(Y8); recv [0x05, auth, bond].
    private func doAesAuth(auth: CBCharacteristic) async throws -> (Int, Int) {
        try await writeResp(auth, [0x02] + G7Client.RAND8 + [self.authEndByte])
        let resp = try await authStream.recv(op: 0x03, timeout: recvTimeout)
        guard resp.count >= 17 else {
            log("  short challengeReply (\(resp.count) bytes, need 17): \(hex(resp))")
            throw G7Error.shortFrame("challengeReply \(resp.count)/17 bytes")
        }
        let x8 = Array(resp[1..<9])
        let y8 = Array(resp[9..<17])
        let expect = Crypto.aes8(G7Client.RAND8)
        let ok = expect == x8
        log("challengeReply verify=\(ok ? "OK" : "BAD")")
        guard ok else { throw G7Error.aesVerifyFailed }

        try await writeResp(auth, [0x04] + Crypto.aes8(y8))
        let st = try await authStream.recv(op: 0x05, timeout: recvTimeout)
        guard st.count >= 3 else {
            log("  short statusReply (\(st.count) bytes, need 3): \(hex(st))")
            throw G7Error.shortFrame("statusReply \(st.count)/3 bytes")
        }
        let a = Int(st[1]), bo = Int(st[2])
        log("*** statusReply auth=\(a) bond=\(bo) ***")
        onMain { self.lastAuthByte = a }
        return (a, bo)
    }

    // 4) Certificate exchange + proof-of-possession.
    private func doCerts(auth: CBCharacteristic) async throws {
        for idx in 0...1 {
            let cert = G7Client.CERTS[idx]
            // [0x0B, idx] + UInt32LE(len)
            var lenLE = [UInt8](repeating: 0, count: 4)
            let n = UInt32(cert.count)
            lenLE[0] = UInt8(n & 0xff)
            lenLE[1] = UInt8((n >> 8) & 0xff)
            lenLE[2] = UInt8((n >> 16) & 0xff)
            lenLE[3] = UInt8((n >> 24) & 0xff)
            try await writeResp(auth, [0x0B, UInt8(idx)] + lenLE)

            let cs = try await authStream.recv(op: 0x0B, timeout: recvTimeout)
            guard cs.count >= 5 else {
                log("  short cert-size reply (\(cs.count) bytes, need 5): \(hex(cs))")
                throw G7Error.shortFrame("cert-size reply \(cs.count)/5 bytes")
            }
            // Sensor announces its cert size at payload bytes [3],[4] (little-endian).
            let size = Int(cs[3]) | (Int(cs[4]) << 8)
            _ = try await dataStream.recv(size, timeout: recvTimeout) // sensor cert (unused)
            await writeDataChunks(cert)
            log("cert\(idx) exchanged (sensor cert \(size) bytes)")
        }

        // Proof of possession: write [0x0C]+RAND16, recv 64 on data (unused), recv [0x0C,...]
        // indication (pc). Sign the FULL pc payload (including its leading 0x0C opcode byte,
        // exactly as the Python passes `pc` straight into g7_challenge) and send the 64-byte sig.
        try await writeResp(auth, [0x0C] + G7Client.RAND16)
        _ = try await dataStream.recv(64, timeout: recvTimeout)
        let pc = try await authStream.recv(op: 0x0C, timeout: recvTimeout)
        let sig = Crypto.challenge(pc)
        await writeDataChunks(sig)
        log("PoP sig sent (challenge input \(pc.count) bytes)")

        // authStatus + KeepAlive (bond gate primer). One optional auth indication may follow.
        try await writeResp(auth, [0x0D, 0x00, 0x02])
        if let extra = try? await authStream.recv(timeout: 6.0) {
            log("  post-0D auth \(hex(extra))")
        }
    }
}

// MARK: - Embedded Dexcom partner certificates
//
// From Juggluco DexGattCallback.java certs[][] (see g7certs.py). Sent to the sensor
// during the cert-exchange step of the handshake.
enum Certs {
    /// 494 bytes
    static let CERT0: [UInt8] = [
        0x30, 0x82, 0x01, 0xea, 0x30, 0x82, 0x01, 0x8f, 0xa0, 0x03, 0x02, 0x01,
        0x02, 0x02, 0x14, 0x2f, 0x3c, 0x52, 0xb6, 0xeb, 0x08, 0x70, 0x10, 0x46,
        0xd4, 0x5d, 0x78, 0xce, 0x81, 0x78, 0x4c, 0x9d, 0xfe, 0x52, 0x40, 0x30,
        0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02, 0x30,
        0x13, 0x31, 0x11, 0x30, 0x0f, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x08,
        0x44, 0x45, 0x58, 0x30, 0x30, 0x50, 0x47, 0x31, 0x30, 0x1e, 0x17, 0x0d,
        0x32, 0x30, 0x31, 0x30, 0x33, 0x30, 0x31, 0x35, 0x35, 0x39, 0x30, 0x34,
        0x5a, 0x17, 0x0d, 0x33, 0x35, 0x31, 0x30, 0x32, 0x37, 0x31, 0x35, 0x35,
        0x39, 0x30, 0x34, 0x5a, 0x30, 0x13, 0x31, 0x11, 0x30, 0x0f, 0x06, 0x03,
        0x55, 0x04, 0x03, 0x0c, 0x08, 0x44, 0x45, 0x58, 0x30, 0x33, 0x50, 0x47,
        0x31, 0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d,
        0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
        0x03, 0x42, 0x00, 0x04, 0xfb, 0x1a, 0xca, 0x21, 0xd8, 0xae, 0xec, 0x9a,
        0x4e, 0xb5, 0x1f, 0x85, 0x30, 0x49, 0x53, 0xd9, 0x77, 0xa1, 0xad, 0x56,
        0x97, 0x99, 0x25, 0x0f, 0xf8, 0x63, 0x98, 0x7f, 0x42, 0xa3, 0xcd, 0x9f,
        0xa4, 0xff, 0x57, 0x1e, 0xb5, 0x68, 0xbc, 0x6c, 0x39, 0x62, 0x77, 0xc3,
        0xdc, 0xb5, 0x1d, 0xed, 0xae, 0xe8, 0x55, 0x13, 0xc8, 0x0a, 0x5c, 0x44,
        0x35, 0x53, 0x8a, 0x19, 0xf5, 0xa9, 0x63, 0x48, 0xa3, 0x81, 0xc0, 0x30,
        0x81, 0xbd, 0x30, 0x0f, 0x06, 0x03, 0x55, 0x1d, 0x13, 0x01, 0x01, 0xff,
        0x04, 0x05, 0x30, 0x03, 0x01, 0x01, 0xff, 0x30, 0x1f, 0x06, 0x03, 0x55,
        0x1d, 0x23, 0x04, 0x18, 0x30, 0x16, 0x80, 0x14, 0x9e, 0x0f, 0x1e, 0x36,
        0xf3, 0xf2, 0x76, 0xa7, 0x01, 0xfe, 0x8e, 0x88, 0x3a, 0x6e, 0x26, 0xa6,
        0x35, 0xbd, 0x6a, 0xfc, 0x30, 0x5a, 0x06, 0x03, 0x55, 0x1d, 0x1f, 0x04,
        0x53, 0x30, 0x51, 0x30, 0x4f, 0xa0, 0x34, 0xa0, 0x32, 0x86, 0x30, 0x68,
        0x74, 0x74, 0x70, 0x3a, 0x2f, 0x2f, 0x63, 0x72, 0x6c, 0x2e, 0x64, 0x70,
        0x2e, 0x73, 0x61, 0x61, 0x73, 0x2e, 0x70, 0x72, 0x69, 0x6d, 0x65, 0x6b,
        0x65, 0x79, 0x2e, 0x63, 0x6f, 0x6d, 0x2f, 0x63, 0x72, 0x6c, 0x2f, 0x44,
        0x45, 0x58, 0x30, 0x30, 0x50, 0x47, 0x31, 0x2e, 0x63, 0x72, 0x6c, 0xa2,
        0x17, 0xa4, 0x15, 0x30, 0x13, 0x31, 0x11, 0x30, 0x0f, 0x06, 0x03, 0x55,
        0x04, 0x03, 0x0c, 0x08, 0x44, 0x45, 0x58, 0x30, 0x30, 0x50, 0x47, 0x31,
        0x30, 0x1d, 0x06, 0x03, 0x55, 0x1d, 0x0e, 0x04, 0x16, 0x04, 0x14, 0x88,
        0xf6, 0x1e, 0x81, 0xbc, 0x4b, 0x17, 0xf0, 0x5c, 0x6b, 0x1b, 0xe2, 0x99,
        0x1d, 0x60, 0x08, 0x7c, 0xce, 0xdd, 0x79, 0x30, 0x0e, 0x06, 0x03, 0x55,
        0x1d, 0x0f, 0x01, 0x01, 0xff, 0x04, 0x04, 0x03, 0x02, 0x01, 0x86, 0x30,
        0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02, 0x03,
        0x49, 0x00, 0x30, 0x46, 0x02, 0x21, 0x00, 0xaa, 0x69, 0xcd, 0x89, 0x7e,
        0xc6, 0x63, 0xaf, 0x5f, 0x9e, 0x15, 0x81, 0x87, 0xdf, 0x68, 0x51, 0xff,
        0x07, 0x56, 0xf0, 0x0c, 0x40, 0x16, 0x24, 0x56, 0x4f, 0x81, 0xa1, 0x9f,
        0x5a, 0x07, 0x85, 0x02, 0x21, 0x00, 0xda, 0xeb, 0xb9, 0xfd, 0xb1, 0x63,
        0xb7, 0x31, 0xeb, 0x06, 0x61, 0xf1, 0xc0, 0xa1, 0x93, 0x28, 0x71, 0xa5,
        0x0e, 0x39, 0x9a, 0xd1, 0xc6, 0xf5, 0x19, 0xea, 0xbd, 0x4c, 0x9e, 0x7b,
        0xa0, 0x13,
    ]
    /// 465 bytes
    static let CERT1: [UInt8] = [
        0x30, 0x82, 0x01, 0xcd, 0x30, 0x82, 0x01, 0x74, 0xa0, 0x03, 0x02, 0x01,
        0x02, 0x02, 0x14, 0x19, 0x05, 0x2f, 0xcc, 0x17, 0x53, 0x0b, 0xfa, 0x56,
        0xe4, 0x9d, 0xca, 0xfc, 0xda, 0xcf, 0x85, 0x3c, 0xe5, 0xba, 0x73, 0x30,
        0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02, 0x30,
        0x13, 0x31, 0x11, 0x30, 0x0f, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x08,
        0x44, 0x45, 0x58, 0x30, 0x33, 0x50, 0x47, 0x31, 0x30, 0x1e, 0x17, 0x0d,
        0x32, 0x33, 0x30, 0x34, 0x31, 0x34, 0x31, 0x30, 0x32, 0x38, 0x31, 0x34,
        0x5a, 0x17, 0x0d, 0x32, 0x35, 0x30, 0x34, 0x31, 0x33, 0x31, 0x30, 0x32,
        0x38, 0x31, 0x33, 0x5a, 0x30, 0x3a, 0x31, 0x38, 0x30, 0x36, 0x06, 0x03,
        0x55, 0x04, 0x03, 0x0c, 0x2f, 0x30, 0x31, 0x2c, 0x30, 0x30, 0x30, 0x30,
        0x2c, 0x30, 0x33, 0x30, 0x30, 0x4c, 0x51, 0x45, 0x43, 0x43, 0x7a, 0x41,
        0x42, 0x41, 0x77, 0x41, 0x41, 0x2c, 0x63, 0x69, 0x6f, 0x69, 0x65, 0x33,
        0x56, 0x62, 0x51, 0x32, 0x68, 0x6c, 0x5a, 0x4d, 0x6a, 0x64, 0x55, 0x6d,
        0x35, 0x72, 0x67, 0x41, 0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
        0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d,
        0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04, 0x51, 0x18, 0xc3, 0x5e, 0x9e,
        0x41, 0xe7, 0xe0, 0x65, 0x4f, 0xee, 0x80, 0x1c, 0x52, 0xa9, 0xc5, 0xdf,
        0xc5, 0x10, 0xef, 0x09, 0x59, 0x7d, 0x5c, 0xca, 0x84, 0x61, 0xe4, 0xaf,
        0x9c, 0x66, 0x67, 0x14, 0x83, 0x4f, 0x2b, 0xc9, 0x03, 0xf1, 0x6f, 0xab,
        0xfc, 0x45, 0x75, 0x5b, 0x01, 0x83, 0xf1, 0xa0, 0x97, 0x45, 0xcd, 0xff,
        0xcb, 0x4e, 0x2f, 0x79, 0x9e, 0x50, 0xbe, 0xd9, 0xa6, 0xb5, 0x8c, 0xa3,
        0x7f, 0x30, 0x7d, 0x30, 0x0c, 0x06, 0x03, 0x55, 0x1d, 0x13, 0x01, 0x01,
        0xff, 0x04, 0x02, 0x30, 0x00, 0x30, 0x1f, 0x06, 0x03, 0x55, 0x1d, 0x23,
        0x04, 0x18, 0x30, 0x16, 0x80, 0x14, 0x88, 0xf6, 0x1e, 0x81, 0xbc, 0x4b,
        0x17, 0xf0, 0x5c, 0x6b, 0x1b, 0xe2, 0x99, 0x1d, 0x60, 0x08, 0x7c, 0xce,
        0xdd, 0x79, 0x30, 0x1d, 0x06, 0x03, 0x55, 0x1d, 0x25, 0x04, 0x16, 0x30,
        0x14, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02, 0x06,
        0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01, 0x30, 0x1d, 0x06,
        0x03, 0x55, 0x1d, 0x0e, 0x04, 0x16, 0x04, 0x14, 0xd3, 0x09, 0xe7, 0x5c,
        0x07, 0x25, 0x41, 0x2d, 0x7a, 0x79, 0x22, 0xe3, 0xaa, 0xcf, 0xb2, 0x7f,
        0x7e, 0xbd, 0x6b, 0xe0, 0x30, 0x0e, 0x06, 0x03, 0x55, 0x1d, 0x0f, 0x01,
        0x01, 0xff, 0x04, 0x04, 0x03, 0x02, 0x05, 0xa0, 0x30, 0x0a, 0x06, 0x08,
        0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02, 0x03, 0x47, 0x00, 0x30,
        0x44, 0x02, 0x20, 0x48, 0xd4, 0x86, 0x8c, 0xf3, 0x93, 0xd9, 0x04, 0x41,
        0x01, 0xb6, 0xf0, 0x7f, 0xd6, 0x8d, 0x7f, 0x06, 0x42, 0x80, 0x5f, 0x85,
        0xda, 0x74, 0xe2, 0xfe, 0x9d, 0xe8, 0xdd, 0x35, 0x07, 0xf0, 0x27, 0x02,
        0x20, 0x1c, 0xd1, 0xbf, 0x7c, 0x6c, 0x7e, 0xdd, 0x59, 0x43, 0x5e, 0x32,
        0x49, 0x25, 0xfc, 0xf0, 0xeb, 0xb3, 0xca, 0xe2, 0x11, 0x0d, 0x79, 0x40,
        0x7c, 0x77, 0xaa, 0x3b, 0x93, 0xb7, 0xbc, 0x04, 0xcb,
    ]
}
