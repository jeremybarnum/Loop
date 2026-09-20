//
//  PodLoanPhoneController+Hold.swift
//  Loop
//
//  The watch's hold on the pod is only as good as its last renewal.
//
//  The phone stays out while the watch keeps saying it is dosing: every landed cycle on the wrist
//  sends a record batch, empty or not, stamped with its send time. When those stop, the phone takes
//  the pod back by itself — no message has to arrive for that to happen, so no lost, late or
//  stale message can leave the pod without a controller. Before this, a silent watch was never
//  reclaimed on a timer (2026-09-08: four hours unattended).
//

import Foundation
import LoopKit

extension PodLoanPhoneController {

    /// How long the hold outlives its last renewal. Three missed cycles.
    static let holdLapse: TimeInterval = .minutes(15)

    /// Last call. A phone walking back into range notices an hour of silence at once, while the
    /// watch — alive, and dosing the whole time — is one cycle from renewing. So the phone takes
    /// the pod only after it has been awake to the lapse for a cycle and still heard nothing.
    static let holdLastCall: TimeInterval = .minutes(6)

    private enum HoldKeys {
        static let renewedAt = "PodLoanPhoneController.holdRenewedAt"
        static let lapseNoticedAt = "PodLoanPhoneController.holdLapseNoticedAt"
    }

    /// Send time of the newest watch message for this loan; the grant itself is the first.
    var holdRenewedAt: Date? {
        get { UserDefaults.standard.object(forKey: HoldKeys.renewedAt) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: HoldKeys.renewedAt) }
    }

    var holdLapseNoticedAt: Date? {
        get { UserDefaults.standard.object(forKey: HoldKeys.lapseNoticedAt) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: HoldKeys.lapseNoticedAt) }
    }

    /// A message from the watch for the current loan renews the hold — by its SEND time, never
    /// by its arrival: a batch that sat in a queue for an hour renews nothing.
    func noteHoldRenewal(sentAt: Date?) {
        let now = deps.now()
        let stamp = min(sentAt ?? now, now)
        guard stamp > (holdRenewedAt ?? .distantPast) else { return }
        holdRenewedAt = stamp
        if holdLapseNoticedAt != nil, now.timeIntervalSince(stamp) <= Self.holdLapse {
            holdLapseNoticedAt = nil
            handbackDiag(epoch, "hold RENEWED during last call — the watch is alive; the phone stays out")
        }
    }

    /// Rides every loop update, like the dormant-grant refresher. All gating lives inside.
    func considerHoldLapse() {
        queue.async { self.queue_considerHoldLapse() }
    }

    func queue_considerHoldLapse() {
        guard state == .loaned || state == .grantOffered, let renewed = holdRenewedAt else {
            if holdLapseNoticedAt != nil { holdLapseNoticedAt = nil }
            return
        }
        let now = deps.now()
        let silence = now.timeIntervalSince(renewed)
        guard silence > Self.holdLapse else {
            if holdLapseNoticedAt != nil { holdLapseNoticedAt = nil }
            return
        }
        guard let noticed = holdLapseNoticedAt else {
            holdLapseNoticedAt = now
            handbackDiag(epoch, String(format: "hold LAPSED — no renewal from the watch for %.0f min; last call, %.0f min, before the phone takes the pod back",
                                       silence / 60, Self.holdLastCall / 60))
            return
        }
        guard now.timeIntervalSince(noticed) >= Self.holdLastCall else { return }
        holdLapseNoticedAt = nil
        forceReclaimToOwner(reason: String(format: "hold lapsed — watch silent %.0f min, last call unanswered", silence / 60))
    }
}
