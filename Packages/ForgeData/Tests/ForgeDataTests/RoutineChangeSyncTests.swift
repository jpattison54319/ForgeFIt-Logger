import ForgeCore
@testable import ForgeData
import SwiftData
import XCTest

@MainActor
final class RoutineChangeSyncTests: XCTestCase {

    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Builds a routine + the workout seeded from it (mirroring WorkoutFactory)
    /// so origin IDs are stamped, then returns both for mutation in a test.
    @discardableResult
    private func seed(
        userID: UUID,
        exerciseID: UUID,
        in context: ModelContext
    ) throws -> (routine: RoutineModel, workout: WorkoutModel) {
        let target = RoutineSetModel(
            userID: userID, position: 0,
            targetRepsLow: 8, targetRepsHigh: 12,
            targetWeight: 60, targetRPE: 8
        )
        let routineExercise = RoutineExerciseModel(
            userID: userID, exerciseID: exerciseID, position: 0, sets: [target]
        )
        let routine = RoutineModel(userID: userID, name: "Push", exercises: [routineExercise])

        let seededSet = SetModel(
            userID: userID, position: 0, setType: .working,
            reps: 8, weight: 60, rpe: 8,
            sourceRoutineSetID: target.id
        )
        let workoutExercise = WorkoutExerciseModel(
            userID: userID, exerciseID: exerciseID, position: 0,
            sourceRoutineExerciseID: routineExercise.id, sets: [seededSet]
        )
        let workout = WorkoutModel(
            userID: userID, routineID: routine.id, title: routine.name,
            exercises: [workoutExercise]
        )

        context.insert(routine)
        context.insert(workout)
        try context.save()
        return (routine, workout)
    }

    // MARK: - Detection

