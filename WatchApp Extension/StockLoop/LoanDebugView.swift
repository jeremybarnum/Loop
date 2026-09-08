//
//  LoanDebugView.swift
//  WatchApp
//
//  The Sport Mode diagnostics page. Ported from the WatchKit build with its hosting controller
//  removed — the view was already SwiftUI, and it is a TabView page now like the glance.
//

import Foundation
import SwiftUI
import WatchKit
import WatchConnectivity
import HealthKit   // DOSING readout: HKQuantity glucose/eventual
import LoopKit     // The .milligramsPerDeciliter HKUnit convenience
import G7SensorKit // CGM HEALTH panel reads the stock manager directly

struct CGMHealth {
    let sensorName: String?
    let lastReadingAge: TimeInterval?
    /// The value and its reading time (Jeremy, 2026-09-06), so a missed window can be told
    /// from Dexcom's app holding the previous value across one grid point — the two look
    /// identical on the glance.
    let bgLine: String
    let linkState: String
    let lifecycle: String
    let expiresIn: String

    init(_ manager: G7CGMManager) {
        sensorName = manager.sensorName
        lastReadingAge = manager.latestReadingTimestamp.map { Date().timeIntervalSince($0) }
        if let g = manager.latestReading?.glucose, let t = manager.latestReadingTimestamp {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            bgLine = String(format: "%d mg/dL · %@ (%.0fs ago)", Int(g), f.string(from: t), Date().timeIntervalSince(t))
        } else {
            bgLine = "—"
        }
        // Scanning AND connected are both normal states in the connect-per-reading rhythm: the
        // sensor hangs up after each reading, so "scanning" between windows is health, not failure.
        linkState = manager.isConnected ? "connected" : (manager.isScanning ? "scanning" : "idle")
        lifecycle = String(describing: manager.lifecycleState)
        if let expiry = manager.sensorExpiresAt {
            let hours = expiry.timeIntervalSinceNow / 3600
            expiresIn = hours > 0 ? String(format: "%.1f h", hours) : "expired"
        } else {
            expiresIn = "—"
        }
    }
}

struct LoanDebugView: View {
    @State private var snapshot: PodLoanWatchController.DebugSnapshot?
    @State private var cgm: CGMHealth?
    @State private var lastAction: String = "—"
    /// The loop's own IOB (Jeremy 2026-07-19: the dosing math is what matters —
    /// surface it here until the UI pass wires the main screens).
    @State private var iobText: String = "—"
    /// Live dosing readout — "is it trying to dose?" made visible on-wrist.
    /// Refreshes on the same 2s timer as everything else.
    @State private var dosing: WatchLoopManager.GlanceData?
    @State private var cobText: String = "—"

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// nil until the stack finishes starting at launch; the readouts render "—" in that window
    /// rather than blocking on it.
    private var session: StockLoopSession? {
        ExtensionDelegate.sharedIfAvailable()?.stockLoopSession
    }

