import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// User-directed export for one experiment. Unlike the automatic iCloud
/// backup, this may contain custom and Health-derived values, so it is only
/// reached from the explicit results-screen share action.
nonisolated enum ExperimentExportService {
    enum ExportError: LocalizedError {
        case experimentNotFound

        var errorDescription: String? {
            switch self {
            case .experimentNotFound: "The experiment is no longer available."
            }
        }
    }

    struct Payload: Codable, Sendable {
        var formatVersion: Int
        var exportedAt: Date
        var appVersion: String?
        var analysisContractVersion: Int
        var units: UnitManifest
        var experiment: ExperimentRow
        var comparisonAnalysis: ExperimentResult?
        var trackers: [TrackerRow]
        var entries: [EntryRow]
        var workouts: [WorkoutRow]
        var sets: [SetRow]
        var cardio: [CardioRow]
        var health: [HealthRow]
    }

    struct UnitManifest: Codable, Sendable {
        var mass: String = "kilograms"
        var strengthVolume: String = "kilogram-repetitions"
        var distance: String = "meters"
        var duration: String = "seconds"
        var energy: String = "kilocalories"
        var heartRate: String = "beats-per-minute"
        var heartRateVariability: String = "milliseconds"
    }

    struct ExperimentRow: Codable, Sendable {
        var id: UUID
        var name: String
        var protocolDescription: String?
        var question: String?
        var startedAt: Date
        var plannedEndAt: Date
        var endedAt: Date?
        var effectiveEndAt: Date
        var timeZoneIdentifier: String
        var state: String
        var headlineMetricSelectionsJSON: String
        var savedComparisonJSON: String?
        var schemaVersion: Int
    }

    struct TrackerRow: Codable, Sendable {
        var id: UUID
        var label: String
        var type: String
        var unit: String?
        var scaleMinimumLabel: String?
        var scaleMaximumLabel: String?
        var optionsJSON: String
        var cadence: String
        var selectedWeekdaysJSON: String
        var position: Int
        var definitionVersion: Int
        var createdAt: Date
        var updatedAt: Date
        var archivedAt: Date?
    }

    struct EntryRow: Codable, Sendable {
        var id: UUID
        var trackerID: UUID
        var workoutID: UUID?
        var observedAt: Date
        var valueType: String
        var numericValue: Double?
        var booleanValue: Bool?
        var textValue: String?
        var choiceValue: String?
        var ratingValue: Int?
        var definitionSnapshotJSON: String
        var updatedAt: Date
    }

    struct WorkoutRow: Codable, Sendable {
        var id: UUID
        var title: String
        var startedAt: Date
        var endedAt: Date
        var source: String?
        var durationSeconds: Int
        var strengthVolume: Double
        var workingSets: Double
        var reps: Int
        var averageHeartRate: Int?
        var maximumHeartRate: Int?
        var activeEnergyKilocalories: Double?
        var sessionRPE: Double?
        var readinessAtStart: Int?
    }

    struct SetRow: Codable, Sendable {
        var workoutID: UUID
        var workoutStartedAt: Date
        var exerciseID: UUID
        var exerciseName: String
        var position: Int
        var setType: String
        var weightMode: String
        var enteredWeightKilograms: Double?
        var addedWeightKilograms: Double?
        var assistanceWeightKilograms: Double?
        var bodyweightKilograms: Double?
        var effectiveLoadKilograms: Double?
        var reps: Int?
        var rpe: Double?
        var rir: Int?
        var durationSeconds: Int?
        var totalVolume: Double?
        var estimatedOneRepMax: Double?
        var completedAt: Date
    }

    struct CardioRow: Codable, Sendable {
        var workoutID: UUID
        var sessionID: UUID
        var modality: String
        var startedAt: Date
        var endedAt: Date?
        var durationSeconds: Int?
        var distanceMeters: Double?
        var averagePaceSecondsPerKilometer: Double?
        var averageHeartRate: Int?
        var maximumHeartRate: Int?
        var activeEnergyKilocalories: Double?
        var zoneSeconds: [Int]
        var averagePowerWatts: Double?
        var elevationGainMeters: Double?
        var steps: Int?
        var posesCompleted: Int?
    }

    struct HealthRow: Codable, Sendable {
        var date: Date
        var hrvMilliseconds: Double?
        var restingHeartRate: Int?
        var respiratoryRate: Double?
        var oxygenSaturationPercent: Double?
        var sleepTotalMinutes: Int?
        var sleepDeepMinutes: Int?
        var sleepREMMinutes: Int?
        var bodyWeightKilograms: Double?
        var steps: Double?
        var exerciseMinutes: Double?
        var activeEnergyKilocalories: Double?
    }

    @MainActor
    static func export(
        experimentID: UUID,
        container: ModelContainer,
        now: Date = .now
    ) async throws -> [URL] {
        let context = container.mainContext
        guard let experiment = try context.fetch(FetchDescriptor<ExperimentModel>())
            .first(where: { $0.id == experimentID && $0.deletedAt == nil }) else {
            throw ExportError.experimentNotFound
        }

        let effectiveEnd = min(experiment.endedAt ?? now, experiment.plannedEndAt)
        let allTrackers = try context.fetch(FetchDescriptor<ExperimentTrackerModel>())
            .filter { $0.deletedAt == nil }
        let trackers = allTrackers.filter { $0.experimentID == experimentID }
        let allEntries = try context.fetch(FetchDescriptor<ExperimentEntryModel>())
            .filter { $0.deletedAt == nil }
        let entries = allEntries.filter {
                $0.experimentID == experimentID
                    && $0.observedAt >= experiment.startedAt
                    && $0.observedAt < effectiveEnd
            }
        let allWorkouts = try context.fetch(FetchDescriptor<WorkoutModel>())
            .filter { $0.deletedAt == nil && $0.endedAt != nil }
        let workouts = allWorkouts.filter {
            $0.startedAt >= experiment.startedAt && $0.startedAt < effectiveEnd
        }
        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let exerciseNames = Dictionary(
            exercises.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let analytics = TrainingAnalytics(workouts: workouts, exercises: exercises)

        let workoutRows = workouts.compactMap { workout -> WorkoutRow? in
            guard let endedAt = workout.endedAt else { return nil }
            let summary = analytics.summary(for: workout)
            return WorkoutRow(
                id: workout.id,
                title: workout.title ?? "Workout",
                startedAt: workout.startedAt,
                endedAt: endedAt,
                source: workout.externalSource ?? workout.sourceDevice,
                durationSeconds: summary.durationSeconds,
                strengthVolume: summary.volume,
                workingSets: summary.sets,
                reps: summary.reps,
                averageHeartRate: workout.avgHR,
                maximumHeartRate: workout.maxHR,
                activeEnergyKilocalories: workout.activeEnergyKcal,
                sessionRPE: workout.wholeSessionRPE,
                readinessAtStart: workout.readinessAtStart
            )
        }
        let setRows = workouts.flatMap { workout in
            workout.exercises.flatMap { exercise in
                exercise.sets.compactMap { set -> SetRow? in
                    guard let completedAt = set.completedAt else { return nil }
                    return SetRow(
                        workoutID: workout.id,
                        workoutStartedAt: workout.startedAt,
                        exerciseID: exercise.exerciseID,
                        exerciseName: exerciseNames[exercise.exerciseID] ?? "Exercise",
                        position: set.position,
                        setType: set.setTypeRaw,
                        weightMode: set.weightModeRaw,
                        enteredWeightKilograms: set.weight,
                        addedWeightKilograms: set.addedWeight,
                        assistanceWeightKilograms: set.assistanceWeight,
                        bodyweightKilograms: set.bodyweightKg,
                        effectiveLoadKilograms: ExperimentAnalysisAdapter.optionalEffectiveLoad(
                            for: set
                        ),
                        reps: set.reps,
                        rpe: set.rpe,
                        rir: set.rir,
                        durationSeconds: set.durationSeconds,
                        totalVolume: ExperimentAnalysisAdapter.optionalTotalVolume(for: set),
                        estimatedOneRepMax: set.estimated1RM,
                        completedAt: completedAt
                    )
                }
            }
        }
        let cardioRows = workouts.flatMap { workout in
            workout.cardioSessions.compactMap { session -> CardioRow? in
                guard session.deletedAt == nil else { return nil }
                return CardioRow(
                    workoutID: workout.id,
                    sessionID: session.id,
                    modality: session.modality,
                    startedAt: session.liveStartedAt ?? session.startedAt,
                    endedAt: session.endedAt,
                    durationSeconds: session.durationSeconds,
                    distanceMeters: session.distanceMeters,
                    averagePaceSecondsPerKilometer: session.avgPaceSecondsPerKm,
                    averageHeartRate: session.avgHR,
                    maximumHeartRate: session.maxHR,
                    activeEnergyKilocalories: session.activeEnergyKcal,
                    zoneSeconds: session.hrZoneSeconds,
                    averagePowerWatts: session.avgPowerWatts,
                    elevationGainMeters: session.elevationGainMeters,
                    steps: session.totalSteps,
                    posesCompleted: session.logicalYogaPosesCompleted
                )
            }
        }

        let savedComparison = ExperimentSavedComparison.decode(
            experiment.savedComparisonJSON
        )
        let reference = savedComparison?.reference ?? .previousEqualPeriod
        let comparisonRequest = try? ExperimentAnalysisAdapter.comparisonRequest(
            experiment: experiment,
            reference: reference,
            now: now
        )
        let healthSnapshot: ExperimentHealthSnapshot
        if let comparisonRequest {
            healthSnapshot = (try? await ExperimentHealthLoader.load(
                request: comparisonRequest
            )) ?? .empty
        } else {
            healthSnapshot = .empty
        }
        let healthRows = healthSnapshot.days
            .filter { comparisonRequest?.currentWindow.contains($0.timestamp) == true }
            .map {
                HealthRow(
                    date: $0.timestamp,
                    hrvMilliseconds: $0.hrvMilliseconds,
                    restingHeartRate: $0.restingHeartRate,
                    respiratoryRate: $0.respiratoryRate,
                    oxygenSaturationPercent: $0.oxygenSaturationPercent,
                    sleepTotalMinutes: $0.sleepTotalMinutes,
                    sleepDeepMinutes: $0.sleepDeepMinutes,
                    sleepREMMinutes: $0.sleepREMMinutes,
                    bodyWeightKilograms: $0.bodyWeightKilograms,
                    steps: $0.steps,
                    exerciseMinutes: $0.exerciseMinutes,
                    activeEnergyKilocalories: $0.activeEnergyKilocalories
                )
            }

        let comparisonAnalysis = try? ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: allTrackers,
            entries: allEntries,
            workouts: allWorkouts,
            exercises: exercises,
            reference: reference,
            customTrackerPairs: savedComparison?.customTrackerPairs ?? [:],
            healthSnapshot: healthSnapshot,
            now: now
        )
        let payload = Payload(
            formatVersion: 1,
            exportedAt: now,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            analysisContractVersion: ExperimentAnalysisContract.currentVersion,
            units: UnitManifest(),
            experiment: ExperimentRow(
                id: experiment.id,
                name: experiment.name,
                protocolDescription: experiment.protocolDescription,
                question: experiment.question,
                startedAt: experiment.startedAt,
                plannedEndAt: experiment.plannedEndAt,
                endedAt: experiment.endedAt,
                effectiveEndAt: effectiveEnd,
                timeZoneIdentifier: experiment.timeZoneIdentifier,
                state: experiment.stateRaw,
                headlineMetricSelectionsJSON: experiment.headlineMetricSelectionsJSON,
                savedComparisonJSON: experiment.savedComparisonJSON,
                schemaVersion: experiment.schemaVersion
            ),
            comparisonAnalysis: comparisonAnalysis,
            trackers: trackers
                .sorted { $0.position < $1.position }
                .map {
                    TrackerRow(
                        id: $0.id,
                        label: $0.label,
                        type: $0.typeRaw,
                        unit: $0.unit,
                        scaleMinimumLabel: $0.scaleMinimumLabel,
                        scaleMaximumLabel: $0.scaleMaximumLabel,
                        optionsJSON: $0.optionsJSON,
                        cadence: $0.cadenceRaw,
                        selectedWeekdaysJSON: $0.selectedWeekdaysJSON,
                        position: $0.position,
                        definitionVersion: $0.definitionVersion,
                        createdAt: $0.createdAt,
                        updatedAt: $0.updatedAt,
                        archivedAt: $0.archivedAt
                    )
                },
            entries: entries
                .sorted { $0.observedAt < $1.observedAt }
                .map {
                    EntryRow(
                        id: $0.id,
                        trackerID: $0.trackerID,
                        workoutID: $0.workoutID,
                        observedAt: $0.observedAt,
                        valueType: $0.valueTypeRaw,
                        numericValue: $0.numericValue,
                        booleanValue: $0.booleanValue,
                        textValue: $0.textValue,
                        choiceValue: $0.choiceValue,
                        ratingValue: $0.ratingValue,
                        definitionSnapshotJSON: $0.definitionSnapshotJSON,
                        updatedAt: $0.updatedAt
                    )
                },
            workouts: workoutRows.sorted { $0.startedAt < $1.startedAt },
            sets: setRows.sorted {
                ($0.workoutStartedAt, $0.exerciseName, $0.position)
                    < ($1.workoutStartedAt, $1.exerciseName, $1.position)
            },
            cardio: cardioRows.sorted { $0.startedAt < $1.startedAt },
            health: healthRows
        )

        return try await write(payload)
    }

    private static var exportRootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeFitExperimentExports", isDirectory: true)
    }

    static func cleanup(urls: [URL]) {
        let rootPath = exportRootDirectory.standardizedFileURL.path + "/"
        let directories = Set(urls.map {
            $0.deletingLastPathComponent().standardizedFileURL
        })
        for directory in directories where directory.path.hasPrefix(rootPath) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func cleanupAll() {
        try? FileManager.default.removeItem(at: exportRootDirectory)
    }

    private static func write(_ payload: Payload) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            let directory = exportRootDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let stamp = payload.exportedAt.formatted(.iso8601.year().month().day())
            let base = "ForgeFit-Experiment-\(stamp)-\(payload.experiment.id.uuidString.prefix(8))"
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let jsonURL = directory.appendingPathComponent("\(base).json")
                try encoder.encode(payload).write(to: jsonURL, options: .atomic)

                let entriesURL = directory.appendingPathComponent("\(base)-Custom-Entries.csv")
                try entriesCSV(payload.entries, trackers: payload.trackers)
                    .write(to: entriesURL, atomically: true, encoding: .utf8)
                let workoutsURL = directory.appendingPathComponent("\(base)-Workouts.csv")
                try workoutsCSV(payload.workouts)
                    .write(to: workoutsURL, atomically: true, encoding: .utf8)
                let setsURL = directory.appendingPathComponent("\(base)-Sets.csv")
                try setsCSV(payload.sets)
                    .write(to: setsURL, atomically: true, encoding: .utf8)
                let cardioURL = directory.appendingPathComponent("\(base)-Cardio.csv")
                try cardioCSV(payload.cardio)
                    .write(to: cardioURL, atomically: true, encoding: .utf8)
                let healthURL = directory.appendingPathComponent("\(base)-Daily-Health.csv")
                try healthCSV(payload.health)
                    .write(to: healthURL, atomically: true, encoding: .utf8)
                return [jsonURL, entriesURL, workoutsURL, setsURL, cardioURL, healthURL]
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    private static func entriesCSV(_ rows: [EntryRow], trackers: [TrackerRow]) -> String {
        let names = Dictionary(trackers.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        let header = ["entry_id", "tracker_id", "tracker", "workout_id", "observed_at", "type", "number", "boolean", "text", "choice", "rating"]
        let body = rows.map { row -> [String] in
            let values: [String] = [
                row.id.uuidString, row.trackerID.uuidString, names[row.trackerID] ?? "",
                row.workoutID?.uuidString ?? "", iso(row.observedAt), row.valueType,
                number(row.numericValue), row.booleanValue.map(String.init) ?? "",
                row.textValue ?? "", row.choiceValue ?? "", row.ratingValue.map(String.init) ?? "",
            ]
            return values
        }
        return csv(header: header, rows: body)
    }

    private static func workoutsCSV(_ rows: [WorkoutRow]) -> String {
        let header = [
            "workout_id", "title", "started_at", "ended_at", "source", "duration_seconds",
            "strength_volume_kg_reps", "working_sets", "reps", "avg_hr_bpm", "max_hr_bpm",
            "active_energy_kcal", "session_rpe", "readiness_at_start",
        ]
        let body = rows.map { row -> [String] in
            let values: [String] = [
                row.id.uuidString, row.title, iso(row.startedAt), iso(row.endedAt), row.source ?? "",
                String(row.durationSeconds), number(row.strengthVolume), number(row.workingSets),
                String(row.reps), row.averageHeartRate.map(String.init) ?? "",
                row.maximumHeartRate.map(String.init) ?? "", number(row.activeEnergyKilocalories),
                number(row.sessionRPE), row.readinessAtStart.map(String.init) ?? "",
            ]
            return values
        }
        return csv(header: header, rows: body)
    }

    private static func setsCSV(_ rows: [SetRow]) -> String {
        let header = [
            "workout_id", "workout_started_at", "exercise_id", "exercise", "position",
            "set_type", "weight_mode", "entered_weight_kg", "added_weight_kg",
            "assistance_weight_kg", "bodyweight_kg", "effective_load_kg", "reps", "rpe",
            "rir", "duration_seconds", "volume_kg_reps", "estimated_1rm_kg", "completed_at",
        ]
        let body = rows.map { row -> [String] in
            let values: [String] = [
                row.workoutID.uuidString, iso(row.workoutStartedAt), row.exerciseID.uuidString,
                row.exerciseName, String(row.position), row.setType, row.weightMode,
                number(row.enteredWeightKilograms), number(row.addedWeightKilograms),
                number(row.assistanceWeightKilograms), number(row.bodyweightKilograms),
                number(row.effectiveLoadKilograms), row.reps.map(String.init) ?? "",
                number(row.rpe), row.rir.map(String.init) ?? "",
                row.durationSeconds.map(String.init) ?? "", number(row.totalVolume),
                number(row.estimatedOneRepMax), iso(row.completedAt),
            ]
            return values
        }
        return csv(header: header, rows: body)
    }

    private static func cardioCSV(_ rows: [CardioRow]) -> String {
        let header = [
            "workout_id", "session_id", "modality", "started_at", "ended_at",
            "duration_seconds", "distance_meters", "pace_seconds_per_km", "avg_hr_bpm",
            "max_hr_bpm", "active_energy_kcal", "zone_seconds", "avg_power_watts",
            "elevation_gain_meters", "steps", "poses_completed",
        ]
        let body = rows.map { row -> [String] in
            let values: [String] = [
                row.workoutID.uuidString, row.sessionID.uuidString, row.modality, iso(row.startedAt),
                row.endedAt.map(iso) ?? "", row.durationSeconds.map(String.init) ?? "",
                number(row.distanceMeters), number(row.averagePaceSecondsPerKilometer),
                row.averageHeartRate.map(String.init) ?? "",
                row.maximumHeartRate.map(String.init) ?? "",
                number(row.activeEnergyKilocalories),
                row.zoneSeconds.map(String.init).joined(separator: "|"),
                number(row.averagePowerWatts), number(row.elevationGainMeters),
                row.steps.map(String.init) ?? "", row.posesCompleted.map(String.init) ?? "",
            ]
            return values
        }
        return csv(header: header, rows: body)
    }

    private static func healthCSV(_ rows: [HealthRow]) -> String {
        let header = [
            "date", "hrv_ms", "resting_hr_bpm", "respiratory_rate_per_minute",
            "oxygen_saturation_percent", "sleep_total_minutes", "sleep_deep_minutes",
            "sleep_rem_minutes", "body_weight_kg", "steps", "exercise_minutes",
            "active_energy_kcal",
        ]
        let body = rows.map { row -> [String] in
            let values: [String] = [
                iso(row.date), number(row.hrvMilliseconds),
                row.restingHeartRate.map(String.init) ?? "",
                number(row.respiratoryRate), number(row.oxygenSaturationPercent),
                row.sleepTotalMinutes.map(String.init) ?? "",
                row.sleepDeepMinutes.map(String.init) ?? "",
                row.sleepREMMinutes.map(String.init) ?? "", number(row.bodyWeightKilograms),
                number(row.steps), number(row.exerciseMinutes), number(row.activeEnergyKilocalories),
            ]
            return values
        }
        return csv(header: header, rows: body)
    }

    private static func csv(header: [String], rows: [[String]]) -> String {
        ([header] + rows)
            .map { $0.map(escapeCSV).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
    }

    private static func escapeCSV(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func number(_ value: Double?) -> String {
        value.map { String($0) } ?? ""
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
