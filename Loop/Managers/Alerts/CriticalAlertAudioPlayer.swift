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
import AudioToolbox
import LoopKit
import os.log
import UIKit

@MainActor
final class CriticalAlertAudioPlayer {
    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "CriticalAlertAudioPlayer")

    private var player: AVAudioPlayer?
    private var stopTimer: Timer?
    private var vibrationTimer: Timer?

    /// How often to re-trigger the system vibration while the alert is
    /// active. The system vibrate pulse is brief (~0.4s), so we repeat it
    /// to keep buzzing for the life of the alarm.
    private let vibrationInterval: TimeInterval = 2.0

    /// Below this output volume the audio fallback is likely inaudible
    /// (e.g. ringer turned all the way down overnight). We can't raise the
    /// volume ourselves, so we log it loudly and lean on vibration.
    private let lowVolumeThreshold: Float = 0.30

    /// How long the alarm plays before stopping on its own. A short burst
    /// (a few loops of the ~0.84s tone) is attention-grabbing without being
    /// a runaway siren — the user-visible UNNotification persists, and the
    /// alert re-fires on the next critical-alert trigger if the condition
    /// holds.
    private let maxDuration: TimeInterval = 6

    /// True if we're currently looping audio for a critical alert.
    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Start (or restart) looping playback of a bundled critical alert
    /// sound. Safe to call repeatedly — replaces any current playback.
    /// `soundnamed` is a bundled `.caf` filename (the alarm's configured
    /// sound, e.g. "bloom.caf"); it lives in Loop's main bundle so it's
    /// always present. We resolve it directly from the bundle rather than
    /// AlertManager's AlertSoundVendor-keyed `Library/Sounds/` lookup.
    /// Falls back to `critical.caf` if the named file is missing.
    func play(soundNamed soundName: String = "critical.caf") {
        stop()

        // Vibration is volume-independent, so it's our primary "you missed
        // it" channel when the ringer is down. Start it up front and bound
        // everything (audio + vibration) to maxDuration, so the alarm still
        // buzzes even if audio setup below fails.
        startVibration()
        stopTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }

        let resource = (soundName as NSString).deletingPathExtension
        let ext = (soundName as NSString).pathExtension.isEmpty ? "caf" : (soundName as NSString).pathExtension
        let url = Bundle.main.url(forResource: resource, withExtension: ext)
            ?? Bundle.main.url(forResource: "critical", withExtension: "caf")
        guard let url else {
            os_log("Neither %{public}@ nor critical.caf found in main bundle; audio fallback unavailable", log: log, type: .error, soundName)
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // .playback ignores the silent switch and Focus modes. It must
            // be mixable, though: a critical alert usually fires while the
            // app is backgrounded/locked, and iOS refuses to activate a
            // NON-mixable session from the background — that's the
            // `AVAudioSessionErrorCodeCannotInterruptOthers` ('!int', 560557684)
            // "Session activation failed" we were hitting. .duckOthers +
            // .mixWithOthers makes activation succeed in the background and
            // ducks/mixes our alarm over any other audio instead of
            // failing outright. Mixable .playback still plays at full volume
            // when nothing else is active and still bypasses the silent switch.
            try session.setCategory(.playback, mode: .default, options: [.duckOthers, .mixWithOthers])
            try session.setActive(true, options: [])
            let volume = session.outputVolume
            os_log("Audio session active. category=%{public}@ otherAudioPlaying=%{public}@ outputVolume=%{public}.2f",
                   log: log, type: .info,
                   session.category.rawValue,
                   session.isOtherAudioPlaying ? "yes" : "no",
                   volume)
            if volume < lowVolumeThreshold {
                os_log("System volume is low (outputVolume=%{public}.2f); critical-alert audio may be inaudible — relying on vibration",
                       log: log, type: .error, volume)
            }

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
            os_log("Started critical-alert audio playback (duration=%{public}.2fs playing=%{public}@)",
                   log: log, type: .info, p.duration, p.isPlaying ? "yes" : "no")
        } catch {
            os_log("Failed to start audio playback: %{public}@", log: log, type: .error, String(describing: error))
        }
    }

    private func startVibration() {
        // Fire immediately, then repeat for the life of the alarm. On
        // devices without a vibration motor (e.g. iPad) this is a no-op.
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        vibrationTimer = Timer.scheduledTimer(withTimeInterval: vibrationInterval, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    /// Stop playback if any. Safe to call when not playing.
    func stop() {
        guard player != nil || stopTimer != nil || vibrationTimer != nil else { return }
        player?.stop()
        player = nil
        stopTimer?.invalidate()
        stopTimer = nil
        vibrationTimer?.invalidate()
        vibrationTimer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        os_log("Stopped critical-alert audio playback", log: log, type: .info)
    }
}
