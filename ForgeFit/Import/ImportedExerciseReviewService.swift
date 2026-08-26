import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Atomic persistence boundary for individual and bulk import-review actions.
/// Discard is deliberately a library soft-delete: imported workout references
/// keep resolving for history, while pickers and the active library hide it.
@MainActor
enum ImportedExerciseReviewService {
    enum Action: Equatable {
        case approve
        case discard
    }

    enum ReviewError: LocalizedError {
        case missingExercise
        case noLongerPending(String)

        var errorDescription: String? {
            switch self {
            case .missingExercise:
                "One of these imported exercises is no longer available."
            case .noLongerPending(let name):
                "\(name) was already reviewed on another screen or device."
            }
        }
    }

    static func apply(
        _ action: Action,
        to exerciseIDs: [UUID],
        in container: ModelContainer,
        save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let ids = Array(Set(exerciseIDs))
        guard !ids.isEmpty else { return }

        let transaction = ModelContext(container)
        transaction.autosaveEnabled = false
        let exercises = try transaction.fetch(FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { ids.contains($0.id) }
        ))
        guard exercises.count == ids.count else {
            transaction.rollback()
            throw ReviewError.missingExercise
        }

        let now = Date.now
        for exercise in exercises {
            let isPending = exercise.needsReview
                || (exercise.importBatchID != nil && exercise.userModified == false)
            guard exercise.ownerID != nil, exercise.deletedAt == nil, isPending else {
                transaction.rollback()
                throw ReviewError.noLongerPending(exercise.name)
            }

            exercise.needsReview = false
            exercise.userModified = true
            exercise.classificationSource = .manual
            exercise.classificationConfidence = 1
            exercise.updatedAt = now
            if action == .discard {
                exercise.deletedAt = now
            }
        }

        do {
            try save(transaction)
        } catch {
            transaction.rollback()
            throw error
        }
    }
}
