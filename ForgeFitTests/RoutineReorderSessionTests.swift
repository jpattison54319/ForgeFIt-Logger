import Foundation
import ForgeData
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
@Suite("Routine reorder session")
struct RoutineReorderSessionTests {
    @Test("A routine snaps through exact positions inside one folder")
    func reordersWithinFolder() throws {
        let folderID = UUID()
        let ids = (0..<4).map { _ in UUID() }
        let session = try #require(RoutineReorderSession(
            draggedItemID: ids[0],
            orders: [.folder(folderID): ids.map(item)]
        ))

        let firstMove = session.move(to: .folder(folderID), placement: .after(ids[1]))
        #expect(firstMove)
        #expect(session.items(in: .folder(folderID)).map(\.id) == [ids[1], ids[0], ids[2], ids[3]])
        let secondMove = session.move(to: .folder(folderID), placement: .after(ids[3]))
        #expect(secondMove)
        #expect(session.items(in: .folder(folderID)).map(\.id) == [ids[1], ids[2], ids[3], ids[0]])
        #expect(session.changedDestinations == [.folder(folderID)])
    }

    @Test("A routine inserts between exact rows in another folder")
    func insertsAcrossFolders() throws {
        let sourceID = UUID()
        let destinationID = UUID()
        let source = (0..<2).map { _ in UUID() }
        let destination = (0..<3).map { _ in UUID() }
        let session = try #require(RoutineReorderSession(
            draggedItemID: source[1],
            orders: [
                .folder(sourceID): source.map(item),
                .folder(destinationID): destination.map(item),
                .ungrouped: []
            ]
        ))

        let didMove = session.move(to: .folder(destinationID), placement: .before(destination[1]))
        #expect(didMove)
        #expect(session.items(in: .folder(sourceID)).map(\.id) == [source[0]])
        #expect(session.items(in: .folder(destinationID)).map(\.id) == [
            destination[0], source[1], destination[1], destination[2]
        ])
        #expect(session.destination == .folder(destinationID))
        #expect(session.changedDestinations == [.folder(sourceID), .folder(destinationID)])
    }

    @Test("Ungrouped supports exact insertion rather than append only")
    func insertsInsideUngrouped() throws {
        let folderID = UUID()
        let draggedID = UUID()
        let ungrouped = (0..<3).map { _ in UUID() }
        let session = try #require(RoutineReorderSession(
            draggedItemID: draggedID,
            orders: [
                .folder(folderID): [item(draggedID)],
                .ungrouped: ungrouped.map(item)
            ]
        ))

        let didMove = session.move(to: .ungrouped, placement: .after(ungrouped[0]))
        #expect(didMove)
        #expect(session.items(in: .ungrouped).map(\.id) == [
            ungrouped[0], draggedID, ungrouped[1], ungrouped[2]
        ])
        #expect(session.routineIDs(in: .folder(folderID)).isEmpty)
    }

    @Test("An alternating pair moves as one visible routine slot")
    func movesAlternatingPairTogether() throws {
        let sourceID = UUID()
        let destinationID = UUID()
        let ownerID = UUID()
        let partnerID = UUID()
        let targetID = UUID()
        let pair = RoutineReorderSession.Item(
            id: ownerID,
            routineIDs: [ownerID, partnerID]
        )
        let session = try #require(RoutineReorderSession(
            draggedItemID: ownerID,
            orders: [
                .folder(sourceID): [pair],
                .folder(destinationID): [item(targetID)]
            ]
        ))

        let didMove = session.move(to: .folder(destinationID), placement: .before(targetID))
        #expect(didMove)
        #expect(session.items(in: .folder(destinationID)).map(\.id) == [ownerID, targetID])
        #expect(session.routineIDs(in: .folder(destinationID)) == [ownerID, partnerID, targetID])
        #expect(session.containsRoutine(partnerID))
    }

    @Test("Dropping on the dragged card is a no-op")
    func ignoresSelfPlacement() throws {
        let id = UUID()
        let session = try #require(RoutineReorderSession(
            draggedItemID: id,
            orders: [.ungrouped: [item(id)]]
        ))

        let didMove = session.move(to: .ungrouped, placement: .before(id))
        #expect(!didMove)
        #expect(!session.hasChanges)
    }

    @Test("The flat stack crosses a folder boundary without moving headers")
    func flatStackCrossesFolderBoundary() throws {
        let folderID = UUID()
        let draggedID = UUID()
        let ungroupedLastID = UUID()
        let folderFirstID = UUID()
        let folderLastID = UUID()
        let session = try #require(RoutineReorderSession(
            draggedItemID: draggedID,
            fingerGlobalY: 200,
            sections: [
                .init(
                    destination: .ungrouped,
                    title: "Ungrouped",
                    items: [item(draggedID), item(ungroupedLastID)]
                ),
                .init(
                    destination: .folder(folderID),
                    title: "Folder",
                    items: [item(folderFirstID), item(folderLastID)]
                ),
            ]
        ))
        let targetIndex = try #require(session.entries.firstIndex {
            $0.id == .item(folderFirstID)
        })

        #expect(session.moveHeld(toFlatIndex: targetIndex))
        #expect(session.items(in: .ungrouped).map(\.id) == [ungroupedLastID])
        #expect(session.items(in: .folder(folderID)).map(\.id) == [
            folderFirstID, draggedID, folderLastID,
        ])
        #expect(session.entries.compactMap { entry -> RoutineReorderSession.Destination? in
            guard case .section(let destination, _) = entry else { return nil }
            return destination
        } == [.ungrouped, .folder(folderID)])
    }

    @Test("A folder header is an exact first-position target")
    func folderHeaderTargetsBeginningIncludingWhenEmpty() throws {
        let sourceID = UUID()
        let populatedID = UUID()
        let emptyID = UUID()
        let draggedID = UUID()
        let targetID = UUID()
        let session = try #require(RoutineReorderSession(
            draggedItemID: draggedID,
            fingerGlobalY: 0,
            sections: [
                .init(destination: .folder(sourceID), title: "Source", items: [item(draggedID)]),
                .init(destination: .folder(populatedID), title: "Populated", items: [item(targetID)]),
                .init(destination: .folder(emptyID), title: "Empty", items: []),
            ]
        ))

        #expect(session.moveHeldToBeginning(of: .folder(populatedID)))
        #expect(session.items(in: .folder(populatedID)).map(\.id) == [draggedID, targetID])
        #expect(session.moveHeldToBeginning(of: .folder(emptyID)))
        #expect(session.items(in: .folder(emptyID)).map(\.id) == [draggedID])
        #expect(session.items(in: .folder(populatedID)).map(\.id) == [targetID])
    }

    @Test("Cross-folder order and membership persist together")
    func persistsCrossFolderPlacement() throws {
        let (container, context) = try TestStore.make()
        let sourceFolder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Source")
        let destinationFolder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Destination")
        let sourceFirst = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Source First",
            folderID: sourceFolder.id,
            position: 0
        )
        let dragged = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Dragged",
            folderID: sourceFolder.id,
            position: 1
        )
        let destinationFirst = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Destination First",
            folderID: destinationFolder.id,
            position: 0
        )
        let destinationLast = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Destination Last",
            folderID: destinationFolder.id,
            position: 1
        )
        [sourceFolder, destinationFolder].forEach(context.insert)
        [sourceFirst, dragged, destinationFirst, destinationLast].forEach(context.insert)
        try context.save()

        let session = try #require(RoutineReorderSession(
            draggedItemID: dragged.id,
            orders: [
                .folder(sourceFolder.id): [item(sourceFirst.id), item(dragged.id)],
                .folder(destinationFolder.id): [item(destinationFirst.id), item(destinationLast.id)]
            ]
        ))
        let didMove = session.move(
            to: .folder(destinationFolder.id),
            placement: .before(destinationLast.id)
        )
        #expect(didMove)
        #expect(RoutineReorderPersistence.apply(session, to: [
            sourceFirst, dragged, destinationFirst, destinationLast
        ]))
        try context.save()

        let verificationContext = ModelContext(container)
        let persisted = try verificationContext.fetch(FetchDescriptor<RoutineModel>())
        let persistedSource = persisted
            .filter { $0.folderID == sourceFolder.id }
            .sorted { $0.position < $1.position }
        let persistedDestination = persisted
            .filter { $0.folderID == destinationFolder.id }
            .sorted { $0.position < $1.position }

        #expect(persistedSource.map(\.name) == ["Source First"])
        #expect(persistedSource.map(\.position) == [0])
        #expect(persistedDestination.map(\.name) == [
            "Destination First", "Dragged", "Destination Last"
        ])
        #expect(persistedDestination.map(\.position) == [0, 1, 2])
    }

    private func item(_ id: UUID) -> RoutineReorderSession.Item {
        RoutineReorderSession.Item(id: id, routineIDs: [id])
    }
}
