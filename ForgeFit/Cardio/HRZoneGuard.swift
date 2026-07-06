import AVFoundation
import ForgeCore
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Watches the live heart rate during a "zone lock" cardio session and fires a
/// cue when the athlete leaves the target zone (above or below) and when they
/// return to it — a haptic plus a spoken phrase ("above zone 2", "back in zone")
/// so it lands even with the phone pocketed. The Apple Watch runs its own
/// lower-latency haptic guard; this is the phone side that adds the voice.
@MainActor
@Observable
final class HRZoneGuard {
    static let shared = HRZoneGuard()

    enum ZoneState: Equatable { case unknown, below, inZone, above }

    private(set) var isActive = false
    private(set) var targetZone = 2
    private(set) var state: ZoneState = .unknown

    @ObservationIgnored private var lastCueAt = Date.distantPast
    @ObservationIgnored private var speakEnabled = true
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    /// Begin guarding a target zone. `speak` adds the spoken voice cue on top of
    /// the haptic.
    func activate(targetZone: Int, speak: Bool = true) {
        self.targetZone = max(1, min(5, targetZone))
        speakEnabled = speak
        state = .unknown
        isActive = true
    }

    func deactivate() {
        isActive = false
        state = .unknown
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Classify the latest HR and cue on any state transition. Called from the
    /// app-level live-HR handler so it works regardless of which screen is up.
    func evaluate(hr: Int?) {
        guard isActive, let hr, hr > 0 else { return }
        let zone = HRZone.config.zone(for: hr)
        let newState: ZoneState = zone < targetZone ? .below : (zone > targetZone ? .above : .inZone)
        guard newState != state else { return }
        let previous = state
        state = newState
        // Don't cue the initial classification — only real transitions.
        guard previous != .unknown else { return }
        cue(for: newState)
    }

    private func cue(for state: ZoneState) {
        // Debounce so HR bouncing across a boundary doesn't chatter.
        let now = Date()
        guard now.timeIntervalSince(lastCueAt) >= 4 else { return }
        lastCueAt = now

        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(state == .inZone ? .success : .warning)
        #endif

        guard speakEnabled else { return }
        let phrase: String
        switch state {
        case .above: phrase = "Above zone \(targetZone)"
        case .below: phrase = "Below zone \(targetZone)"
        case .inZone: phrase = "Back in zone \(targetZone)"
        case .unknown: return
        }
        speak(phrase)
    }

    private func speak(_ text: String) {
        // Duck music/podcasts briefly so the cue is audible, then mix back.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        synthesizer.speak(utterance)
    }
}
