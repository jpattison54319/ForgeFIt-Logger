import ForgeCore
import ForgeData
import Foundation

/// The complete metric vocabulary the builder offers, and the producers that
/// turn snapshots into observations. Descriptors carry the semantics the
/// compatibility engine validates against; producers delegate every derived
/// number to the snapshots (which delegate to TrainingAnalytics) or to the
/// daily Health records (which carry HealthService's validated derivations —
/// nocturnal HRV over all-day, sleeping HR over resting).
///
/// IDs are stable, namespaced strings — recipes outlive catalog evolution,
/// so renaming a TITLE is free but an ID change orphans saved cards.
enum InsightMetricCatalog {

    // MARK: - Descriptor list

    static let all: [InsightMetricDescriptor] = strength + cardio + yoga + health

    static func definition(for id: String) -> InsightMetricDescriptor? {
        if let known = byID[id] { return known }
        if let muscle = muscle(fromMetricID: id) { return muscleSetsDescriptor(muscle: muscle) }
        return nil
    }

    /// The static catalog plus dynamic descriptors for any parameterized ids
    /// this recipe references — validators build their lookup from this, so a
    /// muscle-scoped recipe never reads as "unknown metric".
    static func descriptors(covering recipe: InsightRecipe) -> [InsightMetricDescriptor] {
        all + recipe.allMetricIDs.filter { byID[$0] == nil }.compactMap { definition(for: $0) }
    }

    private static let byID: [String: InsightMetricDescriptor] =
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    // MARK: - Muscle-scoped metrics (parameterized ids)

    /// Per-muscle set volume uses parameterized ids — "strength.muscleSets.
    /// <slug>" — instead of a per-recipe scope so one recipe can put two
    /// muscles side by side (chest vs back). Values are `MuscleVolume`
    /// fractional sets, the exact currency of the weekly muscle-volume card.
    static let muscleSetsPrefix = "strength.muscleSets."

    static func muscleSetsID(for muscle: String) -> String {
        muscleSetsPrefix + MuscleTaxonomy.canonical(muscle).replacingOccurrences(of: " ", with: "-")
    }

    static func muscle(fromMetricID id: String) -> String? {
        guard id.hasPrefix(muscleSetsPrefix) else { return nil }
        let slug = String(id.dropFirst(muscleSetsPrefix.count))
        guard !slug.isEmpty else { return nil }
        return slug.replacingOccurrences(of: "-", with: " ")
    }

    static func muscleDisplayName(_ muscle: String) -> String {
        muscle.prefix(1).uppercased() + muscle.dropFirst()
    }

    private static func muscleSetsDescriptor(muscle: String) -> InsightMetricDescriptor {
        InsightMetricDescriptor(
            id: muscleSetsID(for: muscle),
            title: "\(muscleDisplayName(muscle)) sets",
            category: "Muscles",
            valueKind: .count, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: sessionShapes,
            // Grouping a single muscle's sets by muscle is circular; every
            // other training dimension reads honestly.
            supportedDimensions: strengthDimensions,
            supportedScopes: [.routine]
        )
    }

    /// Muscle choices for the picker: every canonical muscle the exercise
    /// library can produce, big conventional groups first, drill-down
    /// sub-muscles after.
    static func muscleOptions(exercises: [ExerciseLibraryModel]) -> [String] {
        muscleOptions(from: exercises.filter { $0.deletedAt == nil }
            .map { $0.primaryMuscles + $0.secondaryMuscles })
    }

    static func muscleOptions(from rawMuscleLists: [[String]]) -> [String] {
        var seen = Set<String>()
        for list in rawMuscleLists {
            for raw in list {
                let canonical = MuscleTaxonomy.canonical(raw)
                seen.insert(canonical)
                // A child in the library makes its parent comparable too —
                // "lats" data must surface a "back" option.
                if let parent = MuscleTaxonomy.parentByChild[canonical] {
                    seen.insert(parent)
                }
            }
        }
        let priority = [
            "chest", "back", "shoulders", "biceps", "triceps", "forearms",
            "quadriceps", "hamstrings", "glutes", "calves", "abdominals",
        ]
        let prioritized = priority.filter(seen.contains)
        let rest = seen.subtracting(prioritized).sorted()
        return prioritized + rest
    }

