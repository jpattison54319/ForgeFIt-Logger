import ForgeCore
import ForgeData
import Foundation

/// Selects a small, honest weekly headline from the work the athlete actually
/// recorded. Additive totals are eligible; cross-modality averages such as a
/// blended run/row/swim pace are deliberately not.
enum HomeWeekMetrics {
    struct Summary: Equatable {
        let metrics: [Metric]
    }

    struct Metric: Identifiable, Equatable {
        enum Kind: String {
            case time
            case strengthVolume = "strength-volume"
            case strengthSets = "strength-sets"
            case strengthReps = "strength-reps"
            case cardioDistance = "cardio-distance"
            case cardioElevation = "cardio-elevation"
            case cardioFloors = "cardio-floors"
            case cardioSteps = "cardio-steps"
            case cardioStrides = "cardio-strides"
            case cardioJumps = "cardio-jumps"
            case cardioTime = "cardio-time"
            case conditioningRounds = "conditioning-rounds"
            case conditioningReps = "conditioning-reps"
            case conditioningIntervals = "conditioning-intervals"
            case conditioningTime = "conditioning-time"
            case yogaPoses = "yoga-poses"
            case yogaRegions = "yoga-regions"
            case yogaTime = "yoga-time"
            case averageHeartRate = "average-heart-rate"

            var label: String {
                switch self {
                case .time: "Time"
                case .strengthVolume: "Volume"
                case .strengthSets: "Sets"
                case .strengthReps: "Reps"
                case .cardioDistance: "Distance"
                case .cardioElevation: "Elevation"
                case .cardioFloors: "Floors"
                case .cardioSteps: "Steps"
                case .cardioStrides: "Strides"
                case .cardioJumps: "Jumps"
                case .cardioTime: "Cardio"
                case .conditioningRounds: "Rounds"
                case .conditioningReps: "Cond. reps"
                case .conditioningIntervals: "Intervals"
                case .conditioningTime: "Conditioning"
                case .yogaPoses: "Poses"
                case .yogaRegions: "Regions"
                case .yogaTime: "Yoga"
                case .averageHeartRate: "Avg HR"
                }
            }
        }

        enum Value: Equatable {
            case duration(Int)
            case volume(Double)
            case sets(Double)
            case count(Int)
            case distance(meters: Double, fixedMeters: Bool)
            case elevationMeters(Double)
            case beatsPerMinute(Int)
        }

        let kind: Kind
        let value: Value

        var id: String { kind.rawValue }
        var label: String { kind.label }

        func formatted(weightUnit: WeightUnit, distanceUnit: DistanceUnit) -> String {
            switch value {
            case .duration(let seconds):
                Fmt.durationShort(seconds)
            case .volume(let kilograms):
                Fmt.volume(kilograms, unit: weightUnit)
            case .sets(let count):
                Fmt.sets(count)
            case .count(let count):
                count.formatted()
            case .distance(let meters, let fixedMeters):
                fixedMeters
                    ? Fmt.cardioDistance(meters, kind: .swim, unit: distanceUnit)
                    : Fmt.distance(meters, unit: distanceUnit)
            case .elevationMeters(let meters):
                "\(Int(meters.rounded()).formatted()) m"
            case .beatsPerMinute(let bpm):
                "\(bpm.formatted()) bpm"
            }
        }
    }

    private enum Modality: Int, CaseIterable {
        case strength
        case cardio
        case conditioning
        case yoga
    }

    private struct Totals {
        var durationSeconds = 0
        var activeModalities: Set<Modality> = []
        var modalityDuration: [Modality: Int] = [:]
        var modalityLastCompletedAt: [Modality: Date] = [:]

        var strengthVolume = 0.0
        var strengthSets = 0.0
        var strengthReps = 0

        var cardioDistanceMeters = 0.0
        var cardioDistanceIsOnlySwimming = true
        var cardioHasDistance = false
        var cardioElevationMeters = 0.0
        var cardioFloors = 0
        var cardioSteps = 0
        var cardioStrides = 0
        var cardioJumps = 0

