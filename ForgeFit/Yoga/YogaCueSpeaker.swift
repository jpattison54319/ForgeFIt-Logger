import AVFoundation
import Foundation
import ForgeCore
import Observation

struct YogaAudioManifest: Decodable, Sendable {
    struct VoiceSelection: Decodable, Sendable {
        let female: String?
        let male: String?
    }

    struct Clip: Decodable, Sendable {
        let id: String
        let instructor: YogaInstructor
        let voice: String
        let filename: String
        let durationSeconds: TimeInterval
        let sha256: String
        let transcript: String
        let generationID: String?
    }

    let schemaVersion: Int
    let contentVersion: String
    let status: String
    let model: String
    let voices: VoiceSelection
    let voiceApproval: String?
    let listeningApproval: String?
    let clips: [Clip]
}

/// Immutable lookup for build-time-generated narration. `status == approved`
/// means both instructor libraries passed the generation verifier and were
/// explicitly selected after an audition. Any missing asset falls back to an
/// on-device system voice using the same reviewed transcript.
enum YogaAudioLibrary {
    private struct ApprovedIndex {
        let clipsByKey: [String: YogaAudioManifest.Clip]
        let measuredDurations: [String: TimeInterval]
    }

    static let manifest: YogaAudioManifest? = {
        guard let url = Bundle.main.url(forResource: "yoga_audio_manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(YogaAudioManifest.self, from: data) else {
            return nil
        }
        return decoded
    }()

    private static let approvedIndex: ApprovedIndex? = makeApprovedIndex(manifest)

    private static func makeApprovedIndex(_ manifest: YogaAudioManifest?) -> ApprovedIndex? {
        guard let manifest,
              manifest.schemaVersion == YogaGuidanceCatalog.expectedSchemaVersion,
              manifest.contentVersion == YogaGuidanceCatalog.contentVersion,
              manifest.status == "approved",
              manifest.model == "google/gemini-3.1-flash-tts-preview",
              manifest.voiceApproval?.isEmpty == false,
              manifest.listeningApproval?.isEmpty == false,
              let femaleVoice = manifest.voices.female, !femaleVoice.isEmpty,
              let maleVoice = manifest.voices.male, !maleVoice.isEmpty else {
            return nil
        }

        let expected = expectedTranscripts
        guard !expected.isEmpty else { return nil }
        var clipsByKey: [String: YogaAudioManifest.Clip] = [:]
        for instructor in YogaInstructor.allCases {
            let selectedVoice = instructor == .female ? femaleVoice : maleVoice
            let clips = manifest.clips.filter { $0.instructor == instructor }
            guard clips.count == expected.count,
                  Set(clips.map(\.id)) == Set(expected.keys),
                  clips.allSatisfy({ clip in
                      clip.voice == selectedVoice
                          && clip.transcript == expected[clip.id]
                          && clip.durationSeconds > 0
                          && clip.sha256.count == 64
                          && clip.filename.hasSuffix(".mp3")
                          && !clip.filename.contains("/")
                  }) else {
                return nil
            }
            for clip in clips {
                clipsByKey[indexKey(id: clip.id, instructor: instructor)] = clip
            }
        }
        let durations = Dictionary(grouping: manifest.clips, by: \.id).mapValues { entries in
            entries.map(\.durationSeconds).max() ?? 0
        }
        return ApprovedIndex(clipsByKey: clipsByKey, measuredDurations: durations)
    }

    /// Test seam proving the exact bundled transcript catalog can be indexed
    /// before a release manifest is marked approved.
    static func validatesForPlayback(_ manifest: YogaAudioManifest) -> Bool {
        makeApprovedIndex(manifest) != nil
    }

    static var isApproved: Bool { approvedIndex != nil }

    static var measuredDurations: [String: TimeInterval] {
        approvedIndex?.measuredDurations ?? [:]
    }

    static func clip(id: String, instructor: YogaInstructor) -> YogaAudioManifest.Clip? {
        approvedIndex?.clipsByKey[indexKey(id: id, instructor: instructor)]
    }

    private static func indexKey(id: String, instructor: YogaInstructor) -> String {
        "\(instructor.rawValue)|\(id)"
    }

    private static var expectedTranscripts: [String: String] {
        var result: [String: String] = [:]
        for pose in YogaPoseCatalog.load() {
            let sides: [YogaFlowPlan.Side?] = pose.unilateral ? [.left, .right] : [nil]
            for side in sides {
                let context = YogaGuidancePlanningContext(
                    poseSlug: pose.slug,
                    poseName: pose.name,
                    side: side,
                    holdSeconds: pose.defaultHoldSeconds,
                    style: .hatha
                )
                for clip in YogaGuidancePlanner.poseClips(
                    context: context,
                    guidance: YogaGuidanceCatalog.guidance(forSlug: pose.slug)
                ) {
                    result[clip.id] = clip.text
                }
            }
        }

        if let global = YogaGuidanceCatalog.global {
            let groups: [(YogaGuidanceKind, [String])] = [
                (.opening, global.openings),
                (.breath, global.breath),
                (.awareness, global.awareness),
                (.encouragement, global.encouragement),
                (.spiritual, global.spiritual),
                (.closing, global.closings),
            ]
            for (kind, lines) in groups {
                for (index, line) in lines.enumerated() {
                    result["global.\(kind.rawValue).\(index)"] = line
                }
            }
        }
        return result
    }
}

