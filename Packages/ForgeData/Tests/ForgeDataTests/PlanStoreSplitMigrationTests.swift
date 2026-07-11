import Foundation
import SwiftData
import Testing
@testable import ForgeData

extension PersistenceSplitTests {
@Suite struct PlanStoreSplitMigrationTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a legacy combined store holding one fully-populated row of
    /// every PLAN type (progression fields included — the snapshot-drift
    /// trap) plus a LOG workout graph that must stay behind.
    @MainActor
    private func populateLegacyStore(at url: URL) throws -> (routineID: UUID, exerciseID: UUID, workoutID: UUID) {
        let container = try ModelContainer(
            for: Schema(ForgeDataSchema.models),
            configurations: [ModelConfiguration(schema: Schema(ForgeDataSchema.models), url: url, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let userID = UUID()

        let folder = RoutineFolderModel(id: UUID(), userID: userID, name: "Hypertrophy Block")
        folder.parentID = UUID()
        folder.position = 3
        context.insert(folder)

        let exercise = ExerciseLibraryModel(name: "Custom Landmine Press")
        exercise.ownerID = userID
        exercise.movementPattern = "push"
        exercise.primaryMuscles = ["shoulders"]
        exercise.secondaryMuscles = ["triceps"]
        exercise.equipment = "barbell"
        exercise.isUnilateral = true
        exercise.userModified = true
        exercise.needsReview = true
        exercise.classificationConfidence = 0.4
        exercise.importedRawName = "landmine prs"
        context.insert(exercise)

        context.insert(ExerciseAliasModel(exerciseID: exercise.id, ownerID: userID, alias: "LM Press"))

        let note = UserExerciseNoteModel(id: UUID(), userID: userID, exerciseID: exercise.id, note: "Seat 4, wide grip")
        note.seatHeight = "4"
        note.grip = "wide"
        note.machineSettingsJSON = #"{"pin":7}"#
        note.painFlag = true
        context.insert(note)

        let routine = RoutineModel(id: UUID(), userID: userID, name: "Push A")
        routine.notes = "Focus week"
        routine.folderID = folder.id
        routine.position = 1
        context.insert(routine)
        let routineExercise = RoutineExerciseModel(id: UUID(), userID: userID, exerciseID: exercise.id)
        routineExercise.position = 0
        routineExercise.supersetGroup = 2
        routineExercise.progressionRuleJSON = #"{"fixedIncrement":{"step":5}}"#
        routineExercise.notes = "Pause reps"
        routineExercise.intervalPlanJSON = #"{"steps":[]}"#
        routineExercise.yogaFlowJSON = nil
        context.insert(routineExercise)
        routine.exercises.append(routineExercise)
        let routineSet = RoutineSetModel(id: UUID(), userID: userID)
        routineSet.position = 0
        routineSet.targetRepsLow = 6
        routineSet.targetRepsHigh = 8
        routineSet.targetWeight = 40
        routineSet.targetRPE = 8
        routineSet.targetRIR = 2
        routineSet.plannedMiniSetCount = 3
        routineSet.plannedMiniRepsJSON = "[5,3,2]"
        context.insert(routineSet)
        routineExercise.sets.append(routineSet)

        context.insert(UserProgressModel(userID: userID, totalXP: 1234, level: 7))
        let xp = WorkoutXPEventModel(userID: userID, workoutID: UUID(), amount: 55, source: "workout")
        xp.componentsJSON = #"{"volume":30}"#
        context.insert(xp)
        let preset = IntervalPresetModel(userID: userID, name: "8x400", planJSON: #"{"steps":[1]}"#)
        context.insert(preset)
        let flow = YogaFlowModel(userID: userID, name: "Evening Unwind")
        flow.styleRaw = "yin"
        flow.planJSON = #"{"steps":[2]}"#
        flow.position = 2
        context.insert(flow)

        // LOG graph that must remain in the legacy store, untouched.
        let workout = WorkoutModel(userID: userID, title: "Push A — Monday")
        workout.routineID = routine.id
        let workoutExercise = WorkoutExerciseModel(userID: userID, exerciseID: exercise.id, position: 0)
        context.insert(workout)
        context.insert(workoutExercise)
        workout.exercises.append(workoutExercise)

        try context.save()
        return (routine.id, exercise.id, workout.id)
    }

    @MainActor
    @Test func migrationCopiesPlanRowsPreservingIDsAndFields() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("default.store")
        let planURL = dir.appendingPathComponent("plan.store")
        let ids = try populateLegacyStore(at: legacyURL)

        let summary = try PlanStoreSplitMigration.migrate(legacyStoreURL: legacyURL, planStoreURL: planURL)
        #expect(summary.copiedByType["RoutineModel"] == 1)
        #expect(summary.copiedByType["ExerciseLibraryModel"] == 1)
        #expect(summary.totalCopied == 9)

        let plan = try ModelContainer(
            for: Schema(ForgeDataSchema.planModels),
            configurations: [ModelConfiguration(schema: Schema(ForgeDataSchema.planModels), url: planURL, cloudKitDatabase: .none)]
        )
        let context = ModelContext(plan)

        let routine = try #require(try context.fetch(FetchDescriptor<RoutineModel>()).first)
        #expect(routine.id == ids.routineID)
        #expect(routine.notes == "Focus week")
        #expect(routine.position == 1)
        let routineExercise = try #require(routine.exercises.first)
        #expect(routineExercise.exerciseID == ids.exerciseID)
        #expect(routineExercise.supersetGroup == 2)
        #expect(routineExercise.progressionRuleJSON == #"{"fixedIncrement":{"step":5}}"#)
        let set = try #require(routineExercise.sets.first)
        #expect(set.targetRepsLow == 6)
        #expect(set.targetRIR == 2)
        #expect(set.plannedMiniRepsJSON == "[5,3,2]")

        let exercise = try #require(try context.fetch(FetchDescriptor<ExerciseLibraryModel>()).first)
        #expect(exercise.id == ids.exerciseID)
        #expect(exercise.isUnilateral)
        #expect(exercise.needsReview)
        #expect(exercise.classificationConfidence == 0.4)
        #expect(exercise.importedRawName == "landmine prs")

        let note = try #require(try context.fetch(FetchDescriptor<UserExerciseNoteModel>()).first)
        #expect(note.machineSettingsJSON == #"{"pin":7}"#)
        #expect(note.painFlag)

        #expect(try context.fetch(FetchDescriptor<UserProgressModel>()).first?.totalXP == 1234)
        #expect(try context.fetch(FetchDescriptor<WorkoutXPEventModel>()).first?.componentsJSON == #"{"volume":30}"#)
        #expect(try context.fetch(FetchDescriptor<IntervalPresetModel>()).first?.name == "8x400")
        #expect(try context.fetch(FetchDescriptor<YogaFlowModel>()).first?.styleRaw == "yin")
        #expect(try context.fetch(FetchDescriptor<RoutineFolderModel>()).first?.name == "Hypertrophy Block")
    }

    @MainActor
    @Test func migrationIsIdempotent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("default.store")
        let planURL = dir.appendingPathComponent("plan.store")
        _ = try populateLegacyStore(at: legacyURL)

        let first = try PlanStoreSplitMigration.migrate(legacyStoreURL: legacyURL, planStoreURL: planURL)
        #expect(first.totalCopied == 9)
        let second = try PlanStoreSplitMigration.migrate(legacyStoreURL: legacyURL, planStoreURL: planURL)
        #expect(second.totalCopied == 0)
    }

    /// Simulates the final container's first open: the legacy store opened
    /// with the LOG-only schema keeps its LOG rows fully intact.
    @MainActor
    @Test func legacyStoreKeepsLogRowsAfterLogOnlyReopen() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("default.store")
        let planURL = dir.appendingPathComponent("plan.store")
        let ids = try populateLegacyStore(at: legacyURL)
        _ = try PlanStoreSplitMigration.migrate(legacyStoreURL: legacyURL, planStoreURL: planURL)

        let logOnly = try ModelContainer(
            for: Schema(ForgeDataSchema.logModels),
            configurations: [ModelConfiguration(schema: Schema(ForgeDataSchema.logModels), url: legacyURL, cloudKitDatabase: .none)]
        )
        let context = ModelContext(logOnly)
        let workouts = try context.fetch(FetchDescriptor<WorkoutModel>())
        #expect(workouts.map(\.id) == [ids.workoutID])
        #expect(workouts.first?.routineID == ids.routineID)
        #expect(workouts.first?.exercises.count == 1)
    }

    /// The Coach's Corner models post-date this migration: they're
    /// registered in `planModels` (so they get their own store from day
    /// one) but deliberately carry no `copyXxx` function, since no legacy
    /// combined store can contain rows of these types.
    @MainActor
    @Test func postSplitModelsAreRegisteredButNeverCopied() throws {
        let planNames = Set(ForgeDataSchema.planModels.map { String(describing: $0) })
        for name in PlanStoreSplitMigration.postSplitModelNames {
            #expect(planNames.contains(name), "\(name) must be registered in ForgeDataSchema.planModels")
        }

        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("default.store")
        let planURL = dir.appendingPathComponent("plan.store")
        _ = try populateLegacyStore(at: legacyURL)

        let summary = try PlanStoreSplitMigration.migrate(legacyStoreURL: legacyURL, planStoreURL: planURL)
        #expect(summary.totalCopied == 9)
        for name in PlanStoreSplitMigration.postSplitModelNames {
            #expect(summary.copiedByType[name] == nil)
        }
    }
}
}
