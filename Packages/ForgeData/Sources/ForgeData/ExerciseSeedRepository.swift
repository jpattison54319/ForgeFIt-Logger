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
            // Always keep the catalog linkage current, but never clobber a
            // built-in the user has edited — their name/muscles/equipment win.
            model.mappedGlobalID = exercise.mappedGlobalID
            guard existing?.userModified != true else { continue }

            model.ownerID = nil
            model.name = exercise.name
            model.movementPattern = exercise.movementPattern
            // Lifts get broad shoulders/chest tags refined into taxonomy
            // sub-muscles from the name; already-granular tags pass through.
            let refined = MuscleRefinement.refine(
                name: exercise.name,
                primaryMuscles: exercise.primaryMuscles,
                secondaryMuscles: exercise.secondaryMuscles)
            model.primaryMuscles = exercise.movementPattern == "cardio"
                ? normalizedCardioMuscles(exercise.primaryMuscles)
                : refined.primary
            model.secondaryMuscles = exercise.movementPattern == "cardio"
                ? exercise.secondaryMuscles.filter { $0 != "cardiorespiratory" && $0 != "cardiovascular" }
                : refined.secondary
            model.equipment = exercise.equipment
            model.isUnilateral = exercise.isUnilateral
            model.isCardio = exercise.movementPattern == "cardio"
            model.defaultWeightMode = model.isCardio ? .bodyweight : .external
            model.updatedAt = Date()

            if existing == nil {
                context.insert(model)
            }
        }

        for alias in snapshot.aliases {
            let existing = existingAliases[alias.id]
            let model = existing ?? ExerciseAliasModel(id: alias.id, exerciseID: alias.exerciseID, alias: alias.alias)
            model.exerciseID = alias.exerciseID
            model.ownerID = alias.ownerID
            model.alias = alias.alias

            if existing == nil {
                context.insert(model)
            }
        }

        try context.save()
    }

    private static func normalizedCardioMuscles(_ muscles: [String]) -> [String] {
        let normalized = muscles.map { $0 == "cardiorespiratory" ? "cardiovascular" : $0 }
        return ["cardiovascular"] + normalized.filter { $0 != "cardiovascular" }
    }
}
