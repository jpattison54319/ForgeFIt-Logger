import ForgeData
import Foundation
import SwiftData

/// Provides the same check-in-aware report to non-view surfaces that cannot
/// observe `@Query` directly: widgets, notifications, workout-start stamps,
/// and Watch connectivity.
@MainActor
enum ReadinessReportFactory {
    static func todayCheckinTags(in context: ModelContext, now: Date = .now) -> [String] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        var descriptor = FetchDescriptor<DailyCheckinModel>(
            predicate: #Predicate {
                $0.deletedAt == nil && $0.date >= dayStart && $0.date < dayEnd
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.tags ?? []
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
