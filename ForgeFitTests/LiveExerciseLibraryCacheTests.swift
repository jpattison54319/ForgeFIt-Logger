import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct LiveExerciseLibraryCacheTests {
    @Test func refreshRetainsNewlyCreatedExerciseMissingFromCallerSnapshot() throws {
        let existing = ExerciseLibraryModel(name: "Bench Press")
        let created = ExerciseLibraryModel(name: "Cable Y Raise")
        let cached = [existing.id: existing, created.id: created]

        let refreshed = LiveExerciseLibraryCache.refreshedLookup(
            library: [existing],
            retaining: cached
        )

        #expect(refreshed[created.id]?.name == "Cable Y Raise")
        let snapshot = LiveExerciseLibraryCache.librarySnapshot(
            library: [existing],
            lookup: refreshed
        )
        #expect(snapshot.map(\.id) == [existing.id, created.id])
    }

    @Test func refreshedCallerEntryWinsWithoutDuplicatingTheExercise() throws {
        let id = UUID()
        let cached = ExerciseLibraryModel(id: id, name: "Old Name")
        let refreshedModel = ExerciseLibraryModel(id: id, name: "Updated Name")

        let lookup = LiveExerciseLibraryCache.refreshedLookup(
            library: [refreshedModel],
            retaining: [id: cached]
        )
        let snapshot = LiveExerciseLibraryCache.librarySnapshot(
            library: [refreshedModel],
            lookup: lookup
        )

        #expect(lookup[id]?.name == "Updated Name")
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.name == "Updated Name")
    }
}
