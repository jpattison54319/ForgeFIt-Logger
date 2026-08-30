import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
@Suite("Routine organizer")
struct RoutineOrganizerTests {
    @Test("Duplicate physical rows become one authored routine in the draft")
    func canonicalizesDuplicateRoutineIDsBeforeOrganizing() throws {
        let id = UUID()
        let staleExercise = RoutineExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let stale = RoutineModel(
            id: id,
            userID: ForgeFitDemo.userID,
            name: "Stale",
            updatedAt: Date(timeIntervalSince1970: 90),
            exercises: [staleExercise]
        )
        let editedExercise = RoutineExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        let edited = RoutineModel(
            id: id,
            userID: ForgeFitDemo.userID,
            name: "Edited",
            updatedAt: Date(timeIntervalSince1970: 50),
            exercises: [editedExercise]
        )

        let draft = RoutineOrganizerDraft(folders: [], routines: [stale, edited])

        #expect(draft.allRoutineIDs == [id])
        let item = try #require(draft.routines(in: .ungrouped).first)
        #expect(item.name == "Edited")
    }

    @Test("Persistence rejects duplicate logical rows instead of trapping")
    func persistenceRejectsDuplicateRoutineIDs() {
        let id = UUID()
        let first = RoutineModel(id: id, userID: ForgeFitDemo.userID, name: "First")
        let second = RoutineModel(id: id, userID: ForgeFitDemo.userID, name: "Second")
        let draft = RoutineOrganizerDraft(folders: [], routines: [first, second])

        #expect(throws: RoutineOrganizerPersistence.PersistenceError.self) {
            try RoutineOrganizerPersistence.apply(
                draft,
                folders: [],
                routines: [first, second]
            )
        }
    }

    @Test("Several draft moves leave models untouched until one apply")
    func stagesThenAppliesSeveralMoves() throws {
        let firstFolder = folder("First", position: 0)
        let secondFolder = folder("Second", position: 1)
        let first = routine("First A", folderID: firstFolder.id, position: 0)
        let second = routine("First B", folderID: firstFolder.id, position: 1)
        let destination = routine("Second A", folderID: secondFolder.id, position: 0)
        let draft = RoutineOrganizerDraft(
            folders: [firstFolder, secondFolder],
            routines: [first, second, destination]
        )

        #expect(draft.moveRoutine(first.id, to: .folder(firstFolder.id)))
        #expect(draft.moveRoutine(first.id, to: .folder(secondFolder.id)))
        #expect(draft.moveFolder(secondFolder.id, to: nil, before: firstFolder.id))

        #expect(first.folderID == firstFolder.id)
        #expect(first.position == 0)
        #expect(firstFolder.position == 0)
        #expect(secondFolder.position == 1)

        try RoutineOrganizerPersistence.apply(
            draft,
            folders: [firstFolder, secondFolder],
            routines: [first, second, destination]
        )

        #expect(secondFolder.position == 0)
        #expect(firstFolder.position == 1)
        #expect(second.folderID == firstFolder.id)
        #expect(second.position == 0)
        #expect(destination.folderID == secondFolder.id)
        #expect(destination.position == 0)
        #expect(first.folderID == secondFolder.id)
        #expect(first.position == 1)
    }

    @Test("The compact stream preserves the Workout hierarchy")
    func entriesMirrorWorkoutHierarchy() throws {
        let parent = folder("Mesocycle", position: 0)
        let child = folder("Microcycle", position: 0, parentID: parent.id)
        let leaf = folder("Standalone", position: 1)
        let loose = routine("Loose", folderID: nil, position: 0)
        let nested = routine("Nested", folderID: child.id, position: 0)
        let standalone = routine("Standalone A", folderID: leaf.id, position: 0)
        let draft = RoutineOrganizerDraft(
            folders: [parent, child, leaf],
            routines: [loose, nested, standalone]
        )

        let expectedEntryIDs: [RoutineOrganizerDraft.EntryID] = [
            .ungrouped,
            .routine(loose.id),
            .folder(parent.id),
            .folder(child.id),
            .routine(nested.id),
            .folder(leaf.id),
            .routine(standalone.id),
        ]
        #expect(draft.entries.map(\.id) == expectedEntryIDs)

        let childEntry = try #require(draft.entries.first { $0.id == .folder(child.id) })
        guard case .folder(_, let parentID, let depth) = childEntry.kind else {
            Issue.record("Expected the child folder entry")
            return
        }
        #expect(parentID == parent.id)
        #expect(depth == 1)

        let nestedEntry = try #require(draft.entries.first { $0.id == .routine(nested.id) })
        guard case .routine(_, let destination, let depth) = nestedEntry.kind else {
            Issue.record("Expected the nested routine entry")
            return
        }
        #expect(destination == .folder(child.id))
        #expect(depth == 2)
    }

    @Test("Dragging a child before a root folder moves it to the root")
    func flatMoveUnnestsChildFolder() throws {
        let parent = folder("Parent", position: 0)
        let child = folder("Child", position: 0, parentID: parent.id)
        let planned = routine("Planned", folderID: child.id, position: 0)
        let siblingRoot = folder("Next Root", position: 1)
        let draft = RoutineOrganizerDraft(
            folders: [parent, child, siblingRoot],
            routines: [planned]
        )
        let childIndex = try #require(draft.entries.firstIndex { $0.id == .folder(child.id) })
        let siblingIndex = try #require(draft.entries.firstIndex { $0.id == .folder(siblingRoot.id) })

        #expect(draft.moveEntries(
            from: IndexSet(integer: childIndex),
            to: siblingIndex
        ))
        #expect(draft.parentID(of: child.id) == nil)
        #expect(draft.rootFolderIDs == [parent.id, child.id, siblingRoot.id])
        #expect(draft.routines(in: .folder(child.id)).first?.id == planned.id)
    }

    @Test("Dragging a child beside another parent's child reparents it")
    func flatMoveReparentsChildFolder() throws {
        let firstParent = folder("First Parent", position: 0)
        let firstChild = folder("First Child", position: 0, parentID: firstParent.id)
        let secondParent = folder("Second Parent", position: 1)
        let secondChild = folder("Second Child", position: 0, parentID: secondParent.id)
        let firstRoutine = routine("First Routine", folderID: firstChild.id, position: 0)
        let secondRoutine = routine("Second Routine", folderID: secondChild.id, position: 0)
        let draft = RoutineOrganizerDraft(
            folders: [firstParent, firstChild, secondParent, secondChild],
            routines: [firstRoutine, secondRoutine]
        )
        let sourceIndex = try #require(draft.entries.firstIndex { $0.id == .folder(secondChild.id) })
        let destinationIndex = try #require(draft.entries.firstIndex { $0.id == .folder(firstChild.id) })

        #expect(draft.moveEntries(
            from: IndexSet(integer: sourceIndex),
            to: destinationIndex
        ))
        #expect(draft.parentID(of: secondChild.id) == firstParent.id)
        #expect(draft.children(of: firstParent.id) == [secondChild.id, firstChild.id])
        #expect(draft.routines(in: .folder(secondChild.id)).first?.id == secondRoutine.id)
    }

    @Test("Dragging a routine below a leaf folder header moves it into that folder")
    func flatMoveChangesRoutineDestination() throws {
        let target = folder("Target", position: 0)
        let loose = routine("Loose", folderID: nil, position: 0)
        let existing = routine("Existing", folderID: target.id, position: 0)
        let draft = RoutineOrganizerDraft(
            folders: [target],
            routines: [loose, existing]
        )
        let sourceIndex = try #require(draft.entries.firstIndex { $0.id == .routine(loose.id) })
        let existingIndex = try #require(draft.entries.firstIndex { $0.id == .routine(existing.id) })

        #expect(draft.moveEntries(
            from: IndexSet(integer: sourceIndex),
            to: existingIndex
        ))
        #expect(draft.routines(in: .ungrouped).isEmpty)
        #expect(draft.routines(in: .folder(target.id)).map(\.id) == [loose.id, existing.id])
    }

    @Test(
        "Dragging within a folder keeps the visible order",
        arguments: [false, true]
    )
    func flatMoveReordersInsideFolder(nested: Bool) throws {
        let parent = folder("Parent", position: 0)
        let target = folder(
            "Target",
            position: 0,
            parentID: nested ? parent.id : nil
        )
        let first = routine("First", folderID: target.id, position: 0)
        let second = routine("Second", folderID: target.id, position: 1)
        let third = routine("Third", folderID: target.id, position: 2)
        let draft = RoutineOrganizerDraft(
            folders: nested ? [parent, target] : [target],
            routines: [first, second, third]
        )
        let sourceIndex = try #require(draft.entries.firstIndex { $0.id == .routine(first.id) })
        let destinationIndex = try #require(draft.entries.firstIndex { $0.id == .routine(third.id) })

        #expect(draft.moveEntries(
            from: IndexSet(integer: sourceIndex),
            to: destinationIndex + 1
        ))
        #expect(draft.routines(in: .folder(target.id)).map(\.id) == [second.id, third.id, first.id])
        #expect(draft.entries.filter { entry in
            if case .routine(_, .folder(target.id), _) = entry.kind { true } else { false }
        }.map(\.id) == [.routine(second.id), .routine(third.id), .routine(first.id)])
    }

    @Test("Routine order inside a microcycle is durable in a fresh context")
    func microcycleRoutineOrderPersistsAcrossContexts() throws {
        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let mesocycle = folder("Mesocycle", position: 0)
        let microcycle = folder("Microcycle", position: 0, parentID: mesocycle.id)
        let first = routine("First", folderID: microcycle.id, position: 0)
        let second = routine("Second", folderID: microcycle.id, position: 1)
        let third = routine("Third", folderID: microcycle.id, position: 2)
        [mesocycle, microcycle].forEach(context.insert)
        [first, second, third].forEach(context.insert)
        try context.save()

        let draft = RoutineOrganizerDraft(
            folders: [mesocycle, microcycle],
            routines: [first, second, third]
        )
        #expect(draft.moveRoutine(first.id, to: .folder(microcycle.id)))
        try RoutineOrganizerPersistence.commit(
            draft,
            folders: [mesocycle, microcycle],
            routines: [first, second, third],
            in: context
        )

        let verificationContext = ModelContext(container)
        verificationContext.autosaveEnabled = false
        let microcycleID = microcycle.id
        let persisted = try verificationContext.fetch(
            FetchDescriptor<RoutineModel>(
                predicate: #Predicate { $0.folderID == microcycleID },
                sortBy: [SortDescriptor(\RoutineModel.position)]
            )
        )
        #expect(persisted.map(\.name) == ["Second", "Third", "First"])
        #expect(persisted.map(\.position) == [0, 1, 2])
    }

    @Test("A failed organizer save restores the old order and retry stays exact")
    func failedCommitLeavesNoReorderResidueBeforeRetry() throws {
        enum ExpectedFailure: Error { case write }

        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let microcycle = folder("Microcycle", position: 0)
        let first = routine("First", folderID: microcycle.id, position: 0)
        let second = routine("Second", folderID: microcycle.id, position: 1)
        [microcycle].forEach(context.insert)
        [first, second].forEach(context.insert)
        try context.save()

        let draft = RoutineOrganizerDraft(
            folders: [microcycle],
            routines: [first, second]
        )
        #expect(draft.moveRoutine(first.id, to: .folder(microcycle.id)))
        #expect(throws: ExpectedFailure.write) {
            try RoutineOrganizerPersistence.commit(
                draft,
                folders: [microcycle],
                routines: [first, second],
                in: context,
                save: { _ in throw ExpectedFailure.write }
            )
        }

        #expect(first.position == 0)
        #expect(second.position == 1)
        try context.save()
        let beforeRetry = ModelContext(container)
        beforeRetry.autosaveEnabled = false
        #expect(try beforeRetry.fetch(
            FetchDescriptor<RoutineModel>(sortBy: [SortDescriptor(\.position)])
        ).map(\.name) == ["First", "Second"])

        try RoutineOrganizerPersistence.commit(
            draft,
            folders: [microcycle],
            routines: [first, second],
            in: context
        )
        let afterRetry = ModelContext(container)
        afterRetry.autosaveEnabled = false
        #expect(try afterRetry.fetch(
            FetchDescriptor<RoutineModel>(sortBy: [SortDescriptor(\.position)])
        ).map(\.name) == ["Second", "First"])
    }

    @Test("A routine-holding folder cannot become a mesocycle implicitly")
    func requiresRoutinesToMoveBeforeNesting() {
        let target = folder("Target", position: 0)
        let child = folder("Child", position: 1)
        let planned = routine("Planned", folderID: target.id, position: 0)
        let draft = RoutineOrganizerDraft(
            folders: [target, child],
            routines: [planned]
        )

        #expect(!draft.validParents(for: child.id).contains(target.id))
        #expect(!draft.moveFolder(child.id, to: target.id))
        #expect(draft.moveRoutine(planned.id, to: .ungrouped))
        #expect(draft.validParents(for: child.id).contains(target.id))
        #expect(draft.moveFolder(child.id, to: target.id))
        #expect(draft.parentID(of: child.id) == target.id)
        #expect(draft.routines(in: .folder(target.id)).isEmpty)
    }

    @Test("An alternating pair remains one row and persists consecutively")
    func keepsAlternatingPairTogether() throws {
        let source = folder("Source", position: 0)
        let destination = folder("Destination", position: 1)
        let owner = routine("A", folderID: source.id, position: 0)
        let partner = routine("B", folderID: source.id, position: 1)
        let last = routine("Last", folderID: destination.id, position: 0)
        let alternation = RoutineAlternationModel(
            userID: ForgeFitDemo.userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id
        )
        let state = RoutineAlternationService.State(
            alternation: alternation,
            owner: owner,
            partner: partner,
            due: owner
        )
        let draft = RoutineOrganizerDraft(
            folders: [source, destination],
            routines: [owner, partner, last],
            alternationStates: [state]
        )

        let pair = try #require(draft.routines(in: .folder(source.id)).first)
        #expect(pair.routineIDs == [owner.id, partner.id])
        #expect(draft.moveRoutine(pair.id, to: .folder(destination.id)))

        try RoutineOrganizerPersistence.apply(
            draft,
            folders: [source, destination],
            routines: [owner, partner, last]
        )
        #expect(owner.folderID == destination.id)
        #expect(partner.folderID == destination.id)
        let persistedPositions: [Int] = [last.position, owner.position, partner.position]
        #expect(persistedPositions == [0, 1, 2])
    }

    @Test("A fully colocated alternating cycle moves as one row in library order")
    func keepsColocatedAlternatingCycleTogether() throws {
        let source = folder("Source", position: 0)
        let destination = folder("Destination", position: 1)
        let owner = routine("A", folderID: source.id, position: 0)
        let second = routine("B", folderID: source.id, position: 1)
        let third = routine("C", folderID: source.id, position: 2)
        let last = routine("Last", folderID: destination.id, position: 0)
        let alternation = RoutineAlternationModel(
            userID: ForgeFitDemo.userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: third.id,
            memberRoutineIDs: [owner.id, third.id, second.id]
        )
        let state = RoutineAlternationService.State(
            alternation: alternation,
            owner: owner,
            members: [owner, third, second],
            due: owner
        )
        let draft = RoutineOrganizerDraft(
            folders: [source, destination],
            routines: [third, owner, second, last],
            alternationStates: [state]
        )

        let cycle = try #require(draft.routines(in: .folder(source.id)).first)
        #expect(cycle.routineIDs == [owner.id, second.id, third.id])
        #expect(cycle.name == "A / C / B")
        #expect(draft.moveRoutine(cycle.id, to: .folder(destination.id)))

        try RoutineOrganizerPersistence.apply(
            draft,
            folders: [source, destination],
            routines: [owner, second, third, last]
        )

        #expect([owner.folderID, second.folderID, third.folderID].allSatisfy { $0 == destination.id })
        let persistedPositions: [Int] = [
            last.position,
            owner.position,
            second.position,
            third.position,
        ]
        #expect(persistedPositions == [0, 1, 2, 3])
    }

    @Test("A cycle split across destinations never partially collapses")
    func leavesSplitAlternatingCycleIndependent() {
        let source = folder("Source", position: 0)
        let destination = folder("Destination", position: 1)
        let owner = routine("A", folderID: source.id, position: 0)
        let second = routine("B", folderID: source.id, position: 1)
        let third = routine("C", folderID: destination.id, position: 0)
        let alternation = RoutineAlternationModel(
            userID: ForgeFitDemo.userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: second.id,
            memberRoutineIDs: [owner.id, second.id, third.id]
        )
        let state = RoutineAlternationService.State(
            alternation: alternation,
            owner: owner,
            members: [owner, second, third],
            due: owner
        )
        let draft = RoutineOrganizerDraft(
            folders: [source, destination],
            routines: [owner, second, third],
            alternationStates: [state]
        )

        #expect(draft.routines(in: .folder(source.id)).map(\.routineIDs) == [[owner.id], [second.id]])
        #expect(draft.routines(in: .folder(destination.id)).map(\.routineIDs) == [[third.id]])
    }

    @Test("A child folder can return to the root without changing its routines")
    func unnestsFolderWithoutMovingRoutines() throws {
        let parent = folder("Parent", position: 0)
        let child = folder("Child", position: 0, parentID: parent.id)
        let planned = routine("Planned", folderID: child.id, position: 0)
        let draft = RoutineOrganizerDraft(
            folders: [parent, child],
            routines: [planned]
        )

        #expect(draft.moveFolder(child.id, to: nil))
        try RoutineOrganizerPersistence.apply(
            draft,
            folders: [parent, child],
            routines: [planned]
        )

        #expect(child.parentID == nil)
        #expect(child.position == 1)
        #expect(planned.folderID == child.id)
    }

    @Test("Failure recovery restores root membership, positions, and timestamps")
    func restoresOriginalSnapshot() throws {
        let originalDate = Date(timeIntervalSince1970: 10)
        let parent = folder("Parent", position: 0)
        let child = folder("Child", position: 0, parentID: parent.id)
        child.updatedAt = originalDate
        let planned = routine("Planned", folderID: child.id, position: 0)
        planned.updatedAt = originalDate
        let draft = RoutineOrganizerDraft(
            folders: [parent, child],
            routines: [planned]
        )

        #expect(draft.moveFolder(child.id, to: nil))
        #expect(draft.moveRoutine(planned.id, to: .ungrouped))
        try RoutineOrganizerPersistence.apply(
            draft,
            folders: [parent, child],
            routines: [planned],
            now: Date(timeIntervalSince1970: 20)
        )
        RoutineOrganizerPersistence.restoreOriginal(
            draft,
            folders: [parent, child],
            routines: [planned]
        )

        #expect(child.parentID == parent.id)
        #expect(child.position == 0)
        #expect(child.updatedAt == originalDate)
        #expect(planned.folderID == child.id)
        #expect(planned.position == 0)
        #expect(planned.updatedAt == originalDate)
    }

    private func folder(
        _ name: String,
        position: Int,
        parentID: UUID? = nil
    ) -> RoutineFolderModel {
        RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: name,
            position: position,
            parentID: parentID
        )
    }

    private func routine(
        _ name: String,
        folderID: UUID?,
        position: Int
    ) -> RoutineModel {
        RoutineModel(
            userID: ForgeFitDemo.userID,
            name: name,
            folderID: folderID,
            position: position
        )
    }
}
