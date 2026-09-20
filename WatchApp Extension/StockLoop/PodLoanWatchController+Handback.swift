//
//  PodLoanWatchController+Handback.swift
//  StockLoop
//
//  Part of PodLoanWatchController (see PodLoanWatchController.swift). Split by concern; stored properties live in the core class.
//

import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm
import LoopCore
import OmnipodKit
import WatchKit
import os.log

extension PodLoanWatchController {

    // MARK: - Revoke capture


    /// The G7's state, for the contention question that has been argued rather than measured.
    ///
    /// Stamped on every pod operation so "was the CGM holding the radio?" is answerable from one
    /// line instead of by correlating two subsystems' timestamps by eye.
    func g7StateForContention() -> String {
        loopManager.g7ContentionSummary
    }

    /// The insulin book at takeover (R35 reversed, 2026-09-17). The watch's DoseStore is the book
    /// and the watch's pump manager is its writer; the grant seeds it ONCE per epoch with the
    /// phone's FINISHED history through stock's remote-store door, under the phone's own
    /// identities. A dose still DELIVERING at takeover is NOT seeded: the grant's podState blob
    /// carries it and the pump manager reports it as a mutable dose on the first status read —
    /// stock ownership, exactly how the phone books its own running temp.
    ///
    /// The book is per loan: reset before every seed (a previous loan's rows and their re-seeded
    /// twins from the phone carry different identities until the wire moves onto pump events).
    ///
    /// Returns false when the book could not be built: the takeover is refused. A wrist without
    /// the phone's history must not dose — that is R35's operative half, kept.
    func ingestGrantHistory(_ grant: LoanGrant) -> Bool {
        let seedReconciliation = self.now()
        let (entries, liveDoses) = grant.seedDoseEntries(finishedBy: seedReconciliation)
        let epoch = grant.epoch
        let grossImpliedSum = entries.reduce(0.0) { $0 + $1.programmedUnits }
        let liveNote = liveDoses.isEmpty ? "" :
            String(format: "; %d live — delivery tracked from pod state (#72), latest ends +%.0fm",
                   liveDoses.count, (liveDoses.map { $0.endDate }.max()!.timeIntervalSince(seedReconciliation)) / 60)
        // Blocking on purpose: the takeover must not proceed on a book that is not built. A Core
        // Data upsert of ~100 rows takes milliseconds; this serial queue waits for it the way it
        // waits for a pod read.
        let gate = DispatchSemaphore(value: 0)
        var seedError: Error?
        let loopManager = self.loopManager
        Task {
            await loopManager.resetInsulinBook(reason: "new grant (epoch \(epoch))")
            do { try await loopManager.seedInsulinHistory(entries) } catch { seedError = error }
            gate.signal()
        }
        gate.wait()
        if let seedError {
            SportLog.event("loan", "** INSULIN BOOK SEED FAILED — \(String(describing: seedError)) — refusing the takeover: a wrist without the phone's history must not dose **")
            return false
        }
        SportLog.event("loan", String(format: "insulin book seeded from grant — %d finished record(s) under the phone's identities%@ · grossImpliedΣ=%.2fU",
                                       entries.count, liveNote, grossImpliedSum))
        // SEED-IN IOB off the book: primes the glance/HUD so IOB shows at takeover instead of
        // blank until the first cycle, then the row-by-row decomposition for the boundary diff.
        loopManager.primeIOBFromStore(at: seedReconciliation) { iob in
            guard let iob = iob else {
                SportLog.event("loan", "SEED-IN IOB unavailable (no schedule yet)")
                return
            }
            SportLog.event("loan", String(format: "SEED-IN IOB=%.2fU @ takeover (%d seeded doses: %d finished%@)",
                                          iob, entries.count + liveDoses.count, entries.count, liveNote))
            self.loopManager.dumpIOBDecomp("SEED-IN", at: seedReconciliation)
        }
        ingestGrantCarbs(grant)
        ingestGrantGlucose(grant)
        return true
    }

