import Foundation
import ForgeCore
import SwiftData

@MainActor
public enum ExerciseSeedRepository {

    public static func seedGlobalLibrary(
        _ snapshot: ExerciseLibrarySnapshot = GlobalExerciseLibrary.snapshot,
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

        if context.hasChanges {
            try context.save()
        }
    }

    private static func normalizedCardioMuscles(_ muscles: [String]) -> [String] {
        let normalized = muscles.map { $0 == "cardiorespiratory" ? "cardiovascular" : $0 }
        return ["cardiovascular"] + normalized.filter { $0 != "cardiovascular" }
    }
}
