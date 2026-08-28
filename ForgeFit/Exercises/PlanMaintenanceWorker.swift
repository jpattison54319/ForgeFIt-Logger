import ForgeData
import Foundation
import SwiftData

/// Versioned once because older builds cleaned the entire synced plan store on
/// every launch. A new version requests one background audit after an upgrade;
/// later CloudKit row-count changes schedule the same worker without touching
/// the version stamp.
enum PlanMaintenancePolicy {
    /// v2 re-audits routines with graph-aware survivor selection. v1 ranked
    /// parent `updatedAt`, which organization changes also touch.
    static let currentVersion = 2
    static let defaultsKey = "planMaintenance.dedupVersion"

    static func needsLaunchAudit(storedVersion: Int) -> Bool {
        storedVersion < currentVersion
    }
}

nonisolated struct PlanMaintenanceSummary: Sendable, Equatable {
    let duplicateExercisesDeleted: Int
    let duplicateAliasesDeleted: Int
    let duplicateRoutinesDeleted: Int
    let duplicateFoldersDeleted: Int

    var totalDeleted: Int {
        duplicateExercisesDeleted
            + duplicateAliasesDeleted
            + duplicateRoutinesDeleted
            + duplicateFoldersDeleted
    }
}

/// Audits CloudKit-backed plan rows on a private context. Only the value-only
/// summary crosses back to MainActor, so a 900-row exercise-library scan can
/// never pause scrolling.
nonisolated struct PlanMaintenanceWorker: Sendable {
    let modelContainer: ModelContainer

    func removeDuplicates() async throws -> PlanMaintenanceSummary {
        let container = modelContainer
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let exercises = try ExerciseLibraryDeduplicator.removeDuplicates(in: context)
            try Task.checkCancellation()
            let routines = try RoutineDeduplicator.removeDuplicates(in: context)
            return PlanMaintenanceSummary(
                duplicateExercisesDeleted: exercises.duplicateExercisesDeleted,
                duplicateAliasesDeleted: exercises.duplicateAliasesDeleted,
                duplicateRoutinesDeleted: routines.duplicateRoutinesDeleted,
                duplicateFoldersDeleted: routines.duplicateFoldersDeleted
            )
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    #if DEBUG
    func isExecutingOnMainThreadForTesting() async -> Bool {
        let container = modelContainer
        return await Task.detached(priority: .utility) {
            _ = ModelContext(container)
            return Self.currentThreadIsMain()
        }.value
    }

    private static func currentThreadIsMain() -> Bool { Thread.isMainThread }
    #endif
}
