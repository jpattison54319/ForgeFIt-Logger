import Foundation
import ForgeCore
import ForgeData

/// A descriptive comparison of recent training against the preceding four
/// weeks. Load points use one scale for every source:
///
/// - **Strength** accumulates per completed working set — an effective-set
///   count (myo-reps, drop sets, and clusters weighted per `VolumeMath`)
///   scaled by proximity to failure. Set-based load keeps long rest periods
///   from inflating strength stress and lets intensity techniques count for
///   the extra near-failure work they actually contain.
/// - **Cardio** is minutes × 0...10 effort, preferring a logged session
///   effort (Foster's session RPE), then time-in-zone weighting, then the
///   average-HR zone.
/// - **Detail-less imports** fall back to duration × estimated effort.
struct TrainingLoadComparison: Equatable {
    enum BaselineState: Equatable {
        case building
        case ready
        case noRecentLoad
        /// A full 28-day window exists but carries too little load for a
        /// percentage against it to be honest (a near-zero denominator turns
        /// any normal week into a triple-digit "spike" artifact).
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

    var ratio: Double? {
        guard state == .ready, baselineWeeklyLoad > 0 else { return nil }
        return recentLoad / baselineWeeklyLoad
    }

    var baselineDaysRemaining: Int {
        max(0, 28 - baselineDaysAvailable)
    }
}

struct TrainingLoadEstimate: Equatable {
    var strength: Double = 0
    var cardio: Double = 0
    var effortWasEstimated = false

    var total: Double { strength + cardio }
}

/// Shared load math for Recovery and same-day Strain. Keeping the estimator
/// here prevents Apple Health, cardio, and detailed strength logs from
/// silently using incompatible units.
struct TrainingLoadCalculator {
    let workouts: [WorkoutModel]
    var calendar = Calendar.current
    var now = Date()
    /// Mirrors `WorkoutEffortPolicy`: with failure training enabled, a
    /// completed working set with no logged effort IS a failure set (RPE 10 /
    /// RIR 0) — the same convention the finish path stamps onto new workouts.
    /// Applying it here keeps imported history (which predates the stamp) on
    /// the same scale as freshly logged sessions, instead of quietly reading
    /// a failure-trained baseline as "effort 6" and recent weeks as 10.
    var assumesFailureWhenUnlogged = WorkoutEffortPolicy.current().defaultsToFailure

    private static let defaultEffort = 6.0

    /// Load points one straight working set at RPE 8 is worth. Calibrated so
    /// a fully logged canonical hypertrophy session (16 working sets at
    /// RPE 8 in ~70 minutes) lands where duration × effort would put it,
    /// keeping set-based strength and minute-based cardio commensurate.
    /// A versioned convention — changing it moves every golden vector.
    private static let pointsPerEffectiveSet = 35.0

    /// Roughly one easy half-hour session per week (30 min × effort 4).
    /// A 28-day window averaging under this is a denominator artifact, not a
    /// baseline.
    private static let minBaselineWeeklyLoad = 120.0

    /// Minutes of session time one effective set is assumed to occupy, used
    /// only to hand leftover time to duration-less cardio in mixed workouts.
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
        var baselineTotal = 0.0
        var recentSessionCount = 0
        var comparisonSessionCount = 0
        var estimatedEffortSessionCount = 0
        var oldestAge = -1

        for workout in completedWorkouts {
            let day = calendar.startOfDay(for: workout.startedAt)
            guard let age = calendar.dateComponents([.day], from: day, to: today).day,
                  age >= 0 else { continue }
            oldestAge = max(oldestAge, age)

            guard age <= 34 else { continue }
            let estimate = sessionEstimate(workout)
            guard estimate.total > 0 else { continue }

            comparisonSessionCount += 1
            if estimate.effortWasEstimated { estimatedEffortSessionCount += 1 }
            if age <= 6 {
                recent.strength += estimate.strength
                recent.cardio += estimate.cardio
                recentSessionCount += 1
            } else {
                baselineTotal += estimate.total
            }
        }

        // The current seven days occupy ages 0...6. A non-overlapping
        // baseline needs the 28 calendar days at ages 7...34.
        let baselineDays = min(28, max(0, oldestAge - 6))
        let baselineWeekly = baselineDays > 0
            ? baselineTotal * 7 / Double(baselineDays)
            : 0
        let state: TrainingLoadComparison.BaselineState
        if baselineDays < 28 {
            state = .building
        } else if baselineTotal <= 0 {
            state = .noRecentLoad
        } else if baselineWeekly < Self.minBaselineWeeklyLoad {
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
            estimatedEffortSessionCount: estimatedEffortSessionCount
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

        if workingSets.isEmpty, activeCardio.isEmpty {
            return detailLessEstimate(workout)
        }

        var result = TrainingLoadEstimate()
        if !workingSets.isEmpty {
            let strength = strengthLoad(workingSets)
            result.strength = strength.load
            result.effortWasEstimated = strength.anyEffortDefaulted
        }
        for session in activeCardio {
            let effort = cardioEffort(session, workout: workout)
            let minutes = cardioMinutes(
                session,
                workout: workout,
                activeCardio: activeCardio,
                workingSets: workingSets
            )
            result.cardio += minutes * effort.value
            result.effortWasEstimated = result.effortWasEstimated || effort.estimated
        }
        return result
    }

