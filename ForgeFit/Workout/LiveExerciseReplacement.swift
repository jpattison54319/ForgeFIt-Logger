import ForgeCore
import ForgeData
import Foundation

/// Retargets a strength exercise without changing the live workout's row or
/// set structure. Completed entries remain exactly as logged; unfinished
/// entries keep their identity/type/position/plan but discard values that
/// belonged to the exercise being replaced.
@MainActor
enum LiveExerciseReplacement {
    static func replaceInPlace(
        target: WorkoutExerciseModel,
        replacementExerciseID: UUID,
        replacementWeightMode: WeightMode,
        replacementIsUnilateral: Bool,
        now: Date = Date()
    ) {
        target.exerciseID = replacementExerciseID
        target.updatedAt = now

        for set in target.sets where set.completedAt == nil {
            set.weightMode = replacementWeightMode
            set.isUnilateral = replacementIsUnilateral
            set.limbCount = replacementIsUnilateral ? max(2, set.limbCount) : 2

            set.reps = nil
            set.weight = nil
            set.rpe = nil
            set.rir = nil
            set.durationSeconds = nil
            set.holdSeconds = nil
            set.partialReps = nil
            set.addedWeight = nil
            set.assistanceWeight = nil
            set.bodyweightKg = nil
            set.implementWeight = nil
            set.machineSettingsJSON = nil
            set.miniRepsJSON = nil
            set.side2Reps = nil
            set.side2MiniRepsJSON = nil
            set.recomputeDerivedMetrics()
            set.updatedAt = now
        }
    }
}
