import Foundation
@testable import ForgeData
import SwiftData
import Testing

/// Archive/restore semantics: one shared stamp per archived unit, restores
/// that never land somewhere invisible, and positions that never collide.
@MainActor
struct RoutineArchiverTests {

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }

    /// meso ┬ micro1 ─ routineA
    ///      └ micro2 ─ routineB   + ungrouped routineC
    private func seedCycle(in context: ModelContext) -> (
        meso: RoutineFolderModel, micro1: RoutineFolderModel, micro2: RoutineFolderModel,
        routineA: RoutineModel, routineB: RoutineModel, routineC: RoutineModel
    ) {
        let uid = UUID()
        let meso = RoutineFolderModel(userID: uid, name: "Strength Peak", position: 0)
        let micro1 = RoutineFolderModel(userID: uid, name: "Volume Block", position: 0, parentID: meso.id)
        let micro2 = RoutineFolderModel(userID: uid, name: "Intensity Block", position: 1, parentID: meso.id)
        let routineA = RoutineModel(userID: uid, name: "Push", folderID: micro1.id, position: 0)
        let routineB = RoutineModel(userID: uid, name: "Pull", folderID: micro2.id, position: 0)
        let routineC = RoutineModel(userID: uid, name: "Arms", folderID: nil, position: 0)
        [meso, micro1, micro2].forEach(context.insert)
        [routineA, routineB, routineC].forEach(context.insert)
        return (meso, micro1, micro2, routineA, routineB, routineC)
    }

    @Test func archivingAFolderStampsItsSubtreeWithOneTimestamp() throws {
        let (container, context) = try makeContext()
        let cycle = seedCycle(in: context)
        let stamp = Date(timeIntervalSinceReferenceDate: 1000)

        try RoutineArchiver.archive(cycle.meso, in: context, at: stamp)

        for row in [cycle.meso.archivedAt, cycle.micro1.archivedAt, cycle.micro2.archivedAt,
                    cycle.routineA.archivedAt, cycle.routineB.archivedAt] {
            #expect(row == stamp)
        }
        #expect(cycle.routineC.archivedAt == nil)
        _ = container
    }

    @Test func archivingAFolderLeavesEarlierArchivesTheirOwnStamp() throws {
        let (container, context) = try makeContext()
        let cycle = seedCycle(in: context)
        let earlier = Date(timeIntervalSinceReferenceDate: 500)
        RoutineArchiver.archive(cycle.routineA, at: earlier)

        try RoutineArchiver.archive(cycle.meso, in: context, at: Date(timeIntervalSinceReferenceDate: 1000))

        #expect(cycle.routineA.archivedAt == earlier)
        _ = container
    }

    @Test func restoringAFolderRestoresOnlyItsUnit() throws {
        let (container, context) = try makeContext()
        let cycle = seedCycle(in: context)
        RoutineArchiver.archive(cycle.routineA, at: Date(timeIntervalSinceReferenceDate: 500))
        try RoutineArchiver.archive(cycle.meso, in: context, at: Date(timeIntervalSinceReferenceDate: 1000))

        try RoutineArchiver.restore(cycle.meso, in: context)

        #expect(cycle.meso.archivedAt == nil)
        #expect(cycle.micro1.archivedAt == nil)
        #expect(cycle.micro2.archivedAt == nil)
        #expect(cycle.routineB.archivedAt == nil)
        // Archived deliberately before the folder — stays archived.
        #expect(cycle.routineA.archivedAt != nil)
        _ = container
    }

    @Test func restoringANestedRoutineReparentsToNearestLiveAncestor() throws {
        let (container, context) = try makeContext()
        let cycle = seedCycle(in: context)
        // Archive just the micro: its routine rides along; the meso stays live.
        try RoutineArchiver.archive(cycle.micro1, in: context)

        try RoutineArchiver.restore(cycle.routineA, in: context)

        #expect(cycle.routineA.archivedAt == nil)
        #expect(cycle.routineA.folderID == cycle.meso.id)
        #expect(cycle.micro1.archivedAt != nil)
        _ = container
    }

    @Test func restoringARoutineWithNoLiveAncestorGoesTopLevel() throws {
        let (container, context) = try makeContext()
        let cycle = seedCycle(in: context)
        try RoutineArchiver.archive(cycle.meso, in: context)

        try RoutineArchiver.restore(cycle.routineA, in: context)

        #expect(cycle.routineA.folderID == nil)
        _ = container
    }

    @Test func restoringAMicroInsideAnArchivedMesoBringsItsRoutinesToTopLevel() throws {
        let (container, context) = try makeContext()
        let cycle = seedCycle(in: context)
        try RoutineArchiver.archive(cycle.meso, in: context)

        try RoutineArchiver.restore(cycle.micro1, in: context)

        // The micro can't live under a still-archived meso — it surfaces at
        // the top level, and the routines stamped with it come back inside it.
        #expect(cycle.micro1.archivedAt == nil)
        #expect(cycle.micro1.parentID == nil)
        #expect(cycle.routineA.archivedAt == nil)
        #expect(cycle.routineA.folderID == cycle.micro1.id)
        #expect(cycle.meso.archivedAt != nil)
        #expect(cycle.routineB.archivedAt != nil)
        _ = container
    }

    @Test func restoredRowsAppendAfterLiveSiblings() throws {
        let (container, context) = try makeContext()
        let cycle = seedCycle(in: context)
        RoutineArchiver.archive(cycle.routineC)
        // While it's away, two new top-level routines take positions 0 and 1.
        let uid = cycle.routineC.userID
        context.insert(RoutineModel(userID: uid, name: "New One", folderID: nil, position: 0))
        context.insert(RoutineModel(userID: uid, name: "New Two", folderID: nil, position: 1))

        try RoutineArchiver.restore(cycle.routineC, in: context)

        #expect(cycle.routineC.position == 2)
        _ = container
    }

    @Test func restoringANeverArchivedFolderIsHarmless() throws {
        let (container, context) = try makeContext()
        let cycle = seedCycle(in: context)

        try RoutineArchiver.restore(cycle.micro1, in: context)

        #expect(cycle.micro1.archivedAt == nil)
        #expect(cycle.micro1.parentID == cycle.meso.id)
        #expect(cycle.routineA.archivedAt == nil)
        _ = container
    }
}
