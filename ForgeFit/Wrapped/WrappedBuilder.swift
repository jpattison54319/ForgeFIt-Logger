import ForgeCore
import ForgeData
import Foundation

/// Builds the frozen `WrappedPayload` for a month (or year) from plain model
/// arrays. Pure and deterministic — inject `calendar`/dates, no HealthKit, no
/// SwiftData context — so every page and edge case is unit-testable.
///
/// Returns nil for a period with zero completed workouts: no report, no Home
/// card, no notification (an empty story is worse than none). Periods with
/// PARTIAL data still produce a report — pages whose data is absent are
/// simply not emitted.
struct WrappedBuilder {
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    /// Daily readiness/recovery series covering (at least) the period — the
    /// caller passes whatever is available; recovery-derived insights degrade
    /// gracefully when it's empty.
    var healthMetrics: [RecoveryEngine.DailyHealthMetric] = []
    var calendar = Calendar.current

    /// All user-facing date text must format in the builder's calendar's
    /// timezone — `.formatted(.dateTime...)` alone uses the device timezone,
    /// which mislabels month boundaries (June 1 UTC reads as "May" in
    /// US-Eastern) whenever they disagree.
    private var dateStyle: Date.FormatStyle {
        Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    }

    // MARK: - Monthly

    func buildMonth(starting monthStart: Date) -> WrappedPayload? {
        guard let interval = calendar.dateInterval(of: .month, for: monthStart) else { return nil }
        let analytics = TrainingAnalytics(workouts: workouts, exercises: exercises, calendar: calendar, now: interval.end)
        let month = analytics.completed.filter { interval.contains($0.startedAt) }
        guard !month.isEmpty else { return nil }

        let report = analytics.monthlyReport(for: interval.start)
        let monthName = interval.start.formatted(dateStyle.month(.wide))
        let year = calendar.component(.year, from: interval.start)
        let activeDayNumbers = activeDays(in: month)
        let mix = trainingMix(of: month)
        let strength = strengthProgress(month: month, interval: interval, recordsSet: report.recordsSet)
        let insights = WrappedInsights.evaluate(ingredients(
            month: month, report: report, mix: mix,
            activeDays: activeDayNumbers.count,
            strength: strength, interval: interval
        ))

        var pages: [WrappedPage] = []
        pages.append(.cover(.init(
            title: "Your \(monthName) Wrapped",
            subtitle: "One month. \(month.count) session\(month.count == 1 ? "" : "s"). Let's look at what you built."
        )))
        pages.append(.identity(identity(mix: mix, activeDays: activeDayNumbers.count)))
        pages.append(.bigStats(.init(
            workouts: report.workouts,
            trainingMinutes: report.durationSeconds / 60,
            activeDays: activeDayNumbers.count,
            totalVolumeKg: report.volume
        )))
        if mix.strengthCount > 0 && mix.cardioCount > 0 {
            pages.append(.trainingMix(mix))
        }
        pages.append(.calendar(.init(year: year, month: calendar.component(.month, from: interval.start), activeDays: activeDayNumbers)))
        if month.count >= 4, let best = strongestWeek(in: month, interval: interval) {
            pages.append(.strongestWeek(best))
        }
        if let signature = report.topExercises.first {
            pages.append(.signatureExercise(.init(name: signature.name, sets: signature.workingSets, sessions: signature.sessions)))
        }
        if let muscles = muscleMap(month: month) {
            pages.append(.muscleMap(muscles))
        }
        if let strength {
            pages.append(.strengthProgress(strength))
        }
        if let cardio = cardioEngine(of: month, report: report) {
            pages.append(.cardioEngine(cardio))
        }
        if let hr = heartRateStory(of: month) {
            pages.append(.heartRate(hr))
        }
        if let boss = bossBattle(of: month) {
            pages.append(.bossBattle(boss))
        }
        if let improved = insights.improved {
            pages.append(.improved(.init(headline: improved.headline, detail: improved.detail)))
        }
        if let heldBack = insights.heldBack {
            pages.append(.heldBack(.init(headline: heldBack.headline, detail: heldBack.detail)))
        }
        if let delta = comparison(report: report, interval: interval) {
            pages.append(.comparison(delta))
        }
        pages.append(.nextFocus(insights.focus))
        pages.append(.recap(.init(
            title: "\(monthName) \(year)",
            workouts: report.workouts,
            trainingMinutes: report.durationSeconds / 60,
            volumeKg: report.volume,
            activeDays: activeDayNumbers.count,
            identityLabel: identity(mix: mix, activeDays: activeDayNumbers.count).label,
            highlight: report.recordsSet > 0 ? "\(report.recordsSet) record\(report.recordsSet == 1 ? "" : "s") set" : nil
        )))

        return WrappedPayload(
            title: "\(monthName) Wrapped",
            periodLabel: "\(monthName) \(year)",
            pages: pages
        )
    }

