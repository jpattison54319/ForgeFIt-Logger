import Foundation
import SwiftData

/// Archive/restore mutations for routines and routine folders.
///
/// Archiving is hide-not-delete: rows keep their `parentID`/`folderID` links so
/// a restored folder rebuilds its cycle intact. Archiving a folder stamps its
/// whole live subtree with ONE shared timestamp; restoring the folder brings
/// back exactly the rows carrying that stamp — anything the user had archived
/// separately beforehand keeps its own stamp and stays archived, because
/// hiding it was a deliberate, earlier act.
///
/// Restoring a nested item on its own re-parents it to its nearest
/// non-archived ancestor (top level if none) so a restore never lands
/// somewhere invisible, and appends it after its live siblings so it never
/// collides with reordering done while it was away.
@MainActor
public enum RoutineArchiver {

    // MARK: Archive

    public static func archive(_ routine: RoutineModel, at stamp: Date = Date()) {
        routine.archivedAt = stamp
        routine.updatedAt = stamp
    }

    /// Stamps the folder and every live descendant (child folders + routines)
    /// with the same timestamp — the "archived as a unit" identity.
    public static func archive(_ folder: RoutineFolderModel, in context: ModelContext, at stamp: Date = Date()) throws {
        let folders = try context.fetch(FetchDescriptor<RoutineFolderModel>())
        let routines = try context.fetch(FetchDescriptor<RoutineModel>())

        var unitFolderIDs: Set<UUID> = [folder.id]
        folder.archivedAt = stamp
        folder.updatedAt = stamp
        for child in folders where child.parentID == folder.id && child.deletedAt == nil && child.archivedAt == nil {
            child.archivedAt = stamp
            child.updatedAt = stamp
            unitFolderIDs.insert(child.id)
        }
        for routine in routines {
            guard routine.deletedAt == nil, routine.archivedAt == nil,
                  let folderID = routine.folderID, unitFolderIDs.contains(folderID) else { continue }
            routine.archivedAt = stamp
            routine.updatedAt = stamp
        }
    }

    // MARK: Restore

    public static func restore(_ routine: RoutineModel, in context: ModelContext) throws {
        let folders = try context.fetch(FetchDescriptor<RoutineFolderModel>())
        let routines = try context.fetch(FetchDescriptor<RoutineModel>())
        let now = Date()

        routine.archivedAt = nil
        routine.folderID = nearestLiveAncestor(startingAt: routine.folderID, in: folders)
        routine.position = nextPosition(
            over: routines.filter { $0.deletedAt == nil && $0.archivedAt == nil && $0.folderID == routine.folderID && $0.id != routine.id }
        )
        routine.updatedAt = now
    }

    /// Restores the folder plus every row stamped with it as a unit, then
    /// re-homes the folder itself if its own parent is still archived.
    public static func restore(_ folder: RoutineFolderModel, in context: ModelContext) throws {
        let folders = try context.fetch(FetchDescriptor<RoutineFolderModel>())
        let routines = try context.fetch(FetchDescriptor<RoutineModel>())
        let now = Date()
        let stamp = folder.archivedAt

        folder.archivedAt = nil
        var restoredFolderIDs: Set<UUID> = [folder.id]
        if let stamp {
            for child in folders where child.parentID == folder.id && child.deletedAt == nil && child.archivedAt == stamp {
                child.archivedAt = nil
                child.updatedAt = now
                restoredFolderIDs.insert(child.id)
            }
            for routine in routines {
                guard routine.deletedAt == nil, routine.archivedAt == stamp,
                      let folderID = routine.folderID, restoredFolderIDs.contains(folderID) else { continue }
                routine.archivedAt = nil
                routine.updatedAt = now
            }
        }

        folder.parentID = nearestLiveAncestor(startingAt: folder.parentID, in: folders)
        folder.position = nextPosition(
            over: folders.filter { $0.deletedAt == nil && $0.archivedAt == nil && $0.parentID == folder.parentID && $0.id != folder.id }
        )
        folder.updatedAt = now
    }

    // MARK: Helpers

    /// Walks `parentID`/`folderID` links upward past archived (or deleted)
    /// folders and returns the first live folder id — nil means top level.
    /// Folders nest one level today, but the walk is written as a chain (with
    /// a visited-set guard) so deeper nesting or sync-corrupted cycles can't
    /// strand or loop it.
    static func nearestLiveAncestor(startingAt id: UUID?, in folders: [RoutineFolderModel]) -> UUID? {
        var currentID = id
        var visited: Set<UUID> = []
        while let candidateID = currentID, visited.insert(candidateID).inserted {
            guard let candidate = folders.first(where: { $0.id == candidateID }) else { return nil }
            if candidate.deletedAt == nil && candidate.archivedAt == nil { return candidate.id }
            currentID = candidate.parentID
        }
        return nil
    }

    private static func nextPosition(over siblings: [some PositionedRow]) -> Int {
        (siblings.map(\.position).max() ?? -1) + 1
    }
}

/// Lets `nextPosition` run over routines and folders alike.
private protocol PositionedRow {
    var position: Int { get }
}

extension RoutineModel: PositionedRow {}
extension RoutineFolderModel: PositionedRow {}
