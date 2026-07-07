import ForgeCore
@testable import ForgeData
import SwiftData
import XCTest

@MainActor
final class ExerciseLibraryDeduplicatorTests: XCTestCase {

    /// Builds an in-memory container and returns it alongside its context. The
    /// container MUST be retained by the caller for the lifetime of the test —
    /// `mainContext` holds it weakly, so a discarded container tears the store
    /// out from under the context mid-test.
    private func makeContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: offset)
    }

    func testCollapsesDuplicateExercisesKeepingUserModifiedCopy() throws {
        let (container, context) = try makeContainer()
        let id = UUID()

        let pristine = ExerciseLibraryModel(id: id, name: "Bench Press")
        pristine.userModified = false
        pristine.updatedAt = date(2000)
        let edited = ExerciseLibraryModel(id: id, name: "My Bench Press")
        edited.userModified = true
        edited.updatedAt = date(1000) // older, but user-modified must win
        context.insert(pristine)
        context.insert(edited)
        try context.save()

        let summary = try ExerciseLibraryDeduplicator.removeDuplicates(in: context)

        XCTAssertEqual(summary.duplicateExercisesDeleted, 1)
        let survivors = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        XCTAssertEqual(survivors.count, 1)
        XCTAssertEqual(survivors.first?.name, "My Bench Press")
        XCTAssertEqual(survivors.first?.userModified, true)
        _ = container
    }

    func testWithoutUserEditsKeepsMostRecentlyUpdated() throws {
        let (container, context) = try makeContainer()
        let id = UUID()

        let older = ExerciseLibraryModel(id: id, name: "Squat")
        older.updatedAt = date(1000)
        let newer = ExerciseLibraryModel(id: id, name: "Squat (newer)")
        newer.updatedAt = date(5000)
        let oldest = ExerciseLibraryModel(id: id, name: "Squat (oldest)")
        oldest.updatedAt = date(500)
        [older, newer, oldest].forEach(context.insert)
        try context.save()

        let summary = try ExerciseLibraryDeduplicator.removeDuplicates(in: context)

        XCTAssertEqual(summary.duplicateExercisesDeleted, 2)
        let survivors = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        XCTAssertEqual(survivors.map(\.name), ["Squat (newer)"])
        _ = container
    }

    func testDeduplicatesAliasesByID() throws {
        let (container, context) = try makeContainer()
        let aliasID = UUID()
        let exerciseID = UUID()

        let a = ExerciseAliasModel(id: aliasID, exerciseID: exerciseID, alias: "RDL")
        a.createdAt = date(1000)
        let b = ExerciseAliasModel(id: aliasID, exerciseID: exerciseID, alias: "RDL")
        b.createdAt = date(2000)
        context.insert(a)
        context.insert(b)
        try context.save()

        let summary = try ExerciseLibraryDeduplicator.removeDuplicates(in: context)

        XCTAssertEqual(summary.duplicateAliasesDeleted, 1)
        let survivors = try context.fetch(FetchDescriptor<ExerciseAliasModel>())
        XCTAssertEqual(survivors.count, 1)
        _ = container
    }

    func testIsIdempotent() throws {
        let (container, context) = try makeContainer()
        let id = UUID()
        context.insert(ExerciseLibraryModel(id: id, name: "Deadlift"))
        context.insert(ExerciseLibraryModel(id: id, name: "Deadlift"))
        try context.save()

        let first = try ExerciseLibraryDeduplicator.removeDuplicates(in: context)
        XCTAssertEqual(first.duplicateExercisesDeleted, 1)

        let second = try ExerciseLibraryDeduplicator.removeDuplicates(in: context)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExerciseLibraryModel>()).count, 1)
        _ = container
    }

    func testLeavesDistinctRowsUntouched() throws {
        let (container, context) = try makeContainer()
        context.insert(ExerciseLibraryModel(id: UUID(), name: "Row"))
        context.insert(ExerciseLibraryModel(id: UUID(), name: "Curl"))
        context.insert(ExerciseAliasModel(id: UUID(), exerciseID: UUID(), alias: "x"))
        try context.save()

        let summary = try ExerciseLibraryDeduplicator.removeDuplicates(in: context)

        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExerciseLibraryModel>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExerciseAliasModel>()).count, 1)
        _ = container
    }
}