    private static let sessionShapes: Set<InsightShape> = [
        .trend, .relationship, .groupComparison, .periodComparison, .distribution,
    ]
    /// A sparse sensor-backed sum cannot support a whole-period total: an
    /// absent distance/energy/steps sample is unknown, not zero, and the
    /// catalog has no session-level coverage contract that could prove the
    /// partial sum complete.
    private static let optionalRecordedSumShapes: Set<InsightShape> = [
        .trend, .relationship, .groupComparison, .distribution,
    ]
    /// Event counts need a real calendar denominator. Trend/period views get
    /// that from the daily/weekly grid and distributions include zero buckets;
    /// relationship and group views would otherwise analyze constant ones.
    private static let eventShapes: Set<InsightShape> = [
        .trend, .periodComparison, .distribution,
    ]
    /// Whole-session strength values cannot be attributed to every exercise,
    /// muscle, or cardio block in a hybrid workout without duplicating them.
    private static let strengthDimensions: Set<InsightDimension> = [
        .routine, .weekday, .source, .checkinTag,
    ]
    /// Cardio contributions live on segments, so activity is an honest group;
    /// exercise/muscle membership from the surrounding workout is not.
    private static let cardioDimensions: Set<InsightDimension> = [
        .modality, .routine, .weekday, .source, .checkinTag,
    ]
    private static let yogaDimensions: Set<InsightDimension> = [
        .routine, .weekday, .source, .checkinTag,
    ]
    private static let healthDimensions: Set<InsightDimension> = [.weekday, .checkinTag]
    private static let cardioExclusiveDimensions: Set<InsightDimension> = [
        .modality, .weekday, .source, .routine,
    ]

    static let strength: [InsightMetricDescriptor] = [
        .init(
            id: "strength.workouts", title: "Workouts", category: "Strength",
            valueKind: .sessions, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .sum,
            supportedShapes: eventShapes, supportedDimensions: strengthDimensions,
            supportedScopes: [.exercise, .routine]
        ),
        .init(
            id: "strength.duration", title: "Workout duration", category: "Strength",
            valueKind: .durationSeconds, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: sessionShapes, supportedDimensions: strengthDimensions,
            supportedScopes: [.exercise, .routine]
        ),
        .init(
            id: "strength.workingSets", title: "Working sets", category: "Strength",
            valueKind: .count, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: sessionShapes, supportedDimensions: strengthDimensions,
            supportedScopes: [.exercise, .routine]
        ),
        .init(
            id: "strength.reps", title: "Total reps", category: "Strength",
            valueKind: .reps, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: sessionShapes, supportedDimensions: strengthDimensions,
            supportedScopes: [.exercise, .routine]
        ),
        .init(
            id: "strength.volume", title: "Working volume", category: "Strength",
            valueKind: .massKilograms, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: sessionShapes, supportedDimensions: strengthDimensions,
            supportedScopes: [.exercise, .routine]
        ),
        .init(
            id: "strength.e1rm", title: "Estimated 1RM", category: "Strength",
            valueKind: .massKilograms, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .bestSession,
            supportedShapes: sessionShapes, supportedDimensions: [.weekday],
            minimumHistoryDays: 14, requiresExerciseScope: true,
            supportedScopes: [.exercise]
        ),
        .init(
            // Distinct DAYS, and never session buckets — an event count per
            // session is a constant 1.
            id: "strength.exerciseFrequency", title: "Exercise frequency", category: "Strength",
            valueKind: .trainingDays, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .sum,
            supportedShapes: eventShapes, supportedDimensions: [.weekday],
            requiresExerciseScope: true,
            supportedScopes: [.exercise]
        ),
        .init(
            id: "strength.avgRPE", title: "Average RPE", category: "Strength",
            valueKind: .rpe, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .distanceWeightedMean,
            supportedShapes: sessionShapes, supportedDimensions: strengthDimensions,
            supportedScopes: [.exercise, .routine]
        ),
        .init(
            id: "strength.avgRIR", title: "Average RIR", category: "Strength",
            valueKind: .rir, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .distanceWeightedMean,
            supportedShapes: sessionShapes, supportedDimensions: strengthDimensions,
            supportedScopes: [.exercise, .routine]
        ),
        .init(
            id: "strength.volumeDensity", title: "Volume per minute", category: "Strength",
            valueKind: .massPerMinute, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .distanceWeightedMean,
            supportedShapes: sessionShapes, supportedDimensions: strengthDimensions,
            supportedScopes: [.routine]
        ),
        .init(
            id: "strength.relativeE1RM", title: "Relative strength (e1RM ÷ body weight)", category: "Strength",
            valueKind: .bodyweightMultiple, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .bestSession,
            supportedShapes: sessionShapes, supportedDimensions: [.weekday],
            requiresHealth: true, minimumHistoryDays: 14, requiresExerciseScope: true,
            supportedScopes: [.exercise]
        ),
        .init(
            // Distinct DAYS — two sessions on one day are one training day.
            // Session buckets would render a constant 1.
            id: "training.frequency", title: "Training days", category: "Strength",
            valueKind: .trainingDays, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .sum,
            supportedShapes: eventShapes, supportedDimensions: strengthDimensions,
            supportedScopes: [.modality, .routine],
            // One calendar day can contain several routines or sources; only
            // weekday partitions a distinct day exactly once.
            exclusiveGroupingDimensions: [.weekday]
        ),
    ]

