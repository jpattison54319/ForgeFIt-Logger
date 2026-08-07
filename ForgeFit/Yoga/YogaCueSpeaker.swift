import AVFoundation
import Foundation
import ForgeCore
import Observation

/// Spoken guidance for yoga classes. Cue scripts come from the bundled pose
/// catalog (our own authored content); this wrapper owns the synthesizer and
/// the audio-session dance:
///
/// - The session activates only around utterances (`.playback` +
///   `.duckOthers`) and deactivates with `.notifyOthersOnDeactivation` when
///   speech finishes, so the user's music ducks during a cue and restores
///   between poses — never ducked for the whole class.
/// - A phone-call interruption pauses the running class; the class resumes
///   only by the user's hand (a half-heard flow restarting itself mid-call
///   would be worse than staying paused).
///
/// Settings: "yogaVoiceCues" master toggle (default on), "yogaVoiceRate"
/// (default 0.45 — calm), "yogaVoiceID" (default system best).
@MainActor
final class YogaCueSpeaker: NSObject {
    static let shared = YogaCueSpeaker()

    private let synthesizer = AVSpeechSynthesizer()
    /// Round-robin position per pose slug so long classes don't repeat the
    /// same hold line back to back.
    private var holdLineCursor: [String: Int] = [:]
    private var interruptionObserver: NSObjectProtocol?

    private override init() {
        super.init()
        synthesizer.delegate = self
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            Self.handleInterruption(notification)
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: - Cue vocabulary

    /// Pose entry: name (+ side), then the catalog's entry lines.
    func speakEntry(for step: YogaFlowRunner.RuntimeStep, next: YogaFlowRunner.RuntimeStep?) {
        guard cuesEnabled else { return }
        var lines = [step.displayName]
        if let pose = YogaPoseCatalog.pose(forSlug: step.poseStep.poseSlug) {
            // Side switches skip the entry script — the lifter is already in
            // the shape; only the side changes.
            if step.side != .right || step.poseStep.side != .bothSides {
                lines.append(contentsOf: pose.cues.entry)
            } else {
                lines.append("Same pose, other side.")
            }
        } else if let cue = step.poseStep.transitionCue {
            lines.append(cue)
        }
        speak(lines)
    }

    /// Mid-hold: one rotating encouragement line from the catalog.
    func speakHold(for step: YogaFlowRunner.RuntimeStep) {
        guard cuesEnabled,
              let slug = step.poseStep.poseSlug,
              let pose = YogaPoseCatalog.pose(forSlug: slug),
              !pose.cues.hold.isEmpty else { return }
        let cursor = holdLineCursor[slug, default: 0]
        holdLineCursor[slug] = cursor + 1
        speak([pose.cues.hold[cursor % pose.cues.hold.count]])
    }

    /// T-minus-5: exit line plus what's coming.
    func speakTransitionWarning(current: YogaFlowRunner.RuntimeStep, next: YogaFlowRunner.RuntimeStep?) {
        guard cuesEnabled else { return }
        var lines: [String] = []
        if let pose = YogaPoseCatalog.pose(forSlug: current.poseStep.poseSlug) {
            lines.append(pose.cues.exit)
        } else {
            lines.append("Last breath here.")
        }
        if let next {
            lines.append("Next: \(next.displayName).")
        } else {
            lines.append("This is your final pose.")
        }
        speak(lines)
    }

    func speakCompletion() {
        guard cuesEnabled else { return }
        speak(["Your practice is complete. Notice how you feel."])
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivateSession()
    }

    // MARK: - Engine

    private var cuesEnabled: Bool {
        UserDefaults.standard.object(forKey: "yogaVoiceCues") as? Bool ?? true
    }

    private func speak(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        // `.playback` (not ambient) so cues keep speaking with the screen
        // locked; `.duckOthers` dips the user's own music underneath. Activate
        // before enqueuing so the music has ducked and the route is up by the
        // time the first word plays — off the main thread so the blocking
        // activation can't stall the running class's timers.
        Task {
            try? await AudioCueSession.shared.activate()
            let rate = (UserDefaults.standard.object(forKey: "yogaVoiceRate") as? Float) ?? 0.45
            let voice = (UserDefaults.standard.string(forKey: "yogaVoiceID"))
                .flatMap(AVSpeechSynthesisVoice.init(identifier:))
                ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
            for (index, line) in lines.enumerated() {
                let utterance = AVSpeechUtterance(string: line)
                utterance.rate = rate
                utterance.voice = voice
                utterance.preUtteranceDelay = index == 0 ? 0.05 : 0.35
                synthesizer.speak(utterance)
            }
        }
    }

    private func deactivateSession() {
        // Never deactivate while another speaker (zone guard) might be mid-
        // sentence; stopping our own queue is enough. Deactivation with
        // notify restores the user's music to full volume.
        Task { try? await AudioCueSession.shared.deactivate() }
    }

    nonisolated private static func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        if type == .began {
            // A call (or Siri) took the audio: pause the class where it
            // stands. Resuming is a deliberate user action.
            Task { @MainActor in
                YogaFlowRunnerHub.shared.runner?.pause()
            }
        }
    }
}

extension YogaCueSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // Only release the session once the queue is fully drained.
            if !self.synthesizer.isSpeaking {
                self.deactivateSession()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.synthesizer.isSpeaking {
                self.deactivateSession()
            }
        }
    }
}