/// Offline guided-yoga audio with a transcript-identical system fallback.
/// The selected `YogaInstructor` controls both pose art and narration. Audio
/// activates only around a clip so the user's music ducks briefly and returns
/// between the deliberately silent portions of class.
@MainActor
@Observable
final class YogaGuidanceAudio: NSObject {
    static let shared = YogaGuidanceAudio()

    private(set) var currentCaption: String?
    private(set) var currentKind: YogaGuidanceKind?
    private(set) var isSpeaking = false
    private(set) var isUsingBundledNarration = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var activeUtterance: AVSpeechUtterance?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

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

    func play(_ clip: YogaGuidanceClip, voiceEnabled: Bool = true) {
        stopPlayback(clearCaption: false, deactivate: false)
        currentCaption = clip.text
        currentKind = clip.kind
        guard voiceEnabled else {
            isSpeaking = false
            isUsingBundledNarration = false
            deactivateSession()
            return
        }

        let instructor = YogaInstructor.resolved(
            from: UserDefaults.standard.string(forKey: YogaInstructor.preferenceKey)
                ?? YogaInstructor.female.rawValue
        )

        if let asset = YogaAudioLibrary.clip(id: clip.id, instructor: instructor),
           let url = Bundle.main.url(
               forResource: asset.filename,
               withExtension: nil,
               subdirectory: "YogaAudio"
           ) ?? Bundle.main.url(forResource: asset.filename, withExtension: nil),
           let audioPlayer = try? AVAudioPlayer(contentsOf: url) {
            player = audioPlayer
            audioPlayer.delegate = self
            audioPlayer.prepareToPlay()
            isSpeaking = true
            isUsingBundledNarration = true
            Task { @MainActor [weak self, weak audioPlayer] in
                try? await AudioCueSession.shared.activate()
                guard let self, let audioPlayer, self.player === audioPlayer else { return }
                if !audioPlayer.play() {
                    self.speakWithSystemVoice(clip.text, instructor: instructor)
                }
            }
        } else {
            speakWithSystemVoice(clip.text, instructor: instructor)
        }
    }

    func stop(clearCaption: Bool = false) {
        stopPlayback(clearCaption: clearCaption, deactivate: true)
    }

    private func speakWithSystemVoice(_ text: String, instructor: YogaInstructor) {
        player = nil
        isSpeaking = true
        isUsingBundledNarration = false
        Task { @MainActor [weak self] in
            try? await AudioCueSession.shared.activate()
            guard let self, !self.synthesizer.isSpeaking else { return }
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = 0.43
            utterance.voice = self.systemVoice(for: instructor)
            utterance.preUtteranceDelay = 0.03
            utterance.postUtteranceDelay = 0.08
            self.activeUtterance = utterance
            self.synthesizer.speak(utterance)
        }
    }

    private func systemVoice(for instructor: YogaInstructor) -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en") && $0.gender == instructor.systemVoiceGender
        }
        return english.sorted { lhs, rhs in
            let lhsIsUS = lhs.language == "en-US"
            let rhsIsUS = rhs.language == "en-US"
            if lhsIsUS != rhsIsUS { return lhsIsUS }
            if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
            return lhs.language < rhs.language
        }.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func stopPlayback(clearCaption: Bool, deactivate: Bool) {
        player?.stop()
        player = nil
        activeUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isUsingBundledNarration = false
        if clearCaption {
            currentCaption = nil
            currentKind = nil
        }
        if deactivate {
            deactivateSession()
        }
    }

    private func finishedSpeaking() {
        isSpeaking = false
        isUsingBundledNarration = false
        player = nil
        activeUtterance = nil
        deactivateSession()
    }

    private func deactivateSession() {
        Task { try? await AudioCueSession.shared.deactivate() }
    }

    nonisolated private static func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw),
              type == .began else { return }
        Task { @MainActor in
            YogaFlowRunnerHub.shared.runner?.pause()
        }
    }
}

extension YogaGuidanceAudio: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.finishedSpeaking()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.finishedSpeaking()
        }
    }
}

extension YogaGuidanceAudio: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.activeUtterance.map(ObjectIdentifier.init) == utteranceID,
                  !self.synthesizer.isSpeaking else { return }
            self.finishedSpeaking()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.activeUtterance.map(ObjectIdentifier.init) == utteranceID,
                  !self.synthesizer.isSpeaking else { return }
            self.finishedSpeaking()
        }
    }
}

private extension YogaInstructor {
    var systemVoiceGender: AVSpeechSynthesisVoiceGender {
        switch self {
        case .female: .female
        case .male: .male
        }
    }
}