    var body: some View {
        NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                // The dosing decision, on-wrist. `recommend` vs `running` is the
                // tell — high recommend + baseline running + closed = it wants to dose
                // but isn't enacting; matching = it dosed; loop OPEN = not dosing at all.
                // Build tag, moved off the glance. "Which build is this?"
                // is a diagnostic question, and this is the page you are already on when you ask.
                Text("build \(BuildDetails.default.codeIdentity)")
                    .font(.footnote).foregroundColor(.secondary)
                Text("DOSING").font(.footnote).foregroundColor(.secondary)
                row("closed?", (dosing?.closedLoopEnabled ?? false) ? "YES" : "no")
                row("BG now", dosing?.glucose.map { String(format: "%.0f", $0.doubleValue(for: .milligramsPerDeciliter)) } ?? "—")
                row("eventual", dosing?.eventual.map { String(format: "%.0f", $0.doubleValue(for: .milligramsPerDeciliter)) } ?? "—")
                predictionReconciliation
                row("COB / IOB", "\(cobText) / \(dosing?.iob.map { String(format: "%.2f U", $0) } ?? "—")")
                row("recommend", dosing?.recommendedTempRate.map { String(format: "%+.2f U/hr", $0) } ?? "—")
                row("running", dosing?.tempRate.map { String(format: "%+.2f U/hr net", $0) } ?? "none (scheduled)")
                row("last loop", dosing?.lastLoopCompleted.map { String(format: "%.0fs ago", Date().timeIntervalSince($0)) } ?? "—")
                if let err = dosing?.lastLoopErrorText { row("loop err", err) }

                Divider().padding(.vertical, 2)

                Text("LOAN").font(.footnote).foregroundColor(.secondary)

                row("phase", snapshot.map { String(describing: $0.phase) } ?? "—")
                row("epoch", snapshot?.epoch.map(String.init) ?? "—")
                row("mode", snapshot.map { $0.mode.rawValue } ?? "—")
                row("pump", (snapshot?.hasPumpManager ?? false) ? "constructed" : "nil")
                row("odometer", snapshot?.deliveredUnits.map { String(format: "%.2f U", $0) } ?? "—")
                row("loop IOB", iobText)
                row("fault", snapshot?.podFault ?? "none")
                row("last seq", snapshot.map { String($0.lastEventSeq) } ?? "—")
                row("unacked", snapshot.map { String($0.unackedCount) } ?? "—")
                row("uncertain", (snapshot?.pendingUncertain ?? false) ? "CHASING" : "no")
                row("last act", lastAction)

                Divider().padding(.vertical, 2)

                // Request Loan / Hand Back removed 2026-07-24 — both are redundant with
                // the glance's "Start Sport Mode" and hand-back flow (requestLoan /
                // beginHandback still live on those paths).
                //
                // Reset (debug) removed 2026-08-11 (Jeremy: "I've never used it and it seems
                // dangerous. I'm moving closer to production and want to simplify things").
                // It was labelled as a local un-wedge but ABANDONED a live loan: it tore down
                // the pod link and cleared the epoch without handing back, leaving the pod
                // orphaned on its last command, the phone still believing the watch held it
                // (`.loaned` has no timeout — the 5-minute T1 only exists in `.grantOffered`),
                // and any staged-but-unacked doses stranded under an epoch that no longer
                // existed. A one-tap way to strand insulin records is not a debug convenience.
                //
                // Read Status stays: read-only, no command, no state change — a live pod
                // reachability ping, which is the one question this screen cannot infer.
                Button("Read Pod Status") {
                    lastAction = "reading…"
                    session?.loanController.debugReadStatus { ok in
                        DispatchQueue.main.async {
                            switch ok {
                            case .some(true): lastAction = "pod status OK"
                            case .some(false): lastAction = "pod UNREACHABLE"
                            case .none: lastAction = "no pod (not in a loan)"
                            }
                        }
                    }
                }

                Divider().padding(.vertical, 2)

                // CGM HEALTH — read straight off the stock manager, which is now the only
                // producer. These are the fields that actually diagnose a CGM outage in the field:
                // is a sensor known, when did it last deliver, and is the link up right now.
                //
                // (Replaces the old G7 IDENTITY panel — bonded peripheral / pairing code /
                // pre-warm state — all of which described the retired J-PAKE reader. There is no
                // pairing code to show: the sensor authenticates the DEVICE, and the Dexcom watch
                // app is what vouches for it.)
                Text("CGM HEALTH").font(.footnote).foregroundColor(.secondary)
                row("sensor", cgm?.sensorName ?? "none")
                row("last reading", cgm?.lastReadingAge.map { String(format: "%.0fs ago", $0) } ?? "never")
                row("bg", cgm?.bgLine ?? "—")
                row("link", cgm?.linkState ?? "—")
                row("state", cgm?.lifecycle ?? "—")
                row("expires", cgm?.expiresIn ?? "—")
                // "needs D2W: YES" removed. It was a hardcoded constant from when a non-D2W
                // path still existed to contrast with; D2W is now the only glucose path, so the
                // row could only ever read YES. A diagnostic that cannot vary is not a diagnostic
                // — it is a distraction on a screen read while something is wrong. The requirement
                // now lives where it is actionable: the Series 6+ eligibility note for testers.

                // Pod-link release toggle REMOVED. The link policy is automatic:
                // orphan between doses, per-cycle reclaim gated on G7 acquisition state while
                // un-adopted (StockLoopSession wiring + WatchLoopManager gate). The
                // toggle experiment that settled it: held link = 0 adoptions in ~130 min;
                // released = adoption within 7-10 min, twice for two.

                // *** RE-ACQUIRE (BENCH) *** Forget the adopted sensor and
                // run a full COLD acquisition against the CURRENT sensor — scan, connect,
                // service discovery, auth subscribe, adoption. This is the contested phase of
                // the held-pod-link finding, and without this button it is testable only once
                // per 10-day sensor. With it + the g7-ble radio census, held-vs-released link
                // experiments are on demand. Ladybug-class: REMOVE PRE-PRODUCTION.
                // Safe: worst case is a re-adoption delay while the relay covers, same as any
                // new-sensor day; no therapy state is touched.
                Text("CGM ACTIONS").font(.footnote).foregroundColor(.secondary)

                // Ordered CHEAPEST FIRST, because the screen is read while something is wrong
                // and the top button should be the one to try first.
                //
                // RECONNECT keeps the sensor's identity — it drops our link and re-acquires the
                // SAME sensor. This is the first move for a client that has stopped delivering.
                // It deliberately forces one acquisition pass THROUGH ride-only (Jeremy,
                // 2026-09-08: "we can violate ride only when it's a button that I push"): the
                // policy exists to keep our radio out of the sensor's tail automatically, and a
                // tap is not the automatic case. Without the bypass this button would only
                // re-register for connection events and then wait up to a full 5-minute window
                // for Dexcom's next link, which is not what someone pressing a button wants.
                // The override is consumed by that one pass; the next re-arm is ride-only again.
                //
                // It does NOT clear a parked -70 floor. Nothing in our process can: that lives
                // in bluetoothd's accept list and only a Bluetooth toggle, a strong burst or a
                // reboot clears it. If reconnect changes nothing and the sensor is silent, the
                // watch's own Bluetooth is the next thing to try, not this.
                Button("Reconnect CGM") {
                    SportLog.event("g7-ble", "*** USER RECONNECT *** dropping the G7 link and re-acquiring the same sensor")
                    ExtensionDelegate.sharedIfAvailable()?.stockLoopSession?.stack.cgmManager.recycleG7ConnectForLab()
                    lastAction = "CGM reconnect started"
                }

                // RE-ACQUIRE forgets the adopted sensor and rebuilds cold — scan, connect,
                // discovery, auth subscribe, adoption. Strictly more disruptive than Reconnect,
                // so it sits below it. Safe: the worst case is a re-adoption delay while the
                // phone relay covers, exactly like any new-sensor day. No therapy state is
                // touched. Ladybug-class: REMOVE PRE-PRODUCTION.
                Button("Re-acquire Sensor (cold)") {
                    SportLog.event("g7-ble", "*** BENCH RE-ACQUIRE *** forgetting adopted sensor — cold acquisition starts now")
                    ExtensionDelegate.sharedIfAvailable()?.stockLoopSession?.stack.cgmManager.scanForNewSensor()
                    lastAction = "G7 re-acquire started"
                }

                // E1 kept by request, but not under that name: "E1" means nothing to a reader
                // who has not read the investigation. What it DOES is run our G7 client with no
                // pod loan, no pod central and no dosing — the only way to ask "is this the CGM
                // or is this Loop?" and get an unambiguous answer. Refuses to start over a live
                // loan.
                if let session = session {
                    Button(session.standaloneG7TestActive
                           ? "Stop CGM-only test"
                           : "CGM-only test (no pod, no dosing)") {
                        if session.standaloneG7TestActive {
                            session.stopStandaloneG7Test()
                            lastAction = "CGM-only test stopped"
                        } else {
                            session.startStandaloneG7Test()
                            lastAction = session.standaloneG7TestActive
                                ? "CGM-only test running (E1)"
                                : "blocked — end the loan first"
                        }
                    }
                }

                // The pod hold's current mode, so a deferred cycle on this screen is legible
                // rather than looking like a stall.
                Text("pod hold: \(PodRadioHold.modeText)")
                    .font(.caption2).foregroundColor(.secondary)

                // RADIO STRESS RETIRED: the question it existed to
                // answer — does a pod command every single cycle disturb the CGM? — came back
                // negative, repeatedly. Contention lives in CONNECT ESTABLISHMENT, not in
                // dosing traffic against an established link, and that is handled by the
                // acquisition gate rather than by anything on this screen.

                Divider().padding(.vertical, 2)

                // Retired bench experiments (standalone-G7, clean-teardown, release-pod,
                // Fake BG sweep, random-temp) lived here through the
                // diagnostics declutter. Releasing the pod link between doses is now the
                // production default (StockLoopSession.init); the rest are one git revert
                // away if a bench drill needs them again. Their plumbing (session methods,
                // FakeGlucose, the flag reads) is intact — only the on-wrist toggles were
                // removed.

                NavigationLink("Logs") { LogView() }
                    .font(.caption)
                // The glance demo cycles the glance through every state it can render, so the
                // layouts can be judged without waiting for the real conditions. It sits on its
                // own compile condition rather than DEBUG because a clone is built in Debug and
                // run by someone who has no way to know that a screenful of invented pod and
                // insulin state is a mockup. Add GLANCE_DEMO to SWIFT_ACTIVE_COMPILATION_CONDITIONS
                // in a local LoopConfigOverride.xcconfig to get it back; nothing defines it by
                // default, so it is absent from every build a receiver can make.
                #if GLANCE_DEMO
                NavigationLink("Glance demo") { GlanceDemoView() }
                    .font(.caption)
                #endif
            }
        }
        }
        .onReceive(refresh) { _ in
            // Same 2s main-thread timer problem as the glance: the loan queue is the pump's
            // delegate queue, so a sync read froze the UI for the length of any pod operation.
            session?.loanController.refreshDebugSnapshot()
            snapshot = session?.loanController.mirroredDebugSnapshot ?? snapshot
            cgm = session.map { CGMHealth($0.stack.cgmManager) } ?? cgm
            // The comment above says this tick was converted to mirrors — but only the
            // LOAN-queue read was; this line stayed glanceData(), which is
            // `dataAccessQueue.sync` (WatchLoopManager: "kept for the DEBUG page, which ... can
            // afford to wait"). It cannot afford to wait: this closure runs on a 2s MAIN-thread
            // timer, and watchOS keeps page views alive after they are first visited — so from
            // the first time the diagnostics page was ever opened, MAIN blocked on
            // dataAccessQueue every 2 seconds, forever, even with a different page frontmost.
            // A post-carb cycle holds that queue for the whole enact (2-4s when the pod link is
            // held, ~7s when it must be reclaimed first): tick lands in the window ->
            // multi-second UI freeze (the recovered 4.1s stall); the longer reclaim window ->
            // watchdog kill; and when the queue's work item itself waited on a main-bound
            // completion, MAIN and the queue waited on each other forever (a multi-minute wedge
            // ending in a force-quit). Same mirror discipline as the glance now: kick the
            // rebuild, render the last published mirror.
            RuntimeStateLog.mark("debug.tick")
            session?.stack.loopManager.refreshGlanceData()
            if let gd = session?.stack.loopManager.mirroredGlanceData {
                dosing = gd
                iobText = gd.iob.map { String(format: "%.2f U", $0) } ?? "—"
            }
            session?.stack.loopManager.glanceCarbsOnBoard { v in
                DispatchQueue.main.async { cobText = v.map { String(format: "%.0f g", $0) } ?? "—" }
            }
        }
        .onAppear {
            // Same 2s main-thread timer problem as the glance: the loan queue is the pump's
            // delegate queue, so a sync read froze the UI for the length of any pod operation.
            session?.loanController.refreshDebugSnapshot()
            snapshot = session?.loanController.mirroredDebugSnapshot ?? snapshot
            cgm = session.map { CGMHealth($0.stack.cgmManager) } ?? cgm
            // The comment above says this tick was converted to mirrors — but only the
            // LOAN-queue read was; this line stayed glanceData(), which is
            // `dataAccessQueue.sync` (WatchLoopManager: "kept for the DEBUG page, which ... can
            // afford to wait"). It cannot afford to wait: this closure runs on a 2s MAIN-thread
            // timer, and watchOS keeps page views alive after they are first visited — so from
            // the first time the diagnostics page was ever opened, MAIN blocked on
            // dataAccessQueue every 2 seconds, forever, even with a different page frontmost.
            // A post-carb cycle holds that queue for the whole enact (2-4s when the pod link is
            // held, ~7s when it must be reclaimed first): tick lands in the window ->
            // multi-second UI freeze (the recovered 4.1s stall); the longer reclaim window ->
            // watchdog kill; and when the queue's work item itself waited on a main-bound
            // completion, MAIN and the queue waited on each other forever (a multi-minute wedge
            // ending in a force-quit). Same mirror discipline as the glance now: kick the
            // rebuild, render the last published mirror.
            RuntimeStateLog.mark("debug.tick")
            session?.stack.loopManager.refreshGlanceData()
            if let gd = session?.stack.loopManager.mirroredGlanceData {
                dosing = gd
                iobText = gd.iob.map { String(format: "%.2f U", $0) } ?? "—"
            }
            session?.stack.loopManager.glanceCarbsOnBoard { v in
                DispatchQueue.main.async { cobText = v.map { String(format: "%.0f g", $0) } ?? "—" }
            }
        }
    }

    /// The prediction's four components — INSULIN, carbs, momentum,
    /// retrospection — on one line, arithmetically reconciled to the `eventual` row above it.
    ///
    ///     133 ins-4 carb+0 mom+6 RC+16 r+0 = 151
    ///
    /// Every term is mg/dL, forced-sign, and the row LITERALLY ADDS UP: `r` is the closure
    /// term, so start + ins + carb + mom + RC + r == eventual as rendered. The components come
    /// from `WatchLoopManager.computePredictionBreakdown()`, which replays `LoopMath`'s own
    /// per-date arithmetic per contributor (including the momentum blend's (1 − split) scaling
    /// of the other effects), so the true residual is ~0 and `r` carries only integer rounding.
    /// A big `r` on the wrist therefore means the decomposition has drifted from the prediction
    /// — deliberately visible rather than silently absorbed.
    ///
    /// Monospaced (the `LogView` register, :248) so the signed terms don't jitter on the 2 s
    /// refresh; it WRAPS rather than truncating or shrinking, matching this screen's habit —
    /// no number is ever clipped.
    @ViewBuilder
    private var predictionReconciliation: some View {
        if let b = dosing?.predictionBreakdown {
            // `-0.0` formats as "-0"; normalize so a zero term reads "+0".
            let s = WatchLoopManager.PredictionBreakdown.round0(b.startMgdl)
            let ins = WatchLoopManager.PredictionBreakdown.round0(b.insulinMgdl)
            let carb = WatchLoopManager.PredictionBreakdown.round0(b.carbMgdl)
            let mom = WatchLoopManager.PredictionBreakdown.round0(b.momentumMgdl)
            let rc = WatchLoopManager.PredictionBreakdown.round0(b.retrospectiveMgdl)
            let ev = WatchLoopManager.PredictionBreakdown.round0(b.eventualMgdl)
            let r = WatchLoopManager.PredictionBreakdown.round0(ev - (s + ins + carb + mom + rc))
            Text(String(format: "%.0f ins%+.0f carb%+.0f mom%+.0f RC%+.0f r%+.0f = %.0f",
                        s, ins, carb, mom, rc, r, ev))
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            // Say WHICH retrospective model produced that RC term. The watch
            // adopts the phone's Integral toggle at takeover, so a mismatch here against the
            // phone's setting is the signature of the two devices predicting differently — the
            // thing that adoption exists to prevent, and previously only checkable in the log.
            Text(String(format: "RC model: %@ · %d discrepanc%@",
                        (dosing?.retrospectiveCorrectionIsIntegral ?? false) ? "Integral" : "Standard",
                        dosing?.retrospectiveDiscrepancyCount ?? 0,
                        (dosing?.retrospectiveDiscrepancyCount ?? 0) == 1 ? "y" : "ies"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("— no prediction to reconcile")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.caption2)
        }
    }
}

