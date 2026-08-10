import Foundation
import ForgeCore

enum YogaGuidanceKind: String, Codable, Sendable, CaseIterable {
    case poseName
    case entry
    case alignment
    case breath
    case option
    case reflection
    case opening
    case awareness
    case encouragement
    case spiritual
    case exit
    case closing

}

struct YogaGuidanceClip: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let kind: YogaGuidanceKind
    let poseSlug: String?

    var isVariableFiller: Bool {
        if kind == .reflection { return true }
        guard poseSlug == nil else { return false }
        switch kind {
        case .opening, .breath, .awareness, .encouragement, .spiritual, .closing:
            return true
        case .poseName, .entry, .alignment, .option, .reflection, .exit:
            return false
        }
    }
}

struct YogaScheduledCue: Identifiable, Equatable, Sendable {
    var id: String { clip.id }
    let offset: TimeInterval
    let clip: YogaGuidanceClip
    let estimatedDuration: TimeInterval
}

struct YogaGuidancePlan: Equatable, Sendable {
    let holdSeconds: Int
    let cues: [YogaScheduledCue]

    var clipIDs: [String] { cues.map(\.clip.id) }
}

struct YogaGuidancePlanningContext: Sendable {
    let poseSlug: String?
    let poseName: String
    let side: YogaFlowPlan.Side?
    let holdSeconds: Int
    let style: YogaStyle
    let customTransitionCue: String?
    let isFirstStep: Bool

    init(
        poseSlug: String?,
        poseName: String,
        side: YogaFlowPlan.Side?,
        holdSeconds: Int,
        style: YogaStyle,
        customTransitionCue: String? = nil,
        isFirstStep: Bool = false
    ) {
        self.poseSlug = poseSlug
        self.poseName = poseName
        self.side = side
        self.holdSeconds = holdSeconds
        self.style = style
        self.customTransitionCue = customTransitionCue
        self.isFirstStep = isFirstStep
    }
}

/// Turns approved modular lines into a deterministic class timeline. The
/// planner prioritizes pose setup and safe exit, adds refinement only when it
/// fits, deliberately leaves silence, and varies lower-priority guidance using
/// a session seed plus a bounded history of recently used clips.
enum YogaGuidancePlanner {
    private static let interClipPause: TimeInterval = 0.8
    private static let endingBuffer: TimeInterval = 0.5

    /// Smallest whole-second hold that can play the pose name, the canonical
    /// self-contained entry (`entry.0`), and the deliberate exit without
    /// clipping or overlap. Longer entry lines are optional refinements.
    /// Flow generation and editing use this contract so a short class never
    /// drops the instruction that actually establishes the pose.
    static func minimumCriticalHoldSeconds(
        context: YogaGuidancePlanningContext,
        measuredDurations: [String: TimeInterval] = [:]
    ) -> Int? {
        let clips = poseClips(
            context: context,
            guidance: YogaGuidanceCatalog.guidance(forSlug: context.poseSlug)
        )
        guard let name = clips.first(where: { $0.kind == .poseName }),
              let primaryEntry = clips.first(where: { $0.kind == .entry }),
              let exit = clips.first(where: { $0.kind == .exit }) else {
            return nil
        }
        let spoken = [name, primaryEntry, exit]
            .reduce(0) { $0 + duration(for: $1, measured: measuredDurations) }
        let pauses = interClipPause * 2
        return max(1, Int(ceil(spoken + pauses + endingBuffer)))
    }

    static func minimumCriticalHoldSeconds(
        poseSlug: String?,
        poseName: String,
        side: YogaFlowPlan.Side?,
        measuredDurations: [String: TimeInterval] = YogaAudioLibrary.measuredDurations
    ) -> Int? {
        minimumCriticalHoldSeconds(
            context: YogaGuidancePlanningContext(
                poseSlug: poseSlug,
                poseName: poseName,
                side: side,
                holdSeconds: 1,
                style: .hatha
            ),
            measuredDurations: measuredDurations
        )
    }