    /// Per-set strength load: effective sets (per `VolumeMath`, so myo-reps
    /// and drop sets carry their extra near-failure exposure) scaled by
    /// proximity to failure. Effort resolution per set: logged RPE, else
    /// logged RIR, else the failure convention when the user opted in, else a
    /// neutral default that is flagged as estimated.
    private func strengthLoad(_ workingSets: [SetModel]) -> (load: Double, anyEffortDefaulted: Bool) {
        var load = 0.0
        var anyDefaulted = false
        for set in workingSets {
            let effort: Double
            if let rpe = set.rpe {
                effort = clampedEffort(rpe)
            } else if let rir = set.rir {
                effort = clampedEffort(10 - Double(rir))
            } else if assumesFailureWhenUnlogged {
                effort = 10
            } else {
                effort = Self.defaultEffort
                anyDefaulted = true
            }
            load += Self.pointsPerEffectiveSet
                * VolumeMath.effectiveSetCount(set.domainEntry)
                * effortWeight(effort)
        }
        return (load, anyDefaulted)
    }

    /// Fatigue weight of one effective set at a 0...10 effort, anchored at
    /// RPE 8 (2 RIR) = 1.0. Sub-8 efforts discount linearly; efforts past 8
    /// escalate half again as fast because training closer to failure
    /// produces disproportionate fatigue and slower recovery (Refalo et al.
    /// 2023 meta-analysis; Pareja-Blanco et al. 2017 velocity-loss work).
    private func effortWeight(_ effort: Double) -> Double {
        let e = clampedEffort(effort)
        return e <= 8
            ? max(0.55, 1 + (e - 8) * 0.15)
            : min(1.45, 1 + (e - 8) * 0.225)
    }

    /// Workouts with no sets and no cardio detail: only imported or manual
    /// history may estimate load from duration; an empty local shell
    /// contributes nothing.
    private func detailLessEstimate(_ workout: WorkoutModel) -> TrainingLoadEstimate {
        let totalMinutes = durationMinutes(workout)
        guard totalMinutes > 0,
              workout.hkWorkoutUUID != nil || workout.isImportedHistory else {
            return TrainingLoadEstimate()
        }
        let restorativeMinutes = workout.cardioSessions
            .filter { $0.isYogaSession && $0.resolvedYogaStyle.isRestorative }
            .reduce(0.0) { $0 + max(0, Double($1.durationSeconds ?? 0) / 60) }
        let loadableMinutes = max(0, totalMinutes - min(totalMinutes, restorativeMinutes))
        let effort = zoneWeightedEffort(workout.hrZoneSeconds)
            ?? workout.avgHR.map(effort(forHeartRate:))
            ?? (looksMindBodyLike(workout) ? 3 : Self.defaultEffort)
        let load = loadableMinutes * effort
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
        // Duration-less manual log: an even share of the workout time not
        // already accounted for by timed cardio or logged sets.
        let timedCardioMinutes = workout.cardioSessions.reduce(0.0) {
            $0 + max(0, Double($1.durationSeconds ?? 0) / 60)
        }
        let setMinutes = workingSets.reduce(0.0) {
            $0 + VolumeMath.effectiveSetCount($1.domainEntry)
        } * Self.minutesPerEffectiveSet
        let durationless = Double(max(1, activeCardio.count { ($0.durationSeconds ?? 0) <= 0 }))
        let leftover = durationMinutes(workout) - timedCardioMinutes - setMinutes
        return max(1, leftover / durationless)
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

    func looksStrengthLike(_ workout: WorkoutModel) -> Bool {
        let title = (workout.title ?? "").lowercased()
        return title.contains("strength")
            || title.contains("weight")
            || title.contains("resistance")
            || title.contains("core")
            || title.contains("pilates")
    }

    func looksMindBodyLike(_ workout: WorkoutModel) -> Bool {
        let title = (workout.title ?? "").lowercased()
        return title.contains("yoga")
            || title.contains("stretch")
            || title.contains("mind and body")
    }

    private func cardioEffort(
        _ session: CardioSessionModel,
        workout: WorkoutModel
    ) -> (value: Double, estimated: Bool) {
        let importedEstimate = workout.isImportedHistory
            || session.sourceDevice?.hasPrefix("healthkit") == true
        if let effort = session.effort {
            return (clampedEffort(Double(effort)), importedEstimate)
        }
        // Time in zones beats a single average: intervals spend real minutes
        // in Z4/Z5 that an averaged HR files under Z2/Z3.
        if let zoneEffort = zoneWeightedEffort(session.hrZoneSeconds) {
            return (zoneEffort, true)
        }
        if let heartRate = session.avgHR ?? workout.avgHR {
            return (effort(forHeartRate: heartRate), true)
        }
        if session.isYogaSession {
            let effort: Double = switch session.resolvedYogaStyle {
            case .power: 5
            case .vinyasa: 4
            default: 3
            }
            return (effort, true)
        }
        return (Self.defaultEffort, true)
    }

    /// Seconds-in-zone weighted effort (Edwards' summated-zone approach with
    /// this app's zone→effort anchors), so higher zones count for the extra
    /// fatigue they cost. Nil when no zone time is recorded.
    private func zoneWeightedEffort(_ zoneSeconds: [Int]) -> Double? {
        let totalSeconds = zoneSeconds.reduce(0, +)
        guard totalSeconds > 0 else { return nil }
        var weighted = 0.0
        for (index, seconds) in zoneSeconds.enumerated() {
            weighted += Double(max(0, seconds)) * effort(forZone: index + 1)
        }
        return weighted / Double(totalSeconds)
    }

    private func effort(forHeartRate heartRate: Int) -> Double {
        effort(forZone: HRZone.zone(forAvgHR: heartRate))
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
}
