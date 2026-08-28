import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
@Suite("Routine legacy block migration")
struct RoutineLegacyBlockMigrationTests {
    private let userID = ForgeFitDemo.userID

    @Test("A modern routine is a mutation-free no-op")
    func modernRoutineIsNoOp() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        context.autosaveEnabled = false
        let exerciseDate = Date(timeIntervalSince1970: 1_000)
        let blockDate = Date(timeIntervalSince1970: 2_000)
        let routineDate = Date(timeIntervalSince1970: 3_000)
        let library = ExerciseLibraryModel(name: "Bench Press")
        let exercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: library.id,
            position: 4,
            updatedAt: exerciseDate
        )
        let block = RoutineBlockModel(
            userID: userID,
            kind: .conditioning,
            position: 9,
            planJSON: conditioningPlan(exerciseID: UUID()).encodedJSON(),
            updatedAt: blockDate
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Modern",
            updatedAt: routineDate,
            exercises: [exercise],
            blocks: [block]
        )
        context.insert(library)
        context.insert(routine)
        try context.save()
        #expect(!context.hasChanges)

        let didChange = RoutineLegacyBlockMigration.migrateIfNeeded(
            routine: routine,
            exercises: [library],
            in: context
        )

        #expect(!didChange)
        #expect(!context.hasChanges)
        #expect(routine.updatedAt == routineDate)
        #expect(exercise.updatedAt == exerciseDate)
        #expect(block.updatedAt == blockDate)
        #expect(exercise.position == 4)
        #expect(block.position == 9)
    }

    @Test("Legacy conditioning becomes one block and removes only its movement rows")
    func convertsConditioning() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        context.autosaveEnabled = false
        let bench = ExerciseLibraryModel(name: "Bench Press")
        let burpee = ExerciseLibraryModel(name: "Burpee")
        let plan = conditioningPlan(exerciseID: burpee.id)
        let planJSON = plan.encodedJSON()
        let strengthRow = RoutineExerciseModel(
            userID: userID,
            exerciseID: bench.id,
            position: 0
        )
        let conditioningRow = RoutineExerciseModel(
            userID: userID,
            exerciseID: burpee.id,
            position: 1
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Legacy Conditioning",
            conditioningPlanJSON: planJSON,
            exercises: [strengthRow, conditioningRow]
        )
        [bench, burpee].forEach(context.insert)
        context.insert(routine)
        try context.save()

        let didChange = RoutineLegacyBlockMigration.migrateIfNeeded(
            routine: routine,
            exercises: [bench, burpee],
            in: context
        )

        #expect(didChange)
        #expect(context.hasChanges)
        #expect(routine.conditioningPlanJSON == nil)
        #expect(routine.exercises.map(\.id) == [strengthRow.id])
        let block = try #require(routine.blocks.first)
        #expect(routine.blocks.count == 1)
        #expect(block.kind == .conditioning)
        #expect(block.planJSON == planJSON)
        #expect(OrderedRoutineItem.ordered(in: routine).map(\.position) == [0, 1])
        #expect(try context.fetch(FetchDescriptor<RoutineExerciseModel>()).map(\.id) == [strengthRow.id])
    }

    @Test("Yoga library rows and attached flows become independent Yoga blocks")
    func convertsYoga() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        context.autosaveEnabled = false
        let yogaPose = ExerciseLibraryModel(
            name: "Child's Pose",
            modalityRaw: Modality.yoga.rawValue
        )
        let customFlowExercise = ExerciseLibraryModel(name: "Mobility Flow")
        let flowJSON = yogaPlan().encodedJSON()
        let catalogYogaRow = RoutineExerciseModel(
            userID: userID,
            exerciseID: yogaPose.id,
            position: 0
        )
        let attachedFlowRow = RoutineExerciseModel(
            userID: userID,
            exerciseID: customFlowExercise.id,
            position: 1,
            yogaFlowJSON: flowJSON
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Legacy Yoga",
            exercises: [catalogYogaRow, attachedFlowRow]
        )
        [yogaPose, customFlowExercise].forEach(context.insert)
        context.insert(routine)
        try context.save()

        let didChange = RoutineLegacyBlockMigration.migrateIfNeeded(
            routine: routine,
            exercises: [yogaPose, customFlowExercise],
            in: context
        )

        #expect(didChange)
        #expect(routine.exercises.isEmpty)
        let blocks = routine.blocks.sorted { $0.position < $1.position }
        #expect(blocks.count == 2)
        #expect(blocks.allSatisfy { $0.kind == .yoga })
        #expect(blocks.map(\.planJSON) == [nil, flowJSON])
        #expect(blocks.map(\.position) == [0, 1])
    }

    @Test("Migration is idempotent after the caller commits it")
    func migrationIsIdempotent() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        context.autosaveEnabled = false
        let yogaPose = ExerciseLibraryModel(
            name: "Savasana",
            modalityRaw: Modality.yoga.rawValue
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Legacy Once",
            exercises: [
                RoutineExerciseModel(
                    userID: userID,
                    exerciseID: yogaPose.id,
                    position: 3,
                    yogaFlowJSON: yogaPlan().encodedJSON()
                )
            ]
        )
        context.insert(yogaPose)
        context.insert(routine)
        try context.save()

        #expect(RoutineLegacyBlockMigration.migrateIfNeeded(
            routine: routine,
            exercises: [yogaPose],
            in: context
        ))
        try context.save()
        #expect(!context.hasChanges)
        let blockIDs = routine.blocks.map(\.id)

        #expect(!RoutineLegacyBlockMigration.migrateIfNeeded(
            routine: routine,
            exercises: [yogaPose],
            in: context
        ))
        #expect(!context.hasChanges)
        #expect(routine.blocks.map(\.id) == blockIDs)
    }

    @Test("Mixed converted and modern items receive one contiguous order")
    func normalizesMixedOrdering() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        context.autosaveEnabled = false
        let squat = ExerciseLibraryModel(name: "Back Squat")
        let burpee = ExerciseLibraryModel(name: "Burpee")
        let yogaPose = ExerciseLibraryModel(
            name: "Pigeon Pose",
            modalityRaw: Modality.yoga.rawValue
        )
        let strengthRow = RoutineExerciseModel(
            userID: userID,
            exerciseID: squat.id,
            position: 8
        )
        let conditioningRow = RoutineExerciseModel(
            userID: userID,
            exerciseID: burpee.id,
            position: 11
        )
        let yogaRow = RoutineExerciseModel(
            userID: userID,
            exerciseID: yogaPose.id,
            position: 5,
            yogaFlowJSON: yogaPlan().encodedJSON()
        )
        let modernBlock = RoutineBlockModel(
            userID: userID,
            kind: .conditioning,
            position: 2,
            planJSON: #"{"modern":true}"#
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Mixed",
            conditioningPlanJSON: conditioningPlan(exerciseID: burpee.id).encodedJSON(),
            exercises: [strengthRow, conditioningRow, yogaRow],
            blocks: [modernBlock]
        )
        [squat, burpee, yogaPose].forEach(context.insert)
        context.insert(routine)
        try context.save()

        #expect(RoutineLegacyBlockMigration.migrateIfNeeded(
            routine: routine,
            exercises: [squat, burpee, yogaPose],
            in: context
        ))

        let ordered = OrderedRoutineItem.ordered(in: routine)
        #expect(ordered.map(\.position) == Array(0..<ordered.count))
        #expect(ordered.count == 4)
        #expect(Set(routine.exercises.map(\.id)) == Set([strengthRow.id, conditioningRow.id]))
        #expect(routine.blocks.filter { $0.kind == .conditioning }.count == 1)
        #expect(routine.blocks.filter { $0.kind == .yoga }.count == 1)
    }

    @Test("Caller save makes the migrated graph durable in a fresh context")
    func callerSavePersistsMigration() throws {
        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let bench = ExerciseLibraryModel(name: "Bench Press")
        let burpee = ExerciseLibraryModel(name: "Burpee")
        let routine = RoutineModel(
            userID: userID,
            name: "Durable Migration",
            conditioningPlanJSON: conditioningPlan(exerciseID: burpee.id).encodedJSON(),
            exercises: [
                RoutineExerciseModel(userID: userID, exerciseID: bench.id, position: 0),
                RoutineExerciseModel(userID: userID, exerciseID: burpee.id, position: 1)
            ]
        )
        [bench, burpee].forEach(context.insert)
        context.insert(routine)
        try context.save()

        #expect(RoutineLegacyBlockMigration.migrateIfNeeded(
            routine: routine,
            exercises: [bench, burpee],
            in: context
        ))
        #expect(context.hasChanges)
        try context.save()

        let verificationContext = ModelContext(container)
        verificationContext.autosaveEnabled = false
        let routineID = routine.id
        let persisted = try #require(verificationContext.fetch(
            FetchDescriptor<RoutineModel>(
                predicate: #Predicate { $0.id == routineID }
            )
        ).first)
        #expect(persisted.conditioningPlanJSON == nil)
        #expect(persisted.exercises.map(\.exerciseID) == [bench.id])
        let block = try #require(persisted.blocks.first)
        #expect(persisted.blocks.count == 1)
        #expect(block.kind == .conditioning)
        #expect(block.position == 1)
    }

    private func conditioningPlan(exerciseID: UUID) -> ConditioningPlan {
        ConditioningPlan(sections: [
            ConditioningSection(
                name: "Finisher",
                format: .amrap,
                durationSeconds: 600,
                movements: [
                    ConditioningMovement(exerciseID: exerciseID, targetValue: 10)
                ]
            )
        ])
    }

    private func yogaPlan() -> YogaFlowPlan {
        YogaFlowPlan(style: .hatha, steps: [
            YogaFlowPlan.PoseStep(
                poseID: UUID(),
                name: "Child's Pose",
                holdSeconds: 30
            )
        ])
    }
}
