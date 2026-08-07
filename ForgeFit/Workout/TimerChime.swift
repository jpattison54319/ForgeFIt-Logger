import AVFoundation
import Foundation
import OSLog

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
    private var playbackTask: Task<Void, Never>?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForgeFit",
        category: "TimerChime"
    )

    func play() {
        guard Self.isEnabled,
              let url = Bundle.main.url(forResource: "ForgeTimerChime", withExtension: "caf") else { return }
        stop()
        // Activate off the main thread (setActive can block on a Bluetooth
        // handoff), then build and play the chime. `.default` mode — this is a
        // sound, not speech. If the player won't load, release the session so
        // other audio doesn't stay ducked.
        playbackTask = Task {
            do {
                try await AudioCueSession.shared.activate(mode: .default)
            } catch {
                logger.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard !Task.isCancelled else {
                try? await AudioCueSession.shared.deactivate()
                return
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                guard !Task.isCancelled else {
                    try? await AudioCueSession.shared.deactivate()
                    return
                }
                self.player = player
                player.delegate = self
                player.volume = 0.9
                guard player.play() else {
                    self.player = nil
                    logger.error("AVAudioPlayer declined to start the timer chime")
                    try? await AudioCueSession.shared.deactivate()
                    return
                }
            } catch {
                logger.error("Timer chime player failed: \(error.localizedDescription, privacy: .public)")
                try? await AudioCueSession.shared.deactivate()
            }
        }
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        player?.stop()
        player = nil
        Task { try? await AudioCueSession.shared.deactivate() }
    }

    /// Un-duck other audio the moment the chime finishes.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player {
                self.player = nil
            }
            try? await AudioCueSession.shared.deactivate()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            if self.player === player {
                self.player = nil
            }
            if let error {
                self.logger.error("Timer chime decode failed: \(error.localizedDescription, privacy: .public)")
            }
            try? await AudioCueSession.shared.deactivate()
        }
    }
}
