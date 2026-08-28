import Foundation
import ForgeCore
import SwiftData

@MainActor
public enum ExerciseSeedRepository {

    public static func seedGlobalLibrary(
        _ snapshot: ExerciseLibrarySnapshot = GlobalExerciseLibrary.snapshot,
        in context: ModelContext,
        persist: Bool = true
    ) throws {
        try stageGlobalLibrary(snapshot, in: context)

        if persist, context.hasChanges {
            try context.save()
        }
    }

    /// Launch-safe variant of ``seedGlobalLibrary(_:in:persist:)``. A catalog
    /// version upgrade can encounter the user's full exercise library, so even
    /// this small built-in snapshot must not fetch or reconcile on MainActor.
    /// The worker owns a fresh context; only the immutable snapshot and the
    /// container cross the isolation boundary.
    public static func seedGlobalLibraryCooperatively(
        _ snapshot: ExerciseLibrarySnapshot = GlobalExerciseLibrary.snapshot,
        in context: ModelContext
    ) async throws {
        try Task.checkCancellation()
        let container = context.container
        let task = Task.detached(priority: .utility) {
            let transaction = ModelContext(container)
            transaction.autosaveEnabled = false
            do {
                try Task.checkCancellation()
                try stageGlobalLibrary(snapshot, in: transaction)
                try Task.checkCancellation()
                if transaction.hasChanges {
                    try transaction.save()
                }
            } catch {
                transaction.rollback()
                throw error
            }
        }
        try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    private nonisolated static func stageGlobalLibrary(
        _ snapshot: ExerciseLibrarySnapshot,
        in context: ModelContext
    ) throws {
        let existingExercises = Dictionary(
            try context.fetch(FetchDescriptor<ExerciseLibraryModel>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingAliases = Dictionary(
            try context.fetch(FetchDescriptor<ExerciseAliasModel>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for exercise in snapshot.exercises {
            try Task.checkCancellation()
            let existing = existingExercises[exercise.id]
            let model = existing ?? ExerciseLibraryModel(id: exercise.id, name: exercise.name)
            var modelChanged = false
            if existing == nil {
                context.insert(model)
                modelChanged = true
            }

            // Diff before assigning: unconditional writes dirtied the 11
            // built-ins on every seed pass, pushing them to CloudKit each
            // time even when nothing changed.
            func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ExerciseLibraryModel, Value>, _ value: Value) {
                guard model[keyPath: keyPath] != value else { return }
                model[keyPath: keyPath] = value
                modelChanged = true
            }

            // Always keep the catalog linkage current, but never clobber a
            // built-in the user has edited — their name/muscles/equipment win.
            set(\.mappedGlobalID, exercise.mappedGlobalID)
            if existing?.userModified != true {
                let isCardio = exercise.movementPattern == "cardio"
                set(\.ownerID, nil)
                set(\.name, exercise.name)
                set(\.movementPattern, exercise.movementPattern)
                // Lifts get broad shoulders/chest tags refined into taxonomy
                // sub-muscles from the name; already-granular tags pass through.
                let refined = MuscleRefinement.refine(
                    name: exercise.name,
                    primaryMuscles: exercise.primaryMuscles,
                    secondaryMuscles: exercise.secondaryMuscles)
                set(\.primaryMuscles, isCardio ? normalizedCardioMuscles(exercise.primaryMuscles) : refined.primary)
                set(\.secondaryMuscles, isCardio
                    ? exercise.secondaryMuscles.filter { $0 != "cardiorespiratory" && $0 != "cardiovascular" }
                    : refined.secondary)
                set(\.equipment, exercise.equipment)
                set(\.isUnilateral, exercise.isUnilateral)
                set(\.isCardio, isCardio)
                if model.defaultWeightMode != (isCardio ? WeightMode.bodyweight : .external) {
                    model.defaultWeightMode = isCardio ? .bodyweight : .external
                    modelChanged = true
                }
            }
            if modelChanged {
                model.updatedAt = Date()
            }
        }

        for alias in snapshot.aliases {
            try Task.checkCancellation()
            let existing = existingAliases[alias.id]
            let model = existing ?? ExerciseAliasModel(id: alias.id, exerciseID: alias.exerciseID, alias: alias.alias)
            if existing == nil {
                context.insert(model)
            }
            // Same diff discipline — alias rows are tiny but sync too.
            if model.exerciseID != alias.exerciseID { model.exerciseID = alias.exerciseID }
            if model.ownerID != alias.ownerID { model.ownerID = alias.ownerID }
            if model.alias != alias.alias { model.alias = alias.alias }
        }
    }

    private nonisolated static func normalizedCardioMuscles(_ muscles: [String]) -> [String] {
        let normalized = muscles.map { $0 == "cardiorespiratory" ? "cardiovascular" : $0 }
        return ["cardiovascular"] + normalized.filter { $0 != "cardiovascular" }
    }
}
