import ForgeData
import Foundation
import SwiftData

/// A stable isolated create/edit attempt for a custom exercise. Form-specific
/// projection stays with the UI, while this type owns the durable boundary and
/// makes failure behavior directly testable.
@MainActor
final class ExercisePersistenceAttempt {
    enum PersistenceError: LocalizedError {
        case sourceExerciseUnavailable
        case committedExerciseUnavailable

        var errorDescription: String? {
            switch self {
            case .sourceExerciseUnavailable:
                "The exercise is no longer available."
            case .committedExerciseUnavailable:
                "The exercise was saved, but ForgeFit couldn't reopen it. Try again."
            }
        }
    }

    typealias SaveOperation = @MainActor (ModelContext) throws -> Void
    typealias Mutation = @MainActor (ExerciseLibraryModel, ModelContext) throws -> Void

    let id: UUID
    private let persistenceContext: ModelContext
    private var exercise: ExerciseLibraryModel?

    init(
        id: UUID = UUID(),
        creatingName name: String,
        in sourceContext: ModelContext
    ) {
        self.id = id
        persistenceContext = ModelContext(sourceContext.container)
        persistenceContext.autosaveEnabled = false
        let pendingExercise = ExerciseLibraryModel(
            id: id,
            ownerID: ForgeFitDemo.userID,
            name: name
        )
        persistenceContext.insert(pendingExercise)
        exercise = pendingExercise
    }

    init(editing source: ExerciseLibraryModel, in sourceContext: ModelContext) {
        id = source.id
        persistenceContext = ModelContext(sourceContext.container)
        persistenceContext.autosaveEnabled = false
    }

    @discardableResult
    func commit(
        into sourceContext: ModelContext,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        mutate: @escaping Mutation,
        onCommit: @escaping @MainActor (ExerciseLibraryModel) -> Void
    ) -> Bool {
        let exerciseID = id
        var committedExercise: ExerciseLibraryModel?
        return (saveCenter ?? .shared).perform({ [self] in
            if exercise == nil {
                exercise = try persistenceContext.fetch(
                    FetchDescriptor<ExerciseLibraryModel>(
                        predicate: #Predicate { $0.id == exerciseID }
                    )
                ).first
            }
            guard let exercise else {
                throw PersistenceError.sourceExerciseUnavailable
            }
            try mutate(exercise, persistenceContext)
            try save(persistenceContext)
            committedExercise = try sourceContext.fetch(
                FetchDescriptor<ExerciseLibraryModel>(
                    predicate: #Predicate { $0.id == exerciseID }
                )
            ).first
            guard committedExercise != nil else {
                throw PersistenceError.committedExerciseUnavailable
            }
        }, onSuccess: {
            if let committedExercise { onCommit(committedExercise) }
        })
    }
}
