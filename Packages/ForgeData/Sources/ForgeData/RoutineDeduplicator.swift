import Foundation
import SwiftData

/// Collapses accidental duplicate `RoutineModel` and `RoutineFolderModel`
/// rows that arise from the plan-store split migration and subsequent
/// CloudKit sync.
///
/// `PlanStoreSplitMigration` copies routines and folders into `plan.store`
/// preserving their `id`, but CloudKit re-merges pre-split records back on top
/// of the migrated copies. CloudKit cannot enforce a unique constraint on `id`,
/// so the same logical entity can appear as several SwiftData rows. The rest of
/// the app tolerates this with "first wins" folds, but the rows still accumulate.
///
/// This runs at launch (after `ExerciseLibraryDeduplicator`) and keeps a single
/// deterministic survivor per `id`, hard-deleting the rest. The cascade
/// `@Relationship(deleteRule: .cascade)` on `RoutineModel.exercises` and
/// `RoutineExerciseModel.sets` ensures child rows collapse automatically — no
/// separate child dedupe pass is needed. Folders nest via `parentID` (a UUID
/// reference, not a `@Relationship`), so collapsing a parent folder leaves the
/// child's `parentID` still pointing to the surviving parent's `id`.
///
/// Survivor selection depends only on CloudKit-synced attributes
/// (`deletedAt`, `updatedAt`, `createdAt`), so two devices running the cleanup
/// concurrently converge on the same survivor instead of racing to delete each
/// other's copy. A soft-deleted row (`deletedAt != nil`) wins over a live one so
/// the tombstone propagates and the user's deletion intent is preserved.
@MainActor
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
        let routinesDeleted = collapse(
            try context.fetch(FetchDescriptor<RoutineModel>()),
            id: { $0.id },
            prefers: routinePrefers,
            in: context
        )
        let foldersDeleted = collapse(
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

    private static func collapse<Model: PersistentModel>(
        _ rows: [Model],
        id: (Model) -> UUID,
        prefers: (Model, Model) -> Bool,
        in context: ModelContext
    ) -> Int {
        var survivors: [UUID: Model] = [:]
        var doomed: [Model] = []

        for row in rows {
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

    /// A soft-deleted routine (`deletedAt != nil`) wins over a live one so the
    /// tombstone propagates. Among same soft-delete status: most recently
    /// updated, then most recently created. A fully-tied pair falls back to a
    /// stable per-object order so exactly one row survives.
    private static func routinePrefers(
        _ a: RoutineModel,
        over b: RoutineModel
    ) -> Bool {
        if (a.deletedAt == nil) != (b.deletedAt == nil) {
            return a.deletedAt != nil
        }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return stableOrder(a, b)
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
