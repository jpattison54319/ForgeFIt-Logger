import Foundation

/// Minimal RFC-4180 CSV building. A field is quoted only when it must be
/// (contains a comma, quote, or line break); embedded quotes are doubled.
/// Numbers are locale-proof: `.` decimal, no grouping separators — a grouped
/// "1,025" silently misparses as 1.025 in comma-decimal locales.
public enum CSVWriter {
    public static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func row(_ fields: [String]) -> String {
        fields.map(field).joined(separator: ",")
    }

    public static func document(header: [String], rows: [[String]]) -> String {
        ([row(header)] + rows.map(row)).joined(separator: "\n") + "\n"
    }

    /// ≤4 fraction digits, trailing zeros trimmed, never localized.
    public static func number(_ value: Double?) -> String {
        guard let value else { return "" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        var text = String(format: "%.4f", locale: nil, value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    public static func number(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    public static func date(_ value: Date?) -> String {
        value.map { $0.formatted(.iso8601) } ?? ""
    }

    public static func bool(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}

/// The workouts CSV: all the data per workout in one denormalized file — one
/// row per set and one row per cardio session, workout-level columns repeated
/// on every row. Column vocabulary is raw ForgeFit terms (`set_type: myoRep`),
/// no translation layer. Splits, GPS routes, and HR time-series don't fit a
/// CSV honestly — they are JSON-export-only, and the UI copy says so.
///
/// Built over the backup DTOs (health-inexpressible by type) plus the export
/// health appendix, so health values can only enter through their dedicated
/// columns.
public enum WorkoutCSVExport {
    public static let header: [String] = [
        "workout_id", "workout_title", "started_at", "ended_at", "workout_notes",
        "avg_hr", "max_hr", "active_energy_kcal", "readiness_at_start",
        "entry_type",
        "exercise", "exercise_position", "superset_group", "exercise_notes",
        "set_position", "set_type", "weight_kg", "reps", "rpe", "rir",
        "duration_seconds", "hold_seconds", "partial_reps",
        "added_weight_kg", "assistance_weight_kg", "implement_weight_kg",
        "is_unilateral", "side2_reps", "completed_at",
        "modality", "distance_m", "cardio_duration_seconds", "effort",
        "avg_pace_seconds_per_km", "avg_power_watts", "avg_cadence",
        "elevation_gain_m", "cardio_avg_hr", "cardio_max_hr", "cardio_kcal",
    ]

    public static func csv(workouts: [BackupWorkout], health: ExportHealthMetrics) -> String {
        var rows: [[String]] = []
        for workout in workouts {
            let workoutHealth = health.workouts[workout.id.uuidString]
            let workoutColumns = [
                workout.id.uuidString,
                workout.title ?? "Workout",
                CSVWriter.date(workout.startedAt),
                CSVWriter.date(workout.endedAt),
                workout.notes ?? "",
                CSVWriter.number(workoutHealth?.avgHR),
                CSVWriter.number(workoutHealth?.maxHR),
                CSVWriter.number(workoutHealth?.activeEnergyKcal),
                CSVWriter.number(workoutHealth?.readinessAtStart),
            ]
            let exercisesByID = Dictionary(
                workout.exercises.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let cardioExerciseIDs = Set(workout.cardioSessions.compactMap(\.workoutExerciseID))

            for exercise in workout.exercises.sorted(by: { $0.position < $1.position })
            where !cardioExerciseIDs.contains(exercise.id) {
                for set in exercise.sets.sorted(by: { $0.position < $1.position }) {
                    rows.append(workoutColumns + [
                        "set",
                        exercise.name,
                        CSVWriter.number(exercise.position),
                        CSVWriter.number(exercise.supersetGroup),
                        exercise.notes ?? "",
                        CSVWriter.number(set.position),
                        set.setType,
                        CSVWriter.number(set.weightKg),
                        CSVWriter.number(set.reps),
                        CSVWriter.number(set.rpe),
                        CSVWriter.number(set.rir),
                        CSVWriter.number(set.durationSeconds),
                        CSVWriter.number(set.holdSeconds),
                        CSVWriter.number(set.partialReps),
                        CSVWriter.number(set.addedWeight),
                        CSVWriter.number(set.assistanceWeight),
                        CSVWriter.number(set.implementWeight),
                        CSVWriter.bool(set.isUnilateral),
                        CSVWriter.number(set.side2Reps),
                        CSVWriter.date(set.completedAt),
                    ] + Array(repeating: "", count: 11))
                }
            }

            for session in workout.cardioSessions {
                let anchor = session.workoutExerciseID.flatMap { exercisesByID[$0] }
                let sessionHealth = health.cardioSessions[session.id.uuidString]
                rows.append(workoutColumns + [
                    "cardio",
                    anchor?.name ?? session.modality.capitalized,
                    CSVWriter.number(anchor?.position),
                    "", // superset_group
                    anchor?.notes ?? "",
                ] + Array(repeating: "", count: 15) + [
                    session.modality,
                    CSVWriter.number(session.distanceMeters),
                    CSVWriter.number(session.durationSeconds),
                    CSVWriter.number(session.effort),
                    CSVWriter.number(session.avgPaceSecondsPerKm),
                    CSVWriter.number(session.avgPowerWatts),
                    CSVWriter.number(session.avgCadence),
                    CSVWriter.number(session.elevationGainMeters),
                    CSVWriter.number(sessionHealth?.avgHR),
                    CSVWriter.number(sessionHealth?.maxHR),
                    CSVWriter.number(sessionHealth?.activeEnergyKcal),
                ])
            }
        }
        return CSVWriter.document(header: header, rows: rows)
    }
}
