import Foundation

/// Builds `ForgeFitExportFile` pieces from live models, mirroring
/// `BackupMapper`'s conventions (position-sorted children, denormalized
/// exercise names, deterministic encoding).
public enum ExportMapper {

    // MARK: - Tombstone filter

    /// A user-facing export is "my data", not sync bookkeeping: soft-deleted
    /// workouts and cardio sessions are dropped rather than shipped as
    /// tombstones (the iCloud backup keeps them — restore semantics need
    /// them; a re-imported export must not resurrect deleted data).
    public static func filteringTombstones(_ file: ForgeFitBackupFile) -> ForgeFitBackupFile {
        var filtered = file
        filtered.workouts = file.workouts
            .filter { $0.deletedAt == nil }
            .map { workout in
                var workout = workout
                workout.cardioSessions = workout.cardioSessions.filter { $0.deletedAt == nil }
                return workout
            }
        return filtered
    }

    // MARK: - Health appendix

    /// Apple-Health-derived values ForgeFit has stored, keyed by the same ids
    /// the training log uses. Lives here — never in the backup DTOs — so the
    /// backup's typed privacy boundary stays intact.
    public static func healthMetrics(workouts: [WorkoutModel]) -> ExportHealthMetrics {
        var workoutHealth: [String: ExportWorkoutHealth] = [:]
        var sessionHealth: [String: ExportCardioSessionHealth] = [:]
        for workout in workouts where workout.deletedAt == nil {
            let health = ExportWorkoutHealth(
                avgHR: workout.avgHR,
                maxHR: workout.maxHR,
                activeEnergyKcal: workout.activeEnergyKcal,
                hrZoneSeconds: workout.hrZoneSeconds.contains(where: { $0 > 0 }) ? workout.hrZoneSeconds : nil,
                readinessAtStart: workout.readinessAtStart
            )
            if !health.isEmpty { workoutHealth[workout.id.uuidString] = health }

            for session in workout.cardioSessions where session.deletedAt == nil {
                let sessionValues = ExportCardioSessionHealth(
                    avgHR: session.avgHR,
                    maxHR: session.maxHR,
                    activeEnergyKcal: session.activeEnergyKcal,
                    hrZoneSeconds: session.hrZoneSeconds.contains(where: { $0 > 0 }) ? session.hrZoneSeconds : nil,
                    tss: session.tss,
                    totalSteps: session.totalSteps,
                    floorsClimbed: session.floorsClimbed
                )
                if !sessionValues.isEmpty { sessionHealth[session.id.uuidString] = sessionValues }
            }
        }
        return ExportHealthMetrics(workouts: workoutHealth, cardioSessions: sessionHealth)
    }

    // MARK: - Routine library

    public static func routineLibrary(
        folders: [RoutineFolderModel],
        routines: [RoutineModel],
        exerciseNames: [UUID: String]
    ) -> ExportRoutineLibrary {
        let exportFolders = folders
            .filter { $0.deletedAt == nil }
            .sorted { ($0.parentID == nil ? 0 : 1, $0.position) < ($1.parentID == nil ? 0 : 1, $1.position) }
            .map { ExportRoutineFolder(id: $0.id, name: $0.name, position: $0.position, parentID: $0.parentID, archivedAt: $0.archivedAt) }

        let exportRoutines = routines
            .filter { $0.deletedAt == nil }
            .sorted { $0.position < $1.position }
            .map { routine in
                ExportRoutine(
                    id: routine.id,
                    name: routine.name,
                    notes: routine.notes,
                    folderID: routine.folderID,
                    position: routine.position,
                    archivedAt: routine.archivedAt,
                    exercises: routine.exercises
                        .sorted { $0.position < $1.position }
                        .map { exercise in
                            ExportRoutineExercise(
                                id: exercise.id,
                                exerciseID: exercise.exerciseID,
                                name: exerciseNames[exercise.exerciseID] ?? "Unknown exercise",
                                position: exercise.position,
                                supersetGroup: exercise.supersetGroup,
                                progressionRuleJSON: exercise.progressionRuleJSON,
                                intervalPlanJSON: exercise.intervalPlanJSON,
                                yogaFlowJSON: exercise.yogaFlowJSON,
                                notes: exercise.notes,
                                sets: exercise.sets
                                    .sorted { $0.position < $1.position }
                                    .map { set in
                                        ExportRoutineSet(
                                            position: set.position,
                                            setType: set.setTypeRaw,
                                            targetRepsLow: set.targetRepsLow,
                                            targetRepsHigh: set.targetRepsHigh,
                                            targetWeightKg: set.targetWeight,
                                            targetRPE: set.targetRPE,
                                            targetRIR: set.targetRIR,
                                            targetDurationSeconds: set.targetDurationSeconds,
                                            plannedMiniSetCount: set.plannedMiniSetCount,
                                            plannedMiniReps: set.plannedMiniReps.isEmpty ? nil : set.plannedMiniReps
                                        )
                                    }
                            )
                        }
                )
            }
        return ExportRoutineLibrary(folders: exportFolders, routines: exportRoutines)
    }

    // MARK: - Encoding

    /// Same policy as `BackupMapper.encode`: ISO-8601 dates, sorted keys —
    /// deterministic bytes, stable tests. Uncompressed: readability is the
    /// point of a user export.
    public static func encode(_ file: ForgeFitExportFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data) throws -> ForgeFitExportFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ForgeFitExportFile.self, from: data)
    }
}
