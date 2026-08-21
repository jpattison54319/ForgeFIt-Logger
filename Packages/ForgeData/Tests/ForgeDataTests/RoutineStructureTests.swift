@testable import ForgeData
import XCTest

@MainActor
final class RoutineStructureTests: XCTestCase {
    func testNormalizeDeduplicatesRelationshipsAndCanonicalizesMixedOrder() {
        let userID = UUID()
        let firstSet = RoutineSetModel(userID: userID, position: 4)
        let secondSet = RoutineSetModel(userID: userID, position: 4)
        let exercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            position: 7,
            sets: [secondSet, firstSet, firstSet]
        )
        let block = RoutineBlockModel(
            userID: userID,
            kind: .conditioning,
            position: 7
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Normalize",
            exercises: [exercise, exercise],
            blocks: [block, block]
        )

        RoutineStructure.normalize(routine)

        XCTAssertEqual(routine.exercises.count, 1)
        XCTAssertEqual(routine.blocks.count, 1)
        XCTAssertEqual(OrderedRoutineItem.ordered(in: routine).map(\.id), [block.id, exercise.id])
        XCTAssertEqual(OrderedRoutineItem.ordered(in: routine).map(\.position), [0, 1])
        XCTAssertEqual(exercise.sets.count, 2)
        XCTAssertEqual(exercise.sets.sorted { $0.position < $1.position }.map(\.position), [0, 1])
    }

    func testNextRoutinePositionUsesOnlyTheDestinationFolder() {
        let userID = UUID()
        let folderID = UUID()
        let otherFolderID = UUID()
        let inFolder = RoutineModel(userID: userID, name: "A", folderID: folderID, position: 2)
        let otherFolder = RoutineModel(userID: userID, name: "B", folderID: otherFolderID, position: 99)
        let deleted = RoutineModel(userID: userID, name: "Deleted", folderID: folderID, position: 20)
        deleted.deletedAt = .now
        let archived = RoutineModel(userID: userID, name: "Archived", folderID: folderID, position: 30)
        archived.archivedAt = .now

        XCTAssertEqual(
            RoutineStructure.nextRoutinePosition(
                in: [inFolder, otherFolder, deleted, archived],
                folderID: folderID
            ),
            3
        )
        XCTAssertEqual(
            RoutineStructure.nextRoutinePosition(
                in: [inFolder, otherFolder, deleted, archived],
                folderID: nil
            ),
            0
        )
    }
}
