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

    /// macro ┬ meso1 ─ routineA
    ///       └ meso2 ─ routineB   + ungrouped routineC
    private func seedCycle(in context: ModelContext) -> (
        macro: RoutineFolderModel, meso1: RoutineFolderModel, meso2: RoutineFolderModel,
        routineA: RoutineModel, routineB: RoutineModel, routineC: RoutineModel
    ) {
        let uid = UUID()
        let macro = RoutineFolderModel(userID: uid, name: "Strength Peak", position: 0)
        let meso1 = RoutineFolderModel(userID: uid, name: "Volume Block", position: 0, parentID: macro.id)
        let meso2 = RoutineFolderModel(userID: uid, name: "Intensity Block", position: 1, parentID: macro.id)
        let routineA = RoutineModel(userID: uid, name: "Push", folderID: meso1.id, position: 0)
        let routineB = RoutineModel(userID: uid, name: "Pull", folderID: meso2.id, position: 0)
        let routineC = RoutineModel(userID: uid, name: "Arms", folderID: nil, position: 0)
        [macro, meso1, meso2].forEach(context.insert)
        [routineA, routineB, routineC].forEach(context.insert)
        return (macro, meso1, meso2, routineA, routineB, routineC)
    }

    @Test func archivingAFolderStampsItsSubtreeWithOneTimestamp() throws {
        let (container, context) = try makeContext()
        let cycle = seedCycle(in: context)
        let stamp = Date(timeIntervalSinceReferenceDate: 1000)

        try RoutineArchiver.archive(cycle.macro, in: context, at: stamp)

        for row in [cycle.macro.archivedAt, cycle.meso1.archivedAt, cycle.meso2.archivedAt,
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

        try RoutineArchiver.archive(cycle.macro, in: context, at: Date(timeIntervalSinceReferenceDate: 1000))

        #expect(cycle.routineA.archivedAt == earlier)
        _ = container
    }

    @Test func restoringAFolderRestoresOnlyItsUnit() throws {
        let (container, context) = try makeContext()
        let cycle = seedCycle(in: context)
        RoutineArchiver.archive(cycle.routineA, at: Date(timeIntervalSinceReferenceDate: 500))
        try RoutineArchiver.archive(cycle.macro, in: context, at: Date(timeIntervalSinceReferenceDate: 1000))

        try RoutineArchiver.restore(cycle.macro, in: context)

        #expect(cycle.macro.archivedAt == nil)
        #expect(cycle.meso1.archivedAt == nil)
        #expect(cycle.meso2.archivedAt == nil)
        #expect(cycle.routineB.archivedAt == nil)
        // Archived deliberately before the folder — stays archived.
        #expect(cycle.routineA.archivedAt != nil)
        _ = container
    }

    @Test func restoringANestedRoutineReparentsToNearestLiveAncestor() throws {
        let (container, context) = try makeContext()
        let cycle = seedCycle(in: context)
        // Archive just the meso: its routine rides along; the macro stays live.
        try RoutineArchiver.archive(cycle.meso1, in: context)

        try RoutineArchiver.restore(cycle.routineA, in: context)

        #expect(cycle.routineA.archivedAt == nil)
        #expect(cycle.routineA.folderID == cycle.macro.id)
        #expect(cycle.meso1.archivedAt != nil)
        _ = container
    }

    @Test func restoringARoutineWithNoLiveAncestorGoesTopLevel() throws {
        let (container, context) = try makeContext()
        let cycle = seedCycle(in: context)
        try RoutineArchiver.archive(cycle.macro, in: context)

        try RoutineArchiver.restore(cycle.routineA, in: context)

        #expect(cycle.routineA.folderID == nil)
        _ = container
    }

    @Test func restoringAMesoInsideAnArchivedMacroBringsItsRoutinesToTopLevel() throws {
        let (container, context) = try makeContext()
        let cycle = seedCycle(in: context)
        try RoutineArchiver.archive(cycle.macro, in: context)

        try RoutineArchiver.restore(cycle.meso1, in: context)

        // The meso can't live under a still-archived macro — it surfaces at
        // the top level, and the routines stamped with it come back inside it.
        #expect(cycle.meso1.archivedAt == nil)
        #expect(cycle.meso1.parentID == nil)
        #expect(cycle.routineA.archivedAt == nil)
        #expect(cycle.routineA.folderID == cycle.meso1.id)
        #expect(cycle.macro.archivedAt != nil)
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

        try RoutineArchiver.restore(cycle.meso1, in: context)

        #expect(cycle.meso1.archivedAt == nil)
        #expect(cycle.meso1.parentID == cycle.macro.id)
        #expect(cycle.routineA.archivedAt == nil)
        _ = container
    }
}
