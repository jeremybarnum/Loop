//
//  PodRadioHold.swift
//  WatchApp
//
//  The pod-side half of the G7 mute fix, ported by content from her line (build 179, mute
//  record §6b/§7) onto this line's connect-on-demand pod paradigm.
//
//  THE MECHANISM (six watch sysdiagnoses, 2026-09-05→07). bluetoothd keeps one accept-list
//  entry per sensor shared by every app, and a per-device tally of links that formed and died
//  before encryption (HCI 0x3E), over a 5.8-h window. At count 5 its judgment flips; from then
//  on a failed establishment that comes AFTER the daemon's 6-s fast scan makes its retry park
//  a −70 dBm floor on the entry — below wrist-to-arm RSSI — and every app on the bond is mute
//  until a strong burst, a touch, or a watch-Bluetooth toggle. Late failures need the sensor
//  to still be advertising after +6 s, which it only does in its EXTENDED PHASE: for ~10 min
//  after the phone stops collecting, each read is followed by a 27–32-s advertising tail (7 s
//  with the phone present; 3-s minute calls once phone-absent mode settles). On record, every
//  late failure had our scan or our pod link on the chip in that tail; the pod on the air at
//  minute calls counted nothing (17 collisions), and phone-present tails never failed late.
//
//  So: ONE hold. While the sensor is in its extended phase — no relay from the phone in THIS
//  window, but a relay within the last 12.5 min — nothing of ours goes on the pod radio from
//  the burst until close+25 s (capped at read+40 s), nor in the 20 s before the next burst.
//  Everywhere else the pod is unrestricted. Jeremy, 2026-09-07: "my goal is to simply not
//  make it any worse than Dexcom … detect phone absence going into 10 minute mode. During
//  that mode, avoid bolus collisions. Outside of that mode, pod is unrestricted."
//
//  The hold applies at the CYCLE level (her 173 tangle: a hold inside the reclaim closure let
//  the enactor's wait time out and skipped doses), and the relay clock starts at loan start
//  (a loan that begins as the phone leaves must hold its first tails too).
//

import Foundation
import WatchConnectivity
import G7SensorKit

enum PodRadioHold {
    /// Bench kill switch (absent = hold on). Nothing on the wrist sets it.
    static let disabledKey = "G7Lab.podRadioHoldOff"
    static var disabled: Bool { UserDefaults.standard.bool(forKey: disabledKey) }

    // MARK: Pure policy (pinned by WatchAppTests)

    static let period: TimeInterval = 300
    /// Read-relative cap: the sensor closes our session +9…+16 s after the read, every late
    /// failure sat 11–16 s after that close, the long tail ends ~+29 s after the burst.
    static let tailHold: TimeInterval = 40
    /// Close-relative hold: past the failure zone (close+11…+16) and the tail end (~close+19)
    /// with margin; capped by `tailHold` so a late close cannot push the pod past what run 3
    /// proved.
    static let afterCloseHold: TimeInterval = 25
    /// The 20 s before the next expected burst.
    static let lead: TimeInterval = 20
    /// The extended phase is the first two windows without the phone's relay after windows
    /// that had it; 12.5 min is two windows, three when the departure cut a window short.
    static let extendedPhaseSpan: TimeInterval = 12.5 * 60

    /// No relay in THIS window, and a relay within `extendedPhaseSpan`. No relay ever (a loan
    /// that began with the phone away and no grant-start stamp, or a relaunch) means steady
    /// phone-absent mode — minute calls, no tails, nothing to hold for.
    static func isExtendedPhase(lastRelay: Date?, now: Date, relayThisWindow: Bool) -> Bool {
        guard !relayThisWindow, let r = lastRelay else { return false }
        let since = now.timeIntervalSince(r)
        return since >= 0 && since <= extendedPhaseSpan
    }

    /// Seconds since the most recent grid burst, from the last direct read, carried through
    /// misses on the sensor's 300-s grid.
    static func phase(anchor: Date, now: Date) -> TimeInterval {
        let raw = now.timeIntervalSince(anchor).truncatingRemainder(dividingBy: period)
        return raw < 0 ? raw + period : raw
    }

    /// Where the tail hold ends, from the burst: close+25 s capped at +40, the read-relative
    /// fallback until the close is seen.
    static func firstPhaseEnd(closeOffset: TimeInterval?) -> TimeInterval {
        if let c = closeOffset { return min(tailHold, c + afterCloseHold) }
        return tailHold
    }

    /// Seconds until the pod may use the radio; nil when it may now. Only ever non-nil in the
    /// extended phase.
    static func holdRemaining(phase p: TimeInterval, extended: Bool, closeOffset: TimeInterval?) -> TimeInterval? {
        guard extended else { return nil }
        let end = firstPhaseEnd(closeOffset: closeOffset)
        if p < end { return end - p }
        if p >= period - lead { return period - p }
        return nil
    }

