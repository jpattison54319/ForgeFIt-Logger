import Foundation
import SwiftData

/// One-time copy of PLAN-layer rows out of the legacy combined store into
/// the dedicated plan store, part of the 5.1.3(ii) persistence split (plan
/// data syncs via CloudKit; the training log stays local).
///
/// Contract:
/// - Idempotent and crash-safe: rows already present in the destination
///   (matched by `id`) are skipped, so a re-run after a mid-copy crash
///   finishes the job without duplicating anything.
/// - IDs are preserved — live workouts reference routines and exercises by
///   UUID (`routineID`, `exerciseID`, `sourceRoutineSetID`…) and those
///   references must keep resolving after the split.
/// - Both stores are opened with `cloudKitDatabase: .none`; CloudKit must
///   not start mirroring until the app's final container owns plan.store.
/// - The caller only marks migration done after this returns successfully.
///   Legacy PLAN rows are deliberately left in the old store — the final
///   container's first LOG-only open drops those tables automatically.
public enum PlanStoreSplitMigration {

    public struct Summary: Sendable {
        public var copiedByType: [String: Int] = [:]
        public var totalCopied: Int { copiedByType.values.reduce(0, +) }
    }

    /// PLAN models added to `ForgeDataSchema.planModels` after this
    /// migration shipped (the Coach's Corner models). They deliberately
    /// have no `copyXxx` function and never appear in `Summary.copiedByType`:
    /// any legacy combined store old enough to still need this migration
    /// predates their existence, so there are no rows of these types to
    /// find in it. Coaching data is always created fresh directly in
    /// plan.store.
    public static let postSplitModelNames: Set<String> = [
        "CoachingProfileModel", "CoachedProgramModel", "CoachingWeekOverrideModel"
    ]

    @MainActor
    public static func migrate(legacyStoreURL: URL, planStoreURL: URL) throws -> Summary {
        var summary = Summary()

        // Scoped so both temp containers deinit before the caller reopens
        // either store file.
        try autoreleasepool {
            let legacy = try ModelContainer(
                for: Schema(ForgeDataSchema.models),
                configurations: [ModelConfiguration(
                    schema: Schema(ForgeDataSchema.models),
                    url: legacyStoreURL,
                    cloudKitDatabase: .none
                )]
            )
            let plan = try ModelContainer(
                for: Schema(ForgeDataSchema.planModels),
                configurations: [ModelConfiguration(
                    schema: Schema(ForgeDataSchema.planModels),
                    url: planStoreURL,
                    cloudKitDatabase: .none
                )]
            )
            let source = ModelContext(legacy)
            let destination = ModelContext(plan)

            summary.copiedByType["RoutineFolderModel"] = try copyFolders(source, destination)
            summary.copiedByType["ExerciseLibraryModel"] = try copyExercises(source, destination)
            summary.copiedByType["ExerciseAliasModel"] = try copyAliases(source, destination)
            summary.copiedByType["UserExerciseNoteModel"] = try copyNotes(source, destination)
            summary.copiedByType["RoutineModel"] = try copyRoutineGraphs(source, destination)
            summary.copiedByType["UserProgressModel"] = try copyProgress(source, destination)
            summary.copiedByType["WorkoutXPEventModel"] = try copyXPEvents(source, destination)
            summary.copiedByType["IntervalPresetModel"] = try copyIntervalPresets(source, destination)
            summary.copiedByType["YogaFlowModel"] = try copyYogaFlows(source, destination)

            try destination.save()
        }
        return summary
    }

    // MARK: - Per-type copies
    // Every stored property is assigned explicitly. When a field is added to
    // a PLAN model it must be carried here too — the migration round-trip
    // test compares full field sets to catch drift.

