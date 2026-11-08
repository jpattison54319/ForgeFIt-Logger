import AVFoundation
import ForgeCore
import Testing
@testable import ForgeFit

@MainActor
struct WorkoutCueSpeechTests {
    @Test func replacementAndStopNeverDependOnACompletionCallback() async {
        let synth = CueSynthesizerSpy()
        let speech = WorkoutCueSpeech(synthesizer: synth)
        speech.speak("Above zone 2", replacingCurrent: true)
        speech.speak("Back in zone 2", replacingCurrent: true)
        #expect(synth.queued == ["Back in zone 2"])
        #expect(synth.applicationSessionFlags == [false, false])
        speech.stop()
        for _ in 0..<10 { await Task.yield() }
        #expect(synth.queued.isEmpty)
        #expect(synth.spoken == ["Above zone 2", "Back in zone 2"])
    }

    @Test func finishingCancelsBothSplitAndGoalWithoutALateActivation() async {
        let synth = CueSynthesizerSpy()
        let announcer = PaceAnnouncer(speech: WorkoutCueSpeech(synthesizer: synth))
        let wasEnabled = PaceAnnouncer.isEnabled
        PaceAnnouncer.isEnabled = true
        defer { PaceAnnouncer.isEnabled = wasEnabled }
        announcer.announceSplit(unitLabel: "Kilometer", index: 1, splitSeconds: 300, totalSeconds: nil)
        announcer.announceGoal("Distance goal complete")
        #expect(synth.queued.count == 2)
        announcer.stop()
        for _ in 0..<10 { await Task.yield() }
        #expect(synth.queued.isEmpty)
        #expect(synth.spoken.count == 2)
        #expect(synth.applicationSessionFlags.allSatisfy { !$0 })
    }

    @Test func heartRateTransitionsSpeakAndStoppingPreventsFurtherCues() async throws {
        let synth = CueSynthesizerSpy()
        let guarder = HRZoneGuard(speech: WorkoutCueSpeech(synthesizer: synth))
        let inZone = try #require((30...250).first { HRZone.config.zone(for: $0) == 2 })
        let above = try #require((30...250).first { HRZone.config.zone(for: $0) > 2 })
        guarder.activate(targetZone: 2)
        guarder.evaluate(hr: inZone)
        #expect(synth.spoken.isEmpty)
        guarder.evaluate(hr: above)
        #expect(synth.queued == ["Above zone 2"])
        guarder.setTarget(nil, speak: true)
        guarder.evaluate(hr: inZone)
        for _ in 0..<10 { await Task.yield() }
        #expect(synth.queued.isEmpty)
        #expect(!guarder.isActive)
        #expect(synth.spoken == ["Above zone 2"])
        // New intervals do not inherit the previous interval's debounce.
        guarder.activate(targetZone: 2)
        guarder.evaluate(hr: above)
        guarder.evaluate(hr: inZone)
        #expect(synth.queued == ["Back in zone 2"])
        #expect(synth.applicationSessionFlags == [false, false])
        guarder.deactivate()
    }

    @Test func paceGuardStopCannotCancelAnotherAnnouncersSpeech() {
        let paceSynth = CueSynthesizerSpy(), splitSynth = CueSynthesizerSpy()
        let guarder = PaceGuard(speech: WorkoutCueSpeech(synthesizer: paceSynth))
        let announcer = PaceAnnouncer(speech: WorkoutCueSpeech(synthesizer: splitSynth))
        guarder.activate(band: .init(metric: .pace, low: 300, high: 330))
        guarder.evaluate(paceSecondsPerKm: 310)
        guarder.evaluate(paceSecondsPerKm: 340)
        #expect(paceSynth.queued == ["Behind pace"])
        announcer.announceGoal("Distance goal complete")
        guarder.deactivate()
        #expect(paceSynth.queued.isEmpty)
        #expect(splitSynth.queued == ["Distance goal complete"])
        #expect(paceSynth.applicationSessionFlags == [false])
        #expect(splitSynth.applicationSessionFlags == [false])
        announcer.stop()
    }

    @Test func productionSynthesizerDelegatesAudioSessionLifetimeToTheSystem() {
        let synthesizer = AVSpeechSynthesizer()
        let speech = WorkoutCueSpeech(synthesizer: synthesizer)
        #expect(!synthesizer.usesApplicationAudioSession)
        speech.stop()
    }

    private final class CueSynthesizerSpy: WorkoutCueSynthesizing {
        var usesApplicationAudioSession = true
        var queued: [String] = []
        var spoken: [String] = []
        var applicationSessionFlags: [Bool] = []
        func speak(_ utterance: AVSpeechUtterance) {
            queued.append(utterance.speechString)
            spoken.append(utterance.speechString)
            applicationSessionFlags.append(usesApplicationAudioSession)
        }
        func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
            queued.removeAll()
            return true
        }
    }
}
