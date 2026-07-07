import Foundation
import ForgeCore
import ForgeData

/// Derived statistics for the Profile → Statistics screen: muscle
/// distribution, training split, top exercises, rep ranges, weekday habits,
/// strength progression, cardio breakdowns, and monthly reports. Pure and
/// deterministic like the rest of `TrainingAnalytics` so it's testable.
extension TrainingAnalytics {

    // MARK: - Range plumbing

    func completed(in range: TimeChartRange) -> [WorkoutModel] {
        guard range != .all,
              let start = calendar.date(byAdding: .weekOfYear, value: -range.weekCount, to: now) else {
            return completed
        }
        return completed.filter { $0.startedAt >= start }
    }

    /// Whole weeks covered by the range *that actually contain history* — used
    /// to convert range totals into per-week averages.
    func weeksOfHistory(in range: TimeChartRange) -> Double {
        let workouts = completed(in: range)
        guard let earliest = workouts.map(\.startedAt).min() else { return 1 }
        let days = max(1, calendar.dateComponents([.day], from: earliest, to: now).day ?? 7)
        return max(1, min(Double(range.weekCount), Double(days) / 7))
    }

    // MARK: - Muscle distribution

    struct MuscleShare: Identifiable {
        var id: String { muscle }
        let muscle: String
        let sets: Double
        let fraction: Double     // of all fractional sets in range
    }

    /// Fractional working sets per muscle over the range (primary 1.0,
    /// secondary 0.5 — the same convention as weekly muscle volume).
    func muscleDistribution(in range: TimeChartRange) -> [MuscleShare] {
        let byID = exerciseByIDPublic
        var entries: [(set: SetEntry, exercise: ExerciseInfo)] = []
        for workout in completed(in: range) {
            for we in workout.exercises {
                guard let exercise = byID[we.exerciseID], !exercise.isCardio else { continue }
                for set in we.sets where set.completedAt != nil {
                    entries.append((set.domainEntry, exercise.domainInfo))
                }
            }
        }
        let totals = MuscleVolume.weeklyVolume(entries)
        let grandTotal = totals.values.reduce(0, +)
        guard grandTotal > 0 else { return [] }
        return totals
            .map { MuscleShare(muscle: $0.key, sets: $0.value, fraction: $0.value / grandTotal) }
            .sorted { $0.sets > $1.sets }
    }

    // MARK: - Training split (push / pull / legs / core)

    struct SplitShare: Identifiable {
        var id: String { name }
        let name: String
        let sets: Double
        let fraction: Double
    }

    private static let splitCategories: [(name: String, muscles: Set<String>)] = [
        ("Push", ["chest", "shoulders", "triceps"]),
        ("Pull", ["lats", "middle back", "traps", "biceps", "forearms", "neck"]),
        ("Legs", ["quadriceps", "hamstrings", "glutes", "calves", "abductors", "adductors"]),
        ("Core", ["abdominals", "lower back"]),
    ]

    func trainingSplit(in range: TimeChartRange) -> [SplitShare] {
        let distribution = muscleDistribution(in: range)
        guard !distribution.isEmpty else { return [] }
        var totals: [String: Double] = [:]
        for share in distribution {
            let category = Self.splitCategories.first { $0.muscles.contains(share.muscle.lowercased()) }?.name ?? "Other"
            totals[category, default: 0] += share.sets
        }
        let grand = totals.values.reduce(0, +)
        let order = ["Push", "Pull", "Legs", "Core", "Other"]
        return order.compactMap { name in
            guard let sets = totals[name], sets > 0 else { return nil }
            return SplitShare(name: name, sets: sets, fraction: sets / grand)
        }
    }

    // MARK: - Top exercises

    struct ExerciseUsage: Identifiable {
        let id: UUID              // exercise id — navigable
        let name: String
        let workingSets: Int
        let volume: Double        // kg tonnage
        let sessions: Int
    }

