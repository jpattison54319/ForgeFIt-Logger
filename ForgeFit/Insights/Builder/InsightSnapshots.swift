import ForgeCore
import ForgeData
import Foundation

/// One cardio block inside a workout. Cardio metrics read THESE, never the
/// whole-workout rollup — a run inside a hybrid session must not inherit the
/// lifting time around it, and two runs in one workout are two data points.
struct InsightCardioSegment: Sendable, Equatable {
    var startedAt: Date
    var modality: String
    var durationSeconds: Int
    var distanceMeters: Double?
    var avgHR: Int?
    var maxHR: Int?
    var activeEnergyKcal: Double?
    var avgPowerWatts: Double?
    var elevationGainMeters: Double?
    var steps: Int?
    var zoneSeconds: [Int]
    /// The SEGMENT's own origin — a Health-imported ride inside a logged
    /// workout must not borrow the workout's "measured" stamp.
    var isImported: Bool = false
}

/// Immutable, Sendable projections of the training log that the insight
/// engines chew on OFF the main actor. Snapshotting happens on the main actor
/// (SwiftData models aren't Sendable) and delegates every derived number to
/// the app's existing analytics — an insight card must never disagree with
/// Home or Statistics about the same quantity.
struct InsightSessionSnapshot: Sendable, Equatable {
    var id: UUID
    var startedAt: Date
    var durationSeconds: Int
    /// Wall-clock time minus the cardio/yoga blocks — the strength share of
    /// a hybrid session, never the whole workout.
    var strengthDurationSeconds: Int
    var volumeKg: Double
    var workingSets: Double
    var reps: Int
    var hasStrength: Bool
    var isCardio: Bool
    var hasYoga: Bool
    /// Cardio modality raw value ("run"…), "yoga", or "strength".
    var modality: String
    var routineID: UUID?
    var exerciseIDs: [UUID]
    var primaryMuscles: [String]
    /// Canonical muscle → fractional working sets for this session
    /// (`MuscleVolume` currency: 1.0 primary / 0.5 secondary × effective
    /// sets), including taxonomy-parent rollups — "back" counts a lats+mid-
    /// back row once; "lats" stays exact.
    var muscleSets: [String: Double] = [:]
    /// Per-exercise scoped values (same set predicates as `summary`):
    /// exercise-scoped recipes read the exercise's own numbers, not the
    /// whole workout it happened to be in.
    var exerciseVolumeKg: [UUID: Double] = [:]
    var exerciseSets: [UUID: Double] = [:]
    var exerciseReps: [UUID: Int] = [:]
    /// Mean working-set effort for the session (and per exercise) — logged
    /// RPE/RIR only, never inferred. Sample counts ride along so rollups can
    /// weight by contributing SETS: a 20-set session's RPE must outweigh a
    /// 3-set one.
    var avgRPE: Double?
    var avgRIR: Double?
    var rpeSampleCount: Int = 0
    var rirSampleCount: Int = 0
    var exerciseRPE: [UUID: Double] = [:]
    var exerciseRPECounts: [UUID: Int] = [:]
    var exerciseRIR: [UUID: Double] = [:]
    var exerciseRIRCounts: [UUID: Int] = [:]
    var weekday: Int
    /// True when the workout arrived from outside live logging — a Health
    /// import or an external history import (Hevy, CSV).
    var isImported: Bool
    var readinessAtStart: Double?
    var cardioSegments: [InsightCardioSegment] = []
    var yogaDurationSeconds: Int = 0
    var yogaPosesCompleted: Int = 0
    var yogaStyle: String?
    /// Group membership when a dimension is active — attached by the
    /// coordinator, carried into every observation this session produces.
    var category: String?

    var provenance: InsightProvenance { isImported ? .imported : .measured }
}

struct InsightCheckinSnapshot: Sendable, Equatable {
    var date: Date
    var tags: [String]
}

/// Main-actor bridge from SwiftData models to Sendable snapshots. Uses
/// `TrainingAnalytics` for every summary quantity (duration, volume, sets,
/// reps, strength/cardio flags) so the numbers match every other surface.
@MainActor
enum InsightSnapshotter {

