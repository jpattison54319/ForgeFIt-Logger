import ForgeCore
@testable import ForgeData
import Foundation
import SwiftData
import Testing

/// The saved-insight row stores the SHAPE of a comparison, never data. These
/// tests pin the CloudKit-safe defaults and the recipe payload round-trip —
/// including the privacy property that serialized recipes contain no
/// observation or Health values by construction.
@MainActor
struct SavedInsightModelTests {

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }

    @Test func bareRowCarriesCloudKitSafeDefaults() throws {
        let (container, context) = try makeContext()
        let row = SavedInsightModel(userID: UUID())
        context.insert(row)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<SavedInsightModel>()).first)
        #expect(fetched.name == "")
        #expect(fetched.recipeJSON == nil)
        #expect(fetched.position == 0)
        #expect(fetched.deletedAt == nil)
        _ = container
    }

    @Test func recipePayloadRoundTripsThroughTheRow() throws {
        let (container, context) = try makeContext()
        let recipe = InsightRecipe(
            shape: .relationship,
            primaryMetricID: "strength.sessionVolume",
            comparisonMetricIDs: ["health.sleepDuration"],
            lag: InsightLag(unit: .days, count: 1)
        )
        let row = SavedInsightModel(userID: UUID(), name: "Sleep vs volume", recipeJSON: recipe.encodedJSON())
        context.insert(row)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<SavedInsightModel>()).first)
        let decoded = try #require(InsightRecipe.decode(from: fetched.recipeJSON))
        #expect(decoded == recipe)
        _ = container
    }

    /// The serialized payload is pure configuration: metric identifiers and
    /// enum shape — no numeric observations, timestamps of health events, or
    /// value arrays exist anywhere in the contract to leak.
    @Test func serializedRecipeContainsOnlyConfiguration() throws {
        let recipe = InsightRecipe(
            shape: .relationship,
            primaryMetricID: "strength.sessionVolume",
            comparisonMetricIDs: ["health.hrv"],
            lag: InsightLag(unit: .days, count: 1)
        )
        let json = try #require(recipe.encodedJSON())
        #expect(!json.contains("value"))
        #expect(!json.contains("observation"))
        #expect(json.contains("health.hrv"), "Metric IDS are the payload — values never are.")
    }

    @Test func corruptPayloadDecodesToNilNotACrash() {
        #expect(InsightRecipe.decode(from: "not json at all") == nil)
        #expect(InsightRecipe.decode(from: nil) == nil)
        #expect(InsightRecipe.decode(from: #"{"schemaVersion": 999}"#) == nil)
    }
}