    // MARK: - Yearly

    func buildYear(_ year: Int) -> WrappedPayload? {
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        guard let yearStart = calendar.date(from: components),
              let yearInterval = calendar.dateInterval(of: .year, for: yearStart) else { return nil }
        let analytics = TrainingAnalytics(workouts: workouts, exercises: exercises, calendar: calendar, now: yearInterval.end)
        let inYear = analytics.completed.filter { yearInterval.contains($0.startedAt) }
        guard !inYear.isEmpty else { return nil }

        let totalMinutes = inYear.reduce(0) { total, w in
            total + Int((w.endedAt ?? w.startedAt).timeIntervalSince(w.startedAt) / 60)
        }
        let totalVolume = inYear.reduce(0.0) { $0 + ($1.totalVolume ?? 0) }
        let activeDayCount = Set(inYear.map { calendar.startOfDay(for: $0.startedAt) }).count
        let mix = trainingMix(of: inYear)

        var pages: [WrappedPage] = []
        pages.append(.cover(.init(
            title: "Your \(year) Wrapped",
            subtitle: "A whole year in motion."
        )))
        pages.append(.bigStats(.init(
            workouts: inYear.count,
            trainingMinutes: totalMinutes,
            activeDays: activeDayCount,
            totalVolumeKg: totalVolume
        )))
        if let active = mostActiveMonth(of: inYear) {
            pages.append(.mostActiveMonth(active))
        }
        // Favorite exercise across the year.
        if let favorite = topExercise(of: inYear) {
            pages.append(.signatureExercise(favorite))
        }
        if let strength = strengthProgress(month: inYear, interval: yearInterval, recordsSet: recordsSet(in: inYear, interval: yearInterval)) {
            pages.append(.strengthProgress(strength))
        }
        if let cardio = cardioEngine(of: inYear, report: nil) {
            pages.append(.cardioEngine(cardio))
        }
        pages.append(.identity(identity(mix: mix, activeDays: activeDayCount, yearly: true)))
        if let top = topWorkouts(of: inYear) {
            pages.append(.topWorkouts(top))
        }
        let badges = yearBadges(inYear: inYear, activeDays: activeDayCount, totalVolume: totalVolume)
        if !badges.isEmpty {
            pages.append(.badges(.init(earned: badges)))
        }
        pages.append(.recap(.init(
            title: "\(year)",
            workouts: inYear.count,
            trainingMinutes: totalMinutes,
            volumeKg: totalVolume,
            activeDays: activeDayCount,
            identityLabel: identity(mix: mix, activeDays: activeDayCount, yearly: true).label,
            highlight: nil
        )))

        return WrappedPayload(
            title: "\(year) Wrapped",
            periodLabel: "\(year)",
            pages: pages
        )
    }

    // MARK: - Derivations

    private func activeDays(in month: [WorkoutModel]) -> [Int] {
        Set(month.map { calendar.component(.day, from: $0.startedAt) }).sorted()
    }