    static func minimumCriticalHoldSeconds(
        for step: YogaFlowPlan.PoseStep,
        measuredDurations: [String: TimeInterval] = YogaAudioLibrary.measuredDurations
    ) -> Int? {
        let sides: [YogaFlowPlan.Side?]
        switch step.side {
        case .bothSides: sides = [.left, .right]
        case .left: sides = [.left]
        case .right: sides = [.right]
        case nil: sides = [nil]
        }
        return sides.compactMap { side in
            minimumCriticalHoldSeconds(
                poseSlug: step.poseSlug,
                poseName: step.name,
                side: side,
                measuredDurations: measuredDurations
            )
        }.max()
    }

    static func plan(
        context: YogaGuidancePlanningContext,
        sessionSeed: UInt64,
        stepIndex: Int,
        excludedClipIDs: Set<String> = [],
        measuredDurations: [String: TimeInterval] = [:]
    ) -> YogaGuidancePlan {
        let hold = TimeInterval(max(1, context.holdSeconds))
        let guidance = YogaGuidanceCatalog.guidance(forSlug: context.poseSlug)
        let allPoseClips = poseClips(context: context, guidance: guidance)
        let exit = allPoseClips.first { $0.kind == .exit }
        let exitDuration = exit.map { duration(for: $0, measured: measuredDurations) } ?? 0
        let exitOffset = exit.map { _ in max(0, hold - exitDuration - endingBuffer) }

        var scheduled: [YogaScheduledCue] = []
        var cursor: TimeInterval = 0

        @discardableResult
        func appendIfFits(_ clip: YogaGuidanceClip, preferredGap: TimeInterval) -> Bool {
            let clipDuration = duration(for: clip, measured: measuredDurations)
            let latestEnd = (exitOffset ?? hold - endingBuffer) - (exit == nil ? 0 : interClipPause)
            let offset = scheduled.isEmpty ? 0 : cursor + preferredGap
            guard offset + clipDuration <= latestEnd else { return false }
            scheduled.append(YogaScheduledCue(
                offset: offset,
                clip: clip,
                estimatedDuration: clipDuration
            ))
            cursor = offset + clipDuration
            return true
        }

        // Valid authored/generated holds always have room for name, canonical
        // setup, and exit. For a legacy custom hold below that contract,
        // actionable setup outranks repeating the name already shown on screen.
        let criticalMinimum = minimumCriticalHoldSeconds(
            context: context,
            measuredDurations: measuredDurations
        )
        let canFitCompleteCriticalSet = criticalMinimum.map { context.holdSeconds >= $0 } ?? true
        let nameClips = allPoseClips.filter { $0.kind == .poseName }
        let entryClips = allPoseClips.filter { $0.kind == .entry }
        if canFitCompleteCriticalSet {
            for clip in nameClips {
                appendIfFits(clip, preferredGap: 0)
            }
        }
        if let primaryEntry = entryClips.first {
            appendIfFits(primaryEntry, preferredGap: scheduled.isEmpty ? 0 : interClipPause)
            if scheduled.contains(where: { $0.clip.id == primaryEntry.id }) {
                for clip in entryClips.dropFirst() {
                    appendIfFits(clip, preferredGap: interClipPause)
                }
            }
        }

        let hasAuthoredEntry = !entryClips.isEmpty
        let didScheduleEntry = entryClips.first.map { primaryEntry in
            scheduled.contains { $0.clip.id == primaryEntry.id }
        } ?? false

        // The first refinement belongs with setup, so it follows promptly.
        // After that, alternate modular instructor guidance with refinements
        // instead of letting every technical cue consume the hold first.
        // Canonical entry.0 is self-contained; any additional entry lines are
        // optional refinements and join the cycle after alignment/breath/options.
        let refinements = allPoseClips.filter {
            $0.kind == .alignment || $0.kind == .breath || $0.kind == .option
        } + Array(entryClips.dropFirst())

        var variable = allPoseClips.filter { $0.kind == .reflection }
        variable.append(contentsOf: globalClips(
            for: context.style,
            includeOpening: context.isFirstStep
        ))
        variable = ranked(
            variable.filter { !excludedClipIDs.contains($0.id) },
            seed: sessionSeed,
            salt: stepIndex
        )

        if !hasAuthoredEntry || didScheduleEntry {
            var remainingRefinements: [YogaGuidanceClip] = []
            var scheduledFirstRefinement = refinements.isEmpty
            for clip in refinements {
                if !scheduledFirstRefinement {
                    scheduledFirstRefinement = appendIfFits(clip, preferredGap: interClipPause)
                } else {
                    remainingRefinements.append(clip)
                }
            }

            var remainingVariable: [YogaGuidanceClip] = []
            var scheduledFirstVariable = false
            if scheduledFirstRefinement {
                for clip in variable {
                    if !scheduledFirstVariable {
                        scheduledFirstVariable = appendIfFits(
                            clip,
                            preferredGap: firstModularSilence(for: context.style)
                        )
                    } else {
                        remainingVariable.append(clip)
                    }
                }
            }

            var refinementIndex = 0
            var variableIndex = 0
            while refinementIndex < remainingRefinements.count || variableIndex < remainingVariable.count {
                if refinementIndex < remainingRefinements.count {
                    appendIfFits(
                        remainingRefinements[refinementIndex],
                        preferredGap: minimumSilence(for: context.style)
                    )
                    refinementIndex += 1
                }
                if variableIndex < remainingVariable.count {
                    appendIfFits(
                        remainingVariable[variableIndex],
                        preferredGap: minimumSilence(for: context.style)
                    )
                    variableIndex += 1
                }
            }
        }

        if let exit, let exitOffset {
            let priorEnd = scheduled.last.map { $0.offset + $0.estimatedDuration } ?? 0
            if exitOffset >= priorEnd + interClipPause || scheduled.isEmpty {
                scheduled.append(YogaScheduledCue(
                    offset: exitOffset,
                    clip: exit,
                    estimatedDuration: exitDuration
                ))
            }
        }

        return YogaGuidancePlan(
            holdSeconds: context.holdSeconds,
            cues: scheduled.sorted { $0.offset < $1.offset }
        )
    }

