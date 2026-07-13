import Foundation
import ForgeData
import SwiftData

/// One full data refresh, shared by pull-to-refresh on the main screens:
/// import any new Apple Health workouts, re-query the recovery series
/// (HRV/sleep/RHR/bodyweight/today's signals), then refresh the watch snapshot.
/// Readiness recomputes automatically once the observable store updates.
@MainActor
enum AppRefresh {
    static func run(in context: ModelContext) async {
        await ImportedExerciseBackfill.runIfNeeded(in: context)
        await HealthWorkoutImporter.shared.importRecent(in: context)
        await HealthMetricsStore.shared.refreshNow()

        WatchLink.shared.publishState()
        ReadinessDelivery.shared.refreshMorningNotification()
    }
}
