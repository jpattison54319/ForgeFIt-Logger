import ForgeData
import Foundation

/// Computes and persists exact top-level folder insertion. Unnesting is part
/// of the same mutation as ordering so a drop can never briefly fall back to
/// an ambiguous position shared with its former parent.
enum RoutineFolderRootOrdering {
    static func destinationIDs(
        moving folderID: UUID,
        before targetID: UUID?,
        currentRootIDs: [UUID]
    ) -> [UUID]? {
        guard targetID != folderID else { return nil }

        var destination = currentRootIDs.filter { $0 != folderID }
        let insertionIndex: Int
        if let targetID {
            guard let targetIndex = destination.firstIndex(of: targetID) else { return nil }
            insertionIndex = targetIndex
        } else {
            insertionIndex = destination.endIndex
        }
        destination.insert(folderID, at: insertionIndex)
        return destination
    }

    @discardableResult
    static func move(
        _ folder: RoutineFolderModel,
        before targetID: UUID?,
        currentRoots: [RoutineFolderModel],
        allFolders: [RoutineFolderModel],
        at timestamp: Date = .now
    ) -> Bool {
        let currentIDs = currentRoots.map(\.id)
        guard let destinationIDs = destinationIDs(
            moving: folder.id,
            before: targetID,
            currentRootIDs: currentIDs
        ) else { return false }

        let membershipChanged = folder.parentID != nil
        guard membershipChanged || destinationIDs != currentIDs else { return false }

        let previousParentID = folder.parentID
        var foldersByID = Dictionary(uniqueKeysWithValues: currentRoots.map { ($0.id, $0) })
        foldersByID[folder.id] = folder

        folder.parentID = nil
        for (position, id) in destinationIDs.enumerated() {
            guard let root = foldersByID[id] else { continue }
            root.position = position
            root.updatedAt = timestamp
        }

        if let previousParentID,
           let previousParent = allFolders.first(where: { $0.id == previousParentID }) {
            previousParent.updatedAt = timestamp
        }
        return true
    }
}
