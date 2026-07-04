import Foundation
import ForgeData
import SwiftData

/// One full data refresh, shared by pull-to-refresh on the main screens:
/// import any new Apple Health workouts, re-query the recovery series
/// (HRV/sleep/RHR/bodyweight/today's signals) and recompute the streak
/// nudge + watch snapshot. Readiness recomputes automatically once the
/// observable store updates.
@MainActor
enum AppRefresh {
    static func run(in context: ModelContext) async {
        await ImportedExerciseBackfill.runIfNeeded(in: context)
        await HealthWorkoutImporter.shared.importRecent(in: context)
        await HealthMetricsStore.shared.refreshNow()

        let workouts = (try? context.fetch(FetchDescriptor<WorkoutModel>())) ?? []
        let exercises = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        let analytics = TrainingAnalytics(workouts: workouts, exercises: exercises)
        NotificationScheduler.shared.refreshStreakNudge(
            streak: analytics.currentStreak(),
            trainedToday: analytics.trainedToday()
        )
        WatchLink.shared.publishState()
    }
}
