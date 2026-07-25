//
//  LoanDebugController.swift
//  WatchApp Extension
//
//  The deliberately bare-bones third page for bench testing the loan protocol
//  (Jeremy's direction 2026-07-17: stock screens stay intact; a minimal debug
//  surface now; the real Sport-Mode UI is designed at the end, knowing the
//  functionality). Everything here is diagnostic — no dosing controls beyond the
//  protocol entry points the drills need (request / hand back / status read).
//

import Foundation
import SwiftUI
import WatchKit
import WatchConnectivity
import HealthKit   // #29 DOSING readout: HKQuantity glucose/eventual
import LoopKit     // #29: the .milligramsPerDeciliter HKUnit convenience

final class LoanDebugController: WKHostingController<LoanDebugView> {
    override var body: LoanDebugView {
        LoanDebugView()
    }
}

struct LoanDebugView: View {
    @State private var snapshot: PodLoanWatchController.DebugSnapshot?
    @State private var g7: G7Client.IdentitySnapshot?
    @State private var lastAction: String = "—"
    /// The loop's own IOB (Jeremy 2026-07-19: the dosing math is what matters —
    /// surface it here until the UI pass wires the main screens).
    @State private var iobText: String = "—"
    /// #29 live dosing readout — "is it trying to dose?" made visible on-wrist.
    /// Refreshes on the same 2s timer as everything else.
    @State private var dosing: WatchLoopManager.GlanceData?
    @State private var cobText: String = "—"

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var session: StockLoopSession {
        ExtensionDelegate.shared().stockLoopSession
    }

    var body: some View {
        NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                // #29: the dosing decision, on-wrist. `recommend` vs `running` is the
                // tell — high recommend + baseline running + closed = it wants to dose
                // but isn't enacting; matching = it dosed; loop OPEN = not dosing at all.
                Text("DOSING").font(.footnote).foregroundColor(.secondary)
                row("closed?", (dosing?.closedLoopEnabled ?? false) ? "YES" : "no")
                row("BG now", dosing?.glucose.map { String(format: "%.0f", $0.doubleValue(for: .milligramsPerDeciliter)) } ?? "—")
                row("eventual", dosing?.eventual.map { String(format: "%.0f", $0.doubleValue(for: .milligramsPerDeciliter)) } ?? "—")
                row("COB / IOB", "\(cobText) / \(dosing?.iob.map { String(format: "%.2f U", $0) } ?? "—")")
                row("recommend", dosing?.recommendedTempRate.map { String(format: "%+.2f U/hr", $0) } ?? "—")
                row("running", dosing?.tempRate.map { String(format: "%+.2f U/hr net", $0) } ?? "none (scheduled)")
                row("last loop", dosing?.lastLoopCompleted.map { String(format: "%.0fs ago", Date().timeIntervalSince($0)) } ?? "—")
                if let err = dosing?.lastLoopErrorText { row("loop err", err) }

                Divider().padding(.vertical, 2)

                Text("LOAN v2 BENCH").font(.footnote).foregroundColor(.secondary)

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
                // beginHandback still live on those paths). Read Status + Reset stay:
                // a live pod-reachability probe and the un-wedge-the-controller valve.
                Button("Read Status") {
                    lastAction = "reading…"
                    session.loanController.debugReadStatus { ok in
                        DispatchQueue.main.async {
                            switch ok {
                            case .some(true): lastAction = "pod status OK"
                            case .some(false): lastAction = "pod UNREACHABLE"
                            case .none: lastAction = "no pod (not in a loan)"
                            }
                        }
                    }
                }
                Button("Reset (debug)") {
                    session.loanController.debugReset()
                    lastAction = "reset to idle"
                }

                Divider().padding(.vertical, 2)

                // G7 identity: the state that decides fast (targeted reconnect) vs
                // slow (throttled cold scan) acquisition. "bonded: none" on a session
                // that can't find the G7 IS the diagnosis — run Prewarm (foreground,
                // sensor nearby) to bond once; every later session is then targeted.
                Text("G7 IDENTITY").font(.footnote).foregroundColor(.secondary)
                row("reconnect", (g7?.reconnectMode ?? false) ? "on" : "OFF")
                row("bonded", g7?.bondedPeripheral ?? "none")
                row("sensor id", g7?.lastKnownSensorID ?? "none")
                row("code", g7?.sensorCode ?? "—")
                row("prewarm", g7?.pendingPrewarm ?? "—")
                Button("Prewarm G7 Now") {
                    session.stack.client.forcePrewarmNow()
                    lastAction = "prewarm started (keep app open)"
                }

                Divider().padding(.vertical, 2)

                // Retired bench experiments (E1 standalone-G7, E2 clean-teardown, E4
                // release-pod, Fake BG sweep, E5 random-temp) lived here through the
                // 2026-07-24 diagnostics declutter. E4 is now the production default
                // (StockLoopSession.init); the rest are one git revert away if a bench
                // drill needs them again. Their plumbing (session methods, FakeGlucose,
                // the flag reads) is intact — only the on-wrist toggles were removed.

                NavigationLink("Logs") { LogView() }
                    .font(.caption)
                #if DEBUG
                NavigationLink("Glance demo") { GlanceDemoView() }
                    .font(.caption)
                #endif
            }
        }
        }
        .onReceive(refresh) { _ in
            snapshot = session.loanController.debugSnapshot()
            g7 = session.stack.client.identitySnapshot()
            let gd = session.stack.loopManager.glanceData()
            dosing = gd
            iobText = gd.iob.map { String(format: "%.2f U", $0) } ?? "—"
            session.stack.loopManager.glanceCarbsOnBoard { v in
                DispatchQueue.main.async { cobText = v.map { String(format: "%.0f g", $0) } ?? "—" }
            }
        }
        .onAppear {
            snapshot = session.loanController.debugSnapshot()
            g7 = session.stack.client.identitySnapshot()
            let gd = session.stack.loopManager.glanceData()
            dosing = gd
            iobText = gd.iob.map { String(format: "%.2f U", $0) } ?? "—"
            session.stack.loopManager.glanceCarbsOnBoard { v in
                DispatchQueue.main.async { cobText = v.map { String(format: "%.0f g", $0) } ?? "—" }
            }
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

                ShareLink(item: LogFile.tail(maxBytes: 64 * 1024)) {
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
