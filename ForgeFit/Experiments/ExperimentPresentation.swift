import ForgeCore
import ForgeData
import Foundation

/// View-local setup state. It intentionally stays outside SwiftData so
/// cancelling setup never leaves a half-created experiment in the store.
struct ExperimentSetupDraft {
    var name = ""
    var protocolDescription = ""
    var question = ""
    var durationPreset: ExperimentDurationPreset = .eightWeeks
    var customEndDate = Calendar.current.date(byAdding: .weekOfYear, value: 8, to: Date()) ?? Date()
    var headlineMetricIDs: Set<String> = [
        "strength.volume",
        "strength.workingSets",
        "cardio.duration",
    ]
    var trackers: [ExperimentSetupTrackerDraft] = []
    var reminderEnabled = false
    var reminderTime = Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: Date()) ?? Date()

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var resolvedEndDate: Date {
        durationPreset.endDate(from: Date(), customDate: customEndDate)
    }

    var canStart: Bool {
        !trimmedName.isEmpty && resolvedEndDate > Date()
    }
}

struct ExperimentHeadlineMetricOption: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String

    static let all: [ExperimentHeadlineMetricOption] = [
        .init(
            id: "strength.volume", title: "Strength Volume",
            detail: "Working-set load × reps", systemImage: "dumbbell.fill"
        ),
        .init(
            id: "strength.workingSets", title: "Working Sets",
            detail: "Completed working sets", systemImage: "checklist"
        ),
        .init(
            id: "strength.reps", title: "Total Reps",
            detail: "Completed working reps", systemImage: "repeat"
        ),
        .init(
            id: "cardio.duration", title: "Cardio Time",
            detail: "Recorded cardio duration", systemImage: "figure.run"
        ),
        .init(
            id: "cardio.distance", title: "Cardio Distance",
            detail: "Sessions with distance", systemImage: "point.topleft.down.to.point.bottomright.curvepath"
        ),
        .init(
            id: "yoga.duration", title: "Yoga Time",
            detail: "Recorded practice duration", systemImage: "figure.mind.and.body"
        ),
        .init(
            id: "health.sleepTotal", title: "Sleep",
            detail: "Complete nights from Health", systemImage: "moon.zzz.fill"
        ),
        .init(
            id: "health.sleepDeep", title: "Deep Sleep",
            detail: "Complete nights from Health", systemImage: "moon.stars.fill"
        ),
        .init(
            id: "health.sleepREM", title: "REM Sleep",
            detail: "Complete nights from Health", systemImage: "brain.head.profile"
        ),
        .init(
            id: "health.hrv", title: "HRV",
            detail: "Available daily Health readings", systemImage: "waveform.path.ecg"
        ),
        .init(
            id: "health.restingHR", title: "Resting Heart Rate",
            detail: "Available daily Health readings", systemImage: "heart.fill"
        ),
        .init(
            id: "health.respiratoryRate", title: "Respiratory Rate",
            detail: "Available daily Health readings", systemImage: "lungs.fill"
        ),
        .init(
            id: "health.oxygenSaturation", title: "Blood Oxygen",
            detail: "Available daily Health readings", systemImage: "drop.fill"
        ),
        .init(
            id: "health.bodyweight", title: "Body Weight",
            detail: "Available measurements from Health", systemImage: "scalemass.fill"
        ),
        .init(
            id: "health.steps", title: "Steps",
            detail: "Complete days from Health", systemImage: "figure.walk"
        ),
        .init(
            id: "health.exerciseMinutes", title: "Exercise Minutes",
            detail: "Complete days from Health", systemImage: "timer"
        ),
        .init(
            id: "health.activeEnergy", title: "Active Energy",
            detail: "Complete days from Health", systemImage: "flame.fill"
        ),
    ]

    var selection: ExperimentMetricSelection {
        switch id {
        case "strength.volume":
            .init(
                metricID: id, valueKind: .massKilograms, aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case "strength.workingSets":
            .init(
                metricID: id, valueKind: .count, aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case "strength.reps":
            .init(
                metricID: id, valueKind: .reps, aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case "cardio.duration", "yoga.duration":
            .init(
                metricID: id, valueKind: .durationSeconds, aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case "cardio.distance":
            .init(
                metricID: id,
                valueKind: .distanceMeters,
                aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case "health.sleepTotal", "health.sleepDeep", "health.sleepREM":
            .init(metricID: id, valueKind: .durationSeconds, aggregation: .mean)
        case "health.hrv":
            .init(metricID: id, valueKind: .heartRateVariabilityMS, aggregation: .mean)
        case "health.restingHR":
            .init(metricID: id, valueKind: .heartRateBPM, aggregation: .mean)
        case "health.respiratoryRate":
            .init(metricID: id, valueKind: .breathsPerMinute, aggregation: .mean)
        case "health.oxygenSaturation":
            .init(metricID: id, valueKind: .percentage, aggregation: .mean)
        case "health.bodyweight":
            .init(metricID: id, valueKind: .massKilograms, aggregation: .mean)
        case "health.steps":
            .init(metricID: id, valueKind: .steps, aggregation: .mean)
        case "health.exerciseMinutes":
            .init(metricID: id, valueKind: .durationSeconds, aggregation: .mean)
        case "health.activeEnergy":
            .init(metricID: id, valueKind: .energyKilocalories, aggregation: .mean)
        default:
            .init(metricID: id, aggregation: .mean)
        }
    }
}

/// Scoped training outcomes shown below the experiment's global headline
/// outcomes. Their aggregation rules mirror Insights Builder so the same
/// recorded training has the same meaning on both surfaces.
enum ExperimentDetailedMetric: String, CaseIterable, Identifiable {
    case exerciseVolume = "strength.volume"
    case exerciseWorkingSets = "strength.workingSets"
    case exerciseFrequency = "strength.exerciseFrequency"
    case exerciseBestLoad = "strength.effectiveLoad"
    case exerciseBestEstimated1RM = "strength.e1rm"
    case cardioSessions = "cardio.sessions"
    case cardioDuration = "cardio.duration"
    case cardioDistance = "cardio.distance"
    case cardioPace = "cardio.pace"
    case cardioAverageHeartRate = "cardio.avgHR"
    case cardioMaximumHeartRate = "cardio.maxHR"
    case cardioHighZoneTime = "cardio.zoneTime"
    case cardioActiveEnergy = "cardio.energy"
    case cardioPower = "cardio.power"
    case cardioElevation = "cardio.elevation"
    case cardioSteps = "cardio.steps"

    var id: String { rawValue }

    static let strength: [ExperimentDetailedMetric] = [
        .exerciseVolume,
        .exerciseWorkingSets,
        .exerciseFrequency,
        .exerciseBestLoad,
        .exerciseBestEstimated1RM,
    ]

    static let cardio: [ExperimentDetailedMetric] = [
        .cardioSessions,
        .cardioDuration,
        .cardioDistance,
        .cardioPace,
        .cardioAverageHeartRate,
        .cardioMaximumHeartRate,
        .cardioHighZoneTime,
        .cardioActiveEnergy,
        .cardioPower,
        .cardioElevation,
        .cardioSteps,
    ]

    var title: String {
        switch self {
        case .exerciseVolume: "Working volume"
        case .exerciseWorkingSets: "Working sets"
        case .exerciseFrequency: "Training days"
        case .exerciseBestLoad: "Best effective load"
        case .exerciseBestEstimated1RM: "Best estimated 1RM"
        case .cardioSessions: "Sessions"
        case .cardioDuration: "Duration"
        case .cardioDistance: "Distance"
        case .cardioPace: "Pace"
        case .cardioAverageHeartRate: "Average heart rate"
        case .cardioMaximumHeartRate: "Maximum heart rate"
        case .cardioHighZoneTime: "Time in zones 4–5"
        case .cardioActiveEnergy: "Active energy"
        case .cardioPower: "Average power"
        case .cardioElevation: "Elevation gain"
        case .cardioSteps: "Steps"
        }
    }

    var scopeKind: ExperimentMetricScopeKind {
        switch self {
        case .exerciseVolume, .exerciseWorkingSets, .exerciseFrequency,
             .exerciseBestLoad, .exerciseBestEstimated1RM:
            .exercise
        default:
            .modality
        }
    }

    func selection(scopeID: String) -> ExperimentMetricSelection {
        let scope = ExperimentMetricScope(kind: scopeKind, id: scopeID)
        return switch self {
        case .exerciseVolume:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .massKilograms,
                aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case .exerciseWorkingSets:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .count,
                aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case .exerciseFrequency:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .trainingDays,
                aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case .exerciseBestLoad, .exerciseBestEstimated1RM:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .massKilograms,
                aggregation: .maximum
            )
        case .cardioSessions:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .sessions,
                aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case .cardioDuration:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .durationSeconds,
                aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case .cardioDistance:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .distanceMeters,
                aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case .cardioPace:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .pace,
                aggregation: .weightedMean
            )
        case .cardioAverageHeartRate:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .heartRateBPM,
                aggregation: .weightedMean
            )
        case .cardioMaximumHeartRate:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .heartRateBPM,
                aggregation: .maximum
            )
        case .cardioHighZoneTime:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .durationSeconds,
                aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case .cardioActiveEnergy:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .energyKilocalories,
                aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case .cardioPower:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .power,
                aggregation: .weightedMean
            )
        case .cardioElevation:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .elevationMeters,
                aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        case .cardioSteps:
            .init(
                metricID: rawValue,
                scope: scope,
                valueKind: .steps,
                aggregation: .sum,
                missingValuePolicy: .zeroWhenAbsent
            )
        }
    }
}

