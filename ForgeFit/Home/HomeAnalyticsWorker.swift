import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Immutable inputs copied from the MainActor-owned Health cache before score
/// calculation moves to a detached worker.
nonisolated struct HomeAnalyticsInput: Sendable {
    let healthMetrics: [RecoveryEngine.DailyHealthMetric]
    let supplementalSignals: [RecoveryEngine.Signal]
    let activityMetrics: [DailyActivityMetric]
    let todayCheckinTags: [String]
    let now: Date
}

/// The value-only result that crosses back to MainActor for presentation.
/// RecoveryEngine.Report is composed entirely of value types, but its nested
/// presentation types predate strict Sendable annotations, so this boundary
/// states that invariant in one place.
nonisolated struct HomeAnalyticsResult: @unchecked Sendable {
    let generatedAt: Date
    let recovery: RecoveryEngine.Report
    let strain: DailyStrainEngine.Report
    let latestHealthMetric: RecoveryEngine.DailyHealthMetric?
    let healthAssessment: HealthRangeAssessment

    /// Derived from the exact metric snapshot that drives Home's sleep tile,
    /// so the review prompt can never lag behind or lead the displayed value.
    var sleepIntegrityAlert: SleepIntegrityAlert? {
        latestHealthMetric.flatMap(SleepIntegrityAlert.init(metric:))
    }
}

nonisolated struct BodyweightSample: Sendable {
    let date: Date
    let value: Double
}

