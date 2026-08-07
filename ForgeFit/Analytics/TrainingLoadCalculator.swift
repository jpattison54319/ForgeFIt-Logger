import Foundation
import ForgeCore
import ForgeData

/// Descriptive training history on a shared load-point scale. A genuine
/// whole-session CR10 rating is always preferred (duration minutes × session
/// RPE). When it is absent, detailed strength sets, cardio effort, and recorded
/// heart-rate zones provide an explicitly estimated fallback.
nonisolated struct TrainingLoadComparison: Equatable {
    enum BaselineState: Equatable {
        case building
        case ready
        case noRecentLoad
        /// Six complete prior weeks exist, but their median is zero; a ratio
        /// would be undefined and misleading.
        case sparseBaseline
    }

    let state: BaselineState
    let recentLoad: Double
    let baselineWeeklyLoad: Double
    let recentStrengthLoad: Double
    let recentCardioLoad: Double
    let baselineDaysAvailable: Int
    let recentSessionCount: Int
    let comparisonSessionCount: Int
    let estimatedEffortSessionCount: Int
    let baselineIQRLower: Double?
    let baselineIQRUpper: Double?
    let baselineWeekCount: Int

    var delta: Double { recentLoad - baselineWeeklyLoad }

    var ratio: Double? {
        guard state == .ready, baselineWeeklyLoad > 0 else { return nil }
        return recentLoad / baselineWeeklyLoad
    }

    var baselineDaysRemaining: Int {
        max(0, 42 - baselineDaysAvailable)
    }
}

nonisolated struct TrainingLoadEstimate: Equatable {
    var strength: Double = 0
    var cardio: Double = 0
    var effortWasEstimated = false

    var total: Double { strength + cardio }
}

