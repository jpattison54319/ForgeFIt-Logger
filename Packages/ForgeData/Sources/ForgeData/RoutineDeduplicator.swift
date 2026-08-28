import Foundation
import SwiftData

/// Collapses accidental duplicate `RoutineModel` and `RoutineFolderModel`
/// rows that arise from the plan-store split migration and subsequent
/// CloudKit sync.
///
/// `PlanStoreSplitMigration` copies routines and folders into `plan.store`
/// preserving their `id`, but CloudKit re-merges pre-split records back on top
/// of the migrated copies. CloudKit cannot enforce a unique constraint on `id`,
/// so the same logical entity can appear as several SwiftData rows. Historically
/// some callers tolerated this with "first wins" folds, which could expose the
/// wrong physical row and still allowed the duplicates to accumulate.
///
/// This runs on the app's private plan-maintenance context and keeps a single
/// deterministic survivor per `id`, hard-deleting the rest. Routine survivor
/// selection is graph-aware: an exercise/set/block edit must beat a later
/// folder move, because deleting the authored graph would cascade-delete the
/// user's current exercises and sets. Organization fields are reconciled onto
/// that survivor separately before the duplicate graph is removed.
///
/// All ranking inputs are CloudKit-synced, so devices converge on the same
/// survivor. A tombstone wins only when its deletion happened after the newest
/// authored graph; an old CloudKit tombstone must not erase a later edit.
public enum RoutineDeduplicator {

    public struct Summary: Equatable, Sendable {
        public var duplicateRoutinesDeleted: Int
        public var duplicateFoldersDeleted: Int

        public var isEmpty: Bool {
            duplicateRoutinesDeleted == 0 && duplicateFoldersDeleted == 0
        }
    }

    /// Removes duplicate-`id` routine and folder rows, keeping one
    /// deterministic survivor each. Saves only when something was deleted.
    @discardableResult
    public static func removeDuplicates(in context: ModelContext) throws -> Summary {
        let routinesDeleted = try collapseRoutines(
            try context.fetch(FetchDescriptor<RoutineModel>()),
            in: context
        )
        let foldersDeleted = try collapse(
            try context.fetch(FetchDescriptor<RoutineFolderModel>()),
            id: { $0.id },
            prefers: folderPrefers,
            in: context
        )

        let summary = Summary(
            duplicateRoutinesDeleted: routinesDeleted,
            duplicateFoldersDeleted: foldersDeleted
        )
        if !summary.isEmpty {
            try context.save()
        }
        return summary
    }

    /// Returns one deterministic physical row for each logical routine ID.
    /// UI and editing surfaces use this immediately while the background
    /// maintenance context removes the redundant CloudKit rows.
    public static func canonicalRoutines(_ rows: [RoutineModel]) -> [RoutineModel] {
        var groups: [UUID: [RoutineModel]] = [:]
        var orderedIDs: [UUID] = []
        for row in rows {
            if groups[row.id] == nil { orderedIDs.append(row.id) }
            groups[row.id, default: []].append(row)
        }
        return orderedIDs.compactMap { id in
            groups[id]?.reduce(nil as RoutineModel?) { incumbent, candidate in
                guard let incumbent else { return candidate }
                return routinePrefers(candidate, over: incumbent) ? candidate : incumbent
            }
        }
    }

    private static func collapseRoutines(
        _ rows: [RoutineModel],
        in context: ModelContext
    ) throws -> Int {
        let groups = Dictionary(grouping: rows, by: \RoutineModel.id)
        var deleted = 0

        for group in groups.values where group.count > 1 {
            try Task.checkCancellation()
            guard let survivor = canonicalRoutines(group).first else { continue }

            // Folder placement and archive state are organization, not routine
            // authorship. Preserve the latest live organization operation on
            // the freshest authored graph instead of using it to pick a graph.
            if survivor.deletedAt == nil,
               let organization = group
                .filter({ $0.deletedAt == nil })
                .max(by: organizationIsOlder) {
                survivor.folder = organization.folder
                survivor.folderID = organization.folderID
                survivor.position = organization.position
                survivor.archivedAt = organization.archivedAt
            }

            for row in group where row !== survivor {
                context.delete(row)
                deleted += 1
            }
        }
        return deleted
    }

    private static func collapse<Model: PersistentModel>(
        _ rows: [Model],
        id: (Model) -> UUID,
        prefers: (Model, Model) -> Bool,
        in context: ModelContext
    ) throws -> Int {
        var survivors: [UUID: Model] = [:]
        var doomed: [Model] = []

        for row in rows {
            try Task.checkCancellation()
            let key = id(row)
            guard let incumbent = survivors[key] else {
                survivors[key] = row
                continue
            }
            if prefers(row, incumbent) {
                doomed.append(incumbent)
                survivors[key] = row
            } else {
                doomed.append(row)
            }
        }

        for row in doomed {
            context.delete(row)
        }
        return doomed.count
    }

    /// Authored graph time ranks ahead of the parent row's metadata timestamp.
    /// Routine organization also touches the parent timestamp, so reversing
    /// those signals can select a stale graph and cascade-delete the edited one.
    private static func routinePrefers(
        _ a: RoutineModel,
        over b: RoutineModel
    ) -> Bool {
        let aAuthoredAt = authoredGraphUpdatedAt(a)
        let bAuthoredAt = authoredGraphUpdatedAt(b)
        let aIntentAt = a.deletedAt ?? aAuthoredAt
        let bIntentAt = b.deletedAt ?? bAuthoredAt
        if aIntentAt != bIntentAt { return aIntentAt > bIntentAt }
        if (a.deletedAt == nil) != (b.deletedAt == nil) {
            return a.deletedAt != nil
        }
        if aAuthoredAt != bAuthoredAt { return aAuthoredAt > bAuthoredAt }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return stableOrder(a, b)
    }

    /// Child authoring timestamps are the durable content clock already present
    /// in the CloudKit schema. Empty routines fall back to their parent clock.
    private static func authoredGraphUpdatedAt(_ routine: RoutineModel) -> Date {
        let latestExercise = routine.exercises.map(\.updatedAt).max()
        let latestBlock = routine.blocks.map(\.updatedAt).max()
        return [latestExercise, latestBlock].compactMap { $0 }.max()
            ?? routine.updatedAt
    }

    private static func organizationIsOlder(_ a: RoutineModel, _ b: RoutineModel) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return !stableOrder(a, b)
    }

    /// Same survivor logic as `routinePrefers`: soft-deleted wins over live,
    /// then most recently updated, then most recently created, then stable order.
    private static func folderPrefers(
        _ a: RoutineFolderModel,
        over b: RoutineFolderModel
    ) -> Bool {
        if (a.deletedAt == nil) != (b.deletedAt == nil) {
            return a.deletedAt != nil
        }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return stableOrder(a, b)
    }

    private static func stableOrder<Model: PersistentModel>(_ a: Model, _ b: Model) -> Bool {
        String(describing: a.persistentModelID) < String(describing: b.persistentModelID)
    }
}
