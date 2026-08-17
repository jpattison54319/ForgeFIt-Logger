import ForgeData
import Foundation
import SwiftData

/// Stable-ID transactions for mutations launched from the read-only workout
/// detail surface. They never save or roll back the keep-resident UI context.
@MainActor
enum WorkoutDetailPersistence {
    private enum PersistenceError: LocalizedError {
        case missingWorkout
        case missingSession

        var errorDescription: String? {
            switch self {
            case .missingWorkout: "That workout could not be found."
            case .missingSession: "That cardio session could not be found."
            }
        }
    }

    static func softDeleteWorkout(
        container: ModelContainer,
        workoutID: UUID,
        deletedAt: Date,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let transaction = ModelContext(container)
        transaction.autosaveEnabled = false
        do {
            guard let workout = try transaction.fetch(FetchDescriptor<WorkoutModel>(
                predicate: #Predicate { $0.id == workoutID }
            )).first else {
                throw PersistenceError.missingWorkout
            }
            workout.updatedAt = deletedAt
            workout.deletedAt = deletedAt
            try save(transaction)
        } catch {
            transaction.rollback()
            throw error
        }
    }

    static func deleteSplits(
        container: ModelContainer,
        sessionID: UUID,
        splitIDs: [UUID],
        updatedAt: Date,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let transaction = ModelContext(container)
        transaction.autosaveEnabled = false
        do {
            guard let session = try transaction.fetch(FetchDescriptor<CardioSessionModel>(
                predicate: #Predicate { $0.id == sessionID }
            )).first else {
                throw PersistenceError.missingSession
            }
            let ids = splitIDs
            let splits = try transaction.fetch(FetchDescriptor<CardioSplitModel>(
                predicate: #Predicate { ids.contains($0.id) }
            ))
            let foundIDs = Set(splits.map(\.id))
            session.splits.removeAll { foundIDs.contains($0.id) }
            for split in splits {
                transaction.delete(split)
            }
            session.updatedAt = updatedAt
            try save(transaction)
        } catch {
            transaction.rollback()
            throw error
        }
    }

    /// Health refresh is background-derived rather than a user edit, so it
    /// reports a message instead of owning the global Retry action.
    static func reconcileHeartRate(
        container: ModelContainer,
        workoutID: UUID,
        samples: [(date: Date, bpm: Int)],
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> String? {
        let transaction = ModelContext(container)
        transaction.autosaveEnabled = false
        do {
            guard let workout = try transaction.fetch(FetchDescriptor<WorkoutModel>(
                predicate: #Predicate { $0.id == workoutID }
            )).first else {
                throw PersistenceError.missingWorkout
            }
            guard WorkoutHeartRateResolution.reconcile(workout: workout, samples: samples) else {
                return nil
            }
            try save(transaction)
            return nil
        } catch {
            transaction.rollback()
            return error.localizedDescription
        }
    }
}
