import AVFoundation
import ForgeCore
import Foundation
import Observation
import os
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
/// feed), so it needs no hook in the app-level metrics handler. Unlike the
/// zone guard it does not resume an interrupted utterance — a pace cue is
/// stale two seconds after it mattered.
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
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForgeFit", category: "PaceGuard")

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func activate(band: IntervalPlan.Target, speak: Bool = true) {
        guard band.metric == .pace, band.isMeaningful else { return }
        self.band = band
        speakEnabled = speak
        state = .unknown
        isActive = true
    }

    func deactivate() {
        isActive = false
        band = nil
        state = .unknown
        synthesizer.stopSpeaking(at: .immediate)
        deactivateSession()
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
        // Reserve the debounce window up front: activation is async now, so we
        // can't gate on its success synchronously. A rare activation failure
        // costs one quiet interval, not a burst of retries.
        lastCueAt = now
        speak(phrase)
    }

    private func speak(_ text: String) {
        // Activation runs off the main thread; the utterance waits for it inside
        // the task so it isn't clipped, and we stay silent if it fails.
        Task {
            do {
                try await AudioCueSession.shared.activate()
            } catch {
                logger.error("Failed to activate pace cue audio session: \(error.localizedDescription, privacy: .public)")
                return
            }
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
            let utterance = AVSpeechUtterance(string: text)
            utterance.postUtteranceDelay = 0
            synthesizer.speak(utterance)
        }
    }

    private func deactivateSession() {
        Task {
            do {
                try await AudioCueSession.shared.deactivate()
            } catch {
                logger.error("Failed to deactivate pace cue audio session: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension PaceGuard: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.synthesizer.isSpeaking {
                self.deactivateSession()
            }
        }
    }
}
