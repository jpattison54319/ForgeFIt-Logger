import Foundation
import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// App-side metadata for `YogaStyle` (the enum itself lives in ForgeCore so
/// flow JSON decodes on the watch too) — mirrors how `CardioKind` carries its
/// UI concerns.
extension YogaStyle {
    var systemImage: String {
        switch self {
        case .vinyasa: "figure.yoga"
        case .hatha: "figure.mind.and.body"
        case .power: "figure.strengthtraining.functional"
        case .yin: "figure.cooldown"
        case .restorative: "moon.zzz.fill"
        case .gentle: "figure.flexibility"
        }
    }

    /// One-line positioning shown in the flow browser.
    var blurb: String {
        switch self {
        case .vinyasa: "Flowing, breath-paced movement"
        case .hatha: "Classic poses, steady holds"
        case .power: "Strength-building, faster pace"
        case .yin: "Long, passive deep stretches"
        case .restorative: "Fully supported, deeply calming"
        case .gentle: "Easy movement, all levels"
        }
    }

    /// MET estimate for kcal fallback when no watch HR is present
    /// (Ainsworth Compendium of Physical Activities: hatha ~2.5,
    /// general/vinyasa ~4, power ~5, seated/relaxation ~2).
    var metEstimate: Double {
        switch self {
        case .power: 5.0
        case .vinyasa: 4.0
        case .hatha: 2.5
        case .gentle: 2.5
        case .yin, .restorative: 2.0
        }
    }
}

extension YogaFlowPlan {
    /// Build a flow from yoga poses selected in the exercise picker. The
    /// session anchor itself is just the container card, not a runnable pose.
    static func fromSelectedPoses(_ exercises: [ExerciseLibraryModel], style: YogaStyle = .hatha) -> YogaFlowPlan? {
        let poses = exercises.filter { $0.isYoga && !YogaPoseCatalog.isSessionExercise($0) }
        guard !poses.isEmpty else { return nil }
        return YogaFlowPlan(style: style, steps: poses.map { exercise in
            let slug = YogaPoseCatalog.slug(for: exercise)
            let side: YogaFlowPlan.Side? = exercise.isUnilateral ? .left : nil
            let defaultHold = exercise.defaultHoldSeconds ?? 30
            let minimumHold = YogaGuidancePlanner.minimumCriticalHoldSeconds(
                poseSlug: slug,
                poseName: exercise.name,
                side: side
            ) ?? 1
            return PoseStep(
                poseID: exercise.id,
                poseSlug: slug,
                name: exercise.name,
                holdSeconds: max(defaultHold, minimumHold),
                side: exercise.isUnilateral ? .bothSides : nil
            )
        })
    }

    /// A single-pose flow synthesized from a library pose — what runs when the
    /// user adds one pose to a routine/workout without building a sequence.
    /// One-sided poses default to both sides so the practice stays balanced.
    static func singlePose(from exercise: ExerciseLibraryModel, style: YogaStyle = .hatha) -> YogaFlowPlan {
        let slug = YogaPoseCatalog.slug(for: exercise)
        let side: YogaFlowPlan.Side? = exercise.isUnilateral ? .left : nil
        let defaultHold = exercise.defaultHoldSeconds ?? 30
        let minimumHold = YogaGuidancePlanner.minimumCriticalHoldSeconds(
            poseSlug: slug,
            poseName: exercise.name,
            side: side
        ) ?? 1
        return YogaFlowPlan(style: style, steps: [
            PoseStep(
                poseID: exercise.id,
                poseSlug: slug,
                name: exercise.name,
                holdSeconds: max(defaultHold, minimumHold),
                side: exercise.isUnilateral ? .bothSides : nil
            )
        ])
    }

    /// The flow a yoga workout exercise should run: its stored plan, else a
    /// synthesized single-pose hold. Nil only when the exercise isn't yoga.
    static func resolved(for workoutExercise: WorkoutExerciseModel, exercise: ExerciseLibraryModel?) -> YogaFlowPlan? {
        if let plan = YogaFlowPlan.decode(from: workoutExercise.yogaFlowJSON), plan.hasSteps {
            return plan
        }
        guard let exercise, exercise.isYoga, !YogaPoseCatalog.isSessionExercise(exercise) else { return nil }
        return .singlePose(from: exercise)
    }
}