    static func completionClip(
        sessionSeed: UInt64,
        excludedClipIDs: Set<String> = []
    ) -> YogaGuidanceClip {
        let closings = globalClips(kind: .closing, lines: YogaGuidanceCatalog.global?.closings ?? [])
        let fresh = closings.filter { !excludedClipIDs.contains($0.id) }
        return ranked(fresh.isEmpty ? closings : fresh, seed: sessionSeed, salt: 9_901).first
            ?? YogaGuidanceClip(
                id: "global.closing.fallback",
                text: "Your guided practice is complete. Notice how you feel before you move on.",
                kind: .closing,
                poseSlug: nil
            )
    }

    /// All approved pose clips, using exactly the same stable IDs consumed by
    /// the build-time OpenRouter generator and the bundled audio manifest.
    static func poseClips(
        context: YogaGuidancePlanningContext,
        guidance: YogaPoseGuidance?
    ) -> [YogaGuidanceClip] {
        guard let slug = context.poseSlug, let guidance else {
            var result = [YogaGuidanceClip(
                id: "custom.\(stableHash(context.poseName)).name",
                text: context.poseName,
                kind: .poseName,
                poseSlug: nil
            )]
            if let custom = context.customTransitionCue, !custom.isEmpty {
                result.append(YogaGuidanceClip(
                    id: "custom.\(stableHash(custom)).entry",
                    text: custom,
                    kind: .entry,
                    poseSlug: nil
                ))
            }
            return result
        }

        var clips: [YogaGuidanceClip] = []
        let currentSideTag = sideTag(for: context.side, fallback: "center")
        let announcedName = guidance.nameAnnouncement ?? context.poseName
        clips.append(YogaGuidanceClip(
            id: "pose.\(slug).name.\(currentSideTag)",
            text: displayName(announcedName, side: context.side),
            kind: .poseName,
            poseSlug: slug
        ))

        func add(_ kind: YogaGuidanceKind, _ lines: [String]) {
            for (index, template) in lines.enumerated() {
                let variant = template.contains("{side}") || template.contains("{oppositeSide}")
                    ? sideTag(for: context.side, fallback: "left")
                    : "shared"
                clips.append(YogaGuidanceClip(
                    id: "pose.\(slug).\(kind.rawValue).\(index).\(variant)",
                    text: YogaGuidanceCatalog.resolved(template, side: context.side),
                    kind: kind,
                    poseSlug: slug
                ))
            }
        }

        add(.entry, guidance.cues.entry)
        add(.alignment, guidance.cues.alignment)
        add(.breath, guidance.cues.breath)
        add(.option, guidance.cues.options)
        add(.reflection, guidance.cues.reflection)
        add(.exit, [guidance.cues.exit])
        return clips
    }