struct ExperimentScopedComparison: Identifiable, Equatable {
    let id: String
    let title: String
    let scopeKind: ExperimentMetricScopeKind
    let metrics: [ExperimentMetricDelta]

    func delta(for metric: ExperimentDetailedMetric) -> ExperimentMetricDelta? {
        metrics.first {
            $0.selection.metricID == metric.rawValue
                && $0.selection.scope?.kind == scopeKind
                && $0.selection.scope?.id == id
        }
    }
}

enum ExperimentDetailedComparisonPresentation {
    static func exerciseComparisons(
        from result: ExperimentResult,
        namesByID: [UUID: String]
    ) -> [ExperimentScopedComparison] {
        comparisons(
            from: result,
            scopeKind: .exercise,
            supportedMetrics: ExperimentDetailedMetric.strength
        ) { rawID in
            UUID(uuidString: rawID).flatMap { namesByID[$0] } ?? "Unknown exercise"
        }
        .sorted(by: comparisonSort(primaryMetric: .exerciseVolume))
    }

    static func cardioComparisons(
        from result: ExperimentResult
    ) -> [ExperimentScopedComparison] {
        comparisons(
            from: result,
            scopeKind: .modality,
            supportedMetrics: ExperimentDetailedMetric.cardio
        ) { CardioKind.from(modality: $0).title }
        .sorted(by: comparisonSort(primaryMetric: .cardioDuration))
    }

