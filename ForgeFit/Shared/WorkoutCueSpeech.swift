import AVFoundation

/// Speech owns a system-managed session. Its completion, cancellation, and
/// interruptions release ducking independently of the app's chimes/players.
/// Enqueue and stop are synchronous so a suspended activation cannot speak
/// after the workout or guard has stopped.
@MainActor
final class WorkoutCueSpeech {
    private let synthesizer: any WorkoutCueSynthesizing

    init(synthesizer: any WorkoutCueSynthesizing = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        synthesizer.usesApplicationAudioSession = false
    }

    func speak(_ text: String, replacingCurrent: Bool = false) {
        if replacingCurrent { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = false
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
