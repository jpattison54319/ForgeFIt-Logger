import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
@Suite(.serialized)
struct ImportedExerciseBackfillPersistenceTests {
    private enum InjectedFailure: Error { case save }

    @Test func cooperativeBackfillCommitsInAFreshContextAndStampsOnlyAfterSuccess() async throws {
        let (container, context) = try TestStore.make()
        let suite = "ImportedExerciseBackfillPersistenceTests.cooperative.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LiveWorkoutPerformanceGate.shared.setLiveWorkoutActive(false)

        let exercise = ExerciseLibraryModel(
            ownerID: ForgeFitDemo.userID,
            name: "Lat Prayer",
            userModified: false,
            needsReview: true,
            importBatchID: UUID(),
            importedRawName: "Lat Prayer"
        )
        context.insert(exercise)
        try context.save()
        let exerciseID = exercise.id
        let pendingRoutine = RoutineModel(userID: ForgeFitDemo.userID, name: "Unsaved caller edit")
        context.insert(pendingRoutine)

        await ImportedExerciseBackfill.runCooperativelyIfNeeded(
            in: context,
            defaults: defaults
        )

        #expect(defaults.bool(forKey: ImportedExerciseBackfill.didRunKey))
        #expect(context.hasChanges)
        var verification = ModelContext(container)
        var persisted = try #require(try verification.fetch(FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { $0.id == exerciseID }
        )).first)
        #expect(persisted.primaryMuscles == ["lats"])
        #expect(persisted.classificationSource == .keyword)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).isEmpty)

        let firstUpdatedAt = persisted.updatedAt
        await ImportedExerciseBackfill.runCooperativelyIfNeeded(
            in: context,
            defaults: defaults
        )
        verification = ModelContext(container)
        persisted = try #require(try verification.fetch(FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { $0.id == exerciseID }
        )).first)
        #expect(persisted.updatedAt == firstUpdatedAt)
    }

    @Test func failedSaveDoesNotStampCompletionAndLaterRunRetriesInIsolation() async throws {
        let (container, context) = try TestStore.make()
        let suite = "ImportedExerciseBackfillPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LiveWorkoutPerformanceGate.shared.setLiveWorkoutActive(false)

        let exercise = ExerciseLibraryModel(
            ownerID: ForgeFitDemo.userID,
            name: "Barbell Bench Press",
            importBatchID: UUID(),
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

    @Test func currentPendingImportsAreReclassifiedButManualEditsArePreserved() async throws {
        let (container, context) = try TestStore.make()
        let suite = "ImportedExerciseBackfillPersistenceTests.quality.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LiveWorkoutPerformanceGate.shared.setLiveWorkoutActive(false)

        let batchID = UUID()
        let pending = ExerciseLibraryModel(
            ownerID: ForgeFitDemo.userID,
            name: "Lat Prayer",
            primaryMuscles: ["lats", "back", "traps"],
            secondaryMuscles: ["shoulders", "biceps", "chest", "forearms"],
            userModified: false,
            needsReview: true,
            classificationConfidence: 0.8,
            classificationSourceRaw: ClassificationSource.ai.rawValue,
            importBatchID: batchID,
            importedRawName: "Lat Prayer"
        )
        let manual = ExerciseLibraryModel(
            ownerID: ForgeFitDemo.userID,
            name: "Lean Back Abduction Machine",
            primaryMuscles: ["abductors"],
            secondaryMuscles: ["obliques"],
            userModified: true,
            needsReview: false,
            classificationConfidence: 1,
            classificationSourceRaw: ClassificationSource.manual.rawValue,
            importBatchID: batchID,
            importedRawName: "Lean Back Abduction Machine"
        )
        context.insert(pending)
        context.insert(manual)
        try context.save()
        let pendingID = pending.id
        let manualID = manual.id

        await ImportedExerciseBackfill.runIfNeeded(in: context, defaults: defaults)

        let verification = ModelContext(container)
        let persistedPending = try #require(try verification.fetch(FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { $0.id == pendingID }
        )).first)
        let persistedManual = try #require(try verification.fetch(FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { $0.id == manualID }
        )).first)
        #expect(persistedPending.primaryMuscles == ["lats"])
        #expect(persistedPending.secondaryMuscles.isEmpty)
        #expect(persistedPending.classificationSource == .keyword)
        #expect(persistedManual.secondaryMuscles == ["obliques"])
        #expect(persistedManual.classificationSource == .manual)
    }
}