    private static func comparisons(
        from result: ExperimentResult,
        scopeKind: ExperimentMetricScopeKind,
        supportedMetrics: [ExperimentDetailedMetric],
        title: (String) -> String
    ) -> [ExperimentScopedComparison] {
        let supportedIDs = Set(supportedMetrics.map(\.rawValue))
        let scoped = result.metrics.filter {
            $0.selection.scope?.kind == scopeKind
                && supportedIDs.contains($0.selection.metricID)
        }
        return Dictionary(grouping: scoped) { $0.selection.scope?.id ?? "" }
            .compactMap { id, metrics in
                guard !id.isEmpty else { return nil }
                return ExperimentScopedComparison(
                    id: id,
                    title: title(id),
                    scopeKind: scopeKind,
                    metrics: metrics
                )
            }
    }

    private static func comparisonSort(
        primaryMetric: ExperimentDetailedMetric
    ) -> (ExperimentScopedComparison, ExperimentScopedComparison) -> Bool {
        { lhs, rhs in
            let lhsValue = lhs.delta(for: primaryMetric)?.current.value ?? 0
            let rhsValue = rhs.delta(for: primaryMetric)?.current.value ?? 0
            if lhsValue != rhsValue { return lhsValue > rhsValue }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

enum ExperimentDurationPreset: String, CaseIterable, Identifiable {
    case twoWeeks
    case fourWeeks
    case sixWeeks
    case eightWeeks
    case twelveWeeks
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twoWeeks: "2 weeks"
        case .fourWeeks: "4 weeks"
        case .sixWeeks: "6 weeks"
        case .eightWeeks: "8 weeks"
        case .twelveWeeks: "12 weeks"
        case .custom: "Custom"
        }
    }

    private var weekCount: Int? {
        switch self {
        case .twoWeeks: 2
        case .fourWeeks: 4
        case .sixWeeks: 6
        case .eightWeeks: 8
        case .twelveWeeks: 12
        case .custom: nil
        }
    }

    func endDate(from start: Date, customDate: Date, calendar: Calendar = .current) -> Date {
        guard let weekCount else { return customDate }
        return calendar.date(byAdding: .weekOfYear, value: weekCount, to: start) ?? customDate
    }
}

struct ExperimentSetupTrackerDraft: Identifiable, Equatable {
    var id = UUID()
    var label = ""
    var kind: ExperimentTrackerUIKind = .number
    var unit = ""
    var lowLabel = ""
    var highLabel = ""
    var choices: [String] = []
    var cadence: ExperimentTrackerUICadence = .daily
    var weekdays: Set<Int> = []

