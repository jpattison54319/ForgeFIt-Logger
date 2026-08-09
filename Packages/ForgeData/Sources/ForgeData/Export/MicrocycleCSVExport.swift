import ForgeCore
import Foundation

public enum MicrocycleCSVExport {
    public static let windowHeader = [
        "tracking_id", "window_index", "mesocycle", "microcycle",
        "starts_at", "ends_at", "expected_routines", "completed_routines",
    ]

    public static let restDayHeader = ["date", "time_zone"]

    public static func windows(file: ForgeFitBackupFile, routines: ExportRoutineLibrary) -> String {
        let folders = Dictionary(
            routines.folders.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let keyedWorkouts = file.workouts.compactMap { workout -> (UUID, BackupWorkout)? in
            guard workout.endedAt != nil, workout.deletedAt == nil, let routineID = workout.routineID else {
                return nil
            }
            return (routineID, workout)
        }
        let completedByRoutineAndWindow = Dictionary(grouping: keyedWorkouts, by: \.0)
            .mapValues { $0.map(\.1) }
        let completedWorkoutByID = Dictionary(
            file.workouts.compactMap { workout -> (UUID, BackupWorkout)? in
                guard workout.endedAt != nil, workout.deletedAt == nil else { return nil }
                return (workout.id, workout)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let rows = (file.microcycleWindows ?? [])
            .filter { $0.deletedAt == nil }
            .sorted { $0.startsAt < $1.startsAt }
            .map { window -> [String] in
                let snapshots = decodeSnapshots(window.routineSnapshotJSON)
                let assignedWorkouts = decodeAssignments(window.dayAssignmentSnapshotJSON)
                    .filter { $0.day >= window.startsAt && $0.day < window.endsAt }
                    .compactMap { completedWorkoutByID[$0.workoutID] }
                let completed = snapshots.count { snapshot in
                    (completedByRoutineAndWindow[snapshot.id] ?? []).contains {
                        $0.startedAt >= window.startsAt && $0.startedAt < window.endsAt
                    }
                        || assignedWorkouts.contains { $0.routineID == snapshot.id }
                }
                let folder = folders[window.folderID]
                let mesocycle = folder?.parentID.flatMap { folders[$0]?.name } ?? ""
                return [
                    window.trackingID.uuidString,
                    CSVWriter.number(window.index + 1),
                    mesocycle,
                    window.folderName,
                    window.startsAt.formatted(.iso8601),
                    window.endsAt.formatted(.iso8601),
                    CSVWriter.number(snapshots.count),
                    CSVWriter.number(completed),
                ]
            }
        return CSVWriter.document(header: windowHeader, rows: rows)
    }

    public static func restDays(file: ForgeFitBackupFile) -> String {
        let rows = (file.restDays ?? [])
            .filter { $0.deletedAt == nil }
            .sorted { $0.date < $1.date }
            .map { [$0.date.formatted(.iso8601), $0.timeZoneIdentifier] }
        return CSVWriter.document(header: restDayHeader, rows: rows)
    }

    private static func decodeSnapshots(_ json: String) -> [MicrocycleRoutineSnapshot] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([MicrocycleRoutineSnapshot].self, from: data)) ?? []
    }

    private static func decodeAssignments(_ json: String?) -> [MicrocycleDayAssignment] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([MicrocycleDayAssignment].self, from: data)) ?? []
    }
}