    static let cardio: [InsightMetricDescriptor] = [
        .init(
            // Event count — session buckets would render a constant 1.
            id: "cardio.sessions", title: "Cardio sessions", category: "Cardio",
            valueKind: .sessions, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .sum,
            supportedShapes: eventShapes, supportedDimensions: cardioDimensions,
            supportedScopes: [.modality, .routine],
            exclusiveGroupingDimensions: cardioExclusiveDimensions
        ),
        .init(
            id: "cardio.duration", title: "Cardio duration", category: "Cardio",
            valueKind: .durationSeconds, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: sessionShapes, supportedDimensions: cardioDimensions,
            supportedScopes: [.modality, .routine],
            exclusiveGroupingDimensions: cardioExclusiveDimensions
        ),
        .init(
            id: "cardio.distance", title: "Distance", category: "Cardio",
            valueKind: .distanceMeters, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: optionalRecordedSumShapes, supportedDimensions: cardioDimensions,
            supportedScopes: [.modality, .routine],
            zeroFillPolicy: .never,
            exclusiveGroupingDimensions: cardioExclusiveDimensions
        ),
        .init(
            id: "cardio.pace", title: "Pace", category: "Cardio",
            valueKind: .pace, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .distanceWeightedMean,
            supportedShapes: sessionShapes, supportedDimensions: cardioDimensions,
            requiredScope: .modality,
            supportedScopes: [.modality, .routine],
            exclusiveGroupingDimensions: cardioExclusiveDimensions
        ),
        .init(
            id: "cardio.energy", title: "Active energy (workouts)", category: "Cardio",
            valueKind: .energyKilocalories, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: optionalRecordedSumShapes, supportedDimensions: cardioDimensions,
            supportedScopes: [.modality, .routine],
            zeroFillPolicy: .never,
            exclusiveGroupingDimensions: cardioExclusiveDimensions
        ),
        .init(
            id: "cardio.avgHR", title: "Average heart rate", category: "Cardio",
            valueKind: .heartRateBPM, timingRole: .either,
            // Duration-weighted mean — the observation's weight carries the
            // segment's seconds.
            nativeBuckets: [.session, .daily], aggregation: .distanceWeightedMean,
            supportedShapes: sessionShapes, supportedDimensions: cardioDimensions,
            supportedScopes: [.modality, .routine],
            exclusiveGroupingDimensions: cardioExclusiveDimensions
        ),
        .init(
            id: "cardio.maxHR", title: "Max heart rate", category: "Cardio",
            valueKind: .heartRateBPM, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .max,
            supportedShapes: sessionShapes, supportedDimensions: cardioDimensions,
            supportedScopes: [.modality, .routine],
            exclusiveGroupingDimensions: cardioExclusiveDimensions
        ),
        .init(
            id: "cardio.zoneTime", title: "Time in zones 4–5", category: "Cardio",
            valueKind: .durationSeconds, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: optionalRecordedSumShapes, supportedDimensions: cardioDimensions,
            supportedScopes: [.modality, .routine],
            zeroFillPolicy: .never,
            exclusiveGroupingDimensions: cardioExclusiveDimensions
        ),
        .init(
            id: "cardio.power", title: "Average power", category: "Cardio",
            valueKind: .power, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .distanceWeightedMean,
            supportedShapes: sessionShapes, supportedDimensions: cardioDimensions,
            requiredScope: .modality,
            supportedScopes: [.modality, .routine],
            exclusiveGroupingDimensions: cardioExclusiveDimensions
        ),
        .init(
            id: "cardio.elevation", title: "Elevation gain", category: "Cardio",
            valueKind: .elevationMeters, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: optionalRecordedSumShapes, supportedDimensions: cardioDimensions,
            supportedScopes: [.modality, .routine],
            zeroFillPolicy: .never,
            exclusiveGroupingDimensions: cardioExclusiveDimensions
        ),
        .init(
            id: "cardio.steps", title: "Workout steps", category: "Cardio",
            valueKind: .steps, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: optionalRecordedSumShapes, supportedDimensions: cardioDimensions,
            supportedScopes: [.modality, .routine],
            zeroFillPolicy: .never,
            exclusiveGroupingDimensions: cardioExclusiveDimensions
        ),
    ]

