#if DEBUG
import ForgeData
import Foundation
import SwiftData

/// Deterministic library used only by the routine drag/drop UI tests.
enum RoutineReorderUITestFixture {
    static func seed(in context: ModelContext) throws {
        for routine in try context.fetch(FetchDescriptor<RoutineModel>()) {
            context.delete(routine)
        }
        for folder in try context.fetch(FetchDescriptor<RoutineFolderModel>()) {
            context.delete(folder)
        }

        let firstFolder = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: "Folder One",
            position: 0
        )
        let secondFolder = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: "Folder Two",
            position: 1
        )
        context.insert(firstFolder)
        context.insert(secondFolder)

        insertRoutines(
            ["One A", "One B", "One C"],
            folderID: firstFolder.id,
            into: context
        )
        insertRoutines(
            ["Two A", "Two B"],
            folderID: secondFolder.id,
            into: context
        )
        insertRoutines(
            ["Ungrouped One", "Ungrouped Two"],
            folderID: nil,
            into: context
        )
        try context.save()
    }

    private static func insertRoutines(
        _ names: [String],
        folderID: UUID?,
        into context: ModelContext
    ) {
        for (position, name) in names.enumerated() {
            context.insert(RoutineModel(
                userID: ForgeFitDemo.userID,
                name: name,
                folderID: folderID,
                position: position
            ))
        }
    }
}
#endif