    private func trainingMix(of period: [WorkoutModel]) -> WrappedPage.TrainingMix {
        var strengthCount = 0, cardioCount = 0, yogaCount = 0
        var strengthMinutes = 0, cardioMinutes = 0, yogaMinutes = 0
        for workout in period {
            let minutes = Int((workout.endedAt ?? workout.startedAt).timeIntervalSince(workout.startedAt) / 60)
            if isPureYoga(workout) {
                yogaCount += 1
                yogaMinutes += minutes
            } else if isPureCardio(workout) {
                cardioCount += 1
                cardioMinutes += minutes
            } else {
                strengthCount += 1
                strengthMinutes += minutes
            }
        }
        return .init(
            strengthCount: strengthCount,
            cardioCount: cardioCount,
            strengthMinutes: strengthMinutes,
            cardioMinutes: cardioMinutes,
            yogaCount: yogaCount,
            yogaMinutes: yogaMinutes
        )
    }

    private func isPureCardio(_ workout: WorkoutModel) -> Bool {
        guard workout.cardioSessions.contains(where: { !$0.isYogaSession }) else { return false }
        return !workout.exercises.flatMap(\.sets).contains { $0.completedAt != nil }
    }

    /// All-yoga sessions, no completed strength sets, no real cardio.
    private func isPureYoga(_ workout: WorkoutModel) -> Bool {
        guard !workout.cardioSessions.isEmpty,
              workout.cardioSessions.allSatisfy(\.isYogaSession) else { return false }
        return !workout.exercises.flatMap(\.sets).contains { $0.completedAt != nil }
    }

