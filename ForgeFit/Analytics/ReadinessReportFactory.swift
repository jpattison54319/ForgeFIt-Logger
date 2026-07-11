import ForgeData
import Foundation
import SwiftData

/// Provides the same check-in-aware report to non-view surfaces that cannot
/// observe `@Query` directly: widgets, notifications, workout-start stamps,
/// and Watch connectivity.
@MainActor
enum ReadinessReportFactory {
    static func todayCheckinTags(in context: ModelContext, now: Date = .now) -> [String] {
        let checkins = (try? context.fetch(FetchDescriptor<DailyCheckinModel>())) ?? []
        return checkins
            .filter { $0.deletedAt == nil && Calendar.current.isDate($0.date, inSameDayAs: now) }
            .max { $0.updatedAt < $1.updatedAt }?
            .tags ?? []
    }

    static func report(
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        in context: ModelContext,
        supplementalSignals: [RecoveryEngine.Signal] = [],
        now: Date = .now
    ) -> RecoveryEngine.Report {
        RecoveryEngine(
            workouts: workouts,
            exercises: exercises,
            healthMetrics: HealthMetricsStore.shared.metrics,
            supplementalSignals: supplementalSignals,
            todayCheckinTags: todayCheckinTags(in: context, now: now),
            now: now
        ).report()
    }
}
