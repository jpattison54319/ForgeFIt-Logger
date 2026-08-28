import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

struct WorkoutIntentCatalogRevisionTests {
    @Test("An older catalog row mutation invalidates the publisher revision")
    func olderRowMutationInvalidatesRevision() {
        let olderID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let newestID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let olderDate = Date(timeIntervalSinceReferenceDate: 10)
        let newestDate = Date(timeIntervalSinceReferenceDate: 20)
        var entries = [
            entry(id: olderID, name: "Older", updatedAt: olderDate),
            entry(id: newestID, name: "Newest", updatedAt: newestDate),
        ]
        let before = WorkoutIntentCatalogRevision.fingerprint(entries)

        entries[0] = entry(id: olderID, name: "Renamed Older", updatedAt: olderDate)

        #expect(WorkoutIntentCatalogRevision.fingerprint(entries) != before)
    }

    @Test("Soft-deleting a non-newest row invalidates the publisher revision")
    func olderRowDeletionInvalidatesRevision() {
        let olderID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let newestID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let olderDate = Date(timeIntervalSinceReferenceDate: 10)
        let newestDate = Date(timeIntervalSinceReferenceDate: 20)
        var entries = [
            entry(id: olderID, name: "Older", updatedAt: olderDate),
            entry(id: newestID, name: "Newest", updatedAt: newestDate),
        ]
        let before = WorkoutIntentCatalogRevision.fingerprint(entries)

        entries[0] = entry(
            id: olderID,
            name: "Older",
            updatedAt: olderDate,
            deletedAt: Date(timeIntervalSinceReferenceDate: 15)
        )

        #expect(WorkoutIntentCatalogRevision.fingerprint(entries) != before)
    }

    @Test("Fingerprint is stable when fetch order changes")
    func fingerprintDoesNotDependOnFetchOrder() {
        let first = entry(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "First",
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let second = entry(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            name: "Second",
            updatedAt: Date(timeIntervalSinceReferenceDate: 20)
        )

        #expect(WorkoutIntentCatalogRevision.fingerprint([first, second])
            == WorkoutIntentCatalogRevision.fingerprint([second, first]))
    }

    @Test("Only intent-catalog saves wake the detached publisher")
    func saveInvalidationScopeExcludesWorkoutLogging() {
        #expect(WorkoutIntentCatalogInvalidationPolicy.isCatalogEntity(named: "RoutineModel"))
        #expect(WorkoutIntentCatalogInvalidationPolicy.isCatalogEntity(named: "RoutineExerciseModel"))
        #expect(WorkoutIntentCatalogInvalidationPolicy.isCatalogEntity(named: "RoutineSetModel"))
        #expect(WorkoutIntentCatalogInvalidationPolicy.isCatalogEntity(named: "RoutineBlockModel"))
        #expect(WorkoutIntentCatalogInvalidationPolicy.isCatalogEntity(named: "ExerciseLibraryModel"))
        #expect(WorkoutIntentCatalogInvalidationPolicy.isCatalogEntity(named: "YogaFlowModel"))
        #expect(WorkoutIntentCatalogInvalidationPolicy.isCatalogEntity(named: "IntervalPresetModel"))
        #expect(!WorkoutIntentCatalogInvalidationPolicy.isCatalogEntity(named: "WorkoutModel"))
        #expect(!WorkoutIntentCatalogInvalidationPolicy.isCatalogEntity(named: "SetModel"))
    }

    @Test("Saved-preset availability reuses one catalog ID set")
    func savedPresetAvailabilityUsesProvidedCatalogSet() {
        let availableID = UUID()
        let missingID = UUID()
        let available = ConditioningSection(
            name: "Available",
            format: .amrap,
            movements: [.init(exerciseID: availableID, targetValue: 10)]
        )
        let missing = ConditioningSection(
            name: "Missing",
            format: .amrap,
            movements: [.init(exerciseID: missingID, targetValue: 10)]
        )

        #expect(WorkoutIntentAvailability.savedPreset(
            available,
            availableExerciseIDs: [availableID]
        ))
        #expect(!WorkoutIntentAvailability.savedPreset(
            missing,
            availableExerciseIDs: [availableID]
        ))
    }

    @MainActor
    @Test("Catalog worker reads durable state from a fresh context")
    func workerDoesNotPublishUnsavedCallerDrafts() async throws {
        let (container, context) = try TestStore.make()
        let exercise = ExerciseLibraryModel(name: "Worker Exercise")
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Persisted Routine",
            exercises: [RoutineExerciseModel(
                userID: ForgeFitDemo.userID,
                exerciseID: exercise.id
            )]
        )
        context.insert(exercise)
        context.insert(routine)
        try context.save()
        let routineID = routine.id
        routine.name = "Unsaved Draft"

        let first = try await WorkoutIntentCatalogWorker.load(in: container)
        let firstRoutine = try #require(first.routines.first { $0.id == routineID })
        #expect(firstRoutine.name == "Persisted Routine")
        #expect(firstRoutine.isAvailableForWorkoutStart)
        #expect(context.hasChanges)

        routine.name = "Saved Rename"
        routine.updatedAt = .now
        try context.save()
        let second = try await WorkoutIntentCatalogWorker.load(in: container)
        #expect(second.routines.first { $0.id == routineID }?.name == "Saved Rename")
        #expect(second.revision != first.revision)
    }

    private func entry(
        id: UUID,
        name: String,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) -> WorkoutIntentCatalogRevisionEntry {
        WorkoutIntentCatalogRevisionEntry(
            kind: .routine,
            id: id,
            name: name,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
            archivedAt: nil,
            detail: ""
        )
    }
}
