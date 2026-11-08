import AVFoundation
import ForgeCore
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Watches the live rolling pace against a target band and cues when the
/// athlete drifts out and when they come back — haptic plus a short spoken
/// phrase, same discipline as `HRZoneGuard`. Numerically-below-band means
/// FASTER than target, so the spoken vocabulary is ahead/behind, never
/// raw comparisons.
///
/// Fed by `IntervalRunner`'s poll loop (the only place with a live distance
/// feed), so it needs no hook in the app-level metrics handler. Speech
/// interruptions use the system's audio-session lifecycle.
@MainActor
@Observable
final class PaceGuard: NSObject {
    static let shared = PaceGuard()

    enum PaceState: Equatable { case unknown, ahead, onPace, behind }

    private(set) var isActive = false
    private(set) var band: IntervalPlan.Target?
    private(set) var state: PaceState = .unknown

    /// Pace bounces more than HR at a boundary; a longer quiet period keeps
    /// the guard from narrating GPS jitter.
    private static let debounceSeconds: TimeInterval = 8

    @ObservationIgnored private var lastCueAt = Date.distantPast
    @ObservationIgnored private var speakEnabled = true
    @ObservationIgnored private let speech: WorkoutCueSpeech

    init(speech: WorkoutCueSpeech? = nil) {
        self.speech = speech ?? WorkoutCueSpeech()
        super.init()
    }

    func activate(band: IntervalPlan.Target, speak: Bool = true) {
        guard band.metric == .pace, band.isMeaningful else { return }
        speech.stop()
        lastCueAt = .distantPast
        self.band = band
        speakEnabled = speak
        state = .unknown
        isActive = true
    }

    func deactivate() {
        isActive = false
        band = nil
        state = .unknown
        speech.stop()
    }

    /// Classify the latest rolling pace (seconds per km) and cue on real
    /// transitions. A nil pace (stopped, no feed) resets to unknown quietly.
    func evaluate(paceSecondsPerKm: Double?) {
        guard isActive, let band else { return }
        guard let pace = paceSecondsPerKm else {
            state = .unknown
            return
        }
        let newState: PaceState
        switch band.classify(pace) {
        case .below: newState = .ahead     // faster than the band
        case .within: newState = .onPace
        case .above: newState = .behind    // slower than the band
        }
        guard newState != state else { return }
        let previous = state
        state = newState
        guard previous != .unknown else { return }
        cue(for: newState)
    }

    private func cue(for state: PaceState) {
        let now = Date()
        guard now.timeIntervalSince(lastCueAt) >= Self.debounceSeconds else { return }

        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(state == .onPace ? .success : .warning)
        #endif

        guard speakEnabled else {
            lastCueAt = now
            return
        }
        let phrase: String
        switch state {
        case .ahead: phrase = "Ahead of pace"
        case .behind: phrase = "Behind pace"
        case .onPace: phrase = "On pace"
        case .unknown: return
        }
        lastCueAt = now
        speech.speak(phrase, replacingCurrent: true)
    }
}
