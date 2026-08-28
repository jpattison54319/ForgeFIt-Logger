#if DEBUG
import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Deterministic libraries covering each hierarchy presentation used by the
/// Workout-tab UI tests. Alternation fixtures cover both due states and both
/// same-folder/cross-folder placement; none contain Health data.
enum RoutineHierarchyUITestFixture {
    private enum CompletedAlternatingMember: Equatable {
        case owner
    }

    private enum State: String, CaseIterable {
        case flat = "--seed-routine-hierarchy-flat"
        case single = "--seed-routine-hierarchy-single"
        case nested = "--seed-routine-hierarchy-nested"
        case mixed = "--seed-routine-hierarchy-mixed"
        case manyExercises = "--seed-routine-hierarchy-many-exercises"
        case ungroupedDisclosure = "--seed-routine-hierarchy-ungrouped-disclosure"
        case alternatingCrossGroupOwnerDue = "--seed-routine-hierarchy-alternating-cross-group-owner-due"
        case alternatingCrossGroupPartnerDue = "--seed-routine-hierarchy-alternating-cross-group"
        case alternatingSameGroupPartnerDue = "--seed-routine-hierarchy-alternating-same-group"
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
                    ExerciseCatalog.deterministicID(for: "Barbell_Bench_Press_-_Medium_Grip"),
                    ExerciseCatalog.deterministicID(for: "Wide-Grip_Lat_Pulldown"),
                    ExerciseCatalog.deterministicID(for: "Leg_Press"),
                    ExerciseCatalog.deterministicID(for: "Seated_Side_Lateral_Raise"),
                ],
                targetSetCount: 4,
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

        case .alternatingCrossGroupOwnerDue:
            let folder = insertFolder("AX Plans", position: 0, into: context)
            insertAlternatingPair(
                ownerFolderID: folder.id,
                partnerFolderID: nil,
                completedMember: nil,
                into: context
            )

        case .alternatingCrossGroupPartnerDue:
            let folder = insertFolder("AX Plans", position: 0, into: context)
            insertAlternatingPair(
                ownerFolderID: folder.id,
                partnerFolderID: nil,
                completedMember: .owner,
                into: context
            )

        case .alternatingSameGroupPartnerDue:
            let folder = insertFolder("Same Plan", position: 0, into: context)
            insertAlternatingPair(
                ownerFolderID: folder.id,
                partnerFolderID: folder.id,
                completedMember: .owner,
                into: context
            )
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
        includesTargetSet: Bool = false,
        targetSetCount: Int? = nil,
        into context: ModelContext
    ) -> RoutineModel {
        let setCount = max(0, targetSetCount ?? (includesTargetSet ? 1 : 0))
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: name,
            folderID: folderID,
            position: position,
            exercises: exerciseIDs.enumerated().map { index, exerciseID in
                RoutineExerciseModel(
                    userID: ForgeFitDemo.userID,
                    exerciseID: exerciseID,
                    position: index,
                    sets: (0..<setCount).map { setPosition in
                        RoutineSetModel(
                            userID: ForgeFitDemo.userID,
                            position: setPosition,
                            targetRepsLow: 10,
                            targetRepsHigh: 12,
                            targetWeight: 50
                        )
                    }
                )
            }
        )
        context.insert(routine)
        return routine
    }

    private static func insertAlternatingPair(
        ownerFolderID: UUID?,
        partnerFolderID: UUID?,
        completedMember: CompletedAlternatingMember?,
        into context: ModelContext
    ) {
        let owner = insertRoutine(
            "Ax400",
            folderID: ownerFolderID,
            position: 0,
            exerciseIDs: [GlobalExerciseLibrary.machineChestPressID],
            includesTargetSet: true,
            into: context
        )
        let partner = insertRoutine(
            "Cindy",
            folderID: partnerFolderID,
            position: ownerFolderID == partnerFolderID ? 1 : 0,
            exerciseIDs: [GlobalExerciseLibrary.smithMachineSquatID],
            includesTargetSet: true,
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
        if completedMember == .owner {
            context.insert(WorkoutModel(
                userID: ForgeFitDemo.userID,
                routineID: owner.id,
                title: owner.name,
                startedAt: now.addingTimeInterval(-3_600),
                endedAt: now.addingTimeInterval(-1_800)
            ))
        }
    }
}
#endif
