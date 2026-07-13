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
                .map { sharedExercise(from: $0, exerciseNames: exerciseNames) },
            cardioSessions: workout.cardioSessions
                .filter { $0.deletedAt == nil }
                .sorted { $0.startedAt < $1.startedAt }
                .map(sharedCardioSession(from:))
        )
    }

    /// Health- and GPS-stripped cardio/yoga projection. Reads ONLY training
    /// fields off the model — never `avgHR`, `activeEnergyKcal`, `hrZoneSeconds`,
    /// `tss`, `sampleSeriesJSON`, `totalSteps`, `floorsClimbed`, or `routePoints`.
    private static func sharedCardioSession(from session: CardioSessionModel) -> SharedCardioSessionDTO {
        SharedCardioSessionDTO(
            id: session.id,
            modality: session.modality,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            durationSeconds: session.durationSeconds,
            distanceMeters: session.distanceMeters,
            effort: session.effort,
            avgPaceSecondsPerKm: session.avgPaceSecondsPerKm,
            split500mSeconds: session.split500mSeconds,
            strokeRate: session.strokeRate,
            avgPowerWatts: session.avgPowerWatts,
            avgCadence: session.avgCadence,
            resistanceLevel: session.resistanceLevel,
            inclinePercent: session.inclinePercent,
            elevationGainMeters: session.elevationGainMeters,
            yogaStyleRaw: session.yogaStyleRaw,
            posesCompleted: session.posesCompleted,
            splits: session.splits.sorted { $0.index < $1.index }.map(sharedSplit(from:))
        )
    }

    private static func sharedSplit(from split: CardioSplitModel) -> SharedCardioSplitDTO {
        SharedCardioSplitDTO(
            index: split.index,
            distanceMeters: split.distanceMeters,
            durationSeconds: split.durationSeconds,
            paceSecondsPerKm: split.paceSecondsPerKm,
            elevationGainMeters: split.elevationGainMeters,
            label: split.label,
            autoDetected: split.autoDetected
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

        let yogaSessions = cardioSessions.filter(\.isYoga)
        let activeCardio = cardioSessions.filter { !$0.isYoga }
        let distance = activeCardio.compactMap(\.distanceMeters).reduce(0, +)
        // Any yoga session → yoga; else any endurance cardio → cardio; else
        // strength. (Yoga carries an exercise wrapper too, so classify by the
        // session, not by whether exercises exist.)
        let kind = !yogaSessions.isEmpty ? "yoga" : (!activeCardio.isEmpty ? "cardio" : "strength")

        // Wall-clock when known; else fall back to the sessions' own durations.
        let duration = endedAt.map { Int($0.timeIntervalSince(startedAt)) }
            ?? cardioSessions.compactMap(\.durationSeconds).reduce(0, +)

        return SharedWorkoutSummary(
            volumeKg: volume,
            workingSets: working.count,
            reps: reps,
            durationSeconds: max(0, duration),
            exerciseCount: exercises.count,
            distanceMeters: distance,
            kind: kind
        )
    }
}
