import ForgeCore
import ForgeData
import Foundation

/// O(1), body-safe cache keys for Home's bounded presentations. Persistent
/// semantic changes arrive through `RenderPerformanceRevisions`; row counts
/// cover an initial-query/subscription race for inserts and deletes.
@MainActor
enum HomePerformanceRevision {
    struct SuggestionKey: Equatable {
        let persistenceRevision: Int
        let routineCount: Int
        let workoutCount: Int
        let alternationCount: Int
        let folderCount: Int
        let activeMicrocycle: String
        let activeMesocycle: String
        let day: Date
    }

    struct QuickStartKey: Equatable {
        let persistenceRevision: Int
        let routineCount: Int
        let json: String
    }

    struct AnalyticsKey: Hashable {
        let historyRevision: Int
        let exerciseRevision: Int
        let workoutCount: Int
        let exerciseCount: Int
        let healthRefresh: TimeInterval
        let healthMetricsRevision: Int
        let checkinTags: String
        let day: Date
    }

    struct AnalyticsTaskKey: Hashable {
        let request: AnalyticsKey
        let liveWorkoutActive: Bool
    }

    struct WeekKey: Equatable {
        let historyRevision: Int
        let exerciseRevision: Int
        let workoutCount: Int
        let exerciseCount: Int
        let weekStart: Date
    }

    struct CoachDoseKey: Equatable {
        let request: AnalyticsKey
        let renderedRequest: AnalyticsKey?
        let routineID: UUID
        let routineUpdatedAt: Date
    }

    static func suggestion(
        persistenceRevision: Int,
        routineCount: Int,
        workoutCount: Int,
        alternationCount: Int,
        folderCount: Int,
        activeMicrocycle: String,
        activeMesocycle: String,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> SuggestionKey {
        SuggestionKey(
            persistenceRevision: persistenceRevision,
            routineCount: routineCount,
            workoutCount: workoutCount,
            alternationCount: alternationCount,
            folderCount: folderCount,
            activeMicrocycle: activeMicrocycle,
            activeMesocycle: activeMesocycle,
            day: calendar.startOfDay(for: now)
        )
    }

    static func quickStart(
        json: String,
        persistenceRevision: Int,
        routineCount: Int
    ) -> QuickStartKey {
        QuickStartKey(
            persistenceRevision: persistenceRevision,
            routineCount: routineCount,
            json: json
        )
    }

    static func week(
        historyRevision: Int,
        exerciseRevision: Int,
        workoutCount: Int,
        exerciseCount: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> WeekKey {
        WeekKey(
            historyRevision: historyRevision,
            exerciseRevision: exerciseRevision,
            workoutCount: workoutCount,
            exerciseCount: exerciseCount,
            weekStart: TrainingWeekSupport.interval(
                containing: now,
                calendar: calendar
            ).start
        )
    }

    /// `WorkoutFeedRow` is shared by several history surfaces. The key is
    /// intentionally cheaper than rebuilding its summary/presentation, while
    /// still covering late Health/cardio enrichment and structured-set edits.
    static func exerciseCatalog(_ exercises: [ExerciseLibraryModel]) -> Int {
        var hasher = Hasher()
        hasher.combine(exercises.count)
        for exercise in exercises {
            hasher.combine(exercise.id)
            hasher.combine(exercise.updatedAt)
            hasher.combine(exercise.deletedAt)
        }
        return hasher.finalize()
    }

    static func workoutFeed(
        workout: WorkoutModel,
        exerciseCatalogRevision: Int,
        weightUnit: WeightUnit,
        distanceUnit: DistanceUnit
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(workout.id)
        hasher.combine(workout.title)
        hasher.combine(workout.startedAt)
        hasher.combine(workout.endedAt)
        hasher.combine(workout.updatedAt)
        hasher.combine(workout.deletedAt)
        hasher.combine(workout.totalVolume)
        hasher.combine(workout.avgHR)
        hasher.combine(workout.activeEnergyKcal)
        hasher.combine(workout.conditioningPlanSnapshotJSON)
        hasher.combine(workout.conditioningResultJSON)
        hasher.combine(exerciseCatalogRevision)
        hasher.combine(weightUnit.rawValue)
        hasher.combine(distanceUnit.rawValue)
        return hasher.finalize()
    }
}
