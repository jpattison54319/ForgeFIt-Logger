import ForgeCore
import Foundation

/// Pure `WorkoutModel` → shared projection. `shared(from:)` IS the sanitization
/// boundary: its output type (`SharedWorkoutDTO`) has no health, location,
/// provenance, or free-text properties, so nothing sensitive can survive the
/// mapping. Mirrors `BackupMapper` — the codebase's established health boundary.
public enum SocialWorkoutMapper {

    // MARK: - Model → shared DTO

    public static func shared(from workout: WorkoutModel, exerciseNames: [UUID: String]) -> SharedWorkoutDTO {
        SharedWorkoutDTO(
            id: workout.id,
            title: workout.title,
            startedAt: workout.startedAt,
            endedAt: workout.endedAt,
            exercises: workout.exercises
                .sorted { $0.position < $1.position }
                .map { sharedExercise(from: $0, exerciseNames: exerciseNames) }
        )
    }

    private static func sharedExercise(from exercise: WorkoutExerciseModel, exerciseNames: [UUID: String]) -> SharedExerciseDTO {
        SharedExerciseDTO(
            id: exercise.id,
            exerciseID: exercise.exerciseID,
            name: exerciseNames[exercise.exerciseID] ?? "",
            position: exercise.position,
            supersetGroup: exercise.supersetGroup,
            sets: exercise.sets.sorted { $0.position < $1.position }.map(sharedSet(from:))
        )
    }

    private static func sharedSet(from set: SetModel) -> SharedSetDTO {
        SharedSetDTO(
            id: set.id,
            position: set.position,
            setType: set.setTypeRaw,
            weightMode: set.weightModeRaw,
            reps: set.reps,
            weightKg: set.weight,
            rpe: set.rpe,
            rir: set.rir,
            durationSeconds: set.durationSeconds,
            holdSeconds: set.holdSeconds,
            partialReps: set.partialReps,
            addedWeight: set.addedWeight,
            assistanceWeight: set.assistanceWeight,
            isUnilateral: set.isUnilateral,
            implementWeight: set.implementWeight,
            limbCount: set.limbCount,
            isEccentric: set.isEccentric,
            isPaused: set.isPaused,
            machineSettingsJSON: set.machineSettingsJSON,
            miniRepsJSON: set.miniRepsJSON,
            side2Reps: set.side2Reps,
            side2MiniRepsJSON: set.side2MiniRepsJSON,
            plannedMiniSetCount: set.plannedMiniSetCount,
            plannedMiniRepsJSON: set.plannedMiniRepsJSON,
            // Derived aggregates carried verbatim — never `bodyweightKg`, the
            // health input they were computed from.
            effectiveLoad: set.effectiveLoad,
            totalVolume: set.totalVolume,
            estimated1RM: set.estimated1RM,
            completedAt: set.completedAt
        )
    }

    // MARK: - Encoding for transport

    public static func encode(_ dto: SharedWorkoutDTO) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(dto)
    }

    public static func decode(_ data: Data) throws -> SharedWorkoutDTO {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SharedWorkoutDTO.self, from: data)
    }
}

public extension SharedWorkoutDTO {
    /// Health-free rollup for the recent-workouts list and the queryable
    /// CloudKit record fields. Counts only completed working sets (warm-ups
    /// don't count as working volume, matching `SetType.countsAsWorkingVolume`).
    var summary: SharedWorkoutSummary {
        let working = exercises.flatMap(\.sets).filter { set in
            set.completedAt != nil
                && (SetType(rawValue: set.setType)?.countsAsWorkingVolume ?? true)
        }
        let volume = working.compactMap(\.totalVolume).reduce(0, +)
        let reps = working.compactMap(\.reps).reduce(0, +)
        let duration = endedAt.map { Int($0.timeIntervalSince(startedAt)) } ?? 0
        return SharedWorkoutSummary(
            volumeKg: volume,
            workingSets: working.count,
            reps: reps,
            durationSeconds: max(0, duration),
            exerciseCount: exercises.count
        )
    }
}
