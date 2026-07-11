import AVFoundation
import ForgeCore
import Foundation

/// Speaks split announcements during outdoor cardio ("Kilometer 3. Split
/// 5 minutes 12 seconds.") — locked phone and earbuds included, since the
/// route recorder keeps running in background. Same audio-session
/// discipline as YogaCueSpeaker: `.duckOthers` dips music around the
/// utterance only, then releases so it recovers to full volume.
@MainActor
final class PaceAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = PaceAnnouncer()

    /// User toggle (Settings): default on — a silent run tracker that knows
    /// your splits and says nothing is leaving value on the table; the
    /// toggle is there for people who run to podcasts.
    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "paceAnnouncementsEnabled") == nil
                || UserDefaults.standard.bool(forKey: "paceAnnouncementsEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "paceAnnouncementsEnabled") }
    }

    private let synthesizer = AVSpeechSynthesizer()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func announceSplit(unitLabel: String, index: Int, splitSeconds: Int, totalSeconds: Int?) {
        guard Self.isEnabled else { return }
        let phrase = PaceAnnouncement.phrase(
            unitLabel: unitLabel, index: index,
            splitSeconds: splitSeconds, totalSeconds: totalSeconds
        )
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.synthesizer.isSpeaking else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}