    static let yoga: [InsightMetricDescriptor] = [
        .init(
            id: "yoga.sessions", title: "Yoga sessions", category: "Yoga",
            valueKind: .sessions, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .sum,
            supportedShapes: eventShapes, supportedDimensions: yogaDimensions,
            supportedScopes: [.routine]
        ),
        .init(
            id: "yoga.duration", title: "Yoga duration", category: "Yoga",
            valueKind: .durationSeconds, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: sessionShapes, supportedDimensions: yogaDimensions,
            supportedScopes: [.routine]
        ),
        .init(
            id: "yoga.poses", title: "Poses completed", category: "Yoga",
            valueKind: .count, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: sessionShapes, supportedDimensions: yogaDimensions,
            supportedScopes: [.routine]
        ),
    ]

    static let health: [InsightMetricDescriptor] = [
        .init(
            id: "health.sleepTotal", title: "Sleep duration", category: "Recovery",
            valueKind: .durationSeconds, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .mean,
            supportedShapes: sessionShapes, supportedDimensions: healthDimensions,
            requiresHealth: true,
            supportedScopes: []
        ),
        .init(
            id: "health.sleepDeep", title: "Deep sleep", category: "Recovery",
            valueKind: .durationSeconds, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .mean,
            supportedShapes: sessionShapes, supportedDimensions: healthDimensions,
            requiresHealth: true,
            supportedScopes: []
        ),
        .init(
            id: "health.sleepREM", title: "REM sleep", category: "Recovery",
            valueKind: .durationSeconds, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .mean,
            supportedShapes: sessionShapes, supportedDimensions: healthDimensions,
            requiresHealth: true,
            supportedScopes: []
        ),
        .init(
            id: "health.hrv", title: "HRV", category: "Recovery",
            valueKind: .heartRateVariabilityMS, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .mean,
            supportedShapes: sessionShapes, supportedDimensions: healthDimensions,
            requiresHealth: true,
            supportedScopes: []
        ),
        .init(
            id: "health.restingHR", title: "Resting heart rate", category: "Recovery",
            valueKind: .heartRateBPM, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .mean,
            supportedShapes: sessionShapes, supportedDimensions: healthDimensions,
            requiresHealth: true,
            supportedScopes: []
        ),
        .init(
            id: "health.respiratoryRate", title: "Respiratory rate", category: "Recovery",
            valueKind: .breathsPerMinute, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .mean,
            supportedShapes: sessionShapes, supportedDimensions: healthDimensions,
            requiresHealth: true,
            supportedScopes: []
        ),
        .init(
            id: "health.oxygenSaturation", title: "Blood oxygen", category: "Recovery",
            valueKind: .percentage, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .mean,
            supportedShapes: sessionShapes, supportedDimensions: healthDimensions,
            requiresHealth: true,
            supportedScopes: []
        ),
        .init(
            id: "health.bodyweight", title: "Body weight", category: "Recovery",
            valueKind: .massKilograms, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .lastValue,
            supportedShapes: sessionShapes, supportedDimensions: healthDimensions,
            requiresHealth: true, minimumHistoryDays: 14,
            supportedScopes: []
        ),
        .init(
            id: "health.steps", title: "Daily steps", category: "Activity",
            valueKind: .steps, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .sum,
            supportedShapes: optionalRecordedSumShapes, supportedDimensions: healthDimensions,
            requiresHealth: true,
            supportedScopes: [],
            zeroFillPolicy: .never
        ),
        .init(
            id: "health.exerciseMinutes", title: "Exercise minutes", category: "Activity",
            valueKind: .durationSeconds, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .sum,
            supportedShapes: optionalRecordedSumShapes, supportedDimensions: healthDimensions,
            requiresHealth: true,
            supportedScopes: [],
            zeroFillPolicy: .never
        ),
        .init(
            id: "health.activeEnergy", title: "Active energy (daily)", category: "Activity",
            valueKind: .energyKilocalories, timingRole: .either,
            nativeBuckets: [.daily], aggregation: .sum,
            supportedShapes: optionalRecordedSumShapes, supportedDimensions: healthDimensions,
            requiresHealth: true,
            supportedScopes: [],
            zeroFillPolicy: .never
        ),
        .init(
            id: "health.readiness", title: "Readiness at workout start", category: "Recovery",
            valueKind: .readinessScore, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .mean,
            supportedShapes: sessionShapes, supportedDimensions: strengthDimensions,
            supportedScopes: []
        ),
    ]

