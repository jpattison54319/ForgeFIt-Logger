import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
@Suite("Routine folder root ordering")
struct RoutineFolderRootOrderingTests {
    @Test("A child dropped above its parent becomes the first root folder")
    func unnestsBeforeParent() {
        let parent = folder("Parent", position: 0)
        let child = folder("Child", position: 0, parentID: parent.id)

        let moved = RoutineFolderRootOrdering.move(
            child,
            before: parent.id,
            currentRoots: [parent],
            allFolders: [parent, child]
        )

        #expect(moved)
        #expect(child.parentID == nil)
        #expect(child.position == 0)
        #expect(parent.position == 1)
    }

    @Test("A root folder inserts before the exact target")
    func reordersExistingRoots() {
        let first = folder("First", position: 0)
        let second = folder("Second", position: 1)
        let third = folder("Third", position: 2)

        let moved = RoutineFolderRootOrdering.move(
            third,
            before: first.id,
            currentRoots: [first, second, third],
            allFolders: [first, second, third]
        )

        #expect(moved)
        #expect(third.position == 0)
        #expect(first.position == 1)
        #expect(second.position == 2)
    }

    @Test("A root-canvas drop unnests at the end")
    func unnestsAtEnd() {
        let parent = folder("Parent", position: 0)
        let sibling = folder("Sibling", position: 1)
        let child = folder("Child", position: 0, parentID: parent.id)

        let moved = RoutineFolderRootOrdering.move(
            child,
            before: nil,
            currentRoots: [parent, sibling],
            allFolders: [parent, sibling, child]
        )

        #expect(moved)
        #expect(parent.position == 0)
        #expect(sibling.position == 1)
        #expect(child.position == 2)
    }

    @Test("Dropping into the current slot is a no-op")
    func ignoresCurrentSlot() {
        let first = folder("First", position: 0)
        let second = folder("Second", position: 1)

        let moved = RoutineFolderRootOrdering.move(
            first,
            before: second.id,
            currentRoots: [first, second],
            allFolders: [first, second]
        )

        #expect(!moved)
        #expect(first.position == 0)
        #expect(second.position == 1)
    }

    private func folder(
        _ name: String,
        position: Int,
        parentID: UUID? = nil
    ) -> RoutineFolderModel {
        RoutineFolderModel(
            userID: UUID(),
            name: name,
            position: position,
            parentID: parentID
        )
    }
}
