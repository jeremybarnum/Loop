//
//  LoanEventJournal.swift
//  WatchApp Extension
//
//  The watch-side protocol ledger for loan v2 (docs/DESIGN_LOAN_PROTOCOL_V2.md §1.2/§1.3,
//  §10). This is the PROTOCOL record, not a dose world: dosing math reads only the
//  LoopKit DoseStore; the journal exists so every journal-worthy occurrence can travel
//  to the phone with a stable identity (minted at INTENT time, before pod transmission),
//  a monotonic per-loan seq for cursor acks, and a provenance tag (R6 layer 2).
//
//  Durability: every mutation persists to disk BEFORE returning (journal-loss-proof,
//  P4 / the crude build's 0.85 U loss lesson). Relaunch loads the persisted state so
//  the recovered hand-back can drain it (spec §3.2 RELAUNCH).
//

import Foundation
import LoopCore
import os.log

final class LoanEventJournal {
    private struct State: Codable {
        var epoch: Int
        var nextSeq: Int
        var events: [LoanEvent]

        var tombstones: [UUID]

        var ackedCursor: Int

        static func empty(epoch: Int) -> State {
            State(epoch: epoch, nextSeq: 1, events: [], tombstones: [], ackedCursor: 0)
        }
    }

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "LoanEventJournal")
    private let lock = NSLock()
    private var state: State?
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = base.appendingPathComponent("PodLoanJournalV2.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? LoanProtocol.decoder.decode(State.self, from: data) {
            self.state = loaded
            os_log("Loaded persisted loan journal: epoch %d, %d events, cursor %d",
                   log: log, type: .default, loaded.epoch, loaded.events.count, loaded.ackedCursor)
        }
    }

    var activeEpoch: Int? {
        lock.lock(); defer { lock.unlock() }
        return state?.epoch
    }

    var hasUndrainedEvents: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let s = state else { return false }
        return s.events.contains { $0.seq > s.ackedCursor } || !s.tombstones.isEmpty
    }

    func begin(epoch: Int) throws {
        lock.lock(); defer { lock.unlock() }
        if let s = state, s.events.contains(where: { $0.seq > s.ackedCursor }) {
            throw LoanJournalError.undrainedPriorLoan(epoch: s.epoch)
        }
        state = .empty(epoch: epoch)
        persistLocked()
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        state = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    @discardableResult
    func adoptEpoch(_ newEpoch: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard var s = state else {
            state = .empty(epoch: newEpoch)
            persistLocked()
            return 0
        }
        let carried = s.events.filter { $0.seq > s.ackedCursor }.count + s.tombstones.count
        s.epoch = newEpoch
        state = s
        persistLocked()
        os_log("Journal FOLDED into epoch %d — %d undrained event(s) carried, cursor %d kept",
               log: log, type: .default, newEpoch, carried, s.ackedCursor)
        return carried
    }

    func mintEvent(record: LoanDoseRecord, provenance: EventProvenance, at date: Date = Date()) throws -> LoanEvent {
        lock.lock(); defer { lock.unlock() }
        guard var s = state else { throw LoanJournalError.noActiveLoan }
        let event = LoanEvent(id: UUID(), seq: s.nextSeq, provenance: provenance, record: record, loggedAt: date)
        s.nextSeq += 1
        s.events.append(event)
        state = s
        persistLocked()
        return event
    }

    func contains(syncIdentifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state?.events.contains { $0.record.syncIdentifier == syncIdentifier } ?? false
    }

    func unackedEvents() -> [LoanEvent] {
        lock.lock(); defer { lock.unlock() }
        guard let s = state else { return [] }
        return s.events.filter { $0.seq > s.ackedCursor }.sorted { $0.seq < $1.seq }
    }

    func pendingTombstones() -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        return state?.tombstones ?? []
    }

    var lastEventSeq: Int {
        lock.lock(); defer { lock.unlock() }
        guard let s = state else { return 0 }
        return s.nextSeq - 1
    }

    func applyAck(committedCursor: Int) {
        mutate { s in
            let cursor = committedCursor
            s.ackedCursor = max(s.ackedCursor, cursor)
            s.tombstones.removeAll()
        }
    }

    private func mutate(_ body: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var s = state else { return }
        body(&s)
        state = s
        persistLocked()
    }

    private func persistLocked() {
        guard let s = state else { return }
        do {
            let data = try LoanProtocol.encoder.encode(s)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            os_log("Loan journal persist FAILED: %{public}@", log: log, type: .fault, String(describing: error))
        }
    }
}

enum LoanJournalError: Error {
    case noActiveLoan
    case undrainedPriorLoan(epoch: Int)
}
