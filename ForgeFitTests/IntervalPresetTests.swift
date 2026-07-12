import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct IntervalPresetTests {
    /// Returns the CONTAINER (not just a context): a ModelContext holds its
    /// container weakly, so keeping only `container.mainContext` alive lets the
    /// container deallocate and the first fetch crashes inside SwiftData.
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @Test func presetRoundTripsPlanThroughStore() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let plan = IntervalPlan.build(
            warmupSeconds: 300, repeats: 6, workSeconds: 60, recoverSeconds: 90,
            cooldownSeconds: 300, workZone: 4, recoverZone: 2)
        let json = try #require(plan.encodedJSON())
        context.insert(IntervalPresetModel(userID: ForgeFitDemo.userID, name: "My VO2", planJSON: json))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<IntervalPresetModel>())
        #expect(fetched.count == 1)
        let stored = try #require(fetched.first)
        #expect(stored.name == "My VO2")
        // The decoded plan matches the one that was saved, step-for-step.
        #expect(IntervalPlan.decode(from: stored.planJSON) == plan)
    }

    @Test func softDeleteHidesPresetFromActiveQuery() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let keep = IntervalPresetModel(userID: ForgeFitDemo.userID, name: "Keep", planJSON: "{}")
        let drop = IntervalPresetModel(userID: ForgeFitDemo.userID, name: "Drop", planJSON: "{}")
        context.insert(keep)
        context.insert(drop)
        try context.save()

        drop.deletedAt = Date()
        try context.save()

        let active = try context.fetch(
            FetchDescriptor<IntervalPresetModel>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(active.count == 1)
        #expect(active.first?.name == "Keep")
        // Soft delete, not hard: the row still exists in the store.
        #expect(try context.fetch(FetchDescriptor<IntervalPresetModel>()).count == 2)
    }

    @Test func deleteAllLocalModelsRemovesPresets() throws {
        let container = try makeContainer()
        let context = container.mainContext

        context.insert(IntervalPresetModel(userID: ForgeFitDemo.userID, name: "Wipe me", planJSON: "{}"))
        try context.save()

        try AccountResetService.deleteAllLocalModels(in: context)

        #expect(try context.fetch(FetchDescriptor<IntervalPresetModel>()).isEmpty)
    }
}
