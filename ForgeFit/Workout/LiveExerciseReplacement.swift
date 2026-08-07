import ForgeCore
import ForgeData
import Foundation

/// Splits a live exercise replacement around work that is already logged.
///
/// Completed sets are facts about the original exercise, so they stay on its
/// row. Only the unfinished set slots move to a fresh replacement row directly
/// below it. A target with no completed work returns `nil`, allowing the caller
/// to use the normal in-place replacement path.
@MainActor
enum LiveExerciseReplacement {
    struct SplitResult {
        let replacement: WorkoutExerciseModel
        let discardedSets: [SetModel]
    }

    static func splitIfNeeded(
        target: WorkoutExerciseModel,
        replacementExerciseID: UUID,
        replacementWeightMode: WeightMode,
        replacementIsUnilateral: Bool,
        in workout: WorkoutModel,
        now: Date = Date()
    ) -> SplitResult? {
        var rows = workout.exercises.sorted { $0.position < $1.position }
        guard let targetIndex = rows.firstIndex(where: { $0.id == target.id }) else { return nil }

        let orderedSets = target.sets.sorted { $0.position < $1.position }
        let completed = orderedSets.filter { $0.completedAt != nil }
        guard !completed.isEmpty else { return nil }
        let unfinished = orderedSets.filter { $0.completedAt == nil }

        for (index, set) in completed.enumerated() {
            set.position = index
        }
        target.sets = completed
        target.updatedAt = now

        let replacementSets = unfinished.enumerated().map { index, template in
            freshSet(
                from: template,
                position: index,
                weightMode: replacementWeightMode,
                isUnilateral: replacementIsUnilateral,
                userID: target.userID,
                now: now
            )
        }
        let replacement = WorkoutExerciseModel(
            userID: target.userID,
            exerciseID: replacementExerciseID,
            position: targetIndex + 1,
            restSeconds: target.restSeconds,
            microRestSeconds: target.microRestSeconds,
            createdAt: now,
            updatedAt: now,
            sets: replacementSets
        )

        // The replacement is deliberately not copied into the original
        // superset. Its first remaining set may represent round 3 while a new
        // superset member's first set is treated as round 1, which would make
        // rest/completion sequencing dishonest.
        rows.insert(replacement, at: targetIndex + 1)
        for (index, row) in rows.enumerated() {
            row.position = index
            row.updatedAt = now
        }
        workout.exercises = rows
        workout.updatedAt = now

        return SplitResult(replacement: replacement, discardedSets: unfinished)
    }

    private static func freshSet(
        from template: SetModel,
        position: Int,
        weightMode: WeightMode,
        isUnilateral: Bool,
        userID: UUID,
        now: Date
    ) -> SetModel {
        SetModel(
            userID: userID,
            position: position,
            setType: template.setType,
            weightMode: weightMode,
            isUnilateral: isUnilateral,
            limbCount: isUnilateral ? max(2, template.limbCount) : 2,
            isEccentric: template.isEccentric,
            isPaused: template.isPaused,
            plannedMiniSetCount: template.setType == .myoRep ? template.plannedMiniSetCount : nil,
            plannedMiniRepsJSON: template.setType == .cluster ? template.plannedMiniRepsJSON : nil,
            createdAt: now,
            updatedAt: now
        )
    }
}