    // MARK: - Producers

    /// Everything a producer may draw on. Health inputs arrive as the same
    /// daily records HealthService already derives; sessions delegate to
    /// TrainingAnalytics via the snapshotter.
    struct Inputs: Sendable {
        var sessions: [InsightSessionSnapshot] = []
        var health: [InsightDailyHealthSnapshot] = []
        var activity: [InsightDailyActivitySnapshot] = []
        var bodyweight: [InsightObservation] = []
        /// Per-exercise e1RM series — operands pick theirs by scope.
        var e1rmByExercise: [UUID: [InsightObservation]] = [:]
        /// When an exercise filter is active, strength volume/sets/reps read
        /// the exercise's own numbers instead of the whole workout's.
        var scopedExerciseID: UUID?
    }

    /// Operand-level production: apply the operand's OWN scope (exercise /
    /// modality / routine), then run the metric's producer. Recipe-level
    /// filters already narrowed `inputs.sessions` for everyone.
    static func observations(for operand: InsightOperand, inputs: Inputs) -> [InsightObservation] {
        var scoped = inputs
        if let routineID = operand.routineID {
            scoped.sessions = scoped.sessions.filter { $0.routineID == routineID }
        }
        if let exerciseID = operand.exerciseID {
            scoped.sessions = scoped.sessions.filter { $0.exerciseIDs.contains(exerciseID) }
            scoped.scopedExerciseID = exerciseID
        }
        if let modality = operand.modality {
            scoped.sessions = scoped.sessions.compactMap { session in
                guard session.cardioSegments.contains(where: { $0.modality == modality })
                    || session.modality == modality else { return nil }
                var copy = session
                copy.cardioSegments = copy.cardioSegments.filter { $0.modality == modality }
                return copy
            }
        }
        return observations(for: operand.metricID, inputs: scoped)
    }

    /// User-facing title for an operand key: metric title plus its scope
    /// ("Estimated 1RM · Bench Press", "Pace · Run"). v1 recipes carry the
    /// scope in the shared exercise filter instead — pass the recipe so
    /// those still resolve.
    static func operandTitle(
        forKey key: String,
        recipe: InsightRecipe? = nil,
        exerciseNames: [UUID: String] = [:],
        routineNames: [UUID: String] = [:]
    ) -> String {
        let parts = key.components(separatedBy: "#")
        let metricID = parts.first ?? key
        guard let descriptor = definition(for: metricID) else { return key }
        var title = descriptor.title
        var scoped = false
        for part in parts.dropFirst() {
            if part.hasPrefix("ex:"), let id = UUID(uuidString: String(part.dropFirst(3))) {
                title += " · \(exerciseNames[id] ?? "exercise")"
                scoped = true
            } else if part.hasPrefix("mod:") {
                title += " · \(String(part.dropFirst(4)).capitalized)"
                scoped = true
            } else if part.hasPrefix("rt:"), let id = UUID(uuidString: String(part.dropFirst(3))) {
                title += " · \(routineNames[id] ?? "routine")"
                scoped = true
            }
        }
        if !scoped, descriptor.requiresExerciseScope,
           let recipe,
           let filterID = recipe.filters.first(where: { $0.dimension == .exercise })?.values.first
               .flatMap(UUID.init),
           let name = exerciseNames[filterID] {
            title += " · \(name)"
        }
        return title
    }