/// Shared load math for Recovery and same-day Strain. Keeping the estimator
/// here prevents Apple Health, cardio, and detailed strength logs from
/// silently using incompatible units.
nonisolated struct TrainingLoadCalculator {
    let workouts: [WorkoutModel]
    var calendar = Calendar.current
    var now = Date()
    var hrZoneConfig = HRZoneConfigStore.load()

    static let methodID = "hybrid_session_load_v3"

    /// Neutral estimate used only when a completed component has no usable
    /// effort signal. This is a product convention, not a claimed measured RPE.
    private static let defaultEffort = 6.0

    /// Calibration convention: 16 straight sets at RPE 8 produce 560 points,
    /// matching a representative 70-minute session rated 8 on CR10.
    private static let pointsPerEffectiveSet = 35.0

    /// Used only to allocate otherwise duration-less cardio inside a mixed
    /// session; it does not inflate strength load because strength is set-based.
    private static let minutesPerEffectiveSet = 4.0

    var completedWorkouts: [WorkoutModel] {
        let candidates = workouts.filter {
            $0.endedAt != nil && $0.deletedAt == nil && $0.startedAt <= now
        }
        var unique: [WorkoutModel] = []
        var indexByHealthUUID: [UUID: Int] = [:]

        for workout in candidates {
            guard let healthUUID = healthUUID(for: workout) else {
                unique.append(workout)
                continue
            }
            if let index = indexByHealthUUID[healthUUID] {
                if richness(of: workout) > richness(of: unique[index]) {
                    unique[index] = workout
                }
            } else {
                indexByHealthUUID[healthUUID] = unique.count
                unique.append(workout)
            }
        }
        return unique.sorted { $0.startedAt < $1.startedAt }
    }

    func comparison() -> TrainingLoadComparison {
        let today = calendar.startOfDay(for: now)
        var recent = TrainingLoadEstimate()
        var recentSessionCount = 0
        var comparisonSessionCount = 0
        var estimatedEffortSessionCount = 0
        var oldestAge = -1
        var loadByAge: [Int: Double] = [:]

        for workout in completedWorkouts {
            let day = calendar.startOfDay(for: workout.startedAt)
            guard let age = calendar.dateComponents([.day], from: day, to: today).day,
                  age >= 0 else { continue }
            oldestAge = max(oldestAge, age)
            // Recent seven days plus at most eight complete prior weeks.
            guard age <= 62 else { continue }

            let estimate = sessionEstimate(workout)
            guard estimate.total > 0 else { continue }

            comparisonSessionCount += 1
            if estimate.effortWasEstimated { estimatedEffortSessionCount += 1 }
            loadByAge[age, default: 0] += estimate.total
            if age <= 6 {
                recent.strength += estimate.strength
                recent.cardio += estimate.cardio
                recentSessionCount += 1
            }
        }

        let baselineDays = min(56, max(0, oldestAge - 6))
        let completeWeekCount = min(8, baselineDays / 7)
        let weeklyLoads = (0..<completeWeekCount).map { week in
            (0..<7).reduce(0.0) { total, offset in
                total + loadByAge[7 + week * 7 + offset, default: 0]
            }
        }
        let baselineWeekly = median(weeklyLoads) ?? 0
        let iqrLower = quantile(weeklyLoads, probability: 0.25)
        let iqrUpper = quantile(weeklyLoads, probability: 0.75)
        let state: TrainingLoadComparison.BaselineState
        if completeWeekCount < 6 {
            state = .building
        } else if weeklyLoads.allSatisfy({ $0 <= 0 }) && recent.total <= 0 {
            state = .noRecentLoad
        } else if baselineWeekly <= 0 {
            state = .sparseBaseline
        } else {
            state = .ready
        }

        return TrainingLoadComparison(
            state: state,
            recentLoad: recent.total,
            baselineWeeklyLoad: baselineWeekly,
            recentStrengthLoad: recent.strength,
            recentCardioLoad: recent.cardio,
            baselineDaysAvailable: baselineDays,
            recentSessionCount: recentSessionCount,
            comparisonSessionCount: comparisonSessionCount,
            estimatedEffortSessionCount: estimatedEffortSessionCount,
            baselineIQRLower: iqrLower,
            baselineIQRUpper: iqrUpper,
            baselineWeekCount: completeWeekCount
        )
    }

    func dailyLoads(days: Int) -> [Double] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        var buckets = [Double](repeating: 0, count: days)
        for workout in completedWorkouts {
            let day = calendar.startOfDay(for: workout.startedAt)
            guard let age = calendar.dateComponents([.day], from: day, to: today).day,
                  age >= 0, age < days else { continue }
            buckets[age] += sessionEstimate(workout).total
        }
        return buckets
    }

    func sessionEstimate(_ workout: WorkoutModel) -> TrainingLoadEstimate {
        let workingSets = workout.exercises.flatMap(\.sets).filter {
            $0.completedAt != nil && $0.setType.countsAsWorkingVolume
        }
        let activeCardio = workout.cardioSessions.filter {
            !$0.isYogaSession || !$0.resolvedYogaStyle.isRestorative
        }

        // A whole-session rating is the preferred common currency. A mixed
        // session remains one dose and is never summed again by component.
        if let rpe = workout.wholeSessionRPE {
            let minutes = durationMinutes(workout)
            guard minutes > 0 else { return TrainingLoadEstimate() }
            let load = minutes * clampedEffort(rpe)
            let isStrength = !workingSets.isEmpty
                || (activeCardio.isEmpty && looksStrengthLike(workout))
            return isStrength
                ? TrainingLoadEstimate(strength: load)
                : TrainingLoadEstimate(cardio: load)
        }

        guard !workingSets.isEmpty || !activeCardio.isEmpty else {
            return detailLessEstimate(workout)
        }

        var result = TrainingLoadEstimate(effortWasEstimated: true)
        if !workingSets.isEmpty {
            result.strength = strengthLoad(workingSets)
        }
        for session in activeCardio {
            let minutes = cardioMinutes(
                session,
                workout: workout,
                activeCardio: activeCardio,
                workingSets: workingSets
            )
            result.cardio += minutes * cardioEffort(session, workout: workout)
        }
        return result
    }

    /// Component fallback for strength. Logged set RPE wins, then logged RIR;
    /// otherwise the neutral default is used. Effective-set weighting preserves
    /// the existing drop/myo-rep/cluster conventions. Equipment category is not
    /// multiplied: free weights are not universally more fatiguing than machines.
    private func strengthLoad(_ workingSets: [SetModel]) -> Double {
        workingSets.reduce(0.0) { total, set in
            let effort: Double
            if let rpe = set.rpe {
                effort = clampedEffort(rpe)
            } else if let rir = set.rir {
                effort = clampedEffort(10 - Double(rir))
            } else {
                effort = Self.defaultEffort
            }
            return total
                + Self.pointsPerEffectiveSet
                * VolumeMath.effectiveSetCount(set.domainEntry)
                * effortWeight(effort)
        }
    }

    /// RPE 8 anchors one effective set at 1.0. The bounded shape is a product
    /// heuristic used only by the fallback, not a biological fatigue equation.
    private func effortWeight(_ effort: Double) -> Double {
        let value = clampedEffort(effort)
        return value <= 8
            ? max(0.55, 1 + (value - 8) * 0.15)
            : min(1.45, 1 + (value - 8) * 0.225)
    }

    /// Imported/detail-less workouts may still contribute from duration. Empty
    /// local shells remain zero so an abandoned workout is not invented as load.
    private func detailLessEstimate(_ workout: WorkoutModel) -> TrainingLoadEstimate {
        let minutes = durationMinutes(workout)
        guard minutes > 0,
              workout.hkWorkoutUUID != nil || workout.isImportedHistory else {
            return TrainingLoadEstimate()
        }
        let measuredEffort = zoneWeightedEffort(workout.hrZoneSeconds)
            ?? workout.avgHR.map(effort(forHeartRate:))
        // A title and duration do not establish the effort of an imported
        // strength session. Keep it out of the shared load scale unless the
        // import carries heart-rate evidence or a whole-session CR10 rating.
        guard let effort = measuredEffort
            ?? (looksStrengthLike(workout) ? nil : (looksMindBodyLike(workout) ? 3 : Self.defaultEffort)) else {
            return TrainingLoadEstimate()
        }
        let load = minutes * effort
        return looksStrengthLike(workout)
            ? TrainingLoadEstimate(strength: load, effortWasEstimated: true)
            : TrainingLoadEstimate(cardio: load, effortWasEstimated: true)
    }

    private func cardioMinutes(
        _ session: CardioSessionModel,
        workout: WorkoutModel,
        activeCardio: [CardioSessionModel],
        workingSets: [SetModel]
    ) -> Double {
        if let seconds = session.durationSeconds, seconds > 0 {
            return Double(seconds) / 60
        }
        let timedCardioMinutes = activeCardio.reduce(0.0) {
            $0 + max(0, Double($1.durationSeconds ?? 0) / 60)
        }
        let setMinutes = workingSets.reduce(0.0) {
            $0 + VolumeMath.effectiveSetCount($1.domainEntry)
        } * Self.minutesPerEffectiveSet
        let durationlessCount = max(1, activeCardio.count { ($0.durationSeconds ?? 0) <= 0 })
        let leftover = durationMinutes(workout) - timedCardioMinutes - setMinutes
        return max(0, leftover / Double(durationlessCount))
    }

    private func cardioEffort(_ session: CardioSessionModel, workout: WorkoutModel) -> Double {
        if let effort = session.effort {
            return clampedEffort(Double(effort))
        }
        if let effort = zoneWeightedEffort(session.hrZoneSeconds) {
            return effort
        }
        if let heartRate = session.avgHR ?? workout.avgHR {
            return effort(forHeartRate: heartRate)
        }
        if session.isYogaSession {
            return switch session.resolvedYogaStyle {
            case .power: 5
            case .vinyasa: 4
            default: 3
            }
        }
        return Self.defaultEffort
    }

    private func zoneWeightedEffort(_ zoneSeconds: [Int]) -> Double? {
        let totalSeconds = zoneSeconds.reduce(0) { $0 + max(0, $1) }
        guard totalSeconds > 0 else { return nil }
        let weighted = zoneSeconds.enumerated().reduce(0.0) { total, pair in
            total + Double(max(0, pair.element)) * effort(forZone: pair.offset + 1)
        }
        return weighted / Double(totalSeconds)
    }

    private func effort(forHeartRate heartRate: Int) -> Double {
        effort(forZone: hrZoneConfig.zone(for: heartRate))
    }

    private func effort(forZone zone: Int) -> Double {
        switch zone {
        case ...1: 3
        case 2: 4
        case 3: 6
        case 4: 8
        default: 9
        }
    }

    private func looksStrengthLike(_ workout: WorkoutModel) -> Bool {
        let title = (workout.title ?? "").lowercased()
        return title.contains("strength")
            || title.contains("weight")
            || title.contains("resistance")
            || title.contains("core")
            || title.contains("pilates")
    }

    private func looksMindBodyLike(_ workout: WorkoutModel) -> Bool {
        let title = (workout.title ?? "").lowercased()
        return title.contains("yoga")
            || title.contains("stretch")
            || title.contains("mind and body")
    }

    func durationMinutes(_ workout: WorkoutModel) -> Double {
        if let endedAt = workout.endedAt {
            let effectiveEnd = min(endedAt, now)
            let elapsed = effectiveEnd.timeIntervalSince(workout.startedAt) / 60
            if elapsed > 0, elapsed <= 24 * 60 { return elapsed }
        }
        return workout.cardioSessions.reduce(0) {
            $0 + max(0, Double($1.durationSeconds ?? 0) / 60)
        }
    }

    private func clampedEffort(_ effort: Double) -> Double {
        min(10, max(0, effort))
    }

    private func healthUUID(for workout: WorkoutModel) -> UUID? {
        workout.hkWorkoutUUID ?? workout.cardioSessions.compactMap(\.hkWorkoutUUID).first
    }

    private func richness(of workout: WorkoutModel) -> Int {
        let workingSets = workout.exercises.flatMap(\.sets).filter {
            $0.completedAt != nil && $0.setType.countsAsWorkingVolume
        }.count
        var score = workingSets * 100 + workout.cardioSessions.count * 20
        score += workout.exercises.count * 5
        score += workout.avgHR == nil ? 0 : 3
        score += workout.hrZoneSeconds.isEmpty ? 0 : 2
        score += workout.isImportedHistory ? 0 : 1
        return score
    }

    private func median(_ values: [Double]) -> Double? {
        quantile(values, probability: 0.5)
    }

    private func quantile(_ values: [Double], probability: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = min(1, max(0, probability)) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }
}