    // MARK: State (any queue)

    private static let lock = NSLock()
    private static var anchor: Date?        // last direct read = the burst
    private static var closeAt: Date?       // the adopted sensor's link closed (this window)
    private static var relayAt: Date?       // the phone's reading reached the watch

    /// A direct read landed — the sensor's grid phase re-anchors; the previous window's close
    /// no longer applies.
    static func noteDirectRead(_ date: Date = Date()) { lock.lock(); anchor = date; closeAt = nil; lock.unlock() }
    /// The adopted sensor's link just closed — the close-relative hold starts here.
    static func noteSensorClose(_ date: Date = Date()) { lock.lock(); closeAt = date; lock.unlock() }
    /// How recent the phone's relayed READING must be to count as "the phone is collecting".
    /// The phone reads on the sensor's 5-minute grid and relays within seconds, so one window
    /// plus slack clears every phone-present case; a reading older than this was taken before
    /// the phone stopped collecting and says nothing about now.
    static let relayFreshness: TimeInterval = 6 * 60

    /// Pure, pinned by WatchAppTests: does this relayed reading count as evidence the phone is
    /// collecting right now?
    static func relayCounts(readingDate: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(readingDate)
        return age >= 0 && age <= relayFreshness
    }

    /// The phone's own reading reached the watch as a relay. Only a RECENT reading counts.
    ///
    /// Field 2026-09-07 23:02: the phone's radio had been off for ten minutes, but it relayed
    /// its last (22:51) reading once; stamping on arrival alone read that as "the phone is
    /// collecting" and suppressed the hold for a window that was in the sensor's extended
    /// phase. A stale relay also RESTARTED the 12.5-minute clock, dating the extended phase
    /// from the wrong moment. The stamp stays on ARRIVAL rather than on storage (the fill-a-gap
    /// skip drops the relay whenever our own direct read won the race, which is the common
    /// phone-present case) — freshness is the only thing added.
    ///
    /// Her line deliberately did NOT gate this ("the grant context's sample counts even when
    /// stale — that is load-bearing: it starts the clock at the loan grant"). That reason does
    /// not apply here: this line stamps the loan start explicitly, below.
    /// Returns whether the relay counted, so the caller can log the ignore.
    @discardableResult
    static func noteRelay(readingDate: Date, at now: Date = Date()) -> Bool {
        guard relayCounts(readingDate: readingDate, now: now) else { return false }
        lock.lock(); relayAt = now; lock.unlock()
        return true
    }

    /// A loan went ACTIVE: the phone was collecting up to the grant (or, for a seize, may have
    /// just stopped), so the first ~12 minutes of tails are held whether or not a relay ever
    /// lands. Never freshness-gated — this IS the freshness. Separate entry point on purpose:
    /// it is the signal her line got from the stale grant sample, and keeping it distinct is
    /// what makes the gate above safe.
    static func noteLoanStarted(_ date: Date = Date()) { lock.lock(); relayAt = date; lock.unlock() }

    struct Facts { let anchor: Date?; let closeOffset: TimeInterval?; let relayThisWindow: Bool; let lastRelay: Date? }

    /// What this window has shown: the close offset from the anchor (nil until the close), and
    /// whether the phone's relay landed within 90 s before the anchor or 60 s after.
    static func facts() -> Facts {
        lock.lock(); defer { lock.unlock() }
        guard let a = anchor else { return Facts(anchor: nil, closeOffset: nil, relayThisWindow: false, lastRelay: relayAt) }
        let close = closeAt.flatMap { c -> TimeInterval? in let d = c.timeIntervalSince(a); return (d >= 0 && d < 90) ? d : nil }
        let relay = relayAt.map { r -> Bool in let d = r.timeIntervalSince(a); return d > -90 && d < 60 } ?? false
        return Facts(anchor: a, closeOffset: close, relayThisWindow: relay, lastRelay: relayAt)
    }

    static func extendedPhaseNow(now: Date = Date()) -> Bool {
        let f = facts()
        return isExtendedPhase(lastRelay: f.lastRelay, now: now, relayThisWindow: f.relayThisWindow)
    }

    /// What the POD RADIO asks (the dose cycle, the manual bolus, the takeover ladder):
    /// seconds to wait, or nil to go now. Callable from any queue.
    static func remainingNow(now: Date = Date()) -> TimeInterval? {
        guard !disabled else { return nil }
        let f = facts()
        guard let anchor = f.anchor else { return nil }
        let extended = isExtendedPhase(lastRelay: f.lastRelay, now: now, relayThisWindow: f.relayThisWindow)
        return holdRemaining(phase: phase(anchor: anchor, now: now), extended: extended, closeOffset: f.closeOffset).map { max(0.5, $0) }
    }

    /// One word for the log lines.
    static var modeText: String { disabled ? "off" : (extendedPhaseNow() ? "extended-phase" : "none") }

