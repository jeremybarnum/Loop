//
//  PodLoanPhoneController+Grant.swift
//  Loop
//
//  Part of PodLoanPhoneController (see PodLoanPhoneController.swift). Split by concern; stored properties live in the core class.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore
import UserNotifications
import os.log

extension PodLoanPhoneController {

    // MARK: - Grant (§2.2)

    func handleRequest(_ request: LoanRequest) {
        // A request that AGED in the queued channel is a ghost: its watch timed out in ≤25 s
        // and moved on — possibly all the way to a seize. Granting it releases the pod at a
        // watch that isn't asking. Field 2026-08-30: two requests queued against a powered-
        // off phone detonated at power-on — e253 granted to the five-minute-old first copy,
        // the second denied against .grantOffered, the recovery force-reclaiming the fresh
        // grant. The dedupe below cannot catch this (two real taps = two requestIDs); age
        // can. Checked FIRST so a ghost also never updates the dedupe memory or the
        // capability record. Older watches send no stamp and pass untouched.
        if let sentAt = request.sentAt {
            let age = deps.now().timeIntervalSince(sentAt)
            if age > Self.requestTTL {
                os_log("Loan request STALE — sent %.0fs ago (TTL %.0fs); ignored as a queued-channel ghost",
                       log: log, type: .default, age, Self.requestTTL)
                PhoneLog.event("loan", String(format: "request STALE — sent %.0fs ago (TTL %.0fs) — ignored, no grant", age, Self.requestTTL))
                return
            }
        }
        // Suppress a TRANSPORT redelivery of the same request. This is not
        // the same as a user tapping Start twice — a second tap arrives seconds later against
        // settled state, whereas a redelivered copy arrives milliseconds later while the FIRST
        // is still in flight. Seen in the field: copy 1 granted the epoch and released
        // the pod; copy 2 landed in .grantOffered, took the stale-state recovery below,
        // force-reclaimed the pod it had just released (`released=false`) and re-granted —
        // which the reclaim-settle guard then denied. The watch was left holding a grant for a
        // pod still on the phone, so every ladder read returned `no-peripheral` and the loan
        // died. Genuine retries carry a fresh ID and are unaffected; a watch build that sends
        // no ID behaves exactly as before.
        if let id = request.requestID, id == lastRequestID,
           let seenAt = lastRequestAt,
           deps.now().timeIntervalSince(seenAt) < Self.requestDedupeWindow {
            os_log("Duplicate loan request %{public}@ ignored (transport redelivery, %.1fs after the first)",
                   log: log, type: .default, id, deps.now().timeIntervalSince(seenAt))
            return
        }
        if let id = request.requestID {
            lastRequestID = id
            lastRequestAt = deps.now()
        }
        // R40: remember whether this watch speaks seize — the dormant refresher gates on it.
        if let seize = request.supportsSeize {
            UserDefaults.standard.set(seize, forKey: Keys.watchSupportsSeize)
        }
        guard request.supportedVersions.contains(LoanProtocol.version) else {
            sendMessage(.nack(ProtocolNack(seenVersion: request.supportedVersions.max())))
            return
        }
        guard !grantInFlight else {
            deny("A grant is already in progress.")
            return
        }
        guard state == .owner else {
            // A NEW request means the watch is NOT in a loan — so a lingering
            // non-owner state is stale. Recover instead of refusing forever (bug E).
            switch state {
            case .grantOffered, .reconciling, .reclaimPending:
                // No live watch dosing in these states → safe to reset and grant now.
                os_log("Loan request while %{public}@ — recovering stale state and granting", log: log, type: .default, state.rawValue)
                forceReclaimToOwner(reason: "new request while \(state.rawValue)")
                beginGrant()
            case .loaned:
                // Possibly a live loan → don't steal the pod silently. Revoke (single-
                // writer preserved); the reclaim escalation forces to owner if the watch
                // is gone. The user retries in a moment.
                os_log("Loan request while LOANED — revoking the previous loan first", log: log, type: .default)
                reclaimNow()
                deny("Reclaiming the previous loan from the watch — try Start again in a few seconds.")
            case .owner:
                break
            }
            return
        }
        beginGrant()
    }