    /// Session-native metrics emit one observation per qualifying session;
    /// daily-native health metrics one per day with data. The query engine
    /// buckets and aggregates downstream using the descriptor's rule.
    static func observations(for id: String, inputs: Inputs) -> [InsightObservation] {
        switch id {
        case "strength.workouts":
            return inputs.sessions.filter(\.hasStrength).map { $0.observation(1) }
        case "strength.duration":
            // The strength SHARE of a session — a hybrid workout's run time
            // never counts as lifting time.
            return inputs.sessions.filter { $0.hasStrength && $0.strengthDurationSeconds > 0 }
                .map { $0.observation(Double($0.strengthDurationSeconds)) }
        case "strength.workingSets":
            if let scoped = inputs.scopedExerciseID {
                return inputs.sessions.compactMap { session in
                    session.exerciseSets[scoped].map { session.observation($0) }
                }
            }
            return inputs.sessions.filter { $0.workingSets > 0 }.map { $0.observation($0.workingSets) }
        case "strength.reps":
            if let scoped = inputs.scopedExerciseID {
                return inputs.sessions.compactMap { session in
                    session.exerciseReps[scoped].map { session.observation(Double($0)) }
                }
            }
            return inputs.sessions.filter { $0.reps > 0 }.map { $0.observation(Double($0.reps)) }
        case "strength.volume":
            if let scoped = inputs.scopedExerciseID {
                return inputs.sessions.compactMap { session in
                    session.exerciseVolumeKg[scoped].map { session.observation($0) }
                }
            }
            return inputs.sessions.filter { $0.volumeKg > 0 }.map { $0.observation($0.volumeKg) }
        case "strength.e1rm":
            return inputs.scopedExerciseID.flatMap { inputs.e1rmByExercise[$0] } ?? []
        case "strength.avgRPE":
            // Weighted by logged working sets so a day's average is the
            // average of its SETS, not of session means.
            if let scoped = inputs.scopedExerciseID {
                return inputs.sessions.compactMap { session in
                    session.exerciseRPE[scoped].map {
                        session.observation($0, weight: Double(max(session.exerciseRPECounts[scoped] ?? 1, 1)))
                    }
                }
            }
            return inputs.sessions.compactMap { session in
                session.avgRPE.map { session.observation($0, weight: Double(max(session.rpeSampleCount, 1))) }
            }
        case "strength.avgRIR":
            if let scoped = inputs.scopedExerciseID {
                return inputs.sessions.compactMap { session in
                    session.exerciseRIR[scoped].map {
                        session.observation($0, weight: Double(max(session.exerciseRIRCounts[scoped] ?? 1, 1)))
                    }
                }
            }
            return inputs.sessions.compactMap { session in
                session.avgRIR.map { session.observation($0, weight: Double(max(session.rirSampleCount, 1))) }
            }
        case "strength.volumeDensity":
            // Work per strength minute — the strength SHARE of the clock.
            // Weighted by strength minutes, so any rollup equals total
            // volume ÷ total strength time, not a mean of session ratios.
            return inputs.sessions.compactMap { session in
                guard session.volumeKg > 0, session.strengthDurationSeconds >= 60 else { return nil }
                let minutes = Double(session.strengthDurationSeconds) / 60
                return session.observation(session.volumeKg / minutes, weight: minutes)
            }
        case "strength.relativeE1RM":
            // e1RM divided by the nearest body-weight reading within a week —
            // estimated by definition on both sides.
            let series = inputs.scopedExerciseID.flatMap { inputs.e1rmByExercise[$0] } ?? []
            let weights = inputs.bodyweight
            return series.compactMap { record in
                guard let nearest = weights.min(by: {
                    abs($0.timestamp.timeIntervalSince(record.timestamp)) < abs($1.timestamp.timeIntervalSince(record.timestamp))
                }), abs(nearest.timestamp.timeIntervalSince(record.timestamp)) <= 7 * 86_400,
                    nearest.value > 0 else { return nil }
                return InsightObservation(
                    timestamp: record.timestamp,
                    value: record.value / nearest.value,
                    provenance: .estimated
                )
            }
        case "training.frequency":
            // Distinct calendar days: a double session day is ONE training
            // day, so only each day's first session emits an observation.
            return distinctDayObservations(inputs.sessions)
        case "strength.exerciseFrequency":
            // Scoped upstream by the exercise filter; each qualifying DAY
            // counts once.
            return distinctDayObservations(inputs.sessions)

        // Cardio metrics read SEGMENTS: each cardio block is its own data
        // point with its own duration/HR/power — never the whole workout's.
        case "cardio.sessions":
            return segmentObservations(inputs) { _ in 1 }
        case "cardio.duration":
            return segmentObservations(inputs) { $0.durationSeconds > 0 ? Double($0.durationSeconds) : nil }
        case "cardio.distance":
            return segmentObservations(inputs) { $0.distanceMeters }
        case "cardio.pace":
            // Seconds per meter; the renderer formats via the distance unit.
            // The paired distance rides `weight` so the aggregator's
            // distance-weighted mean is honest.
            return inputs.sessions.flatMap { session in
                session.cardioSegments.compactMap { segment -> InsightObservation? in
                    guard let meters = segment.distanceMeters, meters > 100, segment.durationSeconds > 0 else { return nil }
                    var row = observation(value: Double(segment.durationSeconds) / meters, segment: segment, session: session)
                    row.weight = meters
                    return row
                }
            }
        case "cardio.energy":
            return segmentObservations(inputs) { $0.activeEnergyKcal }
        case "cardio.avgHR":
            // Duration-weighted: a five-minute block must not count as much
            // as an hour (`weight` drives the aggregator's weighted mean).
            return weightedSegmentObservations(inputs) { $0.avgHR.map(Double.init) }
        case "cardio.maxHR":
            return segmentObservations(inputs) { $0.maxHR.map(Double.init) }
        case "cardio.zoneTime":
            return segmentObservations(inputs) { segment in
                guard segment.zoneSeconds.count >= 5 else { return nil }
                let hard = segment.zoneSeconds[3] + segment.zoneSeconds[4]
                // A complete zone record with no hard-zone time is an exact
                // zero. Dropping it would bias the distribution upward.
                return Double(hard)
            }
        case "cardio.power":
            return weightedSegmentObservations(inputs) { $0.avgPowerWatts }
        case "cardio.elevation":
            return segmentObservations(inputs) { $0.elevationGainMeters }
        case "cardio.steps":
            return segmentObservations(inputs) { $0.steps.map(Double.init) }

        case "yoga.sessions":
            return inputs.sessions.filter(\.hasYoga).map { $0.observation(1) }
        case "yoga.duration":
            // The yoga sessions' own recorded time, not the workout's.
            return inputs.sessions.filter { $0.yogaDurationSeconds > 0 }
                .map { $0.observation(Double($0.yogaDurationSeconds)) }
        case "yoga.poses":
            return inputs.sessions.filter { $0.yogaPosesCompleted > 0 }
                .map { $0.observation(Double($0.yogaPosesCompleted)) }

        case "health.sleepTotal":
            return inputs.health.compactMap { day in
                day.sleepTotalMinutes.map { day.observation(Double($0) * 60) }
            }
        case "health.sleepDeep":
            return inputs.health.compactMap { day in
                day.sleepDeepMinutes.map { day.observation(Double($0) * 60) }
            }
        case "health.sleepREM":
            return inputs.health.compactMap { day in
                day.sleepREMMinutes.map { day.observation(Double($0) * 60) }
            }
        case "health.hrv":
            // Nocturnal window preferred over the all-day mean — the same
            // preference RecoveryEngine documents and uses.
            return inputs.health.compactMap { day in
                (day.nocturnalHRV ?? day.hrvSDNN).map { day.observation($0) }
            }
        case "health.restingHR":
            return inputs.health.compactMap { day in
                (day.sleepingHR ?? day.restingHR).map { day.observation(Double($0)) }
            }
        case "health.respiratoryRate":
            return inputs.health.compactMap { day in
                day.respiratoryRate.map { day.observation($0) }
            }
        case "health.oxygenSaturation":
            return inputs.health.compactMap { day in
                day.oxygenSaturationPercent.map { day.observation($0) }
            }
        case "health.bodyweight":
            return inputs.bodyweight
        case "health.steps":
            return inputs.activity.compactMap { day in
                day.steps.map { day.observation($0) }
            }
        case "health.exerciseMinutes":
            return inputs.activity.compactMap { day in
                day.exerciseMinutes.map { day.observation($0 * 60) }
            }
        case "health.activeEnergy":
            return inputs.activity.compactMap { day in
                day.activeEnergyKcal.map { day.observation($0) }
            }
        case "health.readiness":
            return inputs.sessions.compactMap { session in
                session.readinessAtStart.map { session.observation($0) }
            }
        default:
            if let muscle = muscle(fromMetricID: id) {
                return inputs.sessions.compactMap { session in
                    session.muscleSets[muscle].map { session.observation($0) }
                }
            }
            return []
        }
    }

