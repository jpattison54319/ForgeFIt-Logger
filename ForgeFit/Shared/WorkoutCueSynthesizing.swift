import AVFoundation

@MainActor
protocol WorkoutCueSynthesizing: AnyObject {
    var usesApplicationAudioSession: Bool { get set }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: WorkoutCueSynthesizing {}
