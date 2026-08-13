import ForgeData
import Foundation

/// Applies one validated organizer draft to the existing CloudKit-backed plan
/// models. The caller owns the single ModelContext save and failure recovery.
@MainActor
enum RoutineOrganizerPersistence {
    enum PersistenceError: LocalizedError {
        case libraryChanged
        case invalidHierarchy

        var errorDescription: String? {
            switch self {
            case .libraryChanged:
                "Your routine library changed while Organize was open. Close it and try again."
            case .invalidHierarchy:
                "That folder arrangement is no longer valid. Review the hierarchy and try again."
            }
        }
    }

    static func apply(
        _ draft: RoutineOrganizerDraft,
        folders: [RoutineFolderModel],
        routines: [RoutineModel],
        now: Date = .now
    ) throws {
        guard Set(folders.map(\.id)) == Set(draft.allFolderIDs),
              Set(routines.map(\.id)) == Set(draft.allRoutineIDs) else {
            throw PersistenceError.libraryChanged
        }

        var foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var routinesByID = Dictionary(uniqueKeysWithValues: routines.map { ($0.id, $0) })
        var placedFolderIDs: Set<UUID> = []

        for (position, folderID) in draft.rootFolderIDs.enumerated() {
            guard let folder = foldersByID.removeValue(forKey: folderID) else {
                throw PersistenceError.libraryChanged
            }
            update(folder, parentID: nil, position: position, now: now)
            placedFolderIDs.insert(folderID)

            for (childPosition, childID) in draft.children(of: folderID).enumerated() {
                guard draft.children(of: childID).isEmpty,
                      let child = foldersByID.removeValue(forKey: childID) else {
                    throw PersistenceError.invalidHierarchy
                }
                update(child, parentID: folderID, position: childPosition, now: now)
                placedFolderIDs.insert(childID)
            }
        }
        guard foldersByID.isEmpty, placedFolderIDs.count == folders.count else {
            throw PersistenceError.invalidHierarchy
        }

        let allFoldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        for folderID in draft.allFolderIDs {
            let oldParentID = draft.originalParentID(of: folderID)
            let newParentID = draft.parentID(of: folderID)
            guard oldParentID != newParentID else { continue }
            for parentID in [oldParentID, newParentID].compactMap({ $0 }) {
                allFoldersByID[parentID]?.updatedAt = now
            }
        }

        for destination in draft.routineDestinations {
            let routineIDs = draft.routines(in: destination).flatMap(\.routineIDs)
            for (position, routineID) in routineIDs.enumerated() {
                guard let routine = routinesByID.removeValue(forKey: routineID) else {
                    throw PersistenceError.libraryChanged
                }
                update(
                    routine,
                    folderID: destination.folderID,
                    position: position,
                    now: now
                )
            }
        }
        guard routinesByID.isEmpty else {
            throw PersistenceError.invalidHierarchy
        }
    }

    static func restoreOriginal(
        _ draft: RoutineOrganizerDraft,
        folders: [RoutineFolderModel],
        routines: [RoutineModel]
    ) {
        let originalDraft = draft.original
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        for (position, folderID) in originalDraft.rootFolderIDs.enumerated() {
            guard let folder = foldersByID[folderID] else { continue }
            folder.parentID = nil
            folder.position = position
            if let updatedAt = draft.originalFolderUpdatedAt[folderID] {
                folder.updatedAt = updatedAt
            }
            for (childPosition, childID) in originalDraft.childFolderIDs[folderID, default: []].enumerated() {
                guard let child = foldersByID[childID] else { continue }
                child.parentID = folderID
                child.position = childPosition
                if let updatedAt = draft.originalFolderUpdatedAt[childID] {
                    child.updatedAt = updatedAt
                }
            }
        }

        for (destination, items) in originalDraft.routineItems {
            for (position, routineID) in items.flatMap(\.routineIDs).enumerated() {
                guard let routine = routines.first(where: { $0.id == routineID }) else { continue }
                routine.folderID = destination.folderID
                routine.position = position
                if let updatedAt = draft.originalRoutineUpdatedAt[routine.id] {
                    routine.updatedAt = updatedAt
                }
            }
        }
    }

    private static func update(
        _ folder: RoutineFolderModel,
        parentID: UUID?,
        position: Int,
        now: Date
    ) {
        guard folder.parentID != parentID || folder.position != position else { return }
        folder.parentID = parentID
        folder.position = position
        folder.updatedAt = now
    }

    private static func update(
        _ routine: RoutineModel,
        folderID: UUID?,
        position: Int,
        now: Date
    ) {
        guard routine.folderID != folderID || routine.position != position else { return }
        routine.folderID = folderID
        routine.position = position
        routine.updatedAt = now
    }
}