    /// One `1` per distinct calendar day (per category, so grouped
    /// comparisons keep their tag duplication) — the producer behind
    /// day-count metrics.
    private static func distinctDayObservations(_ sessions: [InsightSessionSnapshot]) -> [InsightObservation] {
        var seen = Set<String>()
        let calendar = Calendar.current
        return sessions.sorted { $0.startedAt < $1.startedAt }.compactMap { session in
            let day = calendar.startOfDay(for: session.startedAt)
            let key = "\(day.timeIntervalSinceReferenceDate)#\(session.category ?? "")"
            guard seen.insert(key).inserted else { return nil }
            return session.observation(1)
        }
    }

    private static func segmentObservations(
        _ inputs: Inputs,
        value: (InsightCardioSegment) -> Double?
    ) -> [InsightObservation] {
        inputs.sessions.flatMap { session in
            session.cardioSegments.compactMap { segment in
                value(segment).map { observation(value: $0, segment: segment, session: session) }
            }
        }
    }

    /// Duration-weighted variant for intensity means (HR, power).
    private static func weightedSegmentObservations(
        _ inputs: Inputs,
        value: (InsightCardioSegment) -> Double?
    ) -> [InsightObservation] {
        inputs.sessions.flatMap { session in
            session.cardioSegments.compactMap { segment -> InsightObservation? in
                guard let raw = value(segment), segment.durationSeconds > 0 else { return nil }
                var row = observation(value: raw, segment: segment, session: session)
                row.weight = Double(segment.durationSeconds)
                return row
            }
        }
    }

