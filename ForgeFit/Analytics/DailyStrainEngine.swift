import Foundation
import ForgeCore
import ForgeData

/// A same-day exertion guide kept deliberately separate from recovery.
///
/// Scientific anchors and limits:
/// - Structured training uses Foster's session-RPE method (duration x RPE),
///   validated against heart-rate-based load across varied exercise sessions
///   (Foster et al., 2001, JSCR; PMID 11708692).
/// - Steps, exercise minutes, and active energy all contribute so incidental
///   movement is not treated as zero. Device-measured step volume has a graded
///   association with health outcomes (Lee et al., 2019, JAMA Intern Med), but
///   that study does not validate a universal "strain" conversion.
/// - Readiness changes the target modestly. HRV-guided training trials support
///   adjusting training timing/intensity, not prescribing an exact load from a
///   wearable score (Vesterinen et al., 2016, MSSE; PMID 26909534).
/// - ACWR thresholds are intentionally absent. Their mathematical and causal
///   limitations make them unsuitable as injury-risk targets (Impellizzeri et
///   al., 2020, IJSPP; PMID 32502973).
///
/// The 0...10 presentation, signal weights, and bounded target coefficients are
/// transparent product heuristics, not a physiological measurement or injury
/// prediction. Personal baselines do more of the work than population cutoffs.
struct DailyStrainEngine {
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
        var movementRatio: Double?
        var workoutRatio: Double?

        var targetMidpoint: Double? {
            targetRange.map { ($0.lowerBound + $0.upperBound) / 2 }
        }