    // MARK: The glance's wedge hint (pure)

    /// Two or more consecutive expected bursts with no direct read, with the phone not relaying
    /// — the indicia of a parked watch stack. Dexcom's own app is muted the same way, and the
    /// only cure short of waiting 20–45 min is the WATCH's Bluetooth off and on (ruled wording:
    /// it must name the watch — the phone's Bluetooth does nothing for this). Not an alert.
    /// Derived from state rather than counted per window: 10.5 min of direct silence is two
    /// missed bursts by construction on the 300-s grid.
    static func wedgeHint(directAge: TimeInterval?, relayAge: TimeInterval?) -> String? {
        guard let age = directAge, age >= 10.5 * 60 else { return nil }
        if let r = relayAge, r < 10 * 60 { return nil }
        return String(format: NSLocalizedString("G7 silent %d min · try toggling watch Bluetooth", comment: "Glance line when the watch has missed two or more sensor bursts with the phone away"), Int(age / 60))
    }
}

/// TAIL EXPOSURE — the pod-isolation instrument (her build 174, mute record §5).
///
/// The daemon never tells an app about the failed establishment that writes the −70 floor, so
/// it cannot be logged here. What can be logged is our half of it: for 40 s after every close
/// of the adopted sensor's link, whether our pod link or our own scan was on the radio and
/// when. One `[tail]` line per window; join it to a sysdiagnose's 762 times by window to
/// attribute late failures. The preregistered acceptance reads CLEAN on every extended-phase
/// window.
enum TailExposure {
    struct Event: Equatable { let kind: String; let offset: TimeInterval }   // "pod↑" "pod↓" "scan"

    static let window: TimeInterval = 40
    /// After the fast scan (+6 s from Dexcom's re-subscribe, ~+0 from the close) to the end of
    /// the sensor's long tail as measured on the air.
    static let lateZone: ClosedRange<TimeInterval> = 6...29

    private static let lock = NSLock()
    private static var closedAt: Date?
    private static var closedName = ""
    private static var events: [Event] = []
    private static var podUp = false            // last known pod link state, kept across windows
    private static var podUpAtClose = false

    static func noteSensorClosed(_ name: String, now: Date = Date()) {
        PodRadioHold.noteSensorClose(now)
        lock.lock()
        closedAt = now; closedName = name; events = []; podUpAtClose = podUp
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + window + 0.5) { report(for: now) }
    }

    static func notePodLink(up: Bool, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        podUp = up
        guard let t0 = closedAt else { return }
        let dt = now.timeIntervalSince(t0)
        if dt >= 0 && dt <= window { events.append(Event(kind: up ? "pod↑" : "pod↓", offset: dt)) }
    }

    static func noteScanStarted(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let t0 = closedAt else { return }
        let dt = now.timeIntervalSince(t0)
        if dt >= 0 && dt <= window { events.append(Event(kind: "scan", offset: dt)) }
    }

    private static func report(for start: Date) {
        lock.lock()
        guard closedAt == start else { lock.unlock(); return }   // a newer close superseded this window
        let name = closedName, evs = events, upAtClose = podUpAtClose
        lock.unlock()
        SportLog.event("tail", "after \(name) close: \(summary(events: evs, podUpAtClose: upAtClose)) · phone \(WCSession.default.isReachable ? "reachable" : "away") · relay \(PodRadioHold.facts().relayThisWindow ? "this window" : "none") · hold \(PodRadioHold.modeText)")
    }

    /// Pure, pinned by WatchAppTests: the one-line verdict for a window.
    static func summary(events: [Event], podUpAtClose: Bool, window: TimeInterval = window, lateZone: ClosedRange<TimeInterval> = lateZone) -> String {
        var parts: [String] = []
        var touched = false
        var openAt: TimeInterval? = podUpAtClose ? 0 : nil
        for e in events.sorted(by: { $0.offset < $1.offset }) {
            switch e.kind {
            case "pod↑": if openAt == nil { openAt = e.offset }
            case "pod↓":
                if let a = openAt {
                    parts.append(String(format: "pod link +%.1f→+%.1f s", a, e.offset))
                    if a <= lateZone.upperBound && e.offset >= lateZone.lowerBound { touched = true }
                    openAt = nil
                }
            case "scan":
                parts.append(String(format: "scan +%.1f s", e.offset))
                if e.offset <= lateZone.upperBound { touched = true }
            default: break
            }
        }
        if let a = openAt {
            parts.append(String(format: "pod link +%.1f→(still up at +%.0f s)", a, window))
            if a <= lateZone.upperBound { touched = true }
        }
        if parts.isEmpty { return "CLEAN (nothing of ours on the radio for \(Int(window)) s)" }
        return parts.joined(separator: " · ") + " · late zone +\(Int(lateZone.lowerBound))→+\(Int(lateZone.upperBound)) s: \(touched ? "TOUCHED" : "clear")"
    }
}
