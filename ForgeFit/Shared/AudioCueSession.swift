import AVFoundation
import Foundation

/// Off-main-thread gate for the shared `AVAudioSession` that every voice/chime
/// cue rides on (yoga cues, pace announcements, HR/pace zone guards, the rest
/// timer chime).
///
/// `setActive` does synchronous cross-process IPC that can block ~100ms+ while
/// CoreAudio negotiates a Bluetooth route. On the main actor that stalls the
/// run loop mid-workout, right when live timers and rings are animating — the
/// source of the "may lead to UI unresponsiveness if called on the main thread"
/// runtime warning. `AVAudioSession` is thread-safe, so the category setup and
/// (de)activation run on a private serial queue instead:
///
/// - **Serial** so an activate can never overtake the deactivate that should
///   precede it (or vice versa); requests run in the order callers await them.
/// - **Its own queue**, not the cooperative pool, so the blocking IPC never
///   starves Swift concurrency.
///
/// Callers keep ownership of *when* to activate/deactivate and of the ordering
/// against their own synthesizer/player (activate → speak so the first word
/// isn't clipped; deactivate with `.notifyOthersOnDeactivation` once speech
/// drains so ducked music recovers). This type owns only the blocking syscall.
final class AudioCueSession: Sendable {
    static let shared = AudioCueSession()

    private let queue = DispatchQueue(label: "com.forgefit.audio-cue-session", qos: .userInitiated)

    private init() {}

    /// Configure `.playback` + `.duckOthers` and activate the session. `mode` is
    /// `.spokenAudio` for voice cues and `.default` for the timer chime. Throws
    /// the underlying `AVAudioSession` error so voice-gated callers can bail.
    func activate(mode: AVAudioSession.Mode = .spokenAudio) async throws {
        try await run {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: mode, options: [.duckOthers, .mixWithOthers])
            try session.setActive(true)
        }
    }

    /// Release the session with `.notifyOthersOnDeactivation` so the user's
    /// ducked music/podcast returns to full volume.
    func deactivate() async throws {
        try await run {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    /// Hop `work` onto the serial queue and await its completion, so the
    /// blocking `AVAudioSession` calls never touch the main thread.
    private func run(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
