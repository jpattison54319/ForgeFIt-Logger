import ForgeData
import Foundation
import SwiftData

/// Deep-copies a routine with EVERY planned field intact. Kept as a single
/// testable helper because the field list has drifted before: an inline copy
/// silently dropped myo/cluster plans (`plannedMiniSetCount` /
/// `plannedMiniRepsJSON`), cardio interval plans (`intervalPlanJSON`) and yoga
/// flows (`yogaFlowJSON`). When a planned field is added to the routine
/// models, it must be carried here AND in `WorkoutFactory.start`.
enum RoutineDuplicator {

    /// Returns the inserted copy ("<name> Copy") placed at `position`,
    /// leaving `source` untouched. Fresh IDs throughout — the copy must not
    /// share set/exercise identity with the original.
    @MainActor
    @discardableResult
    static func duplicate(_ source: RoutineModel, position: Int, in context: ModelContext) -> RoutineModel {
        let copy = RoutineModel(
            userID: source.userID,
            name: "\(source.name) Copy",
            notes: source.notes,
            folderID: source.folderID,
            position: position
        )
        copy.exercises = source.exercises
            .sorted { $0.position < $1.position }
            .map { sourceExercise in
                let copiedSets = sourceExercise.sets
                    .sorted { $0.position < $1.position }
                    .map { s in
                        RoutineSetModel(
                            userID: source.userID, position: s.position, setType: s.setType,
                            targetRepsLow: s.targetRepsLow, targetRepsHigh: s.targetRepsHigh,
                            targetWeight: s.targetWeight, targetRPE: s.targetRPE,
                            targetRIR: s.targetRIR, targetDurationSeconds: s.targetDurationSeconds,
                            plannedMiniSetCount: s.plannedMiniSetCount,
                            plannedMiniRepsJSON: s.plannedMiniRepsJSON
                        )
                    }
                let duplicated = RoutineExerciseModel(
                    userID: source.userID, exerciseID: sourceExercise.exerciseID,
                    position: sourceExercise.position, supersetGroup: sourceExercise.supersetGroup,
                    progressionRuleID: sourceExercise.progressionRuleID, notes: sourceExercise.notes,
                    intervalPlanJSON: sourceExercise.intervalPlanJSON,
                    yogaFlowJSON: sourceExercise.yogaFlowJSON,
                    sets: copiedSets
                )
                duplicated.progressionRuleJSON = sourceExercise.progressionRuleJSON
                return duplicated
            }
        context.insert(copy)
        return copy
    }
}