    static func sessions(
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        calendar: Calendar = .current
    ) -> [InsightSessionSnapshot] {
        let analytics = TrainingAnalytics(workouts: workouts, exercises: exercises)
        return analytics.completed.map { workout in
            let summary = analytics.summary(for: workout)
            let sessions = workout.cardioSessions.filter { $0.deletedAt == nil }
            let yogaSessions = sessions.filter { $0.modality == CardioSessionModel.yogaModality }
            let cardioSessions = sessions.filter { $0.modality != CardioSessionModel.yogaModality }
            let modality: String = {
                if let cardio = cardioSessions.first { return cardio.modality }
                return yogaSessions.isEmpty ? "strength" : "yoga"
            }()
            // WorkoutExerciseModel has no deletedAt — rows live and die with
            // their workout via the cascade relationship.
            let exerciseIDs = workout.exercises.map(\.exerciseID)
            let muscleVolume = analytics.muscleVolume(for: workout)

            let segments = cardioSessions.map { session in
                InsightCardioSegment(
                    startedAt: session.liveStartedAt ?? session.startedAt,
                    modality: session.modality,
                    durationSeconds: session.durationSeconds ?? 0,
                    distanceMeters: session.distanceMeters,
                    avgHR: session.avgHR,
                    maxHR: session.maxHR,
                    activeEnergyKcal: session.activeEnergyKcal,
                    avgPowerWatts: session.avgPowerWatts,
                    elevationGainMeters: session.elevationGainMeters,
                    steps: session.totalSteps,
                    zoneSeconds: session.hrZoneSeconds,
                    isImported: session.sourceDevice?.hasPrefix("healthkit") == true
                )
            }
            let yogaSeconds = yogaSessions.compactMap(\.durationSeconds).reduce(0, +)
            let segmentSeconds = segments.map(\.durationSeconds).reduce(0, +) + yogaSeconds

            // Per-exercise scoped values — identical predicates to `summary`.
            var exerciseVolume: [UUID: Double] = [:]
            var exerciseSets: [UUID: Double] = [:]
            var exerciseReps: [UUID: Int] = [:]
            var rpeTotal = 0.0, rpeCount = 0
            var rirTotal = 0.0, rirCount = 0
            var exerciseRPETotals: [UUID: (sum: Double, count: Int)] = [:]
            var exerciseRIRTotals: [UUID: (sum: Double, count: Int)] = [:]
            for row in workout.exercises {
                let working = row.sets.filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
                guard !working.isEmpty else { continue }
                exerciseVolume[row.exerciseID, default: 0] += working.reduce(0) { $0 + ($1.totalVolume ?? 0) }
                exerciseSets[row.exerciseID, default: 0] += working.reduce(0) { $0 + VolumeMath.effectiveSetCount($1.domainEntry) }
                exerciseReps[row.exerciseID, default: 0] += working.reduce(0) { $0 + ($1.reps ?? 0) }
                for set in working {
                    if let rpe = set.rpe {
                        rpeTotal += rpe
                        rpeCount += 1
                        var entry = exerciseRPETotals[row.exerciseID] ?? (0, 0)
                        entry.sum += rpe
                        entry.count += 1
                        exerciseRPETotals[row.exerciseID] = entry
                    }
                    if let rir = set.rir {
                        rirTotal += Double(rir)
                        rirCount += 1
                        var entry = exerciseRIRTotals[row.exerciseID] ?? (0, 0)
                        entry.sum += Double(rir)
                        entry.count += 1
                        exerciseRIRTotals[row.exerciseID] = entry
                    }
                }
            }

            return InsightSessionSnapshot(
                id: workout.id,
                startedAt: workout.startedAt,
                durationSeconds: summary.durationSeconds,
                strengthDurationSeconds: summary.hasStrength
                    ? max(0, summary.durationSeconds - segmentSeconds)
                    : 0,
                volumeKg: summary.volume,
                workingSets: summary.sets,
                reps: summary.reps,
                hasStrength: summary.hasStrength,
                isCardio: !segments.isEmpty,
                hasYoga: !yogaSessions.isEmpty,
                modality: modality,
                routineID: workout.routineID,
                exerciseIDs: exerciseIDs,
                primaryMuscles: muscleVolume.map(\.muscle),
                muscleSets: analytics.muscleVolumeInsightBuckets(for: workout),
                exerciseVolumeKg: exerciseVolume,
                exerciseSets: exerciseSets,
                exerciseReps: exerciseReps,
                avgRPE: rpeCount > 0 ? rpeTotal / Double(rpeCount) : nil,
                avgRIR: rirCount > 0 ? rirTotal / Double(rirCount) : nil,
                rpeSampleCount: rpeCount,
                rirSampleCount: rirCount,
                exerciseRPE: exerciseRPETotals.mapValues { $0.sum / Double(max($0.count, 1)) },
                exerciseRPECounts: exerciseRPETotals.mapValues(\.count),
                exerciseRIR: exerciseRIRTotals.mapValues { $0.sum / Double(max($0.count, 1)) },
                exerciseRIRCounts: exerciseRIRTotals.mapValues(\.count),
                weekday: calendar.component(.weekday, from: workout.startedAt),
                isImported: workout.sourceDevice?.hasPrefix("healthkit") == true
                    || workout.externalSource != nil,
                readinessAtStart: workout.readinessAtStart.map(Double.init),
                cardioSegments: segments,
                yogaDurationSeconds: yogaSeconds,
                // Completed poses come from the session row; sessions logged
                // before that field existed fall back to the planned flow —
                // a finished flow was logged as fully done.
                yogaPosesCompleted: yogaSessions.compactMap(\.posesCompleted).reduce(0, +).nonZero
                    ?? workout.exercises
                    .compactMap { YogaFlowPlan.decode(from: $0.yogaFlowJSON)?.steps.count }
                    .reduce(0, +),
                yogaStyle: yogaSessions.first?.yogaStyleRaw,
                category: nil
            )
        }
    }

    static func checkins(_ models: [DailyCheckinModel], calendar: Calendar = .current) -> [InsightCheckinSnapshot] {
        models
            .filter { $0.deletedAt == nil }
            .map { InsightCheckinSnapshot(date: calendar.startOfDay(for: $0.date), tags: $0.tags) }
    }

    /// Per-exercise session-best e1RM, straight from the analytics series the
    /// Statistics screens already chart (kilograms; render via `Fmt` in the
    /// exercise's effective unit). Estimated by definition — it's a formula
    /// over a set, not a measurement.
    static func e1rmObservations(
        exerciseID: UUID,
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel]
    ) -> [InsightObservation] {
        TrainingAnalytics(workouts: workouts, exercises: exercises)
            .e1rmSeries(for: exerciseID)
            .map { InsightObservation(timestamp: $0.date, value: $0.value, provenance: .estimated) }
    }
}

private extension Int {
    var nonZero: Int? { self > 0 ? self : nil }
}
