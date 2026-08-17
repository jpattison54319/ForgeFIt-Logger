import ForgeData
import Foundation
import SwiftData

/// One stable, isolated routine creation attempt. The graph stays outside the
/// shared UI context until its save succeeds, so a failed placeholder or deep
/// copy cannot appear in the library or ride along on a later autosave.
@MainActor
final class RoutineCreationAttempt {
    enum PersistenceError: LocalizedError {
        case committedRoutineUnavailable

        var errorDescription: String? {
            "The routine was saved, but ForgeFit couldn't reopen it. Try again."
        }
    }

    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    let id: UUID
    private let persistenceContext: ModelContext
    private let routine: RoutineModel

    init(
        id: UUID = UUID(),
        name: String,
        folderID: UUID?,
        position: Int,
        in sourceContext: ModelContext,
        now: Date = .now
    ) {
        self.id = id
        persistenceContext = ModelContext(sourceContext.container)
        persistenceContext.autosaveEnabled = false
        routine = RoutineModel(
            id: id,
            userID: ForgeFitDemo.userID,
            name: name,
            folderID: folderID,
            position: position,
            createdAt: now,
            updatedAt: now
        )
        persistenceContext.insert(routine)
    }

    init(
        duplicating source: RoutineModel,
        position: Int,
        in sourceContext: ModelContext
    ) {
        persistenceContext = ModelContext(sourceContext.container)
        persistenceContext.autosaveEnabled = false
        routine = RoutineDuplicator.duplicate(
            source,
            position: position,
            in: persistenceContext
        )
        id = routine.id
    }

    @discardableResult
    func commit(
        into sourceContext: ModelContext,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor (RoutineModel) -> Void
    ) -> Bool {
        let routineID = id
        var committedRoutine: RoutineModel?
        return (saveCenter ?? .shared).perform({ [persistenceContext] in
            try save(persistenceContext)
            committedRoutine = try sourceContext.fetch(
                FetchDescriptor<RoutineModel>(predicate: #Predicate { $0.id == routineID })
            ).first
            guard committedRoutine != nil else {
                throw PersistenceError.committedRoutineUnavailable
            }
        }, onSuccess: {
            if let committedRoutine { onCommit(committedRoutine) }
        })
    }
}

/// Creates a folder and, when it is the first child of a mesocycle, moves the
/// parent's loose routines in the same isolated transaction.
@MainActor
final class RoutineFolderCreationAttempt {
    enum PersistenceError: LocalizedError {
        case parentUnavailable
        case committedFolderUnavailable

        var errorDescription: String? {
            switch self {
            case .parentUnavailable:
                "The parent folder is no longer available."
            case .committedFolderUnavailable:
                "The folder was saved, but ForgeFit couldn't reopen it. Try again."
            }
        }
    }

    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    let id: UUID
    private let name: String
    private let position: Int
    private let parentID: UUID?
    private let now: Date
    private let persistenceContext: ModelContext
    private var folder: RoutineFolderModel?

    init(
        id: UUID = UUID(),
        name: String,
        position: Int,
        parentID: UUID?,
        in sourceContext: ModelContext,
        now: Date = .now
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.parentID = parentID
        self.now = now
        persistenceContext = ModelContext(sourceContext.container)
        persistenceContext.autosaveEnabled = false
    }

    @discardableResult
    func commit(
        into sourceContext: ModelContext,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor (RoutineFolderModel) -> Void
    ) -> Bool {
        let folderID = id
        var committedFolder: RoutineFolderModel?
        return (saveCenter ?? .shared).perform({ [self] in
            if folder == nil {
                let folders = try persistenceContext.fetch(FetchDescriptor<RoutineFolderModel>())
                let routines = try persistenceContext.fetch(FetchDescriptor<RoutineModel>())
                let parent = parentID.flatMap { requestedParentID in
                    folders.first {
                        $0.id == requestedParentID
                            && $0.deletedAt == nil
                            && $0.archivedAt == nil
                    }
                }
                if parentID != nil, parent == nil {
                    throw PersistenceError.parentUnavailable
                }

                let pendingFolder = RoutineFolderModel(
                    id: folderID,
                    userID: ForgeFitDemo.userID,
                    name: name,
                    position: position,
                    parentID: parentID,
                    createdAt: now,
                    updatedAt: now
                )
                persistenceContext.insert(pendingFolder)
                if let parent {
                    let hasExistingChild = folders.contains {
                        $0.parentID == parent.id
                            && $0.deletedAt == nil
                            && $0.archivedAt == nil
                    }
                    if !hasExistingChild {
                        for routine in routines where
                            routine.folderID == parent.id
                                && routine.deletedAt == nil
                                && routine.archivedAt == nil {
                            routine.folderID = pendingFolder.id
                            routine.updatedAt = now
                        }
                    }
                    parent.updatedAt = now
                }
                folder = pendingFolder
            }

            try save(persistenceContext)
            committedFolder = try sourceContext.fetch(
                FetchDescriptor<RoutineFolderModel>(predicate: #Predicate { $0.id == folderID })
            ).first
            guard committedFolder != nil else {
                throw PersistenceError.committedFolderUnavailable
            }
        }, onSuccess: {
            if let committedFolder { onCommit(committedFolder) }
        })
    }
}

/// Soft-deletes one folder and moves its direct contents up one level in an
/// isolated transaction. AppStorage selection changes belong in `onCommit`.
@MainActor
final class RoutineFolderDeletionAttempt {
    enum PersistenceError: LocalizedError {
        case folderUnavailable

        var errorDescription: String? {
            "The folder is no longer available."
        }
    }

    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    private let folderID: UUID
    private let persistenceContext: ModelContext
    private let now: Date
    private var isPrepared = false

    init(
        folder: RoutineFolderModel,
        in sourceContext: ModelContext,
        now: Date = .now
    ) {
        folderID = folder.id
        persistenceContext = ModelContext(sourceContext.container)
        persistenceContext.autosaveEnabled = false
        self.now = now
    }

    @discardableResult
    func commit(
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor () -> Void
    ) -> Bool {
        (saveCenter ?? .shared).perform({ [self] in
            if !isPrepared {
                let folders = try persistenceContext.fetch(FetchDescriptor<RoutineFolderModel>())
                guard let folder = folders.first(where: {
                    $0.id == folderID && $0.deletedAt == nil
                }) else {
                    throw PersistenceError.folderUnavailable
                }
                let routines = try persistenceContext.fetch(FetchDescriptor<RoutineModel>())
                for routine in routines where
                    routine.folderID == folder.id
                        && routine.deletedAt == nil {
                    routine.folderID = folder.parentID
                    routine.updatedAt = now
                }
                for child in folders where
                    child.parentID == folder.id
                        && child.deletedAt == nil {
                    child.parentID = folder.parentID
                    child.updatedAt = now
                }
                folder.updatedAt = now
                folder.deletedAt = now
                isPrepared = true
            }
            try save(persistenceContext)
        }, onSuccess: onCommit)
    }
}
