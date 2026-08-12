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
        guard LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork else { return }
        await ImportedExerciseBackfill.runIfNeeded(in: context)
        guard !Task.isCancelled,
              LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork else { return }
        await HealthWorkoutImporter.shared.importRecent(in: context.container)
        guard !Task.isCancelled,
              LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork else { return }
        await HealthMetricsStore.shared.refreshNow()
        guard !Task.isCancelled,
              LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork else { return }

        WatchLink.shared.publishState()
        ReadinessDelivery.shared.refreshMorningNotification()
    }
}
