import Foundation
import ForgeCore
import ForgeData

/// A same-day exertion guide kept deliberately separate from recovery.
///
/// Movement uses steps accumulated through the same local clock time. Training
/// prefers genuine whole-session duration x CR10 load and uses an explicitly
/// estimated component fallback when that rating is absent. The 0...10
/// transform and 35/65 weights are product settings, not a biological dose,
/// readiness measure, optimized target, or injury prediction.
nonisolated struct DailyStrainEngine {
    struct Report: Equatable {
        enum Status: Equatable {
            case building
            case targetBuilding
            case belowTarget
            case inTarget
            case aboveTarget
        }

        var score: Double?
        var targetRange: ClosedRange<Double>?
        var status: Status
        var baselineDays: Int
        var steps: Int?
        var activeEnergyKcal: Int?
        var exerciseMinutes: Int?
        var workoutMinutes: Int
        var workoutLoad: Double
        var workoutLoadWasEstimated: Bool
        var movementRatio: Double?
        var workoutRatio: Double?
        var coverage: Double

        var targetMidpoint: Double? {
            targetRange.map { ($0.lowerBound + $0.upperBound) / 2 }
        }

        var progressToTarget: Double? {
            guard let score, let target = targetMidpoint, target > 0 else { return nil }
            return min(1, max(0, score / target))
        }

        /// Status is fully determined by the score and target. This is the
        /// single derivation — the engine and Home's same-day cached tile
        /// (which stores only score + target) both resolve through it.
        static func status(score: Double?, targetRange: ClosedRange<Double>?) -> Status {
            guard let score else { return .building }
            guard let targetRange else { return .targetBuilding }
            if score < targetRange.lowerBound { return .belowTarget }
            if score > targetRange.upperBound { return .aboveTarget }
            return .inTarget
        }
    }

    let workouts: [WorkoutModel]
    let activityMetrics: [DailyActivityMetric]
    /// Retained in the initializer while callers migrate. Recovery does not
    /// change either today's strain or its historical usual range.
    var dailyReadiness: Double?
    var trendRecovery: Double?
    var calendar = Calendar.current
    var now = Date()

    private let baselineWindowDays = 56
    private let minimumMovementDays = 14

    func report() -> Report {
        let today = calendar.startOfDay(for: now)
        let completed = completedWorkouts
        let evidenceDates = activityMetrics.map(\.date) + completed.map(\.startedAt)
        let oldestEvidence = evidenceDates
            .map { calendar.startOfDay(for: $0) }
            .filter { $0 < today }
            .min()
        let historyDaysAvailable = min(
            baselineWindowDays,
            oldestEvidence.map {
                max(0, calendar.dateComponents([.day], from: $0, to: today).day ?? 0)
            } ?? 0
        )
        let priorActivity = activityMetrics.filter {
            let day = calendar.startOfDay(for: $0.date)
            let age = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            return day < today && age <= historyDaysAvailable
        }
        let todayActivity = activityMetrics.last {
            calendar.isDate($0.date, inSameDayAs: today)
        }

        let movement = movementRatio(today: todayActivity, history: priorActivity)
        let workoutLoads = workoutLoadsByDay(today: today)
        let todayWorkoutLoad = workoutLoads[today] ?? 0
        let historicalTrainingLoads = Array(1...max(1, historyDaysAvailable)).compactMap { offset -> Double? in
            guard offset <= historyDaysAvailable else { return nil }
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return workoutLoads[day] ?? 0
        }
        let todayWorkouts = completed.filter { calendar.isDate($0.startedAt, inSameDayAs: today) }
        let historicalWorkouts = completed.filter {
            let day = calendar.startOfDay(for: $0.startedAt)
            let age = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            return age >= 1 && age <= historyDaysAvailable
        }
        let trainingComplete = (todayWorkouts + historicalWorkouts).allSatisfy {
            trainingLoadCalculator.sessionEstimate($0).total > 0
        }
        let workoutLoadWasEstimated = todayWorkouts.contains {
            let estimate = trainingLoadCalculator.sessionEstimate($0)
            return estimate.total > 0 && estimate.effortWasEstimated
        }
        let workoutPercentile = historyDaysAvailable >= minimumMovementDays && trainingComplete
            ? empiricalCDF(todayWorkoutLoad, in: historicalTrainingLoads)
            : nil

        let movementQuality = movement == nil ? 0.0 : 1.0
        let trainingQuality = workoutPercentile == nil ? 0.0 : 1.0
        let coverage = 0.35 * movementQuality + 0.65 * trainingQuality
        let raw = 10 * (
            0.35 * (movement?.ratio ?? 0.5)
            + 0.65 * (workoutPercentile ?? 0.5)
        )
        let score = coverage > 0 ? 5 + coverage * (raw - 5) : nil
        let targetRange = score == nil ? nil : historicalUsualRange(
            activity: priorActivity,
            workoutLoads: workoutLoads,
            today: today,
            historyDays: historyDaysAvailable,
            trainingComplete: trainingComplete
        )
        let status = Report.status(score: score, targetRange: targetRange)

        let workoutMinutes = completedWorkouts
            .filter { calendar.isDate($0.startedAt, inSameDayAs: today) }
            .reduce(0) { $0 + Int(durationMinutes($1).rounded()) }

        return Report(
            score: score,
            targetRange: targetRange,
            status: status,
            baselineDays: max(movement?.baselineDays ?? 0, historyDaysAvailable),
            steps: todayActivity?.steps.map { Int($0.rounded()) },
            activeEnergyKcal: todayActivity?.activeEnergyKcal.map { Int($0.rounded()) },
            exerciseMinutes: todayActivity?.exerciseMinutes.map { Int($0.rounded()) },
            workoutMinutes: workoutMinutes,
            workoutLoad: todayWorkoutLoad,
            workoutLoadWasEstimated: workoutLoadWasEstimated,
            movementRatio: movement?.ratio,
            workoutRatio: workoutPercentile,
            coverage: coverage
        )
    }

    private struct MovementRatio {
        var ratio: Double
        var baselineDays: Int
    }

    private func movementRatio(
        today: DailyActivityMetric?,
        history: [DailyActivityMetric]
    ) -> MovementRatio? {
        guard let today else { return nil }
        let todaySteps = today.comparableTimeSteps
        let historicalSteps = history.compactMap(\.comparableTimeSteps)
        guard let todaySteps, historicalSteps.count >= minimumMovementDays else { return nil }
        return MovementRatio(ratio: empiricalCDF(todaySteps, in: historicalSteps), baselineDays: historicalSteps.count)
    }

    private var trainingLoadCalculator: TrainingLoadCalculator {
        TrainingLoadCalculator(workouts: workouts, calendar: calendar, now: now)
    }

    private var completedWorkouts: [WorkoutModel] {
        trainingLoadCalculator.completedWorkouts
    }

    private func workoutLoadsByDay(today: Date) -> [Date: Double] {
        guard let cutoff = calendar.date(byAdding: .day, value: -baselineWindowDays, to: today) else { return [:] }
        return completedWorkouts
            .filter { $0.startedAt >= cutoff && $0.startedAt < now.addingTimeInterval(1) }
            .reduce(into: [:]) { loads, workout in
                loads[calendar.startOfDay(for: workout.startedAt), default: 0] += trainingLoadCalculator.sessionEstimate(workout).total
            }
    }

    private func durationMinutes(_ workout: WorkoutModel) -> Double {
        trainingLoadCalculator.durationMinutes(workout)
    }

    private func historicalUsualRange(
        activity: [DailyActivityMetric],
        workoutLoads: [Date: Double],
        today: Date,
        historyDays: Int,
        trainingComplete: Bool
    ) -> ClosedRange<Double>? {
        let steps = activity.compactMap { metric -> (Date, Double)? in
            guard let value = metric.comparableTimeSteps else { return nil }
            return (calendar.startOfDay(for: metric.date), value)
        }
        guard steps.count >= minimumMovementDays,
              historyDays >= minimumMovementDays,
              trainingComplete else { return nil }
        let stepValues = steps.map(\.1)
        let trainingValues = (1...historyDays).compactMap { offset -> Double? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return workoutLoads[day] ?? 0
        }
        guard trainingValues.count >= minimumMovementDays else { return nil }
        let scores = steps.map { day, value in
            let move = empiricalCDF(value, in: stepValues)
            let train = empiricalCDF(workoutLoads[day] ?? 0, in: trainingValues)
            return 10 * (0.35 * move + 0.65 * train)
        }
        guard let lower = quantile(scores, probability: 0.10),
              let upper = quantile(scores, probability: 0.90) else { return nil }
        return min(lower, upper)...max(lower, upper)
    }

    private func empiricalCDF(_ value: Double, in history: [Double]) -> Double {
        guard !history.isEmpty else { return 0.5 }
        let below = history.filter { $0 < value }.count
        let equal = history.filter { $0 == value }.count
        return (Double(below) + 0.5 * Double(equal)) / Double(history.count)
    }

    private func quantile(_ values: [Double], probability: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = min(1, max(0, probability)) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }
}
