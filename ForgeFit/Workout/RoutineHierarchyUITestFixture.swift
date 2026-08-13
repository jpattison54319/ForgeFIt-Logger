#if DEBUG
import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Deterministic libraries covering each hierarchy presentation used by the
/// Workout-tab UI tests. The alternation fixture includes one completed
/// routine link to advance the pair; none of these fixtures contain Health data.
enum RoutineHierarchyUITestFixture {
    private enum State: String, CaseIterable {
        case flat = "--seed-routine-hierarchy-flat"
        case single = "--seed-routine-hierarchy-single"
        case nested = "--seed-routine-hierarchy-nested"
        case mixed = "--seed-routine-hierarchy-mixed"
        case manyExercises = "--seed-routine-hierarchy-many-exercises"
        case ungroupedDisclosure = "--seed-routine-hierarchy-ungrouped-disclosure"
        case alternatingCrossGroup = "--seed-routine-hierarchy-alternating-cross-group"
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
        for alternation in try context.fetch(FetchDescriptor<RoutineAlternationModel>()) {
            context.delete(alternation)
        }
        for workout in try context.fetch(FetchDescriptor<WorkoutModel>()) {
            context.delete(workout)
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

        case .manyExercises:
            insertRoutine(
                "Long Routine",
                folderID: nil,
                position: 0,
                exerciseIDs: [
                    GlobalExerciseLibrary.machineChestPressID,
                    GlobalExerciseLibrary.overheadCableTricepsExtensionID,
                    GlobalExerciseLibrary.chestSupportedTBarRowID,
                    GlobalExerciseLibrary.bayesianCableCurlID,
                ],
                into: context
            )
            insertRoutine(
                "Short Routine",
                folderID: nil,
                position: 1,
                exerciseIDs: [
                    GlobalExerciseLibrary.romanianDeadliftID,
                    GlobalExerciseLibrary.smithMachineSquatID,
                ],
                into: context
            )

        case .ungroupedDisclosure:
            _ = insertFolder("Plans", position: 0, into: context)
            insertRoutine("Full Body A", folderID: nil, position: 0, into: context)

        case .alternatingCrossGroup:
            let folder = insertFolder("AX Plans", position: 0, into: context)
            let owner = insertRoutine(
                "Ax400",
                folderID: folder.id,
                position: 0,
                exerciseIDs: [GlobalExerciseLibrary.machineChestPressID],
                into: context
            )
            let partner = insertRoutine(
                "Cindy",
                folderID: nil,
                position: 0,
                exerciseIDs: [GlobalExerciseLibrary.smithMachineSquatID],
                into: context
            )
            let now = Date()
            context.insert(RoutineAlternationModel(
                userID: ForgeFitDemo.userID,
                ownerRoutineID: owner.id,
                partnerRoutineID: partner.id,
                createdAt: now.addingTimeInterval(-7_200),
                updatedAt: now.addingTimeInterval(-7_200)
            ))
            context.insert(WorkoutModel(
                userID: ForgeFitDemo.userID,
                routineID: owner.id,
                title: owner.name,
                startedAt: now.addingTimeInterval(-3_600),
                endedAt: now.addingTimeInterval(-1_800)
            ))
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

    @discardableResult
    private static func insertRoutine(
        _ name: String,
        folderID: UUID?,
        position: Int,
        exerciseIDs: [UUID] = [],
        into context: ModelContext
    ) -> RoutineModel {
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: name,
            folderID: folderID,
            position: position,
            exercises: exerciseIDs.enumerated().map { index, exerciseID in
                RoutineExerciseModel(
                    userID: ForgeFitDemo.userID,
                    exerciseID: exerciseID,
                    position: index
                )
            }
        )
        context.insert(routine)
        return routine
    }
}
#endif
