import ForgeData
import ForgeCore
import Foundation
import SwiftData

nonisolated struct RoutineDetailAnalyticsSnapshot: Sendable {
    static let empty = Self(
        baselines: [:],
        volumeSeries: [],
        repsSeries: [],
        durationSeries: []
    )

    let baselines: [UUID: Double]
    let volumeSeries: [MetricPoint]
    let repsSeries: [MetricPoint]
    let durationSeries: [MetricPoint]

    func series(for metric: TrainingAnalytics.Metric) -> [MetricPoint] {
        switch metric {
        case .volume: volumeSeries
        case .reps: repsSeries
        case .duration: durationSeries
        }
    }
}

/// Builds routine-detail history projections on an isolated SwiftData context.
/// Persistent models never cross the detached boundary; the view receives only
/// immutable chart points and UUID-keyed baseline values.
nonisolated struct RoutineDetailAnalyticsWorker: Sendable {
    let modelContainer: ModelContainer

    func calculate(routineID: UUID) async throws -> RoutineDetailAnalyticsSnapshot {
        let container = modelContainer
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let workouts = try context.fetch(FetchDescriptor<WorkoutModel>(
                predicate: #Predicate { $0.endedAt != nil && $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.startedAt)]
            ))
            try Task.checkCancellation()

            var baselines: [UUID: Double] = [:]
            var volumeSeries: [MetricPoint] = []
            var repsSeries: [MetricPoint] = []
            var durationSeries: [MetricPoint] = []
            let analytics = TrainingAnalytics(workouts: workouts, exercises: [])
            for workout in workouts {
                for workoutExercise in workout.exercises {
                    for set in workoutExercise.sets
                    where set.completedAt != nil && set.setType.countsAsWorkingVolume {
                        guard let estimate = set.estimated1RM,
                              estimate.isFinite, estimate > 0 else { continue }
                        baselines[workoutExercise.exerciseID] = max(
                            baselines[workoutExercise.exerciseID] ?? 0,
                            estimate
                        )
                    }
                }
                if workout.routineID == routineID {
                    let summary = analytics.summary(for: workout)
                    volumeSeries.append(MetricPoint(date: workout.startedAt, value: summary.volume))
                    repsSeries.append(MetricPoint(date: workout.startedAt, value: Double(summary.reps)))
                    durationSeries.append(MetricPoint(
                        date: workout.startedAt,
                        value: Double(summary.durationSeconds)
                    ))
                }
                try Task.checkCancellation()
            }

            try Task.checkCancellation()
            return RoutineDetailAnalyticsSnapshot(
                baselines: baselines,
                volumeSeries: volumeSeries,
                repsSeries: repsSeries,
                durationSeries: durationSeries
            )
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }
}
