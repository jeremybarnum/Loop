//
//  CriticalAlertAudioPlayer.swift
//  Loop
//
//  Plays critical-alert sounds via AVAudioPlayer to bypass the iOS
//  silent switch + DND when the build doesn't have the Critical Alerts
//  entitlement (or the user has disabled the permission).
//
//  Critical Alerts on iOS require an Apple-granted entitlement that
//  DIY/sideloaded builds can't obtain. Without it, UNNotificationSound's
//  .defaultCritical / .criticalSoundNamed are silently downgraded to a
//  regular notification — which the system muffles during DND, Focus
//  modes, or with the silent switch on. That can leave an urgent low
//  glucose alarm playing no sound at 3am.
//
//  This class plays the alert sound in-process via AVAudioPlayer with
//  the `.playback` audio session category, which ignores the silent
//  switch and Focus. System volume still applies (apps can't override
//  that, and shouldn't). The user-visible UNNotification still gets
//  scheduled in parallel; this class just emits the audio.
//

import AVFoundation
import LoopKit
import os.log
import UIKit

@MainActor
final class CriticalAlertAudioPlayer {
    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "CriticalAlertAudioPlayer")

    private var player: AVAudioPlayer?
    private var stopTimer: Timer?

    /// Hard cap on how long the audio loop runs before giving up. Five
    /// minutes matches Dexcom's urgent-low cadence — long enough to
    /// reliably wake the user, short enough not to be a runaway alarm if
    /// the phone is genuinely unreachable.
    private let maxDuration: TimeInterval = 5 * 60

    /// True if we're currently looping audio for a critical alert.
    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Start (or restart) looping playback of the bundled critical
    /// alert sound. Safe to call repeatedly — replaces any current
    /// playback. The sound file lives in Loop's main bundle as
    /// `critical.caf` so it's always present; we don't go through
    /// AlertManager's AlertSoundVendor-keyed `Library/Sounds/` lookup,
    /// which would only work for plugins that register sound vendors.
    func play() {
        stop()

        guard let url = Bundle.main.url(forResource: "critical", withExtension: "caf") else {
            os_log("critical.caf not found in main bundle; audio fallback unavailable", log: log, type: .error)
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // Plain .playback — primary audio that ignores the silent
            // switch and Focus modes. Don't use .mixWithOthers /
            // .duckOthers for an alarm: with .mixWithOthers iOS treats
            // us as secondary audio and may not actually start
            // playback when no other audio is active.
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
            os_log("Audio session active. category=%{public}@ otherAudioPlaying=%{public}@ outputVolume=%{public}.2f",
                   log: log, type: .info,
                   session.category.rawValue,
                   session.isOtherAudioPlaying ? "yes" : "no",
                   session.outputVolume)

            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 1.0
            p.prepareToPlay()
            guard p.play() else {
                os_log("AVAudioPlayer.play() returned false for %{public}@", log: log, type: .error, url.lastPathComponent)
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])
                return
            }
            player = p
            stopTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            os_log("Started critical-alert audio playback (duration=%{public}.2fs playing=%{public}@)",
                   log: log, type: .info, p.duration, p.isPlaying ? "yes" : "no")
        } catch {
            os_log("Failed to start audio playback: %{public}@", log: log, type: .error, String(describing: error))
        }
    }

    /// Stop playback if any. Safe to call when not playing.
    func stop() {
        guard player != nil || stopTimer != nil else { return }
        player?.stop()
        player = nil
        stopTimer?.invalidate()
        stopTimer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        os_log("Stopped critical-alert audio playback", log: log, type: .info)
    }
}
