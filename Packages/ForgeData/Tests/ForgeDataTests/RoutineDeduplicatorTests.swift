import ForgeCore
@testable import ForgeData
import SwiftData
import XCTest

@MainActor
final class RoutineDeduplicatorTests: XCTestCase {

    private func makeContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: offset)
    }

    func testCollapsesDuplicateRoutinesKeepingMostRecentlyUpdated() throws {
        let (container, context) = try makeContainer()
        let id = UUID()
        let uid = UUID()

        let older = RoutineModel(id: id, userID: uid, name: "Push Day")
        older.updatedAt = date(1000)
        let newer = RoutineModel(id: id, userID: uid, name: "Push Day (newer)")
        newer.updatedAt = date(5000)
        let oldest = RoutineModel(id: id, userID: uid, name: "Push Day (oldest)")
        oldest.updatedAt = date(500)
        [older, newer, oldest].forEach(context.insert)
        try context.save()

        let summary = try RoutineDeduplicator.removeDuplicates(in: context)

        XCTAssertEqual(summary.duplicateRoutinesDeleted, 2)
        let survivors = try context.fetch(FetchDescriptor<RoutineModel>())
        XCTAssertEqual(survivors.count, 1)
        XCTAssertEqual(survivors.first?.name, "Push Day (newer)")
        _ = container
    }

    func testSoftDeletedWinsOverLive() throws {
        let (container, context) = try makeContainer()
        let id = UUID()
        let uid = UUID()

        let live = RoutineModel(id: id, userID: uid, name: "Leg Day")
        live.updatedAt = date(5000)
        let tombstone = RoutineModel(id: id, userID: uid, name: "Leg Day")
        tombstone.updatedAt = date(1000)
        tombstone.deletedAt = date(2000)
        context.insert(live)
        context.insert(tombstone)
        try context.save()

        let summary = try RoutineDeduplicator.removeDuplicates(in: context)

        XCTAssertEqual(summary.duplicateRoutinesDeleted, 1)
        let survivors = try context.fetch(FetchDescriptor<RoutineModel>())
        XCTAssertEqual(survivors.count, 1)
        XCTAssertNotNil(survivors.first?.deletedAt)
        _ = container
    }

    func testCascadeLeavesOneExerciseAndSetUnderSurvivor() throws {
        let (container, context) = try makeContainer()
        let id = UUID()
        let uid = UUID()

        let set1 = RoutineSetModel(userID: uid, position: 0)
        let ex1 = RoutineExerciseModel(userID: uid, exerciseID: UUID(), sets: [set1])
        let winner = RoutineModel(id: id, userID: uid, name: "Push", exercises: [ex1])
        winner.updatedAt = date(5000)

        let set2 = RoutineSetModel(userID: uid, position: 0)
        let ex2 = RoutineExerciseModel(userID: uid, exerciseID: UUID(), sets: [set2])
        let loser = RoutineModel(id: id, userID: uid, name: "Push", exercises: [ex2])
        loser.updatedAt = date(1000)

        context.insert(winner)
        context.insert(loser)
        try context.save()

        let summary = try RoutineDeduplicator.removeDuplicates(in: context)

        XCTAssertEqual(summary.duplicateRoutinesDeleted, 1)
        let routines = try context.fetch(FetchDescriptor<RoutineModel>())
        XCTAssertEqual(routines.count, 1)
        let exercises = try context.fetch(FetchDescriptor<RoutineExerciseModel>())
        XCTAssertEqual(exercises.count, 1)
        let sets = try context.fetch(FetchDescriptor<RoutineSetModel>())
        XCTAssertEqual(sets.count, 1)
        _ = container
    }

    func testIsIdempotent() throws {
        let (container, context) = try makeContainer()
        let id = UUID()
        let uid = UUID()
        context.insert(RoutineModel(id: id, userID: uid, name: "Push Day"))
        context.insert(RoutineModel(id: id, userID: uid, name: "Push Day"))
        try context.save()

        let first = try RoutineDeduplicator.removeDuplicates(in: context)
        XCTAssertEqual(first.duplicateRoutinesDeleted, 1)

        let second = try RoutineDeduplicator.removeDuplicates(in: context)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RoutineModel>()).count, 1)
        _ = container
    }

    func testRemovesDuplicateThatArrivesAfterInitialCleanup() throws {
        let (container, context) = try makeContainer()
        let id = UUID()
        let uid = UUID()
        let original = RoutineFolderModel(id: id, userID: uid, name: "Mesocycle")
        original.updatedAt = date(1000)
        context.insert(original)
        try context.save()

        XCTAssertTrue(try RoutineDeduplicator.removeDuplicates(in: context).isEmpty)

        // Simulates the old CloudKit record arriving after the launch pass.
        let cloudArrival = RoutineFolderModel(id: id, userID: uid, name: "Mesocycle")
        cloudArrival.updatedAt = date(2000)
        context.insert(cloudArrival)
        try context.save()

        let summary = try RoutineDeduplicator.removeDuplicates(in: context)

        XCTAssertEqual(summary.duplicateFoldersDeleted, 1)
        let survivors = try context.fetch(FetchDescriptor<RoutineFolderModel>())
        XCTAssertEqual(survivors.count, 1)
        XCTAssertEqual(survivors.first?.updatedAt, date(2000))
        _ = container
    }

    func testLeavesDistinctRoutinesUntouched() throws {
        let (container, context) = try makeContainer()
        let uid = UUID()
        context.insert(RoutineModel(id: UUID(), userID: uid, name: "Push Day"))
        context.insert(RoutineModel(id: UUID(), userID: uid, name: "Pull Day"))
        try context.save()

        let summary = try RoutineDeduplicator.removeDuplicates(in: context)

        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RoutineModel>()).count, 2)
        _ = container
    }

    func testCollapsesDuplicateFoldersKeepingMostRecentlyUpdated() throws {
        let (container, context) = try makeContainer()
        let id = UUID()
        let uid = UUID()

        let older = RoutineFolderModel(id: id, userID: uid, name: "Mesocycle A")
        older.updatedAt = date(1000)
        let newer = RoutineFolderModel(id: id, userID: uid, name: "Mesocycle A (newer)")
        newer.updatedAt = date(5000)
        [older, newer].forEach(context.insert)
        try context.save()

        let summary = try RoutineDeduplicator.removeDuplicates(in: context)

        XCTAssertEqual(summary.duplicateFoldersDeleted, 1)
        let survivors = try context.fetch(FetchDescriptor<RoutineFolderModel>())
        XCTAssertEqual(survivors.count, 1)
        XCTAssertEqual(survivors.first?.name, "Mesocycle A (newer)")
        _ = container
    }

    func testSoftDeletedFolderWinsOverLive() throws {
        let (container, context) = try makeContainer()
        let id = UUID()
        let uid = UUID()

        let live = RoutineFolderModel(id: id, userID: uid, name: "Old Macrocycle")
        live.updatedAt = date(5000)
        let tombstone = RoutineFolderModel(id: id, userID: uid, name: "Old Macrocycle")
        tombstone.updatedAt = date(1000)
        tombstone.deletedAt = date(2000)
        context.insert(live)
        context.insert(tombstone)
        try context.save()

        let summary = try RoutineDeduplicator.removeDuplicates(in: context)

        XCTAssertEqual(summary.duplicateFoldersDeleted, 1)
        let survivors = try context.fetch(FetchDescriptor<RoutineFolderModel>())
        XCTAssertEqual(survivors.count, 1)
        XCTAssertNotNil(survivors.first?.deletedAt)
        _ = container
    }

    func testNestedFolderParentIDStaysValidAfterDedup() throws {
        let (container, context) = try makeContainer()
        let uid = UUID()
        let macroID = UUID()
        let mesoID = UUID()

        let macroOld = RoutineFolderModel(id: macroID, userID: uid, name: "Macrocycle")
        macroOld.updatedAt = date(1000)
        let macroNew = RoutineFolderModel(id: macroID, userID: uid, name: "Macrocycle")
        macroNew.updatedAt = date(5000)

        let mesoOld = RoutineFolderModel(id: mesoID, userID: uid, name: "Mesocycle", parentID: macroID)
        mesoOld.updatedAt = date(1000)
        let mesoNew = RoutineFolderModel(id: mesoID, userID: uid, name: "Mesocycle", parentID: macroID)
        mesoNew.updatedAt = date(5000)

        [macroOld, macroNew, mesoOld, mesoNew].forEach(context.insert)
        try context.save()

        let summary = try RoutineDeduplicator.removeDuplicates(in: context)

        XCTAssertEqual(summary.duplicateFoldersDeleted, 2)
        let folders = try context.fetch(FetchDescriptor<RoutineFolderModel>())
        XCTAssertEqual(folders.count, 2)
        let meso = folders.first { $0.parentID != nil }
        XCTAssertNotNil(meso)
        XCTAssertEqual(meso?.parentID, macroID)
        _ = container
    }

    func testLeavesDistinctFoldersUntouched() throws {
        let (container, context) = try makeContainer()
        let uid = UUID()
        context.insert(RoutineFolderModel(id: UUID(), userID: uid, name: "Macrocycle A"))
        context.insert(RoutineFolderModel(id: UUID(), userID: uid, name: "Macrocycle B"))
        try context.save()

        let summary = try RoutineDeduplicator.removeDuplicates(in: context)

        XCTAssertTrue(summary.duplicateFoldersDeleted == 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RoutineFolderModel>()).count, 2)
        _ = container
    }
}
