#if DEBUG
import ForgeData
import Foundation
import SwiftData

/// Deterministic libraries covering each hierarchy presentation used by the
/// Workout-tab UI tests. These fixtures contain no workout or Health data.
enum RoutineHierarchyUITestFixture {
    private enum State: String, CaseIterable {
        case flat = "--seed-routine-hierarchy-flat"
        case single = "--seed-routine-hierarchy-single"
        case nested = "--seed-routine-hierarchy-nested"
        case mixed = "--seed-routine-hierarchy-mixed"
    }

    static func seedIfRequested(arguments: [String], in context: ModelContext) throws {
        guard let state = State.allCases.first(where: { arguments.contains($0.rawValue) }) else {
            return
        }

        for routine in try context.fetch(FetchDescriptor<RoutineModel>()) {
            context.delete(routine)
        }
        for folder in try context.fetch(FetchDescriptor<RoutineFolderModel>()) {
            context.delete(folder)
        }

        switch state {
        case .flat:
            insertRoutine("Root Push", folderID: nil, position: 0, into: context)
            insertRoutine("Root Pull", folderID: nil, position: 1, into: context)

        case .single:
            let folder = insertFolder("Hybrid Athlete", position: 0, into: context)
            insertRoutine("Single Push", folderID: folder.id, position: 0, into: context)

        case .nested:
            let parent = insertFolder("Macro 1", position: 0, into: context)
            let child = insertFolder("Hybrid Athlete", position: 0, parentID: parent.id, into: context)
            insertRoutine("Nested Push", folderID: child.id, position: 0, into: context)

        case .mixed:
            let folder = insertFolder("Hybrid Athlete", position: 0, into: context)
            insertRoutine("Root Hotel", folderID: nil, position: 0, into: context)
            insertRoutine("Mixed Push", folderID: folder.id, position: 0, into: context)
        }

        try context.save()
    }

    @discardableResult
    private static func insertFolder(
        _ name: String,
        position: Int,
        parentID: UUID? = nil,
        into context: ModelContext
    ) -> RoutineFolderModel {
        let folder = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: name,
            position: position,
            parentID: parentID
        )
        context.insert(folder)
        return folder
    }

    private static func insertRoutine(
        _ name: String,
        folderID: UUID?,
        position: Int,
        into context: ModelContext
    ) {
        context.insert(RoutineModel(
            userID: ForgeFitDemo.userID,
            name: name,
            folderID: folderID,
            position: position
        ))
    }
}
#endif
