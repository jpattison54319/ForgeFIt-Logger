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
    /// A single-pose flow synthesized from a library pose — what runs when the
    /// user adds one pose to a routine/workout without building a sequence.
    /// One-sided poses default to both sides so the practice stays balanced.
    static func singlePose(from exercise: ExerciseLibraryModel, style: YogaStyle = .hatha) -> YogaFlowPlan {
        YogaFlowPlan(style: style, steps: [
            PoseStep(
                poseID: exercise.id,
                poseSlug: YogaPoseCatalog.slug(for: exercise),
                name: exercise.name,
                holdSeconds: exercise.defaultHoldSeconds ?? 30,
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
        guard let exercise, exercise.isYoga else { return nil }
        return .singlePose(from: exercise)
    }
}

extension CardioSessionModel {
    /// The style driving XP weighting and recovery classification; hatha is
    /// the neutral default for sessions logged before styles existed.
    var resolvedYogaStyle: YogaStyle { yogaStyle ?? .hatha }
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
        useClockDuration: Bool
    ) {
        session.endedAt = endedAt

        if useClockDuration {
            let start = session.liveStartedAt ?? session.startedAt
            session.durationSeconds = max(1, Int(endedAt.timeIntervalSince(start)))
        } else if session.durationSeconds == nil,
                  let workoutExercise,
                  let plan = YogaFlowPlan.resolved(for: workoutExercise, exercise: exercise),
                  plan.totalSeconds > 0 {
            session.durationSeconds = plan.totalSeconds
        }

        let completedPoseIndexes = Set(
            session.splits
                .filter { $0.label != nil }
                .map(\.index)
        )
        if session.posesCompleted == nil, !completedPoseIndexes.isEmpty {
            session.posesCompleted = completedPoseIndexes.count
        }

        guard let workoutExercise,
              let plan = YogaFlowPlan.resolved(for: workoutExercise, exercise: exercise) else { return }
        if session.yogaStyleRaw == nil {
            session.yogaStyleRaw = plan.styleRaw
        }
        FlexibilityAnalytics.stampExposure(plan: plan, session: session, context: context)
    }
}
