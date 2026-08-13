import Foundation
import ForgeCore
import ForgeData
import Testing
@testable import ForgeFit

@MainActor
struct StrengthExerciseStatsTests {
    private let userID = UUID()
    private let exerciseID = UUID()

    private func set(
        type: SetType = .working,
        weight: Double,
        reps: Int,
        completed: Bool = true
    ) -> SetModel {
        SetModel(
            userID: userID,
            setType: type,
            reps: reps,
            weight: weight,
            completedAt: completed ? Date() : nil
        )
    }

    private func workout(daysAgo: Int, sets: [SetModel], deleted: Bool = false) -> WorkoutModel {
        let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let row = WorkoutExerciseModel(userID: userID, exerciseID: exerciseID, sets: sets)
        return WorkoutModel(
            userID: userID,
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            deletedAt: deleted ? Date() : nil,
            exercises: [row]
        )
    }

    @Test func strengthSeriesUseOneCompletedWorkingValuePerSession() {
        let older = workout(daysAgo: 2, sets: [
            set(type: .warmup, weight: 20, reps: 10),
            set(weight: 80, reps: 5),
            set(weight: 70, reps: 8),
            set(weight: 200, reps: 1, completed: false),
        ])
        let newer = workout(daysAgo: 1, sets: [
            set(weight: 85, reps: 5),
            set(weight: 75, reps: 8),
        ])

        let e1RM = StrengthExerciseStats.series(.estimatedOneRepMax, exerciseID: exerciseID, workouts: [newer, older])
        let weight = StrengthExerciseStats.series(.bestWeight, exerciseID: exerciseID, workouts: [newer, older])
        let volume = StrengthExerciseStats.series(.sessionVolume, exerciseID: exerciseID, workouts: [newer, older])
        let sets = StrengthExerciseStats.series(.workingSets, exerciseID: exerciseID, workouts: [newer, older])

        #expect(e1RM.count == 2)
        #expect(e1RM[1].value > e1RM[0].value)
        #expect(weight.map(\.value) == [80, 85])
        #expect(volume.map(\.value) == [960, 1_025])
        #expect(sets.map(\.value) == [2, 2])
    }

    @Test func availableMetricsExcludePendingAndDeletedHistory() {
        let pendingOnly = workout(daysAgo: 1, sets: [set(weight: 100, reps: 5, completed: false)])
        let deleted = workout(daysAgo: 2, sets: [set(weight: 100, reps: 5)], deleted: true)

        #expect(StrengthExerciseStats.availableMetrics(
            exerciseID: exerciseID,
            workouts: [pendingOnly, deleted]
        ).isEmpty)
    }
}