    private static func existingIDs<T: PersistentModel>(_ type: T.Type, in context: ModelContext, id: KeyPath<T, UUID>) throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<T>()).map { $0[keyPath: id] })
    }

    @MainActor
    private static func copyFolders(_ source: ModelContext, _ destination: ModelContext) throws -> Int {
        let present = try existingIDs(RoutineFolderModel.self, in: destination, id: \.id)
        var copied = 0
        for row in try source.fetch(FetchDescriptor<RoutineFolderModel>()) where !present.contains(row.id) {
            let copy = RoutineFolderModel(id: row.id, userID: row.userID, name: row.name)
            copy.position = row.position
            copy.parentID = row.parentID
            copy.createdAt = row.createdAt
            copy.updatedAt = row.updatedAt
            copy.deletedAt = row.deletedAt
            destination.insert(copy)
            copied += 1
        }
        return copied
    }

    @MainActor
    private static func copyExercises(_ source: ModelContext, _ destination: ModelContext) throws -> Int {
        let present = try existingIDs(ExerciseLibraryModel.self, in: destination, id: \.id)
        var copied = 0
        for row in try source.fetch(FetchDescriptor<ExerciseLibraryModel>()) where !present.contains(row.id) {
            let copy = ExerciseLibraryModel(name: row.name)
            copy.id = row.id
            copy.ownerID = row.ownerID
            copy.movementPattern = row.movementPattern
            copy.primaryMuscles = row.primaryMuscles
            copy.secondaryMuscles = row.secondaryMuscles
            copy.equipment = row.equipment
            copy.isUnilateral = row.isUnilateral
            copy.defaultWeightModeRaw = row.defaultWeightModeRaw
            copy.preferredWeightUnitRaw = row.preferredWeightUnitRaw
            copy.difficulty = row.difficulty
            copy.isCardio = row.isCardio
            copy.cardioKindRaw = row.cardioKindRaw
            copy.modalityRaw = row.modalityRaw
            copy.defaultHoldSeconds = row.defaultHoldSeconds
            copy.mappedGlobalID = row.mappedGlobalID
            copy.instructions = row.instructions
            copy.mechanic = row.mechanic
            copy.mediaSlug = row.mediaSlug
            copy.category = row.category
            copy.force = row.force
            copy.userModified = row.userModified
            copy.needsReview = row.needsReview
            copy.classificationConfidence = row.classificationConfidence
            copy.classificationSourceRaw = row.classificationSourceRaw
            copy.importBatchID = row.importBatchID
            copy.importedRawName = row.importedRawName
            copy.createdAt = row.createdAt
            copy.updatedAt = row.updatedAt
            copy.deletedAt = row.deletedAt
            destination.insert(copy)
            copied += 1
        }
        return copied
    }

    @MainActor
    private static func copyAliases(_ source: ModelContext, _ destination: ModelContext) throws -> Int {
        let present = try existingIDs(ExerciseAliasModel.self, in: destination, id: \.id)
        var copied = 0
        for row in try source.fetch(FetchDescriptor<ExerciseAliasModel>()) where !present.contains(row.id) {
            destination.insert(ExerciseAliasModel(
                id: row.id, exerciseID: row.exerciseID, ownerID: row.ownerID,
                alias: row.alias, createdAt: row.createdAt
            ))
            copied += 1
        }
        return copied
    }

    @MainActor
    private static func copyNotes(_ source: ModelContext, _ destination: ModelContext) throws -> Int {
        let present = try existingIDs(UserExerciseNoteModel.self, in: destination, id: \.id)
        var copied = 0
        for row in try source.fetch(FetchDescriptor<UserExerciseNoteModel>()) where !present.contains(row.id) {
            let copy = UserExerciseNoteModel(id: row.id, userID: row.userID, exerciseID: row.exerciseID, note: row.note)
            copy.seatHeight = row.seatHeight
            copy.grip = row.grip
            copy.stance = row.stance
            copy.machineSettingsJSON = row.machineSettingsJSON
            copy.painFlag = row.painFlag
            copy.createdAt = row.createdAt
            copy.updatedAt = row.updatedAt
            destination.insert(copy)
            copied += 1
        }
        return copied
    }

    /// Routines copy as whole graphs (routine → exercises → sets) with
    /// original IDs, so `sourceRoutineExerciseID`/`sourceRoutineSetID` on
    /// live workouts keep resolving. Unlike RoutineSnapshot (editor scope),
    /// this carries the progression fields too.
    @MainActor
    private static func copyRoutineGraphs(_ source: ModelContext, _ destination: ModelContext) throws -> Int {
        let present = try existingIDs(RoutineModel.self, in: destination, id: \.id)
        var copied = 0
        for routine in try source.fetch(FetchDescriptor<RoutineModel>()) where !present.contains(routine.id) {
            let copy = RoutineModel(id: routine.id, userID: routine.userID, name: routine.name)
            copy.notes = routine.notes
            copy.folder = routine.folder
            copy.folderID = routine.folderID
            copy.position = routine.position
            copy.createdAt = routine.createdAt
            copy.updatedAt = routine.updatedAt
            copy.deletedAt = routine.deletedAt
            destination.insert(copy)

            for exercise in routine.exercises.sorted(by: { $0.position < $1.position }) {
                let exerciseCopy = RoutineExerciseModel(id: exercise.id, userID: exercise.userID, exerciseID: exercise.exerciseID)
                exerciseCopy.position = exercise.position
                exerciseCopy.supersetGroup = exercise.supersetGroup
                exerciseCopy.progressionRuleID = exercise.progressionRuleID
                exerciseCopy.progressionRuleJSON = exercise.progressionRuleJSON
                exerciseCopy.notes = exercise.notes
                exerciseCopy.intervalPlanJSON = exercise.intervalPlanJSON
                exerciseCopy.yogaFlowJSON = exercise.yogaFlowJSON
                exerciseCopy.createdAt = exercise.createdAt
                exerciseCopy.updatedAt = exercise.updatedAt
                destination.insert(exerciseCopy)
                copy.exercises.append(exerciseCopy)

                for set in exercise.sets.sorted(by: { $0.position < $1.position }) {
                    let setCopy = RoutineSetModel(id: set.id, userID: set.userID)
                    setCopy.position = set.position
                    setCopy.setTypeRaw = set.setTypeRaw
                    setCopy.targetRepsLow = set.targetRepsLow
                    setCopy.targetRepsHigh = set.targetRepsHigh
                    setCopy.targetWeight = set.targetWeight
                    setCopy.targetRPE = set.targetRPE
                    setCopy.targetRIR = set.targetRIR
                    setCopy.targetDurationSeconds = set.targetDurationSeconds
                    setCopy.plannedMiniSetCount = set.plannedMiniSetCount
                    setCopy.plannedMiniRepsJSON = set.plannedMiniRepsJSON
                    setCopy.createdAt = set.createdAt
                    destination.insert(setCopy)
                    exerciseCopy.sets.append(setCopy)
                }
            }
            copied += 1
        }
        return copied
    }

    @MainActor
    private static func copyProgress(_ source: ModelContext, _ destination: ModelContext) throws -> Int {
        let present = try existingIDs(UserProgressModel.self, in: destination, id: \.id)
        var copied = 0
        for row in try source.fetch(FetchDescriptor<UserProgressModel>()) where !present.contains(row.id) {
            destination.insert(UserProgressModel(
                id: row.id, userID: row.userID, totalXP: row.totalXP, level: row.level,
                createdAt: row.createdAt, updatedAt: row.updatedAt, deletedAt: row.deletedAt
            ))
            copied += 1
        }
        return copied
    }

    @MainActor
    private static func copyXPEvents(_ source: ModelContext, _ destination: ModelContext) throws -> Int {
        let present = try existingIDs(WorkoutXPEventModel.self, in: destination, id: \.id)
        var copied = 0
        for row in try source.fetch(FetchDescriptor<WorkoutXPEventModel>()) where !present.contains(row.id) {
            let copy = WorkoutXPEventModel(userID: row.userID, workoutID: row.workoutID, amount: row.amount, source: row.source)
            copy.id = row.id
            copy.componentsJSON = row.componentsJSON
            copy.createdAt = row.createdAt
            copy.deletedAt = row.deletedAt
            destination.insert(copy)
            copied += 1
        }
        return copied
    }

    @MainActor
    private static func copyIntervalPresets(_ source: ModelContext, _ destination: ModelContext) throws -> Int {
        let present = try existingIDs(IntervalPresetModel.self, in: destination, id: \.id)
        var copied = 0
        for row in try source.fetch(FetchDescriptor<IntervalPresetModel>()) where !present.contains(row.id) {
            let copy = IntervalPresetModel(userID: row.userID, name: row.name, planJSON: row.planJSON)
            copy.id = row.id
            copy.createdAt = row.createdAt
            copy.updatedAt = row.updatedAt
            copy.deletedAt = row.deletedAt
            destination.insert(copy)
            copied += 1
        }
        return copied
    }

    @MainActor
    private static func copyYogaFlows(_ source: ModelContext, _ destination: ModelContext) throws -> Int {
        let present = try existingIDs(YogaFlowModel.self, in: destination, id: \.id)
        var copied = 0
        for row in try source.fetch(FetchDescriptor<YogaFlowModel>()) where !present.contains(row.id) {
            let copy = YogaFlowModel(userID: row.userID, name: row.name)
            copy.id = row.id
            copy.styleRaw = row.styleRaw
            copy.planJSON = row.planJSON
            copy.position = row.position
            copy.createdAt = row.createdAt
            copy.updatedAt = row.updatedAt
            copy.deletedAt = row.deletedAt
            destination.insert(copy)
            copied += 1
        }
        return copied
    }
}