// MARK: - On-wrist log viewer + share (unified g7watch.log via SportLog)

/// Reads the tail of the single on-device log (G7 transport + M5 protocol) and offers
/// a share sheet — so a TestFlight build's logs can be read and sent from the wrist,
/// no Mac / devicectl. Newest lines at the top.
struct LogView: View {
    @State private var text: String = ""
    @State private var sendNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                // The full file rides WCSession's queued transfer (works even while the
                // phone is unreachable — it delivers when contact resumes) and lands in
                // the phone's Files app (On My iPhone → Loop), where the PHONE's share
                // sheet has real AirDrop. watchOS has no AirDrop; texting logs was pain.
                Button {
                    if let url = LogFile.url {
                        WCSession.default.transferFile(url, metadata: ["kind": "g7watch.log"])
                        sendNote = "queued — appears in iPhone Files app (Loop folder)"
                    }
                } label: {
                    Label("Send Log to iPhone", systemImage: "iphone.and.arrow.forward")
                }
                .font(.caption)
                if let note = sendNote {
                    Text(note).font(.system(size: 10)).foregroundColor(.secondary)
                }

                // Share the ALREADY-LOADED text rather than calling LogFile.tail() here.
                // `item:` is an argument to a View initialiser, so it was re-evaluated on EVERY
                // body pass — and LogFile.tail() is `queue.sync` onto the log-writer queue plus a
                // full file read and a 64 KB UTF-8 decode, all on MAIN. That is a main-thread
                // block whose duration is set by the log-append backlog, which is exactly what
                // spikes during a loan. `text` is loaded once in onAppear and by Refresh.
                ShareLink(item: text) {
                    Label("Share log", systemImage: "square.and.arrow.up")
                }
                .font(.caption)

                Button("Refresh") { load() }
                    .font(.caption)

                Text(text.isEmpty ? "no log yet" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("Logs")
        .onAppear(perform: load)
    }

    private func load() {
        // Newest first: reverse the tail's lines so the latest events are on top.
        let tail = LogFile.tail()
        text = tail.split(separator: "\n", omittingEmptySubsequences: false)
            .reversed().joined(separator: "\n")
    }
}


// RADIO LAB REMOVED 2026-09-08 (Jeremy: "we don't need the radio lab anymore").
// Every question it existed to answer has been settled and the answers are hardcoded:
//   - the G7 doorway toggles went in the 2026-08-25 settlement (now one G7RidePolicy);
//   - "Alarm scan (C00A)" was one OmnipodKit key nobody had flipped in weeks, and it stays
//     at its shipped default (the key is still read at use, so a shell default still works);
//   - the reclaim exerciser answered the reclaim-cadence question months ago.
// The PLUMBING is untouched — `loanController.benchReclaimStart/Stop` and
// `connectionDiagnostics()` are all still there — so a bench drill is one small view away.
// What replaced it: the actions that are actually used, on the main screen, named for a
// reader who is not us.
