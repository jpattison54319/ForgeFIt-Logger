import ForgeCore
@testable import ForgeData
import SwiftData
import XCTest

@MainActor
final class RoutineWorkoutFlowTests: XCTestCase {

    func testRoutineCanDriveCompletedWorkoutWithLoggedSet() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let userID = UUID()
        let exercise = ExerciseLibraryModel(
            name: "Machine Chest Press",
            movementPattern: "horizontal_push",
            primaryMuscles: ["chest"],
            equipment: "machine"
        )
        let target = RoutineSetModel(
            userID: userID,
            position: 0,
            targetRepsLow: 8,
            targetRepsHigh: 12,
            targetWeight: 70,
            targetRPE: 8
        )
        let routineExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: exercise.id,
            position: 0,
            sets: [target]
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Push Day",
            exercises: [routineExercise]
        )

        let workoutID = UUID()
        let workoutExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: exercise.id,
            position: routineExercise.position
        )
        let loggedSet = SetModel(
            userID: userID,
            position: 0,
            setType: .working,
            reps: 8,
            weight: 70,
            rpe: 8,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        workoutExercise.sets = [loggedSet]

        let workout = WorkoutModel(
            id: workoutID,
            userID: userID,
            routineID: routine.id,
            title: routine.name,
            endedAt: Date(timeIntervalSince1970: 1_800_000_600),
            sourceDevice: "iphone",
            exercises: [workoutExercise]
        )
        workout.recomputeTotalVolume()

        context.insert(exercise)
        context.insert(routine)
        context.insert(workout)
        try context.save()

        let reloadContext = ModelContext(container)
        let descriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )
        let reloaded = try XCTUnwrap(reloadContext.fetch(descriptor).first)

        XCTAssertEqual(reloaded.routineID, routine.id)
        XCTAssertNotNil(reloaded.endedAt)
        XCTAssertEqual(reloaded.exercises.count, 1)
        XCTAssertEqual(reloaded.exercises[0].sets.count, 1)
        XCTAssertEqual(reloaded.exercises[0].sets[0].totalVolume ?? 0, 560, accuracy: 0.0001)
        XCTAssertEqual(reloaded.totalVolume ?? 0, 560, accuracy: 0.0001)
    }

    func testPendingRoutineTargetDoesNotCountUntilCompleted() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let userID = UUID()
        let pendingTarget = SetModel(
            userID: userID,
            position: 0,
            setType: .working,
            reps: 10,
            weight: 50,
            rpe: 8,
            completedAt: nil
        )
        let workoutExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            sets: [pendingTarget]
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Target Test",
            exercises: [workoutExercise]
        )

        workout.recomputeTotalVolume()
        XCTAssertEqual(workout.totalVolume ?? -1, 0, accuracy: 0.0001)

        pendingTarget.completedAt = Date()
        pendingTarget.recomputeDerivedMetrics()
        workout.recomputeTotalVolume()

        context.insert(workout)
        try context.save()

        XCTAssertEqual(workout.totalVolume ?? 0, 500, accuracy: 0.0001)
    }

    func testEditedCompletedSetRecomputesWorkoutVolume() throws {
        let set = SetModel(
            userID: UUID(),
            position: 0,
            reps: 8,
            weight: 70,
            rpe: 8,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workoutExercise = WorkoutExerciseModel(
            userID: set.userID,
            exerciseID: UUID(),
            sets: [set]
        )
        let workout = WorkoutModel(
            userID: set.userID,
            title: "Edit Test",
            exercises: [workoutExercise]
        )

        workout.recomputeTotalVolume()
        XCTAssertEqual(workout.totalVolume ?? 0, 560, accuracy: 0.0001)

        set.weight = 80
        set.recomputeDerivedMetrics()
        workout.recomputeTotalVolume()

        XCTAssertEqual(set.totalVolume ?? 0, 640, accuracy: 0.0001)
        XCTAssertEqual(workout.totalVolume ?? 0, 640, accuracy: 0.0001)
    }

    func testCardioSessionPersistsStructuredMetricsWithWorkout() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let userID = UUID()
        let workoutID = UUID()
        let cardio = CardioSessionModel(
            userID: userID,
            modality: "row",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_001_800),
            sourceDevice: "iphone",
            durationSeconds: 1_800,
            distanceMeters: 7_500,
            activeEnergyKcal: 420,
            avgHR: 142,
            effort: 8,
            strokeRate: 28,
            avgPowerWatts: 175
        )
        let workout = WorkoutModel(
            id: workoutID,
            userID: userID,
            title: "Row",
            endedAt: cardio.endedAt,
            sourceDevice: "iphone-cardio-row",
            cardioSessions: [cardio]
        )

        context.insert(workout)
        try context.save()

        let reloadContext = ModelContext(container)
        let descriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )
        let reloaded = try XCTUnwrap(reloadContext.fetch(descriptor).first)
        let reloadedCardio = try XCTUnwrap(reloaded.cardioSessions.first)

        XCTAssertEqual(reloadedCardio.modality, "row")
        XCTAssertEqual(reloadedCardio.durationSeconds, 1_800)
        XCTAssertEqual(reloadedCardio.distanceMeters ?? 0, 7_500, accuracy: 0.0001)
        XCTAssertEqual(reloadedCardio.activeEnergyKcal ?? 0, 420, accuracy: 0.0001)
        XCTAssertEqual(reloadedCardio.avgHR, 142)
        XCTAssertEqual(reloadedCardio.strokeRate, 28)
        XCTAssertEqual(reloadedCardio.avgPowerWatts ?? 0, 175, accuracy: 0.0001)
    }
}
