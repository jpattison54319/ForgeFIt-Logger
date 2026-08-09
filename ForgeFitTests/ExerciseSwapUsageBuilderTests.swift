import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct ExerciseSwapUsageBuilderTests {
    private let userID = UUID()

    @Test func completedSetsAndDuplicateRowsCountOncePerWorkout() throws {
        let (container, context) = try TestStore.make()
        let exerciseID = UUID()
        let endedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let completedSets = (0..<5).map {
            SetModel(userID: userID, position: $0, reps: 8, completedAt: endedAt)
        }
        let first = WorkoutExerciseModel(userID: userID, exerciseID: exerciseID, sets: completedSets)
        let duplicate = WorkoutExerciseModel(
            userID: userID,
            exerciseID: exerciseID,
            sets: [SetModel(userID: userID, completedAt: endedAt)]
        )
        let workout = WorkoutModel(
            userID: userID,
            startedAt: endedAt.addingTimeInterval(-3_600),
            endedAt: endedAt,
            exercises: [first, duplicate]
        )
        context.insert(workout)

        let profiles = ExerciseSwapUsageBuilder.profiles(from: [workout])

        #expect(profiles[exerciseID]?.completedWorkoutCount == 1)
        _ = container
    }

    @Test func unfinishedDeletedAndUncompletedStrengthWorkoutsDoNotCount() throws {
        let (container, context) = try TestStore.make()
        let exerciseID = UUID()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let emptyRow = WorkoutExerciseModel(
            userID: userID,
            exerciseID: exerciseID,
            sets: [SetModel(userID: userID)]
        )
        let unfinished = WorkoutModel(userID: userID, exercises: [emptyRow])
        let uncompleted = WorkoutModel(userID: userID, endedAt: date, exercises: [emptyRow])
        let completedSet = SetModel(userID: userID, completedAt: date)
        let deleted = WorkoutModel(
            userID: userID,
            endedAt: date,
            deletedAt: date,
            exercises: [WorkoutExerciseModel(userID: userID, exerciseID: exerciseID, sets: [completedSet])]
        )
        context.insert(unfinished)
        context.insert(uncompleted)
        context.insert(deleted)

        let profiles = ExerciseSwapUsageBuilder.profiles(from: [unfinished, uncompleted, deleted])

        #expect(profiles[exerciseID] == nil)
        _ = container
    }

    @Test func completedCardioSessionCountsWithoutStrengthSets() throws {
        let (container, context) = try TestStore.make()
        let exerciseID = UUID()
        let endedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let row = WorkoutExerciseModel(userID: userID, exerciseID: exerciseID)
        let session = CardioSessionModel(
            userID: userID,
            workoutExerciseID: row.id,
            modality: "run",
            endedAt: endedAt
        )
        let workout = WorkoutModel(
            userID: userID,
            endedAt: endedAt,
            exercises: [row],
            cardioSessions: [session]
        )
        context.insert(workout)

        let profiles = ExerciseSwapUsageBuilder.profiles(from: [workout])

        #expect(profiles[exerciseID]?.completedWorkoutCount == 1)
        _ = container
    }

    @Test func repeatedCompletedWorkoutsIncrementLifetimeFavoriteCount() throws {
        let (container, context) = try TestStore.make()
        let exerciseID = UUID()
        let workouts = (0..<4).map { offset in
            let completedAt = Date(timeIntervalSince1970: 1_750_000_000 + Double(offset * 86_400))
            return WorkoutModel(
                userID: userID,
                endedAt: completedAt,
                exercises: [
                    WorkoutExerciseModel(
                        userID: userID,
                        exerciseID: exerciseID,
                        sets: [SetModel(userID: userID, completedAt: completedAt)]
                    )
                ]
            )
        }
        workouts.forEach(context.insert)

        let profiles = ExerciseSwapUsageBuilder.profiles(from: workouts)

        #expect(profiles[exerciseID]?.completedWorkoutCount == 4)
        _ = container
    }
}