        var conditioningRounds = 0
        var conditioningReps = 0
        var conditioningIntervals = 0

        var yogaPoses = 0
        var yogaRegions: Set<String> = []

        var heartRateWeightedSum = 0.0
        var heartRateCoveredSeconds = 0

        mutating func record(
            _ modality: Modality,
            durationSeconds: Int = 0,
            completedAt: Date
        ) {
            activeModalities.insert(modality)
            modalityDuration[modality, default: 0] += max(0, durationSeconds)
            if completedAt > (modalityLastCompletedAt[modality] ?? .distantPast) {
                modalityLastCompletedAt[modality] = completedAt
            }
        }
    }

    private struct WorkoutContribution {
        var activeModalities: Set<Modality> = []
        var explicitDuration: [Modality: Int] = [:]
        var latestActivity: [Modality: Date] = [:]

        mutating func record(_ modality: Modality, durationSeconds: Int = 0, at date: Date) {
            activeModalities.insert(modality)
            explicitDuration[modality, default: 0] += max(0, durationSeconds)
            if date > (latestActivity[modality] ?? .distantPast) {
                latestActivity[modality] = date
            }
        }
    }

    static func summary(
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        containing now: Date = .now,
        calendar: Calendar = .current
    ) -> Summary {
        let interval = TrainingWeekSupport.interval(containing: now, calendar: calendar)
        let completed = workouts.filter {
            $0.deletedAt == nil && $0.endedAt != nil && interval.contains($0.startedAt)
        }
        let exerciseByID = Dictionary(
            exercises.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var totals = Totals()

        for workout in completed {
            accumulate(workout, exerciseByID: exerciseByID, into: &totals)
        }

        var metrics = [Metric(kind: .time, value: .duration(totals.durationSeconds))]
        metrics.append(contentsOf: selectAdaptiveMetrics(from: totals, limit: 3))
        return Summary(metrics: metrics)
    }

    /// A body-safe memo key that includes the nested records used by the Home
    /// headline. Session enrichment can change distance or HR after workout
    /// completion without changing `WorkoutModel.updatedAt`, so Home cannot use
    /// the coarser history fingerprint alone.
    static func fingerprint(
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        containing now: Date = .now,
        calendar: Calendar = .current
    ) -> Int {
        let interval = TrainingWeekSupport.interval(containing: now, calendar: calendar)
        var hasher = Hasher()
        hasher.combine(interval.start)
        var referencedExerciseIDs: Set<UUID> = []

        for workout in workouts where workout.deletedAt == nil && workout.endedAt != nil && interval.contains(workout.startedAt) {
            hasher.combine(workout.id)
            hasher.combine(workout.startedAt)
            hasher.combine(workout.endedAt)
            hasher.combine(workout.updatedAt)
            hasher.combine(workout.avgHR)
            hasher.combine(workout.conditioningPlanSnapshotJSON)
            hasher.combine(workout.conditioningResultJSON)

            for row in workout.exercises {
                referencedExerciseIDs.insert(row.exerciseID)
                hasher.combine(row.id)
                hasher.combine(row.updatedAt)
                hasher.combine(row.generatedByWorkoutBlockID)
                hasher.combine(row.yogaFlowJSON)
                for set in row.sets where set.completedAt != nil {
                    hasher.combine(set.id)
                    hasher.combine(set.updatedAt)
                    hasher.combine(set.setTypeRaw)
                    hasher.combine(set.reps)
                    hasher.combine(set.partialReps)
                    hasher.combine(set.durationSeconds)
                    hasher.combine(set.holdSeconds)
                    hasher.combine(set.totalVolume)
                }
            }
            for session in workout.cardioSessions {
                hasher.combine(session.id)
                hasher.combine(session.updatedAt)
                hasher.combine(session.deletedAt)
                hasher.combine(session.endedAt)
                hasher.combine(session.liveStartedAt)
                hasher.combine(session.workoutExerciseID)
                hasher.combine(session.sourceDevice)
                hasher.combine(session.modality)
                hasher.combine(session.durationSeconds)
                hasher.combine(session.distanceMeters)
                hasher.combine(session.avgHR)
                hasher.combine(session.elevationGainMeters)
                hasher.combine(session.floorsClimbed)
                hasher.combine(session.totalSteps)
                hasher.combine(session.posesCompleted)
                hasher.combine(session.flexibilityExposureJSON)
                for split in session.splits {
                    hasher.combine(split.id)
                    hasher.combine(split.index)
                    hasher.combine(split.label)
                    hasher.combine(split.createdAt)
                }
            }
            for block in workout.blocks {
                hasher.combine(block.id)
                hasher.combine(block.updatedAt)
                hasher.combine(block.kindRaw)
                hasher.combine(block.resultJSON)
            }
        }

        for exercise in exercises where referencedExerciseIDs.contains(exercise.id) {
            hasher.combine(exercise.id)
            hasher.combine(exercise.updatedAt)
            hasher.combine(exercise.modalityRaw)
            hasher.combine(exercise.isCardio)
            hasher.combine(exercise.category)
            hasher.combine(exercise.primaryMuscles)
            hasher.combine(exercise.secondaryMuscles)
        }
        return hasher.finalize()
    }

    private static func accumulate(
        _ workout: WorkoutModel,
        exerciseByID: [UUID: ExerciseLibraryModel],
        into totals: inout Totals
    ) {
        let completedAt = workout.endedAt ?? workout.startedAt
        let workoutDuration = duration(of: workout)
        totals.durationSeconds += workoutDuration

        let performedSessions = workout.cardioSessions.filter { isPerformed($0) }
        let linkedSessionRowIDs = Set(performedSessions.compactMap(\.workoutExerciseID))
        let legacyConditioningExerciseIDs = legacyConditioningMovementIDs(in: workout)
        var contribution = WorkoutContribution()

        for session in performedSessions {
            let sessionDuration = max(0, session.durationSeconds ?? 0)
            let sessionCompletedAt = session.endedAt ?? completedAt
            if session.isYogaSession {
                contribution.record(.yoga, durationSeconds: sessionDuration, at: sessionCompletedAt)
                if let poses = session.logicalYogaPosesCompleted, poses > 0 {
                    totals.yogaPoses += poses
                }
                for (region, seconds) in FlexibilityAnalytics.decodeExposure(session.flexibilityExposureJSON)
                    where seconds > 0 {
                    totals.yogaRegions.insert(region)
                }
            } else if session.isConditioningSession {
                contribution.record(.conditioning, durationSeconds: sessionDuration, at: sessionCompletedAt)
            } else {
                contribution.record(.cardio, durationSeconds: sessionDuration, at: sessionCompletedAt)
                accumulateCardio(session, into: &totals)
            }
        }

        for row in workout.exercises where row.generatedByWorkoutBlockID == nil {
            guard !linkedSessionRowIDs.contains(row.id),
                  !legacyConditioningExerciseIDs.contains(row.exerciseID) else { continue }
            let completedSets = row.sets.filter { $0.completedAt != nil }
            guard !completedSets.isEmpty else { continue }

            let exercise = exerciseByID[row.exerciseID]
            let modality = resolvedModality(row: row, exercise: exercise)
            switch modality {
            case .strength:
                let workingSets = completedSets.filter { $0.setType.countsAsWorkingVolume }
                guard !workingSets.isEmpty else { continue }
                contribution.record(.strength, at: completedAt)
                totals.strengthVolume += workingSets.reduce(0) { $0 + ($1.totalVolume ?? 0) }
                totals.strengthSets += workingSets.reduce(0) {
                    $0 + VolumeMath.effectiveSetCount($1.domainEntry)
                }
                totals.strengthReps += workingSets.reduce(0) { $0 + ($1.reps ?? 0) }
            case .cardio:
                let seconds = completedSets.compactMap(\.durationSeconds).reduce(0, +)
                guard seconds > 0 else { continue }
                contribution.record(.cardio, durationSeconds: seconds, at: completedAt)
            case .yoga:
                let timedSets = completedSets.filter { ($0.holdSeconds ?? $0.durationSeconds ?? 0) > 0 }
                guard !timedSets.isEmpty else { continue }
                let seconds = timedSets.reduce(0) { $0 + ($1.holdSeconds ?? $1.durationSeconds ?? 0) }
                contribution.record(.yoga, durationSeconds: seconds, at: completedAt)
                if let exercise {
                    totals.yogaRegions.formUnion(exercise.primaryMuscles.map(MuscleTaxonomy.canonical))
                    totals.yogaRegions.formUnion(exercise.secondaryMuscles.map(MuscleTaxonomy.canonical))
                }
            case .conditioning:
                continue
            }
        }

        let conditioningResults = completedConditioningResults(in: workout)
        if !conditioningResults.isEmpty {
            let fallbackDuration = contribution.explicitDuration[.conditioning, default: 0] == 0
                ? conditioningResults.compactMap(\.elapsedSeconds).reduce(0, +)
                : 0
            contribution.record(.conditioning, durationSeconds: fallbackDuration, at: completedAt)
            for result in conditioningResults {
                if result.scoreKind != .completedIntervals, let rounds = result.fullRounds, rounds > 0 {
                    totals.conditioningRounds += rounds
                }
                if let reps = result.totalReps, reps > 0 {
                    totals.conditioningReps += reps
                }
                if result.scoreKind == .completedIntervals,
                   let intervals = result.completedIntervals ?? result.fullRounds,
                   intervals > 0 {
                    totals.conditioningIntervals += intervals
                }
            }
        }

        attributeWorkoutDuration(workoutDuration, contribution: &contribution)
        for modality in contribution.activeModalities {
            totals.record(
                modality,
                durationSeconds: contribution.explicitDuration[modality, default: 0],
                completedAt: contribution.latestActivity[modality] ?? completedAt
            )
        }
        accumulateHeartRate(workout, performedSessions: performedSessions, duration: workoutDuration, into: &totals)
    }

    private static func resolvedModality(
        row: WorkoutExerciseModel,
        exercise: ExerciseLibraryModel?
    ) -> Modality {
        if YogaFlowPlan.decode(from: row.yogaFlowJSON) != nil || exercise?.modality == .yoga {
            return .yoga
        }
        if exercise?.modality == .cardio {
            return .cardio
        }
        return .strength
    }

    private static func duration(of workout: WorkoutModel) -> Int {
        if let endedAt = workout.endedAt {
            let elapsed = max(0, Int(endedAt.timeIntervalSince(workout.startedAt)))
            if elapsed > 0 { return elapsed }
        }
        let sessionSeconds = workout.cardioSessions
            .filter { isPerformed($0) }
            .compactMap(\.durationSeconds)
            .reduce(0, +)
        if sessionSeconds > 0 { return sessionSeconds }
        return workout.exercises
            .flatMap(\.sets)
            .filter { $0.completedAt != nil }
            .compactMap(\.durationSeconds)
            .reduce(0, +)
    }

    private static func isPerformed(_ session: CardioSessionModel) -> Bool {
        guard session.deletedAt == nil else { return false }
        if session.endedAt != nil { return true }
        let hasRecordedOutput = (session.durationSeconds ?? 0) > 0
            || (session.distanceMeters ?? 0) > 0
            || (session.posesCompleted ?? 0) > 0
            || (session.floorsClimbed ?? 0) > 0
            || (session.totalSteps ?? 0) > 0
        if session.liveStartedAt != nil && hasRecordedOutput { return true }
        return session.isYogaSession
            && session.sourceDevice == CardioSessionModel.yogaManualSource
            && hasRecordedOutput
    }

    private static func accumulateCardio(_ session: CardioSessionModel, into totals: inout Totals) {
        let kind = CardioKind.from(modality: session.modality)
        if kind.usesDistance, let distance = session.distanceMeters, distance > 0 {
            totals.cardioDistanceMeters += distance
            totals.cardioHasDistance = true
            totals.cardioDistanceIsOnlySwimming = totals.cardioDistanceIsOnlySwimming && kind == .swim
        }
        if kind.usesElevation, let elevation = session.elevationGainMeters, elevation > 0 {
            totals.cardioElevationMeters += elevation
        }
        if kind.usesFloors, let floors = session.floorsClimbed, floors > 0 {
            totals.cardioFloors += floors
        }
        if kind.usesStepCount, let count = session.totalSteps, count > 0 {
            switch kind {
            case .stair: totals.cardioSteps += count
            case .elliptical: totals.cardioStrides += count
            case .jumpRope: totals.cardioJumps += count
            default: break
            }
        }
    }

    private static func completedConditioningResults(in workout: WorkoutModel) -> [ConditioningSectionResult] {
        let conditioningBlocks = workout.blocks.filter { $0.kind == .conditioning }
        if !conditioningBlocks.isEmpty {
            return conditioningBlocks
                .flatMap { ConditioningResult.decode(from: $0.resultJSON)?.sectionResults ?? [] }
                .filter(\.completed)
        }
        return (ConditioningResult.decode(from: workout.conditioningResultJSON)?.sectionResults ?? [])
            .filter(\.completed)
    }

    private static func legacyConditioningMovementIDs(in workout: WorkoutModel) -> Set<UUID> {
        guard !workout.blocks.contains(where: { $0.kind == .conditioning }),
              let plan = ConditioningPlan.decode(from: workout.conditioningPlanSnapshotJSON) else {
            return []
        }
        return Set(plan.sections.flatMap(\.movements).map(\.exerciseID))
    }

    private static func attributeWorkoutDuration(
        _ workoutDuration: Int,
        contribution: inout WorkoutContribution
    ) {
        guard !contribution.activeModalities.isEmpty else { return }
        if contribution.activeModalities.count == 1,
           let modality = contribution.activeModalities.first,
           contribution.explicitDuration[modality, default: 0] == 0 {
            contribution.explicitDuration[modality] = workoutDuration
            return
        }
        guard contribution.activeModalities.contains(.strength) else { return }
        let timedModalities = contribution.explicitDuration
            .filter { $0.key != .strength }
            .values
            .reduce(0, +)
        contribution.explicitDuration[.strength, default: 0] += max(0, workoutDuration - timedModalities)
    }

    private static func accumulateHeartRate(
        _ workout: WorkoutModel,
        performedSessions: [CardioSessionModel],
        duration: Int,
        into totals: inout Totals
    ) {
        if let average = workout.avgHR, average > 0, duration > 0 {
            totals.heartRateWeightedSum += Double(average * duration)
            totals.heartRateCoveredSeconds += duration
            return
        }
        for session in performedSessions {
            guard let average = session.avgHR, average > 0,
                  let seconds = session.durationSeconds, seconds > 0 else { continue }
            totals.heartRateWeightedSum += Double(average * seconds)
            totals.heartRateCoveredSeconds += seconds
        }
    }

    private static func selectAdaptiveMetrics(from totals: Totals, limit: Int) -> [Metric] {
        guard limit > 0 else { return [] }
        let isMixedWeek = totals.activeModalities.count > 1
        let candidates = candidateMetrics(totals: totals, isMixedWeek: isMixedWeek)
        let orderedModalities = totals.activeModalities.sorted { lhs, rhs in
            let lhsDuration = totals.modalityDuration[lhs, default: 0]
            let rhsDuration = totals.modalityDuration[rhs, default: 0]
            if lhsDuration != rhsDuration { return lhsDuration > rhsDuration }
            let lhsDate = totals.modalityLastCompletedAt[lhs] ?? .distantPast
            let rhsDate = totals.modalityLastCompletedAt[rhs] ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.rawValue < rhs.rawValue
        }

        var selected: [Metric] = []
        var consumed: [Modality: Int] = [:]
        for modality in orderedModalities {
            guard selected.count < limit, let first = candidates[modality]?.first else { continue }
            selected.append(first)
            consumed[modality] = 1
        }

        while selected.count < limit {
            var added = false
            for modality in orderedModalities where selected.count < limit {
                let index = consumed[modality, default: 0]
                guard let values = candidates[modality], values.indices.contains(index) else { continue }
                selected.append(values[index])
                consumed[modality] = index + 1
                added = true
            }
            if !added { break }
        }

        if selected.count < limit,
           totals.durationSeconds > 0,
           totals.heartRateCoveredSeconds * 2 >= totals.durationSeconds,
           totals.heartRateCoveredSeconds > 0 {
            let average = Int(
                (totals.heartRateWeightedSum / Double(totals.heartRateCoveredSeconds)).rounded()
            )
            selected.append(Metric(kind: .averageHeartRate, value: .beatsPerMinute(average)))
        }
        return Array(selected.prefix(limit))
    }

    private static func candidateMetrics(
        totals: Totals,
        isMixedWeek: Bool
    ) -> [Modality: [Metric]] {
        var result: [Modality: [Metric]] = [:]

        appendPositive(totals.strengthVolume, .strengthVolume, value: { .volume($0) }, to: &result[.strength, default: []])
        appendPositive(totals.strengthSets, .strengthSets, value: { .sets($0) }, to: &result[.strength, default: []])
        appendPositive(totals.strengthReps, .strengthReps, to: &result[.strength, default: []])

        if totals.cardioHasDistance {
            result[.cardio, default: []].append(Metric(
                kind: .cardioDistance,
                value: .distance(
                    meters: totals.cardioDistanceMeters,
                    fixedMeters: totals.cardioDistanceIsOnlySwimming
                )
            ))
        }
        appendPositive(totals.cardioElevationMeters, .cardioElevation, value: { .elevationMeters($0) }, to: &result[.cardio, default: []])
        appendPositive(totals.cardioFloors, .cardioFloors, to: &result[.cardio, default: []])
        appendPositive(totals.cardioSteps, .cardioSteps, to: &result[.cardio, default: []])
        appendPositive(totals.cardioStrides, .cardioStrides, to: &result[.cardio, default: []])
        appendPositive(totals.cardioJumps, .cardioJumps, to: &result[.cardio, default: []])

        appendPositive(totals.conditioningRounds, .conditioningRounds, to: &result[.conditioning, default: []])
        appendPositive(totals.conditioningReps, .conditioningReps, to: &result[.conditioning, default: []])
        appendPositive(totals.conditioningIntervals, .conditioningIntervals, to: &result[.conditioning, default: []])

        appendPositive(totals.yogaPoses, .yogaPoses, to: &result[.yoga, default: []])
        appendPositive(totals.yogaRegions.count, .yogaRegions, to: &result[.yoga, default: []])

        if isMixedWeek {
            appendDurationFallback(.cardio, kind: .cardioTime, totals: totals, to: &result)
            appendDurationFallback(.conditioning, kind: .conditioningTime, totals: totals, to: &result)
            appendDurationFallback(.yoga, kind: .yogaTime, totals: totals, to: &result)
        }
        return result
    }

    private static func appendDurationFallback(
        _ modality: Modality,
        kind: Metric.Kind,
        totals: Totals,
        to result: inout [Modality: [Metric]]
    ) {
        guard result[modality, default: []].isEmpty,
              totals.activeModalities.contains(modality),
              totals.modalityDuration[modality, default: 0] > 0 else { return }
        result[modality, default: []].append(Metric(
            kind: kind,
            value: .duration(totals.modalityDuration[modality, default: 0])
        ))
    }

    private static func appendPositive(
        _ count: Int,
        _ kind: Metric.Kind,
        to metrics: inout [Metric]
    ) {
        guard count > 0 else { return }
        metrics.append(Metric(kind: kind, value: .count(count)))
    }

    private static func appendPositive(
        _ value: Double,
        _ kind: Metric.Kind,
        value metricValue: (Double) -> Metric.Value,
        to metrics: inout [Metric]
    ) {
        guard value > 0 else { return }
        metrics.append(Metric(kind: kind, value: metricValue(value)))
    }
}
