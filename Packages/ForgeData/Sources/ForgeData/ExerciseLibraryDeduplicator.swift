import Foundation
import SwiftData

/// Collapses accidental duplicate rows in the exercise library.
///
/// SwiftData backed by CloudKit cannot enforce unique constraints, so a
/// re-seed race or a sync round-trip can leave several `ExerciseLibraryModel`
/// (or `ExerciseAliasModel`) rows sharing one logical `id`. The rest of the app
/// tolerates this with "first wins" folds, but the rows still accumulate. This
/// runs at launch (after `ExerciseSeedRepository.seedGlobalLibrary`) and keeps a
/// single deterministic survivor per `id`, hard-deleting the others.
///
/// The delete is a real `ModelContext.delete`, so it propagates to other
/// devices through CloudKit. Survivor selection depends only on synced
/// attributes (`userModified`, `updatedAt`, `createdAt`), so two devices running
/// the cleanup concurrently converge on the same survivor instead of racing to
/// delete each other's copy. The pass is idempotent — once a group is collapsed
/// to one row there is nothing left to delete — and self-healing: because it
/// runs *after* the seed, if a group were ever emptied the next launch's seed
/// re-inserts the missing built-in.
@MainActor
public enum ExerciseLibraryDeduplicator {

    public struct Summary: Equatable, Sendable {
        public var duplicateExercisesDeleted: Int
        public var duplicateAliasesDeleted: Int

        public var isEmpty: Bool {
            duplicateExercisesDeleted == 0 && duplicateAliasesDeleted == 0
        }
    }

    /// Removes duplicate-`id` exercise-library and alias rows, keeping one
    /// deterministic survivor each. Saves only when something was deleted.
    @discardableResult
    public static func removeDuplicates(in context: ModelContext) throws -> Summary {
        let exercisesDeleted = collapse(
            try context.fetch(FetchDescriptor<ExerciseLibraryModel>()),
            id: { $0.id },
            prefers: exercisePrefers,
            in: context
        )
        let aliasesDeleted = collapse(
            try context.fetch(FetchDescriptor<ExerciseAliasModel>()),
            id: { $0.id },
            prefers: aliasPrefers,
            in: context
        )

        let summary = Summary(
            duplicateExercisesDeleted: exercisesDeleted,
            duplicateAliasesDeleted: aliasesDeleted
        )
        if !summary.isEmpty {
            try context.save()
        }
        return summary
    }

    /// Folds `rows` down to one survivor per `id`, deleting the rest. Returns
    /// the number deleted. `prefers(a, b)` returns true when `a` should survive
    /// over `b`; it must be a total, deterministic order so the survivor is
    /// stable regardless of fetch order or which device runs the pass.
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

    /// A user-edited copy wins; otherwise the most recently updated, then most
    /// recently created. A fully-tied pair falls back to a stable per-object
    /// order so exactly one row survives.
    private static func exercisePrefers(
        _ a: ExerciseLibraryModel,
        over b: ExerciseLibraryModel
    ) -> Bool {
        if a.userModified != b.userModified { return a.userModified }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return stableOrder(a, b)
    }

    /// Aliases carry no edit/update metadata, so the most recently created copy
    /// wins, with a stable fallback for a tie.
    private static func aliasPrefers(
        _ a: ExerciseAliasModel,
        over b: ExerciseAliasModel
    ) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return stableOrder(a, b)
    }

    private static func stableOrder<Model: PersistentModel>(_ a: Model, _ b: Model) -> Bool {
        String(describing: a.persistentModelID) < String(describing: b.persistentModelID)
    }
}