    /// Make the watch carb store an authoritative MIRROR of the phone's at takeover:
    /// WIPE it, then replace with the grant's carbs via `setSyncCarbObjects` (which
    /// `purgeCachedCarbObjectsUnconditionally` before inserting). This is the phantom-COB fix.
    /// The previous `syncCarbObjects` UPSERTED on (syncIdentifier, provenanceIdentifier) and never
    /// deleted absent entries, so a prior-epoch residual — or a carb the user DELETED on the phone
    /// (→ empty grant, which used to early-return and wipe nothing) — survived on the watch,
    /// absorbing and pushing dosing until it aged past the 24 h cache. With a true replace, an empty
    /// grant wipes to zero, so phone-side deletions propagate. Safe because carbs are ONE-WAY
    /// phone→watch in v1: watch-entered carbs are not returned (see `loanDidRecordCarbs`), so the
    /// watch never legitimately holds a carb the phone doesn't. Full bidirectional sync is future work.
    func ingestGrantCarbs(_ grant: LoanGrant) {
        let phoneCOB = grant.predictionSnapshot?.cobGrams
        let phoneCOBStr = phoneCOB.map { String(format: "%.1f", $0) } ?? "n/a"
        // How stale the phone's COB is. The comparison below is meaningless without it: carbs
        // decay, so a 98-second-old phone COB is legitimately a couple of grams under a fresh one.
        let snapshotAge = grant.predictionSnapshot.map { self.now().timeIntervalSince($0.snapshotAt) }
        let carbs = grant.carbHistory ?? []
        let objects: [SyncCarbObject] = carbs.map { c in
            SyncCarbObject(
                absorptionTime: c.absorptionTime,
                createdByCurrentApp: false,
                foodType: c.foodType,
                grams: c.grams,
                startDate: c.startDate,
                uuid: nil,
                provenanceIdentifier: c.provenanceIdentifier,
                syncIdentifier: c.syncIdentifier,
                syncVersion: c.syncVersion,
                userCreatedDate: c.userCreatedDate,
                userUpdatedDate: c.userUpdatedDate,
                userDeletedDate: nil,
                operation: .create,
                addedDate: nil,
                supercededDate: nil)
        }
        let seededGrams = carbs.reduce(0.0) { $0 + $1.grams }
        let source = (grant.carbHistory == nil) ? "absent(old phone)"
                   : (carbs.isEmpty ? "empty(deleted on phone)→wipe" : "\(objects.count) entr\(objects.count == 1 ? "y" : "ies")")
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let manifest = carbs.isEmpty ? "—" : carbs.map { c in
            String(format: "%.1fg@%@ sync=%@ prov=%@", c.grams, tf.string(from: c.startDate),
                   c.syncIdentifier ?? "nil", String(c.provenanceIdentifier.prefix(12)))
        }.joined(separator: " | ")
        // WIPE-then-replace: setSyncCarbObjects purges unconditionally first, so an EMPTY set is a
        // clean wipe (deletions propagate) and a non-empty set fully replaces (no residual/dup).
        loopManager.carbStore.setSyncCarbObjects(objects) { [weak self] error in
            if let error = error {
                os_log("Grant carb replace failed: %{public}@", log: OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanWatchController"), type: .error, String(describing: error))
                return
            }
            // [cob-diff]: did the wipe-then-replace leave the watch holding EXACTLY the
            // phone's carbs?
            //
            // That question is answered by the ENTRY SET, not by comparing computed COB. The
            // earlier check inferred a residual from Δ(post−phone) > 2 g, which is a category
            // error.
            //
            // Both devices compute COB through the SAME dynamic API, with effect velocities
            // passed identically (WatchLoopManager :703, LoopDataManager :1142) — this is NOT a
            // static-vs-dynamic split between platforms. The divergence is observation
            // FRESHNESS: dynamic absorption falls back, per entry, to the modelled curve while
            // that entry has no observed timeline yet (CarbStatus :56). This read happens
            // immediately after the replace, before any cycle has extended the watch's
            // insulinCounteractionEffects over the newly-seeded carbs, so they take that
            // fallback; the phone's cached figure is from a completed cycle that has observation
            // behind it. The phone would print the same number if read at this instant.
            //
            // Field evidence across eight replaces: Δ ≈ 0 with the newest carb 1 min old
            // (nothing absorbed yet, both agree) and 90-148 min old (both ~zero), and +4.3 to
            // +7.3 g at 3, 5, 8, 21 and 51 min — perfect separation on absorption phase, none on
            // entry count or snapshot age. Every one was reported as "wipe failed?".
            //
            // So read the store back and compare identities. `manifest` above is what we SENT,
            // which proves nothing about what landed.
            guard let self = self else { return }
            let expectedIDs = Set(carbs.compactMap { $0.syncIdentifier })
            let readFrom = (carbs.map(\.startDate).min() ?? self.now()).addingTimeInterval(-3600)
            self.loopManager.carbStore.getCarbEntries(start: readFrom) { result in
                var verdict: String
                switch result {
                case .failure(let e):
                    // Unverified is NOT the same as clean — say so rather than printing a
                    // silent pass.
                    verdict = " ⚠ wipe UNVERIFIED (read-back failed: \(e))"
                case .success(let stored):
                    let storedIDs = Set(stored.compactMap { $0.syncIdentifier })
                    let residual = storedIDs.subtracting(expectedIDs)
                    let missing = expectedIDs.subtracting(storedIDs)
                    let dupes = stored.count - storedIDs.count
                    if residual.isEmpty && missing.isEmpty && dupes == 0 {
                        verdict = " · wipe verified \(stored.count)/\(expectedIDs.count)"
                    } else {
                        verdict = String(format: " ⚠ WIPE FAILED — %d residual, %d missing, %d duplicate",
                                         residual.count, missing.count, dupes)
                    }
                }
                self.loopManager.glanceCarbsOnBoard { cob in
                    let postV = cob ?? 0
                    let vsPhone = phoneCOB.map { postV - $0 }
                    // Δ stays in the line — it is worth seeing — but as what it is: the two sides
                    // reading the same dynamic model at different observation maturity, which
                    // grows with actively-absorbing carbs and says nothing about the wipe.
                    let ageStr = snapshotAge.map { "\(Int($0.rounded()))s" } ?? "n/a"
                    SportLog.event("cob-diff", String(format: "REPLACE %@ · phoneCOB=%@ g (snapshot age %@) · watch COB(post)=%.2f g · replaced %.0f g · Δ(post−phone)=%@ g (observation freshness, not a model split)%@ · [%@]",
                                                       source, phoneCOBStr, ageStr, postV, seededGrams,
                                                       vsPhone.map { String(format: "%+.2f", $0) } ?? "—",
                                                       verdict, manifest))
                }
            }
        }
    }

    /// Seed ~3 h of the phone's glucose so the watch's momentum + retrospective correction
    /// compute from the FIRST post-takeover cycle. The watch GlucoseStore is otherwise empty
    /// until live G7 reads accumulate — momentum was blind for ~15 min and RC never warmed, so
    /// the watch dosed on a prediction that ignored glucose history. Reuses the phone's
    /// syncIdentifier so re-grants dedup (GlucoseStore keys on provenance + syncIdentifier).
    /// Seeded samples are pre-takeover, and the watch's G7 path reads one current EGV per
    /// connection (no backfill), so at most a SINGLE boundary sample can duplicate — phone and
    /// watch derive different G7 syncIds for the same reading, so dedup can't match it — which is
    /// harmless (momentum is duplicate-insensitive; counteraction skips sub-4-min pairs). Pairs
    /// with the RC-freeze fix in WatchLoopManager (both required for RC to produce an effect).
    private func ingestGrantGlucose(_ grant: LoanGrant) {
        guard let records = grant.glucoseHistory, !records.isEmpty else { return }
        let mgdl = LoopUnit.milligramsPerDeciliter
        let mgdlPerMin = mgdl.unitDivided(by: .minute)
        let samples: [NewGlucoseSample] = records.map { r in
            NewGlucoseSample(
                date: r.startDate,
                quantity: LoopQuantity(unit: mgdl, doubleValue: r.valueMgdl),
                condition: nil,
                trend: nil,
                trendRate: r.trendRateMgdlPerMin.map { LoopQuantity(unit: mgdlPerMin, doubleValue: $0) },
                isDisplayOnly: r.isDisplayOnly,
                wasUserEntered: r.wasUserEntered,
                syncIdentifier: r.syncIdentifier ?? "loanv2-glucose-\(Int(r.startDate.timeIntervalSince1970 * 1000))")
        }
        // Stamp the phone as the source BEFORE storing, and regardless of what dedup keeps — the
        // same OPTION C discipline the direct-G7 path uses (see GlanceData.directG7At). The
        // question the glance's provenance line answers is "who last delivered a reading to us",
        // not "whose copy won the store", and on a re-takeover every seeded sample can be a
        // duplicate while the phone has still just handed us its glucose history.
        loopManager.notePhoneGlucoseDelivered()
        Task {
            do {
                let stored = try await loopManager.glucoseStore.addGlucoseSamples(samples)
                // Same "INGEST src=" key as the direct-G7 and phone-relay paths, so
                // one grep counts every route glucose can enter this store by. Without it,
                // scoring CGM coverage meant grepping a BLE-layer line that only fires for live
                // notification values and silently misses backfill batches.
                SportLog.event("glucose", "INGEST src=grant-seed stored=\(stored.count)/\(samples.count) · loan takeover warm-up")
                SportLog.event("loan", "seeded \(stored.count) glucose sample\(stored.count == 1 ? "" : "s") from the phone (momentum/RC warm-up)")
            } catch {
                os_log("Grant glucose ingest failed: %{public}@", log: OSLog(subsystem: "com.loopkit.Loop", category: "PodLoanWatchController"), type: .error, String(describing: error))
            }
        }
    }

    /// INSTRUMENTATION ONLY: stash the phone's grant prediction snapshot on the watch loop
    /// manager (so `[predict-diff]` can subtract it) and echo it to the log at takeover, next to the
    /// SEED-IN IOB/COB lines. No-op when the grant carries no snapshot (older phone / stale caches).
    func ingestPredictionSnapshot(_ grant: LoanGrant) {
        loopManager.stashPhonePredictionSnapshot(grant.predictionSnapshot)
        guard let s = grant.predictionSnapshot else { return }
        let now = self.now()
        SportLog.event("snapshot", String(format:
            "RX phone@grant — eventual %.0f start %.0f@%.0fs IOB %.2f@%.0fs COB %.0f · impact mom %+.0f ins %+.0f carb %+.0f RC %+.0f · momPts %d rcDisc %d · snapAge %.0fs",
            s.eventualMgdl, s.startGlucoseMgdl, now.timeIntervalSince(s.startGlucoseDate),
            s.iobUnits, now.timeIntervalSince(s.iobDate), s.cobGrams,
            s.impactMomentumMgdl, s.impactInsulinMgdl, s.impactCarbMgdl, s.impactRCMgdl,
            s.momentumPointCount, s.rcDiscrepancyCount, now.timeIntervalSince(s.snapshotAt)))
    }

    /// Titles for seeded pump events (record→DoseEntry lives in the shared
    /// LoanProtocolV2 `seedDoseEntry`/`seedDoseEntries` so the watch and the tests agree).
    private static func pumpEventTitle(for type: DoseType) -> String {
        switch type {
        case .bolus:     return "Bolus"
        case .tempBasal: return "Temp Basal"
        case .basal:     return "Basal"
        case .suspend:   return "Suspend"
        case .resume:    return "Resume"
        }
    }


    // MARK: - Hand-back (§3.2 HANDING_BACK)

    /// Request a hand-back WITHOUT giving up control. Phase stays .active —
    /// dosing, boluses, and the G7 loop all continue; the journal drains via interim
    /// offers. When the drain is fully acked, finalizeHandback() stops dosing and
    /// sends the final offer. Cancelable until then.
    func beginHandback() {
        #if targetEnvironment(simulator)
        if defaults.bool(forKey: "sim.fakeLoanFlow") { simDriveHandback(); return }
        #endif
        queue.async {
            guard self.phase == .active, self.pumpManager != nil else { return }
            guard !self.handbackRequested else { return }
            self.reunionPromptActive = false   // a manual End answers the R40(f) prompt too
            self.handbackRequested = true
            self.handbackFailure = nil
            self.handbackResendCount = 0
            self.handbackSawUnreachable = false
            self.handbackSawUrgentSendError = false
            self.urgentSendWedged = false   // a fresh hand-back re-tests the fast path once
            // Bound the wait for the phone's ack. Pre-scheduled alert fires from a suspended
            // app; the resend loop resumes Sport Mode on the watch at the same deadline. Covers
            // both the interim-drain path below and the legacy single-phase finalize.
            self.handbackDeadline = self.now().addingTimeInterval(HandbackStuckAlert.interval)
            self.handbackStartedAt = self.now()
            HandbackStuckAlert.arm()
            guard self.phoneSupportsInterimHandback else {
                // Skew gate: an old phone treats ANY offer as final — go
                // straight to the legacy single-phase hand-back (stop, then offer).
                SportLog.event("loan", "HAND-BACK started (legacy single-phase — phone predates interim drains)")
                self.finalizeHandback()
                return
            }
            SportLog.event("loan", "HAND-BACK requested — draining \(self.journal.unackedEvents().count) events; still in control (WS1)")
            self.sendHandbackOffer(freshened: false, recovered: false)
        }
    }

    /// Abort a requested hand-back while still in the drain (phase .active).
    /// After finalize the pod has stopped taking watch commands — too late to cancel.
    func cancelHandback() {
        queue.async {
            guard self.phase == .active, self.handbackRequested else { return }
            self.handbackRequested = false
            self.resendWorkItem?.cancel()
            self.handbackDeadline = nil
            self.handbackStartedAt = nil
            HandbackStuckAlert.disarm()   // Aborted before the budget — no stuck alert
            SportLog.event("loan", "HAND-BACK cancelled — Sport Mode continues")
        }
    }

    /// The phone never acked the hand-back within the budget (unreachable, or silently
    /// dropping offers). We stayed the pod's SOLE OWNER throughout — interim: still dosing;
    /// final: dosing stopped but the pod is STILL HELD (release only on the final ack) — so
    /// recovery is clean: resume Sport Mode on the watch in the SAME loop mode (never auto-open
    /// or auto-close). Unacked records stay in the journal and re-offer on a
    /// later hand-back (the phone dedups by event ID); the odometer reconciles the totals then.
    /// The pre-scheduled HandbackStuckAlert delivers the wrist notification (even from a suspended
    /// app, in which case this state restore runs on the next wake).
    /// `unreachable`: the phone could not be reached at all, so no offer was sent (R41) —
    /// as opposed to an offer that went unanswered for the deadline.
    /// `refusal`: the phone answered and said no (its reason is shown as-is).
    func handbackTimedOut(unreachable: Bool = false, refusal: String? = nil) {
        let why: String
        if let refusal { why = "REFUSED by the phone — \(refusal)" }
        else if unreachable { why = "not possible — iPhone not reachable, no offer sent" }
        else { why = "timed out (\(Int(HandbackStuckAlert.interval))s) — iPhone never acked" }
        handbackFailure = (now(), refusal ?? (unreachable
            ? NSLocalizedString("iPhone not reachable — still running", comment: "Glance transient: End failed, phone unreachable")
            : NSLocalizedString("iPhone didn't respond — still running", comment: "Glance transient: End failed, no ack")))
        resendWorkItem?.cancel()
        handbackDeadline = nil
        handbackStartedAt = nil
        let wasFinal = (phase == .handingBack)
        let wedge = HandbackWedge.classify(resendCount: handbackResendCount,
                                           sawUnreachable: handbackSawUnreachable,
                                           reachableNow: isPhoneReachable(),
                                           sendsErrored: handbackSawUrgentSendError)
        let wedgeSuffix: String
        switch wedge {
        case .sessionReestablishing:
            wedgeSuffix = " · ** \(handbackResendCount) offers, phone reachable, zero acks — but the sends themselves ERRORED: session re-establishing (#113 variant B), usually self-heals in 1-2 min **"
        case .oneWay:
            wedgeSuffix = " · ** \(handbackResendCount) offers, phone REACHABLE throughout, zero acks — transport wedge (#113 variant A); restarting the WATCH app is the known recovery **"
        case .none:
            wedgeSuffix = ""
        }
        handbackRequested = false
        finalOfferSent = false
        if wasFinal {
            // RELEASED MEANS RELEASED. The watch stopped dosing when it sent the final offer, and
            // from there it cannot know whether the phone took the pod: on 2026-09-19 it resumed
            // by timer 0.6 s before the phone committed — two controllers for 7.6 minutes. It
            // stays stopped, lets go of the pod so the phone can reach it, and keeps offering its
            // records. The phone resumes on the offer, or by itself once the hold lapses.
            SportLog.event("loan", "HAND-BACK \(why) (final); staying RELEASED — the pod is let go, records keep offering, and the phone resumes on receipt or when the hold lapses\(wedgeSuffix)")
            teardownPump()
            finalOfferSentAt = nil
            deliveredAtTakeover = nil
            onLoanActiveChanged?(false)
            // Drain-only from here, even with no records left: the offer itself is the news
            // ("released"), and it may now be queued — late, it is still true.
            phase = .recoveredDrain
            sendHandbackOffer(freshened: false, recovered: true)
            issueProtocolAlert(title: NSLocalizedString("End Not Confirmed", comment: "Watch alert title: the phone has not confirmed a hand-back"),
                               body: NSLocalizedString("The watch has stopped dosing. Your iPhone takes over when it hears from the watch, or by itself within about 20 minutes. Open Loop on the iPhone to hurry it.", comment: "Watch alert body: released but unconfirmed hand-back"))
        } else {
            // Interim hang: never stopped dosing; phase already .active. Just abort the drain.
            SportLog.event("loan", "HAND-BACK \(why) (interim); Sport Mode continues on the watch\(wedgeSuffix)")
        }
        switch wedge {
        case .sessionReestablishing:
            // No alert: this variant resolves on its own, and HandbackStuckAlert has already
            // told the user End did not complete. A second, softer notice on top of it added
            // words without adding an action.
            SportLog.event("loan", "hand-back wedge variant B (session re-establishing) — no alert; expected to clear on its own")
        case .oneWay:
            // Reachability is read live at the classify site, so "is reachable" is observed.
            // The remedy no longer names ONE device: this was written when the wedge was
            // believed to be watch-side only, and 2026-08-15 produced a PHONE-side instance
            // where restarting the watch app did nothing and only reinstalling the phone app
            // cleared it. The classifier cannot tell the two apart, so the copy must not either.
            // The released case has already said its piece above; one alert, not two.
            if !wasFinal {
                issueProtocolAlert(title: "End Not Confirmed",
                                   body: "Your iPhone is reachable but hasn't confirmed. Reopening Loop on both devices usually clears this.")
            }
        case .none:
            break
        }
        // The glance now carries the message (`handbackFailure`), so the pre-scheduled
        // notification is withdrawn: this handler running means the app is awake to show it.
        // The notification remains the fallback for the one case this code cannot cover — the
        // app suspended before the deadline, where this line never runs and it fires by itself.
        HandbackStuckAlert.disarm()
    }

    /// The drain is fully acked while still active — NOW stop dosing, close the
    /// loop-temp record, freshen the odometer, and send the FINAL (released) offer.
    /// The pod's BLE link is still held until the final ack (kept from v1: release
    /// ONLY after the phone has committed everything).
    func finalizeHandback() {
        // A stale INTERIM resend timer (armed 0-15s ago) must
        // not fire during the ~3-12s of temp-cancel + status reads below — once phase
        // flips it would send released=true prematurely and the phone would reclaim
        // while this device is still commanding the pod.
        resendWorkItem?.cancel()
        finalOfferSent = false   // the close path waits for the real final offer
        guard let manager = pumpManager else {
            handbackRequested = false
            phase = .handingBack
            finalOfferSent = true
            sendHandbackOffer(freshened: false, recovered: false)
            return
        }
        handbackRequested = false
        phase = .handingBack
        // The book at the boundary, row by row, so the next grant's SEED-IN decomposition can be
        // diffed against it: on 2026-09-17 the seed read 0.4 U above the watch's own book for the
        // same rows, and this is the instrumentation that names which row moved.
        loopManager.dumpIOBDecomp("HAND-BACK", at: self.now())
        SportLog.event("loan", "drain complete — finalizing hand-back (loop dosing stops now)")
        // Read the running temp BEFORE the loop manager loses its pump: runningTempBasal() is now
        // the driver's own basalDeliveryState (persisted podState — E-1), nil once pumpManager is nil.
        let runningTemp: DoseEntry? = {
            if case .tempBasal(let dose) = manager.status.basalDeliveryState { return dose }
            return nil
        }()
        loopManager.pumpManager = nil  // no dosing from here

        // NO PROGRAM CROSSES THE BOUNDARY — the automatic
        // controller is standing down, so its automatic temp goes with it and the pod reverts
        // to the user's own schedule. This mirrors stock's own off-cycle idiom exactly:
        // LoopDataManager.cancelActiveTempBasal enacts a bare `.cancel` outside loop() for
        // automaticDosingDisabled / unreliableCGMData / maximumBasalRateChanged. Stock never
        // SETS a rate off-cycle (that needs a fresh prediction from fresh CGM data) but it
        // always allows CANCELLING, because cancelling can only move toward less intervention.
        // So the phone does NOT need an off-cycle dosing trigger here; its next reading, ≤5 min
        // away, sets the new rate, and until then the pod runs the user's baseline.
        //
        // The CANCEL IS THE PHONE'S JOB — we do not send it: the phone's reclaim round-trip
        // cancels it (R33).
        //
        // The phone is by definition talking to the pod at this moment, and its reclaim
        // round-trip lands within seconds, so it cancels instead (see
        // PodLoanPhoneController.finishPendingHandbackAudit). The pod keeps delivering OUR last
        // temp in the meantime, which is the better failure mode anyway: continuous therapy
        // across the boundary rather than a gap. The principle is unchanged — no automatic
        // program outlives the controller that set it — only the device that enforces it moved
        // to the one that can.
        //
        // The book is the pump manager's: the running temp stays a mutable row until the phone
        // cancels it on reclaim, and a failed offer that resumes this session resumes with the
        // truth — the pod IS still running it.
        if runningTemp != nil {
            SportLog.event("loan", String(format: "hand-back: our temp (%.2f U/hr until %@) stays live until the phone cancels it on reclaim (R33, phone-enforced)",
                                          runningTemp?.unitsPerHour ?? 0,
                                          runningTemp.map { ISO8601DateFormatter().string(from: $0.endDate) } ?? "—"))
        }

        do {
            // Freshen the odometer (one retry on a zero delta), then offer — but ONLY over a
            // link that is already up. The old comment here claimed "when the link is down this
            // fails instantly"; that was true under the standing-connection model and is FALSE
            // under connect-on-demand, where a read DIALS: fresh-discovery scan → connect → we
            // send nothing while finalizing → the pod hangs up on the idle link (#7 at ~7 s) →
            // the read burns its full 20 s timeout → only then does the final offer go out.
            // Measured on-wrist 2026-08-23 (e172): 20.5 s added to every watch-initiated
            // hand-back, for a reading the phone discards anyway — its own reclaim round-trip
            // is the AUTHORITATIVE end-of-loan reading (reconcile[AUTHORITATIVE], and the
            // grant/settle path depends on that, not on this). Between doses the link is
            // deliberately released, so the common case is skip-and-offer-immediately;
            // a hand-back within the 12 s post-dose hold still freshens in ~0.6 s.
            let finalize: (Bool) -> Void = { freshened in
                self.queue.async {
                    self.finalOfferSent = true
                    self.sendHandbackOffer(freshened: freshened, recovered: false)
                }
            }
            if manager.isConnectionReady {
                manager.podLoanReadStatus { first in
                    let delivered = manager.podLoanInsulinDelivered
                    if first, delivered != nil, delivered == self.deliveredAtTakeover {
                        manager.podLoanReadStatus { second in finalize(second) }
                    } else {
                        finalize(first)
                    }
                }
            } else {
                SportLog.event("loan", "hand-back: freshen SKIPPED — no live pod link; the phone's reclaim read is authoritative")
                finalize(false)
            }
        }
    }

    func sendHandbackOffer(freshened: Bool, recovered: Bool) {
        guard let epoch = epoch ?? journal.activeEpoch else { return }
        var odometer: LoanOdometerSnapshot?
        if let start = deliveredAtTakeover,
           let latest = pumpManager?.podLoanInsulinDelivered ?? revokeCapturedDelivered {
            odometer = LoanOdometerSnapshot(deliveredAtStart: start, deliveredLatest: latest, freshenSucceeded: freshened,
                                            asOf: pumpManager?.podLoanInsulinDeliveredAt ?? revokeCapturedDeliveredAt)
        }
        let offerEvents = journal.unackedEvents()
        let offer = HandbackOffer(
            epoch: epoch,
            handedBackAt: self.now(),
            finalStatus: pumpManager.map { _ in currentPodStatus() },
            odometer: odometer,
            events: offerEvents,
            tombstones: journal.pendingTombstones(),
            recovered: recovered,
            released: phase != .active,   // interim while still dosing; final after finalize
            // The phone inherits the wrist's loop mode on
            // the way back, mirroring the grant's outbound inheritance. Read through the
            // NON-BLOCKING mirror: this runs on `queue`, and `closedLoopEnabled` would sync
            // onto dataAccessQueue — the deadlock direction.
            // RECOVERED offers send nil — no authority (field 2026-08-25 e221): a
            // relaunch-recovered drain reads a freshly-booted manager whose flag is a boot
            // default, not the wrist's real mode; e221's recovered offer overwrote the user's
            // captured CLOSED with open, and the phone resumed open-loop after the watch died.
            // nil already means exactly the right thing at the phone: keep the captured
            // pre-loan value.
            watchClosedLoopEnabled: recovered ? nil : loopManager.closedLoopEnabledNonBlocking,
            // R40 reunion identity: present only while a SEIZED loan is live — the phone
            // retro-acknowledges on match; an old phone ignores it (stale-drain, safe).
            seizeToken: defaults.string(forKey: DormantKeys.activeToken).flatMap(UUID.init(uuidString:)),
            // Same benign-snapshot read as the phase above: "roughly when did the wrist last
            // loop" for the phone's recency seed, not a sync point.
            lastLoopCompleted: loopManager.lastLoopCompleted)
        if offer.released == true, finalOfferSentAt == nil { finalOfferSentAt = self.now() }
        handbackResendCount += 1
        // Self-documenting limbo (a wait can run to 97 silent minutes of 15s resends):
        // log the attempt count each minute so the wait is visible in the log.
        if handbackResendCount == 1 || handbackResendCount % 4 == 0 {
            SportLog.event("loan", "hand-back offer attempt \(handbackResendCount) — waiting for iPhone ack")
        }
        // Say WHY the wait is happening. End tapped with the phone unreachable otherwise shows
        // nothing but "ending…" for minutes, even though `reachable false` is on every send
        // line in the log the whole time: the
        // signal exists, it was just never surfaced. Log transitions here; the glance note is
        // driven off DebugSnapshot.phoneReachable. NOTE we do NOT abort on unreachable —
        // reachability flaps, and the queued offer lands the moment the phone returns (acking
        // within tens of milliseconds once reachable). Fast feedback, slow abort.
        let live = !recovered && phase != .revoked && phase != .recoveredDrain
        let reachableNow = isPhoneReachable()
        if !reachableNow { handbackSawUnreachable = true }
        if live, !reachableNow {
            // A live hand-back needs the phone PRESENT, not reachable later: after it accepts,
            // the phone must reclaim the pod over Bluetooth. A queued offer is accepted whenever
            // the link returns — with the phone possibly nowhere near the pod, and possibly hours
            // after this loan moved on (field 2026-09-18: eight queued offers landed 65 min after
            // the hand-back had timed out; the phone reclaimed a live loan and both devices dosed
            // for three hours). So a live offer is never queued: fail now, keep the loan, and let
            // the user try again near the phone. Ruled 2026-09-19. Drains from a dead loan still
            // queue — there is no live loan to conflict with and the records must land.
            handbackTimedOut(unreachable: true)
            return
        }
        if lastHandbackReachable != reachableNow {
            SportLog.event("loan", reachableNow
                ? "hand-back: iPhone reachable — offer should ack shortly"
                : "drain: iPhone UNREACHABLE — offer queued, will land when it returns")
            lastHandbackReachable = reachableNow
        }
        sendMessage(.handbackOffer(offer), urgentOnly: live)

        // Resend until ack (rows 9/10): same event IDs every retry by construction.
        resendWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Give up after the budget and resume Sport Mode on the watch (we stayed the
            // pod's sole owner throughout). Only the LIVE hand-back (deadline set) — a
            // recovered/revoke drain has no local loan to resume, so it keeps resending.
            if let deadline = self.handbackDeadline, self.now() >= deadline,
               self.phase == .handingBack || (self.phase == .active && self.handbackRequested) {
                self.handbackTimedOut()
                return
            }
            // A DRAIN MUST ALSO TERMINATE (field 2026-08-20 epoch 154). The give-up above is
            // scoped to a LIVE hand-back, on the reasoning that a recovered/revoke drain "has no
            // local loan to resume, so it keeps resending". That is true of the loan but not of
            // the loop: the watch resent every 15 s for six minutes, across three relaunches,
            // and every resend was DELIVERED and ACKed — the phone logged `write DONE -> ACK
            // cursor 6` six times. The acks simply never arrived back (last RX handbackAck was
            // epoch 153); WCSession was one-way for that session. So the watch waited forever for
            // an answer that had already been sent, and the wrist looked wedged.
            //
            // Nothing is lost by stopping: a drain's whole purpose is to deliver records the
            // PHONE has by then already committed, and the phone reclaimed the pod long before
            // (it was `state=owner` for every one of those offers). Bound it, say so, and idle.
            let drain = self.phase == .revoked || self.phase == .recoveredDrain
            if drain, self.handbackResendCount >= Self.maxDrainResends {
                let wedge = HandbackWedge.classify(resendCount: self.handbackResendCount,
                                                   sawUnreachable: self.handbackSawUnreachable,
                                                   reachableNow: self.isPhoneReachable(),
                                                   sendsErrored: self.handbackSawUrgentSendError)
                SportLog.event("loan", "drain GIVING UP after \(self.handbackResendCount) unacked offer(s) [\(wedge)] — the phone owns the pod and has already committed these records; closing to idle")
                self.resendWorkItem?.cancel()
                self.teardownPump()
                self.journal.end()
                self.phase = .idle
                self.epoch = nil
                self.deliveredAtTakeover = nil
                self.handbackDeadline = nil
                self.handbackStartedAt = nil
                self.finalOfferSentAt = nil
                self.handbackRequested = false
                self.finalOfferSent = false
                HandbackStuckAlert.disarm()
                self.onLoanActiveChanged?(false)
                SportLog.event("loan", "CLOSED — drain abandoned, pod already the phone's")
                return
            }
            if self.phase == .handingBack || drain
                || (self.phase == .active && self.handbackRequested) {   // interim drain
                self.sendHandbackOffer(freshened: freshened, recovered: recovered)
            }
        }
        resendWorkItem = work
        schedule(after: 15, label: "handback-resend", execute: work)
    }

    func handleAck(_ ack: HandbackAck) {
        // This was a silent `return`. An ack for the wrong epoch is a real and expected event
        // (a stale redelivery), but it is ALSO what a mis-paired session would look like, so it
        // must be distinguishable from "no ack arrived" in the log rather than inferred.
        guard let current = epoch ?? journal.activeEpoch, ack.epoch == current else {
            SportLog.event("loan", "ack IGNORED ev=\(ack.epoch) — ours ev=\(epoch.map(String.init) ?? "nil") journal ev=\(journal.activeEpoch.map(String.init) ?? "nil"); stale redelivery or epoch mismatch")
            return
        }
        journal.applyAck(committedCursor: ack.committedCursor)
        guard journal.unackedEvents().isEmpty else { return }

        // The drain completed while STILL DOSING — now stop the loop's pod,
        // close records, and send the final (released) offer. The close below runs
        // on that final offer's ack.
        if phase == .active && handbackRequested {
            finalizeHandback()
            return
        }
        guard phase == .handingBack || phase == .revoked || phase == .recoveredDrain else { return }
        // During finalize's pod-ops window (phase flipped, journal
        // empty, final offer NOT yet sent) a duplicate interim ack must not close
        // the loan — the phone would never receive released=true and strand .loaned.
        if phase == .handingBack && !finalOfferSent { return }

        // Fully drained: release the pod ONLY now (kept from v1).
        resendWorkItem?.cancel()
        // Splits "Reclaiming…" into its two candidate components: how long the watch waited
        // for PERMISSION to release (the phone's ack), versus how long the release itself took.
        // The ack only rides WCSession's immediate channel while the watch is reachable, so a
        // wrist dropped after End pushes it into the queued path.
        let ackWait = finalOfferSentAt.map { self.now().timeIntervalSince($0) }
        SportLog.event("loan", String(format: "ack RECEIVED %@ after the final offer — releasing the pod now",
                                      ackWait.map { String(format: "+%.1fs", $0) } ?? "(no offer stamp)"))
        let releaseBegan = self.now()
        teardownPump()
        SportLog.event("loan", String(format: "pod BLE teardown returned in %.2fs — the phone's standing connect can land from here",
                                      self.now().timeIntervalSince(releaseBegan)))
        finalOfferSentAt = nil
        journal.end()
        phase = .idle
        epoch = nil
        deliveredAtTakeover = nil
        handbackDeadline = nil
        handbackStartedAt = nil
        HandbackStuckAlert.disarm()   // Hand-back completed cleanly
        onLoanActiveChanged?(false)
        defaults.removeObject(forKey: DormantKeys.activeToken)   // R40: seized loan (if any) is over
        reunionPromptActive = false   // hygiene: no prompt can outlive its loan
        SportLog.event("loan", "CLOSED — records drained, pod released, cursor \(ack.committedCursor)")
    }


    // MARK: - Revoke (§3.2)

    func handleRevoke(_ revoke: Revoke) {
        // SPLIT-BRAIN GUARD. Record that the phone asked for the pod back BEFORE the epoch
        // match, and log it rather than returning in silence.
        //
        // The hole it closes: the watch's request patience is 25 s (:304) but a grant's lease is
        // 5 MINUTES (PodLoanPhoneController :603). A grant delivered on the queued path can land
        // after the watch has given up and dropped to .idle with `epoch` still nil. A revoke
        // arriving in between would match nothing and vanish; the late grant then arrives
        // un-expired into .idle — an accepting phase (:383) — and the watch takes the pod. The
        // phone meanwhile ignores the resulting takeoverComplete (it requires .grantOffered,
        // PodLoanPhoneController :662), times out, and forceReclaimToOwner sets state = .owner
        // AND setAutomaticDosingPaused(false). Both sides then believe they own the pod.
        //
        // The pod is single-central so they cannot drive it at the same instant — but both
        // drivers dial on demand and drop the link seconds after each command, so they would
        // ALTERNATE, each dosing off its own books with no sight of the other's insulin.
        //
        // Remembering the epoch is enough: the phone increments on every grant, so a legitimate
        // later grant is > this and still passes.
        if revoke.epoch > (lastRevokedEpoch ?? Int.min) {
            lastRevokedEpoch = revoke.epoch
        }
        guard let current = epoch ?? journal.activeEpoch, revoke.epoch == current else {
            SportLog.event("loan", "revoke ev=\(revoke.epoch) matched no live session (epoch \(epoch.map(String.init) ?? "nil"), phase \(phase.rawValue)) — RECORDED; any grant at or below ev=\(revoke.epoch) will now be refused")
            // Refusing in silence read as "no reply from watch" on the phone (field
            // 2026-08-31 21:24: two stale revokes RECORDED here while the phone's ladder
            // concluded the watch was gone and force-stole a live loan's pod). Say what we
            // hold instead; the phone re-aims its reclaim at the real epoch.
            if phase == .active, (epoch ?? Int.min) > revoke.epoch {
                sendHoldsPodStatusReport(reason: "stale revoke e\(revoke.epoch) refused")
            }
            return
        }
        guard phase != .idle else { return }
        // Stop dosing, zero post-revoke pod commands, drain what we have.
        handbackRequested = false   // a phone-initiated revoke supersedes a pending drain
        handbackDeadline = nil
        handbackStartedAt = nil
        HandbackStuckAlert.disarm()   // The phone took over — no stuck alert
        // Capture the odometer BEFORE the teardown nils the pump. The revoke path tears down
        // first ON PURPOSE (it frees the pod's BLE immediately for the phone that is actively
        // reclaiming), but the offer built below used to ask the now-nil pumpManager for
        // podLoanInsulinDelivered and shipped odometer: nil — so revoke hand-backs skipped the
        // AUTHORITATIVE reconcile entirely (e181, 2026-08-23: the one loan that day with no
        // reconcile line). The records still ride the drain; this restores the CROSS-CHECK.
        revokeCapturedDelivered = pumpManager?.podLoanInsulinDelivered
        revokeCapturedDeliveredAt = pumpManager?.podLoanInsulinDeliveredAt
        loopManager.pumpManager = nil
        teardownPump()
        phase = .revoked
        onLoanActiveChanged?(false)
        SportLog.event("loan", "REVOKED — phone reclaimed the pod, draining records")
        sendHandbackOffer(freshened: false, recovered: true)
    }

    /// Drains a relaunch-recovered journal once the transport is available.
    func drainRecoveredIfNeeded() {
        queue.async {
            if let epoch = self.pendingInterruptedTakeoverEpoch {
                self.pendingInterruptedTakeoverEpoch = nil
                SportLog.event("loan", "START INTERRUPTED — takeover was in flight at relaunch; failing it to the phone, epoch \(epoch)")
                self.sendMessage(.takeoverFailed(TakeoverFailed(epoch: epoch, reason: "watch relaunched during takeover")))
            }
            guard self.phase == .recoveredDrain else { return }
            self.sendHandbackOffer(freshened: false, recovered: true)
        }
    }


    // MARK: - Status (§2.8)

    func handleStatusQuery(_ query: StatusQuery) {
        guard let current = epoch, query.epoch == current else {
            // ANSWER, don't go quiet. Silence here was the whole bug — the one case the
            // phone most needs to hear about (its hand-over never arrived, so it is sitting there
            // having already let go of the pod) was the one case this returned without a word.
            //
            // Two guards on saying "I don't have it", because a wrong "no" makes the phone snatch
            // the pod back mid-takeover:
            //   phase != .active   — never claim ignorance while actually holding the pod.
            //   epoch < query.epoch — we are BEHIND the phone, i.e. this grant genuinely never
            //                         landed. A query for an epoch older than ours is a stale
            //                         message and gets the silence it deserves.
            if phase != .active, (epoch ?? Int.min) < query.epoch {
                SportLog.event("loan", "status query for epoch \(query.epoch) — we have \(epoch.map(String.init) ?? "none") and hold no pod: the grant never reached us (#108)")
                sendMessage(.statusReport(StatusReport(
                    epoch: query.epoch,
                    mode: currentMode(),
                    lastDirectGlucoseAge: nil,
                    lastEventSeq: 0,
                    podFault: nil,
                    holdsPod: false,
                    knowsGrant: false)))
            } else if phase == .active, (epoch ?? Int.min) > query.epoch {
                // The third case was the wedge (field 2026-08-31 21:21:31): the phone probing
                // for a GHOST grant while we run a NEWER loan got the "stale message" silence —
                // and silence left it parked on "Handing over…" until a manual force. Answer
                // with the loan we actually hold; the phone's mirror abandons the ghost on it.
                sendHoldsPodStatusReport(reason: "status query for stale e\(query.epoch)")
            }
            return
        }
        let report = StatusReport(
            epoch: current,
            mode: currentMode(),
            lastDirectGlucoseAge: loopManager.latestGlucoseAge,  // sovereignty signal
            lastEventSeq: journal.lastEventSeq,
            podFault: pumpManager?.podLoanFaultDescription,
            holdsPod: phase == .active,
            knowsGrant: true)
        sendMessage(.statusReport(report))
    }

    func currentMode() -> LoanDosingMode {
        // closedPhoneFed/cgmViewer/pausedStale arrive with the picker integration.
        return .closedDirect
    }

    func currentPodStatus() -> LoanPodStatus {
        LoanPodStatus(
            timestamp: self.now(),
            deliveredUnits: pumpManager?.podLoanInsulinDelivered,
            reservoirLevel: nil,
            isSuspended: false,
            faultCode: pumpManager?.podLoanFaultDescription)
    }

}
