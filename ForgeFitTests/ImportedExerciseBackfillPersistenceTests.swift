import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct ImportedExerciseBackfillPersistenceTests {
    private enum InjectedFailure: Error { case save }

    @Test func failedSaveDoesNotStampCompletionAndLaterRunRetriesInIsolation() async throws {
        let (container, context) = try TestStore.make()
        let suite = "ImportedExerciseBackfillPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LiveWorkoutPerformanceGate.shared.setLiveWorkoutActive(false)

        let exercise = ExerciseLibraryModel(
            ownerID: ForgeFitDemo.userID,
            name: "Barbell Bench Press",
            importedRawName: "Barbell Bench Press"
        )
        context.insert(exercise)
        try context.save()
        let exerciseID = exercise.id
        let pendingRoutine = RoutineModel(userID: ForgeFitDemo.userID, name: "Pending")
        context.insert(pendingRoutine)

        await ImportedExerciseBackfill.runIfNeeded(
            in: context,
            defaults: defaults,
            save: { _ in throw InjectedFailure.save }
        )

        #expect(!defaults.bool(forKey: ImportedExerciseBackfill.didRunKey))
        #expect(context.hasChanges)
        var verification = ModelContext(container)
        var persisted = try #require(try verification.fetch(FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { $0.id == exerciseID }
        )).first)
        #expect(persisted.primaryMuscles.isEmpty)

        await ImportedExerciseBackfill.runIfNeeded(in: context, defaults: defaults)

        #expect(defaults.bool(forKey: ImportedExerciseBackfill.didRunKey))
        #expect(context.hasChanges)
        verification = ModelContext(container)
        persisted = try #require(try verification.fetch(FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { $0.id == exerciseID }
        )).first)
        #expect(!persisted.primaryMuscles.isEmpty)

        try context.save()
        let finalContext = ModelContext(container)
        #expect(try finalContext.fetch(FetchDescriptor<RoutineModel>()).contains {
            $0.name == "Pending"
        })
    }
}
