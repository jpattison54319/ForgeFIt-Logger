import Foundation
import ForgeCore
import ForgeData

/// Pure, deterministic analytics computed from logged workouts. Everything the
/// Home / Insights / Profile / Recovery screens display is derived here so the
/// views stay declarative and the math is testable in one place.
struct TrainingAnalytics {
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    var calendar = Calendar.current
    var now = Date()

    private var exerciseByID: [UUID: ExerciseLibraryModel] {
        Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Completed, non-deleted strength workouts (has at least one exercise).
    var completed: [WorkoutModel] {
        workouts.filter { $0.endedAt != nil && $0.deletedAt == nil }
    }

    /// True when a completed workout exists today.
    func trainedToday() -> Bool {
        let today = calendar.startOfDay(for: now)
        return completed.contains { calendar.startOfDay(for: $0.startedAt) == today }
    }

    // MARK: - Per-workout rollups

    struct Summary {
        var date: Date
        var volume: Double        // kg
        /// Effective working sets (`VolumeMath.effectiveSetCount`) — myo-rep /
        /// rest-pause blocks count more than 1, drop rows count 0.5.
        var sets: Double
        var reps: Int
        var durationSeconds: Int
        var hasStrength: Bool
        var hasCardio: Bool
        var isCardio: Bool
        var avgHR: Int?
    }

    func summary(for workout: WorkoutModel) -> Summary {
        let working = workout.exercises.flatMap(\.sets).filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
        let volume = working.reduce(0) { $0 + ($1.totalVolume ?? 0) }
        let reps = working.reduce(0) { $0 + ($1.reps ?? 0) }
        let elapsedDuration: Int
        if let ended = workout.endedAt {
            elapsedDuration = max(0, Int(ended.timeIntervalSince(workout.startedAt)))
        } else {
            elapsedDuration = 0
        }
        let cardio = workout.cardioSessions.first
        // `durationSeconds` is the whole workout's wall-clock duration. A
        // cardio block inside a mixed workout is only one part of that window.
        // Imported legacy cardio may lack a useful workout end time, so its
        // block durations remain a fallback rather than overriding elapsed.
        let duration = elapsedDuration > 0
            ? elapsedDuration
            : workout.cardioSessions.compactMap(\.durationSeconds).reduce(0, +)
        let hasCardio = cardio != nil
        let hasStrength = !working.isEmpty
        return Summary(
            date: workout.startedAt,
            volume: volume,
            sets: working.reduce(0) { $0 + VolumeMath.effectiveSetCount($1.domainEntry) },
            reps: reps,
            durationSeconds: duration,
            hasStrength: hasStrength,
            hasCardio: hasCardio,
            isCardio: hasCardio && !hasStrength,
            avgHR: cardio?.avgHR
        )
    }

    // MARK: - This-week headline numbers

    struct WeekTotals {
        var durationSeconds: Int
        var volume: Double
        var sets: Double
        var reps: Int
        var workoutCount: Int
    }

    func thisWeek() -> WeekTotals {
        let week = TrainingWeekSupport.interval(containing: now, calendar: calendar)
        let inWeek = completed.filter { week.contains($0.startedAt) }
        let summaries = inWeek.map(summary(for:))
        return WeekTotals(
            durationSeconds: summaries.reduce(0) { $0 + $1.durationSeconds },
            volume: summaries.reduce(0) { $0 + $1.volume },
            sets: summaries.reduce(0) { $0 + $1.sets },
            reps: summaries.reduce(0) { $0 + $1.reps },
            workoutCount: inWeek.count
        )
    }

    // MARK: - Weekly trend series (for bar / line charts)

    enum Metric: String, CaseIterable, Identifiable {
        case duration = "Duration"
        case volume = "Volume"
        case reps = "Reps"
        var id: String { rawValue }
    }

    /// One bucket per week for the last `weeks` weeks (oldest → newest).
    func weeklySeries(_ metric: Metric, weeks: Int = 12) -> [MetricPoint] {
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var buckets: [Date: Double] = [:]
        for i in 0..<weeks {
            if let start = calendar.date(byAdding: .weekOfYear, value: -i, to: thisWeekStart) {
                buckets[start] = 0
            }
        }
        for workout in completed {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: workout.startedAt)?.start,
                  buckets[start] != nil else { continue }
            let s = summary(for: workout)
            switch metric {
            case .duration: buckets[start]? += Double(s.durationSeconds) / 3600  // hours
            case .volume: buckets[start]? += s.volume
            case .reps: buckets[start]? += Double(s.reps)
            }
        }
        return buckets
            .map { MetricPoint(date: $0.key, value: $0.value) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Muscle volume (weekly fractional sets)

    func weeklyMuscleVolume() -> [MuscleVolumeBars.Row] {
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let byID = exerciseByID
        var entries: [(set: SetEntry, exercise: ExerciseInfo)] = []
        for workout in completed where workout.startedAt >= weekStart {
            for we in workout.exercises {
                guard let ex = byID[we.exerciseID] else { continue }
                for set in we.sets where set.completedAt != nil {
                    entries.append((set.domainEntry, ex.domainInfo))
                }
            }
        }
        let totals = MuscleVolume.weeklyVolume(entries)
        // Conventional weekly landmark target of ~14 sets/muscle.
        return totals
            .map { MuscleVolumeBars.Row(muscle: $0.key, sets: $0.value, target: 14) }
            .sorted { $0.sets > $1.sets }
    }

    /// Fractional-set volume by muscle for a single workout's completed working
    /// sets, biggest contributor first. Powers the "muscles worked" rollup on a
    /// logged workout.
    func muscleVolume(for workout: WorkoutModel) -> [(muscle: String, sets: Double)] {
        let byID = exerciseByID
        var entries: [(set: SetEntry, exercise: ExerciseInfo)] = []
        for we in workout.exercises {
            guard let ex = byID[we.exerciseID] else { continue }
            for set in we.sets where set.completedAt != nil {
                entries.append((set.domainEntry, ex.domainInfo))
            }
        }
        return MuscleVolume.weeklyVolume(entries)
            .map { (muscle: $0.key, sets: $0.value) }
            .sorted { $0.sets > $1.sets }
    }

    // MARK: - Personal records (best e1RM per exercise)

    struct ExerciseRecord: Identifiable {
        let id: UUID
        let name: String
        let best1RM: Double     // kg
        let bestVolumeSet: Double
        let lastPerformed: Date
    }

    func records() -> [ExerciseRecord] {
        let byID = exerciseByID
        var best: [UUID: ExerciseRecord] = [:]
        for workout in completed {
            for we in workout.exercises {
                guard let ex = byID[we.exerciseID] else { continue }
                for set in we.sets where set.completedAt != nil {
                    let e1rm = set.estimated1RM ?? 0
                    let vol = set.totalVolume ?? 0
                    if let existing = best[ex.id] {
                        best[ex.id] = ExerciseRecord(
                            id: ex.id,
                            name: ex.name,
                            best1RM: max(existing.best1RM, e1rm),
                            bestVolumeSet: max(existing.bestVolumeSet, vol),
                            lastPerformed: max(existing.lastPerformed, workout.startedAt)
                        )
                    } else {
                        best[ex.id] = ExerciseRecord(
                            id: ex.id, name: ex.name, best1RM: e1rm,
                            bestVolumeSet: vol, lastPerformed: workout.startedAt
                        )
                    }
                }
            }
        }
        return best.values
            .filter { $0.best1RM > 0 }
            .sorted { $0.lastPerformed > $1.lastPerformed }
    }

    /// e1RM progression for a single exercise (one point per session best).
    func e1rmSeries(for exerciseID: UUID) -> [MetricPoint] {
        var points: [MetricPoint] = []
        for workout in completed.sorted(by: { $0.startedAt < $1.startedAt }) {
            let best = workout.exercises
                .filter { $0.exerciseID == exerciseID }
                .flatMap(\.sets)
                .filter { $0.completedAt != nil }
                .compactMap { $0.estimated1RM }
                .max()
            if let best, best > 0 {
                points.append(MetricPoint(date: workout.startedAt, value: best))
            }
        }
        return points
    }

    /// Volume-over-time for a routine (matches the routine-detail chart).
    func routineVolumeSeries(routineID: UUID, metric: Metric) -> [MetricPoint] {
        completed
            .filter { $0.routineID == routineID }
            .sorted { $0.startedAt < $1.startedAt }
            .map { workout in
                let s = summary(for: workout)
                let value: Double = switch metric {
                case .volume: s.volume
                case .reps: Double(s.reps)
                case .duration: Double(s.durationSeconds) / 60
                }
                return MetricPoint(date: workout.startedAt, value: value)
            }
    }

    // MARK: - Cardio

    /// Real cardio only — yoga rides `CardioSessionModel` but has its own
    /// analytics pillar (`FlexibilityAnalytics`), so every cardio surface
    /// excludes it here at the source.
    var cardioSessions: [CardioSessionModel] {
        completed.flatMap { $0.cardioSessions }.filter { !$0.isYogaSession }
    }

    func cardioWeeklyMinutes(weeks: Int = 12) -> [MetricPoint] {
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var buckets: [Date: Double] = [:]
        for i in 0..<weeks {
            if let start = calendar.date(byAdding: .weekOfYear, value: -i, to: thisWeekStart) { buckets[start] = 0 }
        }
        for session in cardioSessions {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: session.startedAt)?.start,
                  buckets[start] != nil else { continue }
            buckets[start]? += Double(session.durationSeconds ?? 0) / 60
        }
        return buckets.map { MetricPoint(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
    }

    /// Seconds spent in each of the 5 HR zones, summed across cardio sessions in
    /// the last `weeks` weeks. Prefers each session's stored `hrZoneSeconds`
    /// (measured), falling back to an average-HR estimate so a distribution
    /// still appears for sessions logged without a per-second stream.
    func cardioZoneTotals(weeks: Int = 12) -> [Int] {
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let windowStart = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeekStart)
        else { return [Int](repeating: 0, count: 5) }
        var totals = [Int](repeating: 0, count: 5)
        for session in cardioSessions where session.startedAt >= windowStart {
            let zones = session.hrZoneSeconds.count == 5 && session.hrZoneSeconds.contains(where: { $0 > 0 })
                ? session.hrZoneSeconds
                : CardioMetrics.estimatedZoneSecondsArray(avgHR: session.avgHR, durationSeconds: session.durationSeconds)
            for i in 0..<5 { totals[i] += zones[i] }
        }
        return totals
    }
}
