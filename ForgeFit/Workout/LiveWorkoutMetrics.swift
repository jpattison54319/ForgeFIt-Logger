import ForgeCore
import ForgeData
import Foundation
import Observation

/// Incremental live counters keyed by set identity. A field commit touches one
/// contribution instead of scanning the entire workout twice. Structural
/// mutations (add/delete exercise or set) call `rebuild` as their bounded
/// correctness fallback.
@MainActor
@Observable
final class LiveWorkoutMetrics {
    private struct Contribution {
        var workoutVolume = 0.0
        var visibleVolume = 0.0
        var effectiveSets = 0.0
    }

    private var contributions: [UUID: Contribution] = [:]
    private var workoutVolume = 0.0
    private var isInitialized = false

    private(set) var volume = 0.0
    private(set) var completedSets = 0.0

    func rebuild(from workout: WorkoutModel) {
        var next: [UUID: Contribution] = [:]
        var nextWorkoutVolume = 0.0
        var nextVisibleVolume = 0.0
        var nextCompletedSets = 0.0

        for exercise in workout.exercises {
            for set in exercise.sets {
                let value = Self.contribution(
                    for: set,
                    countsInVisibleStats: exercise.generatedByWorkoutBlockID == nil
                )
                next[set.id] = value
                nextWorkoutVolume += value.workoutVolume
                nextVisibleVolume += value.visibleVolume
                nextCompletedSets += value.effectiveSets
            }
        }

        contributions = next
        workoutVolume = nextWorkoutVolume
        if volume != nextVisibleVolume { volume = nextVisibleVolume }
        if completedSets != nextCompletedSets { completedSets = nextCompletedSets }
        // Rebuild commonly runs from a post-save publication callback. Avoid
        // assigning an equal model value there: SwiftData can treat the setter
        // as a fresh mutation and leave the shared context dirty again.
        // The logger owns its live aggregate in this observable object. Do
        // not mutate the active WorkoutModel parent on every field/set event:
        // ContentView queries that parent and would republish the root behind
        // the logger. Historical edits persist the aggregate immediately;
        // active workouts recompute it once at Finish.
        if workout.endedAt != nil, workout.totalVolume != nextWorkoutVolume {
            workout.totalVolume = nextWorkoutVolume
        }
        isInitialized = true
    }

    func refresh(changedSet: SetModel, in workout: WorkoutModel) {
        changedSet.recomputeDerivedMetrics()
        guard isInitialized else {
            rebuild(from: workout)
            WorkoutMutationContract.stampParentForNestedMutation(workout)
            return
        }

        let old = contributions[changedSet.id] ?? Contribution()
        let owningExercise = changedSet.workoutExercise
            ?? workout.exercises.first { exercise in
                exercise.sets.contains { $0.id == changedSet.id }
            }
        let new = Self.contribution(
            for: changedSet,
            countsInVisibleStats: owningExercise?.generatedByWorkoutBlockID == nil
        )
        contributions[changedSet.id] = new
        workoutVolume = max(0, workoutVolume - old.workoutVolume + new.workoutVolume)
        volume = max(0, volume - old.visibleVolume + new.visibleVolume)
        completedSets = max(0, completedSets - old.effectiveSets + new.effectiveSets)
        if workout.endedAt != nil, workout.totalVolume != workoutVolume {
            workout.totalVolume = workoutVolume
        }
        WorkoutMutationContract.stampParentForNestedMutation(workout)
    }

    private static func contribution(
        for set: SetModel,
        countsInVisibleStats: Bool
    ) -> Contribution {
        guard set.completedAt != nil else { return Contribution() }
        let workoutVolume = set.totalVolume ?? 0
        guard countsInVisibleStats, set.setType.countsAsWorkingVolume else {
            return Contribution(workoutVolume: workoutVolume)
        }
        return Contribution(
            workoutVolume: workoutVolume,
            visibleVolume: workoutVolume,
            effectiveSets: VolumeMath.effectiveSetCount(set.domainEntry)
        )
    }
}