        var progressToTarget: Double? {
            guard let score, let target = targetMidpoint, target > 0 else { return nil }
            return min(1, max(0, score / target))
        }
    }

    let workouts: [WorkoutModel]
    let activityMetrics: [DailyActivityMetric]
    var dailyReadiness: Double?
    var trendRecovery: Double?
    var calendar = Calendar.current
    var now = Date()

    private let baselineWindowDays = 28
    private let minimumMovementDays = 7

    func report() -> Report {
        let today = calendar.startOfDay(for: now)
        let priorActivity = activityMetrics.filter {
            let day = calendar.startOfDay(for: $0.date)
            let age = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            return day < today && age <= baselineWindowDays
        }
        let todayActivity = activityMetrics.last {
            calendar.isDate($0.date, inSameDayAs: today)
        }

        let movement = movementRatio(today: todayActivity, history: priorActivity)
        let workoutLoads = workoutLoadsByDay(today: today)
        let todayWorkoutLoad = workoutLoads[today] ?? 0
        let historyWorkoutCount = completedWorkouts.filter {
            let day = calendar.startOfDay(for: $0.startedAt)
            let age = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            return day < today && age <= baselineWindowDays
        }.count
        let workoutReference = historyWorkoutCount >= 3 ? workoutDailyReference(loads: workoutLoads, today: today) : nil
        // A first hard session should still register immediately when movement
        // history exists. 300 AU is only an initialization anchor (60 min at
        // RPE 5), never a personalized target or a claimed biological limit.
        let workoutRatio: Double? = {
            if let workoutReference, workoutReference > 0 {
                return cappedRatio(todayWorkoutLoad / workoutReference)
            }
            if todayWorkoutLoad > 0, movement != nil {
                return cappedRatio(todayWorkoutLoad / 300)
            }
            return nil
        }()

        let combinedRatio: Double? = {
            switch (movement?.ratio, workoutRatio) {
            case let (movement?, workout?):
                // Active energy already includes much of a workout. Blending
                // an internal-load signal instead of summing it reduces double
                // counting while still correcting lifting's energy blind spot.
                return 0.65 * movement + 0.35 * workout
            case let (movement?, nil): return movement
            case let (nil, workout?): return workout
            case (nil, nil): return nil
            }
        }()

        let score = combinedRatio.map(Self.score(forLoadRatio:))
        let targetRange = score == nil ? nil : strainTargetRange()
        let status: Report.Status = {
            guard let score else { return .building }
            guard let targetRange else { return .targetBuilding }
            if score < targetRange.lowerBound { return .belowTarget }
            if score > targetRange.upperBound { return .aboveTarget }
            return .inTarget
        }()

        let workoutMinutes = completedWorkouts
            .filter { calendar.isDate($0.startedAt, inSameDayAs: today) }
            .reduce(0) { $0 + Int(durationMinutes($1).rounded()) }

        return Report(
            score: score,
            targetRange: targetRange,
            status: status,
            baselineDays: movement?.baselineDays ?? (workoutReference == nil ? 0 : baselineWindowDays),
            steps: todayActivity?.steps.map { Int($0.rounded()) },
            activeEnergyKcal: todayActivity?.activeEnergyKcal.map { Int($0.rounded()) },
            exerciseMinutes: todayActivity?.exerciseMinutes.map { Int($0.rounded()) },
            workoutMinutes: workoutMinutes,
            workoutLoad: todayWorkoutLoad,
            movementRatio: movement?.ratio,
            workoutRatio: workoutRatio
        )
    }

    /// A user's recent norm maps near the middle of the display, while very
    /// large days approach 10 gradually instead of clipping at an arbitrary
    /// raw load. This is presentation math, not a biological dose-response.
    nonisolated static func score(forLoadRatio ratio: Double) -> Double {
        10 * (1 - exp(-0.8 * min(4, max(0, ratio))))
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
        var weightedRatios: [(ratio: Double, weight: Double, days: Int)] = []

        appendMovementRatio(
            today: today.activeEnergyKcal,
            history: history.compactMap(\.activeEnergyKcal),
            weight: 0.55,
            into: &weightedRatios
        )
        appendMovementRatio(
            today: today.exerciseMinutes,
            history: history.compactMap(\.exerciseMinutes),
            weight: 0.25,
            into: &weightedRatios
        )
        appendMovementRatio(
            today: today.steps,
            history: history.compactMap(\.steps),
            weight: 0.20,
            into: &weightedRatios
        )

        let weightSum = weightedRatios.reduce(0) { $0 + $1.weight }
        guard weightSum > 0 else { return nil }
        let ratio = weightedRatios.reduce(0) { $0 + $1.ratio * $1.weight } / weightSum
        return MovementRatio(
            ratio: cappedRatio(ratio),
            baselineDays: weightedRatios.map(\.days).max() ?? 0
        )
    }

    private func appendMovementRatio(
        today: Double?,
        history: [Double],
        weight: Double,
        into ratios: inout [(ratio: Double, weight: Double, days: Int)]
    ) {
        guard let today,
              history.count >= minimumMovementDays,
              let reference = robustMean(history),
              reference > 0 else { return }
        ratios.append((cappedRatio(today / reference), weight, history.count))
    }

    private var completedWorkouts: [WorkoutModel] {
        workouts.filter { $0.endedAt != nil && $0.deletedAt == nil }
    }

    private func workoutLoadsByDay(today: Date) -> [Date: Double] {
        guard let cutoff = calendar.date(byAdding: .day, value: -baselineWindowDays, to: today) else { return [:] }
        return completedWorkouts
            .filter { $0.startedAt >= cutoff && $0.startedAt < now.addingTimeInterval(1) }
            .reduce(into: [:]) { loads, workout in
                loads[calendar.startOfDay(for: workout.startedAt), default: 0] += sessionRPELoad(workout)
            }
    }

    private func workoutDailyReference(loads: [Date: Double], today: Date) -> Double? {
        var daily: [Double] = []
        for offset in 1...baselineWindowDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            if let load = loads[day], load > 0 { daily.append(load) }
        }
        return robustMean(daily)
    }

    private func sessionRPELoad(_ workout: WorkoutModel) -> Double {
        let strengthSets = workout.exercises.flatMap(\.sets).filter {
            $0.completedAt != nil && $0.setType.countsAsWorkingVolume
        }
        let hasStrength = !strengthSets.isEmpty
        let activeCardio = workout.cardioSessions.filter {
            !$0.isYogaSession || !$0.resolvedYogaStyle.isRestorative
        }
        if !hasStrength, activeCardio.isEmpty, !workout.cardioSessions.isEmpty { return 0 }

        var efforts: [Double] = strengthSets.compactMap { set in
            if let rpe = set.rpe { return min(10, max(0, rpe)) }
            if let rir = set.rir { return min(10, max(0, 10 - Double(rir))) }
            return nil
        }
        efforts += activeCardio.map(cardioEffort)
        if efforts.isEmpty, let avgHR = workout.avgHR {
            efforts.append(effort(forHeartRate: avgHR))
        }
        let effort = efforts.isEmpty ? 7 : efforts.reduce(0, +) / Double(efforts.count)
        return durationMinutes(workout) * effort
    }

    private func cardioEffort(_ session: CardioSessionModel) -> Double {
        if let effort = session.effort { return min(10, max(0, Double(effort))) }
        if let avgHR = session.avgHR { return effort(forHeartRate: avgHR) }
        if session.isYogaSession {
            return switch session.resolvedYogaStyle {
            case .power: 5
            case .vinyasa: 4
            default: 3
            }
        }
        return 7
    }

    private func effort(forHeartRate heartRate: Int) -> Double {
        switch HRZone.zone(forAvgHR: heartRate) {
        case 1: 3
        case 2: 4
        case 3: 6
        case 4: 8
        default: 9
        }
    }

    private func durationMinutes(_ workout: WorkoutModel) -> Double {
        if let endedAt = workout.endedAt {
            let elapsed = endedAt.timeIntervalSince(workout.startedAt) / 60
            if elapsed >= 1, elapsed <= 8 * 60 { return elapsed }
        }
        let cardioMinutes = workout.cardioSessions.reduce(0) {
            $0 + Double($1.durationSeconds ?? 0) / 60
        }
        return cardioMinutes > 0 ? cardioMinutes : 45
    }

    private func strainTargetRange() -> ClosedRange<Double>? {
        var weightedRecovery = 0.0
        var weightSum = 0.0
        if let dailyReadiness {
            weightedRecovery += min(1, max(0, dailyReadiness)) * 0.70
            weightSum += 0.70
        }
        if let trendRecovery {
            weightedRecovery += min(1, max(0, trendRecovery)) * 0.30
            weightSum += 0.30
        }
        guard weightSum > 0 else { return nil }

        let recovery = weightedRecovery / weightSum
        // Even perfect recovery only raises the norm by 20%; a green score is
        // not permission for a sudden load spike. Low recovery lowers the
        // target, but never prescribes complete inactivity.
        let midpointRatio = 0.65 + 0.55 * recovery
        let lower = Self.score(forLoadRatio: max(0.35, midpointRatio - 0.12))
        let upper = Self.score(forLoadRatio: min(1.35, midpointRatio + 0.12))
        return lower...upper
    }

    private func cappedRatio(_ value: Double) -> Double {
        min(4, max(0, value))
    }

    private func robustMean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let trim = sorted.count >= 10 ? sorted.count / 10 : 0
        let kept = sorted.dropFirst(trim).dropLast(trim)
        guard !kept.isEmpty else { return nil }
        return kept.reduce(0, +) / Double(kept.count)
    }
}
