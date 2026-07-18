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

final class LoanDebugController: WKHostingController<LoanDebugView> {
    override var body: LoanDebugView {
        LoanDebugView()
    }
}

struct LoanDebugView: View {
    @State private var snapshot: PodLoanWatchController.DebugSnapshot?
    @State private var lastAction: String = "—"

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var session: StockLoopSession {
        ExtensionDelegate.shared().stockLoopSession
    }

    var body: some View {
        NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("LOAN v2 BENCH").font(.footnote).foregroundColor(.secondary)

                row("phase", snapshot.map { String(describing: $0.phase) } ?? "—")
                row("epoch", snapshot?.epoch.map(String.init) ?? "—")
                row("mode", snapshot.map { $0.mode.rawValue } ?? "—")
                row("pump", (snapshot?.hasPumpManager ?? false) ? "constructed" : "nil")
                row("odometer", snapshot?.deliveredUnits.map { String(format: "%.2f U", $0) } ?? "—")
                row("fault", snapshot?.podFault ?? "none")
                row("last seq", snapshot.map { String($0.lastEventSeq) } ?? "—")
                row("unacked", snapshot.map { String($0.unackedCount) } ?? "—")
                row("uncertain", (snapshot?.pendingUncertain ?? false) ? "CHASING" : "no")
                row("last act", lastAction)

                Divider().padding(.vertical, 2)

                Button("Request Loan") {
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    session.loanController.requestLoan(watchBuild: build)
                    lastAction = "requested"
                }
                Button("Hand Back") {
                    session.loanController.beginHandback()
                    lastAction = "handback"
                }
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
        }
        .onAppear {
            snapshot = session.loanController.debugSnapshot()
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
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
