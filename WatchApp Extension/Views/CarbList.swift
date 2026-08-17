//
//  CarbList.swift
//  Loop
//
//  Created by Pete Schwamb on 9/20/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopAlgorithm

struct CarbList: View {
    @Environment(LoopDataManager.self) var loopManager

    var timeFormatter: DateFormatter = {
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        return timeFormatter
    }()

    var carbFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: .gram)
        formatter.numberFormatter.numberStyle = .none
        return formatter
    }()

    @State var entries: [StoredCarbEntry] = []

    /// Set when a delete could not be journaled — the one case the user must be told about,
    /// because the carb is gone here and still live on the phone.
    @State private var warning: String?

    /// DURING A LOAN THIS LIST IS EDITABLE, and it reads a different store.
    ///
    /// The loan stack owns the authoritative carb store while the pod is on the wrist, so reading
    /// the stock store here would show the phone's copy and delete from the wrong book. Deletion
    /// exists for the same reason the loan exists at all: the phone may not be there to edit on.
    /// Off-loan the premise is the opposite — you have your phone — so this stays exactly as
    /// stock: the phone's entries, read-only.
    private var loanSession: StockLoopSession? {
        guard let session = ExtensionDelegate.sharedIfAvailable()?.stockLoopSession,
              session.loanController.isLoanActiveNonBlocking else { return nil }
        return session
    }

    private func reloadCarbEntries() async {
        // The same window stock uses: today, or one full absorption interval back, whichever is
        // earlier — so a long-absorbing breakfast is still listed (and deletable) in the afternoon.
        let start = min(Calendar.current.startOfDay(for: Date()), Date(timeIntervalSinceNow: -CarbMath.maximumAbsorptionTimeInterval))
        let store = loanSession?.stack.loopManager.carbStore ?? loopManager.carbStore
        entries = (try? await store.getCarbEntries(start: start)) ?? []
    }

    /// Delete locally FIRST, then journal. The order is deliberate: the local store is what this
    /// loop cycle predicts from, so the next cycle should already reflect the deletion even if the
    /// journal mint fails — and a mint failure is loud rather than silent.
    private func delete(_ entry: StoredCarbEntry) {
        guard let session = loanSession else { return }
        let grams = entry.quantity.doubleValue(for: .gram)
        let syncIdentifier = entry.syncIdentifier
        let startDate = entry.startDate

        entries.removeAll { $0 == entry }   // optimistic: the row is gone, the loop recalculates
        SportLog.event("carb-ui", String(format: "wrist DELETE %.0f g @ %@ · sync=%@",
                                         grams, timeFormatter.string(from: startDate),
                                         syncIdentifier ?? "none(watch-entered)"))

        // deleteLoanCarbEntry invalidates carbEffect and re-runs the loop, so the prediction drops
        // the carb within seconds rather than at the next reading.
        session.stack.loopManager.deleteLoanCarbEntry(entry) { ok in
            guard ok else {
                Task { @MainActor in
                    warning = NSLocalizedString("Couldn't delete", comment: "Watch carb list error when a delete fails")
                    await reloadCarbEntries()   // put the row back — it is still live and still dosing
                }
                return
            }
            session.loanController.loanDidDeleteCarb(syncIdentifier: syncIdentifier,
                                                     startDate: startDate,
                                                     grams: grams)
            Task { @MainActor in await reloadCarbEntries() }
        }
    }

    var activeCarbs: String? {
        guard let activeContext = loopManager.activeContext,
              let activeCarbohydrates = activeContext.activeCarbohydrates
        else {
            return nil
        }

        return carbFormatter.string(from: activeCarbohydrates)
    }

    var totalCarbs: String? {
        let total = entries.reduce(0, { sum, entry in
            return sum + entry.quantity.doubleValue(for: .gram)
        })

        return carbFormatter.string(from: LoopQuantity(unit: .gram, doubleValue: total))
    }

    var body: some View {
        List {
            Section {
                ForEach(entries, id: \.self) { entry in
                    HStack {
                        Text(timeFormatter.string(from: entry.startDate))
                        Spacer()
                        Text(carbFormatter.string(from: entry.quantity) ?? "-")
                    }
                    // Swipe-to-delete only while the wrist holds the pod. Off-loan the phone owns
                    // these entries and a delete here would edit the wrong book.
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if loanSession != nil {
                            Button(role: .destructive) {
                                delete(entry)
                            } label: {
                                Label(NSLocalizedString("Delete", comment: "Watch carb list swipe action"),
                                      systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                VStack {
                    HStack {
                        Text("Active Carbs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Text(activeCarbs ?? "-")
                            .font(.title3)
                            .foregroundStyle(.primary)
                    }
                    HStack {
                        Text("Total Carbs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Text(totalCarbs ?? "-")
                            .font(.title3)
                            .foregroundStyle(.primary)
                    }
                    .padding(.bottom, 4)
                }
            } footer: {
                if let warning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            Task {
                await reloadCarbEntries()
            }
        }
    }
}
