import AVFoundation
import ForgeCore
import Foundation

/// Speaks split announcements during outdoor cardio ("Kilometer 3. Split
/// 5 minutes 12 seconds.") — locked phone and earbuds included, since the
/// route recorder keeps running in background. Speech's system-managed
/// session ducks other audio around the utterance.
@MainActor
final class PaceAnnouncer {
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

    private let speech: WorkoutCueSpeech

    init(speech: WorkoutCueSpeech? = nil) {
        self.speech = speech ?? WorkoutCueSpeech()
    }

    func announceSplit(unitLabel: String, index: Int, splitSeconds: Int, totalSeconds: Int?) {
        guard Self.isEnabled else { return }
        let phrase = PaceAnnouncement.phrase(
            unitLabel: unitLabel, index: index,
            splitSeconds: splitSeconds, totalSeconds: totalSeconds
        )
        enqueue(phrase)
    }

    /// Goal completion is independent of the optional split-announcement
    /// setting: explicitly choosing a session target arms its one-time voice
    /// confirmation. Sharing this synthesizer keeps a finish-line goal from
    /// talking over a split that was queued a moment earlier.
    func announceGoal(_ phrase: String) {
        enqueue(phrase)
    }

    private func enqueue(_ phrase: String) {
        speech.speak(phrase)
    }

    func stop() {
        speech.stop()
    }
}
