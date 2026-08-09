//
//  LoanCarbListController.swift
//  WatchApp Extension
//
//  R30 (#89): the carb list, wired for Sport Mode.
//
//  Stock already ships this screen — `CarbEntryListController`, reached by tapping active carbs
//  on the chart HUD, rendering time + grams per row with no graph and no per-row absorption.
//  Jeremy 2026-08-08: "same idea as everything else — same screen, different wiring."
//
//  This is a PARALLEL controller rather than an edit to stock's, for two reasons. R30 rules that
//  regular mode stays read-only and unchanged, and stock's controller is a WKInterfaceTable,
//  which has no swipe affordance at all. So the loan gets a SwiftUI twin, the chart HUD branches
//  on `isLoanActive` at the presentation site, and backing the whole feature out is deleting this
//  file plus one `if`.
//
//  Two wiring differences from stock, both load-bearing:
//
//  1. IT READS THE LOAN STACK. Stock reads `ExtensionDelegate.shared().loopManager.carbStore` —
//     the stock stack, backfilled from the phone — and calls `requestCarbBackfill()`, which ASKS
//     the phone. During a loan the authoritative store is the loan stack, and the phone is the
//     thing Sport Mode assumes may be unreachable. Pointing at the stock store would show the
//     wrong carbs exactly when it matters, and go blank exactly when the phone is gone.
//
//  2. DELETION RIDES THE JOURNAL. Local-only would be resurrected: `ingestGrantCarbs` mirrors
//     the phone at every takeover. See `PodLoanWatchController.loanDidDeleteCarb`.
//
//  No ceremony, per R30: deleting carbs lowers COB, which lowers predicted glucose, which makes
//  the loop dose LESS — the conservative direction — and it is undone by re-entering the carb.
//

import Foundation
import SwiftUI
import WatchKit
import HealthKit
import LoopKit
import LoopCore

final class LoanCarbListController: WKHostingController<LoanCarbListView>, IdentifiableClass {
    private let model = LoanCarbListModel()

    override var body: LoanCarbListView { LoanCarbListView(model: model) }

    override func didAppear() {
        super.didAppear()
        model.reload()
    }
}

// MARK: - Model

final class LoanCarbListModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let entry: StoredCarbEntry
        let timeText: String
        let gramsText: String
        static func == (a: Row, b: Row) -> Bool { a.id == b.id }
    }

    @Published var rows: [Row] = []
    @Published var cobText: String = "—"
    /// Set when a delete could not be journaled — the one case the user must be told about,
    /// because the carb is gone here and still live on the phone.
    @Published var warning: String?

    private let isPreview: Bool

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    init() { isPreview = false }

    init(preview rows: [Row], cob: String) {
        isPreview = true
        self.rows = rows
        self.cobText = cob
    }

    func reload() {
        guard !isPreview else { return }
        let session = ExtensionDelegate.shared().stockLoopSession
        let store = session.stack.loopManager.carbStore
        // Same window stock uses: today, or one full absorption interval back, whichever is
        // earlier — so a long-absorbing breakfast is still deletable in the afternoon.
        let start = min(Calendar.current.startOfDay(for: Date()),
                        Date(timeIntervalSinceNow: -store.maximumAbsorptionTimeInterval))
        store.getCarbEntries(start: start) { [weak self] result in
            guard let self = self, case .success(let entries) = result else { return }
            let rows = entries.reversed().map { entry in
                Row(id: entry.syncIdentifier ?? "\(entry.startDate.timeIntervalSince1970)-\(entry.quantity.doubleValue(for: .gram()))",
                    entry: entry,
                    timeText: Self.timeFormatter.string(from: entry.startDate),
                    gramsText: String(format: "%.0f g", entry.quantity.doubleValue(for: .gram())))
            }
            DispatchQueue.main.async { self.rows = rows }
        }
        session.stack.loopManager.glanceCarbsOnBoard { [weak self] cob in
            DispatchQueue.main.async {
                self?.cobText = cob.map { String(format: "%.0f g", $0) } ?? "—"
            }
        }
    }

    /// Delete locally FIRST, then journal. The order is deliberate: the local store is what this
    /// loop cycle predicts from, so the user's next cycle should already reflect the deletion
    /// even if the journal mint fails — and a mint failure is loud rather than silent.
    func delete(_ row: Row) {
        guard !isPreview else { rows.removeAll { $0.id == row.id }; return }
        let session = ExtensionDelegate.shared().stockLoopSession
        let grams = row.entry.quantity.doubleValue(for: .gram())
        let syncIdentifier = row.entry.syncIdentifier
        let startDate = row.entry.startDate

        rows.removeAll { $0.id == row.id }   // optimistic: the row is gone, the loop recalculates
        SportLog.event("carb-ui", String(format: "wrist DELETE %.0f g @ %@ · sync=%@",
                                         grams, Self.timeFormatter.string(from: startDate),
                                         syncIdentifier ?? "none(watch-entered)"))

        // deleteLoanCarbEntry invalidates carbEffect and re-runs the loop, so the prediction
        // drops the carb within seconds rather than at the next reading.
        session.stack.loopManager.deleteLoanCarbEntry(row.entry) { [weak self] ok in
            guard ok else {
                DispatchQueue.main.async {
                    self?.warning = NSLocalizedString("Couldn't delete", comment: "Watch carb list error when a delete fails")
                    self?.reload()   // put the row back — it is still live and still dosing
                }
                return
            }
            session.loanController.loanDidDeleteCarb(syncIdentifier: syncIdentifier,
                                                     startDate: startDate,
                                                     grams: grams)
            DispatchQueue.main.async { self?.reload() }
        }
    }
}

// MARK: - View

struct LoanCarbListView: View {
    @ObservedObject var model: LoanCarbListModel

    var body: some View {
        List {
            Section {
                ForEach(model.rows) { row in
                    HStack {
                        Text(row.timeText)
                            .font(.system(size: 14))
                        Spacer()
                        Text(row.gramsText)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            model.delete(row)
                        } label: {
                            Label(NSLocalizedString("Delete", comment: "Watch carb list swipe action"),
                                  systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Active carbs", comment: "Watch carb list header")
                        .font(.system(size: 12))
                    Spacer()
                    Text(model.cobText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                }
            } footer: {
                if let warning = model.warning {
                    Text(warning).font(.system(size: 11)).foregroundColor(.orange)
                } else if model.rows.isEmpty {
                    Text("No active carbs", comment: "Watch carb list empty state")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

#Preview("Loan carbs") {
    LoanCarbListView(model: LoanCarbListModel(preview: [], cob: "24 g"))
}