    var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSave: Bool {
        guard !trimmedLabel.isEmpty else { return false }
        guard cadence != .selectedDays || !weekdays.isEmpty else { return false }
        guard kind != .choice
                || choices.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .filter({ !$0.isEmpty }).count >= 2
        else { return false }
        return true
    }
}

enum ExperimentTrackerUIKind: String, CaseIterable, Identifiable {
    case number
    case yesNo = "boolean"
    case rating
    case choice
    case note

    var id: String { rawValue }

    var title: String {
        switch self {
        case .number: "Number"
        case .yesNo: "Yes / No"
        case .rating: "1–5 Rating"
        case .choice: "Single Choice"
        case .note: "Note"
        }
    }

    var systemImage: String {
        switch self {
        case .number: "number"
        case .yesNo: "checkmark.circle"
        case .rating: "slider.horizontal.3"
        case .choice: "list.bullet.circle"
        case .note: "note.text"
        }
    }
}

enum ExperimentTrackerUICadence: String, CaseIterable, Identifiable {
    case daily
    case selectedDays = "selectedWeekdays"
    case eachWorkout = "perWorkout"
    case anytime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: "Daily"
        case .selectedDays: "Selected Days"
        case .eachWorkout: "After Each Workout"
        case .anytime: "Anytime"
        }
    }

    var compactTitle: String {
        switch self {
        case .daily: "Daily"
        case .selectedDays: "Selected days"
        case .eachWorkout: "Each workout"
        case .anytime: "Anytime"
        }
    }
}