/// Runs each history-wide operation in a detached task whose SwiftData context
/// is created and consumed there. Model objects never cross that boundary;
/// only immutable value projections return to MainActor.
nonisolated struct HomeAnalyticsWorker: Sendable {
    let modelContainer: ModelContainer

    #if DEBUG
    func isExecutingOnMainThreadForTesting() async -> Bool {
        let container = modelContainer
        return await Task.detached(priority: .userInitiated) {
            _ = ModelContext(container)
            return Self.currentThreadIsMain()
        }.value
    }

    private static func currentThreadIsMain() -> Bool {
        Thread.isMainThread
    }
    #endif

    func calculateCurrent(_ input: HomeAnalyticsInput) async throws -> HomeAnalyticsResult {
        let container = modelContainer
        // Home already has a same-day persisted render. Keep refresh scoring
        // below touch/render priority so a large history can never compete
        // with the first scroll after HealthKit publishes new values.
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            return try Self.calculateCurrent(input, in: context)
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    private static func calculateCurrent(
        _ input: HomeAnalyticsInput,
        in modelContext: ModelContext
    ) throws -> HomeAnalyticsResult {
        try Task.checkCancellation()
        let workouts = try modelContext.fetch(FetchDescriptor<WorkoutModel>())
        let exercises = try modelContext.fetch(FetchDescriptor<ExerciseLibraryModel>())
        try Task.checkCancellation()

        let recovery = RecoveryEngine(
            workouts: workouts,
            exercises: exercises,
            healthMetrics: input.healthMetrics,
            supplementalSignals: input.supplementalSignals,
            todayCheckinTags: input.todayCheckinTags,
            now: input.now
        ).report()
        try Task.checkCancellation()

        let strain = DailyStrainEngine(
            workouts: workouts,
            activityMetrics: input.activityMetrics,
            dailyReadiness: recovery.recovery.daily.state.value,
            trendRecovery: recovery.recovery.systemic.state.value,
            now: input.now
        ).report()
        try Task.checkCancellation()

        return HomeAnalyticsResult(
            generatedAt: input.now,
            recovery: recovery,
            strain: strain,
            latestHealthMetric: input.healthMetrics.max { $0.date < $1.date },
            healthAssessment: HealthRangeAssessment.make(metrics: input.healthMetrics)
        )
    }

    /// Builds the one-time calendar history without monopolizing MainActor.
    /// Existing captured values are merged later by RecoverySnapshotStore, so
    /// this pure projection never overwrites a score the user actually saw.
    func calculateBackfill(
        _ input: HomeAnalyticsInput,
        days: Int = 60
    ) async throws -> [Date: RecoverySnapshot] {
        let container = modelContainer
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            return try Self.calculateBackfill(input, days: days, in: context)
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    private static func calculateBackfill(
        _ input: HomeAnalyticsInput,
        days: Int,
        in modelContext: ModelContext
    ) throws -> [Date: RecoverySnapshot] {
        try Task.checkCancellation()
        let workouts = try modelContext.fetch(FetchDescriptor<WorkoutModel>())
        let exercises = try modelContext.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let checkins = try modelContext.fetch(FetchDescriptor<DailyCheckinModel>())
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: input.now)

        let hasCompletedWorkout = workouts.contains {
            $0.endedAt != nil && $0.deletedAt == nil
        }
        guard hasCompletedWorkout || !input.healthMetrics.isEmpty || !input.activityMetrics.isEmpty else {
            return [:]
        }

        var checkinByDay: [Date: (updatedAt: Date, tags: [String])] = [:]
        for checkin in checkins where checkin.deletedAt == nil {
            let day = calendar.startOfDay(for: checkin.date)
            if checkinByDay[day].map({ $0.updatedAt < checkin.updatedAt }) ?? true {
                checkinByDay[day] = (checkin.updatedAt, checkin.tags)
            }
        }

        var output: [Date: RecoverySnapshot] = [:]
        for offset in 0...max(0, days) {
            try Task.checkCancellation()
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                continue
            }
            let key = calendar.startOfDay(for: day)
            let asOf = calendar.date(
                bySettingHour: 10,
                minute: 0,
                second: 0,
                of: day
            ) ?? day
            let report = RecoveryEngine(
                workouts: workouts,
                exercises: exercises,
                healthMetrics: input.healthMetrics,
                todayCheckinTags: checkinByDay[key]?.tags ?? [],
                now: asOf
            ).report()
            let strain = DailyStrainEngine(
                workouts: workouts,
                activityMetrics: input.activityMetrics,
                dailyReadiness: report.recovery.daily.state.value,
                trendRecovery: report.recovery.systemic.state.value,
                calendar: calendar,
                now: asOf
            ).report()
            let snapshot = RecoverySnapshot(
                daily: report.recovery.daily.state.value,
                trend: report.recovery.systemic.state.value,
                strain: strain.score,
                strainTargetLower: strain.targetRange?.lowerBound,
                strainTargetUpper: strain.targetRange?.upperBound
            )
            if snapshot.hasData {
                output[key] = snapshot
            }
        }
        return output
    }

    /// Repairs historical bodyweight-family set loads on the worker's model
    /// context. Saving here lets SwiftData merge the changes normally without
    /// making Home traverse every workout and set on MainActor.
    func fillMissingBodyweight(from samples: [BodyweightSample]) async throws {
        let container = modelContainer
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            try Self.fillMissingBodyweight(from: samples, in: context)
        }
        try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    private static func fillMissingBodyweight(
        from samples: [BodyweightSample],
        in modelContext: ModelContext
    ) throws {
        guard !samples.isEmpty else { return }
        try Task.checkCancellation()
        // Most refreshes have nothing to repair. Let SQLite answer that with a
        // narrow predicate instead of faulting every workout, exercise, and
        // set merely to discover the answer is "none".
        let missing = try modelContext.fetch(FetchDescriptor<SetModel>(
            predicate: #Predicate {
                $0.completedAt != nil
                    && $0.bodyweightKg == nil
                    && $0.weightModeRaw != "external"
            }
        ))
        guard !missing.isEmpty else { return }

        var affectedWorkouts: [UUID: WorkoutModel] = [:]
        for set in missing {
            try Task.checkCancellation()
            guard let workout = set.workoutExercise?.workout,
                  workout.deletedAt == nil else { continue }
            let reference = set.completedAt ?? workout.startedAt
            set.bodyweightKg = samples.min {
                abs($0.date.timeIntervalSince(reference))
                    < abs($1.date.timeIntervalSince(reference))
            }?.value
            set.recomputeDerivedMetrics()
            affectedWorkouts[workout.id] = workout
        }

        if !affectedWorkouts.isEmpty {
            for workout in affectedWorkouts.values {
                workout.recomputeTotalVolume()
            }
            try modelContext.save()
        }
    }
}
