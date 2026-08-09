import ForgeCore
import ForgeData
import Foundation

@MainActor
enum ExerciseSwapUsageBuilder {
    static func profiles(
        from workouts: [WorkoutModel]
    ) -> [UUID: ExerciseSwapSuggester.UsageProfile] {
        var completedWorkoutCountByExerciseID: [UUID: Int] = [:]

        for workout in workouts where workout.endedAt != nil && workout.deletedAt == nil {
            let completedCardioRowIDs = Set(
                workout.cardioSessions.compactMap { session -> UUID? in
                    guard session.endedAt != nil, session.deletedAt == nil else { return nil }
                    return session.workoutExerciseID
                }
            )
            var exerciseIDsUsedInWorkout = Set<UUID>()

            for row in workout.exercises {
                let hasCompletedStrengthSet = row.sets.contains { $0.completedAt != nil }
                let hasCompletedCardioSession = completedCardioRowIDs.contains(row.id)
                if hasCompletedStrengthSet || hasCompletedCardioSession {
                    exerciseIDsUsedInWorkout.insert(row.exerciseID)
                }
            }

            for exerciseID in exerciseIDsUsedInWorkout {
                completedWorkoutCountByExerciseID[exerciseID, default: 0] += 1
            }
        }

        return completedWorkoutCountByExerciseID.mapValues {
            ExerciseSwapSuggester.UsageProfile(completedWorkoutCount: $0)
        }
    }
}