/// The shared, deterministic training rollup rendered on active and completed
/// experiment screens. Membership is anchored to workout start and the end is
/// exclusive, matching the feature's data contract.
@MainActor
struct ExperimentTrainingRollup: Equatable {
    var workouts = 0
    var trainingDays = 0
    var durationSeconds = 0
    var strengthWorkouts = 0
    var strengthVolume = 0.0
    var strengthVolumeSamples = 0
    var strengthSetSamples = 0
    var workingSets = 0.0
    var reps = 0
    var repsSamples = 0
    var cardioSessions = 0
    var cardioDurationSeconds = 0
    var cardioDurationSamples = 0
    var cardioDistanceMeters = 0.0
    var cardioDistanceSamples = 0
    var yogaSessions = 0
    var yogaDurationSeconds = 0
    var yogaDurationSamples = 0
    var yogaPoses = 0
    var yogaPoseSamples = 0

    static func make(
        workouts allWorkouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> ExperimentTrainingRollup {
        let included = allWorkouts.filter {
            $0.deletedAt == nil
                && $0.endedAt != nil
                && $0.startedAt >= start
                && $0.startedAt < end
        }
        let analytics = TrainingAnalytics(workouts: included, exercises: exercises, calendar: calendar)
        let summaries = included.map(analytics.summary(for:))
        let workingSetRows = included
            .flatMap(\.exercises)
            .flatMap(\.sets)
            .filter {
                $0.completedAt != nil && $0.setType.countsAsWorkingVolume
            }
        let recordedVolumes = workingSetRows.compactMap {
            ExperimentAnalysisAdapter.optionalTotalVolume(for: $0)
        }
        let recordedReps = workingSetRows.compactMap(\.reps)
        let cardio = included.flatMap(\.cardioSessions).filter {
            $0.deletedAt == nil && $0.endedAt != nil && !$0.isYogaSession
        }
        let yoga = included.flatMap(\.cardioSessions).filter {
            $0.deletedAt == nil && $0.endedAt != nil && $0.isYogaSession
        }
        let recordedDistances = cardio.compactMap(\.distanceMeters)
        let recordedDuration = included.reduce(0) { total, workout in
            let elapsed = workout.endedAt.map {
                max(0, Int($0.timeIntervalSince(workout.startedAt)))
            } ?? 0
            guard elapsed == 0 else { return total + elapsed }
            let sessionDuration = workout.cardioSessions
                .filter { $0.deletedAt == nil && $0.endedAt != nil }
                .compactMap(\.durationSeconds)
                .reduce(0, +)
            return total + sessionDuration
        }

        return ExperimentTrainingRollup(
            workouts: included.count,
            trainingDays: Set(included.map { calendar.startOfDay(for: $0.startedAt) }).count,
            durationSeconds: recordedDuration,
            strengthWorkouts: summaries.count(where: \.hasStrength),
            strengthVolume: recordedVolumes.reduce(0, +),
            strengthVolumeSamples: recordedVolumes.count,
            strengthSetSamples: workingSetRows.count,
            workingSets: summaries.reduce(0) { $0 + $1.sets },
            reps: recordedReps.reduce(0, +),
            repsSamples: recordedReps.count,
            cardioSessions: cardio.count,
            cardioDurationSeconds: cardio.compactMap(\.durationSeconds).reduce(0, +),
            cardioDurationSamples: cardio.compactMap(\.durationSeconds).count,
            cardioDistanceMeters: recordedDistances.reduce(0, +),
            cardioDistanceSamples: recordedDistances.count,
            yogaSessions: yoga.count,
            yogaDurationSeconds: yoga.compactMap(\.durationSeconds).reduce(0, +),
            yogaDurationSamples: yoga.compactMap(\.durationSeconds).count,
            yogaPoses: yoga.compactMap(\.logicalYogaPosesCompleted).reduce(0, +),
            yogaPoseSamples: yoga.compactMap(\.logicalYogaPosesCompleted).count
        )
    }
}

/// A truthful compact workout description shared by experiment timelines,
/// raw-data headers, and workout pickers. Planned cardio/yoga blocks are not
/// achievements until their session has an end timestamp.
@MainActor
struct ExperimentWorkoutSummaryPresentation: Equatable {
    let detail: String
    let systemImage: String