    /// Calendar-week buckets inside the month; strongest by volume, then count.
    private func strongestWeek(in month: [WorkoutModel], interval: DateInterval) -> WrappedPage.StrongestWeek? {
        var byWeek: [Date: (count: Int, volume: Double)] = [:]
        for workout in month {
            guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: workout.startedAt)?.start else { continue }
            var bucket = byWeek[weekStart] ?? (0, 0)
            bucket.count += 1
            bucket.volume += workout.totalVolume ?? 0
            byWeek[weekStart] = bucket
        }
        guard let best = byWeek.max(by: { lhs, rhs in
            (lhs.value.volume, lhs.value.count) < (rhs.value.volume, rhs.value.count)
        }), best.value.count >= 2 else { return nil }
        let weekEnd = calendar.date(byAdding: .day, value: 6, to: best.key) ?? best.key
        let label = "\(best.key.formatted(dateStyle.month(.abbreviated).day())) – \(weekEnd.formatted(dateStyle.month(.abbreviated).day()))"
        return .init(weekLabel: label, workouts: best.value.count, volumeKg: best.value.volume)
    }

    /// Per-muscle fractional-set totals for the period — the same convention
    /// as weekly muscle volume (primary 1.0 / secondary 0.5 × effective sets).
    private func muscleTotals(of period: [WorkoutModel]) -> [String: Double] {
        let byID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var entries: [(set: SetEntry, exercise: ExerciseInfo)] = []
        for workout in period {
            for we in workout.exercises {
                guard let exercise = byID[we.exerciseID], !exercise.isCardio else { continue }
                for set in we.sets where set.completedAt != nil {
                    entries.append((set.domainEntry, exercise.domainInfo))
                }
            }
        }
        return MuscleVolume.weeklyVolume(entries)
    }

    private func muscleMap(month: [WorkoutModel]) -> WrappedPage.MuscleMap? {
        let totals = muscleTotals(of: month)
        guard totals.count >= 2 else { return nil }
        let sorted = totals.sorted { $0.value > $1.value }
        let most = sorted.prefix(3).map { WrappedPage.MuscleShareItem(muscle: $0.key, sets: $0.value) }
        let least = sorted.suffix(2).reversed().map { WrappedPage.MuscleShareItem(muscle: $0.key, sets: $0.value) }
        return .init(most: Array(most), least: Array(least))
    }

    /// Assembles the pure ingredient numbers the insights rules consume.
    private func ingredients(
        month: [WorkoutModel],
        report: TrainingAnalytics.MonthlyReport,
        mix: WrappedPage.TrainingMix,
        activeDays: Int,
        strength: WrappedPage.StrengthProgress?,
        interval: DateInterval
    ) -> WrappedInsights.Ingredients {
        let totals = muscleTotals(of: month)
        func categorySets(_ muscles: Set<String>) -> Double {
            totals.reduce(0) { sum, entry in
                muscles.contains(entry.key.lowercased()) ? sum + entry.value : sum
            }
        }
        let pushMuscles: Set<String> = ["chest", "shoulders", "triceps"]
        let pullMuscles: Set<String> = ["lats", "middle back", "traps", "biceps", "forearms", "neck"]

        let midpoint = interval.start.addingTimeInterval(interval.duration / 2)
        let firstHalf = month.filter { $0.startedAt < midpoint }
        let secondHalf = month.filter { $0.startedAt >= midpoint }
        func avgRPE(_ workouts: [WorkoutModel]) -> Double? {
            let values = workouts.flatMap(\.exercises).flatMap(\.sets)
                .filter { $0.completedAt != nil }
                .compactMap(\.rpe)
            guard values.count >= 3 else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
        func avgReadiness(_ workouts: [WorkoutModel]) -> Double? {
            let values = workouts.compactMap { $0.readinessAtStart.map(Double.init) }
            guard values.count >= 2 else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        return WrappedInsights.Ingredients(
            workouts: report.workouts,
            workoutsDelta: report.workoutsDelta,
            volumeKg: report.volume,
            volumeDeltaKg: report.volumeDelta,
            activeDays: activeDays,
            strengthCount: mix.strengthCount,
            cardioCount: mix.cardioCount,
            cardioMinutes: mix.cardioMinutes,
            zoneSeconds: zoneSeconds(of: month),
            pushSets: categorySets(pushMuscles),
            pullSets: categorySets(pullMuscles),
            recordsSet: report.recordsSet,
            bestE1RMGainKg: strength?.bestLiftE1RMGainKg,
            bestLiftName: strength?.bestLiftName,
            avgRPEFirstHalf: avgRPE(firstHalf),
            avgRPESecondHalf: avgRPE(secondHalf),
            readinessFirstHalf: avgReadiness(firstHalf),
            readinessSecondHalf: avgReadiness(secondHalf)
        )
    }

    /// Biggest e1RM improvement inside the period: best in-period e1RM vs the
    /// exercise's best BEFORE the period (only lifts with prior history —
    /// a first-ever lift isn't an "improvement").
    private func strengthProgress(month: [WorkoutModel], interval: DateInterval, recordsSet: Int) -> WrappedPage.StrengthProgress? {
        let prior = workouts.filter { $0.endedAt != nil && $0.deletedAt == nil && $0.startedAt < interval.start }
        var priorBest: [UUID: Double] = [:]
        for workout in prior {
            for we in workout.exercises {
                for set in we.sets where set.completedAt != nil {
                    if let e1rm = set.estimated1RM {
                        priorBest[we.exerciseID] = max(priorBest[we.exerciseID] ?? 0, e1rm)
                    }
                }
            }
        }
        var bestGain: (exerciseID: UUID, gain: Double)?
        for workout in month {
            for we in workout.exercises {
                guard let prior = priorBest[we.exerciseID], prior > 0 else { continue }
                for set in we.sets where set.completedAt != nil {
                    guard let e1rm = set.estimated1RM else { continue }
                    let gain = e1rm - prior
                    if gain > 0, gain > (bestGain?.gain ?? 0) {
                        bestGain = (we.exerciseID, gain)
                    }
                }
            }
        }
        let bestName = bestGain.flatMap { gain in exercises.first { $0.id == gain.exerciseID }?.name }
        guard recordsSet > 0 || bestGain != nil else { return nil }
        return .init(recordsSet: recordsSet, bestLiftName: bestName, bestLiftE1RMGainKg: bestGain?.gain)
    }

    private func zoneSeconds(of period: [WorkoutModel]) -> [Int] {
        var totals = [0, 0, 0, 0, 0]
        for session in period.flatMap(\.cardioSessions) where session.endedAt != nil {
            let zones = session.hrZoneSeconds.isEmpty
                ? CardioMetrics.estimatedZoneSecondsArray(avgHR: session.avgHR, durationSeconds: session.durationSeconds)
                : session.hrZoneSeconds
            for (index, seconds) in zones.prefix(5).enumerated() {
                totals[index] += seconds
            }
        }
        return totals
    }

    private func cardioEngine(of period: [WorkoutModel], report: TrainingAnalytics.MonthlyReport?) -> WrappedPage.CardioEngine? {
        let sessions = period.flatMap(\.cardioSessions).filter { $0.endedAt != nil }
        guard !sessions.isEmpty else { return nil }
        let minutes = sessions.reduce(0) { $0 + ($1.durationSeconds ?? 0) } / 60
        let distance = sessions.reduce(0.0) { $0 + ($1.distanceMeters ?? 0) }
        let longest = sessions.max { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }
        return .init(
            minutes: minutes,
            distanceMeters: distance,
            zoneSeconds: zoneSeconds(of: period),
            longestSessionMinutes: longest?.durationSeconds.map { $0 / 60 },
            longestSessionKind: longest.map { CardioKind.from(modality: $0.modality).title }
        )
    }

    private func heartRateStory(of period: [WorkoutModel]) -> WrappedPage.HeartRate? {
        let withHR = period.filter { $0.maxHR != nil || $0.avgHR != nil }
        guard let highest = withHR.max(by: { ($0.maxHR ?? $0.avgHR ?? 0) < ($1.maxHR ?? $1.avgHR ?? 0) }),
              let peak = highest.maxHR ?? highest.avgHR else { return nil }
        let averages = withHR.compactMap(\.avgHR)
        let average = averages.isEmpty ? nil : averages.reduce(0, +) / averages.count
        return .init(
            highestWorkoutHR: peak,
            highestWorkoutTitle: highest.title ?? "Workout",
            averageWorkoutHR: average
        )
    }

    /// Hardest session: effort (avg RPE, default 7) × duration, volume as the
    /// tiebreaker — deliberately simple and explainable.
    private func bossBattle(of period: [WorkoutModel]) -> WrappedPage.BossBattle? {
        guard period.count >= 2 else { return nil }
        func avgRPE(_ workout: WorkoutModel) -> Double? {
            let values = workout.exercises.flatMap(\.sets).filter { $0.completedAt != nil }.compactMap(\.rpe)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
        func score(_ workout: WorkoutModel) -> Double {
            let minutes = (workout.endedAt ?? workout.startedAt).timeIntervalSince(workout.startedAt) / 60
            return (avgRPE(workout) ?? 7) * minutes + (workout.totalVolume ?? 0) / 1_000
        }
        guard let boss = period.max(by: { score($0) < score($1) }) else { return nil }
        return .init(
            workoutTitle: boss.title ?? "Workout",
            dayLabel: boss.startedAt.formatted(dateStyle.month(.abbreviated).day()),
            durationMinutes: Int((boss.endedAt ?? boss.startedAt).timeIntervalSince(boss.startedAt) / 60),
            volumeKg: boss.totalVolume ?? 0,
            avgRPE: avgRPE(boss)
        )
    }

    private func comparison(report: TrainingAnalytics.MonthlyReport, interval: DateInterval) -> WrappedPage.Comparison? {
        guard let workoutsDelta = report.workoutsDelta,
              let volumeDelta = report.volumeDelta,
              let durationDelta = report.durationDelta,
              let previousStart = calendar.date(byAdding: .month, value: -1, to: interval.start) else { return nil }
        return .init(
            workoutsDelta: workoutsDelta,
            volumeDeltaKg: volumeDelta,
            minutesDelta: durationDelta / 60,
            previousLabel: previousStart.formatted(dateStyle.month(.wide))
        )
    }

    private func identity(mix: WrappedPage.TrainingMix, activeDays: Int, yearly: Bool = false) -> WrappedPage.Identity {
        let total = max(1, mix.strengthCount + mix.cardioCount)
        let strengthShare = Double(mix.strengthCount) / Double(total)
        let base: (label: String, line: String)
        if strengthShare >= 0.75 {
            base = ("Iron Architect", "You built this \(yearly ? "year" : "month") out of heavy sets.")
        } else if strengthShare <= 0.25 {
            base = ("Engine Builder", "Your aerobic engine did the heavy lifting.")
        } else {
            base = ("Hybrid Builder", "Strength and engine work, side by side.")
        }
        let threshold = yearly ? 200 : 20
        if activeDays >= threshold {
            return .init(label: "Relentless \(base.label)", line: "\(activeDays) active days. " + base.line)
        }
        return .init(label: base.label, line: base.line)
    }

    // MARK: - Yearly-only derivations

    private func mostActiveMonth(of inYear: [WorkoutModel]) -> WrappedPage.MostActiveMonth? {
        var byMonth: [Date: Int] = [:]
        for workout in inYear {
            if let start = calendar.dateInterval(of: .month, for: workout.startedAt)?.start {
                byMonth[start, default: 0] += 1
            }
        }
        guard byMonth.count >= 2, let best = byMonth.max(by: { $0.value < $1.value }) else { return nil }
        return .init(monthName: best.key.formatted(dateStyle.month(.wide)), workouts: best.value)
    }

    private func topExercise(of period: [WorkoutModel]) -> WrappedPage.SignatureExercise? {
        let byID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var sets: [UUID: Double] = [:]
        var sessions: [UUID: Set<UUID>] = [:]
        for workout in period {
            for we in workout.exercises {
                guard let exercise = byID[we.exerciseID], !exercise.isCardio else { continue }
                let done = we.sets.filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
                guard !done.isEmpty else { continue }
                sets[we.exerciseID, default: 0] += done.reduce(0) { $0 + VolumeMath.effectiveSetCount($1.domainEntry) }
                sessions[we.exerciseID, default: []].insert(workout.id)
            }
        }
        guard let top = sets.max(by: { $0.value < $1.value }),
              let name = byID[top.key]?.name else { return nil }
        return .init(name: name, sets: top.value, sessions: sessions[top.key]?.count ?? 0)
    }

    private func topWorkouts(of inYear: [WorkoutModel]) -> WrappedPage.TopWorkouts? {
        let ranked = inYear
            .filter { ($0.totalVolume ?? 0) > 0 }
            .sorted { ($0.totalVolume ?? 0) > ($1.totalVolume ?? 0) }
            .prefix(5)
        guard ranked.count >= 3 else { return nil }
        return .init(entries: ranked.map {
            .init(
                title: $0.title ?? "Workout",
                dayLabel: $0.startedAt.formatted(dateStyle.month(.abbreviated).day()),
                volumeKg: $0.totalVolume ?? 0
            )
        })
    }

    private func recordsSet(in period: [WorkoutModel], interval: DateInterval) -> Int {
        var count = 0
        let exerciseIDs = Set(period.flatMap { $0.exercises.map(\.exerciseID) })
        for exerciseID in exerciseIDs {
            for best in PersonalRecords.allTimeBests(for: exerciseID, in: workouts) where interval.contains(best.date) {
                count += 1
            }
        }
        return count
    }

    private func yearBadges(inYear: [WorkoutModel], activeDays: Int, totalVolume: Double) -> [String] {
        var badges: [String] = []
        if inYear.count >= 100 { badges.append("Century Club — 100+ workouts") }
        else if inYear.count >= 50 { badges.append("Fifty Strong — 50+ workouts") }
        if activeDays >= 150 { badges.append("Everyday Athlete — 150+ active days") }
        if totalVolume >= 500_000 { badges.append("Half-Million Club — 500k kg lifted") }
        else if totalVolume >= 100_000 { badges.append("Heavy Hauler — 100k kg lifted") }
        let cardioMinutes = inYear.flatMap(\.cardioSessions).reduce(0) { $0 + ($1.durationSeconds ?? 0) } / 60
        if cardioMinutes >= 3_000 { badges.append("Engine Room — 50+ cardio hours") }
        return badges
    }
}