    private static func observation(
        value: Double,
        segment: InsightCardioSegment,
        session: InsightSessionSnapshot
    ) -> InsightObservation {
        InsightObservation(
            // A session bucket means the containing workout session. All of
            // its cardio blocks use the workout anchor so strength/readiness
            // and cardio observations align, then the query engine aggregates
            // multiple blocks under the metric's own rule.
            timestamp: session.startedAt,
            value: value,
            provenance: segment.isImported ? .imported : session.provenance,
            category: {
                // Source grouping belongs to the contributing segment, not
                // necessarily the surrounding workout container.
                if session.category == "Imported" || session.category == "Logged" {
                    return segment.isImported ? "Imported" : "Logged"
                }
                return session.category
            }()
        )
    }

}

// MARK: - Health snapshot rows

/// Sendable projections of HealthService's daily derivations — field names
/// and preference semantics mirror `RecoveryEngine.DailyHealthMetric`.
struct InsightDailyHealthSnapshot: Sendable, Equatable {
    var date: Date
    var hrvSDNN: Double?
    var nocturnalHRV: Double?
    var restingHR: Int?
    var sleepingHR: Int?
    var respiratoryRate: Double?
    var oxygenSaturationPercent: Double?
    var sleepTotalMinutes: Int?
    var sleepDeepMinutes: Int?
    var sleepREMMinutes: Int?
    var isEstimated: Bool

    func observation(_ value: Double) -> InsightObservation {
        InsightObservation(timestamp: date, value: value, provenance: isEstimated ? .estimated : .measured)
    }
}

struct InsightDailyActivitySnapshot: Sendable, Equatable {
    var date: Date
    var steps: Double?
    var exerciseMinutes: Double?
    var activeEnergyKcal: Double?

    func observation(_ value: Double) -> InsightObservation {
        InsightObservation(timestamp: date, value: value, provenance: .measured)
    }
}

private extension InsightSessionSnapshot {
    func observation(_ value: Double) -> InsightObservation {
        InsightObservation(timestamp: startedAt, value: value, provenance: provenance, category: category)
    }

    /// Weighted observation for `distanceWeightedMean` metrics — the weight
    /// is whatever quantity the value is a ratio OVER (strength minutes for
    /// volume density, logged sets for RPE/RIR), so the rollup reproduces a
    /// ratio of sums instead of a mean of ratios.
    func observation(_ value: Double, weight: Double) -> InsightObservation {
        InsightObservation(
            timestamp: startedAt, value: value, provenance: provenance,
            category: category, weight: weight
        )
    }

    /// Segment observations keep the session's provenance and group but
    /// carry the segment's own timestamp.
    func observation(_ value: Double, at date: Date) -> InsightObservation {
        InsightObservation(timestamp: date, value: value, provenance: provenance, category: category)
    }
}
