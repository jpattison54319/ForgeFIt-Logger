import ForgeData
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
@Suite("Cooperative launch catalog seed")
struct ExerciseCatalogCooperativeSeedTests {
    @Test("Chunked first-install seeding is durable and idempotent")
    func cooperativeSeedIsDurableAndIdempotent() async throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        try await ExerciseCatalog.seedCooperatively(
            into: context,
            batchSize: 12
        )
        let firstCount = try context.fetchCount(FetchDescriptor<ExerciseLibraryModel>())
        #expect(firstCount == ExerciseCatalog.load().count)
        #expect(!context.hasChanges)

        try await ExerciseCatalog.seedCooperatively(
            into: context,
            batchSize: 12
        )
        #expect(try context.fetchCount(FetchDescriptor<ExerciseLibraryModel>()) == firstCount)
        #expect(!context.hasChanges)

        let freshContext = ModelContext(container)
        #expect(try freshContext.fetchCount(FetchDescriptor<ExerciseLibraryModel>()) == firstCount)
    }
}
