import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct IntervalPresetTests {
    @Test func presetRoundTripsPlanThroughStore() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }

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
        let (container, context) = try TestStore.make()
        defer { _ = container }

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
        let (container, context) = try TestStore.make()
        defer { _ = container }

        context.insert(IntervalPresetModel(userID: ForgeFitDemo.userID, name: "Wipe me", planJSON: "{}"))
        try context.save()

        try AccountResetService.deleteAllLocalModels(in: context)

        #expect(try context.fetch(FetchDescriptor<IntervalPresetModel>()).isEmpty)
    }
}
