import ForgeCore
@testable import ForgeData
import SwiftData
import XCTest

@MainActor
final class ForgeDataRoundTripTests: XCTestCase {

    func testWorkoutWithAdvancedSetsRoundTripsThroughSwiftData() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let userID = UUID()
        let exercise = ExerciseLibraryModel(
            name: "Weighted Pull-Up",
            movementPattern: "vertical_pull",
            primaryMuscles: ["lats"],
            secondaryMuscles: ["biceps", "rear_delts"],
            equipment: "bodyweight",
            defaultWeightMode: .bodyweightAdded,
            preferredWeightUnitRaw: "lb"
        )
        let workoutID = UUID()
        let workout = WorkoutModel(
            id: workoutID,
            userID: userID,
            title: "AC-7 Round Trip",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceDevice: "iphone"
        )
        let workoutExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: exercise.id,
            position: 0
        )

        let unilateral = SetModel(
            userID: userID,
            position: 0,
            entry: SetEntry(
                setType: .working,
                reps: 10,
                isUnilateral: true,
                implementWeight: 30,
                limbCount: 2
            )
        )
        let drop = SetModel(
            userID: userID,
            position: 1,
            entry: SetEntry(
                setType: .drop,
                reps: 12,
                weight: 70,
                rpe: 9.0,
                partialReps: 2
            )
        )
        let weightedBodyweight = SetModel(
            userID: userID,
            position: 2,
            entry: SetEntry(
                setType: .working,
                weightMode: .bodyweightAdded,
                reps: 5,
                addedWeight: 20,
                bodyweightKg: 80
            )
        )

        workoutExercise.sets = [unilateral, drop, weightedBodyweight]
        workout.exercises = [workoutExercise]
        workout.recomputeTotalVolume()

        context.insert(exercise)
        context.insert(workout)
        try context.save()

        let reloadContext = ModelContext(container)
        let descriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )
        let reloaded = try XCTUnwrap(reloadContext.fetch(descriptor).first)
        XCTAssertEqual(reloaded.title, "AC-7 Round Trip")
        XCTAssertEqual(reloaded.exercises.count, 1)
        let exerciseID = exercise.id
        let exerciseDescriptor = FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { $0.id == exerciseID }
        )
        let reloadedExercise = try XCTUnwrap(reloadContext.fetch(exerciseDescriptor).first)
        XCTAssertEqual(reloadedExercise.preferredWeightUnitRaw, "lb")

        let sets = reloaded.exercises[0].sets.sorted { $0.position < $1.position }
        XCTAssertEqual(sets.count, 3)

        XCTAssertEqual(sets[0].setType, .working)
        XCTAssertTrue(sets[0].isUnilateral)
        XCTAssertEqual(sets[0].implementWeight, 30)
        XCTAssertEqual(sets[0].totalVolume ?? 0, 600, accuracy: 0.0001)

        XCTAssertEqual(sets[1].setType, .drop)
        XCTAssertEqual(sets[1].partialReps, 2)
        XCTAssertEqual(sets[1].totalVolume ?? 0, 910, accuracy: 0.0001)
        XCTAssertEqual(sets[1].estimated1RM ?? 0, 98, accuracy: 0.0001)

        XCTAssertEqual(sets[2].weightMode, .bodyweightAdded)
        XCTAssertEqual(sets[2].bodyweightKg, 80)
        XCTAssertEqual(sets[2].addedWeight, 20)
        XCTAssertEqual(sets[2].effectiveLoad ?? 0, 100, accuracy: 0.0001)
        XCTAssertEqual(sets[2].totalVolume ?? 0, 500, accuracy: 0.0001)

        XCTAssertEqual(reloaded.totalVolume ?? 0, 2_010, accuracy: 0.0001)
    }

    func testCoachingModelsRoundTripThroughSwiftData() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let userID = UUID()
        let folderID = UUID()
        let exerciseID = UUID()

        let profile = CoachingProfileModel(
            userID: userID,
            focusRaw: CoachingFocus.strength.rawValue,
            goalRaw: "build-muscle",
            experienceRaw: CoachingExperience.intermediate.rawValue,
            sessionsPerWeek: 4,
            sessionMinutes: 45,
            preferredCardioRaw: "run"
        )
        profile.equipment = ["barbell", "bands"]

        let programID = UUID()
        let program = CoachedProgramModel(
            id: programID,
            userID: userID,
            folderID: folderID,
            catalogProgramID: "hybrid-engine",
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            weeks: 8,
            weeklySessionTarget: 4,
            isActive: true
        )

        let override = CoachingWeekOverrideModel(
            userID: userID,
            programID: programID,
            exerciseID: exerciseID,
            weekStart: Date(timeIntervalSince1970: 1_800_000_000),
            reason: "Bench press under target 2 sessions running"
        )
        override.kind = .progressionHold
        override.status = .active

        context.insert(profile)
        context.insert(program)
        context.insert(override)
        try context.save()

        let reloadContext = ModelContext(container)

        let reloadedProfile = try XCTUnwrap(
            try reloadContext.fetch(FetchDescriptor<CoachingProfileModel>()).first
        )
        XCTAssertEqual(reloadedProfile.focus, .strength)
        XCTAssertEqual(reloadedProfile.experience, .intermediate)
        XCTAssertEqual(reloadedProfile.sessionsPerWeek, 4)
        XCTAssertEqual(reloadedProfile.sessionMinutes, 45)
        XCTAssertEqual(reloadedProfile.equipment, ["barbell", "bands"])
        XCTAssertEqual(reloadedProfile.preferredCardioRaw, "run")

        let programDescriptor = FetchDescriptor<CoachedProgramModel>(
            predicate: #Predicate { $0.id == programID }
        )
        let reloadedProgram = try XCTUnwrap(reloadContext.fetch(programDescriptor).first)
        XCTAssertEqual(reloadedProgram.folderID, folderID)
        XCTAssertEqual(reloadedProgram.catalogProgramID, "hybrid-engine")
        XCTAssertFalse(reloadedProgram.isAttachedPlan)
        XCTAssertEqual(reloadedProgram.weeks, 8)
        XCTAssertTrue(reloadedProgram.isActive)

        let reloadedOverride = try XCTUnwrap(
            try reloadContext.fetch(FetchDescriptor<CoachingWeekOverrideModel>()).first
        )
        XCTAssertEqual(reloadedOverride.programID, programID)
        XCTAssertEqual(reloadedOverride.exerciseID, exerciseID)
        XCTAssertEqual(reloadedOverride.kind, .progressionHold)
        XCTAssertEqual(reloadedOverride.status, .active)
        XCTAssertEqual(reloadedOverride.reason, "Bench press under target 2 sessions running")
    }
}