extension CardioSessionModel {
    /// The style driving XP weighting and recovery classification; hatha is
    /// the neutral default for sessions logged before styles existed.
    nonisolated var resolvedYogaStyle: YogaStyle { yogaStyle ?? .hatha }
}

/// One completion path for guided, watch-started, finish-workout, and manual
/// yoga logs. It keeps pose count, duration, style, and flexibility exposure
/// in sync no matter which surface ends the session.
@MainActor
enum YogaSessionCompletion {
    static func complete(
        session: CardioSessionModel,
        workoutExercise: WorkoutExerciseModel?,
        exercise: ExerciseLibraryModel?,
        context: ModelContext,
        endedAt: Date = .now,
        useClockDuration: Bool,
        clearCheckpoint: Bool = true
    ) {
        session.endedAt = endedAt

        let plan = workoutExercise.flatMap { YogaFlowPlan.resolved(for: $0, exercise: exercise) }

        if useClockDuration {
            let start = session.liveStartedAt ?? session.startedAt
            session.durationSeconds = max(1, Int(endedAt.timeIntervalSince(start)))
        } else if session.durationSeconds == nil, let plan, plan.totalSeconds > 0 {
            session.durationSeconds = plan.totalSeconds
        }

        if let plan {
            // Mid-class stops converge on one partial-credit semantic: the
            // hold in progress when the class stopped is recorded with the
            // seconds actually held (the Skip semantic). A live runner records
            // it via `YogaFlowRunner.complete()`; this reconciles the paths
            // with no runner to do it (app terminated mid-hold, or a workout
            // finished from the wrist) from the persisted split timeline.
            recordInterruptedHold(session: session, plan: plan, context: context, endedAt: endedAt)
        }
        if clearCheckpoint {
            YogaRuntimeCheckpointStore.clear(sessionID: session.id)
        }

        if let logicalCount = session.logicalYogaPosesCompleted {
            // Always normalize the stored value. Legacy sessions may carry an
            // expanded Left/Right hold count even though the split timeline
            // can provide the canonical logical-pose result.
            session.posesCompleted = logicalCount
        }

        guard let plan else { return }
        if session.yogaStyleRaw == nil {
            session.yogaStyleRaw = plan.styleRaw
        }
        FlexibilityAnalytics.stampExposure(plan: plan, session: session, context: context)
    }

    /// Backstop partial-hold credit when no live runner can record it. The
    /// durable checkpoint is the authority: it preserves the current step,
    /// accrued seconds, and pause state across process death. With no valid
    /// checkpoint (including a session created by an older build), completion
    /// stays conservative and never invents time from a split-to-end wall gap.
    private static func recordInterruptedHold(
        session: CardioSessionModel,
        plan: YogaFlowPlan,
        context: ModelContext,
        endedAt: Date
    ) {
        guard session.liveStartedAt != nil,
              session.posesCompleted == nil,
              let checkpoint = YogaRuntimeCheckpointStore.load(sessionID: session.id) else { return }
        let expanded = YogaFlowRunner.expand(plan)
        guard expanded.indices.contains(checkpoint.stepIndex) else { return }
        let labeledIndexes = Set(session.splits.compactMap { split -> Int? in
            guard let label = split.label else { return nil }
            return label.isEmpty ? nil : split.index
        })
        guard !labeledIndexes.contains(checkpoint.stepIndex) else { return }
        let step = expanded[checkpoint.stepIndex]
        let duration = checkpoint.elapsed(at: endedAt, cappedAt: step.seconds)
        guard duration > 0 else { return }
        let startedAt = endedAt.addingTimeInterval(-TimeInterval(duration))
        let split = CardioSplitModel(
            userID: session.userID,
            cardioSessionID: session.id,
            index: step.id,
            distanceMeters: 0,
            durationSeconds: duration,
            paceSecondsPerKm: 0,
            label: step.displayName,
            startedAt: startedAt,
            endedAt: endedAt
        )
        split.cardioSession = session
        context.insert(split)
        session.splits.append(split)
    }
}
