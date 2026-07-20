import AVFoundation
import Foundation

/// Plays ForgeFit's signature timer-end sound — the "forge strike", two
/// anvil-like metallic notes a rising fifth apart (rest's done → go lift),
/// synthesized for this app (Resources/ForgeTimerChime.caf).
///
/// Delivery matches the rest timer's two paths:
/// - Foreground: this player. `.playback` + `.duckOthers` briefly dips
///   Spotify/podcasts instead of stopping them, follows the active route
///   (speaker or earbuds), and stays audible with the ringer switch off —
///   gym phones live on silent. The session is only active around the chime
///   (same discipline as YogaCueSpeaker), then released so other audio
///   returns to full volume.
/// - Locked/background: the rest-end notification carries the same .caf
///   (NotificationScheduler), so the identity is identical on the lock
///   screen. The watch buzzes via its own scheduled haptic (WatchStore).
@MainActor
final class TimerChime: NSObject, AVAudioPlayerDelegate {
    static let shared = TimerChime()

    /// User toggle (Settings): default on.
    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "timerSoundEnabled") == nil
                || UserDefaults.standard.bool(forKey: "timerSoundEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "timerSoundEnabled") }
    }

    nonisolated static let soundFileName = "ForgeTimerChime.caf"

    private var player: AVAudioPlayer?

    func play() {
        guard Self.isEnabled,
              let url = Bundle.main.url(forResource: "ForgeTimerChime", withExtension: "caf") else { return }
        // Activate off the main thread (setActive can block on a Bluetooth
        // handoff), then build and play the chime. `.default` mode — this is a
        // sound, not speech. If the player won't load, release the session so
        // other audio doesn't stay ducked.
        Task {
            try? await AudioCueSession.shared.activate(mode: .default)
            guard let player = try? AVAudioPlayer(contentsOf: url) else {
                try? await AudioCueSession.shared.deactivate()
                return
            }
            self.player = player
            player.delegate = self
            player.volume = 0.9
            player.play()
        }
    }

    /// Un-duck other audio the moment the chime finishes.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            try? await AudioCueSession.shared.deactivate()
        }
    }
}