    /// Refuse the request and tell the WATCH why, so it shows the reason instead of hanging
    /// on "requesting…". No phone notice: the user is looking at the wrist they just tapped,
    /// and the reason is already on it — the phone copy was pure duplication.
    func deny(_ reason: String) {
        os_log("Loan denied: %{public}@", log: log, type: .default, reason)
        sendMessage(.denied(LoanDenied(reason: reason)))
    }

    func beginGrant() {
        // NO isWatchAppInstalled GATE HERE. One was added 2026-08-19 22:0x and REMOVED the same
        // hour: it refused three consecutive Start taps while the watch's request was arriving on the
        // URGENT path in the same second — i.e. it blocked a grant over a link that was demonstrably
        // live, because the flag it trusted had flipped false 9 seconds earlier and was simply wrong.
        // The flag flaps on a ~70-second timescale and lags reality; it is not a safe precondition.
        //
        // It also failed silently: the denial is sent to the WATCH, over the direction that is broken
        // in the very case the gate fires, so the phone showed nothing at all and the watch ground out
        // its full 25-second timeout. A guard that can neither be trusted nor explain itself is worse
        // than the failure it guards against, which is recoverable by force reclaim.
        //
        // If this is reinstated, key it on EVIDENCE, not cache: whether the request arrived on the
        // live (didReceiveMessage) path rather than the queued one, and deliver the refusal in the
        // REPLY to that request so it cannot be lost to the same broken direction.
        guard let pump = deps.pumpManager() else {
            deny("No pump is set up on the phone.")
            return
        }
        guard let lendable = pump as? PumpConnectionLendable else {
            deny("This pump can't be loaned to the watch (\(type(of: pump))).")
            return
        }
        // PHONE MIRROR exit: a fresh request while yielding means the watch is alive and
        // ASKING — a watch that is asking is not looping, so the inferred loan is over.
        // Re-arm the pod bid we released at yield, or the still-returning-pod guard below
        // would deny-and-retry against a pod nobody is bringing back; the guard then does
        // its normal job while the link re-establishes, and the next retry grants.
        if yieldingToInferredLoan {
            clearInferredLoanYield(reason: "new loan request — a granted loan supersedes the inferred one")
            reclaimPodConnection()
        }

        // Don't hand a still-returning pod to the watch. After a reclaim the phone
        // enters .owner but the pod BLE isn't truly back for up to ~2 min — reclaimConnection()
        // only re-arms the bid. Granting inside that settle window releases a half-reconnected
        // pod, and the watch's takeover then races the phone's in-flight link → takeover fails
        // (the "rapid hand-back → re-takeover" bug). Deny-and-retry until the pod is genuinely
        // reachable (isConnectionReady) or the settle ceiling clears — conservative: it never
        // grants a not-ready pod, and the user's next Start succeeds once it's home.
        // Readiness = a completed pod ROUND-TRIP since the reclaim began,
        // NOT the peripheral state. isConnectionReady() flips true within seconds of hand-back
        // (baseband connect) while the pod's actual return work hasn't happened; grants issued
        // on that signal released a half-returned pod and the watch takeover flapped against it
        // for ~90 s (every recorded failure was inside this window — 9-85 s gaps; every success
        // outside). The chase in beginReclaimSettleWindow makes verification prompt, so this
        // deny window is short in practice when the phone is awake.
        if let started = reclaimStartedAt,
           deps.now().timeIntervalSince(started) < Self.reclaimSettleTimeout,
           reclaimVerifiedAt == nil {
            os_log("Grant deferred: pod still returning from the last reclaim (%.0fs into settle, round-trip not yet verified) — deny-and-retry",
                   log: log, type: .default, deps.now().timeIntervalSince(started))
            deny("The pod is still returning from the last session. Try Start again in a few seconds.")
            attemptReclaimVerificationNow(started: started)   // the tap accelerates the return check
            return
        }

        // Deny-on-missing: the grant is refused, never defaulted.
        let settings = deps.settings()

        // THE WATCH DOSES BY TEMP BASAL ONLY. If the phone is running automaticBolus, the wrist
        // refuses EVERY cycle — it holds the pod and never doses at all, surfacing a raw Swift
        // error on the watch face. Field-confirmed on the pure line's first live run with a real
        // T1D user: 5 cycles, 5 refusals, zero enacts, for someone whose therapy is a continuous
        // stream of small automatic boluses. It also explains a high eventual with no temping at
        // the same time — the loop never produced a recommendation, so there was nothing to enact.
        //
        // So the loan runs on temps, and the strategy is overridden HERE, in the snapshot the
        // grant carries — deliberately NOT by changing the phone's stored setting. Flipping the
        // real setting would need a restore at hand-back, and a restore that never runs (relaunch
        // mid-loan, force reclaim, dead watch, app killed) would leave the user silently on
        // tempBasalOnly forever: a lasting therapy change from a bookkeeping miss. Overriding the
        // snapshot has nothing to undo, so there is no restore that can fail. The phone is
        // automaticBolus again the instant it has the pod back, because it never stopped being.
        var loanSettings = settings
        let strategyOverridden = settings.automaticDosingStrategy != .tempBasalOnly
        loanSettings.automaticDosingStrategy = .tempBasalOnly
        if strategyOverridden {
            PhoneLog.event("loan", "dosing strategy overridden for the loan — phone \(settings.automaticDosingStrategy) → wrist tempBasalOnly; the phone's own setting is untouched")
        }
        guard settings.basalRateSchedule != nil,
              settings.insulinSensitivitySchedule != nil,
              settings.carbRatioSchedule != nil,
              settings.glucoseTargetRangeSchedule != nil,
              settings.maximumBasalRatePerHour != nil,
              settings.maximumBolus != nil else {
            deny("Therapy settings are incomplete; the watch can't dose without them.")
            return
        }

        // STOCK'S OWN AUTOMATION-OFF BEHAVIOUR, AWAITED: pause dosing, cancel the running temp
        // and wait for the pod to acknowledge it, THEN release the link and grant. No program
        // crosses the boundary (R2), the phone's store holds a real, finished temp record written
        // by the pump manager, and the pod runs the schedule for the seconds until the watch's
        // first program. Before this the watch cancelled the temp seconds after takeover while
        // the phone truncated its own record at the handover — the slice between was booked by
        // neither side. A pod that does not answer the cancel cannot be lent: deny instead.
        grantInFlight = true
        deps.setAutomaticDosingPaused(true)
        deps.cancelTempBasalForGrant { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                self.grantInFlight = false
                if let error = error {
                    self.deps.setAutomaticDosingPaused(false)
                    self.deny("The pod didn't take the temp cancel (\(error.localizedDescription)). The phone kept the pod.")
                    return
                }
                self.continueGrant(settings: settings, loanSettings: loanSettings, pump: pump, lendable: lendable)
            }
        }
    }

    /// The grant after the awaited temp cancel: capture the handover, release the link, and
    /// assemble and send the grant.
    private func continueGrant(settings: LoopSettings, loanSettings: LoopSettings,
                               pump: PumpManager, lendable: PumpConnectionLendable) {
        // Fix 1 (field-confirmed boundaryDup=YES): DO NOT emit a boundaryRecord.
        // Since 2026-09-16 the phone cancels its running temp BEFORE the release, so the history
        // fetched below holds a real, finished temp record and no live temp at all. A separate
        // same-start, same-rate boundaryRecord is therefore a duplicate of that temp, and seeding
        // both double-counts the [start→handover] slice (the ~0.3 U IOB bump at takeover). The
        // watch's stock reconciled() truncates the seeded open temp when it enacts its first
        // command. (Narrow caveat: if a just-set temp has not yet reached the dose store, the seed
        // could miss it for a few seconds — acceptably rarer than the double-seed it replaces.)
        // The .boundaryTruncation Kind + LoanReconciler's handling of it are LEFT in place as
        // defensive/back-compat tolerance ONLY: the watch hand-back journal never mints that kind,
        // so those arms are now vestigial in production (an older phone may still send one).
        let handedOverAt = deps.now()

        // §5.3.3: capture the odometer NOW (the phone was polling until this moment)
        // so the post-reclaim re-audit has a loan-start baseline even if the watch
        // dies before ever sending one.
        if let delivered = lendable.lentDeviceInsulinDelivered {
            UserDefaults.standard.set(delivered, forKey: Keys.deliveredAtGrant)
            // Seed the audit base from the phone's own last reading. takeoverComplete
            // re-anchors it seconds later with the watch's fresher post-takeover pair.
            auditBase = AuditBase(units: delivered, asOf: handedOverAt)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.deliveredAtGrant)
            auditBase = nil
        }
        checkpointsThisLoan = 0
        worstWindowThisLoan = 0
        // The LAST loan's takeover odometer must not leak into this one. If a force-reclaim
        // fires before this loan's takeoverComplete arrives, the audit's baseline fallback is the
        // fresh grant capture above — a stale takeover value would put the whole previous loan's
        // delivery inside the "unexplained" window and book a wildly wrong bolus.
        UserDefaults.standard.removeObject(forKey: Keys.deliveredAtTakeover)
        UserDefaults.standard.set(false, forKey: Keys.watchAuditRan)
        UserDefaults.standard.removeObject(forKey: Keys.expectedUnits)

        // Dosing is already paused and the temp already cancelled (see handleRequest): the pod
        // is on the schedule. Now stop bidding for its link.
        // If the phone doesn't actually drop the pod BLE here, the watch's
        // takeover reads "pod unreachable" (a pod is a single-central peripheral). Relay the
        // release state to the watch's iCloud log — before, and a +3s confirm (release is async).
        let releaseEpoch = epoch + 1
        handbackDiag(releaseEpoch, "GRANT — releasing pod BLE (wasReleased=\(lendable.isConnectionReleased))")
        lendable.releaseConnection()
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak lendable] in
            guard let self = self, let lendable = lendable else { return }
            // `released` is a FLAG — set synchronously by releaseConnection, it says only that we
            // asked. `linkUp` is `isConnectionReady`, which on OmniPumpManager is literally
            // `podLoanConnectionStateDescription == "connected"` — the peripheral's own state.
            //
            // This is the line the whole takeover investigation has been missing. 4 of 6 takeovers
            // failed on build 234, every connect returning connectionLimitReached while the WATCH's
            // central held nothing — so something else held the slot, and the only candidate we
            // could not test was "the phone never actually let go". released=true says nothing
            // about that. linkUp=true three seconds after a release says it outright.
            self.handbackDiag(releaseEpoch, "GRANT +3s — pod BLE released=\(lendable.isConnectionReleased) linkUp=\(lendable.isConnectionReady)")
            if lendable.isConnectionReady {
                self.handbackDiag(releaseEpoch, "GRANT +3s — ** STILL CONNECTED after release — the watch's takeover will be refused (single-central pod) **")
            }
            PhoneLog.flush()   // the analysis wants this file current at exactly this moment
        }

        epoch += 1
        state = .grantOffered
        committedCursor = 0
        committedIDs = []
        persistCommittedIDs()
        // A new grant supersedes any deferred force-reclaim — running it later would
        // stomp this fresh loan straight back to .owner — and any coalesced old-epoch offers:
        // the watch resends whatever went unacked, and those take the stale-offer path.
        pendingForceReclaimReason = nil
        coalescedOffers.removeAll()
        staged = [:]
        stagedTombstones = []
        persistStaged()
        loanStartedAt = handedOverAt
        UserDefaults.standard.set(handedOverAt, forKey: Keys.loanStartedAt)

        let grantEpoch = epoch
        // R40: assembly extracted so the dormant refresher issues EXACTLY what a live grant
        // would — a seized loan must dose on the same materials a granted loan gets.
        assembleGrant(epoch: grantEpoch, referenceDate: handedOverAt,
                      expiresAt: handedOverAt.addingTimeInterval(.minutes(5)),
                      pumpRaw: pump.rawValue, loanSettingsRaw: loanSettings.rawValue,
                      settings: settings) { [weak self] grant in
            guard let self = self else { return }
            guard self.state == .grantOffered, self.epoch == grantEpoch else { return }
            guard let grant = grant else {
                self.abortGrant(reason: "snapshot encoding failed")
                return
            }
            self.sendMessage(.grant(grant))
            self.armT1(for: grantEpoch)
        }
    }

    /// R40: one grant assembly for BOTH the live path and the dormant refresher — the
    /// fetch chain (16 h doses, carbs, 3 h glucose, prediction snapshot) plus the
    /// LoanGrant construction, exactly as the live grant has always built it — including
    /// this line's active-override carry and therapy-settings supplement. Duplicating it
    /// would let the two grants drift. Completion runs on `queue`; nil = snapshot
    /// encoding failed. `expiresAt` is the live path's 5-minute lease; the dormant path
    /// passes `referenceDate` (a dormant grant has no lease — R40(d) staleness is
    /// consent-based, shown in the seize confirm, never enforced).
    private func assembleGrant(epoch grantEpoch: Int, referenceDate: Date, expiresAt: Date,
                               pumpRaw: [String: Any], loanSettingsRaw: [String: Any],
                               settings: LoopSettings,
                               completion: @escaping (LoanGrant?) -> Void) {
        let historyStart = referenceDate.addingTimeInterval(-.hours(16))
        // Fetch insulin AND carb history before building the grant. Nested so both
        // are in hand at construction; the same 16h window that seeds IOB now seeds COB.
        // 3 h of glucose (the Integral RC look-back) seeds momentum + RC; the 16 h window seeds
        // IOB and COB. Nested so all three are in hand at construction.
        let glucoseStart = referenceDate.addingTimeInterval(-.hours(3))
        deps.doseHistory(historyStart) { [weak self] history in
            guard let self = self else { return }
            self.deps.carbHistory(historyStart) { [weak self] carbs in
                guard let self = self else { return }
                self.deps.glucoseHistory(glucoseStart) { [weak self] glucose in
                    guard let self = self else { return }
                    // INSTRUMENTATION ONLY: capture the phone's last-computed prediction
                    // decomposition (cached read, no recompute) as a fourth nested fetch, so it
                    // rides in the grant. Default nil closure ⇒ this is a no-op for tests / old builds.
                    self.deps.predictionSnapshot { [weak self] snapshot in
                    guard let self = self else { return }
                    self.queue.async {
                        guard let stateData = try? PropertyListSerialization.data(fromPropertyList: pumpRaw, format: .binary, options: 0),
                              let settingsData = try? PropertyListSerialization.data(fromPropertyList: loanSettingsRaw, format: .binary, options: 0) else {
                            completion(nil)
                            return
                        }
                        // The active override is NOT part of LoopSettings, so it cannot ride in
                        // therapySettingsRaw and is encoded alongside it — same plist encoding the
                        // hand-back's .overrideChange records use, so both directions agree. An
                        // already-finished override is dropped rather than sent (the same filter the
                        // phone applies before putting one in a WatchContext): seeding a dead
                        // override would show a stale preset on the glance for the whole loan.
                        // Encoding failure is NOT fatal here, unlike the settings blob above — a
                        // loan that dosed unscaled is wrong, but a loan refused outright mid-exercise
                        // is worse, and the log line below says which happened.
                        let activeOverride = self.deps.scheduleOverride().flatMap {
                            $0.hasFinished() ? nil : $0
                        }
                        let overrideData: Data? = activeOverride.flatMap { o in
                            try? PropertyListSerialization.data(fromPropertyList: o.rawValue, format: .binary, options: 0)
                        }
                        if let o = activeOverride {
                            if overrideData == nil {
                                os_log("[override] grant: FAILED to encode active override %{public}@ — the wrist will dose UNSCALED",
                                       log: self.log, type: .error, Self.overrideNameForLog(o))
                            } else {
                                os_log("[override] grant: carrying %{public}@ · insulin needs %.0f%% · sync %{public}@",
                                       log: self.log, type: .default, Self.overrideNameForLog(o),
                                       o.settings.effectiveInsulinNeedsScaleFactor * 100,
                                       o.syncIdentifier.uuidString)
                            }
                        }
                        // What LoopSettings.rawValue drops on this branch, carried alongside it.
                        // The schedules are the ONLY dosing limits the wrist has, and the insulin
                        // model decides its forecast — encoding failure here is therefore not a
                        // detail: the watch refuses the loan on missing schedules (loud), but a
                        // missing insulin model would silently downgrade it to rapid-acting-adult.
                        // So the model is logged when it is carried, and its absence is logged too.
                        var supplement: [String: Any] = [:]
                        supplement["basalRateSchedule"] = settings.basalRateSchedule?.rawValue
                        supplement["insulinSensitivitySchedule"] = settings.insulinSensitivitySchedule?.rawValue
                        supplement["carbRatioSchedule"] = settings.carbRatioSchedule?.rawValue
                        supplement["defaultRapidActingModel"] = settings.defaultRapidActingModel?.rawValue
                        let supplementData = supplement.isEmpty ? nil
                            : try? PropertyListSerialization.data(fromPropertyList: supplement, format: .binary, options: 0)
                        os_log("[grant] settings supplement: basal=%{public}@ isf=%{public}@ cr=%{public}@ model=%{public}@ bytes=%{public}d",
                               log: self.log, type: .default,
                               settings.basalRateSchedule == nil ? "MISSING" : "ok",
                               settings.insulinSensitivitySchedule == nil ? "MISSING" : "ok",
                               settings.carbRatioSchedule == nil ? "MISSING" : "ok",
                               settings.defaultRapidActingModel.map { String(describing: $0) } ?? "MISSING (wrist will assume rapid-acting adult)",
                               supplementData?.count ?? 0)
                        // To the FILE too, and with the seed counts beside it: the grant's size is
                        // dominated by the history it carries, so "how big is the supplement" is
                        // only meaningful next to "how big was it already".
                        self.handbackDiag(grantEpoch, "[grant] supplement \(supplementData?.count ?? 0)B · seeds: \(history.count) dose, \(carbs.count) carb, \(glucose.count) glucose · podState \(stateData.count)B · settings \(settingsData.count)B")
                        let grant = LoanGrant(
                            epoch: grantEpoch,
                            expiresAt: expiresAt,
                            pumpManagerRawState: stateData,
                            podAddress: 0,
                            therapySettingsRaw: settingsData,
                            settingsTimeZoneID: settings.basalRateSchedule?.timeZone.identifier ?? TimeZone.current.identifier,
                            doseHistory: history.compactMap(Self.loanRecord(from:)),
                            boundaryRecord: nil,   // Fix 1: running temp already lives in doseHistory (see above)
                            supportsInterimHandback: true,   // two-phase hand-back capability gate (REAL-3)
                            supportsOverrideRecords: true,   // this phone decodes .overrideChange
                            // Same source LoopDataManager:458 reads. Without this the watch runs
                            // Standard RC while this phone may be running Integral — different
                            // predictions from identical inputs, silently (audit 2026-07-22).
                            integralRetrospectiveCorrectionEnabled: UserDefaults.standard.integralRetrospectiveCorrectionEnabled,
                            // The wrist follows the phone's
                            // loop mode instead of resetting to OPEN each loan. Snapshotted at
                            // the grant like the therapy settings, so a later phone-side toggle
                            // does not reach through to a loan already in flight.
                            phoneClosedLoopEnabled: settings.dosingEnabled,
                            carbHistory: carbs,
                            glucoseHistory: glucose,
                            predictionSnapshot: snapshot,
                            activeOverrideRaw: overrideData,
                            therapySettingsSupplementRaw: supplementData,
                            // Ring ruling 2026-08-23: the wrist's loop dot starts from the
                            // SYSTEM's recency — this phone looped minutes ago at most.
                            lastLoopCompleted: self.deps.lastLoopCompleted())
                        completion(grant)
                    }
                    }
                }
            }
        }
    }


    // MARK: - R40: the dormant-grant refresher (seize credential pipe)

    /// Periodic floor between refreshes with unchanged settings. A settings change
    /// refreshes immediately regardless. Tunable.
    private static let dormantRefreshInterval: TimeInterval = .minutes(30)

    /// A coarse fingerprint of everything therapy-relevant the grant snapshot freezes —
    /// when it changes, the dormant grant refreshes immediately (the R40(d) analysis:
    /// settings-change-then-leave is the only unique staleness exposure, so make its
    /// window as small as the pipe allows).
    private static func settingsFingerprint(_ s: LoopSettings) -> String {
        let basal = s.basalRateSchedule.map { String(describing: $0.items) } ?? "-"
        let isf = s.insulinSensitivitySchedule.map { String(describing: $0.items) } ?? "-"
        let cr = s.carbRatioSchedule.map { String(describing: $0.items) } ?? "-"
        let targets = s.glucoseTargetRangeSchedule.map { String(describing: $0.items) } ?? "-"
        return "\(basal)|\(isf)|\(cr)|\(targets)|\(String(describing: s.maximumBolus))|\(String(describing: s.maximumBasalRatePerHour))|\(s.dosingEnabled)"
    }

    /// The stable per-pod reunion identity carried in every dormant grant and echoed in a
    /// seized loan's offer. v1 approximation: persisted once and rotated only when the
    /// refresher first runs after the stored value is missing — a mismatch at reunion is
    /// never dangerous (the offer degrades to the stale-epoch records-drain), so the
    /// rotation policy can stay coarse until the seize flow's field data argues otherwise.
    func dormantSeizeToken() -> UUID {
        if let raw = UserDefaults.standard.string(forKey: Keys.dormantSeizeToken),
           let token = UUID(uuidString: raw) {
            return token
        }
        let token = UUID()
        UserDefaults.standard.set(token.uuidString, forKey: Keys.dormantSeizeToken)
        return token
    }

    /// Cheap to call from any repeating phone moment (WatchDataManager pings it on loop
    /// updates); all gating and throttling lives here. Refreshes only while this phone
    /// OWNS the pod, only to a watch that advertised supportsSeize, and only when the
    /// settings fingerprint changed or the periodic floor elapsed.
    func considerDormantRefresh() {
        queue.async { [weak self] in self?.queue_considerDormantRefresh() }
    }

    private func queue_considerDormantRefresh() {
        guard state == .owner else { return }
        guard UserDefaults.standard.bool(forKey: Keys.watchSupportsSeize) else { return }
        guard let pump = deps.pumpManager(),
              let lendable = pump as? PumpConnectionLendable,
              !lendable.isConnectionReleased else { return }
        let settings = deps.settings()
        // Same completeness rule as a live grant: deny-on-missing, never defaulted. An
        // incomplete snapshot simply skips this refresh; the last complete one stands.
        guard settings.maximumBolus != nil, settings.maximumBasalRatePerHour != nil,
              settings.basalRateSchedule != nil else { return }
        // The EPOCH rides the fingerprint (fix 4b, field 2026-08-31): every epoch advance
        // — grant, retro-ack, force — re-issues the credential immediately. Without it, a
        // stale provisional epoch produced three field symptoms in one afternoon: epoch
        // reuse on back-to-back seizes, an un-retro-ackable strand, and a seize BRICKED
        // for 12 minutes by the split-brain guard after a revoke (270 ≤ revoked 271,
        // four identical rejects until the 30-min floor refresh).
        let fingerprint = Self.settingsFingerprint(settings) + "|e\(epoch)"
        let periodicDue = lastDormantRefreshAt.map { deps.now().timeIntervalSince($0) >= Self.dormantRefreshInterval } ?? true
        guard periodicDue || fingerprint != lastDormantSettingsFingerprint else { return }

        var loanSettings = settings
        loanSettings.automaticDosingStrategy = .tempBasalOnly   // same override as a live grant
        let issuedAt = deps.now()
        let token = dormantSeizeToken()
        let provisionalEpoch = epoch + 1
        // Stamp the throttle at ENQUEUE, not completion: LoopDataUpdated arrives in bursts
        // faster than assembly finishes, and completion-stamping let five identical 25 KB
        // refreshes through one gate in a single second (field 2026-08-30) — straight into
        // the same queued channel a jam later backs up. A failed assembly re-opens the gate.
        lastDormantRefreshAt = issuedAt
        lastDormantSettingsFingerprint = fingerprint
        assembleGrant(epoch: provisionalEpoch, referenceDate: issuedAt, expiresAt: issuedAt,
                      pumpRaw: pump.rawValue, loanSettingsRaw: loanSettings.rawValue,
                      settings: settings) { [weak self] grant in
            guard let self = self else { return }
            guard let grant = grant else {
                self.lastDormantRefreshAt = nil   // assembly failed — next ping may retry
                return
            }
            guard self.state == .owner else { return }   // ownership moved mid-assembly
            self.sendMessage(.dormantGrant(DormantGrant(grant: grant, issuedAt: issuedAt, seizeToken: token)))
            PhoneLog.event("seize", "dormant grant refreshed — \(grant.doseHistory.count) dose record(s), token …\(String(token.uuidString.suffix(8))) [seize]")
        }
    }

}
