import Foundation
import ForgeCore
import ForgeData
import SwiftData

/// One-shot migration retiring the rest-pause set type: in practice it was
/// indistinguishable from myo-reps (activation + micro-rested minis), so the
/// picker no longer offers it and existing sets — logged history and routine
/// plans alike — convert to myo-reps. The enum case itself survives so
/// not-yet-migrated CloudKit data from other devices still decodes; this
/// backfill simply runs again for it on the next launch.
@MainActor
enum SetTypeRetirementBackfill {
    nonisolated private static let restPauseRaw = SetType.restPause.rawValue

    private nonisolated struct RefreshReceipt: Sendable {
        let setIDs: [UUID]
        let routineSetIDs: [UUID]
        let workoutIDs: [UUID]
        let routineIDs: [UUID]
    }

    static func runCooperatively(in sourceContext: ModelContext) async {
        let container = sourceContext.container
        let task = Task.detached(priority: .utility) {
            try runPersisted(in: container)
        }
        do {
            let receipt = try await withTaskCancellationHandler(
                operation: { try await task.value },
                onCancel: { task.cancel() }
            )
            guard !Task.isCancelled else { return }
            refresh(receipt, in: sourceContext)
        } catch {
            // There is deliberately no completion stamp: a failed pass remains
            // eligible on the next launch/idle window.
        }
    }

    private nonisolated static func runPersisted(
        in container: ModelContainer
    ) throws -> RefreshReceipt {
        let transaction = ModelContext(container)
        transaction.autosaveEnabled = false
        do {
            try Task.checkCancellation()
            let sets = try transaction.fetch(FetchDescriptor<SetModel>(
                predicate: #Predicate { $0.setTypeRaw == restPauseRaw }
            ))
            let routineSets = try transaction.fetch(FetchDescriptor<RoutineSetModel>(
                predicate: #Predicate { $0.setTypeRaw == restPauseRaw }
            ))
            guard !sets.isEmpty || !routineSets.isEmpty else {
                return RefreshReceipt(setIDs: [], routineSetIDs: [], workoutIDs: [], routineIDs: [])
            }

            let now = Date()
            var workoutIDs = Set<UUID>()
            var routineIDs = Set<UUID>()
            for set in sets {
                try Task.checkCancellation()
                set.setType = .myoRep
                set.updatedAt = now
                set.workoutExercise?.updatedAt = now
                if let workout = set.workoutExercise?.workout {
                    workout.updatedAt = now
                    workoutIDs.insert(workout.id)
                }
            }
            for set in routineSets {
                try Task.checkCancellation()
                set.setType = .myoRep
                set.routineExercise?.updatedAt = now
                if let routine = set.routineExercise?.routine {
                    routine.updatedAt = now
                    routineIDs.insert(routine.id)
                }
            }
            try Task.checkCancellation()
            try transaction.save()
            return RefreshReceipt(
                setIDs: sets.map(\.id),
                routineSetIDs: routineSets.map(\.id),
                workoutIDs: Array(workoutIDs),
                routineIDs: Array(routineIDs)
            )
        } catch {
            transaction.rollback()
            throw error
        }
    }

    private static func refresh(_ receipt: RefreshReceipt, in context: ModelContext) {
        if !receipt.setIDs.isEmpty {
            let ids = receipt.setIDs
            _ = try? context.fetch(FetchDescriptor<SetModel>(
                predicate: #Predicate { ids.contains($0.id) }
            ))
        }
        if !receipt.routineSetIDs.isEmpty {
            let ids = receipt.routineSetIDs
            _ = try? context.fetch(FetchDescriptor<RoutineSetModel>(
                predicate: #Predicate { ids.contains($0.id) }
            ))
        }
        if !receipt.workoutIDs.isEmpty {
            let ids = receipt.workoutIDs
            _ = try? context.fetch(FetchDescriptor<WorkoutModel>(
                predicate: #Predicate { ids.contains($0.id) }
            ))
        }
        if !receipt.routineIDs.isEmpty {
            let ids = receipt.routineIDs
            _ = try? context.fetch(FetchDescriptor<RoutineModel>(
                predicate: #Predicate { ids.contains($0.id) }
            ))
        }
    }

    static func run(in context: ModelContext) {
        let transaction = ModelContext(context.container)
        transaction.autosaveEnabled = false
        let sets = (try? transaction.fetch(FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.setTypeRaw == restPauseRaw }
        ))) ?? []
        let routineSets = (try? transaction.fetch(FetchDescriptor<RoutineSetModel>(
            predicate: #Predicate { $0.setTypeRaw == restPauseRaw }
        ))) ?? []
        guard !sets.isEmpty || !routineSets.isEmpty else { return }

        let now = Date()
        for set in sets {
            set.setType = .myoRep
            set.updatedAt = now
            set.workoutExercise?.updatedAt = now
            set.workoutExercise?.workout?.updatedAt = now
        }
        for set in routineSets {
            set.setType = .myoRep
            set.routineExercise?.updatedAt = now
            set.routineExercise?.routine?.updatedAt = now
        }
        do {
            try transaction.save()
        } catch {
            transaction.rollback()
        }
    }
}