    private static func globalClips(for style: YogaStyle, includeOpening: Bool) -> [YogaGuidanceClip] {
        guard let global = YogaGuidanceCatalog.global else { return [] }
        var clips: [YogaGuidanceClip] = []
        if includeOpening {
            clips += globalClips(kind: .opening, lines: global.openings)
        }
        clips += globalClips(kind: .breath, lines: global.breath)
        clips += globalClips(kind: .awareness, lines: global.awareness)
        clips += globalClips(kind: .encouragement, lines: global.encouragement)
        switch style {
        case .hatha, .yin, .restorative, .gentle:
            clips += globalClips(kind: .spiritual, lines: global.spiritual)
        case .vinyasa, .power:
            // A small spiritual vocabulary is still available in active
            // classes, but physical setup and breath keep priority.
            clips += globalClips(kind: .spiritual, lines: Array(global.spiritual.prefix(4)))
        }
        return clips
    }

    private static func globalClips(kind: YogaGuidanceKind, lines: [String]) -> [YogaGuidanceClip] {
        lines.enumerated().map { index, line in
            YogaGuidanceClip(
                id: "global.\(kind.rawValue).\(index)",
                text: line,
                kind: kind,
                poseSlug: nil
            )
        }
    }

    private static func duration(
        for clip: YogaGuidanceClip,
        measured: [String: TimeInterval]
    ) -> TimeInterval {
        if let measured = measured[clip.id], measured > 0 { return measured }
        let words = clip.text.split(whereSeparator: \.isWhitespace).count
        // Calm narration auditions average roughly 2.25 words per second.
        // The extra tail allows a natural stop before the next modular clip.
        return max(1.4, Double(words) / 2.25 + 0.45)
    }

    private static func minimumSilence(for style: YogaStyle) -> TimeInterval {
        switch style {
        case .vinyasa, .power: 7
        case .hatha: 10
        case .gentle: 13
        case .yin, .restorative: 18
        }
    }

    /// The first modular cue arrives sooner than later cycles so a typical
    /// class actually gains instructor texture without turning into chatter.
    private static func firstModularSilence(for style: YogaStyle) -> TimeInterval {
        minimumSilence(for: style) / 2
    }

    private static func displayName(_ name: String, side: YogaFlowPlan.Side?) -> String {
        switch side {
        case .left: "\(name), left side."
        case .right: "\(name), right side."
        default: "\(name)."
        }
    }

    private static func sideTag(for side: YogaFlowPlan.Side?, fallback: String) -> String {
        switch side {
        case .left: "left"
        case .right: "right"
        default: fallback
        }
    }

    private static func ranked(
        _ clips: [YogaGuidanceClip],
        seed: UInt64,
        salt: Int
    ) -> [YogaGuidanceClip] {
        clips.sorted {
            rank(for: $0.id, seed: seed, salt: salt) < rank(for: $1.id, seed: seed, salt: salt)
        }
    }

    private static func rank(for id: String, seed: UInt64, salt: Int) -> UInt64 {
        stableHash("\(seed):\(salt):\(id)")
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
