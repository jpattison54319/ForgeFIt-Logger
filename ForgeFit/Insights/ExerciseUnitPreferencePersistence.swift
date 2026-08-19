import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Persists the per-exercise unit without saving unrelated pending work held
/// by another keep-resident tab's environment context.
@MainActor
enum ExerciseUnitPreferencePersistence {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    enum PersistenceError: LocalizedError {
        case unavailable

        var errorDescription: String? { "That exercise is no longer available." }
    }

    static func set(
        _ unit: WeightUnit?,
        for exercise: ExerciseLibraryModel,
        in sourceContext: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        let exerciseID = exercise.id
        let transaction = ModelContext(sourceContext.container)
        transaction.autosaveEnabled = false
        guard let persistedExercise = try transaction.fetch(
            FetchDescriptor<ExerciseLibraryModel>(
                predicate: #Predicate { $0.id == exerciseID }
            )
        ).first,
        persistedExercise.deletedAt == nil else {
            throw PersistenceError.unavailable
        }
        persistedExercise.preferredWeightUnit = unit
        persistedExercise.updatedAt = now
        try save(transaction)
        _ = try sourceContext.fetch(
            FetchDescriptor<ExerciseLibraryModel>(
                predicate: #Predicate { $0.id == exerciseID }
            )
        ).first
    }
}