    func testNoChangesYieldsEmptyPlan() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let (routine, workout) = try seed(userID: userID, exerciseID: UUID(), in: context)

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)

        XCTAssertFalse(plan.hasChanges)
        XCTAssertEqual(plan.summary, "No changes")
    }

    func testAddedSetDetected() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let (routine, workout) = try seed(userID: userID, exerciseID: UUID(), in: context)

        // Add a second set mid-session (no routine origin).
        let extra = SetModel(userID: userID, position: 1, setType: .working, reps: 8, weight: 60)
        context.insert(extra)
        workout.exercises.first?.sets.append(extra)
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)

        XCTAssertTrue(plan.hasChanges)
        XCTAssertEqual(plan.exercisePlans.first?.addedWorkoutSetIDs.count, 1)
    }

    func testRemovedSetDetected() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let (routine, workout) = try seed(userID: userID, exerciseID: UUID(), in: context)

        // Remove the only set from the workout.
        if let set = workout.exercises.first?.sets.first {
            context.delete(set)
        }
        workout.exercises.first?.sets.removeAll()
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)

        XCTAssertTrue(plan.hasChanges)
        XCTAssertEqual(plan.exercisePlans.first?.removedRoutineSetIDs.count, 1)
    }

    func testSetTypeChangedDetected() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let (routine, workout) = try seed(userID: userID, exerciseID: UUID(), in: context)

        workout.exercises.first?.sets.first?.setType = .drop
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)

        XCTAssertTrue(plan.hasChanges)
        XCTAssertEqual(plan.exercisePlans.first?.setTypeChangedRoutineSetIDs.count, 1)
    }

    func testReorderAndRegroupDetected() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let exerciseA = UUID(), exerciseB = UUID()

        let t1 = RoutineSetModel(userID: userID, position: 0, targetRepsLow: 8, targetWeight: 50)
        let reA = RoutineExerciseModel(userID: userID, exerciseID: exerciseA, position: 0, sets: [t1])
        let t2 = RoutineSetModel(userID: userID, position: 0, targetRepsLow: 5, targetWeight: 80)
        let reB = RoutineExerciseModel(userID: userID, exerciseID: exerciseB, position: 1, sets: [t2])
        let routine = RoutineModel(userID: userID, name: "Two", exercises: [reA, reB])

        let sA = SetModel(userID: userID, position: 0, sourceRoutineSetID: t1.id)
        let weA = WorkoutExerciseModel(userID: userID, exerciseID: exerciseA, position: 1, sourceRoutineExerciseID: reA.id, sets: [sA])
        let sB = SetModel(userID: userID, position: 0, sourceRoutineSetID: t2.id)
        // B moved to position 0 and joined superset group 1.
        let weB = WorkoutExerciseModel(userID: userID, exerciseID: exerciseB, position: 0, supersetGroup: 1, sourceRoutineExerciseID: reB.id, sets: [sB])
        let workout = WorkoutModel(userID: userID, routineID: routine.id, title: routine.name, exercises: [weB, weA])

        context.insert(routine)
        context.insert(workout)
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)

        XCTAssertTrue(plan.hasChanges)
        let planA = plan.exercisePlans.first { $0.matchedRoutineExerciseID == reA.id }
        let planB = plan.exercisePlans.first { $0.matchedRoutineExerciseID == reB.id }
        XCTAssertEqual(planA?.movedPosition, true)
        XCTAssertEqual(planB?.movedPosition, true)
        XCTAssertEqual(planB?.supersetChanged, true)
    }

    func testAddedAndRemovedExercisesDetected() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let exerciseA = UUID(), exerciseB = UUID()

        let reA = RoutineExerciseModel(userID: userID, exerciseID: exerciseA, position: 0,
                                       sets: [RoutineSetModel(userID: userID, position: 0, targetRepsLow: 5)])
        let routine = RoutineModel(userID: userID, name: "One", exercises: [reA])

        // Workout dropped A and added B (no origin).
        let weB = WorkoutExerciseModel(userID: userID, exerciseID: exerciseB, position: 0,
                                       sets: [SetModel(userID: userID, position: 0)])
        let workout = WorkoutModel(userID: userID, routineID: routine.id, title: routine.name, exercises: [weB])

        context.insert(routine)
        context.insert(workout)
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)

        XCTAssertTrue(plan.hasChanges)
        XCTAssertEqual(plan.addedExerciseIDs, [weB.id])
        XCTAssertEqual(plan.removedRoutineExerciseIDs, [reA.id])
    }

    func testCardioTargetNotFalselyReportedAsRemovedSet() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let cardioExerciseID = UUID()

        let cardioTarget = RoutineSetModel(userID: userID, position: 0, targetDurationSeconds: 1_800)
        let re = RoutineExerciseModel(userID: userID, exerciseID: cardioExerciseID, position: 0, sets: [cardioTarget])
        let routine = RoutineModel(userID: userID, name: "Cardio", exercises: [re])

        // Cardio workout exercise has no strength sets (matches WorkoutFactory).
        let we = WorkoutExerciseModel(userID: userID, exerciseID: cardioExerciseID, position: 0,
                                      sourceRoutineExerciseID: re.id, sets: [])
        let workout = WorkoutModel(userID: userID, routineID: routine.id, title: routine.name, exercises: [we])

        context.insert(routine)
        context.insert(workout)
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)

        XCTAssertFalse(plan.hasChanges)
        XCTAssertEqual(plan.exercisePlans.first?.removedRoutineSetIDs, [])
    }

    // MARK: - Apply

    func testApplyCreatesAddedSetFromPerformedValues() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let (routine, workout) = try seed(userID: userID, exerciseID: UUID(), in: context)

        let extra = SetModel(userID: userID, position: 1, setType: .working, reps: 10, weight: 70, rpe: 9)
        context.insert(extra)
        workout.exercises.first?.sets.append(extra)
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)
        try context.save()

        let routineSets = routine.exercises.first?.sets.sorted { $0.position < $1.position } ?? []
        XCTAssertEqual(routineSets.count, 2)
        // The added set's performed reps collapse to a single-value range.
        let added = routineSets[1]
        XCTAssertEqual(added.targetRepsLow, 10)
        XCTAssertEqual(added.targetRepsHigh, 10)
        XCTAssertEqual(added.targetWeight ?? -1, 70, accuracy: 0.0001)
        XCTAssertEqual(added.targetRPE ?? -1, 9, accuracy: 0.0001)
    }

    func testApplyPreservesTargetsOnMatchedSets() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let (routine, workout) = try seed(userID: userID, exerciseID: UUID(), in: context)

        // Perform different reps/weight (NOT a structural change — values ignored).
        let set = workout.exercises.first?.sets.first
        set?.reps = 3
        set?.weight = 999
        set?.recomputeDerivedMetrics()
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        XCTAssertFalse(plan.hasChanges)
        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)
        try context.save()

        // Standing target range is preserved (8–12 @ 60, RPE 8).
        let target = routine.exercises.first?.sets.first
        XCTAssertEqual(target?.targetRepsLow, 8)
        XCTAssertEqual(target?.targetRepsHigh, 12)
        XCTAssertEqual(target?.targetWeight ?? -1, 60, accuracy: 0.0001)
        XCTAssertEqual(target?.targetRPE ?? -1, 8, accuracy: 0.0001)
    }

    func testApplyUpdatesSetTypeOnMatchedSet() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let (routine, workout) = try seed(userID: userID, exerciseID: UUID(), in: context)

        workout.exercises.first?.sets.first?.setType = .drop
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)
        try context.save()

        XCTAssertEqual(routine.exercises.first?.sets.first?.setType, .drop)
        // Standing targets preserved despite type change.
        XCTAssertEqual(routine.exercises.first?.sets.first?.targetRepsLow, 8)
        XCTAssertEqual(routine.exercises.first?.sets.first?.targetRepsHigh, 12)
    }

    func testApplyRemovesDeletedExerciseAndSet() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let exerciseA = UUID(), exerciseB = UUID()

        let reA = RoutineExerciseModel(userID: userID, exerciseID: exerciseA, position: 0,
                                       sets: [RoutineSetModel(userID: userID, position: 0, targetRepsLow: 5)])
        let reB = RoutineExerciseModel(userID: userID, exerciseID: exerciseB, position: 1,
                                       sets: [RoutineSetModel(userID: userID, position: 0, targetRepsLow: 5)])
        let routine = RoutineModel(userID: userID, name: "Two", exercises: [reA, reB])

        let sA = SetModel(userID: userID, position: 0, sourceRoutineSetID: reA.sets.first!.id)
        let weA = WorkoutExerciseModel(userID: userID, exerciseID: exerciseA, position: 0,
                                      sourceRoutineExerciseID: reA.id, sets: [sA])
        let workout = WorkoutModel(userID: userID, routineID: routine.id, title: routine.name, exercises: [weA])

        context.insert(routine)
        context.insert(workout)
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        XCTAssertEqual(plan.removedRoutineExerciseIDs, [reB.id])
        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)
        try context.save()

        XCTAssertEqual(routine.exercises.count, 1)
        XCTAssertEqual(routine.exercises.first?.exerciseID, exerciseA)
    }

    func testApplyReordersAndRegroups() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let exerciseA = UUID(), exerciseB = UUID()

        let t1 = RoutineSetModel(userID: userID, position: 0, targetRepsLow: 8, targetWeight: 50)
        let reA = RoutineExerciseModel(userID: userID, exerciseID: exerciseA, position: 0, sets: [t1])
        let t2 = RoutineSetModel(userID: userID, position: 0, targetRepsLow: 5, targetWeight: 80)
        let reB = RoutineExerciseModel(userID: userID, exerciseID: exerciseB, position: 1, sets: [t2])
        let routine = RoutineModel(userID: userID, name: "Two", exercises: [reA, reB])

        let sA = SetModel(userID: userID, position: 0, sourceRoutineSetID: t1.id)
        let weA = WorkoutExerciseModel(userID: userID, exerciseID: exerciseA, position: 1, sourceRoutineExerciseID: reA.id, sets: [sA])
        let sB = SetModel(userID: userID, position: 0, sourceRoutineSetID: t2.id)
        let weB = WorkoutExerciseModel(userID: userID, exerciseID: exerciseB, position: 0, supersetGroup: 1, sourceRoutineExerciseID: reB.id, sets: [sB])
        let workout = WorkoutModel(userID: userID, routineID: routine.id, title: routine.name, exercises: [weB, weA])

        context.insert(routine)
        context.insert(workout)
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)
        try context.save()

        let sorted = routine.exercises.sorted { $0.position < $1.position }
        XCTAssertEqual(sorted.first?.exerciseID, exerciseB)
        XCTAssertEqual(sorted.first?.supersetGroup, 1)
        XCTAssertEqual(sorted.last?.exerciseID, exerciseA)
        XCTAssertEqual(sorted.last?.position, 1)
    }
}

