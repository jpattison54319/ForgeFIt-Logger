import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct WorkoutBlockPipelineTests {
    private let userID = ForgeFitDemo.userID

    private func conditioningPlan(exerciseID: UUID) -> ConditioningPlan {
        ConditioningPlan(sections: [
            ConditioningSection(
                name: "Finisher",
                format: .amrap,
                durationSeconds: 600,
                movements: [ConditioningMovement(exerciseID: exerciseID, targetValue: 10)]
            )
        ])
    }

    @Test func firstClassRoutineBlockFreezesItsPlanAndOrigin() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let bench = ExerciseLibraryModel(name: "Bench Press")
        let burpee = ExerciseLibraryModel(name: "Burpee")
        context.insert(bench)
        context.insert(burpee)
        let plan = conditioningPlan(exerciseID: burpee.id)
        let routineBlock = RoutineBlockModel(
            userID: userID,
            kind: .conditioning,
            position: 1,
            planJSON: plan.encodedJSON()
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Push + Finish",
            exercises: [RoutineExerciseModel(userID: userID, exerciseID: bench.id, position: 0)],
            blocks: [routineBlock]
        )
        context.insert(routine)
        try context.save()

        let committedWorkout = WorkoutFactory.start(
            routine: routine, exercises: [bench, burpee], in: context, onCommit: { _ in }
        )
        let workout = try #require(committedWorkout)

        let block = try #require(workout.blocks.first)
        #expect(block.kind == .conditioning)
        #expect(block.sourceRoutineBlockID == routineBlock.id)
        #expect(ConditioningPlan.decode(from: block.planSnapshotJSON) == plan)
        #expect(ConditioningProgress.decode(from: block.progressJSON)?.status == .ready)
        let session = try #require(workout.cardioSessions.first { $0.workoutBlockID == block.id })
        #expect(session.isConditioningSession)
        #expect(session.workoutExerciseID == nil)
        #expect(workout.exercises.map(\.exerciseID) == [bench.id])
    }

    @Test func legacyConditioningProjectsOnlyItsMovementRowsIntoBlock() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let bench = ExerciseLibraryModel(name: "Bench Press")
        let burpee = ExerciseLibraryModel(name: "Burpee")
        context.insert(bench)
        context.insert(burpee)
        let plan = conditioningPlan(exerciseID: burpee.id)
        let routine = RoutineModel(
            userID: userID,
            name: "Legacy Mixed",
            conditioningPlanJSON: plan.encodedJSON(),
            exercises: [
                RoutineExerciseModel(userID: userID, exerciseID: bench.id, position: 0),
                RoutineExerciseModel(userID: userID, exerciseID: burpee.id, position: 1)
            ]
        )
        context.insert(routine)
        try context.save()

        let committedWorkout = WorkoutFactory.start(
            routine: routine, exercises: [bench, burpee], in: context, onCommit: { _ in }
        )
        let workout = try #require(committedWorkout)

        #expect(workout.blocks.count == 1)
        #expect(workout.blocks.first?.kind == .conditioning)
        #expect(workout.blocks.first?.sourceRoutineBlockID == nil)
        #expect(workout.exercises.map(\.exerciseID) == [bench.id])
        let ordered = OrderedWorkoutItem.ordered(in: workout)
        #expect(ordered.count == 2)
        #expect(ordered[0].position == 0)
        #expect(ordered[1].position == 1)
    }

    @Test func legacyConditioningStillProjectsBesideFirstClassYoga() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let bench = ExerciseLibraryModel(name: "Bench Press")
        let burpee = ExerciseLibraryModel(name: "Burpee")
        context.insert(bench)
        context.insert(burpee)
        let conditioning = conditioningPlan(exerciseID: burpee.id)
        let yoga = YogaFlowPlan(style: .hatha, steps: [
            YogaFlowPlan.PoseStep(poseID: UUID(), name: "Child's Pose", holdSeconds: 30)
        ])
        let yogaBlock = RoutineBlockModel(
            userID: userID,
            kind: .yoga,
            position: 1,
            planJSON: yoga.encodedJSON()
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Legacy Hybrid",
            conditioningPlanJSON: conditioning.encodedJSON(),
            exercises: [
                RoutineExerciseModel(userID: userID, exerciseID: bench.id, position: 0),
                RoutineExerciseModel(userID: userID, exerciseID: burpee.id, position: 2)
            ],
            blocks: [yogaBlock]
        )
        context.insert(routine)
        try context.save()

        let committedWorkout = WorkoutFactory.start(
            routine: routine, exercises: [bench, burpee], in: context, onCommit: { _ in }
        )
        let workout = try #require(committedWorkout)

        #expect(workout.blocks.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.conditioning, .yoga])
        #expect(workout.exercises.map(\.exerciseID) == [bench.id])
        #expect(OrderedWorkoutItem.ordered(in: workout).count == 3)
    }

    @Test func conditioningQuickStartFreezesOneExecutableBlock() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let exerciseID = UUID()
        let plan = conditioningPlan(exerciseID: exerciseID)

        let committedWorkout = WorkoutFactory.startConditioning(
            plan: plan,
            named: "Ten-Minute Finisher",
            in: context,
            onCommit: { _ in }
        )
        let workout = try #require(committedWorkout)

        #expect(workout.title == "Ten-Minute Finisher")
        #expect(workout.sourceDevice == "iphone-conditioning")
        #expect(workout.exercises.isEmpty)
        let block = try #require(workout.blocks.first)
        #expect(workout.blocks.count == 1)
        #expect(block.kind == .conditioning)
        #expect(ConditioningPlan.decode(from: block.planSnapshotJSON) == plan)
        #expect(ConditioningProgress.decode(from: block.progressJSON)?.status == .ready)
        let session = try #require(workout.cardioSessions.first)
        #expect(workout.cardioSessions.count == 1)
        #expect(session.isConditioningSession)
        #expect(session.workoutBlockID == block.id)

        let verification = ModelContext(container)
        let workoutID = workout.id
        let persisted = try #require(verification.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first)
        #expect(ConditioningPlan.decode(from: persisted.blocks.first?.planSnapshotJSON) == plan)
        #expect(persisted.cardioSessions.first?.workoutBlockID == persisted.blocks.first?.id)
    }

    @Test func conditioningQuickStartRejectsAnEmptyPlan() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }

        let committedWorkout = WorkoutFactory.startConditioning(
            plan: ConditioningPlan(sections: []),
            named: "Empty",
            in: context,
            onCommit: { _ in }
        )

        #expect(committedWorkout == nil)
        #expect(try context.fetch(FetchDescriptor<WorkoutModel>()).isEmpty)
    }
}
