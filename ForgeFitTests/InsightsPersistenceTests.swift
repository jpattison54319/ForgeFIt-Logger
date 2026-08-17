import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct InsightsPersistenceTests {
    private struct InjectedFailure: Error {}

    @Test
    func savedInsightFailureAndRetryDoNotCommitAnotherTabsPendingEdit() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Committed")
        context.insert(routine)
        try context.save()
        routine.name = "Pending elsewhere"
        let insightID = UUID()

        #expect(throws: InjectedFailure.self) {
            try SavedInsightPersistence.create(
                id: insightID,
                userID: ForgeFitDemo.userID,
                name: "Volume trend",
                recipeJSON: #"{"version":1}"#,
                position: 0,
                in: context,
                save: { _ in throw InjectedFailure() }
            )
        }
        var verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<SavedInsightModel>()).isEmpty)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Committed")

        let saved = try SavedInsightPersistence.create(
            id: insightID,
            userID: ForgeFitDemo.userID,
            name: "Volume trend",
            recipeJSON: #"{"version":1}"#,
            position: 0,
            in: context
        )
        #expect(saved.id == insightID)
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<SavedInsightModel>()).count == 1)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Committed")

        try context.save()
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Pending elsewhere")
    }

    @Test
    func savedInsightUpdateReorderAndDeleteRefreshCachedRowsWithoutCrossCommit() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let first = SavedInsightModel(
            userID: ForgeFitDemo.userID,
            name: "First",
            recipeJSON: "first",
            position: 0
        )
        let second = SavedInsightModel(
            userID: ForgeFitDemo.userID,
            name: "Second",
            recipeJSON: "second",
            position: 1
        )
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Committed")
        context.insert(first)
        context.insert(second)
        context.insert(routine)
        try context.save()
        routine.name = "Pending elsewhere"

        _ = try SavedInsightPersistence.update(
            id: first.id,
            name: "Updated",
            recipeJSON: "updated",
            in: context
        )
        #expect(first.name == "Updated")
        #expect(first.recipeJSON == "updated")

        try SavedInsightPersistence.reorder(ids: [second.id, first.id], in: context)
        #expect(first.position == 1)
        #expect(second.position == 0)

        try SavedInsightPersistence.delete(id: second.id, in: context)
        #expect(second.deletedAt != nil)
        #expect(context.hasChanges)

        var verification = ModelContext(container)
        let rows = try verification.fetch(FetchDescriptor<SavedInsightModel>())
        #expect(rows.first(where: { $0.id == first.id })?.name == "Updated")
        #expect(rows.first(where: { $0.id == first.id })?.position == 1)
        #expect(rows.first(where: { $0.id == second.id })?.position == 0)
        #expect(rows.first(where: { $0.id == second.id })?.deletedAt != nil)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Committed")

        try context.save()
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Pending elsewhere")
    }

    @Test
    func exerciseUnitFailureAndRetryAreExactAndDoNotCrossCommit() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let exercise = ExerciseLibraryModel(name: "Bench Press")
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Committed")
        context.insert(exercise)
        context.insert(routine)
        try context.save()
        routine.name = "Pending elsewhere"

        #expect(throws: InjectedFailure.self) {
            try ExerciseUnitPreferencePersistence.set(
                .kg,
                for: exercise,
                in: context,
                save: { _ in throw InjectedFailure() }
            )
        }
        var verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<ExerciseLibraryModel>()).first?.preferredWeightUnitRaw == nil)

        try ExerciseUnitPreferencePersistence.set(.kg, for: exercise, in: context)
        #expect(exercise.preferredWeightUnit == .kg)
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<ExerciseLibraryModel>()).first?.preferredWeightUnitRaw == WeightUnit.kg.rawValue)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Committed")

        try context.save()
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Pending elsewhere")
    }
}