// MARK: - Yoga flow drift

@MainActor
final class RoutineChangeSyncYogaTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func plan(_ names: [String]) -> YogaFlowPlan {
        YogaFlowPlan(style: .hatha, steps: names.map {
            YogaFlowPlan.PoseStep(poseID: UUID(), name: $0, holdSeconds: 30)
        })
    }

    /// Routine had an authored flow; the user edited it mid-session → the
    /// change is detected and applying it updates the routine's flow.
    func testEditedFlowSyncsBackToRoutine() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()

        let original = plan(["Pigeon Pose"]).encodedJSON()
        let routineExercise = RoutineExerciseModel(
            userID: userID, exerciseID: UUID(), position: 0, yogaFlowJSON: original
        )
        let routine = RoutineModel(userID: userID, name: "Evening", exercises: [routineExercise])
        let edited = plan(["Pigeon Pose", "Child's Pose"]).encodedJSON()
        let we = WorkoutExerciseModel(
            userID: userID, exerciseID: routineExercise.exerciseID, position: 0,
            yogaFlowJSON: edited, sourceRoutineExerciseID: routineExercise.id
        )
        let workout = WorkoutModel(userID: userID, endedAt: Date(), exercises: [we])
        context.insert(routine)
        context.insert(workout)
        try context.save()

        let detected = RoutineChangeSync.detect(workout: workout, routine: routine)
        XCTAssertTrue(detected.hasChanges)
        XCTAssertTrue(detected.exercisePlans.contains(where: \.flowChanged))
        XCTAssertTrue(detected.summary.contains("yoga flow updated"))

        RoutineChangeSync.apply(detected, to: routine, from: workout, in: context)
        XCTAssertEqual(routineExercise.yogaFlowJSON, edited)
        _ = container
    }

    /// The factory synthesizes a single-pose flow when the routine has none —
    /// that scaffolding must NOT read as user drift.
    func testSynthesizedSinglePoseFlowIsNotDrift() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()

        let routineExercise = RoutineExerciseModel(userID: userID, exerciseID: UUID(), position: 0)
        let routine = RoutineModel(userID: userID, name: "Wind Down", exercises: [routineExercise])
        let synthesized = plan(["Child's Pose"]).encodedJSON()
        let we = WorkoutExerciseModel(
            userID: userID, exerciseID: routineExercise.exerciseID, position: 0,
            yogaFlowJSON: synthesized, sourceRoutineExerciseID: routineExercise.id
        )
        let workout = WorkoutModel(userID: userID, endedAt: Date(), exercises: [we])
        context.insert(routine)
        context.insert(workout)
        try context.save()

        let detected = RoutineChangeSync.detect(workout: workout, routine: routine)
        XCTAssertFalse(detected.exercisePlans.contains(where: \.flowChanged))
        XCTAssertFalse(detected.hasChanges)
        _ = container
    }

    /// A yoga exercise added mid-session carries its flow into the routine
    /// (and gets no cardio duration-target set).
    func testYogaExerciseAddedMidSessionCopiesFlow() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()

        let routine = RoutineModel(userID: userID, name: "Mixed", exercises: [])
        let flow = plan(["Warrior II", "Triangle Pose"]).encodedJSON()
        let we = WorkoutExerciseModel(
            userID: userID, exerciseID: UUID(), position: 0, yogaFlowJSON: flow
        )
        let session = CardioSessionModel(
            userID: userID, workoutExerciseID: we.id,
            modality: CardioSessionModel.yogaModality, durationSeconds: 600
        )
        let workout = WorkoutModel(userID: userID, endedAt: Date(), exercises: [we], cardioSessions: [session])
        context.insert(routine)
        context.insert(workout)
        try context.save()

        let detected = RoutineChangeSync.detect(workout: workout, routine: routine)
        XCTAssertEqual(detected.addedExerciseIDs, [we.id])
        RoutineChangeSync.apply(detected, to: routine, from: workout, in: context)

        let added = try XCTUnwrap(routine.exercises.first)
        XCTAssertEqual(added.yogaFlowJSON, flow)
        XCTAssertTrue(added.sets.isEmpty)
        _ = container
    }
}
