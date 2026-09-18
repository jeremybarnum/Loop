//
//  PodLoanWatchController+Grant.swift
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

    // MARK: - R40: the dormant grant (seize credential)

    /// UserDefaults keys for the stored seize credential. The grant blob (~14 KB) rides
    /// defaults deliberately: it must survive relaunches and be readable before any store
    /// wiring, exactly like the loan journal's persisted state.
    enum DormantKeys {
        static let envelope = "PodLoanWatchController.dormantGrant"
        static let issuedAt = "PodLoanWatchController.dormantGrantIssuedAt"
        static let token = "PodLoanWatchController.dormantGrantToken"
        /// R40: set the moment a seize activates; rides every hand-back offer of the seized
        /// loan so the phone can retro-acknowledge; cleared when the loan CLOSES. Persisted —
        /// a relaunch mid-seized-loan must keep sending it.
        static let activeToken = "PodLoanWatchController.activeSeizeToken"
    }


    /// True while THIS loan attempt is seize-flavored, for the [seize] grep tag on ladder
    /// and abort lines. Two sources because the fold consumes the pending token early
    /// (persisting it), which made post-fold aborts log untagged on 2026-08-30.
    var seizeMarkerActive: Bool {
        pendingSeizeToken != nil || defaults.string(forKey: DormantKeys.activeToken) != nil
    }

    /// The takeover-liveness budget a seize activation mints for itself — the same 5 minutes
    /// a live grant gets from the phone. The DORMANT credential's own expiresAt is issuedAt
    /// by contract ("meaningless dormant"); forgetting to re-stamp it here is what killed
    /// the first field seize at ladder read 1 (2026-08-30, "grant lease expired
    /// mid-takeover" 900 ms after the confirm). The lease bounds the HANDSHAKE, not the
    /// credential — R40(d) keeps credential age uncapped and disclosed, and the handshake
    /// starts at the confirm.
    static let seizeActivationLease: TimeInterval = 5 * 60

    /// R40(b): the user asked, the phone did not answer, a credential exists — OFFER the
    /// offline path (never auto-take it). Shows the age per R40(d); a deliberate confirm
    /// activates, anything else stays idle.
    func confirmSeize() {
        queue.async {
            // R40 re-entry: the offer can be presented from plain idle OR from a parked
            // drain (.recoveredDrain) — a watch reboot mid-phoneless-loan rests there.
            guard self.phase == .idle || self.phase == .recoveredDrain, let offer = self.seizeOffer,
                  let dormant = self.storedDormantGrant(), dormant.seizeToken == offer.token else {
                SportLog.event("seize", "confirm arrived with no live offer — ignored [seize]")
                return
            }
            self.seizeOffer = nil
            // Force the local epoch FRESH: the credential's epoch is provisional (the
            // phone's counter at issue) and may be stale against loans granted since. The
            // phone's retro-ack matches on the token, not the epoch, so freshness here only
            // has to satisfy the watch's own monotonicity guards — plus the parked
            // journal's epoch, which the fold (handleGrant) re-tags and must strictly
            // exceed: a fold ONTO the same epoch would let the drain's queued
            // released=final offer close the LIVE loan on the phone.
            // Fix 4a (field 2026-08-31): also strictly above the persisted HIGH-WATER mark
            // (CLOSED wipes `epoch` + the journal, so back-to-back seizes reused a spent
            // epoch) and above the last REVOKE the split-brain guard recorded (a stale
            // credential at-or-below it bricked seize outright — four identical rejects
            // until the 30-min credential floor happened to refresh).
            let newEpoch = max(dormant.grant.epoch,
                               (self.epoch ?? 0) + 1,
                               (self.journal.activeEpoch ?? 0) + 1,
                               self.defaults.integer(forKey: Keys.highWaterEpoch) + 1,
                               (self.lastRevokedEpoch ?? 0) + 1)
            // Mint the LIVE lease alongside: the dormant expiresAt is issuedAt by contract,
            // so an un-restamped credential walks into the ladder already expired and the
            // mid-takeover lease guard kills it at read 1 (the first field seize, 2026-08-30).
            let leaseUntil = self.now().addingTimeInterval(Self.seizeActivationLease)
            self.pendingSeizeToken = dormant.seizeToken
            // Belt on the timeout's cancel: the seize is the strongest possible statement
            // that no queued request should ever reach the phone (its grant would collide
            // with the loan being started RIGHT NOW).
            self.cancelStaleQueuedRequests(context: "seize confirmed")
            SportLog.event("seize", String(format: "SEIZE confirmed — activating dormant grant (issued %@, epoch %d→%d, lease +%.0fs, token …%@) [seize]",
                                           DateFormatter.localizedString(from: dormant.issuedAt, dateStyle: .short, timeStyle: .short),
                                           dormant.grant.epoch, newEpoch, Self.seizeActivationLease,
                                           String(dormant.seizeToken.uuidString.suffix(8))))
            self.phase = .requested
            self.attemptStartedAt = self.now()
            self.seizeActivationInFlight = true
            self.handleGrant(dormant.grant.withEpoch(newEpoch, leaseUntil: leaseUntil))
            self.seizeActivationInFlight = false
        }
    }

    func dismissSeize() {
        queue.async {
            guard self.seizeOffer != nil else { return }
            self.seizeOffer = nil
            self.lastIdleNote = NSLocalizedString("Offline start cancelled.", comment: "Glance note after dismissing a seize offer")
            SportLog.event("seize", "seize offer DISMISSED [seize]")
            self.notifyUI()
        }
    }


    // MARK: - R40(f) reunion: the phone's return PROMPTS during a seized loan

    /// Kill switch (absent = enabled), same insurance pattern as the OmnipodKit loan
    /// interlock: a field-new behavior ships with a way to turn it off without a build.
    static let seizeAutoHandbackDisabledKey = "PodLoanWatchController.seizeAutoHandbackDisabled"


    /// Wired from the WCSession delegate's reachability callback. R40(f), ruled
    /// 2026-08-31: the phone's return during a seized loan raises a PROMPT — never an
    /// automatic hand-back. Jeremy's rationale, overruling the auto recommendation:
    /// reachability is not presence ("phone could be lost in the house but still on
    /// WiFi"), and he is rethinking how exceptional the seize posture should be. The
    /// hand-back stays the user's deliberate act; the phone-side mirror (R40(a): first
    /// pod contact after a blackout is a status read, no enacting) is therefore the
    /// safety mechanism for however long the prompt sits unanswered.
    ///
    /// Field 2026-08-30, why SOMETHING must happen here: the returned phone dosed the
    /// pod AS OWNER (it never granted the loan, so its standing connect simply won the
    /// orphaned pod) while the watch still claimed the loan — dual controllers, split
    /// insulin books. Debounced 30 s so a flicker doesn't prompt; one prompt per
    /// reachability transition (a dismissal holds until the phone leaves and returns).
    func noteReachabilityChanged(_ reachable: Bool) {
        queue.async {
            guard reachable else { return }
            guard self.phase == .active,
                  self.defaults.string(forKey: DormantKeys.activeToken) != nil,
                  !self.handbackRequested, !self.reunionPromptActive else { return }
            guard !self.defaults.bool(forKey: Self.seizeAutoHandbackDisabledKey) else {
                SportLog.event("seize", "phone returned during a seized loan — reunion prompt DISABLED by kill switch [seize]")
                return
            }
            guard !self.seizeReunionDebounceArmed else { return }
            self.seizeReunionDebounceArmed = true
            SportLog.event("seize", "phone REACHABLE during a seized loan — reunion prompt in 30s unless it flickers away [seize]")
            self.schedule(after: 30, label: "seize-reunion-debounce") { [weak self] in
                guard let self = self else { return }
                self.seizeReunionDebounceArmed = false
                guard self.phase == .active,
                      self.defaults.string(forKey: DormantKeys.activeToken) != nil,
                      !self.handbackRequested, !self.reunionPromptActive else { return }
                guard self.isPhoneReachable() else {
                    SportLog.event("seize", "phone flickered away before the reunion debounce — seized loan continues [seize]")
                    return
                }
                self.reunionPromptActive = true
                SportLog.event("seize", "phone is back — REUNION PROMPT raised (R40(f): the hand-back stays the user's deliberate act) [seize]")
                self.notifyUI()   // raised within .active — no phase change, no repaint without this
                self.issueReunionPromptAlert()
                // Detector C (fix 2, field 2026-08-31): tell the phone OUTRIGHT that this
                // loan holds the pod, instead of leaving it to infer from dose-stream
                // evidence that only flows when the loop happens to enact. The phone's
                // mirror yields on this within seconds of WC contact.
                self.sendHoldsPodStatusReport(reason: "reunion prompt raised")
            }
        }
    }

    /// Detector C's message: an unsolicited holdsPod status report for the current loan.
    /// The phone treats holdsPod + a newer epoch as books-dirty evidence and yields.
    func sendHoldsPodStatusReport(reason: String) {
        guard phase == .active, let current = epoch else { return }
        sendMessage(.statusReport(StatusReport(
            epoch: current,
            mode: currentMode(),
            lastDirectGlucoseAge: loopManager.latestGlucoseAge,
            lastEventSeq: journal.lastEventSeq,
            podFault: pumpManager?.podLoanFaultDescription,
            holdsPod: true,
            knowsGrant: true)))
        SportLog.event("seize", "statusReport sent — holdsPod e\(current) (\(reason)) [seize]")
    }

    /// The user chose Hand Back on the reunion prompt — the normal hand-back runs.
    func confirmReunionHandback() {
        queue.async {
            guard self.reunionPromptActive, self.phase == .active else { return }
            self.reunionPromptActive = false
            SportLog.event("seize", "reunion prompt: HAND BACK chosen — normal hand-back begins [seize]")
            self.notifyUI()
            self.beginHandback()
        }
    }

    /// The user chose Keep — the seized loan continues. No re-prompt until the phone
    /// LEAVES reachability and returns (a fresh transition re-arms the debounce).
    func dismissReunionPrompt() {
        queue.async {
            guard self.reunionPromptActive else { return }
            self.reunionPromptActive = false
            SportLog.event("seize", "reunion prompt: KEEP chosen — seized loan continues [seize]")
            self.notifyUI()
            // Keep = this loan runs on with the phone present — re-assert holdsPod so the
            // phone's yield can't be waiting on evidence (detector C, fix 2).
            self.sendHoldsPodStatusReport(reason: "Keep chosen")
        }
    }

    /// Wrist-down coverage for the prompt — same alert machinery as the session-ended
    /// notice. Informational only; the choice itself lives on the glance.
    private func issueReunionPromptAlert() {
        let title = NSLocalizedString("iPhone Is Back", comment: "Watch alert title when the phone returns during a seized loan")
        let body = NSLocalizedString("Sport Mode is still running without it. Open the app to hand the pod back, or keep going.", comment: "Watch alert body when the phone returns during a seized loan")
        Task { @MainActor in
            loopManager.issueAlert(Alert(
                identifier: Alert.Identifier(managerIdentifier: "PodLoan", alertIdentifier: "seizeReunionPrompt"),
                foregroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                backgroundContent: Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: "OK"),
                trigger: .immediate))
        }
    }

    /// Every refresh replaces the stored credential wholesale — the newest snapshot is the
    /// only one that matters (R40: full records, settings frozen at issue). Logged at each
    /// arrival so the field cadence is auditable; the seize confirm's age line reads
    /// issuedAt (R40(d): age SHOWN, never capped).
    /// Internal (not private) so tests can seed a stored credential through the real writer.
    func handleDormantGrant(_ dormant: DormantGrant) {
        guard let data = try? LoanProtocol.encoder.encode(dormant) else {
            SportLog.event("seize", "dormant grant arrived but failed to re-encode — NOT stored [seize]")
            return
        }
        defaults.set(data, forKey: DormantKeys.envelope)
        defaults.set(dormant.issuedAt, forKey: DormantKeys.issuedAt)
        defaults.set(dormant.seizeToken.uuidString, forKey: DormantKeys.token)
        SportLog.event("seize", String(format: "dormant grant refreshed — issued %@, %d dose record(s), token …%@ [seize]",
                                       DateFormatter.localizedString(from: dormant.issuedAt, dateStyle: .none, timeStyle: .medium),
                                       dormant.grant.doseHistory.count,
                                       String(dormant.seizeToken.uuidString.suffix(8))))
    }

    /// The stored seize credential, decoded fresh from defaults — the entry flow reads
    /// this when the phone doesn't answer a normal request.
    func storedDormantGrant() -> DormantGrant? {
        guard let data = defaults.data(forKey: DormantKeys.envelope) else { return nil }
        return try? LoanProtocol.decoder.decode(DormantGrant.self, from: data)
    }


    // MARK: - Request / Grant / Takeover (§2.1-2.3)

    /// Where a failed or abandoned start attempt comes to rest. Plain .idle — unless
    /// undrained records are parked, in which case the resting phase is .recoveredDrain and
    /// the drain's resend chain is restarted (the 15 s re-arm guard deliberately lets the
    /// chain die whenever phase leaves the drain family, so every return must re-kick it).
    /// This is what makes the drain a STATE the watch passes through rather than a wall:
    /// field 2026-08-30, a watch reboot mid-seized-loan parked 3 records and then refused
    /// Start — silently — until the phone came back. The records resend on their own;
    /// nothing about them should block the next attempt.
    func returnToRestingPhase() {
        if journal.hasUndrainedEvents {
            phase = .recoveredDrain
            sendHandbackOffer(freshened: false, recovered: true)
        } else {
            phase = .idle
        }
    }

    func requestLoan(watchBuild: String) {
        #if targetEnvironment(simulator)
        // Default in the sim: run the REAL loan protocol against the phone's simulated
        // Omnipod (OmniPumpManager fakes pod comms in-sim). The watch-only fake-flow driver
        // stays available behind a flag for when no paired phone is running.
        // Log the flag VALUE at the decision: a fresh container with the flag absent has been
        // seen driving the fake path, which contradicts this gate as read (the suspect is a
        // stale embedded binary), and this line settles it either way.
        let simFakeFlow = defaults.bool(forKey: "sim.fakeLoanFlow")
        SportLog.event("loan", "Start (sim): sim.fakeLoanFlow=\(simFakeFlow) — \(simFakeFlow ? "FAKE flow driver" : "REAL loan protocol")")
        if simFakeFlow { simDriveStart(); return }
        #endif
        queue.async {
            // R40 re-entry: a parked drain (.recoveredDrain) is startable ground, not a
            // wall. The staged records keep resending on their own timeline and, on the
            // seize path, FOLD into the new loan's stream (handleGrant). Any other busy
            // phase still refuses.
            guard self.phase == .idle || self.phase == .recoveredDrain else {
                SportLog.event("loan", "Start ignored — not idle (phase \(self.phase.rawValue))")
                return
            }
            if self.phase == .recoveredDrain {
                SportLog.event("loan", "Start over a parked drain — \(self.journal.unackedEvents().count) undrained event(s) keep resending; a seize would fold them in [seize]")
            }
            self.phase = .requested
            self.attemptStartedAt = self.now()
            self.lastIdleNote = nil
            // Advisory reachability ACCELERATES the timeout, never gates the attempt (R40(b)):
            // a session already reporting unreachable will not deliver a grant in the next
            // 17 s either, and the user is standing there watching "requesting…" — the first
            // field seize (2026-08-30) spent 25 s twice against a powered-off phone. A
            // reachable-LOOKING dead phone still gets the full window.
            let reachable = self.isPhoneReachable()
            // 60 s with the phone reachable: the grant now includes the phone's cancel-before-release
            // pod round-trip (~13 s on 2026-09-17 11:03, on top of ~10 s of request delivery), and the
            // 25 s this used to allow was missed by 150 ms that morning. A timeout here with the pod
            // already released offers the seize against a phone that has let go — the worst shape.
            let timeout: TimeInterval = reachable ? 60 : 8
            SportLog.event("loan", "REQUEST sent (build \(watchBuild)) — awaiting grant\(reachable ? "" : " (phone unreachable — short \(Int(timeout))s timeout)")")
            self.sendMessage(.request(LoanRequest(watchBuild: watchBuild, supportsSeize: true, sentAt: self.now())))

            // No grant within the timeout → the phone refused, is busy, or isn't reachable.
            // Return to idle with a visible reason instead of hanging on "requesting…".
            self.requestTimeoutWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.phase == .requested else { return }
                // Repaint on EVERY branch below — offer/note can land on a same-value phase
                // the real-change guard skips (fix 5, field 2026-08-31).
                defer { self.notifyUI() }
                self.returnToRestingPhase()
                // The timeout is the moment this request stops being wanted — a copy still
                // queued for a dark phone must die WITH it, not detonate at reunion.
                self.cancelStaleQueuedRequests(context: "request timed out")
                // R40(b): no answer + a stored credential = offer the offline path (never
                // auto-take it; the confirm is the user's deliberate act). The offer takes
                // precedence over the wedge/generic notes below — the user's need is the
                // loan, and the confirm screen replaces the idle note entirely. The log
                // still records reachability so a #113 wedge stays diagnosable.
                if let dormant = self.storedDormantGrant() {
                    self.seizeOffer = (issuedAt: dormant.issuedAt, token: dormant.seizeToken)
                    self.lastIdleNote = nil
                    SportLog.event("seize", String(format: "REQUEST TIMED OUT (reachable=%@) — offering offline start (credential issued %@) [seize]",
                                                   self.isPhoneReachable() ? "Y" : "N",
                                                   DateFormatter.localizedString(from: dormant.issuedAt, dateStyle: .short, timeStyle: .short)))
                    return
                }
                // NAME THE WEDGE (2026-08-21). A request that dies with the phone REACHABLE is
                // the WCSession one-way failure: the phone's isWatchAppInstalled has gone false
                // (it breaks on installs and reboots and can stay false for hours — field
                // 2026-08-21, 09:46-11:53), so everything the phone sends us is silently queued.
                // The grant may even have been sent; it just cannot arrive. Retrying cannot fix a
                // queued-message wedge — only re-establishing the session does, and the reliable
                // field remedy is toggling Bluetooth on the PHONE. Say exactly that, at the
                // moment the user is looking at a failed start, instead of the old generic
                // "refused or busy" which sent them hunting in the wrong places.
                // Reconciled to Caitlin's line 2026-09-09: one note for every timeout. The
                // one-way-wedge signature (#113) is still logged; it just no longer gets its
                // own on-wrist remedy text.
                if self.isPhoneReachable() {
                    SportLog.event("loan", "REQUEST TIMED OUT with phone REACHABLE — one-way wedge signature (#113)")
                }
                self.lastIdleNote = NSLocalizedString("No response from iPhone — check the phone (loan refused, or busy) and try again.", comment: "Glance: loan request timed out")
                SportLog.event("loan", "REQUEST TIMED OUT — no grant in \(Int(timeout))s (phone refused / busy / unreachable)")
            }
            self.requestTimeoutWork = work
            self.schedule(after: timeout, label: "request-timeout", execute: work)
        }
    }


    // MARK: - Grant intake and the takeover ladder (§2.2-2.3)

    func handleGrant(_ grant: LoanGrant) {
        SportLog.event("loan", "GRANT received — epoch \(grant.epoch), \(grant.pumpManagerRawState.count)B pod state")

        // A REAL grant supersedes any seize attempt that never proved out: drop the pending
        // reunion token so this (normal) loan's ACTIVE flip cannot promote a seize identity
        // it does not own. Covers every route to .active — they all pass through here first.
        if !seizeActivationInFlight { pendingSeizeToken = nil }

        /// Order matters here. The timeout is cancelled AFTER the phase check and BEFORE the
        /// rejections: a grant we are going to act on stops the timeout, but a rejected one must
        /// leave something to move the controller. Cancel any earlier and a rejection strands it
        /// at `.requested` with no timeout pending — and since `requestLoan` guards on
        /// `phase == .idle`, Start becomes a silent no-op until the app is relaunched. Every
        /// rejection path goes through `rejectGrant`, which restores `.idle` so the state does
        /// the timeout's job instead.
        // .recoveredDrain accepts grants too (R40 re-entry): the resting phase with a
        // parked drain replaced plain .idle, and a late queued grant deserves the same
        // answer it always got there — usually the "undrained prior loan" denial below,
        // which the phone recovers from, rather than a silent ignore that costs a tap.
        guard phase == .idle || phase == .requested || phase == .recoveredDrain else {
            SportLog.event("loan", "grant ignored — wrong phase (\(phase.rawValue))")
            // A GHOST grant refused mid-loan (a queued request detonating at reunion, field
            // 2026-08-31 21:21:13) used to strand the PHONE at .grantOffered — it waits on a
            // takeoverComplete this refusal guarantees will never come. Answer with the loan
            // we hold so its mirror can abandon the ghost now, not at the +20s probe.
            if phase == .active, (epoch ?? Int.min) >= grant.epoch {
                sendHoldsPodStatusReport(reason: "stale grant e\(grant.epoch) refused")
            }
            return
        }
        requestTimeoutWork?.cancel()

        /// Every rejection must leave the controller startable. Logs the reason, tells the phone
        /// where the protocol expects it, and returns to the resting phase (idle, or the
        /// parked drain when undrained records exist — startable either way).
        func rejectGrant(_ reason: String, notifyPhone: Bool) {
            SportLog.event("loan", "grant REJECTED — \(reason); returning to resting so Start works again")
            if notifyPhone {
                sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: reason)))
            }
            returnToRestingPhase()
        }
        guard self.now() < grant.expiresAt || seizeActivationInFlight else {
            // Row 2: a late grant self-rejects; the phone's T1 already reclaimed.
            // (A confirmed seize stands aside: a dormant credential has no lease — R40(d)
            // staleness was shown and consented to in the confirm.)
            rejectGrant("grant expired", notifyPhone: true)
            return
        }
        if let known = epoch, grant.epoch <= known, !seizeActivationInFlight {
            rejectGrant("stale epoch \(grant.epoch) (known \(known))", notifyPhone: false)
            return
        }
        // SPLIT-BRAIN GUARD (see handleRevoke): the existing expiry check cannot catch this —
        // the lease is 5 min against a 25s request timeout — and the stale-epoch check above is
        // inert because a timed-out request leaves `epoch` nil. Fails safe: the phone keeps the
        // pod and the user taps Start again.
        if let revoked = lastRevokedEpoch, grant.epoch <= revoked {
            rejectGrant("epoch \(grant.epoch) at or below the last revoke (ev=\(revoked)); the phone already asked for the pod back",
                        notifyPhone: true)
            return
        }
        // The grant now rides BOTH channels (phone, 2026-09-17), and the queued copy can drain
        // minutes late — after a short loan on the urgent copy has already ended and cleared
        // `epoch`. The high-water mark never clears: an epoch this watch has accepted once is
        // never accepted again. Silent, because the phone owns the pod and owes nothing.
        if !seizeActivationInFlight, grant.epoch <= defaults.integer(forKey: Keys.highWaterEpoch) {
            rejectGrant("epoch \(grant.epoch) already accepted once (high-water \(defaults.integer(forKey: Keys.highWaterEpoch))) — a late duplicate",
                        notifyPhone: false)
            return
        }

        // Therapy settings snapshot: the ONLY dosing limits; frozen for the
        // loan (spec §8). Validate COMPLETENESS at the loan
        // boundary and refuse with a stated reason — an incomplete config must be a
        // legible denial, not a per-cycle configurationError mid-session (a schedule lost
        // in serialization otherwise dies silently on every cycle of the whole
        // session). Validated BEFORE journal.begin so a
        // refusal leaves no journal/epoch residue.
        var decodedSettings: LoopSettings?
        if let raw = (try? PropertyListSerialization.propertyList(from: grant.therapySettingsRaw, options: [], format: nil)) as? LoopSettings.RawValue {
            decodedSettings = LoopSettings(rawValue: raw)
        }
        // Put back what LoopSettings.rawValue dropped. On this branch that serialization does not
        // carry the three schedules or the insulin model, so `decodedSettings` above is complete
        // only in the fields upstream still bothers to encode — and the schedules are the ONLY
        // dosing limits the wrist has. Applied BEFORE the completeness check below, which is what
        // was refusing the loan with "basal schedule didn't arrive from the phone".
        if var s = decodedSettings, let data = grant.therapySettingsSupplementRaw,
           let supplement = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            if let raw = supplement["basalRateSchedule"] as? BasalRateSchedule.RawValue {
                s.basalRateSchedule = BasalRateSchedule(rawValue: raw)
            }
            if let raw = supplement["insulinSensitivitySchedule"] as? InsulinSensitivitySchedule.RawValue {
                s.insulinSensitivitySchedule = InsulinSensitivitySchedule(rawValue: raw)
            }
            if let raw = supplement["carbRatioSchedule"] as? CarbRatioSchedule.RawValue {
                s.carbRatioSchedule = CarbRatioSchedule(rawValue: raw)
            }
            if let raw = supplement["defaultRapidActingModel"] as? ExponentialInsulinModelPreset.RawValue {
                s.defaultRapidActingModel = ExponentialInsulinModelPreset(rawValue: raw)
            }
            decodedSettings = s
            SportLog.event("loan", "grant settings supplement applied — basal \(s.basalRateSchedule == nil ? "MISSING" : "ok"), ISF \(s.insulinSensitivitySchedule == nil ? "MISSING" : "ok"), CR \(s.carbRatioSchedule == nil ? "MISSING" : "ok"), model \(s.defaultRapidActingModel.map { String(describing: $0) } ?? "default")")
        }
        let missing: String? = {
            guard let s = decodedSettings else { return "settings snapshot" }
            if s.basalRateSchedule == nil { return "basal schedule" }
            if s.insulinSensitivitySchedule == nil { return "insulin sensitivity" }
            if s.carbRatioSchedule == nil { return "carb ratio" }
            if s.glucoseTargetRangeSchedule == nil { return "glucose target range" }
            if s.maximumBasalRatePerHour == nil { return "max basal rate" }
            if s.maximumBolus == nil { return "max bolus" }
            return nil
        }()
        if let missing = missing {
            returnToRestingPhase()
            lastIdleNote = String(format: NSLocalizedString("Can't start: %@ didn't arrive from the phone. Check therapy settings and try again.", comment: "Glance: grant refused for incomplete settings (1: missing field)"), missing)
            SportLog.event("loan", "grant REFUSED — therapy settings incomplete (\(missing))")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "therapy settings incomplete: \(missing)")))
            return
        }

        if seizeActivationInFlight, journal.hasUndrainedEvents {
            // R40 re-entry FOLD: the parked drain becomes this loan's opening stream —
            // epoch re-tagged, events/seqs/cursor/tombstones kept (see adoptEpoch for why
            // re-tagging beats re-minting). Seize-only: confirmSeize guarantees this epoch
            // strictly exceeds the parked one. A normal grant still refuses below — the
            // phone is reachable in that case and the drain resolves itself in seconds.
            let carried = journal.adoptEpoch(grant.epoch)
            SportLog.event("seize", "journal FOLDED — \(carried) undrained event(s) carried into epoch \(grant.epoch); the drain rides this loan's stream [seize]")
            // The folded stream carries REAL records from the prior seized era, and the
            // phone DROPS a future-epoch offer that has no token ("watch ahead of phone").
            // So the reunion token is persisted NOW, not at .active: even if this
            // activation aborts, the resend chain must keep the retro-ack door open.
            // The promote-at-.active hygiene still governs the no-fold path — its property
            // ("no token without records or a live loan") holds here BECAUSE records exist.
            if let token = pendingSeizeToken {
                defaults.set(token.uuidString, forKey: DormantKeys.activeToken)
                pendingSeizeToken = nil
                SportLog.event("seize", "reunion token …\(String(token.uuidString.suffix(8))) persisted at FOLD — the folded drain needs the retro-ack door [seize]")
            }
        } else {
            do {
                try journal.begin(epoch: grant.epoch)
            } catch {
                // An undrained prior loan must drain first — refuse, never clobber.
                rejectGrant("undrained prior loan must drain first", notifyPhone: true)
                return
            }
        }

        epoch = grant.epoch
        // The high-water mark records every epoch ever accepted and is never cleared —
        // the memory CLOSED wipes, so a later seize can't re-mint a spent epoch (fix 4a).
        defaults.set(max(defaults.integer(forKey: Keys.highWaterEpoch), grant.epoch), forKey: Keys.highWaterEpoch)
        phoneSupportsInterimHandback = grant.supportsInterimHandback ?? false   // interim-handback capability gate
        phoneSupportsOverrideRecords = grant.supportsOverrideRecords ?? false    // override-record skew gate
        handbackRequested = false
        finalOfferSent = false
        // Progress-bar anchor: ALWAYS re-anchor at grant. The grant round-trip is WCSession
        // roulette (0.5s to 15s observed on hardware) while the takeover itself is the
        // predictable part (~5s with the scan fix) — so the determinate bar measures
        // the takeover only; the request stage renders indeterminate. This also keeps
        // a late queued grant (after the 25s timeout) from inheriting a dead anchor.
        attemptStartedAt = self.now()
        lastTakeoverReadAt = nil          // fresh ladder, fresh stall measurement
        takeoverMaxReadGap = 0
        PodLoanConnectClock.reset()       // connect/disconnect stamps describe THIS attempt
        // Stamp every BLE edge with the execution state it fired in. The flapping has only
        // ever been seen overnight/wrist-down; Sport Mode is awake and moving. This is how we
        // find out whether the regime that matters behaves the same way.
        PodLoanConnectClock.appStateProbe = { RuntimeStateLog.appStateName() }
        RuntimeStateLog.probeTimerDeferral("takeover-start")
        phase = .takingOver
        loopManager.settings = decodedSettings!
        // Adopt the override the phone had running. Assigning it (rather than calling
        // applyWristOverride) is deliberate: the didSet records it into the override history —
        // which is the only thing that actually rescales basal, ISF and carb ratio — while
        // minting no .overrideChange record, because the phone already holds this override and
        // does not need it handed back. The log line the didSet emits names the resolved
        // multipliers, so "did the override survive the grant?" is answerable from the watch log.
        //
        // A decode failure is treated as "no override" and said out loud: the alternative is
        // refusing the loan, and a loan refused mid-exercise is worse than one that needs the
        // preset re-tapped on the wrist.
        if let raw = grant.activeOverrideRaw {
            if let plist = (try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil)) as? TemporaryScheduleOverride.RawValue,
               let override = TemporaryScheduleOverride(rawValue: plist) {
                loopManager.scheduleOverride = override
            } else {
                SportLog.event("override", "grant carried an override the watch could NOT decode — this loan doses UNSCALED; re-tap the preset on the wrist")
            }
        }
        // Frozen-at-grant like the therapy settings above: run the RC implementation the
        // GRANTING phone runs, instead of silently assuming Standard. nil (older phone) →
        // Standard, the pre-existing behavior.
        loopManager.setIntegralRetrospectiveCorrection(grant.integralRetrospectiveCorrectionEnabled ?? false)
        // The wrist inherits the phone's loop mode: if the phone is closed the watch is
        // closed, if the phone is open the watch is open. An earlier rule reset every loan
        // to OPEN/advisory regardless; it was superseded for the sake of a second user's
        // intuition, not because confidence in the fail-safe changed, so a broader release
        // may revert to always-open.
        //
        // Frozen at the grant like the therapy settings. nil (a phone predating the field)
        // → false, i.e. exactly the old start-OPEN rule, so build skew degrades to the
        // previous behavior rather than to an unintended closed loop.
        loopManager.setClosedLoopEnabled(grant.phoneClosedLoopEnabled ?? false,
                                         reason: grant.phoneClosedLoopEnabled == nil
                                            ? "(older phone sent no loop mode — defaulting open)"
                                            : "inherited from the phone at grant")
        // Ring ruling 2026-08-23: the loop dot starts from the SYSTEM's recency — the phone
        // looped minutes ago at most, so the wrist should not open on grey/red for the seconds
        // until its own first cycle. Forward-only seed; the watch's first cycle (~10 s away)
        // takes over the clock immediately.
        if let phoneLoop = grant.lastLoopCompleted {
            loopManager.seedLastLoopCompleted(phoneLoop, source: "phone at grant")
        }
        // INSTRUMENTATION ONLY: stash the phone's prediction decomposition + echo it into the
        // log, BEFORE the takeover read / first prediction refresh, so [predict-diff] and [iob-diff]
        // Leg 1 have the phone baseline in hand. The serial dataAccessQueue guarantees the stash
        // lands before the first diff.
        ingestPredictionSnapshot(grant)

        // Log what the watch ACTUALLY received. The grant validates completeness but does
        // not record the VALUES, so verifying any prediction against real settings
        // otherwise means back-solving them from observed effects — which is unreliable,
        // because the insulin-effect window includes pre-loan dose history, not
        // just the loan odometer. Two settings-transfer bugs have already hidden here
        // (schedules never reaching the stores; missing overrideHistory), so this also
        // turns "did the settings arrive intact?" into a glance.
        if let s = decodedSettings {
            let now = self.loopManager.now()
            let isf = s.insulinSensitivitySchedule?.quantity(at: now).doubleValue(for: .milligramsPerDeciliter)
            let cr = s.carbRatioSchedule?.value(at: now)
            let basal = s.basalRateSchedule?.value(at: now)
            let target = s.glucoseTargetRangeSchedule?.quantityRange(at: now)
            let lo = target?.lowerBound.doubleValue(for: .milligramsPerDeciliter)
            let hi = target?.upperBound.doubleValue(for: .milligramsPerDeciliter)
            let csf = (isf != nil && cr != nil && cr! > 0) ? isf! / cr! : nil
            SportLog.event("settings", String(
                format: "granted @now — ISF %@ mg/dL/U · CR %@ g/U · CSF %@ mg/dL/g · basal %@ U/hr · target %@-%@ · maxBasal %@ U/hr · maxBolus %@ U",
                isf.map { String(format: "%.0f", $0) } ?? "nil",
                cr.map { String(format: "%.1f", $0) } ?? "nil",
                csf.map { String(format: "%.2f", $0) } ?? "nil",
                basal.map { String(format: "%.2f", $0) } ?? "nil",
                lo.map { String(format: "%.0f", $0) } ?? "nil",
                hi.map { String(format: "%.0f", $0) } ?? "nil",
                s.maximumBasalRatePerHour.map { String(format: "%.2f", $0) } ?? "nil",
                s.maximumBolus.map { String(format: "%.2f", $0) } ?? "nil"))

            // And what DOSING will actually use, whenever an override is running.
            //
            // The line above reads the raw schedules, which is right for "did the settings
            // arrive intact?" and wrong for anything else: an override scales basal by its
            // insulin-needs factor and divides ISF and CR by it, so with a 0.37 factor the
            // schedule says ISF 70 / basal 0.60 while every [dosemath] line in the same
            // second says ISF 189 / basal 0.22. Both numbers are correct and they look like
            // a settings-corruption bug — this cost a full log-reading session on 2026-08-18
            // before the override was remembered.
            //
            // Printed as a SECOND line rather than folded into the first, so the raw values
            // stay greppable for the integrity check they exist to serve.
            if let o = self.loopManager.scheduleOverride, o.isActive(at: now) {
                let f = o.settings.effectiveInsulinNeedsScaleFactor
                SportLog.event("settings", String(
                    format: "override ACTIVE '%@' × %.2f insulin needs — effective ISF %@ mg/dL/U · CR %@ g/U · basal %@ U/hr (dosing uses THESE, not the schedule above)",
                    o.context.presetNameForLog,
                    f,
                    isf.map { String(format: "%.0f", $0 / f) } ?? "nil",
                    cr.map { String(format: "%.1f", $0 / f) } ?? "nil",
                    basal.map { String(format: "%.2f", $0 * f) } ?? "nil"))
            }
        }

        // Stock construction: exactly a phone relaunch. BlePodComms auto-connects from
        // podState.bleIdentifier at init (BlePodComms.swift:44) — no arming step.
        guard let rawValue = (try? PropertyListSerialization.propertyList(from: grant.pumpManagerRawState, options: [], format: nil)) as? [String: Any],
              var rawState = rawValue["state"] as? PumpManager.RawStateValue else {
            teardownPump()
            returnToRestingPhase()
            lastIdleNote = NSLocalizedString("Couldn't read the pod from the phone. Try again.", comment: "Glance: pump snapshot rejected")
            SportLog.event("loan", "grant FAILED — could not rebuild the pump from the phone's snapshot")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "pump state snapshot rejected")))
            return
        }
        // SUBSTITUTE OUR OWN HANDLE (2026-08-20). The snapshot carries the PHONE's
        // `bleIdentifier` — a CoreBluetooth handle minted on that device, which this one can
        // never retrieve. Patching it BEFORE construction matters: BlePodComms.init calls
        // connectToDevice(uuidString:) with whatever it finds, and a foreign UUID there is not
        // harmless — it lands in autoConnectIDs, can never be discovered here, and so pins
        // hasDiscoveredAllAutoConnectDevices false, keeping the radio scanning for the whole
        // loan (the same trap omnipodDidAdoptLoanPod cleans up after).
        //
        // If we have adopted this pod before, our own handle goes in instead and the ordinary
        // driver path — init -> connectToDevice -> retrievePeripherals, then bleRunSession ->
        // configureAndRun -> connectOnDemand — reacquires with no discovery at all.
        //
        // NEVER REMOVE THE KEY when we have no cached handle (field 2026-08-20, epochs 150-152).
        // The first cut deleted it, reasoning that a foreign identifier is useless here. But
        // PodState decodes the LTK and the handle in ONE `if let`:
        //
        //     if let ltkString = rawValue["ltk"] as? String,
        //        let bleIdentifier = rawValue["bleIdentifier"] as? String { ... }
        //
        // so dropping the handle silently drops the POD'S ENCRYPTION KEY. The takeover then
        // connected fine and the pod hung up 108 ms after the first command (Code=7), three
        // grants in a row, because we were talking to it with no session. Leave the phone's
        // value in place instead: it is inert here (retrievePeripherals cannot resolve a foreign
        // UUID) and omnipodDidAdoptLoanPod already replaces it on adopt.
        takeoverCachedHandle = nil
        var cachedHandle: String?
        if var podRaw = rawState["podState"] as? [String: Any],
           let address = podRaw["address"] as? UInt32 {
            cachedHandle = PodLoanBleIdentifierCache.identifier(forPodAddress: address)
            if let cachedHandle {
                takeoverCachedHandle = (address, cachedHandle)
                podRaw["bleIdentifier"] = cachedHandle
                rawState["podState"] = podRaw
            }
            SportLog.event("loan", String(format: "handle for pod %08X: %@", address,
                                          cachedHandle.map { "CACHED \($0) — skipping discovery" } ?? "none yet — will discover"))
        }
        // The snapshot was serialized after the phone released the pod, so it says "released" —
        // true there, not here. Left set, the driver's init-time disarm drops the handle it just
        // armed (autoConnectIDs), and the poweredOn recovery then has nothing to recover.
        rawState["podConnectionReleased"] = false
        guard let manager = OmniPumpManager(rawState: rawState) else {
            teardownPump()
            returnToRestingPhase()
            lastIdleNote = NSLocalizedString("Couldn't read the pod from the phone. Try again.", comment: "Glance: pump snapshot rejected")
            SportLog.event("loan", "grant FAILED — could not rebuild the pump from the phone's snapshot")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "pump state snapshot rejected")))
            return
        }

        manager.pumpManagerDelegate = self
        manager.delegateQueue = queue
        pumpManager = manager
        defaults.set(manager.rawState, forKey: Keys.pumpState)   // R40(e): on disk from the first moment we hold it
        guard ingestGrantHistory(grant) else {
            teardownPump()
            returnToRestingPhase()
            lastIdleNote = NSLocalizedString("Couldn't build the insulin book from the phone's history. Try again.", comment: "Glance: insulin book seed failed")
            SportLog.event("loan", "grant FAILED — the insulin book could not be seeded from the phone's history")
            sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "insulin book seed failed")))
            return
        }
        // Cross-device adoption: unless our own cached handle replaced the phone's above, scan for
        // the pod by its address and adopt the peripheral THIS watch discovers. With a cached
        // handle nothing is armed — the driver's own connect-on-demand dials on the first read,
        // and a handle that never connects is forgotten at the takeover verdict.
        let discover = takeoverCachedHandle == nil
        let armed = manager.podLoanBeginTakeover(discover: discover)
        SportLog.event("loan", "pump rebuilt — \(armed ? (discover ? "takeover scan armed" : "cached handle — the first read dials") : "no pod address!")")

        // First pod status = the takeover proof (§2.3). The pod's BLE session takes
        // SECONDS to establish after construction (scan → connect → EAP-AKA), but a
        // status read fails INSTANTLY with .podNotConnected until it's up
        // (BlePodComms.bleRunSession guard). So retry on a bounded schedule — the
        // pod-side timeout budget (~40s) — instead of failing on the first,
        // pre-connection read.
        // The lease horizon, logged at entry: a grant whose budget is already negative or
        // seconds-thin dies at read 1 with "lease expired mid-takeover", and that death
        // should be legible HERE rather than reconstructed from issue timestamps (the
        // first field seize burned two attempts before the un-restamped dormant lease
        // was identified as the killer).
        SportLog.event("loan", String(format: "takeover ladder start — lease %+.0fs, epoch %d%@",
                                      grant.expiresAt.timeIntervalSince(now()), grant.epoch,
                                      seizeMarkerActive ? " [seize]" : ""))
        queue.async { [weak self] in self?.attemptTakeoverRead(manager: manager, grant: grant, attempt: 0) }
    }

    /// Up to 14 reads while the pod's BLE session establishes — fast when the session-established
    /// event drives them (no fixed period), up to ~112s if every read falls through to the 8s
    /// backstop.
    /// The takeover waits for the pod stack's own session-established EVENT
    /// instead of inferring readiness from a polled CBPeripheral.state.
    ///
    /// Why: `peripheral.state`, read from this controller's queue, is not valid there, and it
    /// contradicts the connect callbacks every time — reporting "disconnected" or "connecting"
    /// a fraction of a second after didConnect. bleRunSession bails on that stale value, so no
    /// byte is ever sent and the pod hangs up on the silent link.
    ///
    /// So: the event drives the retry, and the periodic poll is only a slow backstop. A
    /// short debounce after the event lets the peripheral state propagate to our queue before
    /// the read, since the guard downstream still consults it.
    ///
    /// Deliberately NOT applied to the steady-state reclaim, which is reliable in the field
    /// precisely because it never re-enters this configuration path. Takeover-only: the initial
    /// takeover gets its own protocol.
    func setTakeoverSessionListener(_ armed: Bool) {
        guard armed else {
            PodLoanConnectClock.podLoanOnSessionEstablished = nil
            takeoverBackstop?.cancel()
            takeoverBackstop = nil
            takeoverRetryAction = nil
            return
        }
        PodLoanConnectClock.podLoanOnSessionEstablished = { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                guard self.phase == .takingOver, let action = self.takeoverRetryAction else { return }
                SportLog.event("loan", "takeover: pod session ESTABLISHED (stack event) — reading now instead of waiting for the backstop")
                self.takeoverRetryAction = nil
                self.takeoverBackstop?.cancel()      // cancel the TIMER only
                self.takeoverBackstop = nil
                self.schedule(after: 0.25, label: "session-event-settle") { action() }   // the action still lives
            }
        }
    }

    /// `driver` says WHY this particular read fired: "initial" (attempt 0), "event" (the pod
    /// stack's session-established callback ran it early), or "backstop" (the 8s timer fired with
    /// no event). Without it, the split between event-driven reads (fast, irregular) and
    /// backstop-driven ones (exactly the backstop period) has to be INFERRED by
    /// cross-referencing the "session
    /// ESTABLISHED" log line against the read line that followed it. Stamping the driver directly
    /// on every read line makes that split a single grep instead of a reconstruction.
    func attemptTakeoverRead(manager: OmniPumpManager, grant: LoanGrant, attempt: Int, driver: String = "initial") {
        let maxAttempts = 14
        manager.podLoanReadStatus { [weak self] success in
            guard let self = self else { return }
            self.queue.async {
                guard self.phase == .takingOver, self.epoch == grant.epoch else {
                    // Verdict completeness: a takeover must never vanish without a verdict.
                    // This fires when the in-flight ladder for grant.epoch was superseded — the user
                    // re-tapped Start (phase left .takingOver) or a newer grant bumped the epoch.
                    // Log-only: a "superseded" line, not a behavior change.
                    SportLog.event("loan", "TAKEOVER SUPERSEDED — epoch \(grant.epoch) abandoned mid-ladder (now phase \(self.phase.rawValue), epoch \(self.epoch.map(String.init) ?? "nil"))")
                    return
                }
                // CRITICAL: the grant's ~5-min lease is validated
                // once at intake, but this ladder can run FAR past its nominal ~40s
                // when the app is suspended mid-ladder — frozen queue timers draining
                // late on wake have stretched one ladder to 23 minutes.
                // Past the lease, the phone is entitled to have
                // T1-reclaimed the pod; flipping .active here would put TWO controllers
                // on one pod. Re-check the lease every iteration and abort BEFORE
                // honoring a successful read — expiry outranks a good status.
                guard self.now() < grant.expiresAt else {
                    self.teardownPump()
                    self.returnToRestingPhase()
                    // Reconciled to Caitlin's line 2026-09-09: only a clean transient (pod
                    // seen, connects attempted, no #11) earns "try again"; the wedge
                    // signature names the cure instead. Port API is wedgeSignature(since:).
                    let wedged = PodLoanConnectClock.wedgeSignature(since: self.attemptStartedAt)
                    if wedged {
                        self.lastIdleNote = NSLocalizedString("The pod didn't answer. Turn watch Bluetooth off and on, then try again.", comment: "Glance: takeover failed with the BLE-wedge signature")
                    } else {
                        self.lastIdleNote = NSLocalizedString("Sport Mode start expired before the pod answered. Tap Start to try again.", comment: "Glance: grant lease expired mid-takeover")
                    }
                    SportLog.event("loan", "TAKEOVER ABORTED — grant lease expired mid-takeover after \(attempt + 1) read(s), epoch \(grant.epoch), wedgeSignature=\(wedged)\(self.seizeMarkerActive ? " [seize]" : "")")
                    self.sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: "grant expired mid-takeover")))
                    return
                }
                if success, let delivered = manager.podLoanInsulinDelivered {
                    self.revokeCapturedDelivered = nil   // new loan, new baseline — never a stale capture
                    self.revokeCapturedDeliveredAt = nil
                    self.deliveredAtTakeover = delivered
                    self.phase = .active
                    // R40 reunion identity: the seize is PROVEN only now — persist its token
                    // so the loan's offers echo it and the phone can retro-acknowledge. Every
                    // failed activation leaves this un-promoted, so nothing stale can match.
                    if let token = self.pendingSeizeToken {
                        self.defaults.set(token.uuidString, forKey: DormantKeys.activeToken)
                        self.pendingSeizeToken = nil
                        SportLog.event("seize", "seized loan ACTIVE — reunion token …\(String(token.uuidString.suffix(8))) persisted for the offer echo [seize]")
                    }
                    self.loopManager.pumpManager = manager
                    self.onLoanActiveChanged?(true)
                    let takeoverSecs = self.attemptStartedAt.map { self.now().timeIntervalSince($0) } ?? -1
                    SportLog.event("loan", String(format: "ACTIVE — epoch %d, pod taken after %d read(s) in %.1fs [takeover-timing], odometer %.2f U, final read driver=%@ · %@",
                                                  grant.epoch, attempt + 1, takeoverSecs, delivered, driver, RuntimeStateLog.snapshot()))
                    self.sendMessage(.takeoverComplete(TakeoverComplete(epoch: grant.epoch, firstPodStatus: self.currentPodStatus())))
                    // Refresh the glance eventual + IOB from the just-seeded insulin/carbs/
                    // glucose NOW (display-only, no enact) so the prediction reflects the seeded
                    // carbs at takeover instead of the stale pre-loan value until the first G7
                    // reading drives a full cycle. The seeds completed well before this point.
                    // THE WATCH ASSERTS ITS OWN PROGRAM AT TAKEOVER — no program crosses the
                    // boundary. Two controllers sharing one temp is the defect behind a whole
                    // family of problems: unbooked tails, re-arm copy divergence, the record-close
                    // that truncated a running temp at every release, and a systematic audit bias
                    // (expectedInsulin predicts the SCHEDULE across a gap it has no journal segment
                    // for, so an inherited 0.90 U/hr against a 0.70 schedule accrues ~0.20 U/hr of
                    // unexplained delivery). A clean boundary removes that rather than accounting
                    // around it.
                    //
                    // A full loop() rather than a bespoke enact, deliberately: it reuses every gate
                    // (closed-loop mode inherited from the grant, glucose recency, pump-data
                    // freshness, DoseMath limits, the IOB clamp), records a CYCLE VERDICT like any
                    // other cycle, and — the point — MINTS A JOURNAL EVENT, so the loan's first
                    // program is ours, streamed to the phone, and inside the audit. The new temp
                    // supersedes the old in the same breath, so there is no gap in delivery.
                    // The phone cancelled its running temp before releasing the pod (R2: no program
                    // crosses the boundary), so the pod is on the schedule; the first cycle programs ours.
                    self.loopManager.loop()
                } else if attempt + 1 < maxAttempts {
                    if attempt == 0 {
                        SportLog.event("loan", "connecting to pod… (BLE session establishing; typically ~17s, budget ~40s)")
                    }
                    // Log the pod BLE state each failed read so "unreachable"
                    // shows WHY — stuck disconnected (pod not advertising / still held by the
                    // phone) vs connecting-but-no-response.
                    let readElapsed = self.attemptStartedAt.map { self.now().timeIntervalSince($0) } ?? -1
                    // Measure the inter-read gap. Backstop-driven reads land ~8 s apart (event-
                    // driven reads can be much faster) — a gap well past 8 s is suspended-app time,
                    // not pod silence.
                    let readNow = self.now()
                    if let prev = self.lastTakeoverReadAt {
                        self.takeoverMaxReadGap = max(self.takeoverMaxReadGap, readNow.timeIntervalSince(prev))
                    }
                    self.lastTakeoverReadAt = readNow
                    // Probe the NEXT inter-read interval directly, so a stalled ladder says
                    // whether the OS deferred our timer or the read itself blocked. Only on the
                    // first few reads — this is a meter, not a metronome.
                    if attempt < 3 { RuntimeStateLog.probeTimerDeferral("ladder-read\(attempt + 1)") }
                    // Pair OUR observation with the BLE stack's own timestamps. If didConnect
                    // reads +12s while this poll is landing at +68s, the link was up and only our
                    // deferred timer was late — fix the ladder. If didConnect says "never", the
                    // radio genuinely hasn't connected — fix the keepalive. The poll alone cannot
                    // distinguish those, which is why this line exists.
                    // The G7 side rides along because a #11 cannot name its holder from the pod
                    // central's own census — the G7 client is a separate CBCentralManager, and a
                    // pending G7 connect is the usual suspect for the missing slot.
                    SportLog.event("loan", String(format: "takeover read %d/%d driver=%@ (+%.1fs) — pod BLE state %@ · %@ · %@ · %@",
                                                  attempt + 1, maxAttempts, driver, readElapsed,
                                                  manager.podLoanConnectionStateDescription,
                                                  PodLoanConnectClock.summary(since: self.attemptStartedAt),
                                                  self.g7StateForContention(),
                                                  RuntimeStateLog.snapshot()))
                    // The retry is a cancellable work item so the session-established
                    // event can run it IMMEDIATELY. The timer is only a backstop at 8 s —
                    // with the event driving progress, polling faster only burns
                    // the attempt budget against a stale state read.
                    let fireRetry: (String) -> Void = { [weak self] nextDriver in
                        guard let self = self else { return }
                        self.takeoverRetryAction = nil
                        self.takeoverBackstop = nil
                        guard self.phase == .takingOver, self.epoch == grant.epoch else {
                            // The ladder was superseded during the inter-attempt wait
                            // (re-Start or a newer epoch). Emit the verdict instead of vanishing.
                            SportLog.event("loan", "TAKEOVER SUPERSEDED — epoch \(grant.epoch) abandoned between reads (now phase \(self.phase.rawValue), epoch \(self.epoch.map(String.init) ?? "nil"))")
                            return
                        }
                        self.attemptTakeoverRead(manager: manager, grant: grant, attempt: attempt + 1, driver: nextDriver)
                    }
                    self.takeoverRetryAction = { fireRetry("event") }
                    let backstop = DispatchWorkItem { fireRetry("backstop") }
                    self.takeoverBackstop = backstop
                    self.schedule(after: 8, label: "takeover-read", execute: backstop)
                } else {
                    self.teardownPump()
                    self.returnToRestingPhase()
                    let failSecs = self.attemptStartedAt.map { self.now().timeIntervalSince($0) } ?? -1
                    // A stalled ladder usually means watchOS suspended the app mid-connect, not
                    // that the pod is unreachable — so the message must not send the user to the
                    // pod. `.takingOver` holds runtime through `onTakeoverRadioHold`
                    // (StockLoopSession.swift), the same WorkoutKeepalive the loan workout and hand-back use,
                    // so this gap should only open if the keepalive itself failed to start or
                    // renew (HK auth denied, session error).
                    //
                    // `RuntimeStateLog.snapshot()` on every read line settles which it was without
                    // inference: "keepalive running(takeover)" on every read means the keepalive
                    // held and the stall is something else; "off"/"DENIED"/"FAILED" means the
                    // keepalive is the failure.
                    let stalled = self.takeoverMaxReadGap > 20
                    let wedged = !stalled && PodLoanConnectClock.wedgeSignature(since: self.attemptStartedAt)
                    if stalled {
                        // Say ONLY what was measured. Battery level does NOT track the outcome:
                        // takeovers succeed at 20% with the wrist up, and run unsuspended at 65%
                        // under the same no-keepalive condition. What tracks the outcome is
                        // whether anything kept the app awake during the connect.
                        // Guessing a remedy is how an earlier note ended up blaming a healthy pod.
                        self.lastIdleNote = String(format: NSLocalizedString(
                            "Sport Mode didn't start — the watch app stopped running mid-connect (%@). Your phone still has the pod. Keep the watch awake — wrist up or screen on — and try again.",
                            comment: "Glance: takeover failed because the app was suspended"), batteryTag())
                    } else {
                        // Root-caused, and it is NOT the pod. Every connect
                        // returned CBErrorDomain#11 (connectionLimitReached) — a limit on THIS
                        // APP's CoreBluetooth slots, not a busy or sleeping pod. The phone had
                        // released cleanly (its own log showed the link down) and the pod's
                        // census held one disconnected device. The slot was ours: the G7 client
                        // leaves an armed pending connect alive across a takeover
                        // and a pending connect reserves a slot. Hence the
                        // gap signature — re-takeovers 12-15 s apart all succeeded, the one after a
                        // 153 s quiet gap failed, because only the long gap gave the G7 time to
                        // re-arm.
                        //
                        // So telling the user to "check the pod is nearby and awake" sent them to
                        // inspect healthy hardware for a fault in our own radio bookkeeping. Say
                        // the two things that are true and useful instead: nothing moved, and a
                        // short wait is the remedy that actually works in the field.
                        // ...and when the failure carries the WEDGE signature (#11 during the
                        // attempt, or zero connects against a known-present pod), "try again" is
                        // actively harmful: CoreBluetooth connect requests are SYSTEM-level and
                        // outlive the app, so a force-quit-and-retry leaves orphaned pending
                        // connects consuming slots and each round makes the radio blinder (field,
                        // pure line 2026-08-21: refused-with-#11 escalated to zero adverts in
                        // 108 s across retries; a watch Bluetooth toggle cleared it first try).
                        // Say the remedy that works instead of the one that feeds the failure.
                        // State the fact and stop ("if there is no pod, there is no pod" —
                        // Jeremy, 2026-09-02). Reconciled to Caitlin's line 2026-09-09: the
                        // wedge variant's on-wrist remedy text is gone; `wedged` still drives
                        // the TAKEOVER FAILED log line and the reason sent to the phone.
                        self.lastIdleNote = NSLocalizedString(
                            "Sport Mode didn't start — the pod couldn't be reached. Your phone still has it and is still looping.",
                            comment: "Glance: takeover failed — the pod link never established")
                    }
                    SportLog.event("loan", String(format: "TAKEOVER FAILED wedge=%@ — %@ after %d reads in %.1fs [takeover-timing], max inter-read gap %.1fs (event-driven; 8s backstop when no event fires), %@, final BLE state %@, %@, %@, epoch %d%@",
                                                  wedged ? "YES" : "no",
                                                  stalled ? "ladder STALLED (our polling was deferred; see cb: for whether the link was up)" : "pod unreachable",
                                                  maxAttempts, failSecs, self.takeoverMaxReadGap, batteryTag(),
                                                  manager.podLoanConnectionStateDescription,
                                                  PodLoanConnectClock.summary(since: self.attemptStartedAt),
                                                  RuntimeStateLog.snapshot(), grant.epoch,
                                                  self.seizeMarkerActive ? " [seize]" : ""))
                    // The reason string is rendered verbatim in the PHONE's notification body
                    // ("The watch could not take the pod (…). The phone kept it."), so it carries
                    // the same obligation as the wrist note above: do not blame the pod for a
                    // connection slot we were holding ourselves.
                    self.sendMessage(.takeoverFailed(TakeoverFailed(epoch: grant.epoch, reason: stalled ? "watch app suspended mid-takeover" : (wedged ? "watch Bluetooth wedged — toggle needed" : "couldn't establish the pod link"))))
                    if let trusted = self.takeoverCachedHandle, PodLoanConnectClock.connectCount == 0 {
                        PodLoanBleIdentifierCache.forget(podAddress: trusted.address)
                        SportLog.event("loan", "takeover: cached handle \(trusted.handle) never connected — FORGOTTEN; the next Start discovers")
                    }
                }
            }
        }
    }
}
