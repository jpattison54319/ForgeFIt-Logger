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

    func testAddingCompletedCardioDoesNotTurnPerformedDurationIntoRoutineGoal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let routine = RoutineModel(userID: userID, name: "Mixed")
        let workoutExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            position: 0,
            sets: []
        )
        let performedSession = CardioSessionModel(
            userID: userID,
            workoutExerciseID: workoutExercise.id,
            modality: "run",
            durationSeconds: 535
        )
        let workout = WorkoutModel(
            userID: userID,
            routineID: routine.id,
            title: routine.name,
            exercises: [workoutExercise],
            cardioSessions: [performedSession]
        )
        context.insert(routine)
        context.insert(workout)
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        XCTAssertEqual(plan.addedExerciseIDs, [workoutExercise.id])
        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)
        try context.save()

        let added = try XCTUnwrap(routine.exercises.first)
        XCTAssertTrue(added.sets.isEmpty)
        XCTAssertNil(added.intervalPlanJSON)
    }

    func testAddingCardioPreservesOnlyItsExplicitlyAuthoredGoal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let routine = RoutineModel(userID: userID, name: "Mixed")
        let explicitPlan = IntervalPlan(
            steps: [],
            goal: .init(kind: .duration, value: 1_200)
        )
        let workoutExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            position: 0,
            intervalPlanJSON: explicitPlan.encodedJSON(),
            sets: []
        )
        let performedSession = CardioSessionModel(
            userID: userID,
            workoutExerciseID: workoutExercise.id,
            modality: "run",
            durationSeconds: 535
        )
        let workout = WorkoutModel(
            userID: userID,
            routineID: routine.id,
            title: routine.name,
            exercises: [workoutExercise],
            cardioSessions: [performedSession]
        )
        context.insert(routine)
        context.insert(workout)
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)
        try context.save()

        let added = try XCTUnwrap(routine.exercises.first)
        let storedPlan = try XCTUnwrap(IntervalPlan.decode(from: added.intervalPlanJSON))
        XCTAssertEqual(storedPlan.goal, explicitPlan.goal)
        XCTAssertEqual(storedPlan.goal?.value, 1_200)
        XCTAssertTrue(added.sets.isEmpty)
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

    // MARK: - Reported: "I said yes and the routine didn't change"

    /// An in-place swap keeps the routine lineage and changes only which
    /// movement the row points at. That was invisible to the diff, so a
    /// session where the lifter swapped an exercise reported "no changes" and
    /// the prompt never appeared — or appeared for some other edit and then
    /// applied everything except the swap.
    func testExerciseSwapIsDetectedAndApplied() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let original = UUID()
        let replacement = UUID()
        let seeded = try seed(userID: userID, exerciseID: original, in: context)

        seeded.workout.exercises[0].exerciseID = replacement

        let plan = RoutineChangeSync.detect(workout: seeded.workout, routine: seeded.routine)
        XCTAssertTrue(plan.hasChanges, "A swapped exercise is a structural change.")
        XCTAssertTrue(plan.exercisePlans[0].exerciseChanged)
        XCTAssertTrue(plan.summary.contains("swapped"), "Prompt must name the swap: \(plan.summary)")

        RoutineChangeSync.apply(plan, to: seeded.routine, from: seeded.workout, in: context)
        try context.save()

        XCTAssertEqual(seeded.routine.exercises[0].exerciseID, replacement,
                       "Saying yes must repoint the routine at the exercise actually performed.")
    }

    /// A swap must not cost the row its standing targets — only the movement
    /// changes, the programming stays.
    func testExerciseSwapPreservesStandingTargets() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let seeded = try seed(userID: userID, exerciseID: UUID(), in: context)
        let authoredTarget = seeded.routine.exercises[0].sets[0]
        authoredTarget.loadPrescriptionMode = .percentEstimatedOneRepMax
        authoredTarget.target1RMPercentLow = 75
        authoredTarget.target1RMPercentHigh = 80
        seeded.workout.exercises[0].exerciseID = UUID()
        // Performed something different from the standing target today.
        seeded.workout.exercises[0].sets[0].reps = 5
        seeded.workout.exercises[0].sets[0].weight = 100

        let plan = RoutineChangeSync.detect(workout: seeded.workout, routine: seeded.routine)
        RoutineChangeSync.apply(plan, to: seeded.routine, from: seeded.workout, in: context)
        try context.save()

        let target = seeded.routine.exercises[0].sets[0]
        XCTAssertEqual(target.targetRepsLow, 8)
        XCTAssertEqual(target.targetRepsHigh, 12)
        XCTAssertEqual(target.targetWeight, 60)
        XCTAssertEqual(target.loadPrescriptionMode, .percentEstimatedOneRepMax)
        XCTAssertEqual(target.target1RMPercentLow, 75)
        XCTAssertEqual(target.target1RMPercentHigh, 80)
    }

    func testCardioToStrengthSwapClearsIntervalPlanAndRebuildsTargets() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let cardioTarget = RoutineSetModel(
            userID: userID,
            position: 0,
            targetDurationSeconds: 1_800
        )
        let routineExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            intervalPlanJSON: #"{"steps":[{"kind":"work","seconds":60}]}"#,
            sets: [cardioTarget]
        )
        let routine = RoutineModel(userID: userID, name: "Mixed", exercises: [routineExercise])
        let strengthSet = SetModel(userID: userID, position: 0, reps: 8, weight: 50)
        let workoutExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            sourceRoutineExerciseID: routineExercise.id,
            sets: [strengthSet]
        )
        let workout = WorkoutModel(
            userID: userID,
            routineID: routine.id,
            title: routine.name,
            exercises: [workoutExercise]
        )
        context.insert(routine)
        context.insert(workout)

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)
        try context.save()

        XCTAssertNil(routineExercise.intervalPlanJSON)
        XCTAssertEqual(routineExercise.sets.count, 1)
        XCTAssertNil(routineExercise.sets[0].targetDurationSeconds)
        XCTAssertEqual(routineExercise.sets[0].targetRepsLow, 8)
        XCTAssertEqual(routineExercise.sets[0].targetWeight, 50)
    }

    func testStrengthToYogaSwapClearsIntervalPlanAndCopiesFlow() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let seeded = try seed(userID: userID, exerciseID: UUID(), in: context)
        let workoutExercise = seeded.workout.exercises[0]
        let flow = #"{"style":"vinyasa","steps":[{"name":"Warrior II","seconds":30}]}"#
        workoutExercise.exerciseID = UUID()
        workoutExercise.sets = []
        workoutExercise.intervalPlanJSON = nil
        workoutExercise.yogaFlowJSON = flow
        seeded.workout.cardioSessions = [CardioSessionModel(
            userID: userID,
            workoutExerciseID: workoutExercise.id,
            modality: CardioSessionModel.yogaModality
        )]

        let plan = RoutineChangeSync.detect(workout: seeded.workout, routine: seeded.routine)
        RoutineChangeSync.apply(plan, to: seeded.routine, from: seeded.workout, in: context)
        try context.save()

        let routineExercise = seeded.routine.exercises[0]
        XCTAssertNil(routineExercise.intervalPlanJSON)
        XCTAssertEqual(routineExercise.yogaFlowJSON, flow)
        XCTAssertTrue(routineExercise.sets.isEmpty)
    }

    /// The reported session: sets changed, a set type changed, and an exercise
    /// was swapped, all before tapping yes. Every one must land.
    func testSetTypeSetCountAndSwapAllApplyTogether() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let replacement = UUID()
        let seeded = try seed(userID: userID, exerciseID: UUID(), in: context)
        let we = seeded.workout.exercises[0]

        we.exerciseID = replacement                       // swap
        we.sets[0].setType = .drop                     // set type
        let added = SetModel(userID: userID, position: 1, setType: .working, reps: 6, weight: 70)
        context.insert(added)
        we.sets.append(added)                             // added set

        let plan = RoutineChangeSync.detect(workout: seeded.workout, routine: seeded.routine)
        XCTAssertTrue(plan.hasChanges)
        RoutineChangeSync.apply(plan, to: seeded.routine, from: seeded.workout, in: context)
        try context.save()

        let re = seeded.routine.exercises[0]
        XCTAssertEqual(re.exerciseID, replacement, "swap applied")
        XCTAssertEqual(re.sets.count, 2, "added set applied")
        let ordered = re.sets.sorted { $0.position < $1.position }
        XCTAssertEqual(ordered[0].setType, .drop, "set type applied")
        XCTAssertEqual(ordered[1].targetRepsLow, 6, "new set seeded from performed values")
    }

    /// Regression guard for the wipe this fix also closes: a routine whose row
    /// is a cardio duration target has no workout sets to rebuild from, so the
    /// rebuild had to be skipped rather than run against an empty list.
    func testAcceptingAnUnrelatedChangeDoesNotWipeCardioTargets() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()

        let cardioTarget = RoutineSetModel(userID: userID, position: 0, targetDurationSeconds: 1_800)
        let cardioRoutineExercise = RoutineExerciseModel(
            userID: userID, exerciseID: UUID(), position: 0, sets: [cardioTarget]
        )
        let liftTarget = RoutineSetModel(userID: userID, position: 0, targetRepsLow: 5, targetRepsHigh: 5)
        let liftRoutineExercise = RoutineExerciseModel(
            userID: userID, exerciseID: UUID(), position: 1, sets: [liftTarget]
        )
        let routine = RoutineModel(
            userID: userID, name: "Mixed",
            exercises: [cardioRoutineExercise, liftRoutineExercise]
        )

        // Cardio rows carry no strength sets in the workout (WorkoutFactory).
        let cardioRow = WorkoutExerciseModel(
            userID: userID, exerciseID: cardioRoutineExercise.exerciseID, position: 0,
            sourceRoutineExerciseID: cardioRoutineExercise.id, sets: []
        )
        let liftSet = SetModel(userID: userID, position: 0, setType: .working,
                               reps: 5, sourceRoutineSetID: liftTarget.id)
        let liftRow = WorkoutExerciseModel(
            userID: userID, exerciseID: liftRoutineExercise.exerciseID, position: 1,
            sourceRoutineExerciseID: liftRoutineExercise.id, sets: [liftSet]
        )
        let workout = WorkoutModel(
            userID: userID, routineID: routine.id, title: routine.name,
            exercises: [cardioRow, liftRow]
        )
        context.insert(routine)
        context.insert(workout)
        try context.save()

        // Unrelated change elsewhere in the session.
        liftRow.sets[0].setType = .drop

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)
        try context.save()

        let cardio = routine.exercises.first { $0.id == cardioRoutineExercise.id }
        XCTAssertEqual(cardio?.sets.count, 1, "The cardio duration target must survive.")
        XCTAssertEqual(cardio?.sets.first?.targetDurationSeconds, 1_800)
    }

    func testBlockChangesSyncAndGeneratedMovementRowsStayOutOfRoutine() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let (routine, workout) = try seed(userID: userID, exerciseID: UUID(), in: context)

        let matchedRoutineBlock = RoutineBlockModel(
            userID: userID,
            kind: .conditioning,
            position: 1,
            planJSON: #"{"name":"Original"}"#
        )
        let removedRoutineBlock = RoutineBlockModel(
            userID: userID,
            kind: .yoga,
            position: 2,
            planJSON: #"{"name":"Removed"}"#
        )
        context.insert(matchedRoutineBlock)
        context.insert(removedRoutineBlock)
        routine.blocks = [matchedRoutineBlock, removedRoutineBlock]

        let matchedWorkoutBlock = WorkoutBlockModel(
            userID: userID,
            kind: .conditioning,
            position: 0,
            planSnapshotJSON: #"{"name":"Edited"}"#,
            sourceRoutineBlockID: matchedRoutineBlock.id
        )
        let addedWorkoutBlock = WorkoutBlockModel(
            userID: userID,
            kind: .yoga,
            position: 2,
            planSnapshotJSON: #"{"name":"Added"}"#
        )
        context.insert(matchedWorkoutBlock)
        context.insert(addedWorkoutBlock)
        workout.blocks = [matchedWorkoutBlock, addedWorkoutBlock]

        // Conditioning movement rows are execution detail, not visible
        // routine items. Sync must not turn one into a normal exercise.
        let generated = WorkoutExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            position: 1,
            generatedByWorkoutBlockID: matchedWorkoutBlock.id
        )
        context.insert(generated)
        workout.exercises.append(generated)
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        XCTAssertTrue(plan.hasChanges)
        XCTAssertEqual(plan.addedBlockIDs, [addedWorkoutBlock.id])
        XCTAssertEqual(plan.removedRoutineBlockIDs, [removedRoutineBlock.id])
        XCTAssertFalse(plan.addedExerciseIDs.contains(generated.id))
        XCTAssertEqual(plan.blockPlans.first?.movedPosition, true)
        XCTAssertEqual(plan.blockPlans.first?.planChanged, true)
        XCTAssertTrue(plan.summary.contains("order changed"))
        XCTAssertTrue(plan.summary.contains("block plan updated"))

        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)
        try context.save()

        let synced = routine.blocks.sorted { $0.position < $1.position }
        XCTAssertEqual(synced.count, 2)
        XCTAssertEqual(synced.first?.id, matchedRoutineBlock.id)
        XCTAssertEqual(synced.first?.position, 0)
        XCTAssertEqual(synced.first?.planJSON, #"{"name":"Edited"}"#)
        XCTAssertEqual(synced.last?.kind, .yoga)
        XCTAssertEqual(synced.last?.planJSON, #"{"name":"Added"}"#)
        XCTAssertEqual(routine.exercises.count, 1)
    }

    func testSyncingYogaBlockDoesNotEraseLegacyConditioningPlan() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let legacyConditioning = #"{"legacy":true}"#
        let routineBlock = RoutineBlockModel(
            userID: userID,
            kind: .yoga,
            position: 0,
            planJSON: #"{"flow":"original"}"#
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Hybrid",
            conditioningPlanJSON: legacyConditioning,
            blocks: [routineBlock]
        )
        let workoutBlock = WorkoutBlockModel(
            userID: userID,
            kind: .yoga,
            position: 0,
            planSnapshotJSON: #"{"flow":"edited"}"#,
            sourceRoutineBlockID: routineBlock.id
        )
        let workout = WorkoutModel(userID: userID, blocks: [workoutBlock])
        context.insert(routine)
        context.insert(workout)
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)

        XCTAssertEqual(routine.conditioningPlanJSON, legacyConditioning)
        XCTAssertEqual(routine.blocks.first?.planJSON, #"{"flow":"edited"}"#)
    }

    /// Older builds split a replacement after completed work: the completed
    /// original row kept routine lineage and a fresh replacement row had none.
    /// The old diff therefore kept the original and appended the replacement.
    /// Recover that exact persisted shape as one identity-preserving swap.
    func testLegacySplitReplacementProducesOneExerciseInExactOrder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let originalExerciseID = UUID()
        let replacementExerciseID = UUID()

        func target(_ position: Int, weight: Double) -> RoutineSetModel {
            RoutineSetModel(
                userID: userID,
                position: position,
                targetRepsLow: 8,
                targetRepsHigh: 12,
                targetWeight: weight
            )
        }
        let before = RoutineExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            position: 0,
            sets: [target(0, weight: 20)]
        )
        let originalTargets = [target(0, weight: 60), target(1, weight: 65), target(2, weight: 70)]
        let replaced = RoutineExerciseModel(
            userID: userID,
            exerciseID: originalExerciseID,
            position: 1,
            sets: originalTargets
        )
        let after = RoutineExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            position: 2,
            sets: [target(0, weight: 30)]
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Legacy Split",
            exercises: [before, replaced, after]
        )

        let beforeWorkout = WorkoutExerciseModel(
            userID: userID,
            exerciseID: before.exerciseID,
            position: 0,
            sourceRoutineExerciseID: before.id,
            sets: [SetModel(userID: userID, sourceRoutineSetID: before.sets[0].id)]
        )
        let splitAt = Date(timeIntervalSince1970: 12_345)
        let completedHistory = WorkoutExerciseModel(
            userID: userID,
            exerciseID: originalExerciseID,
            position: 1,
            restSeconds: 120,
            microRestSeconds: 20,
            sourceRoutineExerciseID: replaced.id,
            updatedAt: splitAt,
            sets: [SetModel(
                userID: userID,
                position: 0,
                reps: 10,
                weight: 62.5,
                sourceRoutineSetID: originalTargets[0].id,
                completedAt: splitAt.addingTimeInterval(-30)
            )]
        )
        let replacement = WorkoutExerciseModel(
            userID: userID,
            exerciseID: replacementExerciseID,
            position: 2,
            restSeconds: 120,
            microRestSeconds: 20,
            createdAt: splitAt,
            updatedAt: splitAt,
            sets: [
                SetModel(userID: userID, position: 0, setType: .working, reps: 9, weight: 50),
                SetModel(userID: userID, position: 1, setType: .working, reps: 8, weight: 50)
            ]
        )
        let afterWorkout = WorkoutExerciseModel(
            userID: userID,
            exerciseID: after.exerciseID,
            position: 3,
            sourceRoutineExerciseID: after.id,
            sets: [SetModel(userID: userID, sourceRoutineSetID: after.sets[0].id)]
        )
        let workout = WorkoutModel(
            userID: userID,
            routineID: routine.id,
            exercises: [beforeWorkout, completedHistory, replacement, afterWorkout]
        )
        context.insert(routine)
        context.insert(workout)
        try context.save()

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        XCTAssertEqual(plan.historyOnlyWorkoutExerciseIDs, [completedHistory.id])
        XCTAssertTrue(plan.addedExerciseIDs.isEmpty)
        XCTAssertTrue(plan.removedRoutineExerciseIDs.isEmpty)
        XCTAssertEqual(
            plan.exercisePlans.first { $0.workoutExerciseID == replacement.id }?.matchedRoutineExerciseID,
            replaced.id
        )
        XCTAssertTrue(plan.summary.contains("swapped"))

        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)
        // Applying the same accepted plan again is the caller-context mirror
        // and retry shape. It must be idempotent — no duplicate IDs or rows.
        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)
        try context.save()

        let verification = ModelContext(container)
        let routineID = routine.id
        let persisted = try XCTUnwrap(verification.fetch(FetchDescriptor<RoutineModel>(
            predicate: #Predicate { $0.id == routineID }
        )).first)
        let ordered = persisted.exercises.sorted { $0.position < $1.position }
        XCTAssertEqual(ordered.map(\.exerciseID), [before.exerciseID, replacementExerciseID, after.exerciseID])
        XCTAssertEqual(ordered.map(\.position), [0, 1, 2])
        XCTAssertEqual(ordered.filter { $0.id == replaced.id }.count, 1)
        let persistedReplacement = try XCTUnwrap(ordered.first { $0.id == replaced.id })
        XCTAssertEqual(persistedReplacement.sets.sorted { $0.position < $1.position }.map(\.id), originalTargets.map(\.id))
        XCTAssertEqual(persistedReplacement.sets.sorted { $0.position < $1.position }.compactMap(\.targetWeight), [60, 65, 70])
    }

    func testNewModeSpecificSetsPersistTheVisibleAssistanceAndAddedLoad() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let userID = UUID()
        let seeded = try seed(userID: userID, exerciseID: UUID(), in: context)
        let workoutExercise = seeded.workout.exercises[0]

        let assisted = SetModel(
            userID: userID,
            position: 1,
            setType: .drop,
            weightMode: .bodyweightAssisted,
            assistanceWeight: 27.5,
            bodyweightKg: 80
        )
        let added = SetModel(
            userID: userID,
            position: 2,
            setType: .drop,
            weightMode: .bodyweightAdded,
            addedWeight: 7.5,
            bodyweightKg: 80
        )
        context.insert(assisted)
        context.insert(added)
        workoutExercise.sets.append(contentsOf: [assisted, added])

        let plan = RoutineChangeSync.detect(workout: seeded.workout, routine: seeded.routine)
        RoutineChangeSync.apply(plan, to: seeded.routine, from: seeded.workout, in: context)
        try context.save()

        let targets = seeded.routine.exercises[0].sets.sorted { $0.position < $1.position }
        XCTAssertEqual(targets[1].targetWeight, 27.5, "Assistance must not be read from raw external weight.")
        XCTAssertEqual(targets[2].targetWeight, 7.5, "Added load must not be read from raw external weight.")
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
