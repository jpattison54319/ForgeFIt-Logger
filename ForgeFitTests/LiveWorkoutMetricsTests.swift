import ForgeData
import Foundation
import Testing
@testable import ForgeFit

struct LiveWorkoutMetricsTests {
    @Test func editingCompletedSetImmediatelyRefreshesSetAndWorkoutMetrics() {
        let set = SetModel(
            userID: ForgeFitDemo.userID,
            reps: 5,
            weight: 100,
            completedAt: Date()
        )
        let exercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            sets: [set]
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            exercises: [exercise]
        )

        LiveWorkoutMetrics.refresh(changedSet: set, in: workout)
        #expect(set.totalVolume == 500)
        #expect(workout.totalVolume == 500)

        set.reps = 8
        LiveWorkoutMetrics.refresh(changedSet: set, in: workout)
        #expect(set.totalVolume == 800)
        #expect(workout.totalVolume == 800)

        set.weight = 120
        LiveWorkoutMetrics.refresh(changedSet: set, in: workout)
        #expect(set.totalVolume == 960)
        #expect(workout.totalVolume == 960)
        #expect(set.estimated1RM != nil)
    }
}