    static func make(
        workout: WorkoutModel,
        exercises: [ExerciseLibraryModel] = []
    ) -> ExperimentWorkoutSummaryPresentation {
        let workingSets = workout.exercises
            .flatMap(\.sets)
            .filter {
                $0.completedAt != nil && $0.setType.countsAsWorkingVolume
            }
        let completedSessions = workout.cardioSessions.filter {
            $0.deletedAt == nil && $0.endedAt != nil
        }
        let cardio = completedSessions.filter { !$0.isYogaSession }
        let yoga = completedSessions.filter(\.isYogaSession)
        let elapsed = workout.endedAt.map {
            max(0, Int($0.timeIntervalSince(workout.startedAt)))
        } ?? 0
        let recordedDuration = elapsed > 0
            ? elapsed
            : completedSessions.compactMap(\.durationSeconds).reduce(0, +)

        var parts = [Fmt.durationShort(recordedDuration)]
        if !workingSets.isEmpty {
            let recordedVolumes = workingSets.compactMap {
                ExperimentAnalysisAdapter.optionalTotalVolume(for: $0)
            }
            if recordedVolumes.isEmpty {
                parts.append("Volume not recorded")
            } else {
                let volume = Fmt.volume(recordedVolumes.reduce(0, +))
                parts.append(
                    recordedVolumes.count == workingSets.count
                        ? volume
                        : "\(volume) recorded volume"
                )
            }
        }
        if !cardio.isEmpty {
            let distance = cardio.compactMap(\.distanceMeters).reduce(0, +)
            parts.append(
                distance > 0
                    ? Fmt.distance(distance)
                    : "\(cardio.count) cardio session\(cardio.count == 1 ? "" : "s")"
            )
        }
        if !yoga.isEmpty {
            let poses = yoga.compactMap(\.logicalYogaPosesCompleted).reduce(0, +)
            parts.append(
                poses > 0
                    ? "\(poses) pose\(poses == 1 ? "" : "s")"
                    : "\(yoga.count) yoga session\(yoga.count == 1 ? "" : "s")"
            )
        }

        let categoryCount = [
            !workingSets.isEmpty,
            !cardio.isEmpty,
            !yoga.isEmpty,
        ].count(where: { $0 })
        let systemImage: String
        if categoryCount > 1 {
            systemImage = "figure.cross.training"
        } else if !workingSets.isEmpty {
            systemImage = "figure.strengthtraining.traditional"
        } else if let session = cardio.first {
            systemImage = CardioKind.from(modality: session.modality).systemImage
        } else if !yoga.isEmpty {
            systemImage = "figure.mind.and.body"
        } else {
            systemImage = "clock"
        }

        return ExperimentWorkoutSummaryPresentation(
            detail: parts.joined(separator: " · "),
            systemImage: systemImage
        )
    }
}

struct ExperimentTrainingComparison: Equatable {
    let experiment: ExperimentTrainingRollup
    let reference: ExperimentTrainingRollup

    var strengthVolume: ExperimentNumericChange {
        .init(current: experiment.strengthVolume, reference: reference.strengthVolume)
    }

    var workingSets: ExperimentNumericChange {
        .init(current: experiment.workingSets, reference: reference.workingSets)
    }

    var cardioDuration: ExperimentNumericChange {
        .init(
            current: Double(experiment.cardioDurationSeconds),
            reference: Double(reference.cardioDurationSeconds)
        )
    }

    var yogaDuration: ExperimentNumericChange {
        .init(
            current: Double(experiment.yogaDurationSeconds),
            reference: Double(reference.yogaDurationSeconds)
        )
    }
}

struct ExperimentNumericChange: Equatable {
    let current: Double
    let reference: Double

    var absolute: Double { current - reference }

    /// A zero reference has no honest percentage interpretation.
    var percent: Double? {
        guard reference != 0 else { return nil }
        return (absolute / abs(reference)) * 100
    }

