import AVFoundation
import ForgeCore
import Foundation
import Observation
import os
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
final class HRZoneGuard: NSObject {
    static let shared = HRZoneGuard()

    enum ZoneState: Equatable { case unknown, below, inZone, above }

    private(set) var isActive = false
    private(set) var targetZone = 2
    private(set) var state: ZoneState = .unknown

    @ObservationIgnored private var lastCueAt = Date.distantPast
    @ObservationIgnored private var speakEnabled = true
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForgeFit", category: "HRZoneGuard")
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var wasInterrupted = false
    @ObservationIgnored private var interruptedUtterance: String?

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
        interruptedUtterance = nil
        wasInterrupted = false
        synthesizer.stopSpeaking(at: .immediate)
        deactivateSession()
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

        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(state == .inZone ? .success : .warning)
        #endif

        guard speakEnabled else {
            lastCueAt = now
            return
        }
        let phrase: String
        switch state {
        case .above: phrase = "Above zone \(targetZone)"
        case .below: phrase = "Below zone \(targetZone)"
        case .inZone: phrase = "Back in zone \(targetZone)"
        case .unknown: return
        }
        // Reserve the debounce window up front: activation is async now, so we
        // can't gate on its success synchronously. A rare activation failure
        // costs one quiet interval, not a burst of retries.
        lastCueAt = now
        speak(phrase)
    }

    private func speak(_ text: String) {
        // Duck music/podcasts briefly so the cue is audible, then mix back.
        // Activation runs off the main thread; the utterance waits for it inside
        // the task so it isn't clipped, and we stay silent if it fails.
        Task {
            do {
                try await AudioCueSession.shared.activate()
            } catch {
                logger.error("Failed to activate zone cue audio session: \(error.localizedDescription, privacy: .public)")
                return
            }
            interruptedUtterance = nil
            wasInterrupted = false
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
                logger.error("Failed to deactivate zone cue audio session: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated private static func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        Task { @MainActor in
            let guarder = HRZoneGuard.shared
            switch type {
            case .began:
                guarder.wasInterrupted = guarder.synthesizer.isSpeaking
            case .ended:
                guard guarder.isActive, guarder.wasInterrupted else { return }
                guarder.wasInterrupted = false
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                guard options.contains(.shouldResume) else { return }
                if guarder.synthesizer.isPaused {
                    // Reactivate before resuming the paused utterance; the
                    // replay branch lets `speak` own its own activation.
                    do {
                        try await AudioCueSession.shared.activate()
                    } catch {
                        guarder.logger.error("Failed to reactivate zone cue audio session: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                    guarder.synthesizer.continueSpeaking()
                } else if let text = guarder.interruptedUtterance {
                    guarder.interruptedUtterance = nil
                    guarder.speak(text)
                }
            @unknown default:
                break
            }
        }
    }
}

extension HRZoneGuard: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.synthesizer.isSpeaking {
                self.deactivateSession()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor in
            if self.wasInterrupted {
                self.interruptedUtterance = text
            }
            if !self.synthesizer.isSpeaking, !self.wasInterrupted {
                self.deactivateSession()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor in
            if self.wasInterrupted {
                self.interruptedUtterance = text
            }
        }
    }
}