    func topExercises(in range: TimeChartRange, limit: Int = 5) -> [ExerciseUsage] {
        let byID = exerciseByIDPublic
        var sets: [UUID: Int] = [:]
        var volume: [UUID: Double] = [:]
        var sessions: [UUID: Set<UUID>] = [:]
        for workout in completed(in: range) {
            for we in workout.exercises {
                guard let exercise = byID[we.exerciseID], !exercise.isCardio else { continue }
                let done = we.sets.filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
                guard !done.isEmpty else { continue }
                sets[we.exerciseID, default: 0] += done.count
                volume[we.exerciseID, default: 0] += done.reduce(0) { $0 + ($1.totalVolume ?? 0) }
                sessions[we.exerciseID, default: []].insert(workout.id)
            }
        }
        return sets
            .compactMap { id, count -> ExerciseUsage? in
                guard let exercise = byID[id] else { return nil }
                return ExerciseUsage(
                    id: id,
                    name: exercise.name,
                    workingSets: count,
                    volume: volume[id] ?? 0,
                    sessions: sessions[id]?.count ?? 0
                )
            }
            .sorted { $0.workingSets > $1.workingSets }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Rep ranges

    struct RepRangeShare: Identifiable {
        var id: String { label }
        let label: String
        let subtitle: String
        let sets: Int
        let fraction: Double
    }

    /// Working sets bucketed by classic adaptation zones.
    func repRangeDistribution(in range: TimeChartRange) -> [RepRangeShare] {
        var strength = 0, hypertrophy = 0, endurance = 0
        for workout in completed(in: range) {
            for we in workout.exercises {
                for set in we.sets where set.completedAt != nil && set.setType.countsAsWorkingVolume {
                    guard let reps = set.reps, reps > 0 else { continue }
                    switch reps {
                    case ..<6: strength += 1
                    case ..<13: hypertrophy += 1
                    default: endurance += 1
                    }
                }
            }
        }
        let total = strength + hypertrophy + endurance
        guard total > 0 else { return [] }
        return [
            RepRangeShare(label: "Strength", subtitle: "1–5 reps", sets: strength, fraction: Double(strength) / Double(total)),
            RepRangeShare(label: "Hypertrophy", subtitle: "6–12 reps", sets: hypertrophy, fraction: Double(hypertrophy) / Double(total)),
            RepRangeShare(label: "Endurance", subtitle: "13+ reps", sets: endurance, fraction: Double(endurance) / Double(total)),
        ]
    }

    // MARK: - Weekday habit

    func weekdayFrequency(in range: TimeChartRange) -> [(label: String, count: Int)] {
        var counts = [Int](repeating: 0, count: 7)
        for workout in completed(in: range) {
            let weekday = calendar.component(.weekday, from: workout.startedAt) - 1  // 0 = Sunday
            counts[weekday] += 1
        }
        let symbols = calendar.veryShortStandaloneWeekdaySymbols   // S M T W T F S
        // Rotate so the calendar's firstWeekday leads.
        let first = calendar.firstWeekday - 1
        return (0..<7).map { offset in
            let index = (first + offset) % 7
            return (symbols[index], counts[index])
        }
    }

    // MARK: - Strength progression

    struct StrengthGainer: Identifiable {
        let id: UUID
        let name: String
        let fromE1RM: Double     // kg
        let toE1RM: Double       // kg
        var gainFraction: Double { fromE1RM > 0 ? (toE1RM - fromE1RM) / fromE1RM : 0 }
    }

    /// Exercises whose estimated 1RM moved the most across the range: first
    /// session's best vs the latest session's best (needs ≥3 sessions so a
    /// single outlier day can't fake a trend).
    func topStrengthGainers(in range: TimeChartRange, limit: Int = 3) -> [StrengthGainer] {
        let byID = exerciseByIDPublic
        var sessionBests: [UUID: [(date: Date, best: Double)]] = [:]
        for workout in completed(in: range).sorted(by: { $0.startedAt < $1.startedAt }) {
            for we in workout.exercises {
                let best = we.sets
                    .filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
                    .compactMap(\.estimated1RM)
                    .max()
                guard let best, best > 0 else { continue }
                sessionBests[we.exerciseID, default: []].append((workout.startedAt, best))
            }
        }
        return sessionBests
            .compactMap { id, bests -> StrengthGainer? in
                guard bests.count >= 3,
                      let first = bests.first, let last = bests.last,
                      let exercise = byID[id],
                      last.best > first.best else { return nil }
                return StrengthGainer(id: id, name: exercise.name, fromE1RM: first.best, toE1RM: last.best)
            }
            .sorted { $0.gainFraction > $1.gainFraction }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Cardio

    struct ModalityShare: Identifiable {
        var id: String { kind.rawValue }
        let kind: CardioKind
        let sessions: Int
        let minutes: Double
        let distanceMeters: Double
    }

    struct RangedCardioSession {
        let workout: WorkoutModel
        let session: CardioSessionModel
    }

    func cardioSessions(in range: TimeChartRange) -> [RangedCardioSession] {
        completed(in: range).flatMap { workout in
            workout.cardioSessions.map { RangedCardioSession(workout: workout, session: $0) }
        }
    }

    func cardioModalityBreakdown(in range: TimeChartRange) -> [ModalityShare] {
        var sessions: [CardioKind: Int] = [:]
        var minutes: [CardioKind: Double] = [:]
        var distance: [CardioKind: Double] = [:]
        for item in cardioSessions(in: range) {
            let kind = CardioKind.from(modality: item.session.modality)
            sessions[kind, default: 0] += 1
            minutes[kind, default: 0] += Double(item.session.durationSeconds ?? 0) / 60
            distance[kind, default: 0] += item.session.distanceMeters ?? 0
        }
        return sessions.keys
            .map { kind in
                ModalityShare(
                    kind: kind,
                    sessions: sessions[kind] ?? 0,
                    minutes: minutes[kind] ?? 0,
                    distanceMeters: distance[kind] ?? 0
                )
            }
            .sorted { $0.minutes > $1.minutes }
    }

    /// Aggregate seconds per HR zone across the range: measured zone data
    /// when the watch captured it, estimated from average HR otherwise.
    func cardioZoneTotals(in range: TimeChartRange) -> [Int] {
        var totals = [Int](repeating: 0, count: 5)
        for item in cardioSessions(in: range) {
            let zones: [Int]
            if item.session.hrZoneSeconds.count == 5, item.session.hrZoneSeconds.contains(where: { $0 > 0 }) {
                zones = item.session.hrZoneSeconds
            } else {
                zones = CardioMetrics.estimatedZoneSecondsArray(
                    avgHR: item.session.avgHR,
                    durationSeconds: item.session.durationSeconds
                )
            }
            for index in 0..<5 { totals[index] += zones[index] }
        }
        return totals
    }

    func cardioWeeklyDistance(weeks: Int = 12) -> [MetricPoint] {
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var buckets: [Date: Double] = [:]
        for i in 0..<weeks {
            if let start = calendar.date(byAdding: .weekOfYear, value: -i, to: thisWeekStart) { buckets[start] = 0 }
        }
        for session in cardioSessions {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: session.startedAt)?.start,
                  buckets[start] != nil else { continue }
            buckets[start]? += (session.distanceMeters ?? 0) / 1000
        }
        return buckets.map { MetricPoint(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
    }

    /// The modality with the most pace-able data in range, if any.
    func dominantPaceModality(in range: TimeChartRange) -> CardioKind? {
        let paceable = cardioSessions(in: range).filter { item in
            CardioKind.from(modality: item.session.modality).usesPace
                && (item.session.distanceMeters ?? 0) > 500
                && (item.session.durationSeconds ?? 0) > 0
        }
        let byKind = Dictionary(grouping: paceable) { CardioKind.from(modality: $0.session.modality) }
        return byKind.max { $0.value.count < $1.value.count }?.key
    }

    /// Per-session average pace (minutes per km) over time for one modality.
    func paceSeries(for kind: CardioKind, in range: TimeChartRange) -> [MetricPoint] {
        cardioSessions(in: range)
            .filter { CardioKind.from(modality: $0.session.modality) == kind }
            .compactMap { item -> MetricPoint? in
                guard let meters = item.session.distanceMeters, meters > 500,
                      let seconds = item.session.durationSeconds, seconds > 0 else { return nil }
                let minutesPerKm = (Double(seconds) / 60) / (meters / 1000)
                guard minutesPerKm.isFinite, minutesPerKm < 60 else { return nil }
                return MetricPoint(date: item.workout.startedAt, value: minutesPerKm)
            }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Efficiency Factor (aerobic progression)

    /// Efficiency Factor: distance covered per minute per heartbeat (or watts
    /// per heartbeat for power sports). Higher = more output per beat = fitter.
    /// Only meaningful at aerobic intensity — filter with `isAerobicSession`.
    func efficiencyFactor(for session: CardioSessionModel) -> Double? {
        guard let avgHR = session.avgHR, avgHR > 0 else { return nil }
        if let watts = session.avgPowerWatts, watts > 0 {
            return watts / Double(avgHR)
        }
        guard let meters = session.distanceMeters, meters > 0,
              let seconds = session.durationSeconds, seconds > 0 else { return nil }
        let metersPerMinute = meters / (Double(seconds) / 60)
        return metersPerMinute / Double(avgHR)
    }

    /// A session is "aerobic" (comparable for EF trending) when its average HR
    /// sits in the endurance band (zones 1–3 of the user's model) and it's a
    /// real sustained effort — not a sprint session or a token few minutes.
    func isAerobicSession(_ session: CardioSessionModel, config: HRZoneConfig) -> Bool {
        guard let avgHR = session.avgHR,
              let seconds = session.durationSeconds, seconds >= 600 else { return false }
        return config.zone(for: avgHR) <= 3 && (session.distanceMeters ?? 0) > 1000
    }

    /// EF over time for one modality's aerobic sessions — the cardio equivalent
    /// of a strength progression line.
    func efficiencySeries(for kind: CardioKind, in range: TimeChartRange) -> [MetricPoint] {
        let config = HRZoneConfigStore.load()
        return cardioSessions(in: range)
            .filter { CardioKind.from(modality: $0.session.modality) == kind && isAerobicSession($0.session, config: config) }
            .compactMap { item -> MetricPoint? in
                guard let ef = efficiencyFactor(for: item.session), ef.isFinite, ef > 0 else { return nil }
                return MetricPoint(date: item.workout.startedAt, value: ef)
            }
            .sorted { $0.date < $1.date }
    }

    /// The modality with the most aerobic EF-eligible sessions (drives which EF
    /// trend to surface).
    func dominantAerobicModality(in range: TimeChartRange) -> CardioKind? {
        let config = HRZoneConfigStore.load()
        let aerobic = cardioSessions(in: range).filter {
            isAerobicSession($0.session, config: config) && efficiencyFactor(for: $0.session) != nil
        }
        let byKind = Dictionary(grouping: aerobic) { CardioKind.from(modality: $0.session.modality) }
        return byKind.max { $0.value.count < $1.value.count }?.key
    }

    // MARK: - Critical pace curve

    static let criticalPaceWindows = [60, 180, 300, 600, 1200, 1800, 3600]

    struct CriticalPacePoint: Identifiable {
        var id: Int { windowSeconds }
        var windowSeconds: Int
        var paceSecPerKm: Double
    }

    struct CriticalPaceCurve {
        var current: [CriticalPacePoint]
        var prior: [CriticalPacePoint]
        var hasAnyData: Bool
    }

    /// The best sustained pace at each duration window across the range, plus the
    /// same for the immediately-preceding equal-length period (the overlay that
    /// shows whether the ceiling moved).
    func criticalPaceCurve(in range: TimeChartRange) -> CriticalPaceCurve {
        let windows = Self.criticalPaceWindows
        let currentSessions = cardioSessions(in: range).map(\.session)
        let current = bestPaces(windows: windows, sessions: currentSessions)
        let prior = bestPaces(windows: windows, sessions: cardioSessionsInPriorPeriod(range))
        let hasAnyData = currentSessions.contains { $0.sampleSeriesJSON != nil }
        return CriticalPaceCurve(current: current, prior: prior, hasAnyData: hasAnyData)
    }

    private func bestPaces(windows: [Int], sessions: [CardioSessionModel]) -> [CriticalPacePoint] {
        let seriesList = sessions
            .compactMap { CardioSampleSeries.decode(from: $0.sampleSeriesJSON) }
            .filter { $0.hasDistance }
        guard !seriesList.isEmpty else { return [] }
        return windows.compactMap { window in
            let best = seriesList.compactMap { $0.bestPaceSecPerKm(windowSeconds: window) }.min()
            return best.map { CriticalPacePoint(windowSeconds: window, paceSecPerKm: $0) }
        }
    }

    private func cardioSessionsInPriorPeriod(_ range: TimeChartRange) -> [CardioSessionModel] {
        guard range != .all,
              let start = calendar.date(byAdding: .weekOfYear, value: -range.weekCount, to: now),
              let priorStart = calendar.date(byAdding: .weekOfYear, value: -2 * range.weekCount, to: now) else { return [] }
        return completed
            .filter { $0.startedAt >= priorStart && $0.startedAt < start }
            .flatMap { $0.cardioSessions }
    }

    struct CardioBests {
        var longestSeconds: Int?
        var longestDistanceMeters: Double?
        var bestPaceMinutesPerKm: Double?
    }

    func cardioBests(in range: TimeChartRange) -> CardioBests {
        var bests = CardioBests()
        for item in cardioSessions(in: range) {
            if let seconds = item.session.durationSeconds, seconds > (bests.longestSeconds ?? 0) {
                bests.longestSeconds = seconds
            }
            if let meters = item.session.distanceMeters, meters > (bests.longestDistanceMeters ?? 0) {
                bests.longestDistanceMeters = meters
            }
            if CardioKind.from(modality: item.session.modality).usesPace,
               let meters = item.session.distanceMeters, meters > 500,
               let seconds = item.session.durationSeconds, seconds > 0 {
                let pace = (Double(seconds) / 60) / (meters / 1000)
                if pace.isFinite, pace < (bests.bestPaceMinutesPerKm ?? .infinity) {
                    bests.bestPaceMinutesPerKm = pace
                }
            }
        }
        return bests
    }

    // MARK: - Monthly report

    struct MonthlyReport {
        var monthStart: Date
        var workouts: Int
        var durationSeconds: Int
        var volume: Double            // kg
        var workingSets: Int
        var reps: Int
        var cardioMinutes: Double
        var distanceMeters: Double
        var topMuscles: [MuscleShare]
        var topExercises: [ExerciseUsage]
        var recordsSet: Int
        // Deltas vs the previous calendar month (nil = no previous data).
        var workoutsDelta: Int?
        var volumeDelta: Double?
        var durationDelta: Int?
    }

    /// Months (start dates, newest first) that contain completed workouts.
    func monthsWithHistory() -> [Date] {
        var starts = Set<Date>()
        for workout in completed {
            if let start = calendar.dateInterval(of: .month, for: workout.startedAt)?.start {
                starts.insert(start)
            }
        }
        return starts.sorted(by: >)
    }

    func monthlyReport(for monthStart: Date) -> MonthlyReport {
        let current = monthTotals(for: monthStart)
        let previousStart = calendar.date(byAdding: .month, value: -1, to: monthStart)
        let previous = previousStart.map(monthTotals(for:))
        let hasPrevious = (previous?.workouts ?? 0) > 0

        return MonthlyReport(
            monthStart: monthStart,
            workouts: current.workouts,
            durationSeconds: current.durationSeconds,
            volume: current.volume,
            workingSets: current.sets,
            reps: current.reps,
            cardioMinutes: current.cardioMinutes,
            distanceMeters: current.distanceMeters,
            topMuscles: Array(muscleShares(inMonth: monthStart).prefix(3)),
            topExercises: topExercises(inMonth: monthStart, limit: 3),
            recordsSet: recordsSet(inMonth: monthStart),
            workoutsDelta: hasPrevious ? current.workouts - (previous?.workouts ?? 0) : nil,
            volumeDelta: hasPrevious ? current.volume - (previous?.volume ?? 0) : nil,
            durationDelta: hasPrevious ? current.durationSeconds - (previous?.durationSeconds ?? 0) : nil
        )
    }

    private func workouts(inMonth monthStart: Date) -> [WorkoutModel] {
        guard let interval = calendar.dateInterval(of: .month, for: monthStart) else { return [] }
        return completed.filter { interval.contains($0.startedAt) }
    }

    private func monthTotals(for monthStart: Date) -> (workouts: Int, durationSeconds: Int, volume: Double, sets: Int, reps: Int, cardioMinutes: Double, distanceMeters: Double) {
        let month = workouts(inMonth: monthStart)
        let summaries = month.map(summary(for:))
        let cardioMinutes = month.flatMap(\.cardioSessions).reduce(0.0) { $0 + Double($1.durationSeconds ?? 0) / 60 }
        let distance = month.flatMap(\.cardioSessions).reduce(0.0) { $0 + ($1.distanceMeters ?? 0) }
        return (
            month.count,
            summaries.reduce(0) { $0 + $1.durationSeconds },
            summaries.reduce(0) { $0 + $1.volume },
            summaries.reduce(0) { $0 + $1.sets },
            summaries.reduce(0) { $0 + $1.reps },
            cardioMinutes,
            distance
        )
    }

    private func muscleShares(inMonth monthStart: Date) -> [MuscleShare] {
        let byID = exerciseByIDPublic
        var entries: [(set: SetEntry, exercise: ExerciseInfo)] = []
        for workout in workouts(inMonth: monthStart) {
            for we in workout.exercises {
                guard let exercise = byID[we.exerciseID], !exercise.isCardio else { continue }
                for set in we.sets where set.completedAt != nil {
                    entries.append((set.domainEntry, exercise.domainInfo))
                }
            }
        }
        let totals = MuscleVolume.weeklyVolume(entries)
        let grand = totals.values.reduce(0, +)
        guard grand > 0 else { return [] }
        return totals
            .map { MuscleShare(muscle: $0.key, sets: $0.value, fraction: $0.value / grand) }
            .sorted { $0.sets > $1.sets }
    }

    private func topExercises(inMonth monthStart: Date, limit: Int) -> [ExerciseUsage] {
        let byID = exerciseByIDPublic
        var sets: [UUID: Int] = [:]
        var volume: [UUID: Double] = [:]
        var sessions: [UUID: Set<UUID>] = [:]
        for workout in workouts(inMonth: monthStart) {
            for we in workout.exercises {
                guard let exercise = byID[we.exerciseID], !exercise.isCardio else { continue }
                let done = we.sets.filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
                guard !done.isEmpty else { continue }
                sets[we.exerciseID, default: 0] += done.count
                volume[we.exerciseID, default: 0] += done.reduce(0) { $0 + ($1.totalVolume ?? 0) }
                sessions[we.exerciseID, default: []].insert(workout.id)
            }
        }
        return sets
            .compactMap { id, count -> ExerciseUsage? in
                guard let exercise = byID[id] else { return nil }
                return ExerciseUsage(id: id, name: exercise.name, workingSets: count, volume: volume[id] ?? 0, sessions: sessions[id]?.count ?? 0)
            }
            .sorted { $0.workingSets > $1.workingSets }
            .prefix(limit)
            .map { $0 }
    }

    /// How many of the user's *current* all-time records were set during the
    /// month — "records that still stand".
    private func recordsSet(inMonth monthStart: Date) -> Int {
        guard let interval = calendar.dateInterval(of: .month, for: monthStart) else { return 0 }
        let exerciseIDs = Set(workouts(inMonth: monthStart).flatMap { $0.exercises.map(\.exerciseID) })
        var count = 0
        for id in exerciseIDs {
            for best in PersonalRecords.allTimeBests(for: id, in: workouts) where interval.contains(best.date) {
                count += 1
            }
        }
        return count
    }

    // MARK: - Internal access

    /// `exerciseByID` equivalent usable from this extension (the stored one is
    /// private to the main file).
    private var exerciseByIDPublic: [UUID: ExerciseLibraryModel] {
        Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}