    var directionSystemImage: String {
        if absolute > 0 { return "arrow.up.right" }
        if absolute < 0 { return "arrow.down.right" }
        return "arrow.right"
    }

    func percentText() -> String? {
        percent.map {
            let prefix = $0 > 0 ? "+" : ""
            return "\(prefix)\($0.formatted(.number.precision(.fractionLength(0...1))))%"
        }
    }
}

extension Date {
    func experimentDayNumber(since start: Date, calendar: Calendar = .current) -> Int {
        let startDay = calendar.startOfDay(for: start)
        let currentDay = calendar.startOfDay(for: self)
        return max(1, (calendar.dateComponents([.day], from: startDay, to: currentDay).day ?? 0) + 1)
    }
}

extension ExperimentModel {
    var experimentCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }
}

extension ExperimentTrackerType {
    var experimentTitle: String {
        switch self {
        case .number: "Number"
        case .boolean: "Yes / No"
        case .rating: "1–5 Rating"
        case .choice: "Single Choice"
        case .note: "Note"
        }
    }

    var experimentSystemImage: String {
        switch self {
        case .number: "number"
        case .boolean: "checkmark.circle"
        case .rating: "slider.horizontal.3"
        case .choice: "list.bullet.circle"
        case .note: "note.text"
        }
    }
}

extension ExperimentTrackerCadence {
    var experimentTitle: String {
        switch self {
        case .daily: "Daily"
        case .selectedWeekdays: "Selected days"
        case .perWorkout: "Each workout"
        case .anytime: "Anytime"
        }
    }
}

extension ExperimentEntryValue {
    func experimentDisplayText(unit: String? = nil) -> String {
        switch self {
        case .number(let value):
            let number = value.formatted(.number.precision(.fractionLength(0...2)))
            return [number, unit].compactMap { $0 }.joined(separator: " ")
        case .boolean(let value):
            return value ? "Yes" : "No"
        case .rating(let value):
            return "\(value) / 5"
        case .choice(let value), .note(let value):
            return value
        }
    }
}

enum ExperimentTrackerSchedule {
    static func isDue(
        _ tracker: ExperimentTrackerModel,
        on date: Date,
        calendar baseCalendar: Calendar
    ) -> Bool {
        switch tracker.cadence {
        case .daily:
            true
        case .selectedWeekdays:
            tracker.selectedWeekdays.contains(baseCalendar.component(.weekday, from: date))
        case .perWorkout, .anytime:
            false
        }
    }

    static func hasEntry(
        for tracker: ExperimentTrackerModel,
        on date: Date,
        entries: [ExperimentEntryModel],
        calendar: Calendar
    ) -> Bool {
        entries.contains {
            $0.deletedAt == nil
                && $0.trackerID == tracker.id
                && calendar.isDate($0.observedAt, inSameDayAs: date)
        }
    }

    static func expectedOccurrences(
        for tracker: ExperimentTrackerModel,
        start: Date,
        end: Date,
        workouts: [WorkoutModel],
        calendar: Calendar
    ) -> Int? {
        let trackerStart = max(start, tracker.createdAt)
        let trackerEnd = min(end, tracker.archivedAt ?? end)
        guard trackerStart < trackerEnd else {
            return tracker.cadence == .anytime ? nil : 0
        }
        switch tracker.cadence {
        case .daily, .selectedWeekdays:
            var count = 0
            var cursor = calendar.startOfDay(for: trackerStart)
            while cursor < trackerEnd {
                if tracker.cadence == .daily
                    || tracker.selectedWeekdays.contains(calendar.component(.weekday, from: cursor)) {
                    count += 1
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            return count
        case .perWorkout:
            return workouts.count {
                    $0.deletedAt == nil
                    && $0.endedAt != nil
                    && $0.startedAt >= trackerStart
                    && $0.startedAt < trackerEnd
            }
        case .anytime:
            return nil
        }
    }
}
